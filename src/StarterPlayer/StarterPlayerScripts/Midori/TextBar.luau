--!strict
-- Turns a Text+ callout into its own bar. A gradient on the whole CanvasGroup didn't show
-- (user, 2026-10-10), so each letter's glyph gets its own UIGradient, and the drain edge is
-- placed across the letters by where each one sits in the text. Letters the edge is
-- passing through are split cleanly.
-- Text+ quirk (see RarityText): with a shadow, GetCharacters returns the shadow label and
-- the visible glyph is its child "Main".
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextPlus = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Text+") :: ModuleScript)

local TextBar = {}

local EMPTY_COLOR = Color3.fromRGB(70, 70, 70) -- multiplied over the drained part
local EMPTY_TRANSPARENCY = 0.35
local EDGE = 0.002 -- width of the hard edge, in gradient units
local WHITE = Color3.new(1, 1, 1)

type Glyph = { gradient: UIGradient, from: number, to: number } -- from/to: 0-1 across the text
export type Bar = { glyphs: { Glyph } }

-- Call after every TextPlus.Create on `frame` (the letters are rebuilt each time).
function TextBar.bind(frame: GuiObject): Bar
	-- Measured across the letters themselves (not the frame, whose size may not have laid out
	-- yet), as ratios so UIScale (the slam) doesn't matter.
	local list: { GuiObject } = {}
	local left, right = math.huge, -math.huge
	for _, letter in TextPlus.GetCharacters(frame) do
		local glyph = (letter:FindFirstChild("Main") or letter) :: GuiObject
		table.insert(list, glyph)
		left = math.min(left, glyph.AbsolutePosition.X)
		right = math.max(right, glyph.AbsolutePosition.X + glyph.AbsoluteSize.X)
	end
	local width = math.max(1, right - left)
	local glyphs: { Glyph } = {}
	for _, glyph in list do
		local gradient = glyph:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
		gradient.Parent = glyph
		local from = (glyph.AbsolutePosition.X - left) / width
		local to = from + glyph.AbsoluteSize.X / width
		table.insert(glyphs, { gradient = gradient, from = from, to = math.max(to, from + 1e-3) })
	end
	return { glyphs = glyphs }
end

local function split(gradient: UIGradient, filled: number, emptyFromLeft: boolean, full: Color3)
	local c0, c1, t0, t1 = full, EMPTY_COLOR, 0, EMPTY_TRANSPARENCY
	if filled >= 1 then
		c1, t1 = full, 0
	elseif filled <= 0 then
		c0, t0 = EMPTY_COLOR, EMPTY_TRANSPARENCY
	end
	local edge = if emptyFromLeft then 1 - filled else filled
	if emptyFromLeft then
		c0, c1, t0, t1 = c1, c0, t1, t0
	end
	edge = math.clamp(edge, EDGE, 1 - 2 * EDGE)
	gradient.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, c0),
		ColorSequenceKeypoint.new(edge, c0),
		ColorSequenceKeypoint.new(edge + EDGE, c1),
		ColorSequenceKeypoint.new(1, c1),
	})
	gradient.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, t0),
		NumberSequenceKeypoint.new(edge, t0),
		NumberSequenceKeypoint.new(edge + EDGE, t1),
		NumberSequenceKeypoint.new(1, t1),
	})
end

-- `progress` 0-1 is how full the bar is. emptyFromLeft: the left side empties first (drains
-- left to right); otherwise the right side empties first (drains right to left).
-- `full` tints the filled part (default white = the text's own colour).
function TextBar.set(bar: Bar?, progress: number, emptyFromLeft: boolean, full: Color3?)
	if not bar then
		return
	end
	local p = math.clamp(progress, 0, 1)
	for _, g in bar.glyphs do
		local span = g.to - g.from
		-- How much of this letter is still filled.
		local filled = if emptyFromLeft then (g.to - (1 - p)) / span else (p - g.from) / span
		split(g.gradient, math.clamp(filled, 0, 1), emptyFromLeft, full or WHITE)
	end
end

-- Full bar, each letter a hue shifted along the text (the "loaded" rainbow).
function TextBar.rainbow(bar: Bar?, phase: number)
	if not bar then
		return
	end
	for _, g in bar.glyphs do
		local mid = (g.from + g.to) / 2
		g.gradient.Color = ColorSequence.new(Color3.fromHSV((mid + phase) % 1, 0.75, 1))
		g.gradient.Transparency = NumberSequence.new(0)
	end
end

return TextBar
