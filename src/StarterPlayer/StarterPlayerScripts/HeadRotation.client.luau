--!strict
-- Head look and camera-on-head for R6 characters.
--   Your character: the neck turns toward where the camera looks (scaled, clamped, smoothed; looking
--   behind you eases the head back to straight instead of whipping shoulder to shoulder) and the
--   camera follows your ANIMATED head (not the look turn), smoothed, with small bob ignored and a cap,
--   so attacks and reactions move the view without shaking it.
--   Other players: their head angles arrive ~10x per second over an unreliable remote and
--   are smoothed here. Neck.C0 edits never replicate, so every client applies them itself.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local HeadRotation = ReplicatedStorage:WaitForChild("HeadRotation") :: UnreliableRemoteEvent
-- Shift lock's shoulder offset rides on CameraOffset too (see SmoothShiftLock.Offset).
local ShiftLock = require(script.Parent:WaitForChild("CustomShiftLock"):WaitForChild("SmoothShiftLock")) :: any

local player = Players.LocalPlayer

type Rig = {
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	torso: BasePart,
	head: BasePart,
	neck: Motor6D,
	originalC0: CFrame,
	rootJoint: Motor6D,
	torsoY0: number, -- torso height when originalC0 was read (height system stretches it: HeightService)
	torsoY: number, -- torso height restHead was computed for
	restHead: Vector3, -- head position in root space with no animation and no head turn
	yaw: number,
	pitch: number,
	targetYaw: number,
	targetPitch: number,
	camOffset: Vector3, -- smoothed camera-on-head offset (own character)
}

local rigs: { [Model]: Rig } = {}

local function makeRig(character: Model): Rig?
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	local torso = character:WaitForChild("Torso", 10)
	local head = character:WaitForChild("Head", 10)
	local neck = torso and torso:WaitForChild("Neck", 10)
	local rootJoint = root and root:WaitForChild("RootJoint", 10)
	if
		not (humanoid and humanoid:IsA("Humanoid"))
		or not (root and root:IsA("BasePart"))
		or not (head and head:IsA("BasePart"))
		or not (neck and neck:IsA("Motor6D"))
		or not (rootJoint and rootJoint:IsA("Motor6D"))
	then
		return nil -- not an R6 rig
	end
	local originalC0 = neck.C0
	return {
		character = character,
		humanoid = humanoid,
		root = root,
		torso = torso :: BasePart,
		head = head,
		neck = neck,
		originalC0 = originalC0,
		rootJoint = rootJoint :: Motor6D,
		torsoY0 = (torso :: BasePart).Size.Y,
		torsoY = (torso :: BasePart).Size.Y,
		restHead = (rootJoint.C0 * rootJoint.C1:Inverse() * originalC0 * neck.C1:Inverse()).Position,
		yaw = 0,
		pitch = 0,
		targetYaw = 0,
		targetPitch = 0,
		camOffset = Vector3.zero,
	}
end

-- The neck's rest C0, its position following the torso's current height (owner-set height stretches
-- the torso after spawn; this script overwrites C0 every frame, so it must follow, not keep the old spot).
local function restC0(rig: Rig): CFrame
	local k = rig.torso.Size.Y / rig.torsoY0
	return CFrame.new(rig.originalC0.Position * Vector3.new(1, k, 1)) * rig.originalC0.Rotation
end

local function applyNeck(rig: Rig)
	local c0 = restC0(rig)
	if rig.torso.Size.Y ~= rig.torsoY then
		rig.torsoY = rig.torso.Size.Y
		local rj = rig.rootJoint
		rig.restHead = (rj.C0 * rj.C1:Inverse() * c0 * rig.neck.C1:Inverse()).Position
	end
	rig.neck.C0 = CFrame.new(c0.Position)
		* CFrame.Angles(0, rig.yaw, 0)
		* CFrame.Angles(rig.pitch, 0, 0)
		* rig.originalC0.Rotation
end

-- Frame-rate independent version of "move `smoothing` of the way each 60fps frame".
local function approach(current: number, target: number, dt: number): number
	local alpha = 1 - (1 - D.HEAD_SMOOTHING) ^ (dt * 60)
	return current + (target - current) * alpha
end

-- How much of the look turn the head takes at `yaw` (radians off the body's front): all of it up to
-- HEAD_BEHIND_FADE, then fading to none straight behind, so the target never jumps across your back.
local function behindFade(yaw: number): number
	local off = math.abs(yaw)
	if off <= D.HEAD_BEHIND_FADE then
		return 1
	end
	return math.clamp((math.pi - off) / (math.pi - D.HEAD_BEHIND_FADE), 0, 1)
end

-- Where the head would be with only the animation applied (no look turn), in root space. The look
-- turn swings the head around the neck; the camera shouldn't sway with it.
local function animatedHead(rig: Rig): Vector3
	local cf = rig.torso.CFrame * restC0(rig) * rig.neck.Transform * rig.neck.C1:Inverse()
	return rig.root.CFrame:PointToObjectSpace(cf.Position)
end

-- Ignore wobble under HEAD_CAMERA_DEADZONE (continuous: bigger moves just lose that much), cap at HEAD_CAMERA_MAX.
local function shapeOffset(v: Vector3): Vector3
	local m = v.Magnitude
	if m <= D.HEAD_CAMERA_DEADZONE then
		return Vector3.zero
	end
	return v.Unit * math.min(m - D.HEAD_CAMERA_DEADZONE, D.HEAD_CAMERA_MAX)
end

local function track(character: Model)
	local rig = makeRig(character)
	if rig and character.Parent then
		rigs[character] = rig
	end
end

local function untrack(character: Model)
	local rig = rigs[character]
	rigs[character] = nil
	if rig and rig.character == player.Character then
		rig.humanoid.CameraOffset = Vector3.zero
	end
end

local function watchPlayer(p: Player)
	p.CharacterAdded:Connect(track)
	p.CharacterRemoving:Connect(untrack)
	if p.Character then
		task.spawn(track, p.Character)
	end
end

for _, p in Players:GetPlayers() do
	watchPlayer(p)
end
Players.PlayerAdded:Connect(watchPlayer)

-- Angles for other players' heads (the server never echoes our own back).
HeadRotation.OnClientEvent:Connect(function(sender: Player, yaw: number, pitch: number)
	local character = sender.Character
	local rig = character and rigs[character]
	if rig then
		rig.targetYaw = yaw
		rig.targetPitch = pitch
	end
end)

local sendTimer = 0
local lastSentYaw, lastSentPitch = 0, 0

-- Just before the camera updates, so the head offset lands in this frame's camera.
RunService:BindToRenderStep("MidoriHeadLook", Enum.RenderPriority.Camera.Value - 1, function(dt: number)
	local myCharacter = player.Character
	for character, rig in rigs do
		if not character.Parent then
			rigs[character] = nil
			continue
		end
		local alive = rig.humanoid.Health > 0

		if character == myCharacter then
			local camera = workspace.CurrentCamera
			if camera and alive then
				local look = rig.root.CFrame:VectorToObjectSpace(camera.CFrame.LookVector)
				local yaw = math.atan2(-look.X, -look.Z)
				rig.targetYaw = math.clamp(yaw * D.HEAD_YAW_STRENGTH, -D.HEAD_MAX_YAW, D.HEAD_MAX_YAW) * behindFade(yaw)
				rig.targetPitch = math.clamp(math.asin(math.clamp(look.Y, -1, 1)) * D.HEAD_PITCH_STRENGTH, -D.HEAD_MAX_PITCH, D.HEAD_MAX_PITCH)
			else
				rig.targetYaw, rig.targetPitch = 0, 0
			end

			-- Camera rides the animated head: offset = how far the head is from its rest spot, plus
			-- shift lock's shoulder offset.
			-- The shoulder offset is meant in CAMERA space: CameraOffset is in the root's space, and the
			-- body turns toward the camera smoothly (lags), so convert it or the view swings as it turns.
			local shoulder = Vector3.zero
			if camera and ShiftLock.Offset ~= Vector3.zero then
				local _, yaw = camera.CFrame:ToOrientation()
				shoulder = rig.root.CFrame:VectorToObjectSpace(CFrame.Angles(0, yaw, 0):VectorToWorldSpace(ShiftLock.Offset))
			end
			local target = if alive then shapeOffset((animatedHead(rig) - rig.restHead) * D.HEAD_CAMERA_FOLLOW) else Vector3.zero
			rig.camOffset = rig.camOffset:Lerp(target, 1 - (1 - D.HEAD_CAMERA_SMOOTHING) ^ (dt * 60))
			rig.humanoid.CameraOffset = if alive then rig.camOffset + shoulder else Vector3.zero
		end

		rig.yaw = approach(rig.yaw, rig.targetYaw, dt)
		rig.pitch = approach(rig.pitch, rig.targetPitch, dt)
		applyNeck(rig)
	end

	-- Share our head angles with everyone else at a low, fixed rate, only when they change.
	local mine = myCharacter and rigs[myCharacter]
	sendTimer += dt
	if mine and sendTimer >= D.HEAD_SEND_INTERVAL then
		sendTimer = 0
		if math.abs(mine.yaw - lastSentYaw) > 0.01 or math.abs(mine.pitch - lastSentPitch) > 0.01 then
			lastSentYaw, lastSentPitch = mine.yaw, mine.pitch
			HeadRotation:FireServer(mine.yaw, mine.pitch)
		end
	end
end)
