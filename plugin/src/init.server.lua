if not plugin then
	return
end

-- Studio loads every plugin into the PlayServer and PlayClient datamodels that
-- a playtest creates, not just into Edit. A sync plugin has nothing to do
-- there: the only feature that would justify it is autoConnectPlaytestServer,
-- and this fork has no settings UI to turn it on (see Settings.lua).
--
-- Measured on a client capture: 39 playtests in one session, so ~78 loads of
-- Roact and the whole app for nothing. On a machine under load those take
-- 15-24 s each and trip Studio's plugin watchdog, which then names whichever
-- plugin happens to hold the main thread — usually this one, because it is the
-- heaviest loaded. See docs/diagnostic-plugin-watchdog-studio-2026-08-10.md.
--
-- The setting is read straight off the plugin store rather than through
-- Settings.lua, which requires Roact — the very cost this guard exists to
-- avoid. Key format matches Settings.lua ("Rojo_" .. name); `~= true` covers
-- both `false` and a never-written nil.
--
-- pcall, because the settings store touches the disk, and disk is exactly what
-- is slow on the machines this guard exists for (10-12 s for small reads on the
-- 2026-08-10 capture). Only a playtest datamodel ever reaches this line — the
-- Edit path short-circuits on IsRunning() — and a read we cannot make means the
-- same as `false`: this fork has no UI to turn the feature on, so not loading
-- is both the safe direction and the almost-always correct one.
if game:GetService("RunService"):IsRunning() then
	local ok, autoConnect = pcall(plugin.GetSetting, plugin, "Rojo_autoConnectPlaytestServer")
	if not ok or autoConnect ~= true then
		return
	end
end

local Rojo = script:FindFirstAncestor("Rojo")
local Packages = Rojo.Packages

local Log = require(Packages.Log)
local Roact = require(Packages.Roact)

local Settings = require(script.Settings)
local Config = require(script.Config)
local App = require(script.App)

Log.setLogLevelThunk(function()
	return Log.Level[Settings:get("logLevel")] or Log.Level.Info
end)

local app = Roact.createElement(App, {
	plugin = plugin,
})
local tree = Roact.mount(app, game:GetService("CoreGui"), "Rojo UI")

plugin.Unloading:Connect(function()
	Roact.unmount(tree)
end)

if Config.isDevBuild then
	local TestEZ = require(script.Parent.TestEZ)

	require(script.runTests)(TestEZ)
end
