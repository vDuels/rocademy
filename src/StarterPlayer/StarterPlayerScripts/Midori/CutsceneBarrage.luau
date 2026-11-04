--!strict
-- Barrage dressing for cutscenes (Data/Cutscenes `barrages`; user 2026-10-24, Prodigy's crit), so it
-- looks like far more punches are landing than the body throws:
--   * arm clones with trails flying past the victim (the Firecracker fists, FeedbackController.fist);
--   * see-through copies of the attacker standing beside them, punching the same swings;
--   * the attacker's left arm faded while it lasts.
-- Local on every screen; nothing replicates.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local ArmClone = Paths.client("ArmClone")
local CutscenePuppet = Paths.client("CutscenePuppet")
local FeedbackController = Paths.client("FeedbackController")

local TRAIL = {
	lifetime = 0.14,
	color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(140, 200, 255)),
	transparency = NumberSequence.new(0.35, 1),
}

local CutsceneBarrage = {}

local function animation(path: string): Animation?
	local node: Instance? = Paths.Assets:FindFirstChild("Animations")
	for part in string.gmatch(path, "[^/]+") do
		node = node and node:FindFirstChild(part)
	end
	return if node and node:IsA("Animation") then node else nil
end

-- An arm template (sized like the Firecracker fists) with a ribbon trailing off the fist.
local function fistTemplate(model: Model, limb: string): Model?
	local tpl = ArmClone.template(model, limb)
	local arm = tpl and tpl.PrimaryPart
	if not (tpl and arm) then
		return nil
	end
	arm.Size *= D.BARRAGE_FIST.scale
	local half = arm.Size / 2
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(-half.X, -half.Y, 0) -- across the fist end (-Y is the hand)
	a0.Parent = arm
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(half.X, -half.Y, 0)
	a1.Parent = arm
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = TRAIL.lifetime
	trail.Color = TRAIL.color
	trail.Transparency = TRAIL.transparency
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.Parent = arm
	return tpl
end

-- Plays barrage `b` from server time `startAt` (the cutscene's start). `attacker()` = the body this
-- screen shows for the attacker (its puppet, or the real one).
function CutsceneBarrage.play(b: any, startAt: number, attacker: () -> Model?)
	local begin = startAt + b.t
	task.delay(math.max(0, begin - workspace:GetServerTimeNow()), function()
		local model = attacker()
		local root = model and model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not (model and root) then
			return
		end
		-- The faded left arm.
		local leftArm = model:FindFirstChild("Left Arm") :: BasePart?
		local leftWas = leftArm and leftArm.LocalTransparencyModifier
		if leftArm then
			leftArm.LocalTransparencyModifier = math.max(leftArm.LocalTransparencyModifier, b.leftArm)
		end
		-- The see-through copies, punching each swing with the attacker.
		local copies: { { p: any, offset: CFrame, tracks: { [string]: AnimationTrack }, animator: Animator? } } = {}
		for _, offset in b.copies do
			local ok, p = pcall(CutscenePuppet.new, model)
			if not ok then
				continue
			end
			for _, d in p.model:GetDescendants() do
				if (d:IsA("BasePart") and d.Name ~= "HumanoidRootPart") or d:IsA("Decal") then
					(d :: any).Transparency = math.max((d :: any).Transparency, b.copyTransparency)
				end
			end
			p.show(true) -- alongside the attacker, not instead of them
			p.setCFrame(root.CFrame * offset)
			local humanoid = p.model:FindFirstChildOfClass("Humanoid")
			table.insert(copies, { p = p, offset = offset, tracks = {}, animator = humanoid and humanoid:FindFirstChildOfClass("Animator") })
		end
		local follow = RunService.RenderStepped:Connect(function()
			for _, c in copies do
				c.p.setCFrame(root.CFrame * c.offset)
			end
		end)
		local timers: { thread } = {}
		for _, swing in b.swings do
			table.insert(timers, task.delay(math.max(0, startAt + swing.t - workspace:GetServerTimeNow()), function()
				for _, c in copies do
					local track = c.tracks[swing.anim]
					if not track and c.animator then
						local anim = animation(swing.anim)
						if anim then
							track = c.animator:LoadAnimation(anim)
							track.Priority = Enum.AnimationPriority.Action4
							c.tracks[swing.anim] = track
						end
					end
					if track then
						for _, other in c.tracks do
							if other ~= track and other.IsPlaying then
								other:Stop(0.05)
							end
						end
						if track.IsPlaying then
							track:Stop(0)
						end
						track:Play(0.05, 1, b.speed)
					end
				end
			end))
		end
		-- The fists, spread evenly over the barrage, alternating right / left.
		local arms = { fistTemplate(model, "Right Arm"), fistTemplate(model, "Left Arm") }
		local thrown = 0
		local fists = RunService.RenderStepped:Connect(function()
			local due = math.min(b.fists, math.floor((workspace:GetServerTimeNow() - begin) / (b.duration / b.fists)) + 1)
			while thrown < due and root.Parent do
				thrown += 1
				local tpl = arms[(thrown - 1) % 2 + 1]
				if tpl then
					FeedbackController.fist(tpl, root)
				end
			end
		end)
		task.delay(b.duration, function()
			fists:Disconnect()
			follow:Disconnect()
			for _, thread in timers do
				pcall(task.cancel, thread)
			end
			for _, c in copies do
				c.p.destroy()
			end
			for _, tpl in arms do
				if tpl then
					tpl:Destroy()
				end
			end
			if leftArm and leftWas and leftArm.Parent then
				leftArm.LocalTransparencyModifier = leftWas
			end
		end)
	end)
end

return CutsceneBarrage
