--!strict
-- Local stand-ins for cutscene actors whose bodies this client doesn't own (user, 2026-10-23: from
-- outside, the cutscene looked off). A body's movement reaches other screens through physics
-- replication, a ping + buffer late and smoothed, while the clips play on the server clock: punches
-- before arrival, arcs cut into chords, snaps. The cutscene is scripted, so every screen can play it
-- exactly instead: an exact local copy follows CutsceneTimeline.pose and plays the clips, while the
-- real body (still moving underneath for the server) is hidden here. Nothing replicates.
--   local p = CutscenePuppet.new(real)  -- built, not shown yet
--   p.show()                             -- puppet in, real body hidden (show(true): both stay, e.g. Mirage)
--   p.setCFrame(cf)                      -- root placement (anchored; limbs animate off it)
--   p.destroy()                          -- puppet gone, real body back exactly
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local MoveSchema = Paths.shared("MoveSchema")
local NO_CHARACTERS = Paths.shared("Ragdoll").GROUP.ragdoll
local CHARACTER = Paths.shared("Ragdoll").GROUP.character
local COLLIDER = "MidoriRagdollCollider" -- Shared/Ragdoll's colliders belong in NO_CHARACTERS for good
local SWEEP_FOR = 30 -- s after the hand-back the safety net keeps waiting for the body to be free

-- Safety net (user, 2026-10-29: stayed uncollidable to other players after the Prodigy cutscene): once the
-- body isn't ragdolled / knocked / carried / gripped any more, none of it (but the ragdoll colliders) belongs
-- in NO_CHARACTERS on this screen. The restore below should already have done it; this catches what it missed.
local function sweep(real: Model)
	task.spawn(function()
		local stopAt = os.clock() + SWEEP_FOR
		while os.clock() < stopAt and real.Parent do
			task.wait(0.5)
			if not (real:GetAttribute("Ragdolled") or real:GetAttribute("Knocked") or real:GetAttribute("Carried") or real:GetAttribute("Gripped")) then
				for _, d in real:GetDescendants() do
					if d:IsA("BasePart") and d.Name ~= COLLIDER and d.CollisionGroup == NO_CHARACTERS then
						d.CollisionGroup = CHARACTER
					end
				end
				return
			end
		end
	end)
end

local DEFAULT_IDLE = "rbxassetid://180435571" -- R6 idle, for a style without its own
-- NametagController's local tag + bubble anchor (its names). A cloned tag is a dead copy: nothing rescales it
-- with distance (its UIScale stays at the clone-time value), so in a cutscene it blew up on screen (user,
-- 2026-11-02: "the victim's title and name grows insanely large"). The copy drops both; the REAL tag follows
-- the puppet's head instead (still driven by NametagController) and goes back on destroy.
local NAMETAG = "MidoriNametag"
local BUBBLE_ANCHOR = "MidoriBubbleAnchor"
-- Things on the real body that would push or steer a copy (dash motors, facing aligns, dummy aligns).
local MOVERS = { "LinearVelocity", "AlignOrientation", "AlignPosition", "VectorForce", "AngularVelocity", "BodyMover" }

local CutscenePuppet = {}

local folder: Folder? = nil
local function container(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "MidoriPuppets"
		f.Parent = workspace -- (not the camera: limbs need the physics step to take animation poses)
		folder = f
	end
	return folder :: Folder
end

local function untag(inst: Instance)
	for _, tag in CollectionService:GetTags(inst) do
		CollectionService:RemoveTag(inst, tag) -- no MidoriFighter: nothing else may treat it as a fighter
	end
end

function CutscenePuppet.new(real: Model)
	local was = real.Archivable
	real.Archivable = true
	local copy = real:Clone()
	real.Archivable = was
	assert(copy, "CutscenePuppet: could not copy " .. real:GetFullName())
	copy.Name = real.Name .. "_Puppet"
	untag(copy)
	for _, d in copy:GetDescendants() do
		untag(d)
		local mover = false
		for _, class in MOVERS do
			if d:IsA(class) then
				mover = true
				break
			end
		end
		if mover or d:IsA("LuaSourceContainer") or d:IsA("Sound") or d:IsA("ForceField") or d:IsA("Highlight")
			or d.Name == NAMETAG or d.Name == BUBBLE_ANCHOR then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = d.Name == "HumanoidRootPart"
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.CollisionGroup = NO_CHARACTERS
		end
	end
	local humanoid = copy:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = copy:FindFirstChild("HumanoidRootPart") :: BasePart
	assert(humanoid and root, "CutscenePuppet: no Humanoid / HumanoidRootPart")
	humanoid.EvaluateStateMachine = false -- no physics of its own: the root is placed every frame
	local animator = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animator.Parent = humanoid

	-- Stands in its style's idle (looped, lowest priority) under the cutscene clips, never in a bind pose.
	local idle = Instance.new("Animation")
	local styleIdle = MoveSchema.ofModel(copy).idle
	local found: Instance? = Paths.Assets:FindFirstChild("Animations")
	for part in string.gmatch(styleIdle or "", "[^/]+") do
		found = found and found:FindFirstChild(part)
	end
	idle.AnimationId = if styleIdle and found and found:IsA("Animation") and found.AnimationId ~= "" then found.AnimationId else DEFAULT_IDLE

	-- What gets hidden on the real body (and its saved state, put back on destroy).
	local hiddenLtm: { [Instance]: number } = {}
	local hiddenGui: { [Instance]: boolean } = {}
	-- The hidden real body also stops colliding with characters here: it replicates a ping late, so
	-- our own cutscene dashes bumped into it, invisible, and got shoved off their marks (victim's view).
	local savedGroup: { [BasePart]: string } = {}
	local realHumanoid = real:FindFirstChildOfClass("Humanoid")
	local realDisplay = realHumanoid and realHumanoid.DisplayDistanceType

	-- The real nametag, re-adorned to the puppet's head while shown (and its old adornee).
	local tag: BillboardGui? = nil
	local tagAdornee: Instance? = nil

	local shown, gone = false, false
	local p = { model = copy }
	-- `keepReal`: show the copy alongside the real body (a mirage) instead of standing in for it.
	function p.show(keepReal: boolean?)
		if shown or gone then
			return
		end
		shown = true
		copy.Parent = container()
		-- Parenting lets the Humanoid switch the Torso's collision back on; the camera's occlusion check
		-- would then see the puppet as a wall.
		for _, d in copy:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide = false
			end
		end
		local track = animator:LoadAnimation(idle)
		track.Priority = Enum.AnimationPriority.Idle
		track.Looped = true
		track:Play(0)
		if keepReal then
			return
		end
		for _, d in real:GetDescendants() do
			if d:IsA("BasePart") then
				savedGroup[d] = d.CollisionGroup
				d.CollisionGroup = NO_CHARACTERS
			end
			if (d:IsA("BasePart") or d:IsA("Decal")) and d.LocalTransparencyModifier < 1 then
				hiddenLtm[d] = d.LocalTransparencyModifier
				d.LocalTransparencyModifier = 1
			elseif d:IsA("BillboardGui") and d.Name == NAMETAG and copy:FindFirstChild("Head") then
				tag, tagAdornee = d, d.Adornee
				d.Adornee = copy:FindFirstChild("Head") :: BasePart
			elseif d:IsA("LayerCollector") and d.Enabled then
				hiddenGui[d] = true
				d.Enabled = false
			end
		end
		if realHumanoid then
			realHumanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	function p.setCFrame(cf: CFrame)
		root.CFrame = cf
	end
	function p.destroy()
		if gone then
			return
		end
		gone = true
		if tag and tag.Parent then
			tag.Adornee = if tagAdornee and tagAdornee.Parent then tagAdornee else tag.Parent -- (built on the head)
		end
		copy:Destroy()
		for d, v in hiddenLtm do
			if d.Parent then
				(d :: any).LocalTransparencyModifier = v
			end
		end
		for d, group in savedGroup do
			if d.Parent and d.CollisionGroup == NO_CHARACTERS then -- (the server may have set its own since)
				-- A body puppeted twice saved NO_CHARACTERS as its "original": a body part goes back to the
				-- character group then (the colliders stay where they live).
				d.CollisionGroup = if group == NO_CHARACTERS and d.Name ~= COLLIDER then CHARACTER else group
			end
		end
		if next(savedGroup) then
			sweep(real)
		end
		for d in hiddenGui do
			if d.Parent then
				(d :: any).Enabled = true
			end
		end
		if realHumanoid and realDisplay then
			realHumanoid.DisplayDistanceType = realDisplay
		end
	end
	return p
end

return CutscenePuppet