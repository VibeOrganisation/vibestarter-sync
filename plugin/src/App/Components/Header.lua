local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local Theme = require(Plugin.App.Theme)
local Assets = require(Plugin.Assets)

local e = Roact.createElement

local function Header(props)
	return Theme.with(function(theme)
		return e("Frame", {
			Size = UDim2.new(1, 0, 0, 32),
			LayoutOrder = props.layoutOrder,
			BackgroundTransparency = 1,
		}, {
			-- The brand asset already carries its own colors, so it is not tinted.
			-- Fit keeps its aspect ratio whatever the asset's shape.
			Logo = e("ImageLabel", {
				Image = Assets.Images.Logo,
				ImageTransparency = props.transparency,
				ScaleType = Enum.ScaleType.Fit,

				Size = UDim2.new(0, 28, 0, 28),

				LayoutOrder = 1,
				BackgroundTransparency = 1,
			}),

			Wordmark = e("TextLabel", {
				Text = "VibeStarter Sync",
				FontFace = theme.Font.Bold,
				TextSize = theme.TextSize.Large,
				TextColor3 = theme.TextColor,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextTransparency = props.transparency,
				BackgroundTransparency = 1,

				Size = UDim2.new(0, 0, 1, 0),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = 2,
			}),

			Layout = e("UIListLayout", {
				VerticalAlignment = Enum.VerticalAlignment.Center,
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 10),
			}),
		})
	end)
end

return Header
