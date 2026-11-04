--!strict
-- Streak callouts in the bottom-right corner, drawn with Text+ in Sedgwick Ave Display.
-- push(key, text, color) SLAMS a callout in (oversized, tilted, shaking). The text itself is
-- the timer: it drains left to right (TextBar). Pushing the same key again before it runs
-- out slams it again, refills it and bumps the multiplier ("COUNTER x2", "x3", ...). When
-- it empties the callout drops away and the streak ends.
-- Wired to counters, parries, dash escapes and guard breaks below; anything streak-like
-- can reuse push().
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Enums = Paths.shared("Enums")
local Net = Paths.shared("Net")
local TextPlus = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Text+") :: ModuleScript)
local TextBar = require(script.Parent:WaitForChild("TextBar"))

local FONT = Font.fromId(12187376357) -- Sedgwick Ave Display (Creator Store)
local TEXT_SIZE = 84
local DURATION = 3 -- seconds for the text to drain
local MARGIN = Vector2.new(40, 40) -- from the bottom-right corner
local LAYOUT_WIDTH = 100000 -- render frame width: never wraps

-- The slam: starts huge and snaps down, kicked to a random tilt, shaking as it lands.
local SLAM_SCALE = 2.6
local SLAM_TIME = 0.16
local KICK_TILT = 14 -- degrees, random sign
local REST_TILT = 4 -- degrees it settles at (random sign per slam)
local SHAKE_TIME = 0.28
local SHAKE_PX = 14
local SETTLE_TIME = 0.35

local COUNTER_RED = Color3.fromRGB(235, 30, 30)
local COUNTERED_RED = Color3.fromRGB(130, 10, 14)
local PARRY_GOLD = D.PARRY_COLOR
local ESCAPE_WHITE = D.GHOST_COLOR -- matches the dodge ghost
local GUARD_BREAK_PURPLE = Color3.fromRGB(170, 60, 255)

local STYLE = {
	Font = FONT,
	Size = TEXT_SIZE,
	StrokeSize = 4,
	StrokeColor = Color3.new(0, 0, 0),
	ShadowOffset = Vector2.new(5, 6),
	ShadowColor = Color3.new(0, 0, 0),
	ShadowTransparency = 0.15,
	XAlignment = "Left",
	YAlignment = "Top",
	WordSorting = true, -- keeps GetCharacters working (TextBar needs the letters)
}

local CalloutController = {}

type Entry = {
	slot: Frame, -- sits in the list layout
	group: CanvasGroup, -- free inside the slot: scaled, tilted and shaken
	scale: UIScale,
	text: Frame,
	bar: TextBar.Bar?, -- the text is the bar (bound after each draw)
	color: Color3,
	count: number,
	gen: number,
	drainStart: number, -- os.clock() when the text was last refilled
	removed: boolean,
	shakeUntil: number,
}

local holder: Frame
local entries: { [string]: Entry } = {}
local order = 0

local function waitForLayout(frame: GuiObject)
	while frame.Parent and frame.AbsoluteSize.X <= 0 do
		RunService.RenderStepped:Wait()
	end
end


local function draw(entry: Entry, text: string, gen: number)
	local frame = entry.text
	frame.AnchorPoint = Vector2.zero
	frame.Position = UDim2.new()
	frame.Size = UDim2.fromOffset(LAYOUT_WIDTH, TEXT_SIZE * 2)
	waitForLayout(frame)
	if entry.gen ~= gen then
		return
	end
	local options = table.clone(STYLE)
	options.Color = entry.color
	TextPlus.Create(frame, text, options)
	if entry.gen ~= gen then
		return
	end
	local bounds = TextPlus.GetBounds(frame)
	frame.Size = UDim2.fromOffset(bounds.X, bounds.Y)
	frame.AnchorPoint = Vector2.new(1, 0)
	frame.Position = UDim2.new(1, -6, 0, 0)
	entry.bar = TextBar.bind(frame)
	-- Room for the stroke and shadow so the CanvasGroup doesn't clip them.
	local size = UDim2.fromOffset(bounds.X + 12, bounds.Y + 10)
	entry.group.Size = size
	entry.slot.Size = size
end

local function remove(key: string, entry: Entry)
	entry.removed = true
	if entries[key] == entry then
		entries[key] = nil
	end
	-- Drop away: shrink, fade and fall a little.
	local info = TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(entry.scale, info, { Scale = 0.6 }):Play()
	local fade = TweenService:Create(entry.group, info, {
		GroupTransparency = 1,
		Position = UDim2.new(0.5, 0, 0.5, 30),
	})
	fade.Completed:Once(function()
		entry.slot:Destroy()
	end)
	fade:Play()
end

local function slam(entry: Entry)
	local side = if math.random() < 0.5 then -1 else 1
	entry.scale.Scale = SLAM_SCALE
	entry.group.Rotation = KICK_TILT * side
	entry.group.GroupTransparency = 0
	entry.shakeUntil = os.clock() + SHAKE_TIME
	TweenService:Create(entry.scale, TweenInfo.new(SLAM_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out, 0, false, 0), { Scale = 1 }):Play()
	TweenService:Create(entry.group, TweenInfo.new(SETTLE_TIME, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), {
		Rotation = -REST_TILT * side,
	}):Play()
end

local function create(label: string, color: Color3): Entry
	order += 1
	local slot = Instance.new("Frame")
	slot.Name = label
	slot.BackgroundTransparency = 1
	slot.Size = UDim2.fromOffset(TEXT_SIZE * 3, TEXT_SIZE)
	slot.LayoutOrder = order -- newest at the bottom
	slot.Parent = holder

	local group = Instance.new("CanvasGroup")
	group.BackgroundTransparency = 1
	group.AnchorPoint = Vector2.new(0.5, 0.5) -- scale and tilt around the middle
	group.Position = UDim2.fromScale(0.5, 0.5)
	group.Size = slot.Size
	group.Parent = slot

	local scale = Instance.new("UIScale")
	scale.Parent = group

	local text = Instance.new("Frame")
	text.Name = "Text"
	text.BackgroundTransparency = 1
	text.Parent = group


	return {
		slot = slot,
		group = group,
		scale = scale,
		text = text,
		bar = nil,
		color = color,
		count = 0,
		gen = 0,
		drainStart = os.clock(),
		removed = false,
		shakeUntil = 0,
	}
end

-- Slams `label` in (or bumps its multiplier if it's still up) and restarts its bar.
function CalloutController.push(key: string, label: string, color: Color3)
	local entry = entries[key]
	if not entry then
		entry = create(label, color)
		entries[key] = entry
	end
	entry.count += 1
	entry.gen += 1
	local text = if entry.count > 1 then `{label} x{entry.count}` else label
	slam(entry)
	entry.drainStart = os.clock()
	task.spawn(draw, entry, text, entry.gen)
end

-- Shake decays to nothing over SHAKE_TIME, then the callout sits still. The text drains
-- left to right (computed per frame, never through tweens or .Changed) and drops away when empty.
local function shakeStep()
	local t = os.clock()
	for key, entry in entries do
		local left = 1 - (t - entry.drainStart) / DURATION
		TextBar.set(entry.bar, left, true)
		if left <= 0 and not entry.removed then
			remove(key, entry)
			continue
		end
		local shake = entry.shakeUntil - t
		if shake > 0 then
			local amp = SHAKE_PX * shake / SHAKE_TIME
			entry.group.Position = UDim2.new(0.5, (math.random() * 2 - 1) * amp, 0.5, (math.random() * 2 - 1) * amp)
		elseif entry.group.Position ~= UDim2.fromScale(0.5, 0.5) then
			entry.group.Position = UDim2.fromScale(0.5, 0.5)
		end
	end
end

local function onHitResult(attacker: Model, victim: Model, result: string)
	local me = Players.LocalPlayer.Character
	if not me then
		return
	end
	if result == Enums.Result.Counter then
		-- Counter crits: COUNTER when we land one, COUNTERED when one lands on us.
		if attacker == me then
			CalloutController.push("Counter", "COUNTER", COUNTER_RED)
		elseif victim == me then
			CalloutController.push("Countered", "COUNTERED", COUNTERED_RED)
		end
	elseif result == Enums.Result.Parried then
		-- The victim is the perfect blocker: PERFECT BLOCK when we do it, PERFECT BLOCKED when it is done to us.
		if victim == me then
			CalloutController.push("Parry", "PARRY", PARRY_GOLD)
		elseif attacker == me then
			CalloutController.push("Parried", "PARRIED", PARRY_GOLD)
		end
	elseif result == Enums.Result.GuardBreak then
		if victim == me then
			CalloutController.push("GuardBroken", "GUARD BROKEN", GUARD_BREAK_PURPLE)
		end
	end
end

-- A dash whose i-frames ate a hit (server-confirmed, once per dash).
local function onDodged(dodger: Model)
	if dodger == Players.LocalPlayer.Character then
		CalloutController.push("Escaped", "ESCAPED", ESCAPE_WHITE)
	end
end

function CalloutController.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriCallouts"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(1, 1)
	holder.Position = UDim2.new(1, -MARGIN.X, 1, -MARGIN.Y)
	holder.Size = UDim2.fromOffset(700, 500)
	holder.Parent = gui

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.Padding = UDim.new(0, 2)
	layout.Parent = holder

	RunService.RenderStepped:Connect(shakeStep)
	Net.get("HitResult").OnClientEvent:Connect(onHitResult)
	Net.get("Dodged").OnClientEvent:Connect(onDodged)
end

return CalloutController
