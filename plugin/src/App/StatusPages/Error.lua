local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local Theme = require(Plugin.App.Theme)
local Assets = require(Plugin.Assets)
local getTextBoundsAsync = require(Plugin.App.getTextBoundsAsync)

local TextButton = require(Plugin.App.Components.TextButton)
local BorderedContainer = require(Plugin.App.Components.BorderedContainer)
local ScrollingFrame = require(Plugin.App.Components.ScrollingFrame)
local Tooltip = require(Plugin.App.Components.Tooltip)

local e = Roact.createElement

local ERROR_PADDING = Vector2.new(13, 10)

local Error = Roact.Component:extend("Error")

function Error:init()
	self.contentSize, self.setContentSize = Roact.createBinding(Vector2.new(0, 0))
end

function Error:render()
	return Theme.with(function(theme)
		return e(BorderedContainer, {
			size = Roact.joinBindings({
				containerSize = self.props.containerSize,
				contentSize = self.contentSize,
			}):map(function(values)
				local maximumSize = values.containerSize
				maximumSize -= Vector2.new(14, 14) * 2 -- Page padding
				maximumSize -= Vector2.new(0, 40 + 10) -- Button and spacing
				maximumSize -= Vector2.new(0, 28 + 10) -- Heading and spacing

				local outerSize = values.contentSize + ERROR_PADDING * 2

				return UDim2.new(1, 0, 0, math.min(outerSize.Y, maximumSize.Y))
			end),
			transparency = self.props.transparency,
			layoutOrder = self.props.layoutOrder,
		}, {
			ScrollingFrame = e(ScrollingFrame, {
				size = UDim2.new(1, 0, 1, 0),
				contentSize = self.contentSize:map(function(value)
					return value + ERROR_PADDING * 2
				end),
				transparency = self.props.transparency,

				[Roact.Change.AbsoluteSize] = function(object)
					local containerSize = object.AbsoluteSize - ERROR_PADDING * 2

					local textBounds = getTextBoundsAsync(
						self.props.errorMessage,
						theme.Font.Code,
						theme.TextSize.Code,
						containerSize.X
					)

					self.setContentSize(Vector2.new(containerSize.X, textBounds.Y))
				end,
			}, {
				ErrorMessage = e("TextBox", {
					[Roact.Event.InputBegan] = function(rbx, input)
						if input.UserInputType ~= Enum.UserInputType.MouseButton1 then
							return
						end
						rbx.SelectionStart = 0
						rbx.CursorPosition = #rbx.Text + 1
					end,

					Text = self.props.errorMessage,
					TextEditable = false,
					FontFace = theme.Font.Code,
					TextSize = theme.TextSize.Code,
					TextColor3 = theme.ErrorColor,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextYAlignment = Enum.TextYAlignment.Top,
					TextTransparency = self.props.transparency,
					TextWrapped = true,
					ClearTextOnFocus = false,
					BackgroundTransparency = 1,
					Size = UDim2.new(1, 0, 1, 0),
				}),

				Padding = e("UIPadding", {
					PaddingLeft = UDim.new(0, ERROR_PADDING.X),
					PaddingRight = UDim.new(0, ERROR_PADDING.X),
					PaddingTop = UDim.new(0, ERROR_PADDING.Y),
					PaddingBottom = UDim.new(0, ERROR_PADDING.Y),
				}),
			}),
		})
	end)
end

local ErrorPage = Roact.Component:extend("ErrorPage")

function ErrorPage:init()
	self.containerSize, self.setContainerSize = Roact.createBinding(Vector2.new(0, 0))
end

function ErrorPage:render()
	return Theme.with(function(theme)
		return e("Frame", {
			Size = UDim2.new(1, 0, 1, 0),
			BackgroundTransparency = 1,

			[Roact.Change.AbsoluteSize] = function(object)
				self.setContainerSize(object.AbsoluteSize)
			end,
		}, {
			Heading = e("Frame", {
				Size = UDim2.new(1, 0, 0, 28),
				BackgroundTransparency = 1,
				LayoutOrder = 1,
			}, {
				Layout = e("UIListLayout", {
					VerticalAlignment = Enum.VerticalAlignment.Center,
					FillDirection = Enum.FillDirection.Horizontal,
					SortOrder = Enum.SortOrder.LayoutOrder,
					Padding = UDim.new(0, 8),
				}),

				Icon = e("ImageLabel", {
					Image = Assets.Images.Icons.Warning,
					ImageColor3 = theme.WarningColor,
					ImageTransparency = self.props.transparency,
					Size = UDim2.new(0, 24, 0, 24),
					BackgroundTransparency = 1,
					LayoutOrder = 1,
				}),

				Title = e("TextLabel", {
					Text = "Connection error",
					FontFace = theme.Font.Bold,
					TextSize = theme.TextSize.Large,
					TextColor3 = theme.TextColor,
					TextXAlignment = Enum.TextXAlignment.Left,
					TextTransparency = self.props.transparency,
					Size = UDim2.new(1, -32, 1, 0),
					BackgroundTransparency = 1,
					LayoutOrder = 2,
				}),
			}),

			Error = e(Error, {
				errorMessage = self.state.errorMessage,
				containerSize = self.containerSize,
				transparency = self.props.transparency,
				layoutOrder = 2,
			}),

			Buttons = e("Frame", {
				Size = UDim2.new(1, 0, 0, 40),
				LayoutOrder = 3,
				BackgroundTransparency = 1,
			}, {
				Close = e(TextButton, {
					text = "Okay",
					style = "Bordered",
					fillWidth = true,
					height = 40,
					transparency = self.props.transparency,
					layoutOrder = 1,
					onClick = self.props.onClose,
				}, {
					Tip = e(Tooltip.Trigger, {
						text = "Dismiss message",
					}),
				}),
			}),

			Layout = e("UIListLayout", {
				VerticalAlignment = Enum.VerticalAlignment.Center,
				FillDirection = Enum.FillDirection.Vertical,
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 10),
			}),

			Padding = e("UIPadding", {
				PaddingLeft = UDim.new(0, 14),
				PaddingRight = UDim.new(0, 14),
				PaddingTop = UDim.new(0, 14),
				PaddingBottom = UDim.new(0, 14),
			}),
		})
	end)
end

function ErrorPage.getDerivedStateFromProps(props)
	-- If errorMessage ever gets removed from props, make sure we still have the
	-- property! The component still needs to have its data for it to be properly
	-- animated out without the labels changing.

	return {
		errorMessage = props.errorMessage,
	}
end

return ErrorPage
