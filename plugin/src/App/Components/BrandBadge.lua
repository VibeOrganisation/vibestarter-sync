local Rojo = script:FindFirstAncestor("Rojo")
local Plugin = Rojo.Plugin
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local Theme = require(Plugin.App.Theme)
local Assets = require(Plugin.Assets)

local SlicedImage = require(script.Parent.SlicedImage)

local e = Roact.createElement

-- A neutral rounded tile that frames the (already colored) brand logo like an
-- app icon. Shared by the hero screens so the mark looks identical everywhere.
local function BrandBadge(props)
	local size = props.size or 64
	local logoSize = props.logoSize or math.floor(size * 0.62 + 0.5)

	return Theme.with(function(theme)
		return e(SlicedImage, {
			slice = Assets.Slices.RoundedBackground,
			color = theme.BorderedContainer.BackgroundColor,
			transparency = props.transparency,

			size = UDim2.new(0, size, 0, size),
			position = props.position,
			anchorPoint = props.anchorPoint,
			layoutOrder = props.layoutOrder,
		}, {
			Border = e(SlicedImage, {
				slice = Assets.Slices.RoundedBorder,
				color = theme.BorderedContainer.BorderColor,
				transparency = props.transparency,

				size = UDim2.new(1, 0, 1, 0),
				zIndex = 1,
			}),

			Logo = e("ImageLabel", {
				Image = Assets.Images.Logo,
				ImageTransparency = props.transparency,
				ScaleType = Enum.ScaleType.Fit,

				Size = UDim2.new(0, logoSize, 0, logoSize),
				Position = UDim2.new(0.5, 0, 0.5, 0),
				AnchorPoint = Vector2.new(0.5, 0.5),

				ZIndex = 2,
				BackgroundTransparency = 1,
			}),
		})
	end)
end

return BrandBadge
