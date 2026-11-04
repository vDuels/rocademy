--!strict
-- Knockback runs on whoever owns the victim's physics, like the dash. A player's client owns
-- its character, so the server sends the push to that client and the client runs the same
-- eased DashMotor curve on itself. The server never takes network ownership: swapping it
-- mid-fight snapped the victim back to the server's stale position and again on handback.
-- The victim is in hitstun the whole time, so they have no input to fight it with.
-- Dummies are server-owned, so the server pushes them directly.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local CombatMath = Paths.shared("CombatMath")
local DashMotor = Paths.shared("DashMotor")
local Net = Paths.shared("Net")

type Active = { cancel: () -> (), token: number }

local active: { [any]: Active } = {}
local nextToken = 0

local Knockback = {}

-- `target` (pulls): the client measures dir/distance to it from where it really is.
-- `up`: upward launch speed added at the start (studs/s). `arc`: Bezier arc height (DashMotor.apply).
local function send(v: any, dir: Vector3, distance: number, duration: number, target: Vector3?, up: number?, arc: number?)
	local player = v.player
	if player and player.Character == v.model then
		Net.get("Knockback"):FireClient(player, dir, distance, duration, target, up, arc)
	end
end

-- Ends a fighter's knockback early (death, a newer knockback).
function Knockback.stop(v: any)
	local a = active[v]
	if not a then
		return
	end
	active[v] = nil
	a.cancel()
end

function Knockback.isActive(v: any): boolean
	return active[v] ~= nil
end

-- "Toward" never pulls closer than this (studs between roots): the victim lands in front, not inside you.
local TOWARD_GAP = 3

-- Pushes `v` (flat) along the attacker's facing, or straight away from the attacker for
-- direction "Away", covering kb.distance in kb.duration. "Toward" pulls `v` in at the attacker
-- instead (Slugger Critical), at most kb.distance and never closer than TOWARD_GAP.
type Kb = { distance: number, duration: number, direction: string, up: number?, arc: number? }

-- Where `kb` sends `v`: (flat dir, distance, pull landing spot or nil). nil dir = nowhere.
local function aim(a: any, v: any, kb: Kb): (Vector3?, number, Vector3?)
	local facing = CombatMath.flat(a.root.CFrame.LookVector)
	if kb.direction == "Toward" then
		local off = (v.root.Position - a.root.Position) * Vector3.new(1, 0, 1) -- (CombatMath.flat is a unit vector)
		local room = off.Magnitude - TOWARD_GAP
		if room <= 0.05 then
			return nil, 0, nil
		end
		-- A landing spot, not a distance: the victim's client measures the pull from where it really
		-- is (like grabs), so it stops in front of you instead of overshooting onto you.
		local pulled = math.min(kb.distance, room)
		local target = a.root.Position + off.Unit * (off.Magnitude - pulled)
		return -off.Unit, pulled, Vector3.new(target.X, v.root.Position.Y, target.Z)
	end
	local dir = facing
	if kb.direction == "Away" then
		dir = CombatMath.flat(v.root.Position - a.root.Position)
		if dir == Vector3.zero then
			dir = facing -- standing inside each other: fall back to facing
		end
	end
	return if dir == Vector3.zero then nil else dir, kb.distance, nil
end

function Knockback.apply(a: any, v: any, kb: Kb)
	local dir, distance, target = aim(a, v, kb)
	if dir then
		Knockback.push(v, dir, distance, kb.duration, target, kb.up, kb.arc)
	end
end

-- The same knockback as one ragdoll launch velocity (D.RAGDOLL; for Ragdoll.apply's `launch`): a hit
-- that ragdolls / knocks its victim throws the limp body instead of motoring it. Stops any running push.
function Knockback.launch(a: any, v: any, kb: Kb?): Vector3?
	if not kb then
		return nil
	end
	Knockback.stop(v)
	local dir, distance = aim(a, v, kb)
	return if dir then Paths.shared("Ragdoll").launchVelocity(dir, distance, kb.duration, kb.up) else nil
end

-- Pulls `v` (flat) to `target` over `duration` (grabs).
function Knockback.pullTo(v: any, target: Vector3, duration: number)
	local delta = (target - v.root.Position) * Vector3.new(1, 0, 1)
	if delta.Magnitude < 0.05 then
		return
	end
	Knockback.push(v, delta.Unit, delta.Magnitude, duration, target)
end

function Knockback.push(v: any, dir: Vector3, distance: number, duration: number, target: Vector3?, up: number?, arc: number?)
	Knockback.stop(v)
	nextToken += 1
	local token = nextToken
	local cancel: () -> ()
	if v.player then
		send(v, dir, distance, duration, target, up, arc)
		cancel = function()
			send(v, Vector3.zero, 0, 0) -- distance 0 tells the client to stop
		end
	elseif v.model:GetAttribute("Ragdolled") ~= nil then
		-- Limp already (a hit on a ragdolled dummy): a launch, never a motor (D.RAGDOLL). Players: their client.
		local Ragdoll = Paths.shared("Ragdoll")
		Ragdoll.push(v.model, Ragdoll.launchVelocity(dir, distance, duration, up))
		cancel = function() end
	else
		cancel = DashMotor.apply(v.root, dir, distance, duration, D.KNOCKBACK_MAX_FORCE, nil, nil, nil, nil, arc)
		if up and up > 0 and not v.root.Anchored then
			v.root.AssemblyLinearVelocity += Vector3.yAxis * up -- the motor only drives the flat plane
		end
	end
	active[v] = { cancel = cancel, token = token }
	task.delay(duration, function()
		local cur = active[v]
		if cur and cur.token == token then
			active[v] = nil -- finished on its own; nothing to cancel (a limp body slides out on friction: D.RAGDOLL)
		end
	end)
end

return Knockback
