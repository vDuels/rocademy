--!strict
-- Item names drawn with Text+ and a per-rarity effect (the Appearance tab's rows):
--   Common     white, thin black stroke
--   Rare       blue, dark stroke + drop shadow
--   Epic       purple -> pink across the letters
--   Legendary  gold with a white shimmer sweeping across
--   Mythic     red/pink sweep, and the letters bob in a wave
--   Evolved    teal/violet sweep (faster), bigger wave
-- render() can be called while the GUI is hidden: Text+ needs a laid-out frame, so it waits for one.
-- Text+ quirk (see NametagController): with a shadow, GetCharacters returns the shadow label and
-- the visible glyph is its child "Main".
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Rarity = Paths.shared("Rarity")
local TextPlus = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Text+") :: ModuleScript)

local FONT = Font.fromEnum(Enum.Font.GothamBold)
local MIN_SIZE = 11 -- long names shrink to fit, but never below this
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

-- a -> b is the letter colour range; `sweep` animates it (cycles/s), `wave` bobs letters (px).
type Effect = { a: Color3, b: Color3, stroke: Color3, shadow: boolean, sweep: number?, wave: number? }
local EFFECTS: { [string]: Effect } = {
	Common = { a = WHITE, b = WHITE, stroke = BLACK, shadow = false },
	Rare = { a = Rarity.COLORS.Rare, b = Rarity.COLORS.Rare, stroke = Color3.fromRGB(10, 30, 70), shadow = true },
	Epic = { a = Rarity.COLORS.Epic, b = Color3.fromRGB(255, 120, 220), stroke = Color3.fromRGB(40, 10, 60), shadow = true },
	Legendary = { a = Rarity.COLORS.Legendary, b = Color3.fromRGB(255, 250, 225), stroke = Color3.fromRGB(70, 40, 0), shadow = true, sweep = 0.6 },
	Mythic = { a = Rarity.COLORS.Mythic, b = Color3.fromRGB(255, 175, 175), stroke = Color3.fromRGB(60, 0, 0), shadow = true, sweep = 1.2, wave = 2 },
	Evolved = { a = Rarity.COLORS.Evolved, b = Color3.fromRGB(150, 90, 255), stroke = Color3.fromRGB(0, 40, 35), shadow = true, sweep = 1.6, wave = 3 },
}

type Entry = { effect: Effect, letters: { GuiObject }, glyphs: { GuiObject }, bases: { UDim2 } }
local active: { [GuiObject]: Entry } = {}
local pending: { [GuiObject]: {} } = {} -- latest render request per frame (older ones are dropped)

local RarityText = {}

local function paint(entry: Entry, t: number)
	local e = entry.effect
	local n = #entry.glyphs
	for i, glyph in entry.glyphs do
		local along = if n > 1 then (i - 1) / (n - 1) else 0
		local k = if e.sweep then 0.5 + 0.5 * math.sin(2 * math.pi * (along - t * e.sweep)) else along
		local color = e.a:Lerp(e.b, k)
		if glyph:IsA("TextLabel") then
			glyph.TextColor3 = color
		elseif glyph:IsA("ImageLabel") then
			glyph.ImageColor3 = color
		end
		if e.wave then
			entry.letters[i].Position = entry.bases[i] + UDim2.fromOffset(0, math.sin(t * 6 + i * 0.6) * e.wave)
		end
	end
end

-- Removes any Text+ text (and its animation) from `frame`.
function RarityText.clear(frame: GuiObject)
	active[frame] = nil
	pending[frame] = nil
	for _, child in frame:GetChildren() do
		if not child:IsA("UIBase") then
			child:Destroy()
		end
	end
end

-- Draws `text` into `frame` (left-aligned, vertically centred) with `rarity`'s effect at `size`,
-- shrinking it to fit `maxWidth` px (layout units, so it's right at any UIScale).
function RarityText.render(frame: GuiObject, text: string, rarity: string?, size: number, maxWidth: number)
	RarityText.clear(frame)
	local token = {}
	pending[frame] = token
	local function draw()
		if pending[frame] ~= token or not frame.Parent then
			return
		end
		pending[frame] = nil
		local e = EFFECTS[rarity or "Common"] or EFFECTS.Common
		local options: { [string]: any } = {
			Font = FONT,
			Size = size,
			Color = e.a,
			StrokeSize = 1,
			StrokeColor = e.stroke,
			ShadowOffset = Vector2.new(0, 2),
			ShadowColor = BLACK,
			ShadowTransparency = if e.shadow then 0.45 else 1,
			XAlignment = "Left",
			YAlignment = "Center",
			WordSorting = true, -- keeps GetCharacters working for Roblox fonts
		}
		TextPlus.Create(frame, text, options)
		local width = TextPlus.GetBounds(frame).X
		if width > maxWidth then
			options.Size = math.max(MIN_SIZE, math.floor(size * maxWidth / width))
			TextPlus.Create(frame, text, options)
		end
		local entry: Entry = { effect = e, letters = {}, glyphs = {}, bases = {} }
		for _, letter in TextPlus.GetCharacters(frame) do
			table.insert(entry.letters, letter)
			table.insert(entry.glyphs, (letter:FindFirstChild("Main") or letter) :: GuiObject)
			table.insert(entry.bases, letter.Position)
		end
		active[frame] = entry
		paint(entry, os.clock())
	end
	if frame.AbsoluteSize.X > 0 then
		draw()
	else
		local conn: RBXScriptConnection
		conn = frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			if frame.AbsoluteSize.X > 0 then
				conn:Disconnect()
				draw()
			end
		end)
	end
end

-- One loop animates every sweeping/waving name that's on screen.
RunService.RenderStepped:Connect(function()
	local t = os.clock()
	for frame, entry in active do
		if not frame.Parent then
			active[frame] = nil
		elseif (entry.effect.sweep or entry.effect.wave) and frame.Visible and frame.AbsoluteSize.X > 0 then
			paint(entry, t)
		end
	end
end)

return RarityText
