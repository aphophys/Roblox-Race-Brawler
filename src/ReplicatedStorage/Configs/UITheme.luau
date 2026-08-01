--!strict
--[[
	UITheme
	Kid-friendly glossy candy palette + shared UI constants. Runtime scripts
	(controllers that create/tween UI) should read colors from here rather
	than hardcoding them, so the palette only needs to change in one place.

	The StarterGui.MainHUD tree in default.project.json hardcodes matching
	RGB values in its $properties (JSON can't reference Luau values) — if
	you change a color here, update the matching entry there too. Each
	$properties block in the project.json is commented with which UITheme
	key it mirrors.
]]

export type UIThemeType = {
	Primary: Color3, -- sky blue: standings, general panels
	Secondary: Color3, -- orange: action/pose buttons
	Accent: Color3, -- purple: settings/menu
	Success: Color3, -- green: good effects, positive feedback
	Danger: Color3, -- red: bad effects, jump/impact buttons
	GoldCurrency: Color3,
	FanCurrency: Color3,
	PanelBackground: Color3,
	TextPrimary: Color3,
	GlossHighlight: Color3, -- top-of-button gradient color for the glossy sheen
	CornerRadius: UDim,
	StrokeThickness: number,
}

local UITheme: UIThemeType = {
	Primary = Color3.fromRGB(77, 171, 247),
	Secondary = Color3.fromRGB(255, 138, 61),
	Accent = Color3.fromRGB(178, 102, 255),
	Success = Color3.fromRGB(76, 217, 100),
	Danger = Color3.fromRGB(255, 82, 82),
	GoldCurrency = Color3.fromRGB(255, 199, 44),
	FanCurrency = Color3.fromRGB(255, 105, 180),
	PanelBackground = Color3.fromRGB(255, 255, 255),
	TextPrimary = Color3.fromRGB(45, 45, 65),
	GlossHighlight = Color3.fromRGB(255, 255, 255),
	CornerRadius = UDim.new(0, 16),
	StrokeThickness = 2,
}

return UITheme
