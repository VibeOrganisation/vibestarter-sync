local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local TextButton = require(Plugin.App.Components.TextButton)
local Header = require(Plugin.App.Components.Header)
local Tooltip = require(Plugin.App.Components.Tooltip)

local e = Roact.createElement

local NotConnectedPage = Roact.Component:extend("NotConnectedPage")

function NotConnectedPage:render()
	-- No address entry: VibeStarter always serves on localhost:34872, so the
	-- host/port are fixed (Config defaults) and not user-editable.
	return Roact.createFragment({
		Header = e(Header, {
			transparency = self.props.transparency,
			layoutOrder = 1,
		}),

		Buttons = e("Frame", {
			Size = UDim2.new(1, 0, 0, 34),
			LayoutOrder = 2,
			BackgroundTransparency = 1,
			ZIndex = 2,
		}, {
			Connect = e(TextButton, {
				text = "Connect",
				style = "Solid",
				transparency = self.props.transparency,
				layoutOrder = 1,
				onClick = self.props.onConnect,
			}, {
				Tip = e(Tooltip.Trigger, {
					text = "Connect to the VibeStarter Sync server",
				}),
			}),

			Layout = e("UIListLayout", {
				HorizontalAlignment = Enum.HorizontalAlignment.Right,
				FillDirection = Enum.FillDirection.Horizontal,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 10),
			}),
		}),

		Layout = e("UIListLayout", {
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0, 10),
		}),

		Padding = e("UIPadding", {
			PaddingLeft = UDim.new(0, 20),
			PaddingRight = UDim.new(0, 20),
		}),
	})
end

return NotConnectedPage
