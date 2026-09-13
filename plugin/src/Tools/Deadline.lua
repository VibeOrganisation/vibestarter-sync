-- Run a handler serially, but release the channel if its coroutine never resumes
-- (for example WaitForChild without a timeout). The host's timeout alone cannot
-- stop a suspended Luau handler and leaves this plugin unable to poll again.
local Deadline = {}
local deadlines = setmetatable({}, { __mode = "k" })

function Deadline.remaining()
	local ending = deadlines[coroutine.running()]
	return ending and math.max(0, ending - os.clock()) or nil
end

function Deadline.run(seconds, handler, ...)
	local signal = Instance.new("BindableEvent")
	local results = nil
	local timedOut = false
	local arguments = table.pack(...)
	local worker = task.spawn(function()
		local thread = coroutine.running()
		deadlines[thread] = os.clock() + seconds
		results = table.pack(pcall(handler, table.unpack(arguments, 1, arguments.n)))
		deadlines[thread] = nil
		signal:Fire()
	end)
	-- task.spawn may finish synchronously. Do not wait for a signal already fired.
	if results ~= nil then
		signal:Destroy()
		return table.unpack(results, 1, results.n)
	end
	local timer = task.delay(seconds, function()
		if results ~= nil then
			return
		end
		task.cancel(worker)
		deadlines[worker] = nil
		timedOut = true
		results = table.pack(
			false,
			"STUDIO_TOOL_TIMEOUT: the tool exceeded its execution budget and its waiting coroutine was cancelled. "
				.. "Changes already made are not rolled back; inspect the place before retrying. "
				.. "Use bounded waits and smaller operations. The Studio channel remains available."
		)
		signal:Fire()
	end)
	if results == nil then
		signal.Event:Wait()
	end
	if not timedOut and coroutine.status(timer) ~= "dead" then
		task.cancel(timer)
	end
	signal:Destroy()
	return table.unpack(results, 1, results.n)
end

return Deadline
