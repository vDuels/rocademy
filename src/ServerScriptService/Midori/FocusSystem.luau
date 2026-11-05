--!strict
-- Focus meter (user, 2026-10-23; Prodigy's Astronaut perk turns it on via mods.focus). Like a second
-- adrenaline with no damage bonus: built by dodges and landed hits, lost when you take damage, drained
-- by adrenaline with Spacesuit. Its bonuses (anti-heal, counter damage, shorter endlag) read the
-- Focus snapshotted when an attack starts (f.attackFocus), like adrenaline. Numbers: D.FOCUS.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local CombatMath = Paths.shared("CombatMath")
local Fighter = Paths.server("Fighter")

local F = D.FOCUS

local FocusSystem = {}

-- 0-1 of full; always 0 without the meter.
function FocusSystem.ratio(f: any): number
	return if f.mods.focus > 0 then math.clamp(f.focus / F.max, 0, 1) else 0
end

function FocusSystem.full(f: any): boolean
	return f.mods.focus > 0 and CombatMath.focusFull(f.focus, F.max)
end

-- Adds (or with a negative amount, removes) Focus; nothing without the meter.
function FocusSystem.gain(f: any, amount: number)
	if f.mods.focus <= 0 or amount == 0 then
		return
	end
	f.focus = math.clamp(f.focus + amount, 0, F.max)
	Fighter.syncMeters(f, true)
end

-- Spends it all (Lightshow).
function FocusSystem.empty(f: any)
	f.focus = 0
	Fighter.syncMeters(f, true)
end

-- A landed hit by `f` with `move`. With Uppercut to the Moon a landed M2 gains F.m2Gain
-- (user, 2026-10-25); counters gain more, except on M2s (user, 2026-10-24: no M2 counter bonus).
function FocusSystem.onLanded(f: any, move: any, counter: boolean)
	if move.focusShare > 0 then
		-- Eject: gains this share of your current Focus instead, counter or not (user, 2026-10-25).
		FocusSystem.gain(f, f.focus * move.focusShare)
		return
	end
	local m2Boost = move.kind == "M2" and f.mods.m2FocusGain > 0
	local counterMult = if counter and move.kind ~= "M2" then F.counterGainMult else 1
	FocusSystem.gain(f, (if m2Boost then F.m2Gain else F.hitGain) * counterMult)
	if m2Boost then
		Fighter.proc(f, "m2FocusGain") -- lights Uppercut to the Moon's card
	end
end

-- `v` was hit by `a`'s `move`: a flat loss by move kind, more on a counter. Once per attack
-- (a.attackSeq), so a multi-hit attack (barrage) costs it once.
function FocusSystem.onStruck(v: any, a: any, move: any, counter: boolean)
	if v.focusLossFrom == a and v.focusLossSeq == a.attackSeq then
		return
	end
	v.focusLossFrom, v.focusLossSeq = a, a.attackSeq
	FocusSystem.gain(v, -(F.hitLoss[move.kind] or 0) * (if counter then F.counterLossMult else 1))
end

-- `f`'s attack was parried: loses F.parriedLoss of its current Focus (user, 2026-10-25).
function FocusSystem.onParried(f: any)
	FocusSystem.gain(f, -f.focus * F.parriedLoss)
end

-- How much more Focus counts on this move (M2s with Uppercut to the Moon).
function FocusSystem.power(f: any, move: any): number
	return if move.kind == "M2" then 1 + f.mods.m2FocusPower else 1
end

-- The current attack's Focus bonuses (attacker `a`, snapshotted at its start).
function FocusSystem.antiHeal(a: any, move: any): number
	return F.antiHeal * a.attackFocus * FocusSystem.power(a, move)
end

function FocusSystem.counterDamage(a: any, move: any): number
	return F.counterDamage * a.attackFocus * FocusSystem.power(a, move)
end

-- Extra counter multiplier `v` takes (Spacesuit): flat, +35% of the hit (user, 2026-10-25; was adrenaline-scaled).
function FocusSystem.counterTaken(v: any): number
	return v.mods.counterTaken
end

-- An M1's base damage: 60%+ Focus at attack start drops it to F.m1Damage.damage (user, 2026-10-25).
function FocusSystem.baseDamage(a: any, move: any): number
	if move.kind == "M1" and a.mods.focus > 0 and a.attackFocus >= F.m1Damage.at then
		return math.min(move.damage, F.m1Damage.damage)
	end
	return move.damage
end

-- Lightshow is armed: its cutscene move (Reentry) is unlocked (a landed Eject, MoveSchema unlocks) and
-- Focus is full.
local function lightshowArmed(f: any, now: number): boolean
	if f.mods.focusCutscene <= 0 or not FocusSystem.full(f) then
		return false
	end
	for id, untilT in f.moveUnlocks do
		local m = f.style.moves[id]
		if m and m.cutscene and now <= untilT then
			return true
		end
	end
	return false
end

-- Spacesuit: adrenaline drains Focus, faster the more adrenaline. Not while Lightshow is armed (bug,
-- 2026-11-05: "Lightshow sometimes never procs at 100 Focus"): Reentry can only start once Eject's endlag
-- is over, and full is checked when it starts, so with high adrenaline the drain over that endlag (+ ping)
-- took Focus below full after the HUD had shown FULL! and R was already pressed.
function FocusSystem.tick(f: any, now: number, dt: number)
	local drain = f.mods.adrFocusDrain
	if drain > 0 and f.focus > 0 and f.adrenaline > 0 and not lightshowArmed(f, now) then
		f.focus = math.max(0, f.focus - drain * math.min(CombatMath.ratio(f.adrenaline), 1) * dt)
		Fighter.syncMeters(f)
	end
end

return FocusSystem