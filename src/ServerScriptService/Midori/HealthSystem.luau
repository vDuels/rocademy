--!strict
-- Healable HP (user, 2026-10-14). Humanoid.Health stays the real HP (death, CoreGui, kill parts);
-- f.healable is the part of the missing HP that can still come back (the dark red on the bar).
-- Every heal only refills healable HP. Regen waits D.HEAL_REGEN_DELAY after being attacked.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Fighter = Paths.server("Fighter")
local Enums = Paths.shared("Enums")
local CombatMath = Paths.shared("CombatMath")

local HealthSystem = {}

local function missing(f: any): number
	return math.max(0, f.humanoid.MaxHealth - f.humanoid.Health)
end

-- Heals up to `amount`, taken out of the healable pool. Returns what was healed.
function HealthSystem.heal(f: any, amount: number): number
	local h = math.min(amount, f.healable, missing(f))
	if h <= 0 then
		return 0
	end
	f.humanoid.Health += h
	f.healable -= h
	Fighter.syncMeters(f)
	return h
end

-- Adds up to `amount` of missing HP to the healable pool (regen then heals it back). Only capped by
-- missing HP, not D.HEAL_MAX (that cap is for hits). Returns what was added. (Soda, user 2026-10-17)
function HealthSystem.addHealable(f: any, amount: number): number
	local add = math.max(0, math.min(amount, missing(f) - f.healable))
	if add > 0 then
		f.healable += add
		Fighter.syncMeters(f, true)
	end
	return add
end

-- A kill: all missing HP becomes healable, and D.SIPHON.heal of it comes back over D.SIPHON.duration.
function HealthSystem.siphon(f: any)
	f.healable = missing(f)
	f.siphonLeft = D.SIPHON.heal
	Fighter.syncMeters(f, true)
end

-- Health damage from attacker `a` (nil = no attacker). antiHeal (0-1) wipes that fraction of
-- the existing healable pool AND of this hit's own healable part. A hit that would kill KNOCKS
-- instead (user, 2026-10-18): HP stops at D.KNOCKED.hp and this returns true; the caller knocks
-- (KnockService) once the hit is done. It still counts as a kill for the attacker's siphon.
function HealthSystem.damage(a: any?, v: any, amount: number, antiHeal: number): boolean
	local before = v.humanoid.Health
	local floor = D.KNOCKED.hp
	if v.model:FindFirstChildOfClass("ForceField") or before <= floor then
		return false -- spawn protection (as TakeDamage), or already down
	end
	local knocked = before - amount <= floor
	if knocked then
		v.humanoid.Health = floor
	else
		v.humanoid:TakeDamage(amount)
	end
	local dealt = before - v.humanoid.Health
	-- Ragdolls (D.RAGDOLL; user, 2026-11-03): a limp body takes no anti-heal, and just after getting up it resists some.
	-- Read before this hit's own ragdoll starts (HitResolver ragdolls after the damage), so the hit that
	-- ragdolls you still applies its anti-heal; only the hits on the body already down are spared.
	local R = D.RAGDOLL
	if v.model:GetAttribute("Ragdolled") ~= nil then
		antiHeal = 0
	elseif v.gotUpAt and workspace:GetServerTimeNow() - v.gotUpAt <= R.getUpWindow then
		antiHeal *= 1 - R.getUpResist
	end
	-- The victim's adrenaline resists anti-heal (user, 2026-10-30; CombatMath.antiHealResist).
	local keep = 1 - antiHeal * (1 - CombatMath.antiHealResist(v.adrenaline or 0))
	v.healable = math.min(missing(v), D.HEAL_MAX, (v.healable + dealt * D.HEAL_KEEP) * keep)
	if knocked then
		v.healable = 0
		v.siphonLeft = 0
	end
	Fighter.syncMeters(v, true)
	if a and knocked and Fighter.alive(a) then
		HealthSystem.siphon(a)
	end
	return knocked
end

function HealthSystem.tick(f: any, now: number, dt: number)
	if f.healable <= 0 or not Fighter.alive(f) or f.state == Enums.State.Knocked then
		return -- nothing to heal, or down (knocked: no regen until you get up)
	end
	if f.siphonLeft > 0 then
		local step = math.min(f.siphonLeft, D.SIPHON.heal / D.SIPHON.duration * dt)
		f.siphonLeft -= step
		HealthSystem.heal(f, step) -- an anti-heal hit mid-siphon empties the pool, which ends it
	end
	-- Regen waits HEAL_REGEN_DELAY after being attacked AND after leaving a stun (user, 2026-10-17; endlag doesn't count),
	-- and after self damage (Fury's burn; user, 2026-11-03).
	-- mods.noRegen (Fury while lit; user, 2026-11-03) pauses it outright.
	if f.mods.noRegen <= 0 and not Enums.STUNS[f.state] and now - math.max(f.lastHitTakenAt, f.stunEndedAt, f.selfDamagedAt) >= D.HEAL_REGEN_DELAY then
		HealthSystem.heal(f, D.HEAL_REGEN_PER_SEC * dt)
	end
end

return HealthSystem
