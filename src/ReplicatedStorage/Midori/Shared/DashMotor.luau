--!strict
-- Battlegrounds-style dash: direction snaps to front/back/left/right of a facing vector
-- (the camera, on the client) and the fighter bursts out, easing gently toward a stop.
-- Runs on whoever owns the assembly: the client for players, the server for dummies.
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")

local FIGHTER_TAG = "MidoriFighter" -- set on every fighter by the server (Fighter.lua)

local DashMotor = {}


-- Fighters collide, but a motor at full force driving into another player's body makes
-- the two owners shove each other over a contact each sees late. So this drops the part
-- of `vel` heading into any living fighter within BODY_BLOCK_DIST: the mover stops at
-- them or slides along them. Uses positions as this machine sees them.
local function unblocked(root: BasePart, vel: Vector3): Vector3
	local self = root.Parent
	local pos = root.Position
	for _, m in CollectionService:GetTagged(FIGHTER_TAG) do
		if m == self then
			continue
		end
		local other = m:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = m:FindFirstChildOfClass("Humanoid")
		if not other or not hum or hum.Health <= 0 then
			continue
		end
		local offset = other.Position - pos
		if math.abs(offset.Y) > D.BODY_BLOCK_HEIGHT then
			continue -- above or below us
		end
		local flat = Vector3.new(offset.X, 0, offset.Z)
		local d = flat.Magnitude
		if d > 1e-3 and d < D.BODY_BLOCK_DIST then
			local n = flat / d
			local into = vel:Dot(n)
			if into > 0 then
				vel -= n * into
			end
		end
	end
	return vel
end

-- Snaps a flat input direction to the nearest of the 4 directions relative to `facing`.
function DashMotor.snap(facing: Vector3, dir: Vector3): Vector3
	local right = facing:Cross(Vector3.yAxis)
	local f, r = dir:Dot(facing), dir:Dot(right)
	if math.abs(f) >= math.abs(r) then
		return if f >= 0 then facing else -facing
	end
	return if r >= 0 then right else -right
end

function DashMotor.classify(facing: Vector3, dir: Vector3): string
	local d = facing:Dot(dir)
	if d >= 0.5 then
		return "Front"
	elseif d <= -0.5 then
		return "Back"
	end
	return "Side"
end

-- `slowed`: inside a slow zone (D.SLOW_ZONE.dashDistance instead).
function DashMotor.distance(kind: string, isCancel: boolean, slowed: boolean?): number
	local base = if slowed then D.SLOW_ZONE.dashDistance else D.DASH_DISTANCE[kind] or D.DASH_DISTANCE.Front
	return base * (if isCancel then D.DASH_CANCEL_RANGE_MULT else 1)
end

-- Share of a dash's distance covered at share `s` (0-1) of its time, with no end speed: the curve
-- apply drives (full speed for DASH_HOLD, then easing out by DASH_EASE_POWER). Cutscenes use it to
-- ride and replay dashes exactly.
function DashMotor.ease(s: number): number
	local p, h = D.DASH_EASE_POWER, D.DASH_HOLD
	local total = h + (1 - h) / (p + 1)
	if s <= h then
		return s / total
	end
	local u = math.min(1, (s - h) / (1 - h))
	return (h + (1 - h) * (1 - (1 - u) ^ (p + 1)) / (p + 1)) / total
end

-- Moves along `dir` covering `distance` in `duration`, easing out by DASH_EASE_POWER.
-- Returns a cancel function (safe to call more than once).
-- `steer`, if given, is called every frame and returns the current flat direction, so
-- the dash can turn mid-flight. Without it the dash goes straight along `dir`.
-- `face` also turns the body to the movement direction (AlignOrientation) while it runs.
-- `endSpeed` (default 0) is the speed the ease lands on, e.g. walk speed for a player dash.
-- `flat` also holds vertical velocity at 0 (no gravity drift or dropping off ledges mid-move).
-- `arc` (studs, knockbacks): the path bows up this high and comes back down as it lands, a quadratic
-- Bezier from start to end with its control point 2 * arc up at the middle: height = 4 * arc * p * (1 - p)
-- at progress p (share of the distance covered), so it peaks halfway and lands at the end. Driven
-- through the velocity, never by CFrame: each frame climbs by exactly the curve's own rise over that
-- frame (open loop: a body held down by its Humanoid just bumps less, it never winds up a launch), and
-- the end never leaves the body moving up. Assumes endSpeed 0 (knockbacks).
-- Leftover horizontal velocity is cleared when the motor starts and when it ends.
function DashMotor.apply(root: BasePart, dir: Vector3, distance: number, duration: number, maxForce: number, steer: (() -> Vector3)?, face: boolean?, endSpeed: number?, flat: boolean?, arc: number?): () -> ()
	local arcing = arc ~= nil and arc > 0 and distance > 0
	local att = root:FindFirstChild("RootAttachment") :: Attachment?
	if not att then
		local created = Instance.new("Attachment")
		created.Name = "RootAttachment"
		created.Parent = root
		att = created
	end

	-- Full speed for the first DASH_HOLD of the time, then floor + (peak - floor) * (1 - u)^p over the
	-- rest (u: 0 -> 1). Distance = T * (peak * (hold + (1-hold)/(p+1)) + floor * (1-hold) * p/(p+1)).
	local power, hold = D.DASH_EASE_POWER, D.DASH_HOLD
	local floor = endSpeed or 0
	local peak = (distance / duration - floor * (1 - hold) * power / (power + 1)) / (hold + (1 - hold) / (power + 1))

	local lv = Instance.new("LinearVelocity")
	lv.Name = "MidoriDash"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	if flat or arcing then
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	else
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
		lv.PrimaryTangentAxis = Vector3.xAxis
		lv.SecondaryTangentAxis = Vector3.zAxis
	end
	local vy = 0 -- arc: vertical velocity for this frame
	-- Arc height above the start at time t (Bezier over the ease's progress).
	local function arcHeight(t: number): number
		local p = DashMotor.ease(math.min(1, t / duration))
		return 4 * (arc :: number) * p * (1 - p)
	end
	local function aimArc(t: number, step: number)
		vy = (arcHeight(t + step) - arcHeight(t)) / step
	end
	local function setVel(v: Vector3)
		if arcing then
			lv.VectorVelocity = Vector3.new(v.X, vy, v.Z)
		elseif flat then
			lv.VectorVelocity = Vector3.new(v.X, 0, v.Z)
		else
			lv.PlaneVelocity = Vector2.new(v.X, v.Z)
		end
	end
	local function clearMomentum()
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(0, if flat then 0 else v.Y, 0)
	end
	clearMomentum()
	if arcing then
		aimArc(0, 1 / 60)
	end
	setVel(unblocked(root, dir * peak))
	lv.MaxForce = maxForce
	lv.Parent = root

	local align: AlignOrientation? = nil
	if face then
		local a = Instance.new("AlignOrientation")
		a.Name = "MidoriDashFacing"
		a.Mode = Enum.OrientationAlignmentMode.OneAttachment
		a.Attachment0 = att
		a.RigidityEnabled = true
		a.CFrame = CFrame.lookAlong(Vector3.zero, dir)
		a.Parent = root
		align = a
	end

	local elapsed = 0
	local conn: RBXScriptConnection
	local done = false
	local function cancel()
		if done then
			return
		end
		done = true
		conn:Disconnect()
		lv:Destroy()
		if root.Parent then
			local v = root.AssemblyLinearVelocity
			-- Nothing slides out; the Humanoid takes over. An arc never hands back an upward launch.
			root.AssemblyLinearVelocity = Vector3.new(0, if arcing then math.min(v.Y, 0) else v.Y, 0)
		end
		if align then
			align:Destroy()
		end
	end
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= duration then
			cancel()
			return
		end
		local u = math.max(0, elapsed / duration - hold) / (1 - hold)
		local speed = floor + (peak - floor) * (1 - u) ^ power
		if arcing then
			aimArc(elapsed, dt)
		end
		local current = if steer then steer() else dir
		setVel(unblocked(root, current * speed))
		if align and current ~= Vector3.zero then
			align.CFrame = CFrame.lookAlong(Vector3.zero, current)
		end
	end)
	return cancel
end

-- Gakuran-style dash, steerable (user, 2026-10-13): constant speed (distance / duration) the whole
-- way, only the direction follows `steer`. The natural end keeps the leftover speed so the Humanoid
-- brakes it into a walk (the smooth part). Returns cancel(keepMomentum?): stuns/attacks call it
-- plain (stop dead); callers whose own timer may beat this one pass true at the natural end.
function DashMotor.burst(root: BasePart, dir: Vector3, distance: number, duration: number, maxForce: number, steer: (() -> Vector3)?): (keepMomentum: boolean?) -> ()
	local att = root:FindFirstChild("RootAttachment") :: Attachment?
	if not att then
		local created = Instance.new("Attachment")
		created.Name = "RootAttachment"
		created.Parent = root
		att = created
	end
	local speed = distance / duration
	local lv = Instance.new("LinearVelocity")
	lv.Name = "MidoriDash"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = maxForce
	local function setDir(d: Vector3)
		local v = unblocked(root, d * speed)
		lv.VectorVelocity = Vector3.new(v.X, 0, v.Z)
	end
	root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	setDir(dir)
	lv.Parent = root

	local elapsed = 0
	local done = false
	local conn: RBXScriptConnection
	local function cancel(keepMomentum: boolean?)
		if done then
			return
		end
		done = true
		conn:Disconnect()
		lv:Destroy()
		if root.Parent and not keepMomentum then
			root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
		end
	end
	conn = RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= duration then
			cancel(true)
		elseif steer then
			setDir(steer())
		end
	end)
	return cancel
end

return DashMotor
