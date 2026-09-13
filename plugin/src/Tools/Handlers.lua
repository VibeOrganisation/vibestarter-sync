--[[
	The tools this plugin answers, on public Roblox API only.

	Each one implements a name from VibeStarter's agent-facing Studio contract.
	Ordinary tools return text. Internal native handlers return structured
	state or pixel payloads for the app's playtest and capture orchestration.

	Every handler returns `ok, text`. `text` is what the agent reads in both
	cases, so a failure is a sentence with a next step in it rather than a
	stack trace.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local HttpService = game:GetService("HttpService")
local InsertService = game:GetService("InsertService")
local LogService = game:GetService("LogService")
local RunService = game:GetService("RunService")

local Rojo = script:FindFirstAncestor("Rojo")

local Runtime = require(script.Parent.Runtime)
-- Reading the tree, shared with the playtest's client: `ClientProxy` clones it
-- over there, so both states answer with the same code. See its header.
local Query = require(script.Parent.Query)
-- Reaching the playtest's client, from the state that can. The client DataModel
-- has no HTTP of its own and never will; see `ClientProxy.lua`.
local ClientProxy = require(script.Parent.ClientProxy)
local PlayerTarget = require(script.Parent.PlayerTarget)

--[[
	Which DataModel this Lua state is, in the vocabulary the app routes with.
]]
local function actualDataModel()
	if not RunService:IsRunning() then
		return "Edit"
	end
	return RunService:IsServer() and "Server" or "Client"
end

--[[
	Is this call one the playtest's server answers *on behalf of* its client?

	The client cannot hold a channel of its own — Roblox refuses `HttpService`
	there — so "run it in the Client" is served by the Server state through
	`ClientProxy`, not by a client session that will never attach. Anything
	else stays a topology error, and still says so.
]]
local function proxiesToClient(wanted)
	return wanted == "Client" and RunService:IsRunning() and RunService:IsServer()
end

--[[
	The topology guard every DataModel-routed tool shares.

	One plugin session is one DataModel. A named target that is not this state
	means the topology changed between routing and execution; naming both
	sides lets the agent wait for the requested session to attach and retry
	safely. Returns the sentence, or nil when the call belongs here.
]]
local function datamodelMismatch(wanted)
	if type(wanted) ~= "string" or wanted == "" then
		return nil
	end
	local actual = actualDataModel()
	if wanted == actual then
		return nil
	end
	return ("This VibeStarter plugin session is attached to the %s DataModel, but the call targets %s. Open that DataModel, wait for VibeStarter's plugin to attach there, then retry."):format(
		actual,
		wanted
	)
end
-- The one thing `Tools/` and `App/` share. Cheap and standalone on purpose: it
-- is required in playtest DataModels too, where nothing else of the app half is
-- loaded. See `SyncEndpoint.lua`.
local SyncEndpoint = require(Rojo.Plugin.SyncEndpoint)
-- The reflection database this plugin already ships to sync properties. Using
-- it here means `inspect_instance` shows the same property set the sync engine
-- understands, rather than a second, hand-kept list that would drift from it.
--
-- Required on first use, and that is not a micro-optimisation. `database.json`
-- is 2.1 MB, and this module is now loaded in playtest DataModels too — two
-- more times per playtest, 78 in the session that produced
-- `docs/diagnostic-plugin-watchdog-studio-2026-08-10.md`. Compiling 2.1 MB
-- that often is the exact shape of cost that watchdog fires on, and
-- `inspect_instance` is the only consumer: the cost belongs to the call that
-- needs it, not to attaching.
local reflectionDatabase = nil
local function database()
	if reflectionDatabase == nil then
		reflectionDatabase = require(Rojo.Packages.RbxDom.database)
	end
	return reflectionDatabase
end

local Handlers = {}

-- How many instances a tree search may return before it stops. A search that
-- matched ten thousand parts is a search the agent should narrow, and handing
-- it all of them costs its context without telling it anything more.
local DEFAULT_SEARCH_LIMIT = 100
local MAX_SEARCH_LIMIT = 1000

-- Dotted-path resolution lives in `Query`, beside the inspection and search it
-- feeds, because the client answers those with the same module. Aliased here:
-- every handler that names an instance goes through it.
local resolve = Query.resolve

--[[
	The properties of `className` worth showing, from the reflection database
	this plugin already ships for syncing.

	Filtered to canonical, readable, non-hidden, non-deprecated: reading the
	rest produces either duplicates under an old name or values Roblox itself
	does not expose to scripts, and both crowd out the ones that matter.
]]
local propertiesCache = {}
local function readableProperties(className)
	if propertiesCache[className] then
		return propertiesCache[className]
	end
	local names = {}
	local seen = {}
	local current = className
	while current ~= nil do
		local class = database().Classes[current]
		if class == nil then
			break
		end
		for name, property in pairs(class.Properties) do
			local canonical = property.Kind ~= nil and property.Kind.Canonical ~= nil
			local readable = property.Scriptability == "Read" or property.Scriptability == "ReadWrite"
			if canonical and readable and not seen[name] then
				local hidden = false
				for _, tag in ipairs(property.Tags or {}) do
					if tag == "Hidden" or tag == "Deprecated" or tag == "NotScriptable" then
						hidden = true
						break
					end
				end
				if not hidden then
					seen[name] = true
					table.insert(names, name)
				end
			end
		end
		current = class.Superclass
	end
	table.sort(names)
	propertiesCache[className] = names
	return names
end

--[[
	`inspect_instance`, in the playtest's client.

	Two chunks through the proxy, because the reflection database naming a
	class's readable properties is 2.1 MB and lives on this side: the first
	learns the ClassName from the client, the names are looked up here, and
	the second reads the values with the same `Query.inspect` the local path
	uses — through the cloned modules, so the answer is this plugin's own code
	running over there.
]]
local function clientInspect(arguments)
	local path = arguments.path
	if type(path) ~= "string" or path == "" then
		return false,
			"inspect_instance could not resolve that path: expected a dotted path such as 'Workspace.Baseplate'"
	end
	local probe = ([[
local Query = require(game:GetService("ReplicatedStorage"):WaitForChild(%q):WaitForChild("Query"))
local instance, failure = Query.resolve(%q)
if instance == nil then
	return { failure = failure }
end
return { className = instance.ClassName }
]]):format(ClientProxy.FOLDER_NAME, path)
	local found, why, incapacity = ClientProxy.call(probe, script.Parent.Runtime, script.Parent.Query, arguments.player)
	if found == nil then
		return false, why, incapacity
	end
	if found.failure ~= nil then
		return false, "inspect_instance could not resolve that path in the client: " .. tostring(found.failure)
	end

	local quoted = {}
	for _, name in ipairs(readableProperties(tostring(found.className))) do
		table.insert(quoted, ("%q"):format(name))
	end
	local read = ([[
local proxy = game:GetService("ReplicatedStorage"):WaitForChild(%q)
local Query = require(proxy:WaitForChild("Query"))
local Runtime = require(proxy:WaitForChild("Runtime"))
local instance, failure = Query.resolve(%q)
if instance == nil then
	return { failure = failure }
end
return { lines = Query.inspect(instance, { %s }, Runtime.describe) }
]]):format(ClientProxy.FOLDER_NAME, path, table.concat(quoted, ", "))
	local answer, readWhy, readIncapacity =
		ClientProxy.call(read, script.Parent.Runtime, script.Parent.Query, arguments.player)
	if answer == nil then
		return false, readWhy, readIncapacity
	end
	if answer.failure ~= nil then
		-- Present a moment ago, gone now: the client's world moves under us.
		return false, "inspect_instance could not resolve that path in the client: " .. tostring(answer.failure)
	end
	if type(answer.lines) ~= "table" then
		return false, "inspect_instance got an unreadable answer from the client."
	end
	return true, table.concat(answer.lines, "\n")
end

local function structuredQuery(operation, arguments)
	if arguments.properties then
		assert(type(arguments.properties) == "table" and #arguments.properties <= 50, "At most 50 properties")
	end
	local propertiesByClass = {}
	local function clientCall(method, extra)
		local code = ("local Query=require(game:GetService('ReplicatedStorage'):WaitForChild(%q,5).Query);local h=game:GetService('HttpService');return Query[%q](h:JSONDecode(%q),h:JSONDecode(%q))"):format(
			ClientProxy.FOLDER_NAME,
			method,
			HttpService:JSONEncode(arguments),
			HttpService:JSONEncode(extra or {})
		)
		local answer, why = ClientProxy.call(code, script.Parent.Runtime, script.Parent.Query, arguments.player)
		assert(answer ~= nil, why)
		return answer
	end
	local client = proxiesToClient(arguments.datamodel_type)
	if not client then
		local mismatch = datamodelMismatch(arguments.datamodel_type)
		assert(not mismatch, mismatch)
	end
	if operation == "inspectStructured" and not arguments.properties then
		local classes = client and clientCall("classNames") or Query.classNames(arguments)
		for name in pairs(classes) do
			propertiesByClass[name] = readableProperties(name)
		end
	end
	local result = client and clientCall(operation, propertiesByClass) or Query[operation](arguments, propertiesByClass)
	return true, { content = { { type = "text", text = HttpService:JSONEncode(result) } }, structuredContent = result }
end

function Handlers.inspect_instance(arguments)
	if arguments.format ~= "text" or arguments.paths or arguments.properties or type(arguments.path) == "table" then
		return structuredQuery("inspectStructured", arguments)
	end
	if proxiesToClient(arguments.datamodel_type) then
		return clientInspect(arguments)
	end
	local mismatch = datamodelMismatch(arguments.datamodel_type)
	if mismatch ~= nil then
		return false, mismatch, true
	end
	local instance, failure = resolve(arguments.path)
	if instance == nil then
		return false, "inspect_instance could not resolve that path: " .. failure
	end
	local lines = Query.inspect(instance, readableProperties(instance.ClassName), Runtime.describe)
	return true, table.concat(lines, "\n")
end

--[[
	Why `class_name` is checked before anything is searched.

	`IsA` answers false for a class that does not exist, silently, so
	`basepart` walked a whole place and reported "No instance matched" — a
	typo reading as an empty subtree (deep test of 2026-09-02). The reflection
	database this plugin ships names every class, so an unknown one is refused
	here, and the one that differs only by case is offered back: class names
	are case-sensitive and that is the usual slip.
]]
local function unknownClassName(className)
	local classes = database().Classes
	if classes[className] ~= nil then
		return nil
	end
	local lowered = string.lower(className)
	for name in pairs(classes) do
		if string.lower(name) == lowered then
			return ("search_game_tree: '%s' is not a Roblox class name — class names are case-sensitive; did you mean '%s'?"):format(
				className,
				name
			)
		end
	end
	return ("search_game_tree: '%s' is not a Roblox class name known to this plugin's reflection database, so nothing could ever match it. Check the spelling ('BasePart', 'Model', 'Script', …)."):format(
		className
	)
end

function Handlers.search_game_tree(arguments)
	if arguments.class_name then
		local reason = unknownClassName(arguments.class_name)
		assert(not reason, reason)
	end
	if arguments.format ~= "text" or arguments.tags or arguments.attributes or arguments.properties then
		return structuredQuery("searchStructured", arguments)
	end
	local query = arguments.query
	local needle = type(query) == "string" and query ~= "" and string.lower(query) or nil
	local className = type(arguments.class_name) == "string" and arguments.class_name ~= "" and arguments.class_name
		or nil
	if needle == nil and className == nil then
		return false,
			"search_game_tree needs at least one of `query` (a name substring) or `class_name`. Searching for everything would return the whole place."
	end
	local limit = tonumber(arguments.limit) or DEFAULT_SEARCH_LIMIT
	limit = math.clamp(math.floor(limit), 1, MAX_SEARCH_LIMIT)

	if proxiesToClient(arguments.datamodel_type) then
		-- One chunk: unlike inspection, a search needs nothing from the
		-- reflection database, so the whole answer is worded over there by
		-- the same `Query.searchReport` the local path uses.
		local rootPath = type(arguments.root) == "string" and arguments.root or ""
		local source = ([[
local Query = require(game:GetService("ReplicatedStorage"):WaitForChild(%q):WaitForChild("Query"))
local root = game
local rootPath = %q
if rootPath ~= "" then
	local resolved, failure = Query.resolve(rootPath)
	if resolved == nil then
		return { failure = failure }
	end
	root = resolved
end
return { report = Query.searchReport(root, %s, %s, %d) }
]]):format(
			ClientProxy.FOLDER_NAME,
			rootPath,
			needle ~= nil and ("%q"):format(needle) or "nil",
			className ~= nil and ("%q"):format(className) or "nil",
			limit
		)
		local answer, why, incapacity =
			ClientProxy.call(source, script.Parent.Runtime, script.Parent.Query, arguments.player)
		if answer == nil then
			return false, why, incapacity
		end
		if answer.failure ~= nil then
			return false, "search_game_tree could not resolve `root` in the client: " .. tostring(answer.failure)
		end
		if type(answer.report) ~= "string" then
			return false, "search_game_tree got an unreadable answer from the client."
		end
		return true, answer.report
	end

	local mismatch = datamodelMismatch(arguments.datamodel_type)
	if mismatch ~= nil then
		return false, mismatch, true
	end
	local root = game
	if type(arguments.root) == "string" and arguments.root ~= "" then
		local resolved, failure = resolve(arguments.root)
		if resolved == nil then
			return false, "search_game_tree could not resolve `root`: " .. failure
		end
		root = resolved
	end
	return true, Query.searchReport(root, needle, className, limit)
end

-- Studio's own severities, mapped to the prefixes the app's console scanner
-- reads. It keys on the words "error" and "warn", so tagging each line is what
-- turns a guess about severity into a fact Studio told us.
local SEVERITY = {
	[Enum.MessageType.MessageOutput] = "[info] ",
	[Enum.MessageType.MessageInfo] = "[info] ",
	[Enum.MessageType.MessageWarning] = "[warn] ",
	[Enum.MessageType.MessageError] = "[error] ",
}

--[[
	The client's log, from the proxy's buffer.

	The client agent streams its history and live output. consoleLog flushes
    its pending batch before we read, so an immediate Stop loses no final errors. The severity prefixes are mapped from `SEVERITY` rather
	than written a second time: the app's console scanner keys on those exact
	words, and two tables would drift the day Studio adds a severity.
]]
local function clientConsole(arguments, limit)
	local log, why, incapacity = ClientProxy.consoleLog(script.Parent.Runtime, script.Parent.Query, arguments.player)
	if log == nil then
		return false, why, incapacity
	end
	local prefixes = {}
	for messageType, prefix in pairs(SEVERITY) do
		prefixes[messageType.Value] = prefix
	end
	local entries = log.lines
	local from = 1
	if limit ~= nil and limit > 0 and #entries > limit then
		from = #entries - math.floor(limit) + 1
	end
	local lines = {}
	if log.dropped > 0 and from == 1 then
		-- Only when the trim would otherwise be invisible: a `limit` already
		-- asked for a tail.
		table.insert(lines, ("(the %d oldest lines no longer fit the client's log buffer)"):format(log.dropped))
	end
	for index = from, #entries do
		local entry = entries[index]
		table.insert(lines, (prefixes[entry.severity] or "") .. entry.message)
	end
	if #lines == 0 then
		return true, "The client's output log is empty for this session."
	end
	return true, table.concat(lines, "\n")
end

function Handlers.get_console_output(arguments)
	local limit = tonumber(arguments.limit)
	if proxiesToClient(arguments.datamodel_type) then
		return clientConsole(arguments, limit)
	end
	local mismatch = datamodelMismatch(arguments.datamodel_type)
	if mismatch ~= nil then
		return false, mismatch, true
	end
	local ok, history = pcall(LogService.GetLogHistory, LogService)
	if not ok then
		return false, "Could not read the Studio output log: " .. tostring(history)
	end
	local from = 1
	if limit ~= nil and limit > 0 and #history > limit then
		from = #history - math.floor(limit) + 1
	end
	local lines = {}
	for index = from, #history do
		local entry = history[index]
		table.insert(lines, (SEVERITY[entry.messageType] or "") .. entry.message)
	end
	if #lines == 0 then
		return true, "The Studio output log is empty for this session."
	end
	return true, table.concat(lines, "\n")
end

--[[
	Bind this place to a VibeStarter project: create or update
	`ServerStorage.VibeStarter` and set its `Id` / `Git` attributes, then read
	the place's identity back.

	**Not an agent tool.** Binding a place is something the app does on the
	user's behalf, so this name is absent from the contract table and from the
	catalogue agents see. It is reached by window id, not by place -- because
	the place being stamped is often one that `resolve` cannot name: an
	unpublished draft has `PlaceId == 0` and, by definition, no marker yet.

	Idempotent: a `Configuration` named `VibeStarter` carries the two attributes
	that form the place's discovery marker. The identity comes back in the same
	reply because the plugin is already in the DataModel.
]]
function Handlers.stamp_project_marker(arguments)
	local id = arguments.id
	if type(id) ~= "string" or id == "" then
		return false, "stamp_project_marker needs a non-empty `id`."
	end
	-- A project with no git remote stamps an empty string. `nil` would delete
	-- the attribute and make a re-read
	-- report "no marker" for a place that has one.
	local git = arguments.git
	if type(git) ~= "string" then
		git = ""
	end

	local ok, err = pcall(function()
		local storage = game:GetService("ServerStorage")
		local marker = storage:FindFirstChild("VibeStarter")
		if marker == nil then
			marker = Instance.new("Configuration")
			marker.Name = "VibeStarter"
			marker.Parent = storage
		end
		marker:SetAttribute("Id", id)
		marker:SetAttribute("Git", git)
	end)
	if not ok then
		return false, "could not write the project marker: " .. tostring(err)
	end

	-- The same tagged shape the app's own reads already parse, so both paths
	-- land in one parser. `%.0f` because Luau numbers are doubles and `%d`
	-- would render a large PlaceId in exponent form.
	local creatorId = 0
	local creatorType = ""
	pcall(function()
		creatorId = game.CreatorId
		creatorType = tostring(game.CreatorType and game.CreatorType.Name or "")
	end)
	return true,
		table.concat({
			"VBID:" .. id,
			"VBGIT:" .. git,
			"VBNAME:" .. tostring(game.Name),
			"VBUNIV:" .. string.format("%.0f", game.GameId),
			"VBPLACE:" .. string.format("%.0f", game.PlaceId),
			"VBCREATOR:" .. string.format("%.0f", creatorId),
			"VBCREATORTYPE:" .. creatorType,
		}, "|")
end

--[[
	Tell this window which VibeStarter Sync server to dial.

	**Not an agent tool.** Like `stamp_project_marker` this name is absent from
	the contract table and from the catalogue agents see: VibeStarter can hold
	several projects open at once, each with its own `rojo serve` on its own
	host port, and pointing a window at one of them is the app routing its own
	plumbing. An agent that could call it could point a colleague's Studio at
	another project's server.

	`projectId` is what the app believes this place is bound to. It is recorded
	rather than checked here, because the check belongs where the place marker
	is read — the app half ignores an endpoint pushed for another project
	(`App:useSyncEndpoint`).

	Succeeds with nothing subscribed. A **playtest** DataModel runs this channel
	and has no app half at all; remembering the endpoint is the whole job.
]]
function Handlers.set_sync_endpoint(arguments)
	local host = arguments.host
	if type(host) ~= "string" or host == "" then
		return false, "set_sync_endpoint needs a non-empty `host`."
	end

	local port = arguments.port
	if type(port) == "string" then
		port = tonumber(port)
	end
	if type(port) ~= "number" or port ~= math.floor(port) or port < 1 or port > 65535 then
		return false, "set_sync_endpoint needs a `port` between 1 and 65535."
	end

	local projectId = arguments.projectId
	if projectId ~= nil and (type(projectId) ~= "string" or projectId == "") then
		return false, "set_sync_endpoint's `projectId` must be a non-empty string when it is given."
	end

	local endpoint = ("%s:%d"):format(host, port)
	if SyncEndpoint.set(host, string.format("%d", port), projectId) then
		return true, "This Studio window will sync with " .. endpoint .. "."
	end
	return true, "This Studio window was already syncing with " .. endpoint .. "."
end

local function runtimeOperation(operation, arguments)
	local result
	if proxiesToClient(arguments.datamodel_type) then
		local code = ("local folder=game:GetService('ReplicatedStorage'):WaitForChild(%q, 5); assert(folder, 'Client relay missing'); return require(folder.RuntimeTools)[%q](game:GetService('HttpService'):JSONDecode(%q))"):format(
			ClientProxy.FOLDER_NAME,
			operation,
			HttpService:JSONEncode(arguments)
		)
		local answer, why = ClientProxy.call(code, script.Parent.Runtime, script.Parent.Query, arguments.player)
		if answer == nil then
			return false, why
		end
		result = answer
	else
		local mismatch = datamodelMismatch(arguments.datamodel_type)
		if mismatch then
			return false, mismatch
		end
		result = require(script.Parent.RuntimeTools)[operation](arguments)
	end
	return true, { content = { { type = "text", text = HttpService:JSONEncode(result) } }, structuredContent = result }
end

function Handlers.player_input(arguments)
	arguments.datamodel_type = "Client"
	return runtimeOperation("player_input", arguments)
end
function Handlers.performance_check(arguments)
	arguments.datamodel_type = arguments.datamodel_type or "Client"
	return runtimeOperation("performance_check", arguments)
end
function Handlers.__runtime_condition(arguments)
	return runtimeOperation("condition", arguments)
end

function Handlers.execute_luau(arguments, context)
	if proxiesToClient(arguments.datamodel_type) then
		return ClientProxy.run(arguments.code, script.Parent.Runtime, script.Parent.Query, arguments.player)
	end
	local mismatch = datamodelMismatch(arguments.datamodel_type)
	if mismatch ~= nil then
		return false, mismatch, true
	end
	return Runtime.run(arguments.code, context.scratchParent)
end

--[[
	Fetch a URL from inside Studio.

	Sovereign because this plugin's own existence proves the capability: every
	poll of the channel is an `HttpService` request out of this same process.
	Plugins are not gated on `HttpService.HttpEnabled` — that property governs
	game scripts at runtime — so unlike the rest of the surface there is no
	per-place setting standing behind this one either.

	# Canonical argument and tolerated aliases

	The sovereign schema publishes `url` (`studio_plugin/tools.rs`). Older
	transcripts and hand-written calls may still use a common alias, so the
	handler accepts those spellings without publishing them. A shape it does
	not recognise is `unsupported`: the gateway returns that reason directly to
	the agent because no other backend can serve the call.
]]
local URL_KEYS = { "url", "uri", "href", "address", "link" }

-- Enough to read a JSON API or a page's markup, small enough not to spend an
-- agent's whole context on one fetch. Truncation is always said out loud:
-- a silently cut body reads as a complete one, and an agent that concludes a
-- field is absent because it was cut has been actively misled.
local MAX_BODY_BYTES = 64 * 1024

local function requestedUrl(arguments)
	for _, key in ipairs(URL_KEYS) do
		local value = arguments[key]
		if type(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end

--[[
	`Content-Type`, whatever case the server sent it in.

	Roblox lowercases response header names today; relying on that would make
	this read as "no content type" the day it stops, and a body of unknown type
	is worth saying out loud.
]]
local function contentType(headers)
	if type(headers) ~= "table" then
		return nil
	end
	for name, value in pairs(headers) do
		if type(name) == "string" and string.lower(name) == "content-type" then
			return tostring(value)
		end
	end
	return nil
end

function Handlers.http_get(arguments)
	local target = requestedUrl(arguments)
	if target == nil then
		return false,
			"The VibeStarter Studio plugin could not find a URL in this http_get call. It looks for `url`.",
			true
	end
	if not string.match(target, "^https?://") then
		-- The agent's own mistake, not an incapacity of this Studio session.
		return false, ("http_get needs an http:// or https:// URL; got '%s'."):format(target)
	end

	local headers = nil
	if type(arguments.headers) == "table" then
		headers = {}
		for name, value in pairs(arguments.headers) do
			-- Only string/string pairs: `RequestAsync` throws on anything else,
			-- and a throw here would be reported as the tool failing rather
			-- than as the one header that was wrong.
			if type(name) == "string" and (type(value) == "string" or type(value) == "number") then
				headers[name] = tostring(value)
			end
		end
	end

	local ok, response = pcall(function()
		return HttpService:RequestAsync({
			Url = target,
			Method = "GET",
			Headers = headers,
		})
	end)
	if not ok then
		-- Transport, DNS, TLS, or one of Roblox's own refusals — requests to
		-- Roblox domains are blocked engine-side and land here. The message is
		-- the whole diagnosis, so it is passed through rather than summarised.
		return false, ("http_get could not reach %s: %s"):format(target, tostring(response))
	end

	local body = type(response.Body) == "string" and response.Body or ""
	local truncated = false
	if #body > MAX_BODY_BYTES then
		body = string.sub(body, 1, MAX_BODY_BYTES)
		truncated = true
	end

	-- Only valid UTF-8 can travel back: `JSONEncode` refuses anything else,
	-- and the cut above can land inside a multi-byte character — the most
	-- likely reason a 200 KB page took the whole channel down on 2026-09-02,
	-- before `serve` guarded its encoding. A cut character is trimmed;
	-- a body that is not text at all is shown up to its first invalid byte,
	-- and the reply says so rather than passing the bytes along.
	local notText = nil
	local validLength, invalidAt = utf8.len(body)
	if validLength == nil then
		local cutCharacter = truncated and invalidAt > #body - 3
		body = string.sub(body, 1, invalidAt - 1)
		if not cutCharacter then
			notText = ("Body is not valid UTF-8 text from byte %d on (binary content?); only the %d byte(s) before it are shown."):format(
				invalidAt,
				invalidAt - 1
			)
		end
	end

	local lines = { ("HTTP %d %s"):format(response.StatusCode, tostring(response.StatusMessage)) }
	local kind = contentType(response.Headers)
	table.insert(lines, "Content-Type: " .. (kind or "(not stated by the server)"))
	if truncated then
		table.insert(lines, ("Body truncated to %d bytes of %d."):format(MAX_BODY_BYTES, #(response.Body or "")))
	end
	if notText ~= nil then
		table.insert(lines, notText)
	end
	table.insert(lines, "")
	table.insert(lines, body)

	-- A 4xx/5xx is an answer, not a failure of the tool: the agent asked what
	-- the server says and the server said 404. Reporting it as an error would
	-- cost the status line and the body, which are the two things worth having.
	return true, table.concat(lines, "\n")
end

--[[
	Insert a Creator Store asset into the open place.

	The last upstream tool with a credible path here, and the one this repo
	refused to take on plausibility: "many plugins call `InsertService:LoadAsset`"
	is an argument, not a measurement, and this repo has already paid once for
	the difference. Measured on 2026-08-24 against a real Studio, through this
	channel, under plugin security:

	    .LoadAsset readable=true -> function
	    LoadAsset(0)         -> "Request asset was not found"
	    LoadAsset(125013769) -> Model

	The *first* line is the one that decided it. An asset error, not an identity
	one — a method closed to this context answers "The current thread cannot
	call 'X' (lacking capability RobloxScript)", which is exactly what
	`VirtualInputManager` answered in the same session, and why the two input
	tools stayed with Roblox.

	# Canonical arguments and tolerated aliases

	The sovereign schema publishes `asset_id`, `parent` and `position`. Older
	transcripts and hand-written calls may use common aliases, which remain
	accepted but are not published. An unrecognised shape is returned directly
	to the agent as unsupported. The result always names the id, parent and
	whether a position was applied, so an unintended insert is visible at once.
]]
local ASSET_ID_KEYS = { "asset_id", "assetId", "id", "asset" }
local PARENT_KEYS = { "parent", "parent_path", "parentPath", "destination" }

--[[
	The asset id, whatever plausible shape it arrived in.

	Numbers, numeric strings and `rbxassetid://123` all appear in agent-written
	calls, and refusing two of the three would be refusing the call over its
	spelling.
]]
local function requestedAssetId(arguments)
	-- A value that was *given* but is not a usable id (0, a negative, a
	-- fraction, prose) is remembered and named back: "could not find an
	-- asset id" for `asset_id: 0` sent the bench agent of 2026-09-01
	-- looking at the argument's spelling instead of its value.
	local invalid = nil
	for _, key in ipairs(ASSET_ID_KEYS) do
		local value = arguments[key]
		if type(value) == "number" then
			if value > 0 and value % 1 == 0 then
				return value
			end
			invalid = tostring(value)
		end
		if type(value) == "string" then
			local digits = string.match(value, "^%s*rbxassetid://(%d+)%s*$") or string.match(value, "^%s*(%d+)%s*$")
			local parsed = digits and tonumber(digits) or nil
			if parsed and parsed > 0 then
				return parsed
			end
			if string.match(value, "%S") then
				invalid = value
			end
		end
	end
	return nil, invalid
end

local function requestedParent(arguments)
	for _, key in ipairs(PARENT_KEYS) do
		local value = arguments[key]
		if type(value) == "string" and value ~= "" then
			return value
		end
	end
	return nil
end

--[[
	`{x=,y=,z=}` or `{1,2,3}`, or nothing.

	Accepted because an insert that lands at the origin when the caller asked
	for a spot is the kind of wrong that is only noticed later, in the place.
	Whether upstream's schema has this argument at all is unmeasured, so its
	absence is normal and its presence is honoured — and either way the result
	says which happened.
]]
local function requestedPosition(arguments)
	local value = arguments.position or arguments.Position or arguments.pivot
	if type(value) ~= "table" then
		return nil
	end
	local x = tonumber(value.x or value.X or value[1])
	local y = tonumber(value.y or value.Y or value[2])
	local z = tonumber(value.z or value.Z or value[3])
	if x == nil or y == nil or z == nil then
		return nil
	end
	return Vector3.new(x, y, z)
end

function Handlers.insert_asset(arguments)
	local assetId, invalid = requestedAssetId(arguments)
	if assetId == nil then
		if invalid ~= nil then
			-- The agent's own mistake, not an incapacity of this Studio session.
			return false,
				("insert_asset got '%s' as the asset id, which is not a positive Creator Store asset id."):format(
					invalid
				)
		end
		return false,
			"The VibeStarter Studio plugin could not find an asset id in this insert_asset call. It looks for `asset_id`.",
			true
	end

	local parentPath = requestedParent(arguments)
	local target = workspace
	if parentPath ~= nil then
		local resolved, resolveError = resolve(parentPath)
		if resolved == nil then
			-- The caller named a path that is not present in this DataModel.
			return false, ("insert_asset could not find the parent '%s': %s"):format(parentPath, resolveError)
		end
		target = resolved
	end

	local ok, container = pcall(function()
		return InsertService:LoadAsset(assetId)
	end)
	if not ok then
		-- Everything Roblox refuses lands here with its own wording, and the
		-- wording is the whole diagnosis: a private asset, an id that is not a
		-- model, a moderated one, or the network. Passing it through beats
		-- summarising it into "insert failed".
		return false, ("insert_asset could not load asset %d: %s"):format(assetId, tostring(container))
	end

	local inserted = container:GetChildren()
	if #inserted == 0 then
		container:Destroy()
		return false, ("Asset %d loaded but contained nothing to insert."):format(assetId)
	end

	local position = requestedPosition(arguments)
	-- One undo for one insert. `TryBeginRecording` returns nil when a
	-- recording is already open — a sync patch landing at the same moment —
	-- and in a playtest DataModel there is no history at all. Both are
	-- ordinary, so neither may stop the insert.
	local recording = nil
	if RunService:IsEdit() then
		local recordingOk, identifier = pcall(function()
			return ChangeHistoryService:TryBeginRecording("VibeStarter: insert asset " .. tostring(assetId))
		end)
		recording = recordingOk and identifier or nil
	end

	local names = {}
	for _, child in ipairs(inserted) do
		child.Parent = target
		if position ~= nil then
			-- `PivotTo` works for a Model and for a lone BasePart, which is
			-- what an asset unpacks into; anything else has no pivot and is
			-- left where it landed rather than being moved by a guess.
			pcall(function()
				child:PivotTo(CFrame.new(position))
			end)
		end
		table.insert(names, child:GetFullName() .. " (" .. child.ClassName .. ")")
	end
	container:Destroy()

	if recording ~= nil then
		pcall(function()
			ChangeHistoryService:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
		end)
	end

	local lines = {
		("Inserted asset %d into %s:"):format(assetId, target:GetFullName()),
	}
	for _, name in ipairs(names) do
		table.insert(lines, "  " .. name)
	end
	table.insert(
		lines,
		position ~= nil and ("Positioned at %s."):format(tostring(position))
			or "No position was requested, so the asset kept the one it was saved with."
	)
	return true, table.concat(lines, "\n")
end

--[[
	Walk a playtest character to a point.

	The one tool of the three that act on a running game that could come here,
	and the reason is a measurement rather than an opinion. On 2026-08-24,
	through this channel against a real Studio:

	    PathfindingService  -> CreatePath ok, ComputeAsync ok, Status = Success
	    VirtualInputManager -> SendKeyEvent: lacking capability RobloxScript

	`Humanoid:MoveTo` and `PathfindingService` are entirely public, so this one
	is ours. The other two wanted `VirtualInputManager`, and that answer is the
	border — the two input tools are therefore not provided, and the table says
	why.

	# It only runs in the playtest's server

	A Humanoid lives in the server's world. The edit tree has no character at
	all, and the client has a replica whose movement the server would overrule.
	The app routes it accordingly (`wanted_data_model` in `studio_plugin/host.rs`)
	and this handler refuses rather than pretending when it finds itself
	somewhere else — a tool that "succeeds" against the wrong world is worse
	than one that is not there.

	# Canonical arguments and tolerated aliases

	The schema publishes `position`, `target` and `player`. Common aliases from
	older calls remain accepted; unrecognised shapes report `unsupported` and
	the gateway returns that explanation directly to the agent.
]]
local POSITION_KEYS = { "position", "destination", "target_position", "targetPosition", "goal" }
local TARGET_PATH_KEYS = { "target", "target_path", "targetPath", "instance" }

-- A walk that has not finished by now is a walk that is not going to: the
-- character is stuck on geometry, or the path crossed something that moved.
-- Bounded here rather than left to the caller's ceiling so the answer is
-- "it did not arrive, here is how far it got" instead of a timeout with
-- nothing in it.
local WALK_BUDGET_SECONDS = 45

-- How close counts as arrived. A Humanoid stops where its collision box lets
-- it, not on the point, and `MoveTo` itself treats a few studs as reached —
-- so a tolerance is not laxity, it is the unit the engine works in. Wide
-- enough that standing against the goal passes, narrow enough that "did not
-- move at all" cannot.
local ARRIVAL_TOLERANCE_STUDS = 8

local function requestedPoint(arguments)
	for _, key in ipairs(POSITION_KEYS) do
		local value = arguments[key]
		if type(value) == "table" then
			local x = tonumber(value.x or value.X or value[1])
			local y = tonumber(value.y or value.Y or value[2])
			local z = tonumber(value.z or value.Z or value[3])
			if x ~= nil and y ~= nil and z ~= nil then
				return Vector3.new(x, y, z)
			end
		end
	end
	for _, key in ipairs(TARGET_PATH_KEYS) do
		local value = arguments[key]
		if type(value) == "string" and value ~= "" then
			local instance, resolveError = resolve(value)
			if instance == nil then
				return nil, ("character_navigation could not find '%s': %s"):format(value, resolveError)
			end
			local ok, pivot = pcall(function()
				return instance:GetPivot().Position
			end)
			if not ok then
				return nil, ("character_navigation found '%s' but it has no position to walk to."):format(value)
			end
			return pivot
		end
	end
	return nil
end

--[[
	The Humanoid this call is about.

	One player is the ordinary case and needs no argument. More than one and no
	name is the case where guessing would move the wrong character, so it
	refuses and lists them — the agent can then say which.
]]
local function requestedHumanoid(arguments)
	local wanted = arguments.player or arguments.player_name or arguments.playerName or arguments.character
	local players = game:GetService("Players"):GetPlayers()
	if #players == 0 then
		return nil,
			"No player is in the running game yet, so there is no character to move. A playtest takes a moment to spawn one."
	end

	local chosen = nil
	if type(wanted) == "string" and wanted ~= "" then
		local why
		chosen, why = PlayerTarget.resolve(players, wanted)
		if chosen == nil then
			return nil, why
		end
	elseif #players == 1 then
		chosen = players[1]
	else
		local names = {}
		for _, player in ipairs(players) do
			table.insert(names, player.Name)
		end
		return nil,
			("%d players are in the running game and this call did not say which: %s."):format(
				#players,
				table.concat(names, ", ")
			)
	end

	local character = chosen.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or root == nil then
		return nil, ("%s has no spawned character right now."):format(chosen.Name)
	end
	return { player = chosen, humanoid = humanoid, root = root }
end

function Handlers.character_navigation(arguments)
	if not RunService:IsRunning() then
		-- Routed before the playtest server session attached, or after it stopped.
		return false,
			"character_navigation needs a running playtest, and this VibeStarter plugin is in the Edit DataModel. Start a playtest, wait for the server session to attach, then retry.",
			true
	end
	if not RunService:IsServer() then
		return false,
			"character_navigation must run in the playtest's server, and this VibeStarter plugin is in the client DataModel.",
			true
	end

	local goal, pointError = requestedPoint(arguments)
	if goal == nil then
		if pointError ~= nil then
			-- The caller named something that is not present in this DataModel.
			return false, pointError
		end
		return false,
			"The VibeStarter Studio plugin could not find a destination in this character_navigation call. It looks for `position` as {x, y, z}, or `target` as a dotted path.",
			true
	end

	local who, whoError = requestedHumanoid(arguments)
	if who == nil then
		return false, whoError
	end

	local path = game:GetService("PathfindingService"):CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
	})
	local computed, computeError = pcall(function()
		path:ComputeAsync(who.root.Position, goal)
	end)
	if not computed then
		return false, ("character_navigation could not compute a path: %s"):format(tostring(computeError))
	end
	if path.Status ~= Enum.PathStatus.Success then
		-- A named refusal beats walking in a straight line into a wall: the
		-- agent can move the goal, or conclude the map has no route.
		return false,
			("No path from %s to %s: %s."):format(tostring(who.root.Position), tostring(goal), tostring(path.Status))
	end

	local waypoints = path:GetWaypoints()
	local startedAt = os.clock()
	local reachedCount = 0
	for index, waypoint in ipairs(waypoints) do
		if os.clock() - startedAt > WALK_BUDGET_SECONDS then
			return false,
				("Walked %d of %d waypoints in %ds and stopped: %s is at %s, the goal was %s."):format(
					reachedCount,
					#waypoints,
					WALK_BUDGET_SECONDS,
					who.player.Name,
					tostring(who.root.Position),
					tostring(goal)
				)
		end
		if waypoint.Action == Enum.PathWaypointAction.Jump then
			who.humanoid.Jump = true
		end
		who.humanoid:MoveTo(waypoint.Position)
		-- `MoveTo` gives up on its own after 8 s and fires with `false`, so
		-- this wait always ends. A waypoint that was not reached is reported
		-- rather than retried: retrying is what turns a character wedged on
		-- geometry into a call that never returns.
		local reached = who.humanoid.MoveToFinished:Wait()
		if not reached then
			return false,
				("%s stopped at waypoint %d of %d, at %s. The goal was %s."):format(
					who.player.Name,
					index,
					#waypoints,
					tostring(who.root.Position),
					tostring(goal)
				)
		end
		reachedCount += 1
	end

	-- The waypoints all said "reached" and that is NOT enough to answer yes.
	--
	-- Measured on 2026-08-24, first run against a real playtest: every
	-- waypoint reported reached, in 0.4 s, and the character had not moved a
	-- stud — `MoveToFinished` fires true for a target the humanoid is already
	-- within range of, and a path over geometry it cannot actually walk
	-- produces exactly that. The handler said "walked to 30, 3, 30" while the
	-- character stood at 1.28, 3.64, 0.64.
	--
	-- So arrival is checked against the world rather than inferred from the
	-- events, and the distance is in the answer either way. A tool that
	-- reports success for a move that did not happen is worse than one that is
	-- not there: the agent builds on it.
	local arrivedAt = who.root.Position
	local remaining = (arrivedAt - goal).Magnitude
	if remaining > ARRIVAL_TOLERANCE_STUDS then
		return false,
			("%s did not get there: it is %.1f studs from %s, at %s, after walking %d waypoints in %.1fs. Roblox's pathfinder found a route, so the character is most likely blocked by geometry it cannot climb."):format(
				who.player.Name,
				remaining,
				tostring(goal),
				tostring(arrivedAt),
				#waypoints,
				os.clock() - startedAt
			)
	end

	return true,
		("%s walked to %s in %d waypoints (%.1fs) and is now %.1f studs away, at %s."):format(
			who.player.Name,
			tostring(goal),
			#waypoints,
			os.clock() - startedAt,
			remaining,
			tostring(arrivedAt)
		)
end

local Playtest = require(script.Parent.Playtest)
local NativeCapture = require(script.Parent.NativeCapture)
Handlers.__native_state = function(args)
	local state = Playtest.state()
	if args.include_devices then
		state.devices = require(script.Parent.Devices).list()
	end
	return true, { content = {}, _meta = state }
end
Handlers.__native_start = function(args)
	return true, { content = {}, _meta = Playtest.start(args) }
end
Handlers.__native_authorize_stop = function(args)
	return true, { content = {}, _meta = Playtest.authorizeStop(args) }
end
Handlers.__native_stop = function(args)
	return true, { content = {}, _meta = Playtest.stopServer(args) }
end
Handlers.__native_ready = function()
	return true, { content = {}, _meta = ClientProxy.readiness(script.Parent.Runtime, script.Parent.Query) }
end
Handlers.__native_capture = function(args)
	return true, { content = {}, _meta = NativeCapture.acquire(args) }
end
Handlers.__native_pixels = function(args)
	return true, { content = {}, _meta = NativeCapture.pixels(args) }
end

return Handlers
