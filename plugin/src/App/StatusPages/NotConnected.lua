local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local Theme = require(Plugin.App.Theme)

local BrandBadge = require(Plugin.App.Components.BrandBadge)
local TextButton = require(Plugin.App.Components.TextButton)
local Tooltip = require(Plugin.App.Components.Tooltip)
local VersionTag = require(Plugin.App.Components.VersionTag)

local e = Roact.createElement

local NotConnectedPage = Roact.Component:extend("NotConnectedPage")

function NotConnectedPage:render()
	-- No address entry: VibeStarter always serves on localhost:34872, so the
	-- host/port are fixed (Config defaults) and not user-editable.
	--
	-- The page is a single centered hero so the brand reads as intentional
	-- (not a left-floating logo): badge -> title -> hint -> one big Connect
	-- button that fills the panel width.
	return Theme.with(function(theme)
		local transparency = self.props.transparency

		return Roact.createFragment({
			Hero = e("Frame", {
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

				Badge = e(BrandBadge, {
					size = 64,
					transparency = transparency,
					layoutOrder = 1,
				}),

				Text = e("Frame", {
					Size = UDim2.new(1, 0, 0, 0),
					AutomaticSize = Enum.AutomaticSize.Y,
					BackgroundTransparency = 1,
					LayoutOrder = 2,
				}, {
					Layout = e("UIListLayout", {
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
						FillDirection = Enum.FillDirection.Vertical,
						SortOrder = Enum.SortOrder.LayoutOrder,
						Padding = UDim.new(0, 4),
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
						LayoutOrder = 1,
					}),

					Hint = e("TextLabel", {
						Text = "Ready to sync your project",
						FontFace = theme.Font.Thin,
						TextSize = theme.TextSize.Body,
						TextColor3 = theme.SubTextColor,
						TextXAlignment = Enum.TextXAlignment.Center,
						TextWrapped = true,
						TextTransparency = transparency,
						Size = UDim2.new(1, 0, 0, 0),
						AutomaticSize = Enum.AutomaticSize.Y,
						BackgroundTransparency = 1,
						LayoutOrder = 2,
					}),
				}),

				Connect = e(TextButton, {
					text = "Connect",
					style = "Solid",
					fillWidth = true,
					height = 40,
					transparency = transparency,
					layoutOrder = 3,
					onClick = self.props.onConnect,
				}, {
					Tip = e(Tooltip.Trigger, {
						text = "Connect to the VibeStarter Sync server",
					}),
				}),
			}),

			Version = e(VersionTag, {
				transparency = transparency,
				position = UDim2.new(0.5, 0, 1, -8),
				anchorPoint = Vector2.new(0.5, 1),
			}),

			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, 24),
				PaddingRight = UDim.new(0, 24),
			}),
		})
	end)
end

return NotConnectedPage
