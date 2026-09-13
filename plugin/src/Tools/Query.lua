--[[
	Reading a DataModel's tree: path resolution, inspection, search.

	One module, because the same questions are now asked in two kinds of
	state. `Handlers` requires it where the plugin runs — Edit and a
	playtest's server — and `ClientProxy` clones it beside `Runtime` into the
	playtest, so a chunk running in the **client** answers with this exact
	code. A second copy living as generated source inside a handler would
	drift the day this one learns something; the clone cannot.

	That constraint is why nothing here touches a privilege or a plugin-only
	global: everything is public Roblox API a `LocalScript` may call. The one
	thing inspection needs that a client does not have — the reflection
	database naming each class's readable properties (2.1 MB, server-side) —
	is therefore an *argument*: the caller looks the names up where the
	database lives and passes them in.
]]

local Query = {}
-- Keep wrappers alive between requests; the bounded queue limits retention.
local references = {}
local referenceIds = setmetatable({}, { __mode = "k" })
local referenceTimes = {}
local referenceQueue = {}
local referenceSlot = 1
local MAX_REFERENCES = 2048
local referenceSerial = 0
local referenceEpoch = game:GetService("HttpService"):GenerateGUID(false)
local function reference(instance)
	local id = referenceIds[instance]
	if id and references[id] then
		referenceTimes[id] = os.clock()
		return id
	end
	referenceSerial += 1
	id = "@" .. referenceEpoch .. ":" .. referenceSerial
	references[id], referenceIds[instance], referenceTimes[id] = instance, id, os.clock()
	local expired = referenceQueue[referenceSlot]
	if expired then
		references[expired], referenceTimes[expired] = nil, nil
	end
	referenceQueue[referenceSlot] = id
	referenceSlot = referenceSlot % MAX_REFERENCES + 1
	return id
end
local function identify(instance)
	return { ref = reference(instance), path = instance:GetFullName(), class_name = instance.ClassName }
end
local function value(raw)
	local kind = typeof(raw)
	if kind == "Instance" then
		return identify(raw)
	end
	if kind == "Vector3" then
		return { type = kind, value = { raw.X, raw.Y, raw.Z } }
	end
	if kind == "Vector2" then
		return { type = kind, value = { raw.X, raw.Y } }
	end
	if kind == "Color3" then
		return { type = kind, value = { raw.R, raw.G, raw.B } }
	end
	if kind == "CFrame" then
		return { type = kind, value = { raw:GetComponents() } }
	end
	if kind == "nil" then
		return { type = "nil" }
	end
	if kind == "string" then
		return #raw > 2000 and { value = string.sub(raw, 1, 2000), truncated = true } or raw
	end
	if kind == "boolean" or kind == "number" then
		return raw
	end
	return { type = kind, value = tostring(raw) }
end

--[[
	Resolve a dotted path to an instance.

	Accepts a leading `game.` and, for convenience, a bare service name —
	`Workspace.Baseplate` and `game.Workspace.Baseplate` are the same thing,
	and an agent that writes one and gets "not found" for the other has learned
	nothing about the place.
]]
function Query.resolve(path)
	if type(path) == "string" and string.sub(path, 1, 1) == "@" then
		local instance = references[path]
		if
			instance
			and (instance == game or instance:IsDescendantOf(game))
			and os.clock() - (referenceTimes[path] or 0) <= 300
		then
			return instance
		end
		return nil, "STUDIO_REFERENCE_EXPIRED: Search again in the same DataModel and player."
	end
	if type(path) == "table" then
		local current = game
		for _, segment in ipairs(path) do
			if type(segment) ~= "string" then
				return nil, "Path segments must be strings"
			end
			local matches = {}
			for _, child in ipairs(current:GetChildren()) do
				if child.Name == segment then
					table.insert(matches, child)
				end
			end
			if #matches ~= 1 then
				return nil, "Path segment is missing or ambiguous: " .. segment
			end
			current = matches[1]
		end
		return current
	end
	if type(path) ~= "string" or path == "" then
		return nil, "expected a dotted path such as 'Workspace.Baseplate'"
	end
	local current = game
	local first = true
	for segment in string.gmatch(path, "[^%.]+") do
		if first and (segment == "game" or segment == "Game") then
			first = false
			continue
		end
		first = false
		local child = current:FindFirstChild(segment)
		if child then
			local count = 0
			for _, candidate in ipairs(current:GetChildren()) do
				if candidate.Name == segment then
					count += 1
				end
			end
			if count > 1 then
				return nil, "Ambiguous path: search_game_tree returns unique references for siblings named " .. segment
			end
		end
		if child == nil and current == game then
			-- Services are not always children until they have been fetched.
			local ok, service = pcall(game.GetService, game, segment)
			if ok then
				child = service
			end
		end
		if child == nil then
			-- Instance-valued *properties* that read like children:
			-- `Players.LocalPlayer` in a client, `Workspace.CurrentCamera`,
			-- `Workspace.Terrain`. `FindFirstChild` cannot see them, and
			-- "no child named 'LocalPlayer'" cost the bench agent of
			-- 2026-09-01 a round-trip for a path `execute_luau` accepts.
			-- Read under pcall, keep only an Instance: a method or a plain
			-- property must not become a path segment.
			local ok, value = pcall(function()
				return current[segment]
			end)
			if ok and typeof(value) == "Instance" then
				child = value
			end
		end
		if child == nil then
			return nil, ("'%s' has no child named '%s'"):format(current:GetFullName(), segment)
		end
		current = child
	end
	return current, nil
end

--[[
	One instance, described the way `inspect_instance` answers: header,
	properties, children.

	`propertyNames` comes from the caller (see the header), and `describe` is
	`Runtime.describe` — passed in rather than required here so the module
	works identically as a clone, where `Runtime` is a sibling clone and not
	`script.Parent.Runtime`.
]]
function Query.inspect(instance, propertyNames, describe)
	local lines = {
		("%s (%s)"):format(instance:GetFullName(), instance.ClassName),
	}

	local properties = {}
	for _, name in ipairs(propertyNames) do
		-- pcall per property: a handful throw on read depending on the
		-- instance's state (an unloaded asset, a property valid only at
		-- runtime), and one of those must not take the whole inspection down.
		local ok, value = pcall(function()
			return instance[name]
		end)
		if ok then
			table.insert(properties, ("  %s = %s"):format(name, describe(value)))
		end
	end
	if #properties > 0 then
		table.insert(lines, "Properties:")
		table.move(properties, 1, #properties, #lines + 1, lines)
	end

	local children = instance:GetChildren()
	if #children == 0 then
		table.insert(lines, "Children: none")
	else
		table.insert(lines, ("Children (%d):"):format(#children))
		for _, child in ipairs(children) do
			table.insert(lines, ("  %s (%s)"):format(child.Name, child.ClassName))
		end
	end
	return lines
end

--[[
	Search `root`'s descendants and word the whole answer.

	`needle` is already lowercased by the caller (it validated the arguments);
	`className` matches by `IsA`, so 'BasePart' finds Part and MeshPart. The
	report is built here, down to the truncation sentence, so the Edit path and
	the client path cannot phrase the same search two ways.
]]
function Query.searchReport(root, needle, className, limit)
	local matches = {}
	local truncated = false
	for _, descendant in ipairs(root:GetDescendants()) do
		local nameMatches = needle == nil or string.find(string.lower(descendant.Name), needle, 1, true) ~= nil
		if nameMatches then
			local classMatches = true
			if className ~= nil then
				local ok, isA = pcall(descendant.IsA, descendant, className)
				classMatches = ok and isA
			end
			if classMatches then
				if #matches >= limit then
					truncated = true
					break
				end
				table.insert(matches, ("%s (%s)"):format(descendant:GetFullName(), descendant.ClassName))
			end
		end
	end

	if #matches == 0 then
		return "No instance under " .. root:GetFullName() .. " matched."
	end
	local header = ("%d match(es) under %s:"):format(#matches, root:GetFullName())
	if truncated then
		-- A silent cap reads as "that is all there is", which is the one
		-- conclusion an agent must not draw from a truncated search.
		header = ("%d match(es) under %s (stopped at the limit of %d — narrow the search or raise `limit`):"):format(
			#matches,
			root:GetFullName(),
			limit
		)
	end
	return header .. "\n" .. table.concat(matches, "\n")
end

-- Structured query operations use the same resolver in Edit, Server and each Client.
function Query.classNames(args)
	local classes = {}
	for _, path in ipairs(args.paths or { args.path }) do
		local instance = Query.resolve(path)
		if instance then
			classes[instance.ClassName] = true
		end
	end
	return classes
end
function Query.inspectStructured(args, propertiesByClass)
	local paths = args.paths or { args.path }
	assert(#paths >= 1 and #paths <= 25, "inspect_instance needs 1–25 targets")
	local result = { instances = {} }
	for _, path in ipairs(paths) do
		local instance, why = Query.resolve(path)
		if not instance then
			table.insert(result.instances, { target = path, error = why })
			continue
		end
		local item = identify(instance)
		item.properties, item.attributes, item.children = {}, {}, {}
		for _, name in ipairs(args.properties or propertiesByClass[instance.ClassName] or {}) do
			assert(type(name) == "string", "Property names must be strings")
			local ok, raw = pcall(function()
				return instance[name]
			end)
			if ok then
				item.properties[name] = value(raw)
			else
				item.properties[name] = { error = tostring(raw) }
			end
		end
		for name, raw in pairs(instance:GetAttributes()) do
			item.attributes[name] = value(raw)
		end
		item.tags = instance:GetTags()
		local children = instance:GetChildren()
		item.child_count = #children
		local limit = math.clamp(math.floor(tonumber(args.children_limit) or 30), 0, 100)
		for i = 1, math.min(#children, limit) do
			table.insert(item.children, identify(children[i]))
		end
		item.children_truncated = #children > limit
		table.insert(result.instances, item)
	end
	return result
end
function Query.searchStructured(args)
	local root, why = game, nil
	if args.root then
		root, why = Query.resolve(args.root)
	end
	assert(root, why)
	local limit = math.clamp(math.floor(tonumber(args.limit) or 100), 1, 1000)
	local offset = math.clamp(math.floor(tonumber(args.offset) or 0), 0, 100000)
	assert(
		args.query or args.class_name or args.tags or args.attributes,
		"Supply a name, class, tags or attributes filter"
	)
	local result = {
		matches = {},
		offset = offset,
		truncated = false,
		consistency = "Live tree; offsets are not a stable snapshot. References expire after 5 minutes or a context change.",
	}
	local count = 0
	local needle = args.query and string.lower(args.query)
	for _, instance in ipairs(root:GetDescendants()) do
		if needle and not string.find(string.lower(instance.Name), needle, 1, true) then
			continue
		end
		if args.class_name and not instance:IsA(args.class_name) then
			continue
		end
		local matches = true
		for _, tag in ipairs(args.tags or {}) do
			if not instance:HasTag(tag) then
				matches = false
				break
			end
		end
		for name, expected in pairs(args.attributes or {}) do
			if instance:GetAttribute(name) ~= expected then
				matches = false
				break
			end
		end
		if not matches then
			continue
		end
		count += 1
		if count <= offset then
			continue
		end
		if #result.matches == limit then
			result.truncated = true
			result.next_offset = offset + limit
			break
		end
		local item = identify(instance)
		if args.properties then
			item.properties = {}
			for _, name in ipairs(args.properties) do
				local ok, raw = pcall(function()
					return instance[name]
				end)
				if ok then
					item.properties[name] = value(raw)
				else
					item.properties[name] = { error = tostring(raw) }
				end
			end
		end
		table.insert(result.matches, item)
	end
	return result
end

return Query
