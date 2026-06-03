local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local Theme = require(Plugin.App.Theme)
local Config = require(Plugin.Config)

local e = Roact.createElement

-- A quiet "vX.Y.Z" label so it's always clear which plugin build is loaded.
-- Reads the single source of truth (Config.version <- plugin/Version.txt).
local function VersionTag(props)
	local v = Config.version
	local text = ("v%d.%d.%d%s"):format(v[1], v[2], v[3], v[4] or "")

	return Theme.with(function(theme)
		return e("TextLabel", {
			Text = text,
			FontFace = theme.Font.Thin,
			TextSize = theme.TextSize.Small,
			TextColor3 = theme.Header.VersionColor,
			TextXAlignment = props.textXAlignment or Enum.TextXAlignment.Center,
			TextTransparency = props.transparency,

			Size = props.size or UDim2.new(1, 0, 0, theme.TextSize.Small + 2),
			Position = props.position,
			AnchorPoint = props.anchorPoint,
			LayoutOrder = props.layoutOrder,

			BackgroundTransparency = 1,
		})
	end)
end

return VersionTag
