use std::{collections::VecDeque, io, sync::Mutex};

use futures::channel::oneshot;
use serde::{Deserialize, Serialize};

const MAX_HISTORY_BYTES: u64 = 64 * 1024 * 1024;
const MAX_HISTORY_MESSAGES: usize = 1024;

pub type Subscription<T> = Result<(u32, Vec<T>), CursorExpired>;

#[derive(Debug, Clone, Copy)]
pub struct CursorExpired;

#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryStats {
    pub oldest_cursor: u32,
    pub current_cursor: u32,
    pub retained_messages: usize,
    pub retained_bytes: u64,
    pub max_bytes: u64,
}

/// A bounded replay window. A cursor outside the window must trigger a full
/// snapshot, never a partial replay that silently misses edits.
/// One lock makes checking a cursor and registering its listener atomic.
pub struct MessageQueue<T> {
    state: Mutex<State<T>>,
    max_bytes: u64,
    max_messages: usize,
}

struct State<T> {
    messages: VecDeque<(T, u64)>,
    listeners: Vec<Listener<T>>,
    cursor: u32,
    bytes: u64,
}

impl<T: Clone + Serialize> Default for MessageQueue<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T: Clone + Serialize> MessageQueue<T> {
    pub fn new() -> Self {
        Self::with_limits(MAX_HISTORY_BYTES, MAX_HISTORY_MESSAGES)
    }

    fn with_limits(max_bytes: u64, max_messages: usize) -> Self {
        Self {
            state: Mutex::new(State {
                messages: VecDeque::new(),
                listeners: Vec::new(),
                cursor: 0,
                bytes: 0,
            }),
            max_bytes,
            max_messages,
        }
    }

    pub fn push_messages(&self, new_messages: &[T]) {
        let mut state = self.state.lock().unwrap();
        for message in new_messages {
            // Counting serialization writes no output buffer. Include a floor
            // for collection/object overhead and bound entry count separately.
            // An unmeasurable or oversized patch expires the replay window;
            // clients then read the current tree instead of retaining it here.
            let bytes = message_size(message, self.max_bytes).saturating_add(1024);
            state.cursor = state
                .cursor
                .checked_add(1)
                .expect("message cursor overflow");
            if bytes > self.max_bytes {
                state.messages.clear();
                state.bytes = 0;
            } else {
                while !state.messages.is_empty()
                    && (state.bytes + bytes > self.max_bytes
                        || state.messages.len() >= self.max_messages)
                {
                    let (_, removed_bytes) = state.messages.pop_front().unwrap();
                    state.bytes -= removed_bytes;
                }
                if self.max_messages > 0 {
                    state.messages.push_back((message.clone(), bytes));
                    state.bytes += bytes;
                }
            }
        }
        let listeners = std::mem::take(&mut state.listeners);
        for listener in listeners {
            if let Some(listener) = state.fire(listener) {
                state.listeners.push(listener);
            }
        }
    }

    /// Expire replay when a retained patch can no longer be reconstructed.
    /// Current subscribers stay live; older cursors must read a fresh snapshot.
    pub fn invalidate_history(&self) {
        let mut state = self.state.lock().unwrap();
        state.messages.clear();
        state.bytes = 0;
        let listeners = std::mem::take(&mut state.listeners);
        for listener in listeners {
            if let Some(listener) = state.fire(listener) {
                state.listeners.push(listener);
            }
        }
    }

    pub fn subscribe(&self, cursor: u32) -> oneshot::Receiver<Subscription<T>> {
        let (sender, receiver) = oneshot::channel();
        let mut state = self.state.lock().unwrap();
        // A closed socket drops its receiver even when no edits arrive.
        state
            .listeners
            .retain(|listener| !listener.sender.is_canceled());
        if let Some(listener) = state.fire(Listener { sender, cursor }) {
            state.listeners.push(listener);
        }
        receiver
    }

    #[cfg(test)]
    #[allow(unused)]
    pub fn subscribe_any(&self) -> oneshot::Receiver<Subscription<T>> {
        self.subscribe(self.cursor())
    }

    pub fn cursor(&self) -> u32 {
        self.state.lock().unwrap().cursor
    }

    pub fn stats(&self) -> HistoryStats {
        let state = self.state.lock().unwrap();
        HistoryStats {
            oldest_cursor: state.oldest_cursor(),
            current_cursor: state.cursor,
            retained_messages: state.messages.len(),
            retained_bytes: state.bytes,
            max_bytes: self.max_bytes,
        }
    }
}

// Some project metadata uses serde flattening (unknown-length maps), which
// bincode cannot size. Count JSON writes as a fallback without keeping JSON.
// Stop at the budget so even a huge fallback value cannot grow a scratch buffer.
fn message_size<T: Serialize>(message: &T, max_bytes: u64) -> u64 {
    bincode::serialized_size(message).unwrap_or_else(|_| {
        struct Counter {
            bytes: u64,
            max: u64,
        }
        impl io::Write for Counter {
            fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
                self.bytes = self.bytes.saturating_add(buf.len() as u64);
                if self.bytes > self.max {
                    return Err(io::Error::other("history budget exceeded"));
                }
                Ok(buf.len())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let mut counter = Counter {
            bytes: 0,
            max: max_bytes,
        };
        match serde_json::to_writer(&mut counter, message) {
            Ok(()) => counter.bytes,
            Err(_) => u64::MAX,
        }
    })
}

impl<T: Clone> State<T> {
    fn oldest_cursor(&self) -> u32 {
        self.cursor - self.messages.len() as u32
    }

    fn fire(&self, listener: Listener<T>) -> Option<Listener<T>> {
        if listener.sender.is_canceled() {
            return None;
        }
        if listener.cursor < self.oldest_cursor() || listener.cursor > self.cursor {
            let _ = listener.sender.send(Err(CursorExpired));
        } else if listener.cursor < self.cursor {
            let messages = self
                .messages
                .iter()
                .skip((listener.cursor - self.oldest_cursor()) as usize)
                .map(|(message, _)| message.clone())
                .collect();
            let _ = listener.sender.send(Ok((self.cursor, messages)));
        } else {
            return Some(listener);
        }
        None
    }
}

struct Listener<T> {
    sender: oneshot::Sender<Subscription<T>>,
    cursor: u32,
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::executor::block_on;

    #[test]
    fn invalidating_history_expires_old_cursors_and_keeps_current_listeners() {
        let queue = MessageQueue::new();
        queue.push_messages(&["old"]);
        let current_listener = queue.subscribe(1);
        queue.invalidate_history();
        assert!(block_on(queue.subscribe(0)).unwrap().is_err());
        assert_eq!(queue.stats().retained_bytes, 0);
        queue.push_messages(&["new"]);
        assert_eq!(
            block_on(current_listener).unwrap().unwrap(),
            (2, vec!["new"])
        );
    }

    #[test]
    fn history_is_bounded_by_bytes_even_without_clients() {
        let queue = MessageQueue::with_limits(12 * 1024, 1024);
        for _ in 0..1000 {
            queue.push_messages(&["x".repeat(4096)]);
        }
        let stats = queue.stats();
        assert_eq!(stats.current_cursor, 1000);
        assert_eq!(stats.retained_messages, 2);
        assert!(stats.retained_bytes <= stats.max_bytes);
        assert!(block_on(queue.subscribe(0)).unwrap().is_err());
        let (cursor, messages) = block_on(queue.subscribe(998)).unwrap().unwrap();
        assert_eq!(cursor, 1000);
        assert_eq!(messages.len(), 2);
    }

    #[test]
    fn flattened_project_metadata_remains_replayable() {
        #[derive(Clone, Serialize)]
        struct Metadata {
            #[serde(flatten)]
            properties: std::collections::BTreeMap<String, String>,
        }
        let message = Metadata {
            properties: [("name".into(), "project".into())].into(),
        };
        assert!(bincode::serialized_size(&message).is_err());
        let queue = MessageQueue::new();
        queue.push_messages(&[message]);
        let (_, messages) = block_on(queue.subscribe(0)).unwrap().unwrap();
        assert_eq!(messages[0].properties["name"], "project");
    }

    #[test]
    fn source_edit_history_drops_old_patch_payloads() {
        use crate::snapshot::{AppliedPatchSet, AppliedPatchUpdate};
        use rbx_dom_weak::types::{Ref, Variant};
        let queue = MessageQueue::with_limits(1024 * 1024, 1024);
        let id = Ref::new();
        for index in 0..1000 {
            let mut update = AppliedPatchUpdate::new(id);
            update.changed_properties.insert(
                "Source".into(),
                Some(Variant::String(format!(
                    "-- {index}\n{}",
                    "x".repeat(64 * 1024)
                ))),
            );
            queue.push_messages(&[AppliedPatchSet {
                updated: vec![update],
                ..Default::default()
            }]);
        }
        let stats = queue.stats();
        assert!(
            stats.retained_messages > 0,
            "real patches must remain serializable"
        );
        assert!(stats.retained_messages < 16);
        assert!(stats.retained_bytes <= 1024 * 1024);
        let (_, patches) = block_on(queue.subscribe(999)).unwrap().unwrap();
        let source = patches[0].updated[0]
            .changed_properties
            .get(&"Source".into())
            .unwrap();
        assert!(matches!(source, Some(Variant::String(text)) if text.starts_with("-- 999\n")));
    }

    #[test]
    fn count_limit_preserves_absolute_cursors_and_exact_boundary() {
        let queue = MessageQueue::with_limits(64 * 1024, 2);
        queue.push_messages(&[10, 20, 30]);
        assert!(block_on(queue.subscribe(0)).unwrap().is_err());
        assert_eq!(
            block_on(queue.subscribe(1)).unwrap().unwrap(),
            (3, vec![20, 30])
        );
        assert_eq!(
            block_on(queue.subscribe(2)).unwrap().unwrap(),
            (3, vec![30])
        );
        assert!(block_on(queue.subscribe(4)).unwrap().is_err());
        let receiver = queue.subscribe(3);
        queue.push_messages(&[40]);
        assert_eq!(block_on(receiver).unwrap().unwrap(), (4, vec![40]));
    }

    #[test]
    fn oversized_patch_releases_history_and_wakes_clients_for_resync() {
        let queue = MessageQueue::with_limits(4096, 100);
        queue.push_messages(&[String::from("before")]);
        let receiver = queue.subscribe(1);
        queue.push_messages(&["x".repeat(8192)]);
        assert!(block_on(receiver).unwrap().is_err());
        assert_eq!(queue.stats().retained_bytes, 0);
        assert_eq!(queue.stats().oldest_cursor, 2);
        queue.push_messages(&[String::from("after")]);
        assert_eq!(
            block_on(queue.subscribe(2)).unwrap().unwrap(),
            (3, vec![String::from("after")])
        );
        assert!(block_on(queue.subscribe(1)).unwrap().is_err());
    }

    #[test]
    fn canceled_idle_subscriptions_do_not_accumulate() {
        let queue = MessageQueue::<u32>::new();
        for _ in 0..1000 {
            drop(queue.subscribe(0));
        }
        assert_eq!(queue.state.lock().unwrap().listeners.len(), 1);
        queue.push_messages(&[1]);
        assert!(queue.state.lock().unwrap().listeners.is_empty());
    }

    #[test]
    fn concurrent_subscribe_and_push_never_lose_the_wakeup() {
        use std::sync::{Arc, Barrier};
        let queue = Arc::new(MessageQueue::new());
        for cursor in 0..100 {
            let barrier = Arc::new(Barrier::new(2));
            let other_queue = queue.clone();
            let other_barrier = barrier.clone();
            let reader = std::thread::spawn(move || {
                other_barrier.wait();
                other_queue.subscribe(cursor)
            });
            barrier.wait();
            queue.push_messages(&[cursor]);
            let mut receiver = reader.join().unwrap();
            assert_eq!(
                receiver.try_recv().unwrap().unwrap().unwrap(),
                (cursor + 1, vec![cursor])
            );
        }
    }
}
