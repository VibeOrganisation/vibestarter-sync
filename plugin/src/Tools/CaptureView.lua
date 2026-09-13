-- Runs in the viewport's DataModel, in Edit or in the selected Play client.
local CaptureView = {}

function CaptureView.acquire(operation)
	local camera = workspace.CurrentCamera
	local expected = camera and camera:GetAttribute("VibeStarterFrameExpectedCFrame")
	local fov = camera and camera:GetAttribute("VibeStarterFrameExpectedFov")
	local held = true
	local function observe()
		if operation == nil or not held then
			return
		end
		if
			camera == nil
			or workspace.CurrentCamera ~= camera
			or camera:GetAttribute("VibeStarterFrameOperation") ~= operation
			or camera.CameraType ~= Enum.CameraType.Scriptable
			or typeof(expected) ~= "CFrame"
			or type(fov) ~= "number"
		then
			held = false
			return
		end
		local _, angle = expected:ToObjectSpace(camera.CFrame):ToAxisAngle()
		held = (camera.CFrame.Position - expected.Position).Magnitude <= 0.5
			and math.abs(angle) <= math.rad(1)
			and math.abs(camera.FieldOfView - fov) <= 0.1
	end
	local pending, uri = true, nil
	local started = os.clock()
	local lastFrame = started
	local runService = game:GetService("RunService")
	local inactiveHint = runService:IsRunning() and "Restore the Studio viewport, then retry."
		or "Use a single-player Play client for game visuals, or restore the Studio viewport, then retry."
	local connection = runService.RenderStepped:Connect(function()
		lastFrame = os.clock()
	end)
	-- The independent cleanup also runs if the tool coroutine is cancelled.
	local timer = task.delay(8, function()
		pending = false
		connection:Disconnect()
	end)
	local ok, failure = pcall(function()
		observe()
		game:GetService("CaptureService"):CaptureScreenshot(function(value)
			if pending then
				observe()
				uri = value
			end
		end)
		while uri == nil and pending and os.clock() - started < 8 do
			task.wait(0.02)
			if uri == nil then
				observe()
				assert(
					os.clock() - lastFrame < 1.5,
					"STUDIO_RENDER_INACTIVE: No rendered frame for 1.5 seconds (the viewport may be minimized or inactive). "
						.. inactiveHint
						.. " Scripts can continue while rendering is suspended."
				)
			end
		end
		assert(
			type(uri) == "string",
			"STUDIO_CAPTURE_TIMEOUT: Studio did not produce an image within 8 seconds despite active rendering."
		)
	end)
	pending = false
	connection:Disconnect()
	if coroutine.status(timer) ~= "dead" then
		task.cancel(timer)
	end
	assert(ok, tostring(failure))
	local result = { uri = uri }
	if operation ~= nil then
		result.frameHeld = held
	end
	return result
end

return CaptureView
