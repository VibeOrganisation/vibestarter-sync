--[[
	Reaching the playtest's client, from the state that can.

	A playtest's **client** DataModel can never talk to VibeStarter. Measured
	2026-09-01 on Studio 0.736.0: the plugin *is* loaded there and its `plugin`
	global *is* present, but the first request out of it comes back "Http
	requests can only be executed by game server". Roblox refuses `HttpService`
	in a client DataModel, plugin security included, and Luau offers no other
	way out — no server socket, no WebSocket. So the client is not a channel
	that has not attached yet; it is one that cannot exist.

	What *does* exist is the ordinary Roblox route. The playtest's **server**
	holds the channel, and a server can reach its clients. So this module makes
	the server carry the client's half:

	    app ──HTTP──> plugin (Server DataModel)
	                     │  RemoteEvent
	                     ▼
	                  agent (LocalScript in PlayerGui)  ── requires ──> chunk

	Two things had to be true for this to work at all, and both were measured
	on 2026-09-01 before a line of this module was written:

	  * a `LocalScript` whose `Source` this plugin writes at runtime, parented
	    into a live player's `PlayerGui`, **does run on the client**;
	  * a `ModuleScript` whose `Source` is written the same way **replicates
	    and `require`s** on the client.

	Why the compile stays on the server: the client has neither. `loadstring`
	is off there, and writing `.Source` needs plugin security, which a game
	script does not have. The server authors the chunk; the client only
	`require`s it. That asymmetry is the whole design.

	Why `Runtime` and `Query` are cloned rather than copied: formatting a
	returned value is `Runtime.describe` and reading the tree is `Query`, and a
	second copy of either living as a string inside the agent would drift the
	day one of them learns something new. Neither needs a privilege, so the
	real modules are cloned into `ReplicatedStorage` and the client requires
	*them*.

	Each call targets **one** client. A `Play` has exactly one and needs no
	argument; a multi-client test (`Start` with several players) must name one,
	because "run this somewhere" is not a question with a right answer — and
	firing all clients would run the caller's side effects once per player.

	The agent also carries the client's log without being asked: it seeds from
	`LogService:GetLogHistory()` the moment it starts, then streams every
	`MessageOut` to the server in small batches. Reading the client's console
    flushes its pending batch before reading the server buffer, preserving
    even errors emitted immediately before the read.

	Everything this module creates lives in the playtest's own DataModel, which
	is discarded at stop. It never touches the edit place, so the sync engine
	never sees a change the user did not make.
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Deadline = require(script.Parent.Deadline)
local PlayerTarget = require(script.Parent.PlayerTarget)
local ClientProxy = {}

local FOLDER_NAME = "VibeStarterClientProxy"
local AGENT_NAME = "VibeStarterClientAgent"

-- How long the server waits for a client to answer one call. `prewarm` pays
-- for the agent's installation and the modules' replication at playtest
-- start, so a call normally answers in a beat — this ceiling exists for the
-- client that died mid-call, so the tool fails instead of hanging the agent
-- that asked.
local REPLY_TIMEOUT = 15

-- How long `prewarm` keeps trying to put an agent into every present player.
-- A Play's client takes a few seconds to join and a beat more to grow a
-- PlayerGui; the loop returns the moment everyone is served, so the ceiling
-- is only ever paid by a playtest whose client never finishes loading.
local PREWARM_BUDGET = 30

-- How long a console read waits for a freshly installed agent's first log
-- batch. The agent sends one immediately on starting — even an empty one, as
-- its "I am here" — so this is replication latency, not work.
local FIRST_LOG_WAIT = 3

-- How many log lines are kept per client. Studio's own history is capped too;
-- what matters is that trimming is *said* (`dropped`), so a clean-looking log
-- can never be a trimmed one pretending.
local MAX_LOG_LINES = 2000

-- The client half. Thin on purpose: everything that needs a privilege happens
-- on the server, so this is plumbing and nothing else. `__FOLDER__` is
-- substituted below — the name must be `FOLDER_NAME`'s, and a second literal
-- of it here would break the day the constant moves.
local AGENT_SOURCE = ([==[
local HttpService = game:GetService("HttpService")
local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local folder = ReplicatedStorage:WaitForChild("__FOLDER__", 30)
if folder == nil then
	return
end
local toClient = folder:WaitForChild("ToClient", 30)
local toServer = folder:WaitForChild("ToServer", 30)
local logRemote = folder:WaitForChild("Log", 30)
local runtime = folder:WaitForChild("Runtime", 30)
local deadline = folder:WaitForChild("Deadline", 30)
if toClient == nil or toServer == nil or logRemote == nil or runtime == nil or deadline == nil then
	return
end

local Deadline = require(deadline)
local okRuntime, Runtime = pcall(require, runtime)
if not okRuntime then
	Runtime = nil
end

-- The log stream. Seeded from the history so nothing printed before this
-- agent existed is lost, then live. The first batch is sent even when empty:
-- it is how the server knows this agent is standing.
local pendingLog = {}
pcall(function()
	for _, entry in ipairs(LogService:GetLogHistory()) do
		table.insert(pendingLog, { entry.message, entry.messageType.Value })
	end
end)
local function flushLog()
    logRemote:FireServer(pendingLog)
    pendingLog = {}
end
LogService.MessageOut:Connect(function(message, messageType)
	table.insert(pendingLog, { message, messageType.Value })
end)
task.spawn(function()
	while true do
		task.wait(0.25)
		if #pendingLog > 0 then
			flushLog()
		end
	end
end)

local function respond(...)
    flushLog()
    toServer:FireServer(...)
end

toClient.OnClientEvent:Connect(function(jobId, chunk, raw, budget)

	local printed = {}
	local function capture(...)
		local parts = {}
		for index = 1, select("#", ...) do
			parts[index] = tostring((select(index, ...)))
		end
		table.insert(printed, table.concat(parts, "\t"))
	end

	local results = table.pack(Deadline.run(budget, function()
		local okFactory, factory = pcall(require, chunk)
		assert(okFactory and type(factory) == "function", "the client could not require the chunk: " .. tostring(factory))
		return factory(capture)
	end))
	if not results[1] then
		local reason = "[error] " .. tostring(results[2])
		if #printed > 0 then
			respond(jobId, false, table.concat(printed, "\n") .. "\n" .. reason)
		else
			respond(jobId, false, reason)
		end
		return
	end

	if raw then
		-- The chunk is one of this plugin's own and its first returned value
		-- is data, not prose: hand it back as JSON so the server reads a
		-- value instead of parsing a description of one.
		local okEncode, encoded = pcall(function()
			return HttpService:JSONEncode({ value = results[2] })
		end)
		if okEncode then
			respond(jobId, true, encoded)
		else
			respond(jobId, false, "the chunk's return value does not encode as JSON: " .. tostring(encoded))
		end
		return
	end

	local lines = printed
	for index = 2, results.n do
		local value = results[index]
		local shown = Runtime ~= nil and Runtime.describe(value) or tostring(value)
		table.insert(lines, "-- returned: " .. shown)
	end
	if #lines == 0 then
		respond(jobId, true, "(the code ran and produced no output)")
		return
	end
	respond(jobId, true, table.concat(lines, "\n"))
end)
-- Readiness is announced only after the call listener is installed.
flushLog()
]==]):gsub("__FOLDER__", FOLDER_NAME)

local folder = nil
local toClient = nil
local toServer = nil
local logRemote = nil
local runtimeClone = nil
local queryClone = nil
local captureClone = nil
local playersConnections = {}
-- Keep the actual scripts, not just their names: after a proxy rebuild an
-- old script is still listening to the destroyed RemoteEvents.
local playerAgents = {}
local nextJob = 0
-- jobId -> { player, signal, answer }. An entry exists exactly while a call
-- waits; anything arriving for a jobId that is not here is late or duplicated
-- and is dropped, so an answer after the timeout cannot accumulate anywhere.
local pendingJobs = {}
-- player -> { lines = { {message, severity} }, dropped = n }. Fed by the
-- agents' streams, trimmed at MAX_LOG_LINES, cleared when the player leaves.
local clientLogs = {}

--[[
	Wrap the caller's source exactly as `Runtime` does.

	Same one-line wrapper, so a syntax error is reported one line lower than the
	caller wrote it — and so a script behaves the same whichever DataModel it is
	sent to. Kept next to the agent it feeds rather than exported from
	`Runtime`: the two must agree, and here that is visible.
]]
local function wrap(source)
	return "return function(print)\n" .. source .. "\nend"
end

local function installAgent(player)
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if gui == nil then
		return false
	end
	local existing = playerAgents[player]
	if existing ~= nil and existing.Parent == gui then
		return true
	end
	if existing ~= nil then
		existing:Destroy()
	end
	local agent = Instance.new("LocalScript")
	agent.Name = AGENT_NAME
	local ok = pcall(function()
		agent.Source = AGENT_SOURCE
	end)
	if not ok then
		agent:Destroy()
		return false
	end
	-- A replacement must announce its own readiness. Reusing the old log
	-- would send work before the new listener exists and duplicate history.
	clientLogs[player] = nil
	playerAgents[player] = agent
	agent.Parent = gui
	return true
end

--[[
	Install once the player can hold an agent.

	`PlayerAdded` fires before the PlayerGui exists, so the immediate install
	would fail and nothing would retry until the next call's `ensure`. Waiting
	here is what makes a late joiner served without anyone asking.
]]
local function installAgentWhenReady(player)
	task.spawn(function()
		if player:FindFirstChildOfClass("PlayerGui") == nil then
			player:WaitForChild("PlayerGui", 30)
		end
		installAgent(player)
	end)
end

--[[
	Put the proxy in place, or say how many clients hold an agent.

	Idempotent: called before every client-bound call, because a playtest can
	gain a player after the first one and an agent must be waiting in each.
	Rebuilt whole if the game's own code destroyed any piece of it — and the
	old player connections are dropped first, so a rebuild cannot stack a
	second `PlayerAdded` handler on the first.
]]
local runtimeToolsClone = nil
local deadlineClone = nil
local function ensure(runtimeModule, queryModule)
	local standing = folder ~= nil
		and folder.Parent == ReplicatedStorage
		and toClient ~= nil
		and toClient.Parent == folder
		and toServer ~= nil
		and toServer.Parent == folder
		and logRemote ~= nil
		and logRemote.Parent == folder
		and runtimeClone ~= nil
		and runtimeClone.Parent == folder
		and queryClone ~= nil
		and queryClone.Parent == folder
		and captureClone ~= nil
		and captureClone.Parent == folder
		and runtimeToolsClone ~= nil
		and runtimeToolsClone.Parent == folder
		and deadlineClone ~= nil
		and deadlineClone.Parent == folder
	if not standing then
		for _, connection in ipairs(playersConnections) do
			connection:Disconnect()
		end
		playersConnections = {}
		for player, agent in pairs(playerAgents) do
			agent:Destroy()
			clientLogs[player] = nil
		end
		playerAgents = {}
		if folder ~= nil then
			folder:Destroy()
		end

		folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME

		toClient = Instance.new("RemoteEvent")
		toClient.Name = "ToClient"
		toClient.Parent = folder

		toServer = Instance.new("RemoteEvent")
		toServer.Name = "ToServer"
		toServer.Parent = folder

		logRemote = Instance.new("RemoteEvent")
		logRemote.Name = "Log"
		logRemote.Parent = folder

		-- The real modules, not transcriptions of them. See the header.
		runtimeClone = runtimeModule:Clone()
		runtimeClone.Name = "Runtime"
		runtimeClone.Parent = folder
		queryClone = queryModule:Clone()
		queryClone.Name = "Query"
		queryClone.Parent = folder
		captureClone = script.Parent.CaptureView:Clone()
		captureClone.Name = "CaptureView"
		captureClone.Parent = folder
		runtimeToolsClone = script.Parent.RuntimeTools:Clone()
		runtimeToolsClone.Name = "RuntimeTools"
		runtimeToolsClone.Parent = folder
		deadlineClone = script.Parent.Deadline:Clone()
		deadlineClone.Name = "Deadline"
		deadlineClone.Parent = folder

		toServer.OnServerEvent:Connect(function(player, jobId, ok, text)
			local pending = pendingJobs[jobId]
			if pending == nil or pending.answer ~= nil then
				-- Late, duplicated, or spoofed by a game script: the call it
				-- would answer is not waiting, so there is nothing to keep.
				return
			end
			if pending.player ~= player then
				-- Only the client that was asked may answer.
				return
			end
			pending.answer = { ok = ok == true, text = tostring(text) }
			pending.signal:Fire()
		end)

		logRemote.OnServerEvent:Connect(function(player, batch)
			if type(batch) ~= "table" then
				return
			end
			local log = clientLogs[player]
			if log == nil then
				log = { lines = {}, dropped = 0 }
				clientLogs[player] = log
			end
			for _, entry in ipairs(batch) do
				if type(entry) == "table" and type(entry[1]) == "string" then
					table.insert(log.lines, { message = entry[1], severity = tonumber(entry[2]) })
				end
			end
			local excess = #log.lines - MAX_LOG_LINES
			if excess > 0 then
				log.lines = table.move(log.lines, excess + 1, #log.lines, 1, {})
				log.dropped += excess
			end
		end)

		folder.Parent = ReplicatedStorage

		table.insert(playersConnections, Players.PlayerAdded:Connect(installAgentWhenReady))
		table.insert(
			playersConnections,
			Players.PlayerRemoving:Connect(function(player)
				clientLogs[player] = nil
				playerAgents[player] = nil
			end)
		)
	end

	local installedFor = 0
	for _, player in ipairs(Players:GetPlayers()) do
		if installAgent(player) then
			installedFor += 1
		end
	end
	return installedFor
end

--[[
	The one client this call is about.

	One player is the ordinary case and needs no argument. More than one and no
	name is the case where guessing would run the caller's code on the wrong
	client — or on several — so it refuses and lists them, exactly as
	`character_navigation` does for characters.

	Returns `player` or `nil, why, incapacity`.
]]
local function chooseClient(playerName)
	local players = Players:GetPlayers()
	if #players == 0 then
		return nil,
			"No player has joined this playtest yet, so there is no client to reach. Note that Run "
				.. "starts a server alone: use Play, which gives a client and a character.",
			true
	end
	if type(playerName) == "string" and playerName ~= "" then
		local player, why = PlayerTarget.resolve(players, playerName)
		return player, why, false
	end
	if #players == 1 then
		return players[1]
	end
	local names = {}
	for _, player in ipairs(players) do
		table.insert(names, player.Name)
	end
	return nil,
		("%d players are in this playtest and this call did not say which client: %s. Name one with `player`."):format(
			#players,
			table.concat(names, ", ")
		),
		false
end

--[[
	The server-side state checks every entry point shares.

	Returns `nil` when the proxy can work here, or `why, incapacity` when it
	cannot — worded for the agent, because the gateway hands it straight over.
]]
local function cannotProxyHere()
	if not RunService:IsRunning() or not RunService:IsServer() then
		return "The client proxy only exists in a playtest's Server DataModel; this state is not it.", true
	end
	return nil
end

--[[
	Send one chunk to one client and wait for its answer.

	Returns `{ ok, text }` or `nil, why, incapacity`. The wait is a signal,
	not a poll: the answer (or the deadline) fires it, so a fast client costs
	no tick and a dead one costs exactly `REPLY_TIMEOUT`.
]]
local function callClient(player, source, raw)
	local readyBy = os.clock() + FIRST_LOG_WAIT
	while clientLogs[player] == nil and os.clock() < readyBy do
		task.wait(0.05)
	end
	if clientLogs[player] == nil then
		return nil, player.Name .. "'s client agent has not finished loading yet.", true
	end
	nextJob += 1
	local jobId = nextJob
	local chunk = Instance.new("ModuleScript")
	chunk.Name = "VibeStarterClientChunk" .. tostring(jobId)
	local sourceOk, sourceError = pcall(function()
		chunk.Source = wrap(source)
	end)
	if not sourceOk then
		chunk:Destroy()
		return nil, "Could not write the client chunk's source: " .. tostring(sourceError), true
	end
	chunk.Parent = folder

	local pending = { player = player, signal = Instance.new("BindableEvent"), answer = nil }
	pendingJobs[jobId] = pending
	-- Cleanup belongs to the watchdog too: Deadline may cancel the waiter
	-- before this client's reply, so code after Event:Wait is not guaranteed.
	local cleaned = false
	local function cleanup()
		if cleaned then
			return
		end
		cleaned = true
		pendingJobs[jobId] = nil
		pending.signal:Destroy()
		chunk:Destroy()
	end
	local replyTimeout = math.min(REPLY_TIMEOUT, Deadline.remaining() or REPLY_TIMEOUT)
	local expired = false
	local timer = task.delay(replyTimeout, function()
		expired = true
		if pending.answer == nil then
			pending.signal:Fire()
		end
		cleanup()
	end)
	local sent, failure = pcall(function()
		-- Leave time for the client's timeout response to cross the remote.
		toClient:FireClient(player, jobId, chunk, raw == true, math.max(0.001, replyTimeout - 1))
		if pending.answer == nil then
			pending.signal.Event:Wait()
		end
	end)
	local answer = pending.answer
	cleanup()
	if not expired and coroutine.status(timer) ~= "dead" then
		task.cancel(timer)
	end
	if not sent then
		return nil, "Could not reach the client: " .. tostring(failure), true
	end

	if answer == nil then
		return nil,
			(
				"%s's client did not answer within %.1fs. Its agent may not have loaded yet, or the "
				.. "code it was given never returned."
			):format(player.Name, replyTimeout),
			true
	end
	return answer
end

--[[
	Everything `run`, `call` and `consoleLog` do before their own work: check
	the state, pick the client, stand the proxy up, and make sure the chosen
	client holds an agent.

	Returns `player` or `nil, why, incapacity`.
]]
local function readyClient(runtimeModule, queryModule, playerName)
	local why, incapacity = cannotProxyHere()
	if why ~= nil then
		return nil, why, incapacity
	end
	local player, whyNot, cannot = chooseClient(playerName)
	if player == nil then
		return nil, whyNot, cannot
	end
	ensure(runtimeModule, queryModule)
	if not installAgent(player) then
		return nil,
			(
				"%s has no PlayerGui to install the client agent into yet. Give the player a moment to "
				.. "finish loading and retry."
			):format(player.Name),
			true
	end
	return player
end

--[[
	Run `source` in one client of the playtest, and return what it said.

	Returns `ok, text` like every handler, and a third value that is true when
	the failure is an incapacity rather than a fault in the caller's code — the
	gateway shows those to the agent as `Unsupported`.
]]
function ClientProxy.run(source, runtimeModule, queryModule, playerName)
	if type(source) ~= "string" or source == "" then
		return false, "Running code in the Client DataModel needs a `code` string."
	end
	local player, why, incapacity = readyClient(runtimeModule, queryModule, playerName)
	if player == nil then
		return false, why, incapacity
	end
	local answer, failure, cannot = callClient(player, source, false)
	if answer == nil then
		return false, failure, cannot
	end
	return answer.ok, answer.text
end

--[[
	Run one of this plugin's own chunks in a client and return its first
	returned value as data.

	For the handlers that read the client's tree rather than run the caller's
	code: the chunk returns a table, the agent JSON-encodes it, and this
	decodes it — so the handler formats a value instead of parsing prose.

	Returns `value` or `nil, why, incapacity`. A chunk that failed in the
	client comes back as `nil` with the client's own reason.
]]
function ClientProxy.call(source, runtimeModule, queryModule, playerName)
	local player, why, incapacity = readyClient(runtimeModule, queryModule, playerName)
	if player == nil then
		return nil, why, incapacity
	end
	local answer, failure, cannot = callClient(player, source, true)
	if answer == nil then
		return nil, failure, cannot
	end
	if not answer.ok then
		return nil, answer.text, false
	end
	local decodedOk, decoded = pcall(function()
		return HttpService:JSONDecode(answer.text)
	end)
	if not decodedOk or type(decoded) ~= "table" then
		return nil, "the client's answer could not be decoded: " .. tostring(answer.text), false
	end
	if type(decoded.value) ~= "table" then
		-- The contract with the handlers' own chunks: the payload is a table,
		-- so a caller can read fields without checking the shape first.
		return nil, "the client's chunk did not return a table", false
	end
	return decoded.value
end

--[[
	The client's log, from the buffer its agent streams into.

	The stream contains the history and live lines. A small client call flushes
    its pending batch before this read, so stopping immediately afterwards
    cannot discard the final quarter-second of errors. Readiness is announced
    only once the client's request listener is installed.

	Returns `log` (`{ lines, dropped }`) or `nil, why, incapacity`.
]]
function ClientProxy.consoleLog(runtimeModule, queryModule, playerName)
	local player, why, incapacity = readyClient(runtimeModule, queryModule, playerName)
	if player == nil then
		return nil, why, incapacity
	end
	local answer, failure, cannot = callClient(player, "return true", false)
	if answer == nil then
		return nil, failure, cannot
	end
	if not answer.ok then
		return nil, answer.text, false
	end
	local log = clientLogs[player]
	if log == nil then
		return nil,
			("%s's client agent has not sent its log yet. Give the client a moment to finish loading " .. "and retry."):format(
				player.Name
			),
			true
	end
	return log
end

--[[
	Pay the proxy's installation at playtest start instead of on first use.

	Called from `Tools.start` when this state is a playtest's server. Without
	it the first client-bound call also pays for the folder, the module
	replication and the agent's `WaitForChild`s — seconds, all inside
	`REPLY_TIMEOUT`'s budget. The loop returns the moment every present player
	holds an agent; late joiners are `PlayerAdded`'s job.

	Never throws and never blocks the caller: `Tools.start` must survive
	anything this does.
]]
function ClientProxy.prewarm(runtimeModule, queryModule)
	if cannotProxyHere() ~= nil then
		return
	end
	task.spawn(function()
		local deadline = os.clock() + PREWARM_BUDGET
		while os.clock() < deadline do
			local served = 0
			local ok, reached = pcall(ensure, runtimeModule, queryModule)
			if ok then
				served = reached
			end
			local players = #Players:GetPlayers()
			if players > 0 and served >= players then
				return
			end
			task.wait(0.5)
		end
	end)
end

-- Readiness is observed, not inferred from a delay or server attachment.
-- Called by the app before confirming a native Play start.
function ClientProxy.readiness(runtimeModule, queryModule)
	ensure(runtimeModule, queryModule)
	local players = Players:GetPlayers()
	local ready = 0
	local names = {}
	for _, player in ipairs(players) do
		table.insert(names, player.Name)
		if installAgent(player) and clientLogs[player] ~= nil then
			ready += 1
		end
	end
	table.sort(names)
	return { ready = #players > 0 and ready == #players, players = #players, clientsReady = ready, playerNames = names }
end

-- Exported for the handlers that write chunks requiring the cloned modules:
-- the chunk must name the folder, and a second literal would drift.
ClientProxy.FOLDER_NAME = FOLDER_NAME

return ClientProxy
