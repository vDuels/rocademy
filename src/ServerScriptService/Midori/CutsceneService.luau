--!strict
-- Cutscenes (user, 2026-10-22). Data in ReplicatedStorage.Midori.Data.Cutscenes; the camera runs on the
-- clients (StarterPlayerScripts.Midori.CutsceneController).
--   play1v1(id, attacker, victim): only the two players get the camera.
--   play3P(id, actors): every player gets the camera.
-- Every actor goes into State.Cutscene for the cutscene's duration (Fighter.hittable is false, nothing is
-- Idle so nothing can be pressed, their client roots them) and CombatService's onExpire puts them back
-- to Idle. Actor animations play here so they replicate to everyone.
-- Dev chat: ",cs <id>" = 1v1 against the nearest other fighter, ",cs3 <id>" = the same as 3P.
-- Cutscenes with `cues` move dummies here (players' clients move their own, Shared/CutsceneTimeline);
-- `hits` / `finisher` land here on the server clock.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Cutscenes = Paths.data("Cutscenes")
local Enums = Paths.shared("Enums")
local Net = Paths.shared("Net")
local Ragdoll = Paths.shared("Ragdoll")
local CutsceneTimeline = Paths.shared("CutsceneTimeline")
local Fighter = Paths.server("Fighter")
local Registry = Paths.server("FighterRegistry")
local HealthSystem = Paths.server("HealthSystem")
local Knockback = Paths.server("Knockback")

local State = Enums.State

local CutsceneService = {}

-- Random volume and PlaybackSpeed (pitch + speed together) per hit; the speed always moves at least
-- spec.minStep from the last one, so no two punches in a row sound alike.
local lastPitch = 1
-- One template Sound per id, cloned per hit (user: clone + cache instead of building each hit).
local soundCache: { [string]: Sound } = {}
local function hitSound(spec: any?, root: BasePart)
	if not spec then
		return
	end
	local lo, hi = spec.pitch[1], spec.pitch[2]
	local pitch = lo + math.random() * (hi - lo)
	for _ = 1, 8 do
		if math.abs(pitch - lastPitch) >= (spec.minStep or 0) then
			break
		end
		pitch = lo + math.random() * (hi - lo)
	end
	lastPitch = pitch
	local template = soundCache[spec.id]
	if not template then
		template = Instance.new("Sound")
		template.SoundId = spec.id
		soundCache[spec.id] = template
	end
	local s = template:Clone()
	s.Volume = spec.volume[1] + math.random() * (spec.volume[2] - spec.volume[1])
	s.PlaybackSpeed = pitch
	s.Parent = root
	s:Play()
	Debris:AddItem(s, 3)
end

-- The cutscene's damage on the victim: flat `hits`, then the finisher (knockback + ragdoll, out into
-- hitstun). A hit that would kill stops HP at the knock floor; the knock itself waits for the
-- finisher's launch, as HitResolver does.
local function runHits(def: any, a: any, v: any, t: number)
	if not v or not (def.hits or def.finisher) then
		return
	end
	local knocked = false
	local function live(): boolean
		return Registry.get(v.model) == v and Registry.get(a.model) == a and Fighter.alive(v) and v.state == State.Cutscene
	end
	local function after(at: number, fn: () -> ())
		task.delay(math.max(0, t + at - workspace:GetServerTimeNow()), function()
			if live() then
				fn()
			end
		end)
	end
	for _, h in def.hits or {} do
		after(h.t, function()
			knocked = HealthSystem.damage(a, v, h.damage, def.antiHeal or 0) or knocked
			hitSound(def.hitSound, v.root)
		end)
	end
	-- Barrages (user, 2026-10-24): every arm-clone fist sounds like a punch landing too, on top of the
	-- real hits, timed like the fists (CutsceneBarrage throws fist i at (i - 1) * duration / fists).
	for _, b in def.barrages or {} do
		for i = 1, b.fists do
			after(b.t + (i - 1) * b.duration / b.fists, function()
				hitSound(def.hitSound, v.root)
			end)
		end
	end
	local fin = def.finisher
	if fin then
		after(fin.t, function()
			knocked = HealthSystem.damage(a, v, fin.damage, def.antiHeal or 0) or knocked
			hitSound(def.hitSound, v.root)
			local now = workspace:GetServerTimeNow()
			Fighter.setState(v, State.Hitstun, fin.ragdoll, now)
			if v.player then
				Net.get(Net.Names.StateSync):FireClient(v.player, State.Hitstun, v.stateEndsAt, "cutscene")
			end
			-- Thrown limp, like every ragdoll (D.RAGDOLL): the knockback is the launch, not a motor.
			local launch = Knockback.launch(a, v, fin.knockback)
			Ragdoll.apply(v, fin.ragdoll, fin.knockback.spin, launch)
			if knocked then
				Paths.server("KnockService").knock(v, now, nil, launch)
			end
		end)
	end
end

-- Assets.<root>.<a>.<b>... from "a/b", or nil.
local function asset(root: string, path: string?): Instance?
	local node: Instance? = if path then Paths.Assets:FindFirstChild(root) else nil
	for part in string.gmatch(path or "", "[^/]+") do
		node = node and node:FindFirstChild(part)
	end
	return node
end

-- Where a cutscene happens: at the lead's root, but upright (yaw only) and standing on the floor
-- (user, 2026-10-29: the attacker sometimes faced the wrong way and rose up the Y axis). The raw root
-- CFrame carried whatever tilt / height the move that started it left (a rush mid-air, a slope, a
-- step), and every actor offset + cue is in anchor space.
local ROOT_HEIGHT = 3 -- R6 root above the floor
function CutsceneService.anchorFor(lead: any): CFrame
	local root: BasePart = lead.root
	local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
	local pos = root.Position
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = Registry.models()
	params.RespectCanCollide = true
	local hit = workspace:Raycast(pos, Vector3.new(0, -12, 0), params)
	if hit then
		pos = Vector3.new(pos.X, hit.Position.Y + ROOT_HEIGHT, pos.Z)
	end
	return CFrame.lookAlong(pos, look)
end

local function play(id: string, actors: { [string]: any }, everyone: boolean, now: number?): boolean
	local def = Cutscenes[id]
	local lead = actors.attacker or select(2, next(actors))
	if not def or not lead then
		return false
	end
	for _, f in actors do
		if not Fighter.hittable(f) then
			return false -- dead, knocked or already in a cutscene
		end
	end
	local t = now or workspace:GetServerTimeNow()
	local anchor = CutsceneService.anchorFor(lead)
	local models = {}
	for role, f in actors do
		models[role] = f.model
		Fighter.setState(f, State.Cutscene, def.duration, t)
		if f.player then
			Net.get(Net.Names.StateSync):FireClient(f.player, State.Cutscene, -1, "cutscene")
		end
		local spec = def.actors[role] or {}
		if spec.offset then
			f.root.AssemblyLinearVelocity = Vector3.zero
			f.root.CFrame = anchor * spec.offset
		end
		local anim = asset("Animations", spec.anim)
		local animator = f.humanoid:FindFirstChildOfClass("Animator")
		if anim and anim:IsA("Animation") and anim.AnimationId ~= "" and animator then
			-- Freed when the cutscene ends: a fresh track per cutscene would otherwise pile up toward the
			-- Animator's 256-track cap (user, 2026-10-28: stuck anims).
			local track = animator:LoadAnimation(anim)
			track:Play()
			task.delay(def.duration, function()
				track:Stop(0.2)
				task.delay(0.3, track.Destroy, track)
			end)
		end
		if spec.cues and not f.player then
			CutsceneTimeline.run(f.model, spec.cues, anchor, t, true, false) -- a dummy's moves; clips run on clients
		end
	end
	runHits(def, actors.attacker or lead, actors.victim, t)
	-- Every client hears about it: all of them play the actors' clips (Shared/CutsceneTimeline); the
	-- camera runs for everyone (3P) or just the actors (1v1). Only in a running game: edit-mode tests have
	-- no remotes (and Team Create can list a player there, so a player count isn't enough).
	if RunService:IsRunning() and #Players:GetPlayers() > 0 then
		Net.get(Net.Names.Cutscene):FireAllClients(id, anchor, models, t, everyone)
	end
	return true
end

-- 1 on 1: the attacker's and victim's screens only. Returns whether it started.
function CutsceneService.play1v1(id: string, attacker: any, victim: any, now: number?): boolean
	return play(id, { attacker = attacker, victim = victim }, false, now)
end

-- Third person: every screen. `actors` = role -> fighter (roles as in the cutscene's data).
function CutsceneService.play3P(id: string, actors: { [string]: any }, now: number?): boolean
	return play(id, actors, true, now)
end

function CutsceneService.init()
	local function watch(player: Player)
		player.Chatted:Connect(function(message: string)
			local kind, id = string.match(message, "^,(cs3?)%s+(%S+)%s*$")
			if not kind or not Paths.server("RoleService").isDev(player) then
				return
			end
			local a = Registry.getByPlayer(player)
			if not a then
				return
			end
			local nearest, best = nil, 30
			for _, v in Registry.all() do
				local d = (v.root.Position - a.root.Position).Magnitude
				if v ~= a and d < best then
					nearest, best = v, d
				end
			end
			if nearest then
				local actors = { attacker = a, victim = nearest }
				play(id, actors, kind == "cs3")
			end
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
end

return CutsceneService
