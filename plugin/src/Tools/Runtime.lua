--[[
	Running Luau that arrived over the sovereign channel.

	This was the one genuinely unmeasured thing in the whole channel, and it is
	deliberately alone in its own file so that the answer would be a small diff
	either way.

	The question: can a Studio plugin compile and run source it was handed?
	**Yes** -- measured 2026-08-23 against a real Studio, 18 ms, and it was
	`loadstring` that served it: under plugin security it is available, and
	`ServerScriptService.LoadStringEnabled` gates server scripts at runtime
	rather than this context.

	One machine, one place, one Studio version. So both mechanisms stay, and
	`Runtime.run` now RETURNS which one compiled -- the failure path already
	named which one failed, and the success path saying nothing is what forced
	the question to be asked back by hand. Which one carries real traffic is
	also what decides whether the other is a tested fallback or dead code we
	find broken at the worst moment.

	There are two mechanisms and neither is guaranteed everywhere:

	  * `loadstring` is a global, but Roblox gates it on
	    `ServerScriptService.LoadStringEnabled`, which is off in most places.
	  * A `ModuleScript` whose `Source` is set at runtime and then `require`d
	    compiles under plugin security. Setting `.Source` is what this plugin
	    already does on every sync, so the permission is one the user has
	    granted.

	So: try both, in that order, and when neither works say **which** failed
	and how — an agent that reads "loadstring is disabled and requiring a
	generated module raised X" can act, where one that reads "could not run
	code" cannot. Nothing here guesses, and nothing here pretends the
	capability exists.

	The scratch module is parented inside the plugin's own script tree, not
	into the DataModel. That is not tidiness: `ServerStorage` is a place this
	plugin *synchronises*, and creating and destroying instances there would
	feed the diff engine changes the user never made.
]]

local Runtime = {}

-- `require` caches per instance, so a fresh ModuleScript is a fresh compile.
-- The counter only keeps names readable in a stack trace.
local nextChunk = 0

--[[
	Wrap the caller's source so that:
	  * a top-level `return` returns to us rather than ending a script,
	  * `print` is ours, so output can be captured without touching the
	    Studio log or racing another agent's calls.

	The wrapper costs one line, so a syntax error is reported one line further
	down than the caller wrote it. Said out loud in the error rather than
	silently corrected, because correcting it would mean parsing Roblox's
	message format — one more thing that changes under us.
]]
local function wrap(source)
	return "return function(print)\n" .. source .. "\nend"
end

--[[
	Returns `factory, nil, nil` on success, `nil, why, syntaxError` otherwise.

	`syntaxError` is the one distinction that matters downstream: a source that
	does not parse is the caller's own mistake, and reporting it as "this Studio
	would not let the plugin compile" sent agents — and the gateway's log —
	after a capability that was never missing.
]]
local function compileWithLoadstring(source)
	if type(loadstring) ~= "function" then
		return nil, "loadstring is not available in this Studio", false
	end
	-- `loadstring` returns `nil, message` on a syntax error and throws when
	-- the feature is disabled, so both returns are kept: the message is the
	-- line and column the agent needs.
	local ok, chunk, compileError = pcall(loadstring, wrap(source))
	if not ok then
		return nil, "loadstring refused: " .. tostring(chunk), false
	end
	if chunk == nil then
		return nil, tostring(compileError), true
	end
	local ranOk, factoryOrError = pcall(chunk)
	if not ranOk then
		return nil, "the compiled chunk failed to load: " .. tostring(factoryOrError), false
	end
	return factoryOrError, nil, false
end

local function compileWithModule(source, scratchParent)
	nextChunk += 1
	local module = Instance.new("ModuleScript")
	module.Name = "VibeStarterChunk" .. tostring(nextChunk)
	local sourceOk, sourceError = pcall(function()
		module.Source = wrap(source)
	end)
	if not sourceOk then
		module:Destroy()
		return nil, "could not write the chunk's source: " .. tostring(sourceError)
	end
	module.Parent = scratchParent
	local ok, factoryOrError = pcall(require, module)
	-- Destroyed either way: a required module stays cached against the
	-- instance, and keeping it alive would grow the plugin's tree by one
	-- module per tool call for the life of the session.
	module:Destroy()
	if not ok then
		return nil, "requiring a generated module failed: " .. tostring(factoryOrError)
	end
	if type(factoryOrError) ~= "function" then
		return nil, "the generated module did not return a function, which means the wrapper did not compile"
	end
	return factoryOrError, nil
end

--[[
	Compile and run `source`, capturing what it prints and what it returns.

	Returns `ok, text` — `text` is the tool result on success and the reason on
	failure, in both cases already in the words an agent should read.
]]
function Runtime.run(source, scratchParent)
	if type(source) ~= "string" or source == "" then
		return false, "execute_luau needs a `code` string to run."
	end

	local mechanism = "loadstring"
	local factory, loadstringError, syntaxError = compileWithLoadstring(source)
	if factory == nil and syntaxError then
		-- The caller's code does not parse. The generated-module path would
		-- only throw the same message from a different line, so it is not
		-- tried; and this is a failure of the call, never an incapacity of
		-- this Studio — the third return stays false.
		return false,
			"[error] the code does not compile: "
				.. tostring(loadstringError)
				.. "\nNote that the plugin wraps your code in one extra line, so the reported line number is your line plus one.",
			false,
			mechanism
	end
	local moduleError = nil
	if factory == nil then
		mechanism = "generated ModuleScript"
		factory, moduleError = compileWithModule(source, scratchParent)
	end
	if factory == nil then
		-- Neither mechanism compiled anything, and `loadstring` never got as
		-- far as parsing the source: this is the Studio refusing, not the
		-- code. The third return says so — "an incapacity of this Studio" —
		-- and the gateway hands the reason to the agent as `Unsupported`;
		-- there is no fallback backend. See `Served::Unsupported` in
		-- `studio_plugin/host.rs`.
		--
		-- One case still lands here by construction: `loadstring` absent AND
		-- the source not parsing, which `require` reports as a throw. The
		-- message names both mechanisms and the wrapper line so that case
		-- reads for what it is.
		return false,
			"This Studio would not let the VibeStarter plugin compile the code.\n"
				.. "- loadstring: "
				.. tostring(loadstringError)
				.. "\n- generated module: "
				.. tostring(moduleError)
				.. "\nNote that the plugin wraps your code in one extra line, so a syntax error is reported one line lower than you wrote it.",
			true
	end

	local printed = {}
	local function capture(...)
		local parts = {}
		for index = 1, select("#", ...) do
			parts[index] = tostring((select(index, ...)))
		end
		table.insert(printed, table.concat(parts, "\t"))
	end

	local results = table.pack(pcall(factory, capture))
	local ok = results[1]
	if not ok then
		local reason = tostring(results[2])
		-- The wrapper's extra line shifts runtime line numbers too, not only
		-- a syntax error's; a `:3:` in the message is the agent's line 2.
		if string.find(reason, ":%d+:") ~= nil then
			reason = reason
				.. "\nNote that the plugin wraps your code in one extra line, so the reported line number is your line plus one."
		end
		if #printed > 0 then
			-- What ran before the error is often the whole diagnosis, and
			-- dropping it would leave the agent re-running the script just to
			-- see how far it got.
			return false, table.concat(printed, "\n") .. "\n[error] " .. reason, false, mechanism
		end
		return false, "[error] " .. reason, false, mechanism
	end

	local lines = printed
	for index = 2, results.n do
		local value = results[index]
		table.insert(lines, "-- returned: " .. Runtime.describe(value))
	end
	if #lines == 0 then
		return true, "(the code ran and produced no output)", false, mechanism
	end
	return true, table.concat(lines, "\n"), false, mechanism
end

--[[
	How deep a returned table is walked. Past it the rest is one string that
	says so — a self-referencing world is not something to send back whole.
]]
local MAX_DEPTH = 8

--[[
	The same table, with everything JSON cannot carry replaced by its text.

	`HttpService:JSONEncode` turns every Roblox datatype into `null`, silently:
	`{ v = Vector3.new(1, 2, 3), inst = workspace }` came back as
	`{"v":null,"inst":null}` (measured 2026-09-02), and nothing in the reply
	let the agent tell a field it forgot to set from one the encoder threw
	away. So the table is walked first, and each value the encoder would lose
	becomes the line `describe` gives it at top level — an Instance is its
	path and class, a datatype is its type and its own text (`Vector3(1, 2,
	3)`, `Color3(1, 0, 0)`), an enum item its full name. Keys that are not
	strings or a clean 1..n array are stringified, so a mixed table becomes an
	object rather than an encoder error. Cycles and depth are bounded.
]]
local function jsonSafe(value, depth, seen)
	local kind = typeof(value)
	if kind == "nil" or kind == "boolean" or kind == "string" then
		return value
	elseif kind == "number" then
		-- NaN and the infinities have no JSON form either. Typed like the
		-- datatypes below — `number(nan)`, not `nan` — so that a string "nan"
		-- and the number 0/0 do not come back byte for byte identical
		-- (deep test of 2026-09-02, five such collisions).
		if value ~= value or value == math.huge or value == -math.huge then
			return "number(" .. tostring(value) .. ")"
		end
		return value
	elseif kind == "Instance" then
		return value:GetFullName() .. " (" .. value.ClassName .. ")"
	elseif kind == "EnumItem" or kind == "Enum" or kind == "Enums" then
		return tostring(value)
	elseif kind == "function" then
		return "(function)"
	elseif kind == "thread" then
		return "(thread)"
	elseif kind == "table" then
		if seen[value] then
			return "(cycle)"
		end
		if depth >= MAX_DEPTH then
			return ("(a table nested deeper than %d levels)"):format(MAX_DEPTH)
		end
		seen[value] = true
		local count, maxIndex, allIndices = 0, 0, true
		for key in pairs(value) do
			count += 1
			if type(key) == "number" and key >= 1 and key == math.floor(key) then
				if key > maxIndex then
					maxIndex = key
				end
			else
				allIndices = false
			end
		end
		local out = {}
		if allIndices and count == maxIndex then
			for index = 1, maxIndex do
				out[index] = jsonSafe(value[index], depth + 1, seen)
			end
		else
			for key, item in pairs(value) do
				local name = type(key) == "string" and key or tostring(jsonSafe(key, depth + 1, seen))
				out[name] = jsonSafe(item, depth + 1, seen)
			end
		end
		seen[value] = nil
		return out
	end
	-- Vector3, CFrame, Color3, UDim2, BrickColor, Random…: the type, so the
	-- agent knows what it reads, and the value's own text.
	return kind .. "(" .. tostring(value) .. ")"
end

--[[
	One value, in one line an agent can read.

	Deliberately not JSON: half of what Studio holds (CFrame, Enum, Instance)
	has no JSON form, and encoding the other half differently would make the
	output shape depend on what happened to be returned. A table IS given as
	JSON — the one shape an agent can read a structure back from — with the
	values JSON cannot carry made into text rather than dropped (`jsonSafe`).
]]
function Runtime.describe(value)
	local kind = typeof(value)
	if kind == "string" then
		return string.format("%q", value)
	elseif kind == "Instance" then
		return value:GetFullName() .. " (" .. value.ClassName .. ")"
	elseif kind == "EnumItem" then
		return tostring(value)
	elseif kind == "table" then
		local ok, encoded = pcall(function()
			return game:GetService("HttpService"):JSONEncode(jsonSafe(value, 0, {}))
		end)
		if ok then
			return encoded
		end
		-- Nothing `jsonSafe` produces should fail to encode; if Studio still
		-- refuses, its reason beats a bare "table: 0x…".
		return "(a table that does not encode as JSON: " .. tostring(encoded) .. ")"
	end
	return tostring(value)
end

return Runtime
