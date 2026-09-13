-- Device simulation is scoped to the owned test and restored by its lifecycle.
local Devices = {}
local function service()
	local ok, value = pcall(game.GetService, game, "StudioDeviceSimulatorService")
	assert(ok and value, "STUDIO_DEVICE_UNAVAILABLE: Update Studio to use device simulation.")
	return value
end
local function mobile(s, id)
	local form = s:GetDeviceInfoAsync(id).DeviceForm
	return form == Enum.DeviceForm.Phone or form == Enum.DeviceForm.Tablet
end
function Devices.snapshot()
	local s = service()
	local id = s:GetDeviceAsync()
	local state = { id = id, starterOrientation = game:GetService("StarterGui").ScreenOrientation }
	if id ~= "default" then
		state.resolution = s:GetResolutionAsync()
		state.dpi = s:GetPixelDensityAsync()
		state.scaling = s:GetScalingModeAsync()
		state.orientation = mobile(s, id) and s:GetOrientationAsync() or nil
	end
	return state
end
function Devices.list()
	local s = service()
	local profiles = {}
	for _, id in ipairs(s:GetDeviceListAsync()) do
		local info = s:GetDeviceInfoAsync(id)
		table.insert(
			profiles,
			{ id = id, name = info.Name, width = info.Width, height = info.Height, form = tostring(info.DeviceForm) }
		)
	end
	local current = Devices.snapshot()
	local settings = {
		id = current.id,
		orientation = current.orientation and tostring(current.orientation),
		scaling = current.scaling and tostring(current.scaling),
		dpi = current.dpi,
		starterOrientation = tostring(current.starterOrientation),
	}
	if current.resolution then
		settings.resolution = { current.resolution.X, current.resolution.Y }
	end
	return { active = current.id, settings = settings, profiles = profiles }
end
function Devices.restore(previous, expected)
	local s = service()
	if expected then
		local now = Devices.snapshot()
		for _, key in ipairs({ "id", "resolution", "dpi", "scaling", "orientation", "starterOrientation" }) do
			if now[key] ~= expected[key] then
				return false,
					("Device %s changed outside the test (%s → %s); current settings preserved."):format(
						key,
						tostring(expected[key]),
						tostring(now[key])
					)
			end
		end
	end
	game:GetService("StarterGui").ScreenOrientation = previous.starterOrientation
	s:SetDeviceAsync(previous.id)
	if previous.id ~= "default" then
		if previous.orientation then
			s:SetOrientationAsync(previous.orientation)
		end
		s:SetResolutionAsync(previous.resolution.X, previous.resolution.Y)
		s:SetPixelDensityAsync(previous.dpi)
		s:SetScalingModeAsync(previous.scaling)
	end
	return true
end
function Devices.apply(args)
	assert(
		type(args) == "table" and type(args.id) == "string",
		"device needs a preset id; list presets with get_studio_state(include_devices=true)"
	)
	local s = service()
	if args.orientation then
		assert(
			table.find({ "Portrait", "LandscapeLeft", "LandscapeRight" }, args.orientation),
			"Unsupported orientation"
		)
		assert(args.id ~= "default" and mobile(s, args.id), "Orientation requires a mobile preset")
	end
	local previous = Devices.snapshot()
	local ok, result = pcall(function()
		s:SetDeviceAsync(args.id)
		if args.orientation then
			-- New clients initialize their orientation from StarterGui, overriding the simulator.
			game:GetService("StarterGui").ScreenOrientation = Enum.ScreenOrientation[args.orientation]
			s:SetOrientationAsync(Enum.ScreenOrientation[args.orientation])
		end
		return Devices.snapshot()
	end)
	if not ok then
		local restored, why = pcall(Devices.restore, previous)
		error(
			tostring(result)
				.. (restored and " (device restored)" or " (device restore failed: " .. tostring(why) .. ")")
		)
	end
	return previous, result
end
return Devices
