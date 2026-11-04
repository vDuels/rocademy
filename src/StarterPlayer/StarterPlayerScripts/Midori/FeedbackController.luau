--!strict
-- Confirmed-only feedback: hit/crit/block/parry VFX and sounds play when the server's
-- HitResult arrives, never on client guesses. Swing and dash sounds are fine to predict.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Enums = Paths.shared("Enums")
local Net = Paths.shared("Net")
local D = Paths.data("Defaults")
local MoveSchema = Paths.shared("MoveSchema")
local Ghost = Paths.client("Ghost")
local ArmClone = Paths.client("ArmClone")
local ImpactFrame = Paths.client("ImpactFrame")
local LimbFx = Paths.client("LimbFx")
local WindTrail = Paths.shared("WindTrail")
local CameraFov = Paths.client("CameraFov")
local Mirage = Paths.client("Mirage")
local RockModule = Paths.lib("RockModule")
local ColorShift = Paths.client("ColorShift")

local Result, State = Enums.Result, Enums.State

local Sfx = Paths.Assets:WaitForChild("Sfx")
local Hitsounds = Sfx:WaitForChild("Hitsounds")
local Swingsounds = Sfx:WaitForChild("Swingsounds")
local Generic = Sfx:WaitForChild("Generic")
-- Per-move overrides: a move's swingSfx / hitSfx names a sound in Sfx/Styles/<style>.
-- Moves without one use the shared Swingsounds / Hitsounds.
local StyleSfx = Sfx:WaitForChild("Styles")
local HitEffect = Paths.Assets:WaitForChild("Vfx"):WaitForChild("HitEffect") :: BasePart

-- One shared blur: a landed `blur` move snaps it to `size`, then it eases back to 0 over D.LAND_BLUR_FADE.
local blurFx: BlurEffect? = nil
local function landBlur(size: number)
	if not blurFx or not blurFx.Parent then
		local b = Instance.new("BlurEffect")
		b.Name = "MidoriLandBlur"
		b.Size = 0
		b.Parent = game:GetService("Lighting")
		blurFx = b
	end
	local b = blurFx :: BlurEffect
	b.Size = math.max(b.Size, size)
	TweenService:Create(b, TweenInfo.new(D.LAND_BLUR_FADE, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), { Size = 0 }):Play()
end

type Variant = { scale: number, color: Color3?, count: number }

local VARIANTS: { [string]: Variant } = {
	[Result.Hit] = { scale = 1, count = 1 },
	[Result.Counter] = { scale = 1.4, color = Color3.fromRGB(255, 70, 70), count = 2 },
	[Result.Clash] = { scale = 1.6, color = Color3.fromRGB(255, 70, 70), count = 3 },
	[Result.Blocked] = { scale = 0.7, color = Color3.fromRGB(170, 180, 190), count = 1 },
	[Result.Strip] = { scale = 1, color = Color3.fromRGB(170, 180, 190), count = 2 },
	[Result.Parried] = { scale = 1.5, color = D.PARRY_COLOR, count = 3 },
	[Result.GuardBreak] = { scale = 2, color = Color3.fromRGB(255, 200, 80), count = 3 },
}

local FeedbackController = {}
-- Fighters whose unlocking hit (Prodigy Eject) landed on us, and until when (os.clock) their unlocked
-- move (Reentry) counts as coming at us: its targetShift then plays on our screen, focused on them.
local unlockedBy: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local MOVE_STATES = { [State.Startup] = true, [State.Rush] = true, [State.RushMiss] = true, [State.Endlag] = true }

local fxFolder: Folder

local function play(sound: Instance, parent: Instance)
	local s = (sound :: Sound):Clone()
	s.Parent = parent
	s:Play()
	-- Clean up when it ends. TimeLength is 0 until the asset loads, so timing the cleanup off it cut
	-- every long sound short on its first play; the Debris timer is only a fallback.
	s.Ended:Once(function()
		s:Destroy()
	end)
	Debris:AddItem(s, math.max(s.TimeLength / math.max(s.PlaybackSpeed, 0.01), 10) + 0.5)
end

local function playRandom(folder: Instance, parent: Instance)
	local sounds = folder:GetChildren()
	if #sounds > 0 then
		play(sounds[math.random(#sounds)], parent)
	end
end

local function scaleSequence(seq: NumberSequence, k: number): NumberSequence
	local points = {}
	for _, kp in seq.Keypoints do
		table.insert(points, NumberSequenceKeypoint.new(kp.Time, kp.Value * k, kp.Envelope * k))
	end
	return NumberSequence.new(points)
end

local function spawnEffect(pos: Vector3, variant: Variant)
	local fx = HitEffect:Clone()
	fx.CFrame = CFrame.new(pos)
	fx.Anchored = true
	fx.CanCollide = false
	fx.CanQuery = false
	fx.CanTouch = false
	fx.Parent = fxFolder
	local life = 0
	for _, inst in fx:GetDescendants() do
		if inst:IsA("ParticleEmitter") then
			inst.Enabled = false
			if variant.scale ~= 1 then
				inst.Size = scaleSequence(inst.Size, variant.scale)
			end
			if variant.color then
				inst.Color = ColorSequence.new(variant.color)
			end
			local count = inst:GetAttribute("EmitCount")
			inst:Emit((if typeof(count) == "number" then count else 1) * variant.count)
			life = math.max(life, inst.Lifetime.Max)
		end
	end
	Debris:AddItem(fx, life + 0.2)
end

-- The sound a fighter's move names in `field` ("swingSfx" / "hitSfx"), from its style's
-- Sfx/Styles folder, if both exist.
local function moveSound(model: any, moveId: any, field: string): Sound?
	if typeof(model) ~= "Instance" or type(moveId) ~= "string" then
		return nil
	end
	local style = MoveSchema.ofModel(model)
	local move = style.moves[moveId]
	local name = move and (move :: any)[field]
	local folder = if name then StyleSfx:FindFirstChild(style.name) else nil
	local sound = folder and folder:FindFirstChild(name)
	if sound and sound:IsA("Folder") then
		-- A folder = variations: one of its sounds at random (Dema's Swing).
		local sounds = {}
		for _, s in sound:GetChildren() do
			if s:IsA("Sound") then
				table.insert(sounds, s)
			end
		end
		sound = if #sounds > 0 then sounds[math.random(#sounds)] else nil
	end
	return if sound and sound:IsA("Sound") then sound else nil
end

-- The move's `field` (cleanHitSfx / clashSfx): a sound, or a folder whose sounds all play together
-- (Sfx/Styles/<style>). Returns true if it played anything.
local function playStyleSounds(model: any, moveId: any, field: string, parent: Instance): boolean
	if typeof(model) ~= "Instance" or type(moveId) ~= "string" then
		return false
	end
	local style = MoveSchema.ofModel(model)
	local move = style.moves[moveId]
	local name = move and (move :: any)[field]
	local folder = if name then StyleSfx:FindFirstChild(style.name) else nil
	local found = folder and folder:FindFirstChild(name)
	if not found then
		return false
	end
	for _, s in (if found:IsA("Sound") then { found } else found:GetChildren()) do
		if s:IsA("Sound") then
			play(s, parent)
		end
	end
	return true
end

local function soundsFor(result: string, parent: Instance, attacker: any, info: any)
	local moveId = if type(info) == "table" then info.move else nil
	if result == Result.Clash then
		playStyleSounds(attacker, moveId, "clashSfx", parent) -- layered on the usual clash sounds below
	end
	-- contactSfx: on any connect (guard results layer it on their own sounds; on a hit it's the hit sound).
	local contact = playStyleSounds(attacker, moveId, "contactSfx", parent)
	if result == Result.Hit and playStyleSounds(attacker, moveId, "cleanHitSfx", parent) then
		return
	elseif result == Result.Hit or result == Result.Counter or result == Result.Clash then
		playStyleSounds(attacker, moveId, "landSfx", parent) -- layered on the hit sound
		local own = moveSound(attacker, moveId, "hitSfx")
		if own then
			play(own, parent)
		elseif not contact then
			playRandom(Hitsounds, parent)
		end
		-- Counters (and clashes, which are mutual counters) layer the counter sting.
		if result ~= Result.Hit then
			play(Generic:WaitForChild("Counter"), parent)
		end
	elseif result == Result.Blocked then
		play(Generic:WaitForChild("Blocked"), parent)
	elseif result == Result.Strip then
		play(Generic:WaitForChild("Blocked"), parent)
		play(Generic:WaitForChild("WeakBlock"), parent)
	elseif result == Result.Parried then
		play(Generic:WaitForChild("Parry"), parent)
	elseif result == Result.GuardBreak then
		play(Generic:WaitForChild("BlockBreak"), parent)
	end
end

local function rootOf(model: any): BasePart?
	if typeof(model) ~= "Instance" then
		return nil
	end
	return model:FindFirstChild("HumanoidRootPart") :: BasePart?
end

-- Where a hit's sounds play from: the victim's root, else (not streamed in here, e.g. we're in an apartment
-- 3000+ studs out) a throwaway attachment at the hit, so distance still turns it down. Never a Folder: a
-- Sound under anything but a part / attachment plays everywhere at full volume (user, 2026-11-01: combat
-- "clear as day" inside apartments). nil = nowhere to put it: no sound.
local function hitSoundAt(victim: any, pos: any): Instance?
	local root = rootOf(victim)
	if root then
		return root
	end
	if typeof(pos) ~= "Vector3" then
		return nil
	end
	local a = Instance.new("Attachment")
	a.Name = "MidoriHitSound"
	a.Position = pos -- Terrain sits at the origin, so this is the world position
	a.Parent = workspace.Terrain
	Debris:AddItem(a, 12)
	return a
end

-- Every M2 / crit (R) start: the generic M2 / Critical sting plus a quick flash on the fighter
-- (white for M2, D.CRIT_FLASH_COLOR for crits).
local function m2Flash(model: Instance, color: Color3, timing: any?)
	local f = timing or D.M2_FLASH
	local h = Instance.new("Highlight")
	h.FillColor = color
	h.FillTransparency = 1
	h.OutlineTransparency = 1
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = model
	local up = TweenService:Create(h, TweenInfo.new(f.peakAt, Enum.EasingStyle.Linear), { FillTransparency = f.peak })
	up.Completed:Connect(function()
		TweenService:Create(h, TweenInfo.new(f.fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { FillTransparency = f.rest }):Play()
	end)
	up:Play()
	Debris:AddItem(h, f.peakAt + f.fade)
end

-- One barrage fist: a clone of the attacker's arm, pointing forward at a random spot in front of
-- them. It appears slightly see-through and punches forward (following the attacker) while
-- fading a little, then fades out fast while drifting on with what's left of the punch.
local function spawnFist(tpl: Model, root: BasePart)
	local F = D.BARRAGE_FIST
	local fist = tpl:Clone()
	local part = fist.PrimaryPart :: BasePart
	local x = (math.random() * 2 - 1) * F.spread.X
	local y = F.height + (math.random() * 2 - 1) * F.spread.Y
	-- Arm's long axis (Y) laid along the root's forward, hand first.
	local tilt = CFrame.Angles(math.rad(90), 0, 0)
	-- Travel so the tip (half an arm ahead of the centre) stops exactly at tipEnd.
	local reach = F.from + F.tipEnd - part.Size.Y / 2
	local function at(forward: number): CFrame
		return root.CFrame * CFrame.new(x, y, F.from - forward) * tilt -- -Z is forward
	end
	part.CFrame = at(0)
	part.Transparency = F.startTransparency
	fist.Parent = fxFolder
	local t0 = os.clock()
	local released: CFrame? = nil -- where the thrust ended; the fade-out drifts on from there
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - t0
		if not root.Parent or t >= F.thrust + F.fade then
			conn:Disconnect()
			fist:Destroy()
			return
		end
		if t < F.thrust then
			local a = t / F.thrust
			part.CFrame = at(reach * (1 - (1 - a) ^ 2)) -- ease out
			part.Transparency = F.startTransparency + (F.thrustTransparency - F.startTransparency) * a
		else
			released = released or at(reach)
			local a = (t - F.thrust) / F.fade
			-- tilt maps the arm's -Y (hand) to forward, so the drift goes along the arm.
			part.CFrame = (released :: CFrame) * CFrame.new(0, -F.drift * (1 - (1 - a) ^ 2), 0)
			part.Transparency = F.thrustTransparency + (1 - F.thrustTransparency) * a
		end
	end)
end

-- One fist thrown from `root` (an ArmClone template, sized by the caller); cutscene barrages use it too.
FeedbackController.fist = spawnFist

-- Fuse meter: Assets.2d.Bomb over the fighter's head, world-sized like the shield (everyone sees it).
-- A dim empty bomb with a full one on top, clipped from the bottom: set(left) shrinks the clip, so
-- the bomb drains from the top down as the fuse burns. Tunables: D.FUSE_METER.
type FuseMeter = { gui: BillboardGui, set: (left: number) -> () }
local function fuseMeter(root: BasePart): FuseMeter?
	local template = Paths.Assets:FindFirstChild("2d") and Paths.Assets["2d"]:FindFirstChild("Bomb")
	if not template then
		return nil
	end
	local M = D.FUSE_METER
	local gui = Instance.new("BillboardGui")
	gui.Name = "MidoriFuse"
	gui.Adornee = root
	gui.Size = UDim2.fromScale(M.size, M.size) -- scale-only: studs, shrinks with distance
	gui.StudsOffsetWorldSpace = Vector3.new(0, M.height, 0)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = true
	gui.MaxDistance = M.maxDistance

	local empty = template:Clone() :: ImageLabel
	empty.ImageColor3 = M.emptyColor
	empty.ImageTransparency = M.emptyTransparency
	empty.Parent = gui

	local clip = Instance.new("Frame")
	clip.BackgroundTransparency = 1
	clip.ClipsDescendants = true
	clip.AnchorPoint = Vector2.new(0, 1)
	clip.Position = UDim2.fromScale(0, 1)
	clip.Size = UDim2.fromScale(1, 1)
	clip.Parent = gui
	local full = template:Clone() :: ImageLabel
	full.AnchorPoint = Vector2.new(0.5, 1) -- pinned to the clip's bottom, so it never moves as the clip shrinks
	full.Position = UDim2.fromScale(0.5, 1)
	full.Parent = clip

	gui.Parent = fxFolder
	return {
		gui = gui,
		set = function(left: number)
			local k = math.clamp(left, 0.001, 1)
			clip.Size = UDim2.fromScale(1, k)
			full.Size = UDim2.fromScale(1, 1 / k) -- stays the whole gui's height inside the shrinking clip
		end,
	}
end

-- The server's combat state (the barrage start is server-decided, even for our own fuse).
local function stateOf(model: Instance): any
	return model:GetAttribute("MState")
end

-- Fuse moves (Firecracker Critical): fuse.sfx plays for the fuse's `duration` (the server's
-- roll). If it then went off (MState Barrage): startSfx once, loopSfx until the barrage ends and
-- punchSfx on every punch thrown (same spacing as the server's hits). Else it fizzled: silence.
local function fuseBarrageSounds(model: Instance, root: BasePart, style: any, move: any, duration: number)
	local folder = StyleSfx:FindFirstChild(style.name)
	local function sound(name: string?): Sound?
		local s = if name and folder then folder:FindFirstChild(name) else nil
		return if s and s:IsA("Sound") then s else nil
	end
	local function hold(name: string?): Sound?
		local s = sound(name)
		if not s then
			return nil
		end
		local c = s:Clone()
		c.Parent = root
		c:Play()
		return c
	end
	task.spawn(function()
		local fuse = hold(move.fuse.sfx)
		local bomb = fuseMeter(root)
		-- Our own fuse moves our camera (D.FUSE_CAMERA): zoom in for its last moments, wide during the barrage.
		local mine = model == Players.LocalPlayer.Character
		local cam = D.FUSE_CAMERA
		local zoomed = false
		-- Burns until it goes off (MState may land a little before or after the timer).
		local t0 = os.clock()
		while root.Parent and stateOf(model) ~= State.Barrage and os.clock() - t0 < duration + 0.3 do
			local left = duration - (os.clock() - t0)
			-- No zoom while we're stunned (our own predicted state, so it reacts instantly); a stun
			-- that lands mid-zoom eases it back out. A stun at the pop fizzles the fuse anyway.
			local stunned = mine and Enums.STUNS[model:GetAttribute("LocalMState")] == true
			if mine and zoomed and stunned then
				zoomed = false
				CameraFov.set("fuse", nil, cam.out)
			elseif mine and not zoomed and not stunned and left <= cam.zoomAt then
				zoomed = true
				CameraFov.set("fuse", cam.zoom, math.max(left, 0.05), cam.zoomStyle, Enum.EasingDirection.Out)
			end
			local burnt = (os.clock() - t0) / duration
			if burnt >= 1 then
				if fuse then
					fuse:Destroy()
					fuse = nil
				end
				if bomb then
					bomb.gui:Destroy()
					bomb = nil
				end
			elseif bomb then
				bomb.set(1 - burnt)
			end
			task.wait()
		end
		if fuse then
			fuse:Destroy()
		end
		if bomb then
			bomb.gui:Destroy()
		end
		local b = move.barrage
		if not b or stateOf(model) ~= State.Barrage then
			if mine then
				CameraFov.set("fuse", nil, cam.out) -- fizzled
			end
			return
		end
		if mine then
			-- One continuous whip from the close-up straight out to the barrage width. Clearing "fuse"
			-- instantly first snapped back to normal for a frame, which read as a glitch and ate the zoom-in.
			CameraFov.set("fuse", nil, cam.barrageIn)
			CameraFov.set("barrage", cam.barrage, cam.barrageIn)
		end
		if move.fuse.impact then
			-- No victim yet: flash for the user and for us if we're close enough to be in it.
			local me = Players.LocalPlayer.Character
			local myRoot = me and me:FindFirstChild("HumanoidRootPart") :: BasePart?
			local near = me ~= model and myRoot and (myRoot.Position - root.Position).Magnitude <= D.IMPACT_POP_RANGE
			ImpactFrame.play(model, if near then me else nil)
		end
		for _, name in b.startSfx do
			local s = sound(name)
			if s then
				play(s, root)
			end
		end
		local loop = hold(b.loopSfx)
		if loop then
			loop.Looped = true
		end
		local punch = sound(b.punchSfx)
		local arms = if b.fists > 0 and model:IsA("Model")
			then { ArmClone.template(model, "Right Arm"), ArmClone.template(model, "Left Arm") }
			else {}
		for _, tpl in arms do
			local arm = tpl.PrimaryPart :: BasePart
			arm.Size *= D.BARRAGE_FIST.scale -- the shirt stretches with the part
		end
		local interval, start, thrown, fisted = b.duration / b.hits, os.clock(), 0, 0
		while root.Parent and stateOf(model) == State.Barrage do
			local elapsed = os.clock() - start
			local due = math.min(b.hits, math.floor(elapsed / interval) + 1)
			while thrown < due do
				thrown += 1
				if punch then
					play(punch, root)
				end
			end
			local fistsDue = math.min(b.fists, math.floor(elapsed / (b.duration / math.max(b.fists, 1))) + 1)
			while fisted < fistsDue do
				fisted += 1
				local tpl = arms[(fisted - 1) % 2 + 1] -- alternate right / left
				if tpl then
					spawnFist(tpl, root)
				end
			end
			task.wait()
		end
		for _, tpl in arms do
			tpl:Destroy()
		end
		if mine then
			CameraFov.set("barrage", nil, cam.out)
		end
		if loop then
			loop:Destroy()
		end
	end)
end

-- `fuse` = how long a lit fuse burns (AttackStarted's 4th arg; fuse moves only).
-- `speed` = the attack's speed (startup / speed = time to the hitbox), default 1.
function FeedbackController.swing(root: BasePart, moveId: string?, fuse: number?, speed: number?)
	local model = root.Parent
	local style = if model then MoveSchema.ofModel(model) else nil
	local move = if style and type(moveId) == "string" then style.moves[moveId] else nil
	local own = moveSound(model, moveId, "swingSfx")
	if own then
		play(own, root)
	elseif move and move.fuse then
		fuseBarrageSounds(model :: Instance, root, style, move, fuse or move.fuse.max)
	else
		playRandom(Swingsounds, root)
	end
	-- A move with its own limb look (colour / length / trail: the dash kick, KickCan) gets the styled flash
	-- below whatever its kind; plain M2s / crits keep the stock flash here.
	local styled = move ~= nil and (move.limbColor ~= nil or move.limbTime ~= nil or move.trail ~= nil)
	if model and type(moveId) == "string" then
		if move and (move.kind == "M2" or move.kind == "R") then
			play(Generic:WaitForChild(if move.kind == "R" then "Critical" else "M2"), root)
			m2Flash(model, if move.kind == "R" then D.CRIT_FLASH_COLOR else Color3.new(1, 1, 1))
			if move.limbFx and not styled then
				local cfg = LimbFx.config(move.kind)
				if move.fuse and move.barrage then
					-- Lit fuse: slower squares (no ghost) keep popping until the barrage ends; a fizzle stops them.
					local limbs, every, until_ = move.limbFx, D.LIMB_FX_FUSE.every, (fuse or move.fuse.max) + move.barrage.duration
					local fuseEnds = fuse or move.fuse.max
					local t0 = os.clock()
					task.spawn(function()
						while model.Parent and os.clock() - t0 < until_ do
							if os.clock() - t0 > fuseEnds + 0.2 and stateOf(model) ~= State.Barrage then
								break
							end
							LimbFx.squares(model :: Model, limbs, cfg, D.LIMB_FX_FUSE.spinMult)
							task.wait(every)
						end
					end)
				else
					LimbFx.play(model :: Model, move.limbFx, cfg, move.startup / (speed or 1))
				end
			end
		end
	end
	if model and move and (move.kind == "M1" or styled) then
		-- M1 / styled limb flash + foot trail (Furious Feng's dash kick, KickCan). A lead move (the dive) flashes when the
		-- swing itself starts, not on the click; both skip if the attack was cut off by then.
		local own = model == Players.LocalPlayer.Character
		local function swinging(): boolean
			local st = if own then model:GetAttribute("LocalMState") else stateOf(model)
			return model.Parent ~= nil and (st == State.Startup or st == State.Endlag)
		end
		local sp = speed or 1
		-- Due at the swing's start (no lead / from 0): run now, no deferral and no state check (the attack just
		-- started; a deferred check could miss a state that hasn't replicated yet). Later ones wait and check.
		local function at(t: number, fn: () -> ())
			if t <= 0 then
				fn()
			else
				task.delay(t, function()
					if swinging() then
						fn()
					end
				end)
			end
		end
		if move.limbFx then
			local cfg = LimbFx.config(move.kind)
			if move.limbColor or move.limbTime then
				cfg = table.clone(cfg)
				cfg.color = move.limbColor or cfg.color
				cfg.time = if move.limbTime then move.limbTime / sp else cfg.time
			end
			local lead = if move.lead then move.lead.time else 0
			at(lead / sp, function()
				LimbFx.play(model :: Model, move.limbFx, cfg, if move.limbTime then cfg.time else (move.startup - lead) / sp)
			end)
		end
		local trail = move.trail
		if trail then
			-- Times count from the swing (after a lead), like the flash.
			at(((if move.lead then move.lead.time else 0) + trail.from) / sp, function()
				local limb = model:FindFirstChild(trail.limb)
				if not (limb and limb:IsA("BasePart")) then
					return
				end
				local w = WindTrail.attach(model :: Model, D.WIND_TRAIL_SCALE * 0.5, limb, CFrame.new(0, -limb.Size.Y / 2, 0))
				if w then
					if trail.color then
						for _, t in w:GetDescendants() do
							if t:IsA("Trail") then
								t.Color = ColorSequence.new(trail.color)
							end
						end
					end
					task.delay((trail.to - trail.from) / sp, WindTrail.fade, w)
				end
			end)
		end
	end
	if move and move.vfx then
		Paths.client(move.vfx).play(root)
	end
	-- impactSfx: a sound, or a folder whose sounds all play together, at the hitbox time.
	-- ponytail: plays even if the attack gets interrupted, and ignores adrenaline's startup speed-up.
	local swing = move and move.charge and move.charge.swing
	if swing and model and type(moveId) == "string" then
		-- Swing charge (Slugger M2): impactSfx is the release sound. Our own CombatController calls
		-- release(); for others, watch the server's state end (releaseCharge moves it) for the release.
		if model ~= Players.LocalPlayer.Character then
			task.spawn(function()
				local t0 = os.clock()
				while root.Parent and model:GetAttribute("MState") == State.Startup and os.clock() - t0 < 3 do
					local ends = model:GetAttribute("MStateEnds")
					if typeof(ends) == "number" and ends > 0 and workspace:GetServerTimeNow() >= ends - swing.hit then
						FeedbackController.release(root, moveId)
						return
					end
					RunService.Heartbeat:Wait()
				end
			end)
		end
	elseif move and move.impactSfx then
		task.delay(move.startup, FeedbackController.release, root, moveId :: string)
	end
end

-- Plays `moveId`'s impactSfx now (a sound, or every sound in a folder).
function FeedbackController.release(root: BasePart, moveId: string)
	local model = root.Parent
	if not model then
		return
	end
	local style = MoveSchema.ofModel(model)
	local move = style and style.moves[moveId]
	-- Slugger Critical's slam (move.slamFx, or any slowZone move), hit or miss: rocks burst from the feet,
	-- sharp rocks on the D.SLOW_ZONE edge + rubble inside for its duration (the look only: Critical lost its
	-- slow on 2026-10-31, the user kept the rocks). Not if the swing was dash-cancelled or stunned out before
	-- the hitbox (our own body: LocalMState; others: the server's MState).
	local state = model:GetAttribute("LocalMState") or model:GetAttribute("MState")
	if move and (move.slamFx or move.slowZone) and (state == State.Startup or state == State.Endlag) then
		local Z = D.SLOW_ZONE
		local at = CFrame.new(root.Position)
		RockModule.Explosion(root.CFrame - Vector3.new(0, 2.5, 0), 10, 0.5, 1.5, false)
		RockModule.Spikes(at, Z.radius, 22, Z.duration)
		RockModule.Rubble(at, Z.radius, 24, Z.duration)
	end
	local styleSfx = if move and move.impactSfx then StyleSfx:FindFirstChild(style.name) else nil
	local impact = if styleSfx and move then styleSfx:FindFirstChild(move.impactSfx :: string) else nil
	if impact then
		for _, s in (if impact:IsA("Sound") then { impact } else impact:GetChildren()) do
			if s:IsA("Sound") then
				play(s, root)
			end
		end
	end
end

-- A landed hit's particles at `pos` (no sound), e.g. cutscene hits (CutsceneController). `result`
-- picks the variant (default Hit; Counter = bigger + red).
function FeedbackController.hitEffect(pos: Vector3, result: string?)
	spawnEffect(pos, VARIANTS[result or Result.Hit] or VARIANTS[Result.Hit])
end

-- `dir` / `distance` (when known): Cosmic Ray throws a mirage the other way (Mirage).
function FeedbackController.dash(root: BasePart, dir: Vector3?, distance: number?)
	play(Generic:WaitForChild("Dash"), root)
	local character = root.Parent
	if character then
		m2Flash(character, D.DASH_FLASH.color, D.DASH_FLASH)
		if dir and character:IsA("Model") and character:GetAttribute("CosmicRay") == true then
			Mirage.spawn(character, dir, distance or D.DASH_DISTANCE.Front)
		end
	end
end

function FeedbackController.init()
	fxFolder = Instance.new("Folder")
	fxFolder.Name = "MidoriFx"
	fxFolder.Parent = workspace

	-- Rock debris (Lib/RockModule, workspace.Debris) fades as the camera nears it. LocalTransparencyModifier
	-- is local and stacks on the library's own fade tweens; past 0.25 the camera stops treating a rock as
	-- an occluder too.
	local fade = D.ROCK_FADE
	RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		local folder = workspace:FindFirstChild("Debris")
		if not cam or not folder then
			return
		end
		local eye = cam.CFrame.Position
		for _, p in folder:GetChildren() do
			if p:IsA("BasePart") then
				local d = (p.Position - eye).Magnitude - p.Size.Magnitude / 2
				p.LocalTransparencyModifier = math.clamp((fade.far - d) / (fade.far - fade.near), 0, 1)
			end
		end
	end)

	Net.get("HitResult").OnClientEvent:Connect(function(attacker: Model, victim: Model, result: string, pos: Vector3, info: any)
		local variant = VARIANTS[result]
		if not variant then
			return
		end
		if typeof(pos) == "Vector3" then
			spawnEffect(pos, variant)
		end
		local landed = result == Result.Hit or result == Result.Counter or result == Result.Clash
		local move = if typeof(attacker) == "Instance" and type(info) == "table" and type(info.move) == "string"
			then MoveSchema.ofModel(attacker).moves[info.move]
			else nil
		local me = Players.LocalPlayer.Character
		-- A clean hit that starts a cutscene (HitResolver): its start sound goes out in the same breath as
		-- the hit sound, for the two fighters (whose screens run a 1v1 cutscene). A clone of the loaded
		-- Assets sound, like the hit sounds, so it never waits on a load. Faded out linearly, every time.
		local cutscene = type(info) == "table" and info.cutscene == true -- the server started its cutscene
		local start = cutscene and move and move.cutscene and Paths.data("Cutscenes")[move.cutscene].startSound
		local startTemplate = start and Sfx:FindFirstChild("Cutscenes") and Sfx.Cutscenes:FindFirstChild(start.sound)
		if startTemplate and me and (attacker == me or victim == me) then
			local s = (startTemplate :: Sound):Clone()
			s.Parent = SoundService
			s:Play()
			TweenService:Create(s, TweenInfo.new(start.fade, Enum.EasingStyle.Linear, Enum.EasingDirection.Out, 0, false, start.fadeAt), { Volume = 0 }):Play()
			Debris:AddItem(s, start.fadeAt + start.fade + 0.1)
		end
		local soundAt = hitSoundAt(victim, pos)
		if soundAt then
			soundsFor(result, soundAt, attacker, info)
		end
		-- Impact frame (attacker + victim only): any result switched on in D.IMPACT_RESULTS, or a
		-- landed hit from a move flagged `impact = true`.
		if D.IMPACT_RESULTS[result] or (landed and move and move.impact) or cutscene then
			ImpactFrame.play(attacker, victim)
		end
		-- Their unlocking hit landed on us: their unlocked move in the window is aimed at us (+0.5s slack
		-- for the trip here).
		if landed and move and move.unlocks and me and victim == me and typeof(attacker) == "Instance" then
			unlockedBy[attacker] = os.clock() + move.unlocks.window + 0.5
		end
		-- Landed-hit colour shift (move.landShift, Prodigy Eject), attacker + victim only.
		if landed and move and move.landShift and me and (attacker == me or victim == me) then
			ColorShift.pulse(D.COLOR_SHIFT[move.landShift])
		end
		-- Landed-hit blur (move.blur), attacker + victim only.
		if landed and move and move.blur > 0 and me and (attacker == me or victim == me) then
			landBlur(move.blur)
		end
	end)

	-- Our own swings and dashes are already predicted locally by CombatController, except a lit
	-- fuse: only the server knows how long it burns.
	Net.get("AttackStarted").OnClientEvent:Connect(function(model: Model, moveId: string, speed: number, fuse: number?)
		local root = rootOf(model)
		local isFuse = typeof(fuse) == "number"
		if root and (isFuse or model ~= Players.LocalPlayer.Character) then
			FeedbackController.swing(root, moveId, if isFuse then fuse else nil, if typeof(speed) == "number" and speed > 0 then speed else 1)
		end
		-- Someone whose Eject landed on us throws Reentry: our screen focuses on them (move.targetShift)
		-- for as long as they're in the move (their replicated MState), 3s at most.
		local move = if root and type(moveId) == "string" then MoveSchema.ofModel(model).moves[moveId] else nil
		local window = unlockedBy[model]
		if move and move.targetShift and window and os.clock() <= window then
			unlockedBy[model] = nil
			local release = ColorShift.hold(D.COLOR_SHIFT[move.targetShift], model)
			-- Local only (client-set attributes don't replicate): Afterimage gives us their long trail.
			model:SetAttribute("TargetingMe", true)
			task.spawn(function()
				local t0 = os.clock()
				while model.Parent and MOVE_STATES[model:GetAttribute("MState")] and os.clock() - t0 < 3 do
					RunService.Heartbeat:Wait()
				end
				model:SetAttribute("TargetingMe", nil)
				release()
			end)
		end
	end)
	Net.get("DashStarted").OnClientEvent:Connect(function(model: Model, dir: Vector3?)
		local root = rootOf(model)
		if root and model ~= Players.LocalPlayer.Character then
			FeedbackController.dash(root, if typeof(dir) == "Vector3" then dir else nil)
		end
	end)
	-- A dash that actually dodged a hit (server-confirmed, once per dash) leaves a ghost
	-- where the dodger is now, mid-dash. Everyone, including the dodger, sees it.
	Net.get("Dodged").OnClientEvent:Connect(function(dodger: Model)
		if typeof(dodger) == "Instance" and dodger:IsA("Model") and dodger.Parent then
			Ghost.snapshot(dodger)
		end
	end)
end

return FeedbackController
