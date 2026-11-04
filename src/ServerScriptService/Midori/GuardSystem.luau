--!strict
-- Guard health: damage from blocked hits, break/restore, and paused regeneration.
-- Max guard is Fighter.guardMax (style.guardMax, default D.GUARD_MAX, plus perk bonuses).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Fighter = Paths.server("Fighter")

local GuardSystem = {}

function GuardSystem.damage(f: any, amount: number, regenDelay: number, now: number)
	f.guard = math.max(0, f.guard - math.max(0, amount + f.mods.guardDamageTaken))
	if amount > 0 and f.mods.guardDamageTaken ~= 0 then
		Fighter.proc(f, "guardDamageTaken")
	end
	if amount > 0 and f.mods.guardMax > 0 and f.guard > 0 then
		Fighter.proc(f, "guardMax") -- the extra max guard is what's holding
	end
	f.guardRegenPausedUntil = math.max(f.guardRegenPausedUntil, now + regenDelay * (1 - f.mods.guardRegenDelayCut))
	Fighter.syncMeters(f, true)
end

-- Guard returns at a fraction of max and stays paused; the no-block window is handled by
-- CombatService when the break stun ends.
function GuardSystem.breakGuard(f: any, now: number)
	f.guard = Fighter.guardMax(f) * D.GUARD_BREAK_RESTORE
	f.guardRegenPausedUntil = now + D.GUARD_BREAK_REGEN_PAUSE
	Fighter.syncMeters(f, true)
end

function GuardSystem.tick(f: any, now: number, dt: number)
	local max = Fighter.guardMax(f)
	if f.guard < max and now >= f.guardRegenPausedUntil then
		-- Holding block (block start / held / blocked) regens faster (user, 2026-10-10).
		local mult = if f.blockHeld and Fighter.isGuarding(f) then D.GUARD_REGEN_BLOCKING_MULT else 1
		f.guard = math.min(max, f.guard + D.GUARD_REGEN_PER_SEC * mult * dt)
		Fighter.syncMeters(f)
	end
end

return GuardSystem
