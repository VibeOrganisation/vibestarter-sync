local Error = {}
Error.__index = Error

Error.Kind = {
	HttpNotEnabled = {
		message = "VibeStarter Sync needs HTTP requests, which are turned off for this place.\n"
			.. "Open Game Settings from the 'Home' tab of Studio and enable 'Allow HTTP Requests' under Security.",
	},
	ConnectFailed = {
		message = "Couldn't reach VibeStarter.\n"
			.. "The app may have closed or stopped syncing this project - reopen it and start syncing to resume.",
	},
	Timeout = {
		message = "HTTP request timed out.",
	},
	Unknown = {
		message = "Unknown HTTP error: {{message}}",
	},
}

setmetatable(Error.Kind, {
	__index = function(_, key)
		error(("%q is not a valid member of Http.Error.Kind"):format(tostring(key)), 2)
	end,
})

function Error.new(type, extraMessage)
	extraMessage = extraMessage or ""
	local message = type.message:gsub("{{message}}", extraMessage)

	local err = {
		type = type,
		message = message,
	}

	setmetatable(err, Error)

	return err
end

function Error:__tostring()
	return self.message
end

--[[
	This method shouldn't have to exist. Ugh.
]]
function Error.fromRobloxErrorString(message)
	local lower = message:lower()

	if lower:find("^http requests are not enabled") then
		return Error.new(Error.Kind.HttpNotEnabled)
	end

	if lower:find("^httperror: timedout") then
		return Error.new(Error.Kind.Timeout)
	end

	-- Every way "nothing is listening at the other end" reaches us. `netfail` is
	-- the one Roblox actually returns most of the time when a local port is
	-- closed, and it used to fall through to Unknown — which is how a closed
	-- VibeStarter app surfaced as "Unknown HTTP error: HttpError: NetFail".
	-- `dnsresolve` is the same story for a host name that no longer resolves:
	-- nothing the user can act on differently, so it shares the message.
	-- TLS failures deliberately stay out of this bucket — there the server IS
	-- answering, and "reopen the app" would be the wrong advice.
	if
		lower:find("^httperror: connectfail")
		or lower:find("^httperror: netfail")
		or lower:find("^httperror: dnsresolve")
	then
		return Error.new(Error.Kind.ConnectFailed)
	end

	return Error.new(Error.Kind.Unknown, message)
end

function Error.fromResponse(response)
	local lower = (response.body or ""):lower()
	if response.code == 408 or response.code == 504 or lower:find("timed? ?out") then
		return Error.new(Error.Kind.Timeout)
	end

	return Error.new(Error.Kind.Unknown, string.format("%s: %s", tostring(response.code), tostring(response.body)))
end

return Error
