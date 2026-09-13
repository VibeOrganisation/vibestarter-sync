-- Native playtest ownership lives in the edit plugin, not in window focus.
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local Playtest = {}
local active = nil
local epoch = HttpService:GenerateGUID(false)
local service = nil

local function studio()
	if service then
		return service
	end
	local ok, value = pcall(function()
		return game:GetService("StudioTestService")
	end)
	assert(ok and value, "STUDIO_NATIVE_UNAVAILABLE: StudioTestService is unavailable; update Studio.")
	service = value
	service:GetPropertyChangedSignal("EditModeActive"):Connect(function()
		epoch = HttpService:GenerateGUID(false)
		if active and not active.finished and not service.EditModeActive and not active.runningEpoch then
			active.runningEpoch = epoch
		end
	end)
	return service
end

function Playtest.state()
	local s = studio()
	local edit = s.EditModeActive
	local owned = active and not active.finished
	return {
		-- Multiplayer runs in child processes while the original window may stay in Edit.
		running = not edit or (owned and active.players > 1 and active.phase == "running") or false,
		phase = owned and active.phase
			or (edit and "edit" or (active and active.finishedEpoch == epoch and "transitioning" or "external")),
		mode = owned and active.mode or nil,
		testId = owned and active.id or nil,
		owner = owned and active.owner or nil,
		epoch = epoch,
		error = active and active.error or nil,
		players = owned and active.players or nil,
		deviceRestoreError = active and active.deviceRestoreError or nil,
		finishedTestId = active and active.finished and active.id or nil,
	}
end

function Playtest.checkEpoch(args)
	if args.__nativeEpoch ~= nil then
		assert(Playtest.state().epoch == args.__nativeEpoch, "STUDIO_SESSION_CHANGED: Session changed; action refused.")
	end
end

function Playtest.start(args)
	local s = studio()
	assert(type(args.testId) == "string" and type(args.owner) == "string", "Missing playtest identity")
	assert(args.mode == "play" or args.mode == "run", "mode must be play or run")
	assert(
		s.EditModeActive and (not active or active.finished),
		"STUDIO_BUSY: A playtest or transition is already active. Let the user finish; no action was sent."
	)
	local players = args.players or 1
	assert(
		type(players) == "number" and players % 1 == 0 and players >= 1 and players <= 8,
		"players must be an integer from 1 to 8"
	)
	assert(args.mode ~= "run" or (players == 1 and args.device == nil), "Run cannot simulate clients or devices")
	local record = {
		id = args.testId,
		owner = args.owner,
		mode = args.mode,
		players = players,
		phase = "starting",
		finished = false,
	}
	active = record
	task.spawn(function()
		local ok, result = pcall(function()
			if args.device then
				record.previousDevice, record.testDevice = require(script.Parent.Devices).apply(args.device)
			end
			assert(s.EditModeActive, "STUDIO_BUSY: A manual test started during device setup; it was preserved.")
			local testArgs = { vibeStarterTestId = record.id, vibeStarterOwner = record.owner }
			record.phase = "running"
			if record.mode == "run" then
				return s:ExecuteRunModeAsync(testArgs)
			end
			if record.players > 1 then
				return s:ExecuteMultiplayerTestAsync(record.players, testArgs)
			end
			return s:ExecutePlayModeAsync(testArgs)
		end)
		record.phase = "restoring"
		-- Execute*Async can return before EditModeActive changes after EndTest.
		-- Wait for that transition, but never follow a replacement test.
		local restoreDeadline = os.clock() + 10
		while
			record.previousDevice
			and not s.EditModeActive
			and epoch == record.runningEpoch
			and os.clock() < restoreDeadline
		do
			task.wait(0.05)
		end
		if record.previousDevice and not s.EditModeActive then
			record.deviceRestoreError = "Another test is active; its device settings were preserved."
		elseif record.previousDevice then
			local restored, result, why =
				pcall(require(script.Parent.Devices).restore, record.previousDevice, record.testDevice)
			if not restored or result ~= true then
				record.deviceRestoreError = tostring(why or result)
			end
		end
		record.finishedEpoch = epoch
		record.finished = true
		record.phase = ok and (result == nil and "interrupted" or "completed") or "failed"
		record.error = not ok and tostring(result) or nil
	end)
	return Playtest.state()
end

function Playtest.authorizeStop(args)
	local state = Playtest.state()
	if not state.running and state.phase == "edit" then
		return state
	end
	assert(
		state.testId == args.testId and state.owner == args.owner and state.testId ~= nil,
		"STUDIO_NOT_OWNED: This test is not the requested agent test. No Stop was sent."
	)
	return state
end

function Playtest.stopServer(args)
	assert(RunService:IsServer(), "Stop must run in the test server")
	local s = studio()
	local current = s:GetTestArgs()
	assert(
		type(current) == "table"
			and current.vibeStarterTestId == args.testId
			and current.vibeStarterOwner == args.owner
			and type(args.testId) == "string",
		"STUDIO_STALE_TEST: The test identity changed. No Stop was sent."
	)
	task.delay(0.1, function()
		local latest = s:GetTestArgs()
		if latest and latest.vibeStarterTestId == args.testId and latest.vibeStarterOwner == args.owner then
			s:EndTest({ vibeStarterTestId = args.testId, status = "stopped" })
		end
	end)
	return { stopRequested = true, testId = args.testId }
end

return Playtest
