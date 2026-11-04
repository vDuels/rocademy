--!strict
-- Anti-run (user, 2026-10-30): a 0-1 flee meter per fighter, owned by the server. Moving away from the
-- nearest fighter you're in combat with (CombatTag), within D.FLEE.range, fills it by how fast you're
-- going straight away from them (your own velocity, so being chased still counts); a dash away
-- adds D.FLEE.dash on top (CombatService.requestDash). Anything else drains it after drainDelay.
-- Only movement you choose counts: stuns (knockback), dashes / rushes (the chunk covers those), knocked,
-- gripping, cutscenes and being carried don't fill it.
-- Clients read the "Flee" attribute (walk + run slowed by CombatMath.fleeMult) and "FleeLocked" (no
-- running from a full meter until it's back under unlockAt) in RunController.
-- Speed check: logged, not punished (like the dash distance check) until the numbers look right.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local CombatMath = Paths.shared("CombatMath")
local State = Paths.shared("Enums").State
local Fighter = Paths.server("Fighter")
local CombatTag = Paths.server("CombatTag")

local NO_FILL = {
	[State.Hitstun] = true,
	[State.ParryStun] = true,
	[State.GuardBreakStun] = true,
	[State.Dash] = true,
	[State.Rush] = true,
	[State.RushMiss] = true,
	[State.Knocked] = true,
	[State.Gripping] = true,
	[State.Cutscene] = true,
}

local FLAT = Vector3.new(1, 0, 1) -- keeps the length (CombatMath.flat normalises)

local FleeSystem = {}

local function sync(f: any)
	local F = D.FLEE
	local sent = f.model:GetAttribute("Flee")
	sent = if typeof(sent) == "number" then sent else 0
	-- Every sendStep, plus the exact ends (so 0 really clears and 1 really shows full).
	if math.abs(f.flee - sent) >= F.sendStep or (f.flee ~= sent and (f.flee == 0 or f.flee == 1)) then
		f.model:SetAttribute("Flee", if f.flee > 0 then f.flee else nil)
	end
	local locked = f.model:GetAttribute("FleeLocked") == true
	if f.fleeLocked ~= locked then
		f.model:SetAttribute("FleeLocked", f.fleeLocked or nil)
	end
end

local function set(f: any, value: number)
	local F = D.FLEE
	f.flee = math.clamp(value, 0, 1)
	if f.flee >= F.lockAt then
		f.fleeLocked = true
	elseif f.flee <= F.unlockAt then
		f.fleeLocked = false
	end
	sync(f)
end

-- Nearest live, standing foe within range: the flat direction from them to us, or nil.
local function awayDir(f: any): Vector3?
	local best: Vector3?, bestDist = nil, D.FLEE.range
	for _, other in CombatTag.foes(f) do
		if Fighter.hittable(other) then
			local to = (f.root.Position - other.root.Position) * FLAT
			local dist = to.Magnitude
			if dist <= bestDist and dist > 1e-3 then
				best, bestDist = to.Unit, dist
			end
		end
	end
	return best
end

-- A dash away from a close foe (CombatMath.dashIntent "Away").
function FleeSystem.dashAway(f: any, now: number)
	f.fleeAt = now
	set(f, (f.flee or 0) + D.FLEE.dash)
end

function FleeSystem.tick(f: any, now: number, dt: number)
	local F = D.FLEE
	f.flee = f.flee or 0
	f.fleeAt = f.fleeAt or -math.huge
	f.fleeLocked = f.fleeLocked or false
	local vel = f.root.AssemblyLinearVelocity * FLAT
	local away = awayDir(f)
	local speed = if away then vel:Dot(away) else 0
	local counts = away ~= nil and not NO_FILL[f.state] and f.model:GetAttribute("Carried") ~= true
	if counts and speed >= F.minSpeed then
		f.fleeAt = now
		set(f, f.flee + speed / F.fullStuds * dt)
	elseif f.flee > 0 and now - f.fleeAt >= F.drainDelay then
		set(f, f.flee - F.drainPerSec * dt)
	end
	-- Speed check (log only). The fastest legal run: perk run mult x Focus's best x the flee slow.
	if f.flee > 0 and not NO_FILL[f.state] and f.model:GetAttribute("Skating") ~= true and now >= (f.fleeWarnAt or 0) then
		local runMult = f.model:GetAttribute("RunSpeedMult")
		local cap = D.RUN_SPEED * (if typeof(runMult) == "number" then runMult else 1) * F.focusMax * CombatMath.fleeMult(f.flee) + F.speedSlack
		if vel.Magnitude > cap then
			f.fleeWarnAt = now + 2
			warn(string.format("[Midori] %s moving %.1f st/s while fleeing (cap %.1f)", f.model.Name, vel.Magnitude, cap))
		end
	end
end

return FleeSystem
