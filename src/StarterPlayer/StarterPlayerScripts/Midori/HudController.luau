--!strict
-- Screen HUD, top-left: Hi-Fi Rush with a squeeze of Persona. Slanted sticker bars (guard white,
-- HP green, adrenaline red) on a red Persona slash, and your 3 equipped trait cards under them.
-- Cards sit desaturated; when the server says a trait procced (TraitProc) its card slams to full
-- colour for D.HUD_TRAIT_PROC_HOLD and flashes its name tag. While you're fighting (you hit or got
-- hit/blocked/parried/dodged within D.LOADOUT_COMBAT_LOCK) everything bops on D.HUD_BPM.
-- Driven only by replicated values: Humanoid.Health, character attributes Guard/GuardMax,
-- Adrenaline/AdrenalineMax, Healable, and the Player's "PerkSlots" ("id,,id").
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local StarterPlayer = game:GetService("StarterPlayer")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local CombatMath = Paths.shared("CombatMath")
local MoveSchema = Paths.shared("MoveSchema")
local UserInputService = game:GetService("UserInputService")

local BLACK = Color3.new(0, 0, 0)
local EMPTY_CARD = Color3.fromRGB(70, 70, 78)
local FONT = Font.fromEnum(Enum.Font.LuckiestGuy)
local CELL = 256
local CARD_CELL = 12
-- The housing art (D.HUD_FRAME, drawn by hud_frame.py at 2 px per unit) holds the slash, the black
-- slab and the tracks. Each bar's fill is its own strip at the bar's exact aspect, so the slants are
-- true. Units = UI offsets. Keep in sync with hud_frame.py BARS / LEAN.
local LEAN = 0.45 -- x shift per unit of height: every bar end leans "/"
local BARS = {
	guard = { x = 74.9, y = 18, w = 330, h = 20, strip = 520 },
	hp = { x = 56, y = 46, w = 362, h = 34, strip = 570 },
	adr = { x = 45.2, y = 88, w = 280, h = 16, strip = 650 },
	-- Focus (Prodigy): floats under your character (user, 2026-10-25; was under adrenaline), on the same
	-- lean, reusing adrenaline's strip art. Coords are inside its BillboardGui. Only while "FocusOn", in
	-- combat mode, and not while the HUD is slid out (cutscene / side menu) (user, 2026-10-25).
	-- w/h must stay the art's (adrenaline's strip is 280 x 16): bigger = FOCUS_SCALE, not w/h (user, 2026-10-25).
	focus = { x = 6, y = 4, w = 280, h = 16, strip = 650 },
}
local FOCUS_SCALE = 1.4
local FOCUS_OFFSET = Vector3.new(0, -3.4, 0) -- studs below the root, camera space
local FOCUS_TRACK = Color3.fromRGB(16, 24, 48)
local CHARGE_W, CHARGE_H = 120, 8
-- M2 charge bar fill by tier reached (tap, mid, full)
local CHARGE_COLORS = { Color3.new(1, 1, 1), Color3.fromRGB(255, 210, 50), Color3.fromRGB(240, 36, 60) }
-- Controls list: out of combat / in combat (CombatModeController, T). The M2 row reads "HOLD M2" for charge styles.
local CONTROLS_FREE = { { "SHIFT", "Sprint" }, { "T", "Combat mode" }, { "G", "Emotes" }, { "E", "Interact" }, { "CTRL", "Shift lock" } }
local CONTROLS_FIGHT = { { "M1", "Attack" }, { "M2", "Heavy" }, { "R", "Critical" }, { "F", "Block / parry" }, { "Q", "Dash" }, { "T", "Leave combat" } }
-- Cooldown stickers (crit red, M2 white), right of the bars and tilted up. Art from hud_frame.py CDS:
-- housing = black plate + track at sheet y `housing` (cw x ch), the bar inside it at x/y, fill strip at `strip`.
-- cx/cy = the sticker's centre in HUD units, rot = its tilt.
local CDS = {
	crit = { cw = 215.6, ch = 26, housing = 700, x = 5.8, y = 4, w = 200, h = 14, strip = 840, cx = 478, cy = 96, rot = -16 },
	m2 = { cw = 165.6, ch = 24, housing = 770, x = 5.8, y = 4, w = 150, h = 12, strip = 880, cx = 452, cy = 151, rot = -13 },
}
local EPS = 0.002
-- Name tags share one lane under the cards (left-aligned, all at -6deg) and stack a row per tag on
-- screen, so they never cover each other. The offset slab behind each takes its trait's colour.
local TAG_X, TAG_Y, TAG_ROW = 34, 252, 32
local TAG_TILT = -6
-- Slide-out when the side menu opens: distance in HUD units, bars spring (critical) and cards spring (bouncy).
local SLIDE_DIST = 640
local ROOT_Y = 58 -- the chat box lives in the topbar (ChatBarController), so the HUD keeps its spot
local SLIDE_K, SLIDE_C = 260, 32
local CARD_K, CARD_C = 140, 14 -- underdamped: ~10% overshoot past home on the way back in

local HudController = {}

local function new(class: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(class)
	if inst:IsA("GuiObject") then
		inst.BorderSizePixel = 0
		inst.BackgroundTransparency = 1
	end
	for k, v in props do
		(inst :: any)[k] = v
	end
	inst.Parent = parent
	return inst
end

local function sprite(image: string, rect: { Vector2 }, props: { [string]: any }, parent: Instance): ImageLabel
	props.Image = image
	props.ImageRectOffset = rect[1]
	props.ImageRectSize = rect[2]
	return new("ImageLabel", props, parent)
end

-- Saturation s (0-1); idle cards also drop a little value so the lit one pops.
local function saturate(c: Color3, s: number): Color3
	local h, sat, v = c:ToHSV()
	return Color3.fromHSV(h, sat * s, v * (0.6 + 0.4 * s))
end

-- Hard-edged leaning cut. Measured in Studio: a rotated UIGradient's keypoints span only the line
-- through the box's centre (~100px on a thin bar), so the cut keypoint stays at 0.5 and Offset
-- (a fraction of the width, unrotated) slides it. The cut passes the bar's mid-height at x_mid.
local CUT_KEYS = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0),
	NumberSequenceKeypoint.new(0.499, 0),
	NumberSequenceKeypoint.new(0.5, 1),
	NumberSequenceKeypoint.new(1, 1),
})
local function cut(img: ImageLabel, grad: UIGradient, b: any, t: number)
	img.Visible = t > EPS
	local xMid = if t >= 1 - EPS then b.w * 2 else LEAN * b.h / 2 + t * (b.w - LEAN * b.h)
	grad.Offset = Vector2.new((xMid - b.w / 2) / b.w, 0)
end
type Bar = { b: any, fill: ImageLabel, grad: UIGradient, extra: ImageLabel?, extraGrad: UIGradient?, color: Color3, shown: number, target: number, flash: number }
type Card = {
	root: Frame, scale: UIScale, bg: ImageLabel, icon: ImageLabel, flash: ImageLabel, tag: Frame, tagBack: Frame, tagScale: UIScale, tagText: TextLabel, tagOut: boolean, tagRow: number, tagY: number,
	id: string?, data: any, sat: number, litUntil: number, tagUntil: number, pop: number, baseRot: number, baseX: number, baseY: number,
}
export type Hud = {
	gui: ScreenGui,
	focusBoard: BillboardGui, -- the Focus meter; caller sets its Adornee (our root)
	set: (guard: number, guardMax: number, hp: number, hpMax: number, healable: number, adr: number, adrMax: number) -> (),
	setFocus: (focus: number, focusMax: number, on: boolean) -> (),
	setCharge: (held: number?, tiers: { any }?) -> (),
	setControls: (fighting: boolean, chargeM2: boolean) -> (),
	setTraits: (ids: { string }) -> (),
	cooldown: (name: string, untilT: number, now: number) -> (),
	setOut: (out: boolean) -> (),
	proc: (key: string) -> (),
	hold: (key: string, now: number) -> (),
	step: (dt: number, now: number, fighting: boolean) -> (),
}

local function strip(parent: Instance, b: any, color: Color3, z: number): (ImageLabel, UIGradient)
	local img = new("ImageLabel", {
		Image = D.HUD_FRAME, ImageRectOffset = Vector2.new(0, b.strip), ImageRectSize = Vector2.new(b.w * 2, b.h * 2),
		ImageColor3 = color, Position = UDim2.fromOffset(b.x, b.y), Size = UDim2.fromOffset(b.w, b.h), ZIndex = z,
	}, parent)
	-- the cut's UIGradient rotation lives in the strip's 0-1 space, so convert the lean into it
	local grad = new("UIGradient", { Rotation = math.deg(math.atan(LEAN)), Transparency = CUT_KEYS }, img)
	return img, grad
end

local function makeBar(parent: Instance, b: any, color: Color3, healable: boolean): Bar
	local extra, extraGrad
	if healable then
		extra, extraGrad = strip(parent, b, D.HUD_HEALABLE_COLOR, 2)
	end
	local fill, grad = strip(parent, b, color, 3)
	return { b = b, fill = fill, grad = grad, extra = extra, extraGrad = extraGrad, color = color, shown = 1, target = 1, flash = 0 }
end

local function makeCard(parent: Instance, i: number, x: number, y: number, rot: number): Card
	local size = 96
	local root = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(size, size), Rotation = rot, ZIndex = 5 - i }, parent)
	local scale = new("UIScale", {}, root)
	local cardRect = { Vector2.new((CARD_CELL % 4) * CELL, (CARD_CELL // 4) * CELL), Vector2.new(CELL, CELL) }
	local bg = sprite(D.HUD_ATLAS, cardRect, { Size = UDim2.fromScale(1, 1) }, root)
	local icon = sprite(D.HUD_ATLAS, cardRect, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.52, 0.5), Size = UDim2.fromScale(0.68, 0.68), Rotation = -rot * 0.5 }, root)
	local flash = sprite(D.HUD_ATLAS, cardRect, { Size = UDim2.fromScale(1, 1), ImageColor3 = Color3.new(1, 1, 1), ImageTransparency = 1 }, root)
	-- Persona name tag (lives in the shared lane on `parent`, not on the card): black slab, coloured offset slab, white text
	local tag = new("Frame", { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(TAG_X, TAG_Y), Size = UDim2.fromOffset(10, 26), Rotation = TAG_TILT, Visible = false, ZIndex = 10 }, parent)
	local tagScale = new("UIScale", {}, tag)
	local tagBack = new("Frame", { BackgroundTransparency = 0, BackgroundColor3 = D.HUD_SLASH_COLOR, Position = UDim2.fromOffset(5, 4), Size = UDim2.fromScale(1, 1), ZIndex = 10 }, tag)
	new("Frame", { BackgroundTransparency = 0, BackgroundColor3 = BLACK, Size = UDim2.fromScale(1, 1), ZIndex = 11 }, tag)
	local tagText = new("TextLabel", {
		FontFace = FONT, TextColor3 = Color3.new(1, 1, 1), TextSize = 20, TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2.fromOffset(7, 1), Size = UDim2.new(1, -10, 1, 0), ZIndex = 12, AutomaticSize = Enum.AutomaticSize.None,
	}, tag)
	return { root = root, scale = scale, bg = bg, icon = icon, flash = flash, tag = tag, tagBack = tagBack, tagScale = tagScale, tagText = tagText, tagOut = false, tagRow = 0, tagY = 0, id = nil, data = nil, sat = D.HUD_TRAIT_IDLE_SAT, litUntil = 0, tagUntil = 0, pop = 0, baseRot = rot, baseX = x, baseY = y }
end

-- Builds the HUD under `parent` (a ScreenGui is made if parent isn't one). Pure UI: callers feed it values.
function HudController.build(parent: Instance): Hud
	local gui = new("ScreenGui", { Name = "MidoriHud", ResetOnSpawn = false, IgnoreGuiInset = true, DisplayOrder = 5, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, parent)
	local root = new("Frame", { Name = "Root", Position = UDim2.fromOffset(16, ROOT_Y), Size = UDim2.fromOffset(512, 256) }, gui)
	local uiScale = new("UIScale", {}, root)
	local function rescale()
		local cam = workspace.CurrentCamera
		local h = if cam then cam.ViewportSize.Y else 1080
		uiScale.Scale = math.clamp(h / 900, 0.6, 1.3)
	end
	rescale()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
	local baseScale = uiScale.Scale

	-- housing (slash + slab + tracks) and the fills shake together on damage
	local barsGroup = new("Frame", { Size = UDim2.fromScale(1, 1) }, root)
	new("ImageLabel", { Image = D.HUD_FRAME, ImageRectSize = Vector2.new(1024, 512), Size = UDim2.fromOffset(512, 256), ZIndex = 1 }, barsGroup)
	local guard = makeBar(barsGroup, BARS.guard, D.HUD_GUARD_COLOR, false)
	local hp = makeBar(barsGroup, BARS.hp, D.HUD_HP_COLOR, true)
	local adr = makeBar(barsGroup, BARS.adr, D.HUD_ADR_COLOR, false)
	-- Focus meter (user, 2026-10-25: "make it better"): navy track, FOCUS label + value inside it, and
	-- notches at the Focus thresholds (M1 damage at D.FOCUS.m1Damage.at, dash cooldown at dashCdFocus).
	local fb = BARS.focus
	local focusBoard = new("BillboardGui", {
		Name = "MidoriFocus", ResetOnSpawn = false, AlwaysOnTop = true, LightInfluence = 0, Enabled = false,
		Size = UDim2.fromOffset((fb.x * 2 + fb.w) * FOCUS_SCALE, (fb.y * 2 + fb.h) * FOCUS_SCALE), StudsOffset = FOCUS_OFFSET,
	}, gui.Parent)
	local focusHolder = new("Frame", { Size = UDim2.fromOffset(fb.x * 2 + fb.w, fb.y * 2 + fb.h) }, focusBoard)
	new("UIScale", { Scale = FOCUS_SCALE }, focusHolder)
	local focusTrack, focusTrackGrad = strip(focusHolder, fb, FOCUS_TRACK, 2)
	cut(focusTrack, focusTrackGrad, fb, 1)
	local focus = makeBar(focusHolder, fb, D.HUD_FOCUS_COLOR, false)
	local focusOn, focusFull, focusValue = false, false, 0
	local combatOn, hudOut = false, false -- combat mode (setControls) / HUD slid out (setOut: cutscene, side menu)
	local focusText = { "FOCUS", "0" }
	local focusLabels = {}
	for i, align in { Enum.TextXAlignment.Left, Enum.TextXAlignment.Right } do
		local label = new("TextLabel", {
			FontFace = FONT, TextSize = 15, TextColor3 = Color3.new(1, 1, 1), TextXAlignment = align, Text = focusText[i],
			Position = UDim2.fromOffset(fb.x + 10, fb.y), Size = UDim2.fromOffset(fb.w - 20 - LEAN * fb.h, fb.h + 2), ZIndex = 5,
		}, focusHolder)
		new("UIStroke", { Thickness = 1.5, Color = BLACK }, label)
		focusLabels[i] = label
	end
	local notches = {}
	for _, at in { D.FOCUS.m1Damage.at, D.FOCUS.dashCdFocus / D.FOCUS.max } do
		local xMid = LEAN * fb.h / 2 + at * (fb.w - LEAN * fb.h)
		table.insert(notches, {
			at = at,
			frame = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(fb.x + xMid, fb.y + fb.h / 2), Size = UDim2.fromOffset(3, fb.h + 4),
				Rotation = math.deg(math.atan(LEAN)), BackgroundTransparency = 0, ZIndex = 4,
			}, focusHolder),
		})
	end
	local function showFocus(on: boolean)
		focusBoard.Enabled = on and combatOn and not hudOut and focusBoard.Adornee ~= nil
		focusTrack.Visible = on
		for _, l in focusLabels do
			l.Visible = on
		end
		for _, n in notches do
			n.frame.Visible = on
		end
	end
	showFocus(false)
	focus.fill.Visible = false

	-- M2 charge bar (user, 2026-10-25): just under the crosshair (screen centre), only while a swing
	-- charge (Slugger M2) winds up. Notches at each tier; the fill takes the reached tier's colour.
	local chargeBox = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0.5, 30), Size = UDim2.fromOffset(CHARGE_W + 6, CHARGE_H + 6),
		BackgroundTransparency = 0, BackgroundColor3 = BLACK, Rotation = -3, Visible = false,
	}, gui)
	new("UIScale", {}, chargeBox)
	local chargeFill = new("Frame", { Position = UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(0, CHARGE_H), BackgroundTransparency = 0, ZIndex = 2 }, chargeBox)
	local chargeNotches: { Frame } = {}
	local chargeHeld, chargeTiers, chargeVis, chargeTier, chargeFlash = 0, {} :: { any }, 0, 0, 0
	local chargeOn = false

	-- Controls (user, 2026-10-25): bottom left, the keys that matter right now. Rebuilt when the set changes.
	local controls = new("CanvasGroup", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 16, 1, -16), Size = UDim2.fromOffset(320, 300), Rotation = -3 }, gui)
	local controlsScale = new("UIScale", {}, controls)
	new("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, VerticalAlignment = Enum.VerticalAlignment.Bottom, Padding = UDim.new(0, 4) }, controls)
	local controlsKey, controlsSlide = "", 1
	-- cooldown stickers: t = recharge progress (1 = ready); untilT/total in server time
	local cds = {}
	for name, c in CDS do
		local box = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(c.cx, c.cy), Size = UDim2.fromOffset(c.cw, c.ch), Rotation = c.rot }, barsGroup)
		local housing = new("ImageLabel", { Image = D.HUD_FRAME, ImageRectOffset = Vector2.new(0, c.housing), ImageRectSize = Vector2.new(math.floor(c.cw * 2), math.floor(c.ch * 2)), Size = UDim2.fromScale(1, 1), ImageTransparency = 1, ZIndex = 1 }, box)
		local fill, grad = strip(box, c, Color3.new(1, 1, 1), 3)
		fill.ImageTransparency = 1
		-- lastBusy (os.clock): last frame it was recharging; hidden until first used
		cds[name] = { b = c, housing = housing, fill = fill, grad = grad, color = if name == "crit" then D.HUD_CRIT_CD_COLOR else D.HUD_M2_CD_COLOR, t = 1, untilT = 0, total = 1, flash = 0, lastBusy = -math.huge, vis = 0 }
	end

	local cards: { Card } = {}
	local CARD_POS = { { 70, 178, -6 }, { 146, 184, 4 }, { 222, 176, -3 } }
	for i = 1, D.PERK_SLOTS do
		local p = CARD_POS[i] or { 50 + (i - 1) * 72, 130, 0 }
		cards[i] = makeCard(root, i, p[1], p[2], p[3])
	end

	local shake, adrFull = 0, false
	local lastHp, lastGuard = math.huge, math.huge
	local beat, lastBeatIndex = 0, -1
	-- Slide out (the side menu is open): 0 = home, 1 = off-screen left. The bars ride a stiff spring;
	-- the trait cards ride a looser, bouncy one so they trail behind and overshoot (user, 2026-10-17).
	local slideTarget, barsP, barsV, cardsP, cardsV = 0, 0, 0, 0, 0

	local hud = {} :: Hud
	hud.gui = gui
	hud.focusBoard = focusBoard

	function hud.setOut(out)
		slideTarget = if out then 1 else 0
		hudOut = out
	end

	function hud.set(g, gMax, h, hMax, healable, a, aMax)
		local gt = math.clamp(g / math.max(gMax, 1), 0, 1)
		local ht = math.clamp(h / math.max(hMax, 1), 0, 1)
		if h < lastHp - 1e-3 then
			shake = math.max(shake, 7)
			hp.flash = 1
		end
		if g < lastGuard - 1e-3 then
			shake = math.max(shake, 3)
			guard.flash = 1
		end
		lastHp, lastGuard = h, g
		-- Losses snap (user: delayed bars read as lag); gains ease in step().
		local at = math.clamp(a / math.max(aMax, 1), 0, 1)
		guard.target, hp.target, adr.target = gt, ht, at
		guard.shown, hp.shown, adr.shown = math.min(guard.shown, gt), math.min(hp.shown, ht), math.min(adr.shown, at)
		if hp.extra and hp.extraGrad then
			cut(hp.extra, hp.extraGrad, hp.b, math.clamp(ht + healable / math.max(hMax, 1), 0, 1))
		end
		adrFull = a >= aMax - 1e-3 and aMax > 0
	end

	-- Focus bar: shown only while `on`; losses snap and flash, gains ease in (like the others).
	function hud.setFocus(f, fMax, on)
		focusOn = on
		local ft = math.clamp(f / math.max(fMax, 1), 0, 1)
		if ft < focus.shown - 1e-3 then
			focus.flash = 1
		end
		focus.target = ft
		focus.shown = math.min(focus.shown, ft)
		focusFull = on and CombatMath.focusFull(f, fMax) -- same "full" as the server's Lightshow check
		focusValue = ft
		focusLabels[2].Text = if focusFull then "FULL!" else tostring(math.floor(f))
	end

	-- held = seconds into the windup (nil = not charging: the bar holds its last value and fades out);
	-- tiers = the move's charge.tiers, the last one is full.
	function hud.setCharge(held, tiers)
		chargeOn = held ~= nil
		if not held or not tiers then
			return
		end
		if tiers ~= chargeTiers then
			chargeTiers = tiers
			for _, n in chargeNotches do
				n:Destroy()
			end
			table.clear(chargeNotches)
			local full = tiers[#tiers].at
			for i = 2, #tiers - 1 do
				table.insert(chargeNotches, new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(3 + CHARGE_W * tiers[i].at / full, 3 + CHARGE_H / 2),
					Size = UDim2.fromOffset(2, CHARGE_H + 6), BackgroundTransparency = 0, BackgroundColor3 = BLACK, ZIndex = 3,
				}, chargeBox))
			end
		end
		local tier = 1
		for i, t in tiers do
			if held >= t.at - 1e-3 then
				tier = i
			end
		end
		if tier > chargeTier and held > 0 then
			chargeFlash = 1 -- reached a tier
		end
		chargeTier, chargeHeld = tier, held
	end

	-- `rows` (optional) replaces the list outright, e.g. build mode's keys (HudController.setControls).
	function hud.setControls(fighting, chargeM2, rows)
		combatOn = fighting
		local key = `{fighting}{chargeM2}`
		if rows then
			local parts = {}
			for _, r in rows do
				table.insert(parts, r[1] .. "=" .. r[2])
			end
			key = "rows:" .. table.concat(parts, ";")
		end
		if key == controlsKey then
			return
		end
		controlsKey, controlsSlide = key, 1
		for _, c in controls:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		for i, row in (if rows then rows elseif fighting then CONTROLS_FIGHT else CONTROLS_FREE) do
			local keyText, label = row[1], row[2]
			if fighting and keyText == "M2" and chargeM2 then
				keyText, label = "HOLD M2", "Charge heavy"
			end
			local line = new("Frame", { LayoutOrder = i, Size = UDim2.new(1, 0, 0, 26) }, controls)
			-- key cap on an offset shadow slab (Persona style): red in combat, black out of it
			local shadow = new("Frame", { Position = UDim2.fromOffset(3, 3), Size = UDim2.fromOffset(28, 24), BackgroundTransparency = 0, BackgroundColor3 = if fighting then D.HUD_SLASH_COLOR else BLACK, ZIndex = 1 }, line)
			local cap = new("TextLabel", {
				FontFace = FONT, TextSize = 18, TextColor3 = BLACK, Text = keyText, BackgroundTransparency = 0, BackgroundColor3 = Color3.new(1, 1, 1),
				AutomaticSize = Enum.AutomaticSize.X, Size = UDim2.fromOffset(28, 24), ZIndex = 2,
			}, line)
			new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 3) }, cap)
			local text = new("TextLabel", {
				FontFace = FONT, TextSize = 18, TextColor3 = Color3.new(1, 1, 1), Text = label, TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2.fromOffset(0, 1), Size = UDim2.new(1, 0, 1, 0), ZIndex = 2,
			}, line)
			new("UIStroke", { Thickness = 2, Color = BLACK }, text)
			-- the label starts after the cap (its width is only known once the text measured)
			local function place()
				local w = cap.AbsoluteSize.X / math.max(controlsScale.Scale, 1e-3)
				shadow.Size = UDim2.fromOffset(w, 24)
				text.Position = UDim2.fromOffset(w + 12, 1)
			end
			place()
			cap:GetPropertyChangedSignal("AbsoluteSize"):Connect(place)
		end
	end

	-- name = "crit" | "m2"; untilT/now in server time (the RCooldownUntil / M2CooldownUntil attributes)
	function hud.cooldown(name, untilT, now)
		local c = cds[name]
		if untilT > c.untilT + 1e-3 then
			c.total = math.max(untilT - now, 1e-3) -- a new cooldown started; a cut (Technical) keeps the old total
		end
		c.untilT = untilT
		local t = if untilT <= now then 1 else math.clamp(1 - (untilT - now) / c.total, 0, 1)
		if t >= 1 and c.t < 1 then
			c.flash = 1 -- ready
		end
		c.t = t
	end

	function hud.setTraits(ids)
		for i, card in cards do
			local id = ids[i]
			if id == "" then
				id = nil
			end
			if card.id == id then
				continue
			end
			card.id = id
			local data = if id and Paths.findPerk(id) then Paths.perk(id) else nil
			card.data = data
			card.icon.Visible = data ~= nil and data.icon ~= nil
			if data and data.icon then
				card.icon.ImageRectOffset = Vector2.new((data.icon % 4) * CELL, (data.icon // 4) * CELL)
				card.icon.ImageRectSize = Vector2.new(CELL, CELL)
			end
			card.tagText.Text = if data then string.upper(data.name) .. "!" else ""
			card.tagBack.BackgroundColor3 = if data and data.color then data.color else D.HUD_SLASH_COLOR
			card.litUntil = 0
			card.bg.ImageTransparency = if data then 0 else 0.25
		end
	end

	local function light(card: Card, now: number)
		local fresh = now >= card.tagUntil -- tag gone or on its way out: slam it back in
		card.litUntil = now + D.HUD_TRAIT_PROC_HOLD
		card.sat = 1
		card.pop = 1
		card.flash.ImageTransparency = 0
		TweenService:Create(card.flash, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { ImageTransparency = 1 }):Play()
		if fresh then
			-- name tag slams in from the left, holds, then whips out to the right (step)
			local tag = card.tag
			card.tagOut = false
			card.tagScale.Scale = 1
			tag.Visible = true
			tag.Size = UDim2.fromOffset(card.tagText.TextBounds.X + 18, 26) -- measured now: the font may load late
			-- lowest row no other visible tag (incl. one on its way out) is using
			local used = {}
			for _, other in cards do
				if other ~= card and other.tag.Visible then
					used[other.tagRow] = true
				end
			end
			local row = 0
			while used[row] do
				row += 1
			end
			card.tagRow = row
			-- Roblox rotates around the centre, which drops a long tag's left end; lift it so every
			-- tag's left end sits on its row and the rows stay parallel bands
			local y = TAG_Y + row * TAG_ROW + (tag.Size.X.Offset / 2) * math.sin(math.rad(TAG_TILT))
			card.tagY = y
			tag.Position = UDim2.fromOffset(TAG_X - 40, y)
			TweenService:Create(tag, TweenInfo.new(0.16, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(TAG_X, y) }):Play()
			card.tagUntil = now + 1.2
		end
	end

	-- key = a Mods field or a perk's `proc` key (Fighter.proc on the server)
	function hud.proc(key)
		local now = os.clock()
		for _, card in cards do
			local data = card.data
			if data and ((data.mods and data.mods[key] ~= nil) or data.proc == key) then
				light(card, now)
			end
		end
	end

	-- sustained proc (Fleet Foot while you're running): stays lit, no re-slam every frame
	function hud.hold(key, now)
		for _, card in cards do
			local data = card.data
			if data and data.mods and data.mods[key] ~= nil then
				if now >= card.litUntil then
					light(card, now)
				else
					card.litUntil = math.max(card.litUntil, now + 0.6)
				end
			end
		end
	end

	function hud.step(dt, now, fighting)
		-- beat clock: everything bops on D.HUD_BPM, only mid-fight (the last bop decays out)
		local beatIndex = math.floor(now * D.HUD_BPM / 60)
		if beatIndex ~= lastBeatIndex and fighting then
			lastBeatIndex = beatIndex
			beat = 1
		end
		beat *= math.exp(-dt * 9)
		uiScale.Scale = baseScale * (1 + 0.022 * beat)
		if workspace.CurrentCamera then
			baseScale = math.clamp(workspace.CurrentCamera.ViewportSize.Y / 900, 0.6, 1.3)
		end

		-- slide springs: fixed 1/120 substeps (real time even at low fps; a hitch is capped at 0.1s),
		-- then snapped to rest once settled so the HUD goes fully still instead of creeping sub-pixel
		local left = math.min(dt, 0.1)
		while left > 0 do
			local h = math.min(left, 1 / 120)
			left -= h
			barsV += (SLIDE_K * (slideTarget - barsP) - SLIDE_C * barsV) * h
			barsP += barsV * h
			cardsV += (CARD_K * (slideTarget - cardsP) - CARD_C * cardsV) * h
			cardsP += cardsV * h
		end
		if math.abs(slideTarget - barsP) < 1e-3 and math.abs(barsV) < 1e-2 then
			barsP, barsV = slideTarget, 0
		end
		if math.abs(slideTarget - cardsP) < 1e-3 and math.abs(cardsV) < 1e-2 then
			cardsP, cardsV = slideTarget, 0
		end
		root.Position = UDim2.fromOffset(math.round(16 - barsP * (16 + SLIDE_DIST * uiScale.Scale)), ROOT_Y)
		root.Visible = barsP < 0.99 or cardsP < 0.99 or slideTarget == 0

		shake *= math.exp(-dt * 14)
		barsGroup.Position = UDim2.fromOffset((math.random() - 0.5) * 2 * shake, (math.random() - 0.5) * 2 * shake)

		for _, bar in { guard, hp, adr } do
			if bar.shown < bar.target then
				bar.shown = math.min(bar.target, bar.shown + dt * 1.5) -- gains ease in
			end
			cut(bar.fill, bar.grad, bar.b, bar.shown)
			bar.flash = math.max(0, bar.flash - dt * 8)
			local c = bar.color
			if bar == adr and adrFull and fighting then
				c = if beatIndex % 2 == 0 then D.HUD_ADR_COLOR else Color3.fromRGB(255, 220, 40) -- MAX: flips on the beat
			end
			bar.fill.ImageColor3 = c:Lerp(Color3.new(1, 1, 1), bar.flash)
		end
		showFocus(focusOn)
		if focusOn then
			-- notches: dim on the empty track, black once the fill has passed them
			for _, n in notches do
				n.frame.BackgroundColor3 = if focusValue >= n.at - 1e-3 then BLACK else Color3.fromRGB(70, 85, 120)
			end
			if focus.shown < focus.target then
				focus.shown = math.min(focus.target, focus.shown + dt * 1.5)
			end
			cut(focus.fill, focus.grad, focus.b, focus.shown)
			focus.flash = math.max(0, focus.flash - dt * 8)
			-- full: pulses white on the beat (ready for Lightshow)
			local c = if focusFull and beatIndex % 2 == 1 then Color3.new(1, 1, 1) else focus.color
			focus.fill.ImageColor3 = c:Lerp(Color3.new(1, 1, 1), focus.flash)
		else
			focus.fill.Visible = false
		end

		-- charge bar: pops in, fades out after the release (holding its last value)
		local s = baseScale
		chargeVis += ((if chargeOn then 1 else 0) - chargeVis) * (1 - math.exp(-dt * (if chargeOn then 30 else 8)))
		chargeBox.Visible = chargeVis > 0.01 and #chargeTiers > 0
		if chargeBox.Visible then
			local full = chargeTiers[#chargeTiers].at
			chargeFlash = math.max(0, chargeFlash - dt * 5)
			chargeFill.Size = UDim2.fromOffset(math.round(CHARGE_W * math.clamp(chargeHeld / full, 0, 1)), CHARGE_H)
			chargeFill.BackgroundColor3 = (CHARGE_COLORS[chargeTier] or CHARGE_COLORS[#CHARGE_COLORS]):Lerp(Color3.new(1, 1, 1), chargeFlash)
			chargeBox.BackgroundTransparency = 1 - chargeVis * 0.85
			chargeFill.BackgroundTransparency = 1 - chargeVis
			for _, n in chargeNotches do
				n.BackgroundTransparency = 1 - chargeVis
			end
			chargeBox.UIScale.Scale = s * (1 + 0.25 * chargeFlash)
		end
		if not chargeOn then
			chargeTier = 0
		end

		-- controls: slide in from the left whenever the set changes
		controlsSlide *= math.exp(-dt * 12)
		controlsScale.Scale = s
		controls.GroupTransparency = controlsSlide
		controls.Position = UDim2.new(0, math.round(16 - 40 * controlsSlide), 1, -16)
		for _, c in cds do
			cut(c.fill, c.grad, c.b, c.t)
			c.flash = math.max(0, c.flash - dt * 5)
			-- dimmed while recharging, full colour + a flash when ready
			local base = if c.t >= 1 then c.color else c.color:Lerp(Color3.fromRGB(40, 40, 48), 0.45)
			c.fill.ImageColor3 = base:Lerp(Color3.new(1, 1, 1), c.flash)
			-- shown while recharging and for HUD_CD_FADE_DELAY after it's ready, then fades out (user, 2026-10-17)
			if c.t < 1 then
				c.lastBusy = now
			end
			local want = if now - c.lastBusy < D.HUD_CD_FADE_DELAY then 1 else 0
			c.vis += (want - c.vis) * (1 - math.exp(-dt * (if want > c.vis then 20 else 6)))
			c.housing.ImageTransparency = 1 - c.vis
			c.fill.ImageTransparency = 1 - c.vis
			c.fill.Visible = c.fill.Visible and c.vis > 0.01
		end

		for i, card in cards do
			local lit = now < card.litUntil
			local target = if lit then 1 else D.HUD_TRAIT_IDLE_SAT
			card.sat += (target - card.sat) * (1 - math.exp(-dt * (if lit then 30 else 3)))
			card.pop *= math.exp(-dt * 7)
			local base = if card.data then (card.data.color or Color3.fromRGB(200, 200, 200)) else EMPTY_CARD
			card.bg.ImageColor3 = if card.data then saturate(base, card.sat) else base
			card.icon.ImageColor3 = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(150, 150, 150), (1 - card.sat) * 0.6)
			-- each card hops in turn on the beat (a ripple across the row); lit cards hop harder
			local hop = if (beatIndex % D.PERK_SLOTS) + 1 == i then beat * (if lit then 9 else 4) else 0
			card.root.Position = UDim2.fromOffset(card.baseX - math.round((cardsP - barsP) * SLIDE_DIST), card.baseY - hop)
			card.scale.Scale = 1 + 0.35 * card.pop + (if lit then 0.06 * beat else 0)
			if card.tag.Visible and not card.tagOut and now >= card.tagUntil then
				card.tagOut = true
				local out = TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In)
				TweenService:Create(card.tag, out, { Position = UDim2.fromOffset(TAG_X + 36, card.tagY) }):Play()
				local shrink = TweenService:Create(card.tagScale, out, { Scale = 0 })
				shrink.Completed:Connect(function()
					if card.tagOut then
						card.tag.Visible = false
					end
				end)
				shrink:Play()
			end
			card.root.Rotation = card.baseRot + math.sin(card.pop * 14) * 10 * card.pop
		end
	end

	return hud
end

-- The side menu (MenuController), cutscenes and build mode slide the live HUD out. Each asks under its own
-- `reason` (default: the menu / cutscene one); the HUD stays out while ANY reason holds it, so closing the
-- menu mid build mode doesn't bring the bars back.
local slideOut: ((boolean) -> ())? = nil
local outBy: { [string]: boolean } = {}
function HudController.setOut(out: boolean, reason: string?)
	outBy[reason or "default"] = if out then true else nil
	if slideOut then
		slideOut(next(outBy) ~= nil)
	end
end

-- Build mode (BuildController) swaps the bottom-left controls list for its own keys; nil = back to normal.
local controlsOverride: { { string } }? = nil
function HudController.setControls(rows: { { string } }?)
	controlsOverride = rows
end

-- CombatController feeds the M2 charge bar every frame (Hud.setCharge).
local chargeSink: ((number?, { any }?) -> ())? = nil
function HudController.setCharge(held: number?, tiers: { any }?)
	if chargeSink then
		chargeSink(held, tiers)
	end
end

-- Main hands over each life's combat mode (CombatModeController) so the controls list follows it.
local combatMode: any = nil
function HudController.setMode(mode: any)
	combatMode = mode
end

function HudController.init()
	local player = Players.LocalPlayer
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false) -- the HUD's green bar replaces it
	end)
	local hud = HudController.build(player:WaitForChild("PlayerGui"))
	slideOut = hud.setOut
	chargeSink = hud.setCharge
	-- ponytail: keyboard keys only; touch-only devices have MobileButtons there instead, gamepad gets no list
	local controlsGui = hud.gui:FindFirstChildOfClass("CanvasGroup") :: CanvasGroup
	local function keyboardOnly()
		controlsGui.Visible = UserInputService.KeyboardEnabled
	end
	keyboardOnly()
	UserInputService.LastInputTypeChanged:Connect(keyboardOnly)
	local walkSpeed = StarterPlayer.CharacterWalkSpeed

	local function traits()
		local raw = player:GetAttribute("PerkSlots")
		hud.setTraits(if typeof(raw) == "string" then string.split(raw, ",") else {})
	end
	player:GetAttributeChangedSignal("PerkSlots"):Connect(traits)
	traits()
	-- "fighting" = we were attacker or victim of any hit result (incl. blocks/parries) or a dodge lately
	local lastFightAt = -math.huge
	local function exchange(a: unknown, v: unknown)
		local character = player.Character
		if character and (a == character or v == character) then
			lastFightAt = os.clock()
		end
	end
	local Net = Paths.shared("Net")
	Net.get("HitResult").OnClientEvent:Connect(exchange)
	Net.get("Dodged").OnClientEvent:Connect(exchange)
	Net.get("TraitProc").OnClientEvent:Connect(function(key: unknown)
		if typeof(key) == "string" then
			hud.proc(key)
		end
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		local now = os.clock()
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		hud.gui.Enabled = humanoid ~= nil
		hud.focusBoard.Adornee = if humanoid and humanoid.Health > 0 then humanoid.RootPart else nil
		if character and humanoid then
			local function num(name: string, default: number): number
				local v = character:GetAttribute(name)
				return if typeof(v) == "number" then v else default
			end
			local gMax = num("GuardMax", D.GUARD_MAX)
			hud.set(num("Guard", gMax), gMax, humanoid.Health, humanoid.MaxHealth, num("Healable", 0), num("Adrenaline", 0), num("AdrenalineMax", D.ADR_MAX))
			hud.setFocus(num("Focus", 0), num("FocusMax", D.FOCUS.max), character:GetAttribute("FocusOn") == true)
			local style = MoveSchema.ofModel(character)
			local m2 = style.m2 and style.moves[style.m2]
			hud.setControls(combatMode ~= nil and combatMode.isOn(), m2 ~= nil and m2.charge ~= nil and m2.charge.swing ~= nil, controlsOverride)
			-- ponytail: server-mirrored timers, so a bar starts ~half a ping late; read CombatController's predicted S timers if that shows
			local serverNow = workspace:GetServerTimeNow()
			hud.cooldown("crit", num("RCooldownUntil", 0), serverNow)
			hud.cooldown("m2", num("M2CooldownUntil", 0), serverNow)
			if humanoid.MoveDirection.Magnitude > 0.1 and humanoid.WalkSpeed > walkSpeed + 0.5 then
				hud.hold("runSpeed", now) -- Fleet Foot is lit while you run
			end
		end
		hud.step(dt, now, now - lastFightAt < D.LOADOUT_COMBAT_LOCK)
	end)
end

return HudController
