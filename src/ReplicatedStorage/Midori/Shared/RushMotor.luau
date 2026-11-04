--!strict
-- Rush movement (Feng Critical): a constant-speed charge along a flat direction. With a
-- `target` (the camera look, on the client) the direction turns toward it, but never faster
-- than `turnRate` deg/s, so the rush is only slightly steerable. easeOut() is the miss carry:
-- the steering keeps going while the speed eases to a stop. Runs on whoever owns the
-- assembly, like DashMotor: the client for players, the server for dummies.
local RunService = game:GetService("RunService")

local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")

export type Motor = {
	dir: Vector3,
	easeOut: (self: Motor, duration: number) -> (),
	stop: (self: Motor) -> (),
}

local RushMotor = {}

-- Turns flat unit `from` toward flat unit `to` by at most `maxAngle` radians, around Y.
function RushMotor.turn(from: Vector3, to: Vector3, maxAngle: number): Vector3
	if to == Vector3.zero then
		return from
	end
	local angle = math.atan2(from:Cross(to).Y, from:Dot(to))
	return CFrame.fromAxisAngle(Vector3.yAxis, math.clamp(angle, -maxAngle, maxAngle)):VectorToWorldSpace(from)
end

-- `face` also turns the body to the rush direction (AlignOrientation) while it runs.
function RushMotor.start(root: BasePart, dir: Vector3, speed: number, turnRate: number, target: (() -> Vector3)?, face: boolean?): Motor
	local att = root:FindFirstChild("RootAttachment") :: Attachment?
	if not att then
		local created = Instance.new("Attachment")
		created.Name = "RootAttachment"
		created.Parent = root
		att = created
	end

	local lv = Instance.new("LinearVelocity")
	lv.Name = "MidoriRush"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lv.PrimaryTangentAxis = Vector3.xAxis
	lv.SecondaryTangentAxis = Vector3.zAxis
	lv.PlaneVelocity = Vector2.new(dir.X * speed, dir.Z * speed)
	lv.MaxForce = D.DASH_MAX_FORCE
	lv.Parent = root

	local align: AlignOrientation? = nil
	if face then
		local a = Instance.new("AlignOrientation")
		a.Name = "MidoriRushFacing"
		a.Mode = Enum.OrientationAlignmentMode.OneAttachment
		a.Attachment0 = att
		a.RigidityEnabled = true
		a.CFrame = CFrame.lookAlong(Vector3.zero, dir)
		a.Parent = root
		align = a
	end

	local motor = { dir = dir } :: any
	local maxTurn = math.rad(turnRate)
	local easeFor: number? = nil
	local easeElapsed = 0
	local conn: RBXScriptConnection
	local done = false

	function motor.stop(_self: Motor)
		if done then
			return
		end
		done = true
		conn:Disconnect()
		lv:Destroy()
		-- Stop dead: without this the body keeps the rush speed and slides on (a carry is easeOut's job).
		local v = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(0, v.Y, 0)
		if align then
			align:Destroy()
		end
	end

	function motor.easeOut(_self: Motor, duration: number)
		if easeFor == nil then
			easeFor = duration
		end
	end

	conn = RunService.Heartbeat:Connect(function(dt)
		local v = speed
		local ease = easeFor
		if ease then
			easeElapsed += dt
			if easeElapsed >= ease then
				motor:stop()
				return
			end
			v = speed * (1 - easeElapsed / ease) ^ D.RUSH_CARRY_EASE_POWER
		end
		if target and maxTurn > 0 then
			motor.dir = RushMotor.turn(motor.dir, target(), maxTurn * dt)
		end
		local d = motor.dir
		lv.PlaneVelocity = Vector2.new(d.X * v, d.Z * v)
		if align then
			align.CFrame = CFrame.lookAlong(Vector3.zero, d)
		end
	end)
	return motor :: Motor
end

return RushMotor
