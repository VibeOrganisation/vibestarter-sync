local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local Theme = require(Plugin.App.Theme)

local BrandBadge = require(Plugin.App.Components.BrandBadge)
local Spinner = require(Plugin.App.Components.Spinner)

local e = Roact.createElement

local ConnectingPage = Roact.Component:extend("ConnectingPage")

function ConnectingPage:render()
	-- Mirrors the NotConnected hero so the transition reads as the same screen
	-- "working": badge and title stay put, the button is replaced by a spinner
	-- and a status line.
	return Theme.with(function(theme)
		local transparency = self.props.transparency

		local statusText = if type(self.props.text) == "string" and #self.props.text > 0
			then self.props.text
			else "Connecting…"

		return e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Position = UDim2.new(0.5, 0, 0.5, 0),
			AnchorPoint = Vector2.new(0.5, 0.5),
			BackgroundTransparency = 1,
		}, {
			Layout = e("UIListLayout", {
				HorizontalAlignment = Enum.HorizontalAlignment.Center,
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 16),
			}),

			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, 24),
				PaddingRight = UDim.new(0, 24),
			}),

			Badge = e(BrandBadge, {
				size = 64,
				transparency = transparency,
				layoutOrder = 1,
			}),

			Title = e("TextLabel", {
				Text = "VibeStarter Sync",
				FontFace = theme.Font.Bold,
				TextSize = theme.TextSize.Large,
				TextColor3 = theme.TextColor,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextTransparency = transparency,
				Size = UDim2.new(1, 0, 0, theme.TextSize.Large + 2),
				BackgroundTransparency = 1,
				LayoutOrder = 2,
			}),

			Spinner = e(Spinner, {
				transparency = transparency,
				layoutOrder = 3,
			}),

			Status = e("TextLabel", {
				Text = statusText,
				FontFace = theme.Font.Thin,
				TextSize = theme.TextSize.Body,
				TextColor3 = theme.SubTextColor,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextWrapped = true,
				RichText = true,
				TextTransparency = transparency,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 4,
			}),
		})
	end)
end

return ConnectingPage
