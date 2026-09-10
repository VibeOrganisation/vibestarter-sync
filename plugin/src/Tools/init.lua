--[[
	The sovereign Studio channel, Studio's half.

	VibeStarter's app holds a loopback port and this module dials it, pulls tool
	calls off it, runs them here, and posts the answers back. That is the whole
	channel. The app deposits the plugin itself; there is no user-managed
	setting or external process in its lifecycle, and its catalogue is compiled
	with the app.

	# Why polling

	Because Luau has nothing else. A plugin can make outbound HTTP requests and
	that is the entire surface: no server socket, no WebSocket. So each poll is
	held open by the app for up to ~25 s and returns early the moment there is
	work, which costs a handful of requests a minute while idle and adds one
	round trip to a call. The Sync fork's own message channel has worked this
	way in production here for months.

	# Why scanning for the port

	The app cannot tell this module where it is. There is no environment, no
	filesystem, and no argument — a plugin only knocks. So the app takes the
	first free port in a small fixed range and this module walks the same range
	until something answers with the channel's own marker. A foreign HTTP
	server on the first port is skipped rather than mistaken for the app, which
	is what the marker is for.
]]

local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Rojo = script:FindFirstAncestor("Rojo")
local Log = require(Rojo.Packages.Log)

local Config = require(script.Parent.Config)
local Handlers = require(script.Handlers)
local Deadline = require(script.Deadline)

local Tools = {}

-- Must match `PROTOCOL_VERSION` in `src-tauri/src/mcp/studio_plugin/wire.rs`.
-- A user can be left with an older `.rbxm` from a previous install, and Studio
-- loads it without asking anyone; the app refuses a mismatch rather than
-- letting a half-understood job run against a real place.
local PROTOCOL_VERSION = 1
local CHANNEL_MAGIC = "vibestarter-studio-tools"

-- Must match `PORT_RANGE` in `host.rs`.
local FIRST_PORT = 34873
local LAST_PORT = 34877

-- A poll the app answered immediately with no work should not be repeated
-- immediately: the app normally holds each one for ~25 s, so a fast empty
-- answer means something is wrong with that assumption, and spinning on it
-- would turn one idle Studio into a busy loop against the app's port. This is
-- a floor, not a cadence — a poll that waited properly sleeps for none of it.
local MIN_POLL_INTERVAL = 1

-- Backoff between attempts to find the app, in seconds.
--
-- Studio left open with no VibeStarter running is an ordinary state that can
-- last hours, and a scan is five requests, not one. The same lesson the sync
-- reconnect learned the hard way (`App/init.lua`: "a closed VibeStarter app
-- meant one failed request every two seconds for the entire Studio session")
-- applies here five times over. So: fast while it might come back, then quiet.
local RETRY_MIN = 2
local RETRY_MAX = 30

-- How long to pause after a poll dies on the transport, before scanning for the
-- app again. The app closing mid-poll is the ordinary cause, and it is followed
-- by a five-port scan, so going straight back round would put that scan in the
-- same instant the app is shutting down or restarting.
--
-- Declared above the loop that reads it on purpose: a local read before its
-- declaration is a global read of nil in Luau, and `task.wait(nil)` yields one
-- frame — which is how this pause once silently did not happen.
local RECONNECT_DELAY = 2

local function url(port, path)
	return ("http://127.0.0.1:%d/vibestarter/studio%s"):format(port, path)
end

-- Why the last request could not even be made, as `RequestAsync` worded it.
-- Kept for one line: the channel is how this plugin reports anything, so when
-- it is the channel that cannot start, the only place left to say why is
-- Studio's own Output — see the announcement in `Tools.start`.
local lastTransportError = nil

--[[
	One request, with everything that can go wrong flattened into `ok, body,
	status`. `RequestAsync` throws on a transport failure and returns a table on
	an HTTP error, and the loop below needs to tell those apart from success
	without a pcall at every call site.
]]
local function request(params)
	local ok, response = pcall(function()
		return HttpService:RequestAsync(params)
	end)
	if not ok then
		lastTransportError = tostring(response)
		return false, tostring(response), nil
	end
	local body = nil
	if response.Body ~= nil and response.Body ~= "" then
		-- A body that is not JSON is not a fault to report: it is what a
		-- foreign server on a scanned port answers with, and the caller
		-- already treats a missing body as "not us".
		local decodedOk, decoded = pcall(function()
			return HttpService:JSONDecode(response.Body)
		end)
		if decodedOk then
			body = decoded
		end
	end
	return response.Success, body, response.StatusCode
end

-- The port the app was last found on. Tried first on every later scan: the app
-- keeps its port for its whole run, so after the first success a reconnect is
-- one request instead of five.
local knownPort = nil

local function knock(port)
	local ok, body = request({
		Url = url(port, "/hello"),
		Method = "GET",
	})
	if not ok or type(body) ~= "table" or body.channel ~= CHANNEL_MAGIC then
		return false
	end
	if body.protocolVersion ~= PROTOCOL_VERSION then
		-- A plugin left behind by an older install. Saying which two numbers
		-- disagree is what makes this one line instead of a support ticket
		-- about tools that "just stopped working".
		Log.warn(
			"VibeStarter's Studio channel speaks protocol {}, this plugin speaks {}. Reinstall the plugin from the app.",
			tostring(body.protocolVersion),
			tostring(PROTOCOL_VERSION)
		)
		return false
	end
	return true
end

--[[
	Find the app's port, or nil.

	Deliberately silent when nothing answers: Studio is very often open with no
	VibeStarter running, and that is not a fault worth a line every few seconds
	for a whole session.
]]
local function discover()
	if knownPort ~= nil and knock(knownPort) then
		return knownPort
	end
	for port = FIRST_PORT, LAST_PORT do
		if port ~= knownPort and knock(port) then
			knownPort = port
			return port
		end
	end
	return nil
end

--[[
	The project this place is bound to, read from the marker the app stamps.

	It is the only identity an unpublished place has, and it is what lets the
	app route a call to the right window without asking Roblox anything. Read
	through pcall because a place with no marker is an ordinary case — someone
	opened a place that is not a VibeStarter project — not an error.
]]
--[[
	`game.CreatorId` / `game.CreatorType`, guarded.

	Both are readable on an unpublished draft, where they are 0 and `None`. That
	is not a failure and must not read as one: an unsaved place genuinely has no
	owner yet, and the app's identity cache already treats a zero creator as
	"nothing to cache".
]]
local function creatorId()
	local ok, value = pcall(function()
		return game.CreatorId
	end)
	return ok and value or 0
end

local function creatorType()
	local ok, value = pcall(function()
		return game.CreatorType and game.CreatorType.Name or ""
	end)
	return ok and value or ""
end

--[[
	Does this place already hold code?

	Only asked when there is no marker, which is the only time anything reads
	it: it words the app's question when it offers to bind an unbound place
	("this looks like a fresh baseplate" versus "this place already has
	content"). A bound place skips the scan entirely, so the cost falls on
	fresh baseplates, where `GetDescendants` is a handful of instances.

	Same test as the app's own Luau (`PLACE_SNAPSHOT_LUAU`): the first
	`LuaSourceContainer` wins and the scan stops. Identical on purpose -- a
	place must not read as populated to one path and empty to the other.
]]
local function isPopulated()
	local ok, populated = pcall(function()
		for _, descendant in ipairs(game:GetDescendants()) do
			if descendant:IsA("LuaSourceContainer") then
				return true
			end
		end
		return false
	end)
	return ok and populated or false
end

--[[
	`ServerStorage`, or nil where there is no such thing.

	Fetched here, guarded, and only for the marker read — never at load time.
	A `GetService` that throws at the top of this file would take the whole
	module down inside the `pcall` of `init.server.lua`, silently. (This was
	once suspected of keeping a playtest's client state from attaching; the
	real cause was measured on 2026-09-01 — Roblox refuses `HttpService` in a
	client DataModel, see `docs/studio-surface-outils-independante.md` — and
	the client no longer dials at all. The guard stays because it is right.)

	A state without `ServerStorage` has no marker to read either, which is the
	same answer as a place that was never stamped.
]]
local function serverStorage()
	local ok, service = pcall(game.GetService, game, "ServerStorage")
	return ok and service or nil
end

local function projectId()
	local storage = serverStorage()
	if storage == nil then
		return nil
	end
	local marker = storage:FindFirstChild("VibeStarter")
	if marker == nil then
		return nil
	end
	local ok, id = pcall(function()
		return marker:GetAttribute("Id")
	end)
	if ok and type(id) == "string" and id ~= "" then
		return id
	end
	return nil
end

local function versionString()
	local version = Config.version
	return ("%d.%d.%d"):format(version[1], version[2], version[3])
end

--[[
	Which DataModel this Lua state is, named the way upstream names it.

	`RunService` is the only thing that can answer, and it answers by
	elimination: an edit session is not running, and a running one is either
	the playtest's server or its client. Studio never gives a plugin a state
	that is neither.
]]
local function dataModelType()
	if not RunService:IsRunning() then
		return "Edit"
	end
	return RunService:IsServer() and "Server" or "Client"
end

local function attach(port, nonce)
	-- Read once: `populated` is only meaningful without a marker, and only
	-- worth its `GetDescendants` scan then.
	local marker = projectId()
	local ok, body, status = request({
		Url = url(port, "/attach"),
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = HttpService:JSONEncode({
			protocolVersion = PROTOCOL_VERSION,
			pluginVersion = versionString(),
			placeId = game.PlaceId,
			gameId = game.GameId,
			placeName = game.Name,
			projectId = marker,
			-- Who owns the experience. Stable for the life of a place, so it
			-- belongs here rather than in a round trip: with it, binding a
			-- place to a project needs only the marker write.
			creatorId = creatorId(),
			creatorType = creatorType(),
			-- Only meaningful without a marker, and only computed then.
			populated = marker == nil and isPopulated() or false,
			isEdit = not RunService:IsRunning(),
			-- Which DataModel this is, in upstream's own words ("Edit",
			-- "Server", "Client") so that `execute_luau`'s `datamodel_type`
			-- can be answered without translating anything.
			--
			-- `isEdit` alone stopped being enough the day this channel started
			-- attaching from playtests: a playtest opens TWO Lua states, and
			-- both would have said `isEdit = false` and been
			-- indistinguishable. A caller that asked for the server and got
			-- the client would not see a failure, it would see a wrong answer.
			dataModelType = dataModelType(),
			sessionNonce = nonce,
		}),
	})
	if not ok then
		if status ~= nil then
			Log.warn(
				"VibeStarter's Studio channel refused this plugin (HTTP {}): {}",
				tostring(status),
				type(body) == "table" and tostring(body.error) or "no reason given"
			)
		end
		return nil
	end
	-- A 200 whose body is missing the two fields every later request needs is
	-- not a session. Treating it as one would make each poll a 400 forever.
	if type(body) ~= "table" or type(body.sessionId) ~= "string" or type(body.token) ~= "string" then
		return nil
	end
	return body
end

--[[
	Run one job and post its answer back.

	Every failure path ends in a posted result. A job the app is blocked on
	that silently produces nothing costs the caller its whole ceiling — two
	minutes, five for an asset — for something we already know the outcome of.
]]
-- `JSONEncode` as a value: the encoded text, or nil and Studio's reason.
local function encodeResult(payload)
	local ok, encoded = pcall(function()
		return HttpService:JSONEncode(payload)
	end)
	if ok then
		return encoded, nil
	end
	return nil, encoded
end

local function serve(port, session, job, context)
	local handler = Handlers[job.tool]
	-- `unsupported` means "this Studio session cannot do this", as opposed to
	-- "this call failed". The gateway returns that incapacity directly to the
	-- agent, so it must never be set for an ordinary failure.
	local ok, text, unsupported, mechanism
	if handler == nil then
		ok, text, unsupported =
			false,
			("The VibeStarter Studio plugin has no handler for '%s'. This is a VibeStarter bug: the app routed a tool here that this plugin does not implement."):format(
				tostring(job.tool)
			),
			-- This is a capability mismatch, not an ordinary tool failure.
			true
	else
		-- `first`/`second` because pcall's second return means two different
		-- things: the handler's own `ok` when it ran, the error message when
		-- it threw.
		-- `fourth` is optional and only the compiling tools set it: which
		-- mechanism compiled the source. The app logs it, because "the plugin
		-- served it" without "how" is what had to be asked back by hand on
		-- 2026-08-23.
		-- Reserve time to post the failure and resume polling before the host
		-- expires its request. A timed-out handler must not own this loop forever.
		local budget = type(job.deadlineMs) == "number" and job.deadlineMs / 1000 or 120
		budget = math.max(0.001, budget - math.min(5, budget * 0.1))
		local ran, first, second, third, fourth = Deadline.run(budget, handler, job.arguments or {}, context)
		if ran then
			ok, text, unsupported, mechanism = first, second, third == true, fourth
		else
			-- The handler itself threw. Reporting it as the tool's failure,
			-- with the message, is the difference between an agent that can
			-- work around it and one that retries the same call forever.
			ok, text = false, "The VibeStarter Studio plugin failed while running this tool: " .. tostring(first)
		end
	end

	local payload = { jobId = job.jobId, ok = ok }
	if type(mechanism) == "string" then
		payload.mechanism = mechanism
	end
	if ok then
		payload.result = { content = { { type = "text", text = tostring(text) } } }
	else
		payload.error = tostring(text)
		payload.unsupported = unsupported == true
	end
	-- Encoded under pcall, and that guard is load-bearing. `JSONEncode`
	-- throws "Can't convert to JSON" on a string that is not valid UTF-8, and
	-- a handler can hand one back without knowing: `http_get` did on
	-- 2026-09-02, with a 200 KB page cut at 64 KB (most likely inside a
	-- multi-byte character). Thrown here, the error escaped `serve`, killed the channel's
	-- coroutine, and Studio stayed open but mute — every later call timed out
	-- and the app read a Studio it could not see as closed. So an answer that
	-- cannot be encoded becomes an error the agent reads, and the channel
	-- stays up.
	local encoded, encodeError = encodeResult(payload)
	if encoded == nil then
		encoded = HttpService:JSONEncode({
			jobId = job.jobId,
			ok = false,
			unsupported = false,
			error = (
				"The VibeStarter Studio plugin ran %s but could not encode its answer as JSON (%s). "
				.. "The answer most likely holds bytes that are not valid UTF-8 text; ask for a smaller or text-only result."
			):format(tostring(job.tool), tostring(encodeError)),
		})
	end
	request({
		Url = url(port, ("/result?session=%s&token=%s"):format(session.sessionId, session.token)),
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = encoded,
	})
end

--[[
	Start the channel. Runs for the life of the plugin and never throws: a
	failure here must not be able to take the sync plugin down with it.
]]
function Tools.start(plugin)
	-- A folder inside the plugin's own tree, not the DataModel: generated
	-- chunks are compiled here, and the DataModel is a place this plugin
	-- *synchronises* — creating instances there would feed the diff engine
	-- changes the user never made.
	local scratch = Instance.new("Folder")
	scratch.Name = "VibeStarterToolScratch"
	scratch.Parent = script

	-- A playtest's **client** state stops here, and that is the design rather
	-- than a limitation being worked around.
	--
	-- It cannot dial out at all: Roblox refuses `HttpService` in a client
	-- DataModel, plugin security included (measured 2026-09-01, Studio
	-- 0.736.0). Running the loop anyway would knock five ports every two
	-- seconds for the whole playtest, be refused every time, and say so in the
	-- user's Output — noise about a state that is not supposed to dial.
	--
	-- It does not need to: client work is carried by the playtest's **server**,
	-- which has both HTTP and plugin security. See `ClientProxy.lua`.
	if RunService:IsRunning() and not RunService:IsServer() then
		return
	end

	-- A playtest's **server**, on the other hand, pays the client proxy's
	-- installation now rather than on first use: the folder, the module
	-- clones and each player's agent take seconds to replicate, and paying
	-- them inside the first client-bound call's reply budget is what made
	-- that call slow. See `ClientProxy.prewarm`.
	if RunService:IsRunning() and RunService:IsServer() then
		require(script.ClientProxy).prewarm(script.Runtime, script.Query)
	end

	local context = { scratchParent = scratch }
	local nonce = HttpService:GenerateGUID(false)
	local running = true

	-- The port and session of the attachment currently held, or nil. Kept out
	-- here for one reason: so that `Unloading` below can say goodbye.
	local live = nil

	--[[
		Say goodbye, best effort.

		Studio unloads this plugin when the place is closed, when the plugin is
		reloaded, and when Studio itself quits — and the app cannot see any of
		those. Its own way of finding out is to release the parked poll and see
		whether anyone takes it back up, which costs a few seconds; one HTTP
		call from here, when there is still a Lua state to make it from, costs
		nothing and is immediate.

		Best effort is the whole contract, and the app is built for it: the
		request is fired inline rather than spawned, because a `task.spawn` on
		a DataModel that is being torn down may simply never run — but nothing
		waits for it, and if the state dies first the app falls back to the
		measurement it would have made anyway.
	]]
	plugin.Unloading:Connect(function()
		running = false
		local session = live
		live = nil
		if session == nil then
			return
		end
		request({
			Url = url(session.port, ("/detach?session=%s&token=%s"):format(session.sessionId, session.token)),
			Method = "POST",
			-- The app reads the session out of the query and ignores the body;
			-- it is here because `RequestAsync` wants one on a POST.
			Headers = { ["Content-Type"] = "application/json" },
			Body = "{}",
		})
	end)

	-- Said at most once per Lua state, and only in a playtest.
	--
	-- An Edit state that finds nothing is the ordinary case — Studio open with
	-- no VibeStarter running — and the whole scan is deliberately silent about
	-- it. A **playtest** state is different: the app is plainly running (it is
	-- what the agent called `start_stop_play` through), so failing to reach it
	-- from here is a real fault worth a line.
	--
	-- Only the server can reach this branch now — the client returns above —
	-- so this line no longer reports the expected, it reports a playtest whose
	-- server cannot be driven. `warn`, because a plugin's `warn` reaches
	-- Studio's Output and `print` from our own `execute_luau` does not.
	local announced = false
	local function announceIfPlaytest(what)
		if announced or not RunService:IsRunning() then
			return
		end
		announced = true
		warn(
			("VibeStarter's Studio tool channel could not reach the app from this playtest's %s DataModel: %s. "):format(
				dataModelType(),
				what
			) .. "The app is running (it started this playtest), so this state is the one that cannot dial out."
		)
	end

	task.spawn(function()
		local retry = RETRY_MIN
		while running do
			local port = discover()
			local session = port ~= nil and attach(port, nonce) or nil
			if session == nil then
				announceIfPlaytest(
					port == nil and ("no VibeStarter answered on ports %d-%d (%s)"):format(
						FIRST_PORT,
						LAST_PORT,
						lastTransportError ~= nil and lastTransportError or "no transport error"
					) or "the app refused this plugin's attach"
				)
				task.wait(retry)
				retry = math.min(retry * 2, RETRY_MAX)
				continue
			end
			retry = RETRY_MIN
			Log.info("Connected to VibeStarter's Studio channel on port {}", tostring(port))
			live = { port = port, sessionId = session.sessionId, token = session.token }
			local pollUrl = url(port, ("/poll?session=%s&token=%s"):format(session.sessionId, session.token))
			while running do
				local startedAt = os.clock()
				local ok, body, status = request({
					Url = pollUrl,
					Method = "GET",
				})
				if not ok then
					-- This session is over either way, so there is nothing
					-- left to say goodbye to: a 410 means the app has already
					-- forgotten it, and a transport failure means the app is
					-- not reachable to be told.
					live = nil
					if status == 410 then
						-- The app restarted, or this session was reaped.
						-- Attaching again is the whole recovery, and it costs
						-- one round trip.
						break
					end
					-- Transport failure: the app closed, or the machine went
					-- to sleep mid-poll. Rediscover rather than hammer a port
					-- that may no longer be ours.
					task.wait(RECONNECT_DELAY)
					break
				end
				local jobs = type(body) == "table" and body.jobs or nil
				if type(jobs) == "table" and #jobs > 0 then
					for _, job in ipairs(jobs) do
						-- Serially, on purpose. Two tool calls interleaved
						-- inside one place would let an agent observe a tree
						-- half-written by another, and the app's per-place
						-- lease exists precisely to prevent that.
						-- Nothing in `serve` is meant to throw; this is the
						-- line that keeps the channel alive the day something
						-- does anyway. A coroutine that dies here is silent
						-- until Studio restarts, and that silence reads as a
						-- closed Studio from the app's side.
						local served, why = pcall(serve, port, session, job, context)
						if not served then
							Log.warn(
								"VibeStarter Studio channel: serving {} threw and was not answered: {}",
								tostring(job.tool),
								tostring(why)
							)
						end
					end
				elseif os.clock() - startedAt < MIN_POLL_INTERVAL then
					-- The app is supposed to hold an idle poll open, so this
					-- branch means it did not. Sleeping the difference keeps a
					-- wrong assumption from becoming a busy loop against its
					-- port; a poll that waited properly never reaches it.
					task.wait(MIN_POLL_INTERVAL)
				end
			end
		end
	end)
end

return Tools
