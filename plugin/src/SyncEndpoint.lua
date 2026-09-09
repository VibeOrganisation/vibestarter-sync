--[[
	The sync endpoint VibeStarter pushed to *this* Studio window.

	# Why this module exists

	`Tools/` and `App/` are two halves of this plugin that never spoke to each
	other: the tool channel answers VibeStarter's calls, the app syncs a place,
	and neither needed anything the other had. This is the one fact both need.

	VibeStarter can hold several projects open at once, and each one gets its
	own `rojo serve` on its own host port. A window has no way of guessing
	which: the port is compiled into `Config.defaultPort`, and the number is
	right for exactly one project. So the app — which knows, per attached
	window, the project its place marker names — pushes it here
	(`set_sync_endpoint`), the tool channel records it, and the app half reads
	it.

	# Why it is in memory and nowhere else

	Two measured reasons, both of which make `plugin:SetSetting` the wrong
	store for it:

	- the plugin's settings are **global to the plugin** and cached **per
	  window at load**, so two windows cannot hold two different values, and a
	  window would not see what another wrote;
	- a place that was never published has `PlaceId == 0`, so there is no key
	  to file one under either.

	A pushed endpoint is per window and per app run, which is exactly the
	lifetime of this module.

	# What happens without a push

	Nothing changes. `getHostAndPort` falls back to `Config.defaultPort`
	(34872), which is the first slot VibeStarter allocates, so one open project
	needs no push at all — and neither does a plugin from an install that
	predates this.
]]

local SyncEndpoint = {}

-- Fired after `set`, with no argument: the subscriber reads `get()` rather than
-- a payload, so a push that lands twice in a row cannot be applied out of
-- order.
local bindable = Instance.new("BindableEvent")

local current = nil

SyncEndpoint.Changed = bindable.Event

-- The endpoint pushed to this window, or nil when nothing has been pushed.
-- `port` is a string, because that is what the app half's host/port bindings
-- hold and what its URL formatting expects.
function SyncEndpoint.get(): { host: string, port: string, projectId: string? }?
	return current
end

-- Record what VibeStarter pushed. Returns true when it was news.
--
-- Fires whether or not anything is listening: a **playtest** DataModel runs the
-- tool channel and has no app half at all, and the handler must succeed there
-- having done nothing but remember.
function SyncEndpoint.set(host: string, port: string, projectId: string?): boolean
	if
		current ~= nil
		and current.host == host
		and current.port == port
		and current.projectId == projectId
	then
		return false
	end

	current = { host = host, port = port, projectId = projectId }
	bindable:Fire()
	return true
end

return SyncEndpoint
