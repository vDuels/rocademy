--!strict
local CollectionService = game:GetService("CollectionService")
local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")

local CombatMath = {}

-- Adrenaline over the BASE max. A perk-raised max (Aggressive Personality) can push this past 1,
-- so its extra adrenaline keeps scaling the damage and speed bonuses.
function CombatMath.ratio(adrenaline: number): number
	return math.max(adrenaline / D.ADR_MAX, 0)
end

-- Health-damage multiplier from adrenaline (guard damage never uses this).
function CombatMath.damageMult(adrenaline: number): number
	return 1 + D.ADR_MAX_DAMAGE_BONUS * CombatMath.ratio(adrenaline)
end

-- Attack animation speed from adrenaline: startup shrinks, endlag duration does not.
function CombatMath.speed(adrenaline: number): number
	return 1 + D.ADR_MAX_SPEED_BONUS * CombatMath.ratio(adrenaline)
end

-- How many swings into its style's M1 chain `move` is (hit 1 = 0); 0 for anything else.
function CombatMath.chainStep(style: any, move: any): number
	local i = if move.kind == "M1" then table.find(style.m1Chain, move.id) else nil
	return if i then i - 1 else 0
end

-- Chain endlag mod (Measured Strikes): later chain M1s get a copy of the move with longer endlag
-- (additive per step). Hitstun/blockstun are fixed in data, so they don't grow with it.
function CombatMath.chainMove(style: any, move: any, endlagPerStep: number): any
	local step = CombatMath.chainStep(style, move)
	if endlagPerStep == 0 or step == 0 then
		return move
	end
	local copy = table.clone(move)
	copy.endlag = move.endlag * (1 + endlagPerStep * step)
	return copy
end

-- Focus (D.FOCUS) on an attack, server and the owner's client alike: `ratio` = Focus / max when it
-- starts. Returns the move with its endlag cut, and a speed factor for the windup: an M2 eases toward
-- `m2Startup` seconds at full Focus (Uppercut to the Moon), folded into the attack speed so everyone's
-- animation timing agrees. `m2Power` = how much more Focus counts on M2s (1 = normal).
function CombatMath.focusMove(move: any, ratio: number, m2Power: number, m2Startup: number): (any, number)
	if ratio <= 0 then
		return move, 1
	end
	local m2 = move.kind == "M2"
	local copy = table.clone(move)
	copy.endlag = move.endlag * math.max(0, 1 - D.FOCUS.endlag * ratio * (if m2 then m2Power else 1))
	local speed = 1
	if m2 and m2Startup > 0 and m2Startup < move.startup then
		speed = move.startup / (move.startup + (m2Startup - move.startup) * ratio)
	end
	return copy, speed
end

-- `counterBonus` is added to D.COUNTER_MULT on counters (perks).
function CombatMath.damage(base: number, mult: number, counter: boolean, counterBonus: number?): number
	return base * mult * (if counter then D.COUNTER_MULT + (counterBonus or 0) else 1)
end

function CombatMath.flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	if f.Magnitude > 1e-4 then
		return f.Unit
	end
	return Vector3.zero
end

function CombatMath.inFrontArc(defender: CFrame, attackerPos: Vector3, arcDeg: number): boolean
	local to = CombatMath.flat(attackerPos - defender.Position)
	if to == Vector3.zero then
		return true
	end
	local look = CombatMath.flat(defender.LookVector)
	return look:Dot(to) >= math.cos(math.rad(arcDeg * 0.5)) - 1e-6
end

-- Full Focus (Lightshow) = within 1 of max: the Focus attribute only replicates 1-point changes, so the
-- server and the HUD agree on this, and Spacesuit's drain doesn't knock it off "full" in a frame.
function CombatMath.focusFull(focus: number, max: number): boolean
	return focus > max - 1
end

-- Dash cooldown for a fighter holding `focus` (0 without the meter): shorter at high Focus (Prodigy).
-- Server (requestDash) and client (tryDash prediction) both use this.
function CombatMath.dashCooldown(focus: number): number
	return D.DASH_COOLDOWN * (if focus >= D.FOCUS.dashCdFocus then 1 - D.FOCUS.dashCdCut else 1)
end

-- What a dash from `origin` along `dir` does relative to the nearest of `enemies` (positions):
-- "Away" (fleeing a close one), "Toward" (closing on a far one) or nil (around them / nobody near).
-- Server (requestDash) and client (tryDash prediction) both use this. D.DASH_INTENT has the thresholds.
function CombatMath.dashIntent(origin: Vector3, dir: Vector3, enemies: { Vector3 }): string?
	local I = D.DASH_INTENT
	local d = CombatMath.flat(dir)
	local best, bestDist = nil, I.towardMaxRange
	for _, pos in enemies do
		local to = Vector3.new(pos.X - origin.X, 0, pos.Z - origin.Z)
		if to.Magnitude <= bestDist then
			best, bestDist = to, to.Magnitude
		end
	end
	if not best or d == Vector3.zero or bestDist < 1e-3 then
		return nil
	end
	local dot = d:Dot(best.Unit)
	if bestDist <= I.awayRange and dot <= I.awayDot then
		return "Away"
	elseif bestDist >= I.towardMinRange and dot >= I.towardDot then
		return "Toward"
	end
	return nil
end

-- Share of incoming anti-heal ignored at this much adrenaline: linear to D.ADR_ANTIHEAL_RESIST.max at .full.
function CombatMath.antiHealResist(adrenaline: number): number
	local R = D.ADR_ANTIHEAL_RESIST
	return R.max * math.clamp(adrenaline / R.full, 0, 1)
end

-- Walk + run speed multiplier for a flee meter value (0-1; D.FLEE). Server speed check + RunController.
function CombatMath.fleeMult(flee: number): number
	return 1 - (1 - D.FLEE.minMult) * math.clamp(flee, 0, 1)
end

-- The dash cooldown multiplier for a dashIntent result.
function CombatMath.dashIntentMult(intent: string?): number
	local I = D.DASH_INTENT
	return if intent == "Away" then I.awayCooldownMult elseif intent == "Toward" then I.towardCooldownMult else 1
end

-- Is `model` (at `pos`) inside its slow zone at `now` (D.SLOW_ZONE)? Server and client both read
-- the attributes the server put on it.
function CombatMath.inSlowZone(model: Instance, pos: Vector3, now: number): boolean
	local at, ends = model:GetAttribute("SlowZoneAt"), model:GetAttribute("SlowZoneEnds")
	return typeof(at) == "Vector3" and typeof(ends) == "number" and now < ends
		and ((pos - at) * Vector3.new(1, 0, 1)).Magnitude <= D.SLOW_ZONE.radius
end

-- A swing charge move's tier after `held` seconds of windup (press -> release, incl. startup).
-- 1ms slack so an auto release at exactly a tier's `at` reaches it.
function CombatMath.chargeTier(move: any, held: number): any
	local tiers = move.charge.tiers
	local tier = tiers[1]
	for _, t in tiers do
		if held >= t.at - 1e-3 then
			tier = t
		end
	end
	return tier
end

-- A blink move's lane length after `held` seconds of windup (from the press), where `startup` is
-- this attack's real minimum windup: 0 -> blink.min over startup, then -> blink.max over charge.time.
function CombatMath.blinkRange(move: any, held: number, startup: number): number
	local b = move.blink
	if held < startup then
		return b.min * math.max(held, 0) / startup
	end
	return b.min + (b.max - b.min) * math.clamp((held - startup) / move.charge.time, 0, 1)
end

-- The blink lane as a box hitbox (`range` long, starting at the attacker).
function CombatMath.blinkHitbox(move: any, range: number): any
	local b = move.blink
	return { shape = "Box", size = Vector3.new(b.width, b.height, math.max(range, 0.1)), offset = CFrame.new(0, 0, -range / 2) }
end

-- Where a blink from `root` lands: `range` studs along its flat facing, stopped
-- D.BLINK_WALL_GAP short of the first wall (characters and `ignore` don't block it).
function CombatMath.blinkTarget(root: BasePart, range: number, ignore: { Instance }): CFrame
	local dir = CombatMath.flat(root.CFrame.LookVector)
	if dir == Vector3.zero then
		return root.CFrame
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	local hit = workspace:Raycast(root.Position, dir * range, params)
	local dist = range
	while hit and hit.Instance.Parent and hit.Instance.Parent:FindFirstChildOfClass("Humanoid") do
		-- Characters never stop it: skip past them and look again.
		table.insert(ignore, hit.Instance.Parent)
		params.FilterDescendantsInstances = ignore
		hit = workspace:Raycast(root.Position, dir * range, params)
	end
	if hit then
		dist = math.max(0, hit.Distance - D.BLINK_WALL_GAP)
	end
	return root.CFrame + dir * dist
end

-- The R move `root`'s fighter throws: its `close` swap (Prodigy: Eject) when another living fighter
-- is within close.range, else the style's R (Reentry). The client measures what it sees; the server
-- passes `origin` (the player's own reported pose) and `posOf` (where the player saw each fighter,
-- LagComp) so both measure the same gap. Without them the server and client could disagree and a
-- close press would throw Reentry (and its Lightshow cutscene) instead of Eject (bug, 2026-10-24).
function CombatMath.rMove(style: any, root: BasePart, origin: Vector3?, posOf: ((Model) -> Vector3?)?): any?
	local move = style.r and style.moves[style.r]
	local close = move and move.close
	if close and not close.range then
		return style.moves[close.move] -- no range: always swaps (Prodigy Eject, user 2026-10-25)
	elseif close then
		local from = origin or root.Position
		for _, model in CollectionService:GetTagged("MidoriFighter") do
			local hrp = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			local hum = model:FindFirstChildOfClass("Humanoid")
			if hrp and hrp ~= root and hum and hum.Health > 0 then
				local at = if posOf then posOf(model :: Model) or hrp.Position else hrp.Position
				if (at - from).Magnitude <= (close.range :: number) then
					return style.moves[close.move]
				end
			end
		end
	end
	return move
end

return CombatMath
