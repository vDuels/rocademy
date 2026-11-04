--!strict
-- Hi-Fi Rush / Persona popup card (user, 2026-10-27; matches the HUD): a small black slanted tag over a big
-- LuckiestGuy title with a fat black outline and a hard drop shadow, on a red slash that wipes in behind it.
-- show(title) slides it in from `away` and slams it down; hide() slides it back out to `away`. Fits the screen (scales with viewport height).
-- Used by LocationController (top centre) and MusicController (middle right).
local TweenService = game:GetService("TweenService")
local TextService = game:GetService("TextService")

local FONT = Enum.Font.LuckiestGuy
local RED = Color3.fromRGB(230, 30, 45)
local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local SHADOW = Vector2.new(5, 6)

local Sticker = {}
Sticker.__index = Sticker

export type Options = {
	parent: Instance,
	tag: string, -- the small label, e.g. "LOCATION"
	anchor: Vector2, -- where on the card `position` is
	position: UDim2,
	size: number, -- title text size at 720p
	away: Vector2, -- offscreen offset (px): show() slides in from here, hide() slides back out to it
}

local function label(parent: Instance, size: number, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = FONT
	l.TextSize = size
	l.TextColor3 = color
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextYAlignment = Enum.TextYAlignment.Center
	l.Parent = parent
	return l
end

local function box(parent: Instance, color: Color3): Frame
	local f = Instance.new("Frame")
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

function Sticker.new(o: Options)
	local self = setmetatable({}, Sticker) :: any
	self.o = o
	self.gen = 0

	-- holder: screen fit (its own UIScale); card: the slam (a second UIScale only stacks on a separate frame)
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	-- Hidden until show(): a 0-size CanvasGroup can't render as a group, so Roblox draws its children raw
	-- and GroupTransparency is ignored (bug, 2026-10-27: tag boxes left on screen at join).
	holder.Visible = false
	holder.AnchorPoint = o.anchor
	holder.Position = o.position
	holder.Parent = o.parent
	local fit = Instance.new("UIScale")
	fit.Parent = holder
	local function refit()
		local cam = workspace.CurrentCamera
		local vpY = if cam then cam.ViewportSize.Y else 720
		fit.Scale = math.clamp(vpY / 720, 0.55, 1.2)
	end
	refit()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refit)
	end

	local card = Instance.new("CanvasGroup")
	card.BackgroundTransparency = 1
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.Size = UDim2.fromScale(1, 1)
	card.GroupTransparency = 1
	card.Rotation = -3
	card.Parent = holder
	local slam = Instance.new("UIScale")
	slam.Parent = card

	local s = o.size
	self.slashShadow = box(card, BLACK)
	self.slash = box(card, RED)
	self.tagBox = box(card, BLACK)
	self.tagBox.Rotation = -4
	self.tag = label(self.tagBox, math.floor(s * 0.4), WHITE)
	self.tag.Text = o.tag
	self.tag.TextXAlignment = Enum.TextXAlignment.Center
	self.tag.Size = UDim2.fromScale(1, 1)
	self.titleShadow = label(card, s, BLACK)
	self.title = label(card, s, WHITE)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = math.max(3, s / 12)
	stroke.Color = BLACK
	stroke.LineJoinMode = Enum.LineJoinMode.Miter
	stroke.Parent = self.title
	local shadowStroke = stroke:Clone()
	shadowStroke.Parent = self.titleShadow

	self.holder = holder
	self.card = card
	self.scale = slam
	return self
end

-- Lays the card out for `title` (sized to the text) and slams it in.
function Sticker.show(self: any, title: string)
	local o: Options = self.o
	local s = o.size
	local text = string.upper(title)
	local textW = TextService:GetTextSize(text, s, FONT, Vector2.new(1e4, 1e4)).X
	local tagW = TextService:GetTextSize(o.tag, math.floor(s * 0.4), FONT, Vector2.new(1e4, 1e4)).X + 20
	local pad = 24
	local w = math.max(textW, tagW) + pad * 2 + SHADOW.X + 8
	local tagH = math.floor(s * 0.55)
	local h = tagH + s * 1.25 + SHADOW.Y + 8
	self.holder.Size = UDim2.fromOffset(w, h)

	local slashY = tagH + s * 0.2
	local slashH = s * 0.9
	local slashW = textW + pad * 2
	self.slash.Position = UDim2.fromOffset(0, slashY)
	self.slashShadow.Position = UDim2.fromOffset(SHADOW.X, slashY + SHADOW.Y)
	self.slash.Size = UDim2.fromOffset(0, slashH)
	self.slashShadow.Size = UDim2.fromOffset(0, slashH)
	self.tagBox.Position = UDim2.fromOffset(pad - 6, 4)
	self.tagBox.Size = UDim2.fromOffset(tagW, tagH)
	self.title.Text = text
	self.titleShadow.Text = text
	self.title.Position = UDim2.fromOffset(pad, tagH)
	self.title.Size = UDim2.fromOffset(textW + 8, s * 1.25)
	self.titleShadow.Position = UDim2.fromOffset(pad + SHADOW.X, tagH + SHADOW.Y)
	self.titleShadow.Size = self.title.Size

	self.gen += 1
	self.holder.Visible = true
	self.card.Position = UDim2.new(0.5, o.away.X, 0.5, o.away.Y)
	TweenService:Create(self.card, TweenInfo.new(0.28, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, 0.5) }):Play()
	self.card.GroupTransparency = 0
	self.scale.Scale = 1.15
	local wipe = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(self.slash, wipe, { Size = UDim2.fromOffset(slashW, slashH) }):Play()
	TweenService:Create(self.slashShadow, wipe, { Size = UDim2.fromOffset(slashW, slashH) }):Play()
	TweenService:Create(self.scale, TweenInfo.new(0.22, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	self.tagBox.Position = UDim2.fromOffset(pad - 46, 4)
	TweenService:Create(self.tagBox, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(pad - 6, 4) }):Play()
end

-- Slides it back out to `away` and fades, then hides it. Safe to call when already hidden.
function Sticker.hide(self: any)
	local my = self.gen
	local info = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	local out = TweenService:Create(self.card, info, {
		GroupTransparency = 1,
		Position = UDim2.new(0.5, self.o.away.X, 0.5, self.o.away.Y),
	})
	out.Completed:Once(function()
		if self.gen == my then
			self.holder.Visible = false
		end
	end)
	out:Play()
end

return Sticker
