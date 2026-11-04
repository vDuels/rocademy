--!strict
-- Adrenaline meter: gained by taking hits, being guard-broken and parrying; drains once you
-- stop getting hit. Attacks snapshot it when they start (see CombatService.startAttack).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Fighter = Paths.server("Fighter")

local AdrenalineSystem = {}

-- Positive amounts are gains (boosted by mods.adrenalineGain); negative ones are costs.
function AdrenalineSystem.gain(f: any, amount: number)
	if amount > 0 then
		amount *= 1 + f.mods.adrenalineGain
		if f.mods.adrenalineGain ~= 0 then
			Fighter.proc(f, "adrenalineGain")
		end
	end
	f.adrenaline = math.clamp(f.adrenaline + amount, 0, Fighter.adrMax(f))
	Fighter.syncMeters(f, true)
end

-- Being attacked at all (hit, blocked, parried, guard-broken) restarts the drain delay.
function AdrenalineSystem.markAttacked(f: any, now: number)
	f.lastHitTakenAt = now
end

function AdrenalineSystem.onStruck(f: any, amount: number, now: number)
	AdrenalineSystem.markAttacked(f, now)
	AdrenalineSystem.gain(f, amount)
end

function AdrenalineSystem.tick(f: any, now: number, dt: number)
	if f.adrenaline > 0 and now - f.lastHitTakenAt >= D.ADR_DRAIN_DELAY then
		f.adrenaline = math.max(0, f.adrenaline - D.ADR_DRAIN_PER_SEC * dt)
		Fighter.syncMeters(f)
	end
end

return AdrenalineSystem
