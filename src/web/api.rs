//! Defines Rojo's HTTP API, all under /api. These endpoints generally return
//! JSON.

use std::{
    collections::{HashMap, HashSet},
    fs,
    path::PathBuf,
    str::FromStr,
    sync::Arc,
};

use futures::{sink::SinkExt, stream::StreamExt};
use hyper::{body, Body, Method, Request, Response, StatusCode};
use hyper_tungstenite::{is_upgrade_request, tungstenite::Message, upgrade, HyperWebsocket};
use opener::OpenError;
use rbx_dom_weak::{
    types::{Ref, Variant},
    InstanceBuilder, UstrMap, WeakDom,
};

use crate::{
    json,
    serve_session::ServeSession,
    snapshot::{InstanceWithMeta, PatchSet, PatchUpdate},
    web::{
        interface::{
            ErrorResponse, Instance, MessagesPacket, OpenResponse, ReadResponse,
            ServerInfoResponse, SocketPacket, SocketPacketBody, SocketPacketType, SubscribeMessage,
            VibeStarterStatusResponse, WriteRequest, WriteResponse, PROTOCOL_VERSION,
            SERVER_VERSION,
        },
        util::{json, json_ok},
    },
    web_api::{BufferEncode, InstanceUpdate, RefPatchResponse, SerializeResponse},
};

pub async fn call(serve_session: Arc<ServeSession>, mut request: Request<Body>) -> Response<Body> {
    let service = ApiService::new(serve_session);

    match (request.method(), request.uri().path()) {
        (&Method::GET, "/api/rojo") => service.handle_api_rojo().await,
        (&Method::GET, "/api/vibestarter/status") => service.handle_vibestarter_status().await,
        (&Method::GET, path) if path.starts_with("/api/read/") => {
            service.handle_api_read(request).await
        }
        (&Method::GET, path) if path.starts_with("/api/socket/") => {
            if is_upgrade_request(&request) {
                service.handle_api_socket(&mut request).await
            } else {
                json(
                    ErrorResponse::bad_request(
                        "/api/socket must be called as a websocket upgrade request",
                    ),
                    StatusCode::BAD_REQUEST,
                )
            }
        }
        (&Method::GET, path) if path.starts_with("/api/serialize/") => {
            service.handle_api_serialize(request).await
        }
        (&Method::GET, path) if path.starts_with("/api/ref-patch/") => {
            service.handle_api_ref_patch(request).await
        }

        (&Method::POST, path) if path.starts_with("/api/open/") => {
            service.handle_api_open(request).await
        }
        (&Method::POST, "/api/write") => service.handle_api_write(request).await,

        (_method, path) => json(
            ErrorResponse::not_found(format!("Route not found: {}", path)),
            StatusCode::NOT_FOUND,
        ),
    }
}

pub struct ApiService {
    serve_session: Arc<ServeSession>,
}

impl ApiService {
    pub fn new(serve_session: Arc<ServeSession>) -> Self {
        ApiService { serve_session }
    }

    /// Get a summary of information about the server
    async fn handle_api_rojo(&self) -> Response<Body> {
        let tree = self.serve_session.tree();
        let root_instance_id = tree.get_root_id();

        let history = self.serve_session.message_queue().stats();
        json_ok(&ServerInfoResponse {
            oldest_message_cursor: history.oldest_cursor,
            message_cursor: history.current_cursor,
            server_version: SERVER_VERSION.to_owned(),
            protocol_version: PROTOCOL_VERSION,
            session_id: self.serve_session.session_id(),
            project_name: self.serve_session.project_name().to_owned(),
            expected_place_ids: self.serve_session.serve_place_ids().cloned(),
            unexpected_place_ids: self.serve_session.blocked_place_ids().cloned(),
            place_id: self.serve_session.place_id(),
            game_id: self.serve_session.game_id(),
            root_instance_id,
            vibestarter_project_id: self.vibestarter_project_id(),
        })
    }

    /// VibeStarter Sync: read the `id` field of the served project's
    /// `vibestarter.json` (the committed source-of-truth UUID). Best-effort —
    /// any missing file / parse error yields `None`, which simply leaves
    /// marker auto-connect disabled (the user can still connect manually).
    fn vibestarter_project_id(&self) -> Option<String> {
        let path = self.serve_session.root_dir().join("vibestarter.json");
        let text = fs::read_to_string(path).ok()?;
        serde_json::from_str::<serde_json::Value>(&text)
            .ok()?
            .get("id")?
            .as_str()
            .map(str::to_owned)
    }

    /// VibeStarter Sync extension: structured session/connection state for the
    /// host app, replacing log-scraping of "WebSocket subscription
    /// established/closed".
    async fn handle_vibestarter_status(&self) -> Response<Body> {
        let root_instance_id = self.serve_session.tree().get_root_id();
        let socket_client_count = self.serve_session.socket_client_count();
        let (last_patch_age_secs, last_patch_summary, last_error) =
            self.serve_session.sync_status().snapshot();

        json_ok(&VibeStarterStatusResponse {
            message_history: self.serve_session.message_queue().stats(),
            server_version: SERVER_VERSION.to_owned(),
            protocol_version: PROTOCOL_VERSION,
            session_id: self.serve_session.session_id(),
            project_name: self.serve_session.project_name().to_owned(),
            root_instance_id,
            message_cursor: self.serve_session.message_queue().cursor(),
            socket_client_count,
            studio_connected: socket_client_count > 0,
            last_patch_age_secs,
            last_patch_summary,
            last_error,
        })
    }

    /// Handle WebSocket upgrade for real-time message streaming
    async fn handle_api_socket(&self, request: &mut Request<Body>) -> Response<Body> {
        let argument = &request.uri().path()["/api/socket/".len()..];
        let input_cursor: u32 = match argument.parse() {
            Ok(v) => v,
            Err(err) => {
                return json(
                    ErrorResponse::bad_request(format!("Malformed message cursor: {}", err)),
                    StatusCode::BAD_REQUEST,
                );
            }
        };

        // Upgrade the connection to WebSocket
        let (response, websocket) = match upgrade(request, None) {
            Ok(result) => result,
            Err(err) => {
                return json(
                    ErrorResponse::internal_error(format!("WebSocket upgrade failed: {}", err)),
                    StatusCode::INTERNAL_SERVER_ERROR,
                );
            }
        };

        let serve_session = Arc::clone(&self.serve_session);

        // Spawn a task to handle the WebSocket connection
        tokio::spawn(async move {
            if let Err(e) =
                handle_websocket_subscription(serve_session, websocket, input_cursor).await
            {
                log::error!("Error in websocket subscription: {}", e);
            }
        });

        response
    }

    async fn handle_api_write(&self, request: Request<Body>) -> Response<Body> {
        let session_id = self.serve_session.session_id();
        let tree_mutation_sender = self.serve_session.tree_mutation_sender();

        let body = body::to_bytes(request.into_body()).await.unwrap();

        let request: WriteRequest = match json::from_slice(&body) {
            Ok(request) => request,
            Err(err) => {
                return json(
                    ErrorResponse::bad_request(format!("Invalid body: {}", err)),
                    StatusCode::BAD_REQUEST,
                );
            }
        };

        if request.session_id != session_id {
            return json(
                ErrorResponse::bad_request("Wrong session ID"),
                StatusCode::BAD_REQUEST,
            );
        }

        let updated_instances = request
            .updated
            .into_iter()
            .map(|update| PatchUpdate {
                id: update.id,
                changed_class_name: update.changed_class_name,
                changed_name: update.changed_name,
                changed_properties: update.changed_properties,
                changed_metadata: None,
            })
            .collect();

        tree_mutation_sender
            .send(PatchSet {
                removed_instances: Vec::new(),
                added_instances: Vec::new(),
                updated_instances,
            })
            .unwrap();

        json_ok(WriteResponse { session_id })
    }

    async fn handle_api_read(&self, request: Request<Body>) -> Response<Body> {
        let argument = &request.uri().path()["/api/read/".len()..];
        let requested_ids: Result<Vec<Ref>, _> = argument.split(',').map(Ref::from_str).collect();

        let requested_ids = match requested_ids {
            Ok(ids) => ids,
            Err(_) => {
                return json(
                    ErrorResponse::bad_request("Malformed ID list"),
                    StatusCode::BAD_REQUEST,
                );
            }
        };

        let message_queue = self.serve_session.message_queue();
        let tree = self.serve_session.tree();
        let message_cursor = message_queue.cursor();

        let mut instances = HashMap::new();

        for id in requested_ids {
            if let Some(instance) = tree.get_instance(id) {
                instances.insert(id, Instance::from_rojo_instance(instance));

                for descendant in tree.descendants(id) {
                    instances.insert(descendant.id(), Instance::from_rojo_instance(descendant));
                }
            }
        }

        json_ok(ReadResponse {
            session_id: self.serve_session.session_id(),
            message_cursor,
            instances,
        })
    }

    /// Accepts a list of IDs and returns them serialized as a binary model.
    /// The model is sent in a schema that causes Roblox to deserialize it as
    /// a Luau `buffer`.
    ///
    /// The returned model is a folder that contains ObjectValues with names
    /// that correspond to the requested Instances. These values have their
    /// `Value` property set to point to the requested Instance.
    async fn handle_api_serialize(&self, request: Request<Body>) -> Response<Body> {
        let argument = &request.uri().path()["/api/serialize/".len()..];
        let requested_ids: Result<Vec<Ref>, _> = argument.split(',').map(Ref::from_str).collect();

        let requested_ids = match requested_ids {
            Ok(ids) => ids,
            Err(_) => {
                return json(
                    ErrorResponse::bad_request("Malformed ID list"),
                    StatusCode::BAD_REQUEST,
                );
            }
        };
        let mut response_dom = WeakDom::new(InstanceBuilder::new("Folder"));

        let tree = self.serve_session.tree();
        for id in &requested_ids {
            if let Some(instance) = tree.get_instance(*id) {
                let clone = response_dom.insert(
                    Ref::none(),
                    InstanceBuilder::new(instance.class_name())
                        .with_name(instance.name())
                        .with_properties(instance.properties().clone()),
                );
                let object_value = response_dom.insert(
                    response_dom.root_ref(),
                    InstanceBuilder::new("ObjectValue")
                        .with_name(id.to_string())
                        .with_property("Value", clone),
                );

                let mut child_ref = clone;
                if let Some(parent_class) = parent_requirements(&instance.class_name()) {
                    child_ref =
                        response_dom.insert(object_value, InstanceBuilder::new(parent_class));
                    response_dom.transfer_within(clone, child_ref);
                }

                response_dom.transfer_within(child_ref, object_value);
            } else {
                json(
                    ErrorResponse::bad_request(format!("provided id {id} is not in the tree")),
                    StatusCode::BAD_REQUEST,
                );
            }
        }
        drop(tree);

        let mut source = Vec::new();
        rbx_binary::to_writer(&mut source, &response_dom, &[response_dom.root_ref()]).unwrap();

        json_ok(SerializeResponse {
            session_id: self.serve_session.session_id(),
            model_contents: BufferEncode::new(source),
        })
    }

    /// Returns a list of all referent properties that point towards the
    /// provided IDs. Used because the plugin does not store a RojoTree,
    /// and referent properties need to be updated after the serialize
    /// endpoint is used.
    async fn handle_api_ref_patch(self, request: Request<Body>) -> Response<Body> {
        let argument = &request.uri().path()["/api/ref-patch/".len()..];
        let requested_ids: Result<HashSet<Ref>, _> =
            argument.split(',').map(Ref::from_str).collect();

        let requested_ids = match requested_ids {
            Ok(ids) => ids,
            Err(_) => {
                return json(
                    ErrorResponse::bad_request("Malformed ID list"),
                    StatusCode::BAD_REQUEST,
                );
            }
        };

        let mut instance_updates: HashMap<Ref, InstanceUpdate> = HashMap::new();

        let tree = self.serve_session.tree();
        for instance in tree.descendants(tree.get_root_id()) {
            for (prop_name, prop_value) in instance.properties() {
                let Variant::Ref(prop_value) = prop_value else {
                    continue;
                };
                if let Some(target_id) = requested_ids.get(prop_value) {
                    let instance_id = instance.id();
                    let update =
                        instance_updates
                            .entry(instance_id)
                            .or_insert_with(|| InstanceUpdate {
                                id: instance_id,
                                changed_class_name: None,
                                changed_name: None,
                                changed_metadata: None,
                                changed_properties: UstrMap::default(),
                            });
                    update
                        .changed_properties
                        .insert(*prop_name, Some(Variant::Ref(*target_id)));
                }
            }
        }

        json_ok(RefPatchResponse {
            session_id: self.serve_session.session_id(),
            patch: SubscribeMessage {
                added: HashMap::new(),
                removed: Vec::new(),
                updated: instance_updates.into_values().collect(),
            },
        })
    }

    /// Open a script with the given ID in the user's default text editor.
    async fn handle_api_open(&self, request: Request<Body>) -> Response<Body> {
        let argument = &request.uri().path()["/api/open/".len()..];
        let requested_id = match Ref::from_str(argument) {
            Ok(id) => id,
            Err(_) => {
                return json(
                    ErrorResponse::bad_request("Invalid instance ID"),
                    StatusCode::BAD_REQUEST,
                );
            }
        };

        let tree = self.serve_session.tree();

        let instance = match tree.get_instance(requested_id) {
            Some(instance) => instance,
            None => {
                return json(
                    ErrorResponse::bad_request("Instance not found"),
                    StatusCode::NOT_FOUND,
                );
            }
        };

        let script_path = match pick_script_path(instance) {
            Some(path) => path,
            None => {
                return json(
                    ErrorResponse::bad_request(
                        "No appropriate file could be found to open this script",
                    ),
                    StatusCode::NOT_FOUND,
                );
            }
        };

        match opener::open(&script_path) {
            Ok(()) => {}
            Err(error) => match error {
                OpenError::Io(io_error) => {
                    return json(
                        ErrorResponse::internal_error(format!(
                            "Attempting to open {} failed because of the following io error: {}",
                            script_path.display(),
                            io_error
                        )),
                        StatusCode::INTERNAL_SERVER_ERROR,
                    )
                }
                OpenError::ExitStatus {
                    cmd,
                    status,
                    stderr,
                } => {
                    return json(
                        ErrorResponse::internal_error(format!(
                            r#"The command '{}' to open '{}' failed with the error code '{}'.
                            Error logs:
                            {}"#,
                            cmd,
                            script_path.display(),
                            status,
                            stderr
                        )),
                        StatusCode::INTERNAL_SERVER_ERROR,
                    )
                }
            },
        };

        json_ok(OpenResponse {
            session_id: self.serve_session.session_id(),
        })
    }
}

/// If this instance is represented by a script, try to find the correct .lua or .luau
/// file to open to edit it.
fn pick_script_path(instance: InstanceWithMeta<'_>) -> Option<PathBuf> {
    match instance.class_name().as_str() {
        "Script" | "LocalScript" | "ModuleScript" => {}
        _ => return None,
    }

    // Pick the first listed relevant path that has an extension of .lua or .luau that
    // exists.
    instance
        .metadata()
        .relevant_paths
        .iter()
        .find(|path| {
            // We should only ever open Lua or Luau files to be safe.
            match path.extension().and_then(|ext| ext.to_str()) {
                Some("lua") => {}
                Some("luau") => {}
                _ => return false,
            }

            fs::metadata(path)
                .map(|meta| meta.is_file())
                .unwrap_or(false)
        })
        .map(|path| path.to_owned())
}

/// VibeStarter Sync: RAII guard that counts an active WebSocket subscription on
/// the session while held, decrementing on drop (any exit path of the loop).
struct SocketClientGuard(Arc<ServeSession>);

impl SocketClientGuard {
    fn new(serve_session: Arc<ServeSession>) -> Self {
        serve_session.socket_connected();
        SocketClientGuard(serve_session)
    }
}

impl Drop for SocketClientGuard {
    fn drop(&mut self) {
        self.0.socket_disconnected();
    }
}

/// Handle WebSocket connection for streaming subscription messages
async fn handle_websocket_subscription(
    serve_session: Arc<ServeSession>,
    websocket: HyperWebsocket,
    input_cursor: u32,
) -> anyhow::Result<()> {
    let mut websocket = websocket.await?;

    let session_id = serve_session.session_id();
    let tree_handle = serve_session.tree_handle();
    let message_queue = serve_session.message_queue();

    log::debug!(
        "WebSocket subscription established for session {}",
        session_id
    );

    // VibeStarter Sync: count this as a connected client until the loop exits.
    let _client_guard = SocketClientGuard::new(Arc::clone(&serve_session));

    // Now continuously listen for new messages using select to handle both incoming messages
    // and WebSocket control messages concurrently
    let mut cursor = input_cursor;
    loop {
        let receiver = message_queue.subscribe(cursor);

        tokio::select! {
            // Handle new messages from the message queue
            result = receiver => {
                match result {
                    Ok(Ok((new_cursor, messages))) => {
                        if !messages.is_empty() {
                            let json_message = {
                                let tree = tree_handle.lock().unwrap();
                                let api_messages: Option<Vec<_>> = messages
                                    .into_iter()
                                    .map(|patch| SubscribeMessage::from_patch_update(&tree, patch))
                                    .collect();

                                if let Some(api_messages) = api_messages {
                                    let response = SocketPacket {
                                        session_id,
                                        packet_type: SocketPacketType::Messages,
                                        body: SocketPacketBody::Messages(MessagesPacket {
                                            message_cursor: new_cursor,
                                            messages: api_messages,
                                        }),
                                    };

                                    Some(serde_json::to_string(&response)?)
                                } else {
                                    // Publish expiration before closing so the plugin's
                                    // reconnect check cannot retry this invalid window.
                                    message_queue.invalidate_history();
                                    None
                                }
                            };
                            let Some(json_message) = json_message else {
                                log::debug!("Replay references a removed addition; requesting a fresh snapshot");
                                let _ = websocket.send(Message::Close(None)).await;
                                break;
                            };

                            log::debug!("Sending batch of messages over WebSocket subscription");

                            if websocket.send(Message::Text(json_message)).await.is_err() {
                                // Client disconnected
                                log::debug!("WebSocket subscription closed by client");
                                break;
                            }
                            cursor = new_cursor;
                        }
                    }
                    Ok(Err(_)) | Err(_) => {
                        // An expired cursor requires a fresh snapshot. Closing
                        // makes the plugin recheck the replay window via /api/rojo.
                        // Message queue disconnected
                        log::debug!("Message queue disconnected; closing WebSocket subscription");
                        let _ = websocket.send(Message::Close(None)).await;
                        break;
                    }
                }
            }

            // Handle incoming WebSocket messages (ping/pong/close)
            msg = websocket.next() => {
                match msg {
                    Some(Ok(Message::Close(_))) => {
                        log::debug!("WebSocket subscription closed by client");
                        break;
                    }
                    Some(Ok(Message::Ping(data))) => {
                        // tungstenite handles pong automatically
                        log::debug!("Received ping: {:?}", data);
                    }
                    Some(Ok(Message::Pong(data))) => {
                        log::debug!("Received pong: {:?}", data);
                    }
                    Some(Ok(Message::Text(_))) | Some(Ok(Message::Binary(_))) => {
                        // Ignore text/binary messages from client for subscription endpoint
                        // TODO: Use this for bidirectional sync or requesting fallbacks?
                        log::debug!("Ignoring message from client since we don't use it for anything yet: {:?}", msg);
                    }
                    Some(Ok(Message::Frame(_))) => {
                        // This should never happen according to tungstenite docs
                        unreachable!();
                    }
                    Some(Err(e)) => {
                        log::error!("WebSocket error: {}", e);
                        break;
                    }
                    None => {
                        // WebSocket stream ended
                        log::debug!("WebSocket stream ended");
                        break;
                    }
                }
            }
        }
    }

    Ok(())
}

/// Certain Instances MUST be a child of specific classes. This function
/// tracks that information for the Serialize endpoint.
///
/// If a parent requirement exists, it will be returned.
/// Otherwise returns `None`.
fn parent_requirements(class: &str) -> Option<&str> {
    Some(match class {
        "Attachment" | "Bone" => "Part",
        "Animator" => "Humanoid",
        "BaseWrap" | "WrapLayer" | "WrapTarget" | "WrapDeformer" => "MeshPart",
        _ => return None,
    })
}

#[cfg(test)]
mod replay_tests {
    use super::*;
    use crate::snapshot::AppliedPatchSet;
    use hyper::service::{make_service_fn, service_fn};
    use hyper_tungstenite::tungstenite::{connect, stream::MaybeTlsStream};
    use std::{convert::Infallible, time::Duration};

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn expired_socket_closes_and_fresh_snapshot_cursor_can_stream() {
        let dir = tempfile::tempdir().unwrap();
        let project = dir.path().join("default.project.json");
        fs::write(
            &project,
            r#"{"name":"Replay","tree":{"$className":"Folder"}}"#,
        )
        .unwrap();
        let session = Arc::new(ServeSession::new(memofs::Vfs::new_default(), &project).unwrap());
        session
            .message_queue()
            .push_messages(&vec![AppliedPatchSet::default(); 1030]);

        let api = ApiService::new(session.clone());
        let response = api.handle_api_rojo().await;
        let info: ServerInfoResponse =
            serde_json::from_slice(&body::to_bytes(response.into_body()).await.unwrap()).unwrap();
        assert_eq!(info.oldest_message_cursor, 6);
        assert_eq!(info.message_cursor, 1030);
        assert_eq!(info.protocol_version, 6);

        let request = Request::builder()
            .uri(format!("/api/read/{}", info.root_instance_id))
            .body(Body::empty())
            .unwrap();
        let response = api.handle_api_read(request).await;
        let read: ReadResponse =
            serde_json::from_slice(&body::to_bytes(response.into_body()).await.unwrap()).unwrap();
        assert_eq!(read.message_cursor, 1030);
        assert!(read.instances.contains_key(&info.root_instance_id));

        let service_session = session.clone();
        let server =
            hyper::Server::bind(&([127, 0, 0, 1], 0).into()).serve(make_service_fn(move |_| {
                let session = service_session.clone();
                async move {
                    Ok::<_, Infallible>(service_fn(move |request| {
                        let session = session.clone();
                        async move { Ok::<_, Infallible>(call(session, request).await) }
                    }))
                }
            }));
        let address = server.local_addr();
        let (stop, stopped) = futures::channel::oneshot::channel::<()>();
        let task = tokio::spawn(server.with_graceful_shutdown(async {
            let _ = stopped.await;
        }));
        tokio::task::spawn_blocking(move || {
            let open = |cursor| {
                let (mut socket, _) =
                    connect(format!("ws://{address}/api/socket/{cursor}")).unwrap();
                if let MaybeTlsStream::Plain(tcp) = socket.get_mut() {
                    tcp.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
                }
                socket
            };
            let mut expired = open(0);
            assert!(matches!(expired.read().unwrap(), Message::Close(_)));
            let _ = expired.close(None);
            let mut retained = open(6);
            let packet: serde_json::Value =
                serde_json::from_str(retained.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(packet["body"]["messageCursor"], 1030);
            assert_eq!(packet["body"]["messages"].as_array().unwrap().len(), 1024);
            let _ = retained.close(None);
            let mut fresh = open(read.message_cursor);
            session
                .message_queue()
                .push_messages(&[AppliedPatchSet::default()]);
            let packet: serde_json::Value =
                serde_json::from_str(fresh.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(packet["body"]["messageCursor"], 1031);
            assert_eq!(packet["body"]["messages"].as_array().unwrap().len(), 1);
            let _ = fresh.close(None);

            // A short disconnection can contain an addition followed by deletion,
            // even though both patches still fit in the byte/count window.
            let before_addition = session.message_queue().cursor();
            {
                use crate::snapshot::{apply_patch_set, InstanceSnapshot, PatchAdd, PatchSet};
                let tree_handle = session.tree_handle();
                let mut tree = tree_handle.lock().unwrap();
                let addition = apply_patch_set(
                    &mut tree,
                    PatchSet {
                        added_instances: vec![PatchAdd {
                            parent_id: info.root_instance_id,
                            instance: InstanceSnapshot::new()
                                .name("Transient")
                                .class_name("Folder"),
                        }],
                        ..PatchSet::default()
                    },
                );
                let added_id = addition.added[0];
                session.message_queue().push_messages(&[addition]);
                let removal = apply_patch_set(
                    &mut tree,
                    PatchSet {
                        removed_instances: vec![added_id],
                        ..PatchSet::default()
                    },
                );
                session.message_queue().push_messages(&[removal]);
            }
            let mut deleted_addition = open(before_addition);
            assert!(matches!(
                deleted_addition.read().unwrap(),
                Message::Close(_)
            ));
            let _ = deleted_addition.close(None);
            let stats = session.message_queue().stats();
            assert_eq!(stats.current_cursor, before_addition + 2);
            assert_eq!(stats.oldest_cursor, stats.current_cursor);
            assert_eq!(stats.retained_bytes, 0);
            assert_eq!(stats.retained_messages, 0);
            // Expiration is visible to the plugin before it attempts to resume.
            let mut retry_old = open(before_addition);
            assert!(matches!(retry_old.read().unwrap(), Message::Close(_)));
            let _ = retry_old.close(None);
            // The tree lock and server remain usable after the invalid replay.
            assert!(session
                .tree_handle()
                .lock()
                .unwrap()
                .get_instance(info.root_instance_id)
                .is_some());
            let mut after_resync = open(stats.current_cursor);
            session
                .message_queue()
                .push_messages(&[AppliedPatchSet::default()]);
            let packet: serde_json::Value =
                serde_json::from_str(after_resync.read().unwrap().to_text().unwrap()).unwrap();
            assert_eq!(packet["body"]["messageCursor"], stats.current_cursor + 1);
            let _ = after_resync.close(None);
        })
        .await
        .unwrap();
        stop.send(()).unwrap();
        task.await.unwrap().unwrap();
    }
}
