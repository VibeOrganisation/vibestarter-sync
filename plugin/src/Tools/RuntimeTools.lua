-- Bounded runtime operations shared verbatim by the server and client proxy.
local Query = require(script.Parent.Query)
local RunService = game:GetService("RunService")
local Tools = {}

local function number(value, default, low, high, name)
	if value == nil then
		return default
	end
	assert(type(value) == "number" and value == value and value >= low and value <= high, name .. " is out of range")
	return value
end

local function validateActions(actions)
	assert(type(actions) == "table" and #actions >= 1 and #actions <= 32, "actions must contain 1–32 entries")
	-- Validate the entire batch before pressing anything. A press always includes its release.
	local total = 0
	for _, action in ipairs(actions) do
		assert(type(action) == "table", "Each action must be an object")
		assert(
			action.verify_activation == nil or type(action.verify_activation) == "boolean",
			"verify_activation must be boolean"
		)
		assert(table.find({ "key", "click", "move", "text" }, action.type), "Unknown input action")
		total += number(action.duration_ms, 100, 0, 2000, "duration_ms")
		if action.type == "key" then
			assert(type(action.key) == "string" and Enum.KeyCode[action.key], "Unknown key")
		end
		if action.type == "text" then
			assert(type(action.text) == "string" and #action.text <= 2000, "text must be at most 2000 bytes")
		end
		if action.type == "click" or action.type == "move" then
			assert(
				action.button == nil or action.button == "left" or action.button == "right",
				"button must be left or right"
			)
			if not action.target and not action.instance then
				assert(
					type(action.position) == "table" and #action.position == 2,
					"position must be [x, y] in screen pixels"
				)
				assert(action.position[1] ~= nil and action.position[2] ~= nil, "position needs x and y")
				number(action.position[1], nil, 0, 16384, "x")
				number(action.position[2], nil, 0, 16384, "y")
			end
		end
	end
	assert(total <= 8000, "Input batch must fit within 8000 ms; split longer sequences into scenario steps")
end

function Tools.player_input(args, pluginContext)
	assert(RunService:IsClient() and RunService:IsRunning(), "STUDIO_INPUT_REQUIRES_CLIENT: Use a Play client.")
	validateActions(args.actions)
	if not pluginContext then
		local inputEndpoint = game:GetService("ReplicatedStorage"):WaitForChild("VibeStarterPluginInput", 3)
		assert(
			inputEndpoint and inputEndpoint:IsA("BindableFunction"),
			"STUDIO_INPUT_UNAVAILABLE: The client plugin input endpoint is missing; restart Studio."
		)
		local forwarded = table.clone(args)
		forwarded.actions = {}
		for _, original in ipairs(args.actions or {}) do
			local action = table.clone(original)
			if action.target then
				local target, why = Query.resolve(action.target)
				assert(target, why)
				assert(target:IsA("GuiObject") and target.Visible, "Input target must be a visible GuiObject")
				action.target = nil
				action.instance = target
			end
			table.insert(forwarded.actions, action)
		end
		-- Observe in the game VM after each plugin invocation has returned.
		-- Input dispatch and deferred GUI signals may arrive on later frames.
		local connection
		local function cleanup()
			if connection then
				connection:Disconnect()
				connection = nil
			end
		end
		local expired = false
		local started = os.clock()
		local timer = task.delay(10, function()
			expired = true
			cleanup()
		end)
		local observations, completed = {}, 0
		local ok, failure = pcall(function()
			for index, action in ipairs(forwarded.actions) do
				assert(not expired and os.clock() - started < 10, "STUDIO_INPUT_TIMEOUT")
				local activated = nil
				local target = action.instance
				if action.type == "click" and action.button ~= "right" and target and target:IsA("GuiButton") then
					activated = false
					connection = target.Activated:Connect(function()
						activated = true
					end)
				end
				local single = table.clone(forwarded)
				single.actions = { action }
				-- Share the batch deadline with the plugin's independent release watchdog.
				single.__input_timeout_s = math.max(0.001, 10 - (os.clock() - started))
				inputEndpoint:Invoke(single)
				if activated ~= nil then
					local untilTime = os.clock() + 0.25
					repeat
						task.wait(0.02)
					until activated or expired or os.clock() >= untilTime
				end
				cleanup()
				assert(not expired, "STUDIO_INPUT_TIMEOUT")
				table.insert(observations, { index = index, type = action.type, activation_observed = activated })
				assert(
					activated ~= false or action.verify_activation == false,
					"STUDIO_INPUT_NOT_OBSERVED: Action "
						.. index
						.. " was sent but the target button did not activate. Check visibility, overlays, Interactable/Active and whether Studio rendering is suspended. Use verify_activation=false only when intentionally testing a button that must not activate."
				)
				completed += 1
			end
		end)
		cleanup()
		if coroutine.status(timer) ~= "dead" then
			task.cancel(timer)
		end
		assert(ok, tostring(failure) .. " (completed " .. completed .. " actions)")
		return {
			completed = completed,
			released = true,
			observations = observations,
			note = "Input delivery is not a game outcome. Targeted left clicks on GuiButtons observe Activated; use scenario assertions to verify other effects.",
		}
	end
	local actions = args.actions
	local created, input = pcall(function()
		return game:GetService("UserInputService"):CreateVirtualInput()
	end)
	assert(
		created and input,
		"STUDIO_INPUT_UNAVAILABLE: VirtualInput is unavailable in this Studio client; update Studio."
	)
	local heldKey, heldMouse, position
	local function release()
		if heldKey then
			pcall(function()
				input:SendKey(false, heldKey, false)
			end)
			heldKey = nil
		end
		if heldMouse then
			pcall(function()
				input:SendMouseButton(position, heldMouse, false, 0)
			end)
			heldMouse = nil
		end
	end
	-- This watchdog outlives a cancelled caller, so a yielded action cannot strand a key.
	local expired = false
	local timer = task.delay(number(args.__input_timeout_s, 10, 0.001, 10, "input timeout"), function()
		expired = true
		release()
	end)
	local completed = 0
	local ok, failure = pcall(function()
		for _, action in ipairs(actions) do
			assert(not expired, "STUDIO_INPUT_TIMEOUT")
			local duration = (action.duration_ms or 100) / 1000
			if action.type == "key" then
				heldKey = Enum.KeyCode[action.key]
				input:SendKey(true, heldKey, false)
			elseif action.type == "text" then
				input:SendTextInput(action.text)
			else
				if action.target or action.instance then
					local instance, why = action.instance, nil
					if not instance then
						instance, why = Query.resolve(action.target)
					end
					assert(instance, why)
					assert(instance:IsA("GuiObject") and instance.Visible, "Input target must be a visible GuiObject")
					position = instance.AbsolutePosition
						+ instance.AbsoluteSize / 2
						- game:GetService("GuiService"):GetInsetArea(Enum.ScreenInsets.None).Min
				else
					assert(
						type(action.position) == "table" and #action.position == 2,
						"position must be [x, y] in viewport pixels"
					)
					position = Vector2.new(
						number(action.position[1], nil, 0, 16384, "x"),
						number(action.position[2], nil, 0, 16384, "y")
					)
				end
				input:SendMousePosition(position)
				if action.type == "click" then
					heldMouse = action.button == "right" and Enum.UserInputType.MouseButton2
						or Enum.UserInputType.MouseButton1
					input:SendMouseButton(position, heldMouse, true, 0)
				end
			end
			task.wait(duration)
			release()
			assert(not expired, "STUDIO_INPUT_TIMEOUT")
			completed += 1
		end
	end)
	release()
	if coroutine.status(timer) ~= "dead" then
		task.cancel(timer)
	end
	assert(ok, tostring(failure) .. " (completed " .. completed .. " actions; held inputs released)")
	return { completed = completed, released = true }
end

local function primitive(value)
	local kind = typeof(value)
	if kind == "nil" or kind == "boolean" or kind == "number" or kind == "string" then
		return value
	end
	return tostring(value)
end

function Tools.condition(args)
	local target, why = Query.resolve(args.target)
	if
		not target
		and why
		and (
			string.find(why, "STUDIO_REFERENCE_EXPIRED", 1, true)
			or string.find(string.lower(why), "ambiguous", 1, true)
		)
	then
		error(why)
	end
	if args.exists ~= nil then
		assert(type(args.exists) == "boolean", "exists must be boolean")
		return { passed = (target ~= nil) == args.exists, actual = target ~= nil, expected = args.exists }
	end
	if not target then
		return { passed = false, error = why }
	end
	assert((args.property ~= nil) ~= (args.attribute ~= nil), "Specify property or attribute")
	local value
	if args.property then
		value = target[args.property]
	else
		value = target:GetAttribute(args.attribute)
	end
	value = primitive(value)
	local op = args.operator or "equals"
	local passed
	if op == "equals" then
		passed = value == args.value
	elseif op == "not_equals" then
		passed = value ~= args.value
	elseif op == "greater_than" or op == "less_than" then
		assert(type(value) == "number" and type(args.value) == "number", "Ordered comparisons require numbers")
		passed = op == "greater_than" and value > args.value or op == "less_than" and value < args.value
	else
		error("Unknown condition operator")
	end
	return { passed = passed, actual = value, expected = args.value, target = args.target, operator = op }
end

function Tools.performance_check(args)
	assert(RunService:IsRunning(), "STUDIO_PERFORMANCE_REQUIRES_PLAYTEST")
	local duration = number(args.duration_s, 3, 0.5, 8, "duration_s")
	local stats = game:GetService("Stats")
	local function memory()
		local ok, value = pcall(function()
			return stats:GetTotalMemoryUsageMb()
		end)
		return ok and value or nil
	end
	local countBefore, memoryBefore = #game:GetDescendants(), memory()
	local samples = {}
	local heartbeats = 0
	local start = os.clock()
	local signal = RunService:IsClient() and RunService.RenderStepped or RunService.Heartbeat
	-- A subscription with a separately scheduled disconnect survives caller cancellation.
	local connection = signal:Connect(function(dt)
		if #samples < 10000 then
			table.insert(samples, dt * 1000)
		end
	end)
	local heartbeatConnection = RunService.Heartbeat:Connect(function()
		heartbeats += 1
	end)
	local timer = task.delay(duration, function()
		connection:Disconnect()
		heartbeatConnection:Disconnect()
	end)
	task.wait(duration)
	connection:Disconnect()
	heartbeatConnection:Disconnect()
	if coroutine.status(timer) ~= "dead" then
		task.cancel(timer)
	end

	table.sort(samples)
	local sum = 0
	for _, value in ipairs(samples) do
		sum += value
	end
	local function percentile(q)
		return samples[math.clamp(math.ceil(#samples * q), 1, #samples)]
	end
	local after, memoryAfter = #game:GetDescendants(), memory()
	return {
		context = RunService:IsClient() and "Client" or "Server",
		duration_s = os.clock() - start,
		samples = #samples,
		frame_ms = #samples > 0
				and { mean = sum / #samples, p50 = percentile(0.5), p95 = percentile(0.95), max = samples[#samples] }
			or nil,
		heartbeats = heartbeats,
		rendering = RunService:IsClient()
				and {
					status = #samples > 0 and "active" or "inactive",
					observed_fps = #samples / (os.clock() - start),
					note = #samples == 0
							and "No rendered frames during this observation. Restore the Studio viewport before screenshots or visual input tests; this is not a game performance score."
						or nil,
				}
			or nil,
		instances = { before = countBefore, after = after, delta = after - countBefore },
		memory_mb = {
			before = memoryBefore,
			after = memoryAfter,
			delta = memoryBefore and memoryAfter and memoryAfter - memoryBefore or nil,
		},
		note = "Studio measurements; memory is process-wide. Server heartbeat is not client rendering performance. Compare identical scenarios on the same host; no mobile performance prediction.",
	}
end

return Tools
