--!strict
-- Shield billboard on every fighter's HumanoidRootPart (players and dummies), driven by the
-- state the server replicates (MState / MStateEnds / BlockPressAt attributes), so everyone
-- sees the same thing:
--   block      shield shown
--   weak guard (held >= HOLD_STRIP_THRESHOLD) a transparent copy pulses out behind it
--   guard break shield darkens + goes slightly transparent, Crack grows in on top, and both
--               fade out together exactly as the guard-break stun ends
--
-- Visibility (per viewer): the billboard is AlwaysOnTop so it shows through bodies, but
--   * distance is measured from YOUR character (not the camera): opaque to SHIELD_VISIBLE_DIST,
--     fading out to SHIELD_HIDE_DIST, gone beyond it
--   * a line-of-sight ray from the camera ignores every character, so only real geometry
--     (walls, floors) hides it: people in other rooms don't see your shield
-- Each image's final transparency = its mode look (the `look` values) faded by that factor.
-- The billboard is sized in studs (scale UDim2), so it scales with distance like the
-- character instead of staying a fixed pixel size.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Enums = Paths.shared("Enums")
local Net = Paths.shared("Net")

local State = Enums.State
local FIGHTER_TAG = "MidoriFighter"

-- ImageLabel templates; style them in Studio, they're cloned as-is (only layout,
-- transparency and the broken tint are driven from here).
local Art = Paths.Assets:WaitForChild("2d")
local SHIELD_TEMPLATE = Art:WaitForChild("Shield") :: ImageLabel
local CRACK_TEMPLATE = Art:WaitForChild("Crack") :: ImageLabel

-- The billboard is bigger than the shield so the weak-guard ghost can grow past its edge.
local BOX = 1 + D.SHIELD_WEAK_PULSE_SCALE + 0.1
local INNER = 1 / BOX
local LOS_MAX_PASSES = 4 -- see-through parts / bodies skipped before giving up

type Mode = "none" | "block" | "weak" | "broken"

type Shield = {
	model: Model,
	root: BasePart,
	gui: BillboardGui,
	main: ImageLabel,
	ghost: ImageLabel,
	crack: ImageLabel,
	-- Mode look per image (transparency before the visibility fade); tweens drive these.
	look: { main: NumberValue, ghost: NumberValue, crack: NumberValue },
	mode: Mode,
	tweens: { Tween },
	los: number, -- smoothed 0..1 line-of-sight
	losTarget: number,
	nextLos: number,
	brokenFrom: number, -- guard-break fade window (server time)
	brokenUntil: number,
	parryUntil: number, -- shield is tinted PARRY_COLOR until then (server time)
	-- Guard meter inside the shield: `main` is the dim empty shield, `fill` is a full copy
	-- clipped from the bottom up to the guard level.
	fillClip: Frame,
	fill: ImageLabel,
	guardShown: number,
}

local brokenFade: (s: Shield, now: number) -> ()

local ShieldController = {}

local player = Players.LocalPlayer
local shields: { [Model]: Shield } = {}
local container: ScreenGui
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function image(parent: Instance, name: string, template: ImageLabel, z: number): ImageLabel
	local img = template:Clone()
	img.Name = name
	img.AnchorPoint = Vector2.new(0.5, 0.5)
	img.Position = UDim2.fromScale(0.5, 0.5)
	img.Size = UDim2.fromScale(INNER, INNER)
	img.ImageTransparency = 1
	img.ZIndex = z
	img.Parent = parent
	return img
end

-- A full shield copy inside `main`, clipped to its bottom part (see setLevel). Children of
-- `main` follow its size/pop tweens, so the meter always lines up with the shield.
local function meterLayer(main: ImageLabel, name: string, z: number): (Frame, ImageLabel)
	local clip = Instance.new("Frame")
	clip.Name = name
	clip.BackgroundTransparency = 1
	clip.BorderSizePixel = 0
	clip.ClipsDescendants = true
	clip.AnchorPoint = Vector2.new(0, 1)
	clip.Position = UDim2.fromScale(0, 1)
	clip.Size = UDim2.fromScale(1, 1)
	clip.ZIndex = z
	clip.Parent = main
	local img = SHIELD_TEMPLATE:Clone()
	img.Name = "Image"
	img.AnchorPoint = Vector2.new(0, 1)
	img.Position = UDim2.fromScale(0, 1)
	img.Size = UDim2.fromScale(1, 1)
	img.ImageTransparency = 1
	img.ZIndex = z
	img.Parent = clip
	return clip, img
end

-- Show the bottom `level` (0-1) of a meter layer; the image inside stays shield-sized.
local function setLevel(clip: Frame, img: ImageLabel, level: number)
	clip.Visible = level > 0.001
	if clip.Visible then
		clip.Size = UDim2.fromScale(1, level)
		img.Size = UDim2.fromScale(1, 1 / level)
	end
end

local function value(): NumberValue
	local v = Instance.new("NumberValue")
	v.Value = 1
	return v
end

local function cancelTweens(s: Shield)
	for _, t in s.tweens do
		t:Cancel()
	end
	table.clear(s.tweens)
end

local function tween(s: Shield, inst: Instance, info: TweenInfo, props: { [string]: any })
	local t = TweenService:Create(inst, info, props)
	table.insert(s.tweens, t)
	t:Play()
end

local function quick(time: number, style: Enum.EasingStyle?): TweenInfo
	return TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
end

local function desiredMode(s: Shield, now: number): Mode
	local state = s.model:GetAttribute("MState")
	if state == State.GuardBreakStun then
		return "broken"
	end
	-- Our own shield follows CombatController's prediction (no round-trip wait); everyone
	-- else's follows the server.
	local pressAttr = "BlockPressAt"
	local predicted = if s.model == player.Character then s.model:GetAttribute("LocalMState") else nil
	if predicted ~= nil then
		state = predicted
		pressAttr = "LocalBlockPressAt"
	end
	if Enums.GUARDING[state] then
		local press = s.model:GetAttribute(pressAttr)
		if typeof(press) == "number" and now - press >= D.HOLD_STRIP_THRESHOLD then
			return "weak"
		end
		return "block"
	end
	return "none"
end

-- Guard break: one shared fade so the shield and crack go out as one piece, holding most of
-- the stun (quartic ease-in) and gone exactly when it ends.
function brokenFade(s: Shield, now: number)
	local span = s.brokenUntil - s.brokenFrom
	local a = if span > 0 then math.clamp((now - s.brokenFrom) / span, 0, 1) else 1
	a = a ^ 4
	s.look.main.Value = D.SHIELD_BROKEN_TRANSPARENCY + (1 - D.SHIELD_BROKEN_TRANSPARENCY) * a
	s.look.crack.Value = a
end

local function enter(s: Shield, mode: Mode, now: number)
	local prev = s.mode
	s.mode = mode
	cancelTweens(s)
	local look = s.look

	if mode == "none" then
		if prev == "broken" then
			-- The stun fade already ran to the end; just make sure nothing lingers.
			look.main.Value = 1
			look.crack.Value = 1
		else
			tween(s, look.main, quick(D.SHIELD_FADE), { Value = 1 })
		end
		look.ghost.Value = 1
		return
	end

	if mode == "broken" then
		local ends = s.model:GetAttribute("MStateEnds")
		local stun = if typeof(ends) == "number" and ends > now then ends - now else D.GUARD_BREAK_STUN
		look.ghost.Value = 1
		s.main.ImageColor3 = D.SHIELD_BROKEN_COLOR
		s.main.Size = UDim2.fromScale(INNER, INNER)
		s.crack.Size = UDim2.fromScale(0, 0)
		tween(s, s.crack, quick(D.SHIELD_CRACK_GROW, Enum.EasingStyle.Back), { Size = UDim2.fromScale(INNER, INNER) })
		-- The shared fade is computed every frame from these times (see brokenFade), never
		-- through a Changed signal: a deferred Changed could land after the stun ended and
		-- leave the shield and crack stuck half-faded.
		s.brokenFrom = now
		s.brokenUntil = now + stun
		brokenFade(s, now)
		return
	end

	-- block / weak: a normal shield (fresh after a guard break).
	s.main.ImageColor3 = SHIELD_TEMPLATE.ImageColor3
	look.crack.Value = 1
	if prev == "none" or prev == "broken" then
		look.main.Value = 1
		s.main.Size = UDim2.fromScale(INNER * 0.8, INNER * 0.8)
		tween(s, look.main, quick(D.SHIELD_FADE), { Value = 0 })
		tween(s, s.main, quick(D.SHIELD_FADE, Enum.EasingStyle.Back), { Size = UDim2.fromScale(INNER, INNER) })
	else
		look.main.Value = 0
		s.main.Size = UDim2.fromScale(INNER, INNER)
	end
	if mode == "block" then
		look.ghost.Value = 1
	end
end

local function pulse(s: Shield, now: number)
	-- Ripple: grows from the shield's size outward while fading, then starts again.
	local phase = (now * D.SHIELD_WEAK_PULSE_SPEED) % 1
	local k = INNER * (1 + D.SHIELD_WEAK_PULSE_SCALE * phase)
	s.ghost.Size = UDim2.fromScale(k, k)
	s.look.ghost.Value = D.SHIELD_WEAK_TRANSPARENCY + (1 - D.SHIELD_WEAK_TRANSPARENCY) * phase
end

---- Visibility ----

local function characterOf(part: Instance): Model?
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

-- True if real geometry sits between the camera and `target`. Bodies (any model with a
-- Humanoid, players and NPCs) and see-through / non-colliding parts never hide a shield.
local function blocked(from: Vector3, target: Vector3): boolean
	local exclude: { Instance } = { container }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	for model in shields do
		table.insert(exclude, model)
	end
	local dir = target - from
	for _ = 1, LOS_MAX_PASSES do
		rayParams.FilterDescendantsInstances = exclude
		local hit = workspace:Raycast(from, dir, rayParams)
		if not hit then
			return false
		end
		local part = hit.Instance
		local body = characterOf(part)
		if body then
			table.insert(exclude, body)
		elseif part.Transparency >= 0.5 or not part.CanCollide then
			table.insert(exclude, part)
		else
			return true
		end
	end
	return false
end

-- 1 = fully visible, 0 = hidden, for the viewer's character at `viewer`.
local function distanceFactor(s: Shield, viewer: Vector3): number
	local d = (s.root.Position - viewer).Magnitude
	local span = D.SHIELD_HIDE_DIST - D.SHIELD_VISIBLE_DIST
	return math.clamp((D.SHIELD_HIDE_DIST - d) / span, 0, 1)
end

---- Lifetime ----

local function remove(model: Model)
	local s = shields[model]
	if s then
		shields[model] = nil
		cancelTweens(s)
		s.gui:Destroy()
		for _, v in s.look do
			v:Destroy()
		end
	end
end

local function add(model: Instance)
	if not model:IsA("Model") or shields[model] then
		return
	end
	local root = model:FindFirstChild("HumanoidRootPart") or model:WaitForChild("HumanoidRootPart", 10)
	if not root or not model.Parent or shields[model] then
		return
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "MidoriShield"
	gui.Adornee = root :: BasePart
	-- Scale-only size = studs: it shrinks with distance like the character does.
	gui.Size = UDim2.fromScale(D.SHIELD_SIZE * BOX, D.SHIELD_SIZE * BOX)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = true -- through bodies; walls are handled by the line-of-sight check
	gui.ClipsDescendants = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.ResetOnSpawn = false
	gui.Enabled = false

	local main = image(gui, "Shield", SHIELD_TEMPLATE, 2)
	local fillClip, fill = meterLayer(main, "Fill", 2)
	local s: Shield = {
		model = model,
		root = root :: BasePart,
		gui = gui,
		ghost = image(gui, "Ghost", SHIELD_TEMPLATE, 1),
		main = main,
		crack = image(gui, "Crack", CRACK_TEMPLATE, 3),
		fillClip = fillClip,
		fill = fill,
		guardShown = 1,
		look = { main = value(), ghost = value(), crack = value() },
		mode = "none",
		tweens = {},
		los = 0,
		losTarget = 0,
		nextLos = 0,
		brokenFrom = 0,
		brokenUntil = 0,
		parryUntil = 0,
	}
	gui.Parent = container
	shields[model] = s

	model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			remove(model)
		end
	end)
end

function ShieldController.init()
	container = Instance.new("ScreenGui")
	container.Name = "MidoriShields"
	container.ResetOnSpawn = false
	container.Parent = player:WaitForChild("PlayerGui")

	CollectionService:GetInstanceAddedSignal(FIGHTER_TAG):Connect(function(model)
		task.spawn(add, model)
	end)
	CollectionService:GetInstanceRemovedSignal(FIGHTER_TAG):Connect(function(model)
		if model:IsA("Model") then
			remove(model)
		end
	end)
	for _, model in CollectionService:GetTagged(FIGHTER_TAG) do
		task.spawn(add, model)
	end

	-- Landed parry: the parrier's (the victim's) shield turns PARRY_COLOR.
	Net.get("HitResult").OnClientEvent:Connect(function(_attacker: Model, victim: Model, result: string, _pos: Vector3, info: any)
		local s = shields[victim]
		if s and result == Enums.Result.Parried then
			local recovery = if type(info) == "table" and type(info.stun) == "number" then info.stun else D.PARRY_RECOVERY
			s.parryUntil = workspace:GetServerTimeNow() + recovery + D.SHIELD_FADE
		end
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		local now = workspace:GetServerTimeNow()
		local clock = os.clock()
		local camera = workspace.CurrentCamera
		local mine = player.Character
		local myRoot = mine and mine:FindFirstChild("HumanoidRootPart") :: BasePart?
		local viewer = if myRoot then myRoot.Position elseif camera then camera.Focus.Position else Vector3.zero

		for model, s in shields do
			local mode = desiredMode(s, now)
			if mode ~= s.mode then
				enter(s, mode, now)
			end
			if s.mode == "weak" then
				pulse(s, now)
			elseif s.mode == "broken" then
				brokenFade(s, now)
			end
			if s.mode ~= "broken" then
				-- Parry tint lasts through the parry recovery and the fade-out after it.
				local tint = if now < s.parryUntil then D.PARRY_COLOR else SHIELD_TEMPLATE.ImageColor3
				s.main.ImageColor3 = tint
				s.ghost.ImageColor3 = tint
				s.fill.ImageColor3 = tint
			end

			-- Guard meter from the replicated Guard: losses snap instantly, nothing lingers
			-- (user, 2026-10-10); regen eases up.
			local g, gMax = model:GetAttribute("Guard"), model:GetAttribute("GuardMax")
			local ratio = if typeof(g) == "number" and typeof(gMax) == "number" and gMax > 0 then math.clamp(g / gMax, 0, 1) else 1
			s.guardShown = if ratio < s.guardShown then ratio else s.guardShown + (ratio - s.guardShown) * (1 - math.exp(-dt / 0.06))
			setLevel(s.fillClip, s.fill, s.guardShown)

			local look = s.look
			local showing = look.main.Value < 1 or look.ghost.Value < 1 or look.crack.Value < 1
			local vis = 0
			if showing then
				if model == mine then
					vis = 1 -- your own shield is always fully visible to you
				else
					vis = distanceFactor(s, viewer)
					if vis > 0 and camera then
						if clock >= s.nextLos then
							s.nextLos = clock + D.SHIELD_LOS_INTERVAL
							s.losTarget = if blocked(camera.CFrame.Position, s.root.Position) then 0 else 1
						end
					else
						s.losTarget = 0
					end
					-- Ease line of sight so stepping round a corner fades instead of popping.
					local step = dt / D.SHIELD_LOS_FADE
					s.los = if s.los < s.losTarget then math.min(s.los + step, s.losTarget) else math.max(s.los - step, s.losTarget)
					vis *= s.los
				end
			else
				s.los, s.losTarget, s.nextLos = 0, 0, 0 -- re-check right away next time
			end

			s.gui.Enabled = vis > 0
			if vis > 0 then
				-- While guarding, `main` is the dim empty shield and the meter layers carry the
				-- real opacity; a broken shield keeps its own look with no meter.
				local metered = s.mode ~= "broken"
				local alpha = (1 - look.main.Value) * vis
				s.main.ImageTransparency = 1 - alpha * (if metered then D.SHIELD_EMPTY_OPACITY else 1)
				s.fill.ImageTransparency = if metered then 1 - alpha else 1
				s.ghost.ImageTransparency = 1 - (1 - look.ghost.Value) * vis
				s.crack.ImageTransparency = 1 - (1 - look.crack.Value) * vis
			end
		end
	end)
end

return ShieldController
