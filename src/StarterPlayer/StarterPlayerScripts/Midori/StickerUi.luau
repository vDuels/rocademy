--!strict
-- Small Hi-Fi Rush / Persona sticker kit for popup panels (DJ picker, door panel). SCALE ONLY: outlines are
-- black frames behind, shadows are hard offset copies, LuckiestGuy text scaled to its box.
local StickerUi = {}

StickerUi.RED = Color3.fromRGB(225, 18, 40)
StickerUi.BLACK = Color3.new(0, 0, 0)
StickerUi.WHITE = Color3.new(1, 1, 1)
StickerUi.CARD = Color3.fromRGB(36, 33, 46)
StickerUi.WELL = Color3.fromRGB(16, 14, 22)
StickerUi.DIM = Color3.fromRGB(120, 115, 135)
StickerUi.YELLOW = Color3.fromRGB(255, 220, 40)
StickerUi.GOOD = Color3.fromRGB(90, 230, 120)
StickerUi.FONT = Enum.Font.LuckiestGuy

function StickerUi.new(class: string, props: { [string]: any }, parent: Instance?): any
	local o = Instance.new(class)
	if o:IsA("GuiObject") then
		o.BorderSizePixel = 0
		o.BackgroundTransparency = 1
	end
	for k, v in props do
		(o :: any)[k] = v
	end
	o.Parent = parent
	return o
end
local new = StickerUi.new

-- Hard black drop shadow + black outline + `color` fill. Returns (outer, fill). `shadow` = the drop shadow's
-- offset as a share of the size (tall things want a smaller Y).
function StickerUi.sticker(parent: Instance, color: Color3, props: { [string]: any }, border: Vector2, shadow: Vector2?): (Frame, Frame)
	local outer = new("Frame", props, parent)
	local s = shadow or Vector2.new(0.015, 0.06)
	new("Frame", { BackgroundTransparency = 0, BackgroundColor3 = StickerUi.BLACK, Size = UDim2.fromScale(1, 1), Position = UDim2.fromScale(s.X, s.Y), ZIndex = 0 }, outer)
	new("Frame", { BackgroundTransparency = 0, BackgroundColor3 = StickerUi.BLACK, Size = UDim2.fromScale(1, 1), ZIndex = 1 }, outer)
	local fill = new("Frame", {
		Name = "Fill", BackgroundTransparency = 0, BackgroundColor3 = color, ZIndex = 2,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1 - border.X * 2, 1 - border.Y * 2),
	}, outer)
	return outer, fill
end

function StickerUi.label(parent: Instance, text: string, color: Color3, props: { [string]: any }): TextLabel
	local p = table.clone(props)
	p.Font, p.TextScaled, p.Text, p.TextColor3, p.ZIndex = StickerUi.FONT, true, text, color, 4
	return new("TextLabel", p, parent)
end

-- A clickable sticker with a centred label. Returns (outer, fill, label, button).
function StickerUi.button(parent: Instance, text: string, color: Color3, textColor: Color3, props: { [string]: any }): (Frame, Frame, TextLabel, TextButton)
	local outer, fill = StickerUi.sticker(parent, color, props, Vector2.new(0.02, 0.08))
	local l = StickerUi.label(fill, text, textColor, { Size = UDim2.fromScale(0.9, 0.7), Position = UDim2.fromScale(0.05, 0.15) })
	local b = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, outer)
	return outer, fill, l, b
end

return StickerUi
