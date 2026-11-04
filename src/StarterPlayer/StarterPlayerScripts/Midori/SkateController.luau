--!strict
-- Skateboard (user, 2026-10-18): a 1:1 port of the reference game's skate MOVEMENT, with every combat
-- part removed (no hitboxes, damage, team colours or ult). Numbers: D.SKATE; (user) there = tuned by
-- the user from playing the original. Runs on our own character (we own its physics);
-- SkateService puts the board on for everyone. Per frame = per 60fps frame, scaled by dt.
--
--   B            hop on / off (can't step off for onLock; hop-on cooldown after stepping off)
--   (always)     the board points exactly where the camera does ("perfect control", user), ground
--                or air; shift lock is forced on while riding, so the mouse steers (no right-click)
--   M1           push: ground only, +pushBonus pushDelay after the press (an ollie, Q, trick or
--                stepping off before then cancels it)
--   M2           ollie: a hop, ground or air; during a trick it's worth +ollieTrickBonus on landing
--   Jump         on the ground: a lower board jump, then jumpCooldown (user). Within trickLedge of
--                ROLLING off a ledge / ramp: a trick (normal jump height, user) worth +trickBonus on
--                landing; more presses in that air replay trick animations (cosmetic combo)
--   Q (hold)     freeze in place (mid-air too) and aim; let go (or lungeMaxHold) = lunge at your
--                old speed + lungeBonus, holding your height for lungeHold (rising if you look up)
--   speed        drains by D.SKATE.decay (halved in the air), walls and damage drain it, downhill
--                feeds it under slopeCap, a ramp's lip launches you. 0 speed past idleBail = off.
--
-- Vertical motion copies the reference's force stack: while any lift is active (ollie, trick, lunge
-- hold, ramp push) your up speed is SET to their sum; otherwise gravity has it. Q's freeze holds
-- every axis at 0. Optional assets (none exist yet, so they're just slots):
--   Assets.Animations.Skate: Ride (looped), Push, Ollie, Charge, Lunge, Jump, Fall, Land, Tricks/*
--   Assets.Sfx.Skate: On, Off, Loop (looped), Push, Stunt (trick), Land, Ollie, Lunge
--   Assets.Vfx.SkateSpeedLines (a Part with a ParticleEmitter; else a built-in placeholder)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local SkateMath = Paths.shared("SkateMath")
local CombatMath = Paths.shared("CombatMath")
local State = Paths.shared("Enums").State
local CameraFov = Paths.client("CameraFov")

local KEY = Enum.KeyCode.B
local FONT = Font.fromEnum(Enum.Font.LuckiestGuy)
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local HOT = Color3.new(1, 0.2, 0.2)
local CONFIRM_TIMEOUT = 1.5 -- the server has this long to put "Skating" on, else we step off
local LIFT_HOLD = 0.05 -- jump-like lifts hold their up speed this long (so the Humanoid's ground snap can't eat it)
local JUMP_LOCK_DELAY = 0.1 -- the jump cooldown kicks in this long after takeoff (the jump itself must launch first)
local GROUND_TRIES = 3 -- the ground ray looks past this many non-solid hits
local POP_TIME = 0.5
local METER_DOTS = 30
local METER_HOME = Vector2.new(0.5, 0.8) -- speedometer rest spot, screen fraction (user: lower than the crosshair)
local R6_ROOT_C0 = CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, -0)

local player = Players.LocalPlayer

export type Skate = { isRiding: () -> boolean, press: (string) -> boolean, unpress: (string) -> (), destroy: () -> () }

local SkateController = {}

local function new(class: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(class)
	for k, v in props do
		(inst :: any)[k] = v
	end
	inst.Parent = parent
	return inst
end

-- Per-frame lerp factor for a reference "lerp by `a` each frame", at any frame rate.
local function perFrame(a: number, dt: number): number
	return 1 - (1 - a) ^ (dt * 60)
end

-- CustomShiftLock's ToggleShiftLock bindable (same hook as the P menu).
local function setShiftLock(on: boolean)
	local scripts = player:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("CustomShiftLock")
	local ev = module and module:FindFirstChild("ToggleShiftLock", true)
	if ev and ev:IsA("BindableEvent") then
		ev:Fire(on)
	end
end

local function skateAssets(kind: string): Instance?
	local folder = Paths.Assets:FindFirstChild(kind)
	return folder and folder:FindFirstChild("Skate")
end

-- Assets.Animations.Skate.<name>, if it's an Animation with an id.
local function anim(name: string): Animation?
	local folder = skateAssets("Animations")
	local a = folder and folder:FindFirstChild(name)
	return if a and a:IsA("Animation") and a.AnimationId ~= "" then a else nil
end

local function trickAnims(): { Animation }
	local folder = skateAssets("Animations")
	local tricks = folder and folder:FindFirstChild("Tricks")
	local out = {}
	for _, a in if tricks then tricks:GetChildren() else {} do
		if a:IsA("Animation") and a.AnimationId ~= "" then
			table.insert(out, a)
		end
	end
	return out
end

-- Plays a copy of Assets.Sfx.Skate.<name> on `parent` (nil if there's no such sound yet).
local function sound(name: string, parent: Instance, pitch: number?, looped: boolean?): Sound?
	local folder = skateAssets("Sfx")
	local s = folder and folder:FindFirstChild(name)
	if not s or not s:IsA("Sound") or s.SoundId == "" then
		return nil
	end
	local c = s:Clone()
	c.Looped = looped == true
	c.PlaybackSpeed *= pitch or 1
	c.Parent = parent
	c:Play()
	if not looped then
		Debris:AddItem(c, math.max(c.TimeLength / c.PlaybackSpeed, 1) + 1)
	end
	return c
end

-- The speed meter (the reference had it on the crosshair; user: lower, METER_HOME): a dotted ring (full at meterFull) around the
-- number. Spins in on hop-on, pulses brighter/bigger when you gain, drifts red and shakes from `hot`,
-- "+N" pops rise off it, fades out on hop-off.
type Meter = { show: () -> (), hide: () -> (), update: (number, number, number) -> (), plus: (number) -> (), destroy: () -> () }
local function buildMeter(): Meter
	local S = D.SKATE
	local gui = new("ScreenGui", { Name = "MidoriSkate", ResetOnSpawn = false, Enabled = false, DisplayOrder = 5, IgnoreGuiInset = true })
	local holder = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(METER_HOME.X, METER_HOME.Y), Size = UDim2.fromOffset(116, 116), BackgroundTransparency = 1 }, gui)
	local scale = new("UIScale", {}, holder)
	local dots: { Frame } = {}
	for i = 1, METER_DOTS do
		local a = (i - 1) / METER_DOTS * math.pi * 2
		dots[i] = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, math.sin(a) * 50, 0.5, -math.cos(a) * 50),
			Size = UDim2.fromOffset(5, 13),
			Rotation = math.deg(a),
			BackgroundColor3 = WHITE,
			BorderSizePixel = 0,
		}, holder)
	end
	local number = new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(90, 50), BackgroundTransparency = 1, FontFace = FONT, TextSize = 40, TextColor3 = WHITE, Text = "0" }, holder)
	local numberStroke = new("UIStroke", { Color = BLACK, Thickness = 3 }, number)
	gui.Parent = player:WaitForChild("PlayerGui")

	local fill, alpha, color, last = 0, 1, WHITE, 0
	local fading: RBXScriptConnection? = nil
	local function paint()
		local lit = math.floor(math.clamp(fill, 0, 1) * METER_DOTS + 0.5)
		for i, d in dots do
			d.BackgroundColor3 = color
			d.BackgroundTransparency = if i <= lit then alpha else 0.9 -- unlit dots = the faint back ring
		end
		number.TextColor3 = color
		number.TextTransparency = alpha
		numberStroke.Transparency = 0.5 + alpha * 0.5
	end
	return {
		show = function()
			if fading then
				fading:Disconnect() -- hopped back on mid fade-out
				fading = nil
			end
			gui.Enabled = true
			alpha, color, fill = 0.2, WHITE, 0
			holder.Position = UDim2.fromScale(METER_HOME.X, METER_HOME.Y)
			holder.Rotation = -360
			TweenService:Create(holder, TweenInfo.new(1, Enum.EasingStyle.Quart), { Rotation = 0 }):Play()
		end,
		hide = function()
			-- fade out over 1s, back to the centre and white
			if fading then
				fading:Disconnect()
			end
			local t0 = os.clock()
			fading = RunService.RenderStepped:Connect(function()
				local k = math.min(1, (os.clock() - t0) / 1)
				alpha = 0.2 + 0.8 * (1 - (1 - k) ^ 4)
				color = color:Lerp(WHITE, k)
				holder.Position = holder.Position:Lerp(UDim2.fromScale(METER_HOME.X, METER_HOME.Y), k)
				paint()
				if k >= 1 and fading then
					fading:Disconnect()
					fading = nil
					gui.Enabled = false
				end
			end)
		end,
		update = function(speed: number, smoothed: number, dt: number)
			fill = smoothed
			scale.Scale += (1 - scale.Scale) * perFrame(0.02, dt)
			alpha += (0.2 - alpha) * perFrame(0.05, dt)
			if speed > last then -- gaining: flash full and a touch bigger
				alpha, scale.Scale = 0, 0.065 / 0.06
			end
			last = speed
			if speed >= S.hot then
				color = color:Lerp(HOT, perFrame(0.001, dt))
				local j = speed / 50 * 0.03
				local target = UDim2.fromScale(METER_HOME.X + (math.random() * 2 - 1) * j, METER_HOME.Y + (math.random() * 2 - 1) * j)
				holder.Position = holder.Position:Lerp(target, perFrame(0.02, dt))
			else
				color = color:Lerp(WHITE, perFrame(0.02, dt))
				holder.Position = holder.Position:Lerp(UDim2.fromScale(METER_HOME.X, METER_HOME.Y), perFrame(0.01, dt))
			end
			number.Text = tostring(math.abs(math.ceil(speed)))
			paint()
		end,
		plus = function(n: number)
			local t = new("TextLabel", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, 0, 0.4, 0), BackgroundTransparency = 1, FontFace = FONT, TextScaled = true, TextColor3 = color, Text = `+{n}` }, holder)
			local s = new("UIStroke", { Color = BLACK, Thickness = 3 }, t)
			TweenService:Create(t, TweenInfo.new(1, Enum.EasingStyle.Back), { Position = UDim2.new(0.5, 0, -0.3, 0), Size = UDim2.new(1, 0, 0.2, 0) }):Play()
			TweenService:Create(t, TweenInfo.new(1, Enum.EasingStyle.Quart, Enum.EasingDirection.In), { TextTransparency = 1 }):Play()
			TweenService:Create(s, TweenInfo.new(1, Enum.EasingStyle.Quart, Enum.EasingDirection.In), { Transparency = 1 }):Play()
			Debris:AddItem(t, 1)
		end,
		destroy = function()
			gui:Destroy()
		end,
	}
end

-- Speed lines: a part 20 studs in front of the camera emitting back at it (rate = speed). Uses
-- Assets.Vfx.SkateSpeedLines if it exists, else a plain placeholder.
local function buildSpeedLines(): (BasePart, ParticleEmitter?)
	local vfx = Paths.Assets:FindFirstChild("Vfx")
	local template = vfx and vfx:FindFirstChild("SkateSpeedLines")
	local part: BasePart
	if template and template:IsA("BasePart") then
		part = template:Clone()
	else
		part = new("Part", { Size = Vector3.new(40, 24, 1), Transparency = 1 })
		new("ParticleEmitter", {
			Texture = "rbxasset://textures/particles/sparkles_main.dds",
			EmissionDirection = Enum.NormalId.Front,
			Orientation = Enum.ParticleOrientation.VelocityParallel,
			Speed = NumberRange.new(70, 90),
			Lifetime = NumberRange.new(0.2, 0.3),
			Size = NumberSequence.new(0.15),
			Squash = NumberSequence.new(2.5), -- stretched along their flight: streaks
			Transparency = NumberSequence.new(0.4, 1),
			LightEmission = 1,
			Rate = 0,
			LockedToPart = true,
		}, part)
	end
	part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch = true, false, false, false
	part.Name = "MidoriSkateLines"
	return part, part:FindFirstChildWhichIsA("ParticleEmitter")
end

function SkateController.start(character: Model, run: any): Skate
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local rootJoint = root:FindFirstChild("RootJoint") :: Motor6D?
	local restC0 = if rootJoint then rootJoint.C0 else R6_ROOT_C0
	local animator = humanoid:WaitForChild("Animator") :: Animator
	local S = D.SKATE
	local meter = buildMeter()
	-- speed lines exist only while riding (built on hop-on, destroyed on hop-off)
	local lines: BasePart?, lineEmitter: ParticleEmitter? = nil, nil

	-- the board
	local riding = false
	local onAt = 0 -- when we hopped on (onLock)
	local boardReadyAt = 0 -- hop-on cooldown after stepping off
	local confirmBy = 0
	local lv: LinearVelocity? = nil
	local align: AlignOrientation? = nil
	-- speed
	local speed = 0
	local heading = Vector3.zAxis
	local lastActionAt = 0 -- hop-on / Q: idleBail counts from here
	local lastDashAt = -math.huge
	local lastHealth = humanoid.Health
	-- ground (the leaning ray)
	local onGround = false
	local lastGroundAt = -math.huge
	local lean = CFrame.identity -- body lean to the ground; tilts the next frame's rays too
	-- ramps
	local onRamp, rampLatched = false, false
	local rampSteep, rampStart, rampUp = 0, 0, 0
	-- vertical "force stack": up speed is SET to the sum of active lifts (+ ramp push) while any is on
	local lifts: { { up: number, untilT: number } } = {}
	-- moves
	local tricking = false
	local ollied = false
	local lastTrick, combo, lastTrickIndex = -math.huge, 0, 0
	local lastPush, pushToken = -math.huge, 0
	local lastOllie, lastLunge = -math.huge, -math.huge
	local busyFrom, busyUntil = 0, 0 -- a push / ollie locks the other moves for a moment
	local charging = false
	local chargeStart, chargeSaved = 0, 0
	local jumpedThisAir = false
	local jumpReadyAt = 0
	-- airborne animation state (reference: jumped / v98)
	local airborne, airAt = false, 0
	-- feel
	local fovSmoothed, popFrom, popAt = 0, 0, -math.huge
	-- tracks + sounds
	local tracks: { [string]: AnimationTrack } = {}
	local trickTrack: AnimationTrack? = nil
	local loopSound: Sound? = nil
	-- restore
	local baseHip = humanoid.HipHeight
	local baseJumpHeight, baseJumpPower = humanoid.JumpHeight, humanoid.JumpPower
	local shiftLockWasOn = false
	local conns: { RBXScriptConnection } = {}

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude

	local function flatLook(): Vector3
		local cam = workspace.CurrentCamera
		local look = CombatMath.flat(if cam then cam.CFrame.LookVector else root.CFrame.LookVector)
		return if look.Magnitude > 1e-3 then look.Unit else heading
	end

	-- A solid, non-character hit, looking past up to GROUND_TRIES non-solid parts (reference). A hit on
	-- another character skips that whole character (else its limbs burn the tries: riding over a body
	-- would read as being in the air).
	local function solid(origin: Vector3, dir: Vector3): RaycastResult?
		local skip: { Instance } = { character }
		for _ = 1, GROUND_TRIES do
			params.FilterDescendantsInstances = skip
			local hit = workspace:Raycast(origin, dir, params)
			if not hit then
				return nil
			end
			local model = hit.Instance.Parent
			local body = if model and model:FindFirstChildOfClass("Humanoid") then model
				elseif model and model.Parent and model.Parent:FindFirstChildOfClass("Humanoid") then model.Parent
				else nil
			if hit.Instance.CanCollide and not body then
				return hit
			end
			table.insert(skip, body or hit.Instance)
		end
		return nil
	end

	-- The ground ray: from 1 stud above the root, groundRay long, straight down the body's lean.
	local function groundRay(): RaycastResult?
		local frame = root.CFrame * lean
		return solid((root.CFrame * CFrame.new(0, 1, 0)).Position, -frame.UpVector * S.groundRay)
	end

	local function lift(up: number, time: number)
		table.insert(lifts, { up = up, untilT = os.clock() + time })
	end

	-- Up speed that peaks `height` studs higher, counting the LIFT_HOLD it's held for.
	local function jumpSpeed(height: number): number
		local g = workspace.Gravity
		return -g * LIFT_HOLD + math.sqrt(g * g * LIFT_HOLD * LIFT_HOLD + 2 * g * height)
	end

	-- Your normal (off-board) jump height, whichever of JumpHeight / JumpPower the Humanoid uses.
	local function normalJumpHeight(): number
		return if humanoid.UseJumpPower then baseJumpPower ^ 2 / (2 * workspace.Gravity) else baseJumpHeight
	end

	-- The board jump (jumpMult of your normal one), or none while the jump cooldown runs.
	local function setBoardJump(enabled: boolean)
		local k = if enabled then S.jumpMult else 0
		humanoid.JumpHeight = baseJumpHeight * k
		humanoid.JumpPower = baseJumpPower * math.sqrt(k)
	end

	local function busy(): boolean
		local now = os.clock()
		return charging or (now >= busyFrom and now < busyUntil)
	end

	local function play(name: string, fade: number?): AnimationTrack?
		local a = anim(name)
		if not a then
			return nil
		end
		local t = tracks[name]
		if not t then
			t = animator:LoadAnimation(a)
			tracks[name] = t
		end
		t:Play(fade or 0.1)
		return t
	end
	local function stop(name: string)
		local t = tracks[name]
		if t then
			t:Stop()
		end
	end
	-- Everything but the riding pose (the reference's stopAnimations({"EOn", ...})).
	local function stopMoves()
		for name, t in tracks do
			if name ~= "Ride" then
				t:Stop()
			end
		end
		if trickTrack then
			trickTrack:Stop(0)
		end
	end

	-- FOV pop (+deg, gone over POP_TIME, Quad out) on top of the speed FOV.
	local function pop(deg: number)
		popFrom, popAt = deg, os.clock()
	end
	local function applyFov(dt: number)
		fovSmoothed += (speed / S.meterFull - fovSmoothed) * perFrame(S.fovSmooth, dt)
		local k = math.clamp((os.clock() - popAt) / POP_TIME, 0, 1)
		local popDeg = popFrom * (1 - (1 - (1 - k) ^ 2)) -- Quad out from popFrom to 0
		local base = CameraFov.getBase()
		CameraFov.set("skate", (base + fovSmoothed * S.meterFull * S.fovPerSpeed + popDeg) / base, 0)
	end

	local function off(tellServer: boolean, forced: boolean)
		if not riding then
			return
		end
		riding = false
		boardReadyAt = os.clock() + (if forced then S.offForcedCooldown else S.offCooldown)
		pushToken += 1
		charging, tricking = false, false
		table.clear(lifts)
		rampUp, rampLatched = 0, false
		if tellServer then
			Net.get(Net.Names.Skate):FireServer(false)
		end
		if lv then
			lv:Destroy()
			lv = nil
		end
		if align then
			align:Destroy()
			align = nil
		end
		for _, t in tracks do
			t:Stop(0.2)
		end
		if trickTrack then
			trickTrack:Stop(0.1)
			trickTrack = nil
		end
		if loopSound then
			loopSound:Destroy()
			loopSound = nil
		end
		sound("Off", root)
		play("Off")
		humanoid.HipHeight = baseHip
		humanoid.JumpHeight, humanoid.JumpPower = baseJumpHeight, baseJumpPower
		humanoid.AutoRotate = true
		if not shiftLockWasOn then
			setShiftLock(false) -- back to how you had it before hopping on
		end
		shiftLockWasOn = false
		run.setRooted(false)
		if rootJoint then
			rootJoint.C0 = restC0
		end
		lean = CFrame.identity
		CameraFov.set("skate", nil, 0.6)
		if lines then
			lines:Destroy()
			lines, lineEmitter = nil, nil
		end
		meter.hide()
	end

	local function on()
		local now = os.clock()
		local state = character:GetAttribute("LocalMState")
		if not S.enabled or riding or now < boardReadyAt or humanoid.Health <= 0 or character:GetAttribute("CombatMode") or (state ~= nil and state ~= State.Idle) then
			return
		end
		local att = root:FindFirstChild("RootAttachment") :: Attachment?
		if not att then
			att = new("Attachment", { Name = "RootAttachment" }, root)
		end
		riding, onAt, lastActionAt = true, now, now
		Net.get(Net.Names.Skate):FireServer(true)
		confirmBy = now + CONFIRM_TIMEOUT
		local v = CombatMath.flat(root.AssemblyLinearVelocity)
		-- startSpeed, or a fresh dash's speed (only a dash carries; running doesn't)
		speed = if now - lastDashAt <= S.dashCarry then math.max(S.startSpeed, v.Magnitude) else S.startSpeed
		heading = flatLook()
		lean = CFrame.identity
		onGround = groundRay() ~= nil
		lastGroundAt = if onGround then now else -math.huge
		tricking, ollied, charging, jumpedThisAir, airborne = false, false, false, false, false
		rampLatched, rampUp, jumpReadyAt, fovSmoothed = false, 0, 0, 0
		table.clear(lifts)
		lastHealth = humanoid.Health
		run.setRooted(true) -- WalkSpeed 0: the board moves us, not the Humanoid
		humanoid.AutoRotate = false
		humanoid.HipHeight = baseHip + S.hipLift
		setBoardJump(true)
		-- Shift lock is forced on while riding (user): the mouse steers, no right-click (M2 is the
		-- ollie). Its body turn agrees with the board (both face the camera). Hop-off restores it.
		shiftLockWasOn = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
		setShiftLock(true)
		lv = new("LinearVelocity", {
			Name = "MidoriSkate",
			Attachment0 = att,
			RelativeTo = Enum.ActuatorRelativeTo.World,
			VelocityConstraintMode = Enum.VelocityConstraintMode.Plane, -- Y stays free: gravity, jumps, lifts
			PrimaryTangentAxis = Vector3.xAxis,
			SecondaryTangentAxis = Vector3.zAxis,
			PlaneVelocity = Vector2.new(heading.X, heading.Z) * speed,
			MaxForce = S.maxForce,
		}, root)
		align = new("AlignOrientation", {
			Name = "MidoriSkateFacing",
			Mode = Enum.OrientationAlignmentMode.OneAttachment,
			Attachment0 = att,
			RigidityEnabled = true,
			CFrame = CFrame.lookAlong(Vector3.zero, heading),
		}, root)
		stopMoves()
		play("On")
		local ride = play("Ride", 0.2)
		if ride then
			ride.Looped = true
		end
		sound("On", root)
		task.delay(0.75, function()
			if riding and not loopSound then
				loopSound = sound("Loop", root, 1, true)
			end
		end)
		pop(S.fovHop)
		lines, lineEmitter = buildSpeedLines()
		;(lines :: BasePart).Parent = workspace.CurrentCamera
		meter.show()
	end

	-- M1: ground only, off cooldown; +pushBonus pushDelay later unless something cancels it.
	local function push()
		local now = os.clock()
		if not onGround or busy() or now - lastPush < S.pushCooldown then
			return
		end
		lastPush = now
		pushToken += 1
		local token = pushToken
		busyFrom, busyUntil = now + S.pushBusy, now + S.pushDelay
		play("Push")
		task.delay(S.pushDelay, function()
			if riding and token == pushToken and not tricking then
				speed = math.min(S.maxSpeed, speed + S.pushBonus)
				meter.plus(S.pushBonus)
				sound("Push", root, math.random(80, 120) / 100)
			end
		end)
	end

	-- A random trick animation, never the same one twice in a row.
	local function playTrick()
		local list = trickAnims()
		if #list == 0 then
			return
		end
		local i = math.random(#list)
		if #list > 1 and i == lastTrickIndex then
			i = i % #list + 1
		end
		lastTrickIndex = i
		if trickTrack then
			trickTrack:Stop(0)
		end
		local t = animator:LoadAnimation(list[i])
		trickTrack = t
		t:Play(0)
		t.Stopped:Once(function()
			if riding and trickTrack == t and not onGround then
				play("Fall")
			end
			task.defer(t.Destroy, t) -- a new track per trick: free it (Animator 256-track cap)
		end)
	end

	-- Jump in the air: a trick off a ledge (see the header), or a cosmetic re-trick during one.
	local function trick()
		local now = os.clock()
		if not riding or charging or onGround then
			return
		end
		if not tricking then
			if jumpedThisAir or now - lastGroundAt >= S.trickLedge then
				return
			end
			stopMoves()
			pushToken += 1 -- a trick cancels a push still winding up
			tricking, ollied, combo = true, false, 0
			lastTrick = now
			lift(jumpSpeed(normalJumpHeight()), LIFT_HOLD) -- (user) a ledge trick = your normal jump
			playTrick()
			sound("Stunt", root)
		elseif now - lastTrick > S.trickWindow and not busy() then
			combo = if now - lastTrick < S.comboWindow then combo + 1 else 0
			lastTrick = now
			playTrick()
			sound("Stunt", root, 1 + 0.06 * combo)
		end
	end

	-- M2: a hop, ground or air; cancels a push; during a trick, +ollieTrickBonus on landing.
	local function ollie()
		local now = os.clock()
		if busy() or now - lastOllie < S.ollieCooldown then
			return
		end
		lastOllie = now
		pushToken += 1
		busyFrom, busyUntil = now, now + S.ollieBusy
		ollied = ollied or tricking
		lift(jumpSpeed(S.ollieHeight), LIFT_HOLD)
		play("Ollie")
		sound("Ollie", root)
		if tricking then
			sound("Stunt", root, 1.05)
		end
	end

	-- Frozen = the mover holds ALL of your velocity at 0 (gravity too): you hang in place mid-air.
	local function setFrozen(frozen: boolean)
		local l = lv
		if not l then
			return
		end
		if frozen then
			l.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
			l.VectorVelocity = Vector3.zero
			root.AssemblyLinearVelocity = Vector3.zero
		else
			l.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
			l.PrimaryTangentAxis = Vector3.xAxis
			l.SecondaryTangentAxis = Vector3.zAxis
		end
	end

	-- Q held: freeze and aim. Cancels a push; counts as an action for idleBail.
	local function lungeStart()
		local now = os.clock()
		if charging or now - lastLunge < S.lungeCooldown then
			return
		end
		lastLunge, lastActionAt = now, now
		pushToken += 1
		charging, chargeStart, chargeSaved = true, now, speed
		speed = 0
		table.clear(lifts)
		rampUp = 0
		setFrozen(true)
		stopMoves()
		play("Charge")
	end
	local function lungeRelease()
		if not charging then
			return
		end
		charging = false
		setFrozen(false)
		stop("Charge")
		play("Lunge")
		speed = math.min(S.maxSpeed, chargeSaved + S.lungeBonus)
		meter.plus(S.lungeBonus)
		pop(S.fovLunge)
		sound("Lunge", root)
		-- hold your height for lungeHold, rising if you aim up (the reference: 0.01 + look.Y * 0.75 * 20)
		local cam = workspace.CurrentCamera
		local up = if cam then cam.CFrame.LookVector.Y else 0
		lift(0.01 + math.max(up, 0) * S.lungeLift, S.lungeHold)
	end

	-- CombatController hands us its actions while riding; true = taken (no attack / dash).
	local function press(action: string): boolean
		if not riding then
			return false
		end
		if action == "M1" then
			push()
		elseif action == "M2" then
			ollie()
		elseif action == "Dash" then
			lungeStart()
		else
			return false -- R / Block: CombatController decides (they need combat mode anyway)
		end
		return true
	end
	local function unpress(action: string)
		if action == "Dash" then
			lungeRelease()
		end
	end

	table.insert(conns, humanoid.StateChanged:Connect(function(_, new)
		if new ~= Enum.HumanoidStateType.Jumping then
			return
		end
		jumpedThisAir = true
		local now = os.clock()
		if riding and now >= jumpReadyAt then
			-- (user) a plain board jump: no jumping again for jumpCooldown. Locked only once the jump
			-- has launched (zeroing JumpHeight on the Jumping state itself cancels the jump).
			jumpReadyAt = now + S.jumpCooldown
			task.delay(JUMP_LOCK_DELAY, function()
				if riding and os.clock() < jumpReadyAt then
					setBoardJump(false)
				end
			end)
		end
	end))
	table.insert(conns, UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.KeyCode ~= KEY then
			return
		end
		if not riding then
			on()
		elseif os.clock() - onAt >= S.onLock then
			off(true, false)
		end
	end))
	table.insert(conns, UserInputService.JumpRequest:Connect(trick))
	table.insert(conns, humanoid.HealthChanged:Connect(function(hp)
		if riding and hp < lastHealth and speed > 0 then
			speed = math.clamp(speed - (lastHealth - hp) * S.damageDrain, 0, S.maxSpeed)
		end
		lastHealth = hp
	end))
	table.insert(conns, character:GetAttributeChangedSignal("Skating"):Connect(function()
		if riding and not character:GetAttribute("Skating") then
			off(false, true) -- the server took the board (combat mode, refused)
		end
	end))
	table.insert(conns, character:GetAttributeChangedSignal("LocalMState"):Connect(function()
		local state = character:GetAttribute("LocalMState")
		if state == State.Dash then
			lastDashAt = os.clock()
		end
		if riding and state ~= nil and state ~= State.Idle then
			off(true, true) -- hit, stunned: knocked off
		end
	end))

	-- Forced shift lock: turned off while riding (its key), it comes straight back on. Not while the
	-- side menu or the emote wheel is up: they turn it off so you can click, and restore it on close.
	table.insert(conns, RunService.RenderStepped:Connect(function()
		if not riding then
			return
		end
		if UserInputService.MouseEnabled and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
			and not player:GetAttribute("MenuOpen") and not player:GetAttribute("EmoteWheelOpen") then
			setShiftLock(true)
		end
		local cam = workspace.CurrentCamera
		if cam and lines then
			lines.CFrame = cam.CFrame * CFrame.new(0, 0, -20) * CFrame.Angles(0, math.pi, 0)
		end
	end))

	-- The reference's riding loop, in its order.
	table.insert(conns, RunService.Heartbeat:Connect(function(dt)
		local l, a = lv, align
		if not riding or not l or not a then
			return
		end
		local now = os.clock()
		local f = dt * 60
		if humanoid.Health <= 0 or (now > confirmBy and not character:GetAttribute("Skating")) then
			off(true, true)
			return
		end
		if charging and now - chargeStart >= S.lungeMaxHold then
			lungeRelease()
		end
		if jumpReadyAt > 0 and now >= jumpReadyAt then
			jumpReadyAt = 0
			setBoardJump(true)
		end
		if speed <= 0 and not charging and now - lastActionAt > S.idleBail then
			off(true, true) -- out of speed, and it's been idleBail since hop-on / the last Q
			return
		end

		-- airborne animations (reference: EJump / EFall / ELand)
		if not tricking then
			local st = humanoid:GetState()
			if st == Enum.HumanoidStateType.Freefall or st == Enum.HumanoidStateType.Jumping then
				if not airborne then
					airborne, airAt = true, now
					if st == Enum.HumanoidStateType.Jumping then
						play("Jump")
						task.delay(0.4, function()
							if riding and airborne and not tricking then
								play("Fall")
							end
						end)
					else
						play("Fall")
					end
				end
			elseif now - airAt > 0.2 then
				if airborne then
					play("Land")
				end
				airborne = false
				stop("Jump")
				stop("Fall")
			end
		end
		if humanoid.FloorMaterial ~= Enum.Material.Air and humanoid:GetState() ~= Enum.HumanoidStateType.Jumping then
			jumpedThisAir = false -- really back on the floor: tricks allowed again
		end

		-- perfect control (user): the board points where the camera does, every frame
		heading = flatLook()

		-- speed: decay (at the start-of-frame rate), walls, slopes
		local hit = groundRay()
		local wasOnGround = onGround
		onGround = hit ~= nil
		local normal = if hit then hit.Normal else Vector3.yAxis
		local local_ = if hit then root.CFrame.Rotation:VectorToObjectSpace(normal) else Vector3.yAxis
		local uphill = if hit then local_.Z else 0 -- + = the ground rises ahead (= SkateMath.uphill)
		local wall = solid(root.Position, (root.CFrame * lean).LookVector * S.wallReach) ~= nil
		if not charging then
			speed = SkateMath.step(speed, dt, onGround, uphill, wall)
		end
		if onGround then
			lastGroundAt = now
		end

		-- ramps: ride one for over rampTime, then leaving it pushes you up
		onRamp = onGround and uphill > S.rampMin and normal.Y < 0.99 and normal.Y > 0.01
		if onRamp then
			if not rampLatched then
				rampLatched, rampStart = true, now
			end
			rampSteep = math.clamp(uphill, 0, 1)
		elseif rampLatched then
			if now - rampStart > S.rampTime then
				rampUp = math.clamp(rampSteep * speed * S.rampLaunch, 0, 100)
			end
			rampLatched = false
		end
		rampUp *= 0.9 ^ f
		if rampUp <= 5 then
			rampUp = 0
		end

		-- landing a trick
		if onGround and not wasOnGround and tricking then
			local bonus = S.trickBonus + (if ollied then S.ollieTrickBonus else 0)
			tricking, ollied = false, false
			speed = math.min(S.maxSpeed, speed + bonus)
			meter.plus(bonus)
			sound("Land", root)
			if trickTrack then
				trickTrack:Stop(0.1)
			end
		elseif onGround then
			tricking = false
		end

		-- movement: horizontal = heading x speed; vertical = the force stack, else gravity
		if charging then
			l.VectorVelocity = Vector3.zero
		else
			l.PlaneVelocity = Vector2.new(heading.X, heading.Z) * speed
			local up, any = 0, false
			for i = #lifts, 1, -1 do
				if now >= lifts[i].untilT then
					table.remove(lifts, i)
				else
					up += lifts[i].up
					any = true
				end
			end
			if rampUp > 0 and not onRamp then
				up += rampUp
				any = true
			end
			if any then
				local v = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(v.X, up, v.Z)
			end
		end
		a.CFrame = CFrame.lookAlong(Vector3.zero, heading)

		-- lean into the ground (and sit down onto a slope); straighten slowly in the air
		if rootJoint then
			if hit then
				local dist = (root.Position - hit.Position).Magnitude
				local drop = if math.abs(local_.Z) == 0 then 0 else (3.3 + S.hipLift) - dist
				lean = CFrame.Angles(local_.Z, local_.X, 0)
				rootJoint.C0 = rootJoint.C0:Lerp(restC0 * CFrame.Angles(-local_.Z, -local_.X, 0) * CFrame.new(0, 0, drop), perFrame(S.lean, dt))
			else
				lean = CFrame.identity
				rootJoint.C0 = rootJoint.C0:Lerp(restC0, perFrame(S.leanBack, dt))
			end
		end

		-- feel: FOV, speed lines, meter
		applyFov(dt)
		if lineEmitter then
			lineEmitter.Rate = if speed > S.linesFrom then speed else 0
		end
		meter.update(speed, fovSmoothed, dt)
	end))

	local destroyed = false
	local function destroy()
		if destroyed then
			return
		end
		destroyed = true
		off(true, false)
		for _, c in conns do
			c:Disconnect()
		end
		meter.destroy()
	end
	table.insert(conns, humanoid.Died:Connect(destroy))
	return {
		isRiding = function()
			return riding
		end,
		press = press,
		unpress = unpress,
		destroy = destroy,
	}
end

return SkateController
