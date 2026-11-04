--!strict
-- Fury logic (data: Data/Perks/Fury). Landing a dash attack (style.dashM1 / dashM2) lights it; any attack of ours that
-- connects with nobody (PerkService "onMissed") puts it out, as do getting knocked / dying / a style swap.
-- While lit: data.mods on the fighter, data.burn HP a second of self damage (all healable, never knocks), and
-- Vfx.FuriousFengFire (emitters locked to the part) + a ghost welded to data.limb. Server-made, so everyone sees them.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Enums = Paths.shared("Enums")
local Fighter = Paths.server("Fighter")
local HealthSystem = Paths.server("HealthSystem")

type State = { fx: { BasePart }?, burnAt: number }

local Fury = {}

local function weldTo(limb: BasePart, p: BasePart)
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.CFrame = limb.CFrame
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = limb
	weld.Part1 = p
	weld.Parent = p
	p.Parent = limb.Parent
end

local function light(f: any, data: any): { BasePart }
	local limb = f.model:FindFirstChild(data.limb)
	if not limb or not limb:IsA("BasePart") then
		return {}
	end
	local list = {}
	local template = Paths.Assets:WaitForChild("Vfx"):FindFirstChild("FuriousFengFire")
	if template and template:IsA("BasePart") then
		local fire = template:Clone()
		fire.Name = "Fury"
		fire.Size = limb.Size -- the emitters fill the leg
		fire.Transparency = 1
		for _, e in fire:GetDescendants() do
			if e:IsA("ParticleEmitter") then
				e.LockedToPart = true
			end
		end
		weldTo(limb, fire)
		table.insert(list, fire)
	end
	local ghost = Instance.new("Part")
	ghost.Name = "FuryGhost"
	ghost.Size = limb.Size * D.LIMB_FX.ghostScale
	ghost.Color = data.ghostColor
	ghost.Material = Enum.Material.SmoothPlastic
	ghost.Transparency = D.LIMB_FX.ghostTransparency
	ghost.TopSurface = Enum.SurfaceType.Smooth
	ghost.BottomSurface = Enum.SurfaceType.Smooth
	weldTo(limb, ghost)
	table.insert(list, ghost)
	return list
end

local function douse(f: any, data: any, s: State)
	local fx = s.fx
	if not fx then
		return
	end
	s.fx = nil
	Fighter.addMods(f, data.mods, -1)
	for _, p in fx do
		local fade = 0
		for _, e in p:GetDescendants() do
			if e:IsA("ParticleEmitter") then
				e.Enabled = false -- live particles finish their life
				fade = math.max(fade, e.Lifetime.Max)
			end
		end
		p.Transparency = 1
		task.delay(fade, p.Destroy, p)
	end
end

function Fury.attach(_f: any, _data: any): State
	return { fx = nil, burnAt = 0 }
end

function Fury.detach(f: any, data: any, s: State)
	douse(f, data, s)
end

function Fury.onLanded(f: any, data: any, s: State, move: any, now: number)
	-- Any dash attack lights it (the dash kick, KickCan; user, 2026-11-03).
	if s.fx or (move.id ~= f.style.dashM1 and move.id ~= f.style.dashM2) then
		return
	end
	Fighter.addMods(f, data.mods, 1)
	s.fx = light(f, data)
	s.burnAt = now + 1
	Fighter.proc(f, data.proc)
end

function Fury.onMissed(f: any, data: any, s: State, _move: any, _now: number)
	douse(f, data, s)
end

function Fury.tick(f: any, data: any, s: State, now: number, _dt: number)
	if not s.fx then
		return
	end
	if not Fighter.alive(f) or f.state == Enums.State.Knocked then
		douse(f, data, s)
		return
	end
	if now >= s.burnAt then
		s.burnAt = now + 1
		-- Never knocks: stops 1 HP above the knocked floor. All of it goes into the healable pool.
		local burn = math.min(data.burn, f.humanoid.Health - D.KNOCKED.hp - 1)
		if burn > 0 then
			f.humanoid.Health -= burn
			HealthSystem.addHealable(f, burn)
			f.selfDamagedAt = now -- it's damage: pauses regen like a hit
		end
	end
end

return Fury
