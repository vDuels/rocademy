--!strict
-- R6 ragdoll (rebuilt 2026-10-24; user: "overall ragdolling is a buggy mess"). The REAL body goes limp:
-- the server turns the limb Motor6Ds off and BallSocketConstraints (pre-built at spawn, `rig`) on, and
-- whoever owns the body simulates it: the player's client, the server for dummies. Roblox replicates
-- every limb like any physics, so every screen sees the same body. (The old version built a separate
-- local skeleton on every screen and pulled it to the root with aligns: screens disagreed, settled
-- bodies slid off, knockbacks overshot.)
-- The RootJoint stays on: the HumanoidRootPart rides inside the torso, so the camera, the server's
-- position checks and knockback (a DashMotor on the root) all move the body itself.
-- R6 Humanoids force limb CanCollide off, so every body part gets an invisible collider (a child of the
-- part, so clone effects skip it) that only collides while ragdolled, in GROUP.ragdoll (hits the world,
-- never characters).
-- Owner client: Physics state, controls off, camera on the head, the server's seeded tumble, knocked
-- twitches; stands back up when it ends. A knockback stops dead at its distance (stopMomentum).
-- One physics model for every ragdoll (D.RAGDOLL; user 2026-11-02): a start is ONE launch (push): the same
-- velocity on the root and every limb, the body tipping away from it, then plain physics. Knockbacks on a
-- limp body become that launch (Knockback.launch / launchVelocity), never a motor; the dash / knockback
-- motors on the root are killed when a ragdoll starts. Joint friction + a heavy core make it settle.
-- Every death is a limp corpse (corpse; BreakJointsOnDeath off).
-- Carried / gripped (KnockService): the CARRIER owns the body; its client holds the root on its
-- shoulder (or in front, gripped) with rigid one-attachment aligns, so only the body is moved and the
-- limbs dangle. The body is in GROUP.ghost meanwhile (hits nothing; the carrier's shoulder collider
-- does the walls).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")

local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")

local FIGHTER_TAG = "MidoriFighter"
local CARRIER_LINK = "MidoriCarrier" -- KnockService: ObjectValue in a carried model -> the carrier's root
local SOCKET = "MidoriRagdollSocket"
local COLLIDER = "MidoriRagdollCollider"
local HOLD = "MidoriCarryHold"
local BODY = { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }
local LIMBS = { "Head", "Left Arm", "Right Arm", "Left Leg", "Right Leg" }
local DOWN = CFrame.Angles(0, 0, -math.pi / 2) -- socket X axis along the limb (pointing down at rest)
-- Each limb hangs off the Torso at its Motor6D's pivot. upper = cone (deg), twist = +-deg. My picks.
local JOINTS: { [string]: { motor: string, rot: CFrame, upper: number, twist: number } } = {
	Head = { motor = "Neck", rot = CFrame.Angles(0, 0, math.pi / 2), upper = 40, twist = 60 },
	["Left Arm"] = { motor = "Left Shoulder", rot = DOWN, upper = 110, twist = 80 },
	["Right Arm"] = { motor = "Right Shoulder", rot = DOWN, upper = 110, twist = 80 },
	["Left Leg"] = { motor = "Left Hip", rot = DOWN, upper = 70, twist = 30 },
	["Right Leg"] = { motor = "Right Hip", rot = DOWN, upper = 70, twist = 30 },
}
local NO_BOUNCE = PhysicalProperties.new(0.7, 0.9, 0, 1, 100) -- density, friction, elasticity 0 (wins)
-- ponytail: colliders a touch smaller than their parts so neighbours don't snag at the joints; raise
-- toward 1 if limbs sink into the floor.
local COLLIDER_SCALE = 0.9
-- Gripped: held up by the head at D.GRIP.offset, so the torso (what the hold moves) hangs this far under it.
local GRIP_DROP = CFrame.new(0, -1.5, 0)

-- debris: Lib/RockModule's non-colliding rocks (its own name for the group, PlayerCollision = false).
local GROUP = { character = "MidoriCharacter", ragdoll = "MidoriRagdoll", carry = "MidoriCarry", ghost = "MidoriGhost", debris = "RockDebris" }

local tokens: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any

local Ragdoll = {}
Ragdoll.GROUP = GROUP

-- The local player's movement controls (Roblox's PlayerModule): off while our own body is ragdolled
-- or knocked, so WASD / the thumbstick can't slide the body away (user, 2026-10-24).
local controls: any = nil
local function setControls(on: boolean)
	if not controls then
		local scripts = Players.LocalPlayer:FindFirstChildOfClass("PlayerScripts")
		local module = scripts and scripts:FindFirstChild("PlayerModule")
		local ok, pm = pcall(require, module :: any)
		controls = if ok and pm then pm:GetControls() else nil
	end
	if controls then
		if on then
			controls:Enable()
		else
			controls:Disable()
		end
	end
end

local function groupReady(name: string): boolean
	local ok, yes = pcall(PhysicsService.IsCollisionGroupRegistered, PhysicsService, name)
	return ok and yes
end

local function part(model: Model, name: string): BasePart?
	local p = model:FindFirstChild(name)
	return if p and p:IsA("BasePart") then p else nil
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Server: registers the collision groups (they replicate to every client). Call once at boot.
function Ragdoll.initServer()
	for _, name in GROUP do
		if not groupReady(name) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	PhysicsService:CollisionGroupSetCollidable(GROUP.ragdoll, GROUP.character, false)
	PhysicsService:CollisionGroupSetCollidable(GROUP.carry, GROUP.character, false)
	PhysicsService:CollisionGroupSetCollidable(GROUP.carry, GROUP.ragdoll, false)
	PhysicsService:CollisionGroupSetCollidable(GROUP.carry, GROUP.carry, false)
	for _, g in { GROUP.character, GROUP.ragdoll, GROUP.carry } do
		PhysicsService:CollisionGroupSetCollidable(GROUP.debris, g, false) -- rocks never block a fighter
	end
	for _, g in PhysicsService:GetRegisteredCollisionGroups() do
		PhysicsService:CollisionGroupSetCollidable(GROUP.ghost, g.name, false) -- a carried body hits nothing
	end
end

-- Server: puts a fighter's body parts (and any added later, e.g. accessories) in the character group.
function Ragdoll.characterGroup(model: Model)
	if not groupReady(GROUP.character) then
		return -- tests / before initServer
	end
	local function set(d: Instance)
		if d:IsA("BasePart") and d.CollisionGroup == "Default" then
			d.CollisionGroup = GROUP.character
		end
	end
	for _, d in model:GetDescendants() do
		set(d)
	end
	model.DescendantAdded:Connect(set)
end

-- Server: puts every body part of `model` (colliders included) in `group` (GROUP.*).
function Ragdoll.setGroup(model: Model, group: string)
	if not groupReady(group) then
		return -- tests / before initServer
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = group
		end
	end
end

-- Server, once per body at spawn: the disabled sockets and the colliders. Not an R6 body (or rigged
-- already): nothing.
function Ragdoll.rig(model: Model)
	local torso = part(model, "Torso")
	if not torso or torso:FindFirstChild(SOCKET) then
		return
	end
	for name, j in JOINTS do
		local limb = part(model, name)
		local motor = torso:FindFirstChild(j.motor)
		if not (limb and motor and motor:IsA("Motor6D")) then
			continue
		end
		local a0 = Instance.new("Attachment")
		a0.Name = SOCKET
		a0.CFrame = CFrame.new(motor.C0.Position) * j.rot
		a0.Parent = torso
		local a1 = Instance.new("Attachment")
		a1.Name = SOCKET
		a1.CFrame = CFrame.new(motor.C1.Position) * j.rot
		a1.Parent = limb
		local c = Instance.new("BallSocketConstraint")
		c.Name = SOCKET
		c.Attachment0 = a0
		c.Attachment1 = a1
		c.LimitsEnabled = true
		c.UpperAngle = j.upper
		c.TwistLimitsEnabled = true
		c.TwistLowerAngle = -j.twist
		c.TwistUpperAngle = j.twist
		-- Joint friction (D.RAGDOLL.jointFriction): limbs settle instead of flopping forever.
		local F = D.RAGDOLL.jointFriction
		c.MaxFrictionTorque = if name == "Head" then F.Head elseif string.find(name, "Arm") then F.Arm else F.Leg
		c.Enabled = false
		c.Parent = torso
	end
	local ready = groupReady(GROUP.ragdoll)
	for _, name in BODY do
		local p = part(model, name)
		if not p then
			continue
		end
		local c = Instance.new("Part")
		c.Name = COLLIDER
		c.Size = p.Size * COLLIDER_SCALE
		c.Transparency = 1
		c.CastShadow = false
		c.CanCollide, c.CanQuery, c.CanTouch, c.Massless = false, false, false, true
		-- Weight only while limp (setLimp): a heavy core leads, light limbs follow (D.RAGDOLL.density).
		local W = D.RAGDOLL.density
		local density = if name == "Torso" then W.Torso elseif name == "Head" then W.Head else W.Limb
		c.CustomPhysicalProperties = PhysicalProperties.new(density, NO_BOUNCE.Friction, NO_BOUNCE.Elasticity, NO_BOUNCE.FrictionWeight, NO_BOUNCE.ElasticityWeight)
		if ready then
			c.CollisionGroup = GROUP.ragdoll -- before parenting, so characterGroup leaves it alone
		end
		c.CFrame = p.CFrame
		local w = Instance.new("Weld")
		w.Part0 = p
		w.Part1 = c
		w.Parent = c
		c.Parent = p
	end
end

-- Motors off + sockets and colliders on (`on`), or back. The server's change replicates; the owner
-- also makes it locally so its own body reacts this frame.
local function setLimp(model: Model, on: boolean)
	local torso = part(model, "Torso")
	if not torso then
		return
	end
	for _, j in JOINTS do
		local m = torso:FindFirstChild(j.motor)
		if m and m:IsA("Motor6D") then
			m.Enabled = not on
		end
	end
	for _, c in torso:GetChildren() do
		if c:IsA("BallSocketConstraint") and c.Name == SOCKET then
			c.Enabled = on
		end
	end
	for _, name in BODY do
		local p = part(model, name)
		local c = p and p:FindFirstChild(COLLIDER)
		if c and c:IsA("BasePart") then
			c.CanCollide = on
			c.Massless = not on -- standing: no extra weight on the walking / dashing body
		end
	end
	-- Facing / holding constraints on the root (a dummy's facing align, a rush's straight-line hold) would
	-- keep a limp body bolt upright and eat its tip (bug, 2026-11-02: dummies didn't ragdoll). Off while
	-- limp, back as they were after. The carry hold (HOLD) is how a carried body is moved: left alone.
	local root = part(model, "HumanoidRootPart")
	for _, a in if root then root:GetChildren() else {} do
		if (a:IsA("AlignOrientation") or a:IsA("AlignPosition")) and a.Name ~= HOLD then
			if on and a.Enabled then
				a:SetAttribute("MidoriLimpOff", true)
				a.Enabled = false
			elseif not on and a:GetAttribute("MidoriLimpOff") then
				a:SetAttribute("MidoriLimpOff", nil)
				a.Enabled = true
			end
		end
	end
end

-- The launch for a knockback on a limp body: a ballistic arc that lands `distance` along flat `dir`.
-- Airtime = the longest of the knockback's duration, D.RAGDOLL.minAir and what `up` (studs/s) would
-- fly: a bigger `up` throws higher and longer, never further.
function Ragdoll.launchVelocity(dir: Vector3, distance: number, duration: number, up: number?): Vector3
	local g = workspace.Gravity
	local air = math.max(duration, D.RAGDOLL.minAir, 2 * (up or 0) / g)
	return flat(dir) * (distance / air) + Vector3.yAxis * (g * air / 2)
end

-- Root movers (DashMotor's dash / knockback) a limp body must never be driven by.
local MOVERS = { MidoriDash = true, MidoriDashFacing = true }

-- One ragdoll launch, run by whoever simulates the body (the owner client; the server for dummies and
-- corpses). `vel` = the launch (nil: keep the momentum the root has, e.g. tripping mid-dash), given to
-- the root and EVERY limb so nothing lags. The body tips away from the flat part of it, plus a seeded
-- random wobble from `spin` (a move's knockback.spin) - the same on every screen.
function Ragdoll.push(model: Model, vel: Vector3?, spin: number?, seed: number?)
	local root, torso = part(model, "HumanoidRootPart"), part(model, "Torso")
	if not root or not torso then
		return
	end
	for _, d in root:GetChildren() do
		if MOVERS[d.Name] then
			d:Destroy()
		end
	end
	local v = vel or root.AssemblyLinearVelocity
	for _, name in { "HumanoidRootPart", table.unpack(BODY) } do
		local p = part(model, name)
		if p and not p.Anchored then
			p.AssemblyLinearVelocity = v
			p.AssemblyAngularVelocity = Vector3.zero
		end
	end
	local R = D.RAGDOLL
	local push = flat(v)
	local omega = Vector3.zero
	if push.Magnitude > 1e-3 then
		-- d(up)/dt = omega x up = push direction: the top of the body goes the way it's pushed.
		omega = Vector3.yAxis:Cross(push.Unit) * math.min(push.Magnitude * R.tip, R.tipMax)
	end
	if spin and spin > 0 then
		local rng = Random.new(seed or 0)
		local axis = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
		if axis.Magnitude > 1e-3 then
			omega += axis.Unit * spin * R.wobble
		end
	end
	torso.AssemblyAngularVelocity = omega
end

-- Kills the body's sliding and spinning (gravity stays): a knockback ends exactly at its distance.
-- Every part, not just the root: the limbs are their own assemblies while limp.
function Ragdoll.stopMomentum(model: Model)
	for _, name in { "HumanoidRootPart", table.unpack(BODY) } do
		local p = part(model, name)
		if p and not p.Anchored then
			p.AssemblyLinearVelocity = Vector3.new(0, p.AssemblyLinearVelocity.Y, 0)
			p.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

-- Stands the body up where its torso lies, facing the way the torso points (its head's way if it
-- lies face up / down). The owner calls it as the ragdoll ends; the Humanoid fixes the height.
function Ragdoll.standUp(model: Model)
	local root, torso = part(model, "HumanoidRootPart"), part(model, "Torso")
	if not (root and torso) then
		return
	end
	local face = flat(torso.CFrame.LookVector)
	if face.Magnitude < 0.2 then
		face = flat(torso.CFrame.UpVector)
	end
	if face.Magnitude < 1e-3 then
		face = Vector3.zAxis
	end
	root.CFrame = CFrame.lookAlong(torso.Position + Vector3.yAxis * 1.5, face.Unit)
	Ragdoll.stopMomentum(model)
end

-- Server: ragdolls fighter `f` for `duration` seconds with a random tumble up to `spin` rad/s (a newer
-- call restarts the timer).
-- `launch` (Knockback.launch): the start velocity; nil keeps the body's own momentum.
function Ragdoll.apply(f: any, duration: number, spin: number?, launch: Vector3?)
	local model: Model = f.model
	local token = (tokens[model] or 0) + 1
	tokens[model] = token
	local seed = math.random(1, 2 ^ 30)
	model:SetAttribute("RagdollSpin", spin or 0)
	model:SetAttribute("RagdollLaunch", launch) -- set before Ragdolled: the owner reads it on that change
	model:SetAttribute("Ragdolled", seed)
	Ragdoll.setGroup(model, GROUP.ragdoll)
	setLimp(model, true)
	if f.player then
		-- Limp limbs are their own assemblies: keep them all on the player, who simulates the body.
		for _, name in BODY do
			local p = part(model, name)
			if p then
				pcall(p.SetNetworkOwner, p, f.player)
			end
		end
	else
		-- Server-run bodies (dummies): the server simulates EVERY part. Limp limbs are their own assemblies,
		-- and left alone Roblox hands them to a nearby player while the server runs the torso (desync).
		for _, name in { "HumanoidRootPart", table.unpack(BODY) } do
			local p = part(model, name)
			if p and not p.Anchored then
				pcall(p.SetNetworkOwner, p, nil)
			end
		end
		f.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
		Ragdoll.push(model, launch, spin, seed)
	end
	task.delay(duration, function()
		if tokens[model] == token and model.Parent then
			Ragdoll.stop(f)
		end
	end)
end

-- Server: keeps an already-limp body limp for `duration` from now (a newer apply / stop still wins),
-- without a new launch: its flight goes on untouched (e.g. knocked mid ragdoll-hit).
function Ragdoll.hold(f: any, duration: number)
	local model: Model = f.model
	if model:GetAttribute("Ragdolled") == nil then
		Ragdoll.apply(f, duration)
		return
	end
	local token = (tokens[model] or 0) + 1
	tokens[model] = token
	task.delay(duration, function()
		if tokens[model] == token and model.Parent then
			Ragdoll.stop(f)
		end
	end)
end

-- Server: a body about to be killed stays a limp ragdoll as a corpse (bug, 2026-11-02: a grip kill left
-- the body "stiff as a board"). Roblox's death joint-break is off for it (it also broke the colliders'
-- welds), the motors stay off / sockets + colliders on, the server simulates every part, and the
-- Humanoid stops holding the body up. Call BEFORE setting Health to 0.
function Ragdoll.corpse(f: any)
	local model: Model = f.model
	f.humanoid.BreakJointsOnDeath = false
	tokens[model] = (tokens[model] or 0) + 1 -- no pending Ragdoll.stop stands it back up
	Ragdoll.setGroup(model, GROUP.ragdoll)
	setLimp(model, true)
	for _, name in { "HumanoidRootPart", table.unpack(BODY) } do
		local p = part(model, name)
		if p and not p.Anchored then
			pcall(p.SetNetworkOwner, p, nil)
		end
	end
	if f.humanoid.Health > 0 then
		f.humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	end
end

-- Server: ends `f`'s ragdoll now (cancels apply's timer), e.g. getting up from a knock.
function Ragdoll.stop(f: any)
	local model: Model = f.model
	tokens[model] = (tokens[model] or 0) + 1
	if model:GetAttribute("Ragdolled") ~= nil then
		f.gotUpAt = workspace:GetServerTimeNow() -- the anti-heal resist window (HealthSystem.damage)
	end
	model:SetAttribute("Ragdolled", nil)
	setLimp(model, false)
	Ragdoll.setGroup(model, GROUP.character)
	if not f.player and f.humanoid.Health > 0 then
		Ragdoll.standUp(model)
		f.humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
	end
end

-- Client, our own body: limp until the server ends it. Returns the undo.
local function ownerRagdoll(model: Model, seed: number, spin: number, launch: Vector3?): () -> ()
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root, head = part(model, "HumanoidRootPart"), part(model, "Head")
	if not (humanoid and root) then
		return function() end
	end
	setLimp(model, true)
	local rootCollide = root.CanCollide
	root.CanCollide = false -- rides inside the torso; the colliders hold the body up
	humanoid:ChangeState(Enum.HumanoidStateType.Physics)
	setControls(false)
	if head then
		workspace.CurrentCamera.CameraSubject = head
	end
	Ragdoll.push(model, launch, spin, seed)

	-- Knocked: now and then a limb twitches (a small spin kick; real physics, so everyone sees it).
	local B = D.KNOCKED.bob
	local rng = Random.new(seed)
	local nextTwitch = os.clock() + rng:NextNumber(B.twitchEvery.Min, B.twitchEvery.Max)
	local conn = RunService.Heartbeat:Connect(function()
		if os.clock() < nextTwitch then
			return
		end
		nextTwitch = os.clock() + rng:NextNumber(B.twitchEvery.Min, B.twitchEvery.Max)
		if model:GetAttribute("Knocked") ~= true or model:GetAttribute("Carried") or model:GetAttribute("Gripped") then
			return
		end
		local limb = part(model, LIMBS[rng:NextInteger(1, #LIMBS)])
		if limb then
			local axis = if rng:NextNumber() < 0.5 then limb.CFrame.RightVector else limb.CFrame.LookVector
			limb.AssemblyAngularVelocity += axis * (2 * B.twitch / B.twitchTime)
		end
	end)

	return function()
		conn:Disconnect()
		if not model.Parent then
			return
		end
		setLimp(model, false)
		root.CanCollide = rootCollide
		Ragdoll.standUp(model)
		if model == Players.LocalPlayer.Character then -- (not after a respawn: that body is gone)
			setControls(true)
			workspace.CurrentCamera.CameraSubject = humanoid
			if humanoid.Health > 0 then
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end
			-- TEMP RAGDOLLDEBUG (user, 2026-11-03: "unragdolling sometimes still leaves you on the floor").
			-- Still down 0.5s after getting up and not ragdolled again: log why, then stand up once more.
			task.delay(0.5, function()
				local torso = part(model, "Torso")
				local st = humanoid:GetState()
				local tilted = torso ~= nil and torso.CFrame.UpVector.Y < 0.7
				local stuck = st == Enum.HumanoidStateType.Physics or st == Enum.HumanoidStateType.FallingDown
					or st == Enum.HumanoidStateType.Ragdoll or tilted
				if not stuck or model:GetAttribute("Ragdolled") ~= nil or humanoid.Health <= 0 or not model.Parent then
					return
				end
				local motors = {}
				for _, j in JOINTS do
					local m = torso and torso:FindFirstChild(j.motor)
					table.insert(motors, `{j.motor}={if m and m:IsA("Motor6D") then tostring(m.Enabled) else "missing"}`)
				end
				local sockets = 0
				for _, c in if torso then torso:GetChildren() else {} do
					if c:IsA("BallSocketConstraint") and c.Name == SOCKET and c.Enabled then
						sockets += 1
					end
				end
				warn("[RAGDOLLDEBUG] still down after getting up:", "state =", st.Name, "torsoUpY =",
					torso and string.format("%.2f", torso.CFrame.UpVector.Y), "motors:", table.concat(motors, " "),
					"socketsOn =", sockets, "rootCollide =", root.CanCollide, "rootAnchored =", root.Anchored,
					"Knocked =", model:GetAttribute("Knocked"), "Carried =", model:GetAttribute("Carried"),
					"Gripped =", model:GetAttribute("Gripped"), "MState =", model:GetAttribute("MState"),
					"group =", root.CollisionGroup, "vel =", root.AssemblyLinearVelocity)
				setLimp(model, false)
				Ragdoll.standUp(model)
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
			end)
		end
	end
end

-- Client: our own body's ragdoll, and holding the bodies we carry / grip.
function Ragdoll.initClient()
	local undo: (() -> ())? = nil
	local function track(character: Model)
		local lastSeed: number? = nil
		local function update()
			local seed = character:GetAttribute("Ragdolled")
			if typeof(seed) == "number" then
				local spin = character:GetAttribute("RagdollSpin")
				local launch = character:GetAttribute("RagdollLaunch")
				spin = if typeof(spin) == "number" then spin else 0
				launch = if typeof(launch) == "Vector3" then launch else nil
				if not undo then
					undo = ownerRagdoll(character, seed, spin, launch)
				elseif seed ~= lastSeed then
					Ragdoll.push(character, launch, spin, seed) -- ragdolled again while limp: a fresh launch
				end
				lastSeed = seed
			elseif undo then
				lastSeed = nil
				local u = undo
				undo = nil
				u()
			end
		end
		character:GetAttributeChangedSignal("Ragdolled"):Connect(update)
		update()
	end
	Players.LocalPlayer.CharacterAdded:Connect(function(character)
		undo = nil -- the old body's ragdoll died with it
		setControls(true) -- died while ragdolled / knocked: that body never got up
		track(character)
	end)
	if Players.LocalPlayer.Character then
		track(Players.LocalPlayer.Character)
	end

	-- Carrying / gripping (KnockService gave us the body): rigid one-attachment aligns hold its root
	-- at the offset from ours every frame. One-attachment: only the body is pushed, never us.
	local holds: { [Model]: { AlignPosition | AlignOrientation } } = {}
	RunService.PreSimulation:Connect(function()
		local me = Players.LocalPlayer.Character
		local myRoot = me and part(me, "HumanoidRootPart")
		for model, h in holds do
			local link = model:FindFirstChild(CARRIER_LINK)
			if not (myRoot and model.Parent and link and link:IsA("ObjectValue") and link.Value == myRoot) then
				for _, a in h do
					a:Destroy()
				end
				holds[model] = nil
			end
		end
		if not myRoot then
			return
		end
		for _, model in CollectionService:GetTagged(FIGHTER_TAG) do
			local link = model:FindFirstChild(CARRIER_LINK)
			local root = part(model, "HumanoidRootPart")
			if not (root and link and link:IsA("ObjectValue") and link.Value == myRoot) then
				continue
			end
			local h = holds[model]
			if not h then
				local att = root:FindFirstChild("RootAttachment") :: Attachment?
				if not att then
					local a = Instance.new("Attachment")
					a.Name = "RootAttachment"
					a.Parent = root
					att = a
				end
				local pos = Instance.new("AlignPosition")
				pos.Name = HOLD
				pos.Mode = Enum.PositionAlignmentMode.OneAttachment
				pos.Attachment0 = att
				pos.RigidityEnabled = true
				pos.Parent = root
				local rot = Instance.new("AlignOrientation")
				rot.Name = HOLD
				rot.Mode = Enum.OrientationAlignmentMode.OneAttachment
				rot.Attachment0 = att
				rot.RigidityEnabled = true
				rot.Parent = root
				h = { pos, rot }
				holds[model] = h
			end
			local offset = link:GetAttribute("Offset") -- a grip holds in front (KnockService)
			local target = myRoot.CFrame * (if typeof(offset) == "CFrame" then offset * GRIP_DROP else D.CARRY.offset * D.CARRY.torsoRot)
			local hold = h :: { any }
			hold[1].Position = target.Position
			hold[2].CFrame = target.Rotation
		end
	end)
end

return Ragdoll
