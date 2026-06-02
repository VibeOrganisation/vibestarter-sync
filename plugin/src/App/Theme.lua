--[[
	Theming system provided through Roact's context.

	Imposes the VibeStarter "Soft Industrial" palette (warm dark + orange),
	independent of the Studio theme, so the plugin matches the app. Colors are
	mirrored from the app's design tokens (tauri-app/src/styles/tokens.css,
	dark theme).
]]

local ContentProvider = game:GetService("ContentProvider")

local Rojo = script:FindFirstAncestor("Rojo")
local Packages = Rojo.Packages

local Roact = require(Packages.Roact)

local strict = require(script.Parent.Parent.strict)

-- VibeStarter palette (Color3 mirrors of the app's dark-theme tokens).
local ACCENT = Color3.fromRGB(221, 136, 56) -- orange-500, the signature accent
local ACCENT_ON = Color3.fromRGB(20, 16, 12) -- sand-950, text on accent fills
local BG_BASE = Color3.fromRGB(31, 26, 21) -- sand-900, main background
local BG_RAISED = Color3.fromRGB(40, 34, 28) -- sand-800, raised surfaces/cards
local BG_OVERLAY = Color3.fromRGB(35, 30, 24) -- sand-850, overlays/dropdowns
local TEXT_PRIMARY = Color3.fromRGB(242, 237, 229)
local TEXT_SECONDARY = Color3.fromRGB(188, 176, 160)
local TEXT_MUTED = Color3.fromRGB(133, 123, 110) -- sand-500, placeholders/disabled
local BORDER_SUBTLE = Color3.fromRGB(57, 47, 37) -- sand-700
local BORDER_STRONG = Color3.fromRGB(84, 73, 62) -- sand-600
local SUCCESS = Color3.fromRGB(123, 184, 122)
local DANGER = Color3.fromRGB(210, 106, 90)
local WARNING = Color3.fromRGB(217, 179, 107)
local INFO = Color3.fromRGB(110, 158, 201)

local Context = Roact.createContext({})

local StudioProvider = Roact.Component:extend("StudioProvider")

-- Build the fixed VibeStarter theme and store it in state. Same key structure
-- as before so every component that reads `theme.X` keeps working.
function StudioProvider:updateTheme()
	local theme = strict("VibeStarterTheme", {
		Font = {
			Main = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Medium, Enum.FontStyle.Normal),
			Bold = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold, Enum.FontStyle.Normal),
			Thin = Font.new(
				"rbxasset://fonts/families/Montserrat.json",
				Enum.FontWeight.Regular,
				Enum.FontStyle.Normal
			),
			Code = Font.new(
				"rbxasset://fonts/families/Inconsolata.json",
				Enum.FontWeight.Regular,
				Enum.FontStyle.Normal
			),
		},
		TextSize = {
			Body = 15,
			Small = 13,
			Medium = 16,
			Large = 18,
			Code = 16,
		},
		BrandColor = ACCENT,
		BackgroundColor = BG_BASE,
		TextColor = TEXT_PRIMARY,
		SubTextColor = TEXT_SECONDARY,
		Button = {
			Solid = {
				ActionFillColor = Color3.fromRGB(255, 255, 255),
				ActionFillTransparency = 0.8,
				Enabled = {
					TextColor = ACCENT_ON,
					BackgroundColor = ACCENT,
				},
				Disabled = {
					TextColor = ACCENT_ON,
					BackgroundColor = ACCENT,
				},
			},
			Bordered = {
				ActionFillColor = TEXT_PRIMARY,
				ActionFillTransparency = 0.9,
				Enabled = {
					TextColor = TEXT_PRIMARY,
					BorderColor = BORDER_STRONG,
				},
				Disabled = {
					TextColor = TEXT_MUTED,
					BorderColor = BORDER_SUBTLE,
				},
			},
		},
		Checkbox = {
			Active = {
				IconColor = ACCENT_ON,
				BackgroundColor = ACCENT,
			},
			Inactive = {
				IconColor = TEXT_MUTED,
				BorderColor = BORDER_STRONG,
			},
		},
		Dropdown = {
			TextColor = TEXT_PRIMARY,
			BorderColor = BORDER_STRONG,
			BackgroundColor = BG_OVERLAY,
			IconColor = TEXT_MUTED,
		},
		TextInput = {
			Enabled = {
				TextColor = TEXT_PRIMARY,
				PlaceholderColor = TEXT_MUTED,
				BorderColor = BORDER_STRONG,
			},
			Disabled = {
				TextColor = TEXT_SECONDARY,
				PlaceholderColor = TEXT_MUTED,
				BorderColor = BORDER_SUBTLE,
			},
			ActionFillColor = TEXT_PRIMARY,
			ActionFillTransparency = 0.9,
		},
		AddressEntry = {
			TextColor = TEXT_PRIMARY,
			PlaceholderColor = TEXT_MUTED,
		},
		BorderedContainer = {
			BorderColor = BORDER_SUBTLE,
			BackgroundColor = BG_RAISED,
		},
		Spinner = {
			ForegroundColor = ACCENT,
			BackgroundColor = BORDER_SUBTLE,
		},
		Diff = {
			-- Bright fallbacks in case a row isn't updated to the background colors.
			Add = Color3.fromRGB(255, 0, 255),
			Remove = Color3.fromRGB(255, 0, 255),
			Edit = Color3.fromRGB(255, 0, 255),

			Row = TEXT_PRIMARY,
			Warning = WARNING,

			Background = {
				Add = SUCCESS,
				Remove = DANGER,
				Edit = INFO,
				Remain = TEXT_SECONDARY,
			},

			Text = {
				Add = ACCENT_ON,
				Remove = ACCENT_ON,
				Edit = ACCENT_ON,
				Remain = TEXT_PRIMARY,
			},
		},
		ConnectionDetails = {
			ProjectNameColor = TEXT_PRIMARY,
			AddressColor = TEXT_SECONDARY,
			DisconnectColor = TEXT_PRIMARY,
		},
		Settings = {
			DividerColor = BORDER_SUBTLE,
			Navbar = {
				BackButtonColor = TEXT_PRIMARY,
				TextColor = TEXT_PRIMARY,
			},
			Setting = {
				NameColor = TEXT_PRIMARY,
				DescriptionColor = TEXT_SECONDARY,
				UnstableColor = WARNING,
				DebugColor = INFO,
			},
		},
		Header = {
			LogoColor = ACCENT,
			VersionColor = TEXT_MUTED,
		},
		Notification = {
			InfoColor = TEXT_PRIMARY,
			CloseColor = TEXT_SECONDARY,
		},
		ErrorColor = TEXT_PRIMARY,
		ScrollBarColor = BORDER_STRONG,
	})

	self:setState({
		theme = theme,
	})
end

function StudioProvider:init()
	self:updateTheme()

	-- Preload the Fonts so that getTextBoundsAsync won't yield
	local fontAssetIds = {}
	for _, font in self.state.theme.Font do
		table.insert(fontAssetIds, font.Family)
	end
	pcall(ContentProvider.PreloadAsync, ContentProvider, fontAssetIds)
end

function StudioProvider:render()
	return Roact.createElement(Context.Provider, {
		value = self.state.theme,
	}, self.props[Roact.Children])
end

local function with(callback)
	return Roact.createElement(Context.Consumer, {
		render = callback,
	})
end

return {
	StudioProvider = StudioProvider,
	Consumer = Context.Consumer,
	with = with,
}
