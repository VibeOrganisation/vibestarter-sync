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

--[[
	Resolve a dotted path to an instance.

	Accepts a leading `game.` and, for convenience, a bare service name —
	`Workspace.Baseplate` and `game.Workspace.Baseplate` are the same thing,
	and an agent that writes one and gets "not found" for the other has learned
	nothing about the place.
]]
function Query.resolve(path)
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

return Query
