--!strict
-- Afterimage trail (user, 2026-10-23): exact copies of a character (body parts, accessories, clothes,
-- face, at the pose they're in that instant) dropped every INTERVAL while it dashes. Each starts at
-- START transparency and fades out over FADE, tinted pastel green -> pastel blue -> pastel purple as
-- it goes. Local only. (Ghost does single solid-colour silhouettes; this is the full look.)
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
-- Copies sit exactly where the real body is: in the group that never touches characters, or the real
-- Humanoid's ground check found the copied legs under it and lifted the character (user: weird Y movement).
local NO_CHARACTERS = Paths.shared("Ragdoll").GROUP.ragdoll

local START, FADE, INTERVAL = 0.7, 0.2, 0.04
local TINTS = { Color3.fromRGB(170, 255, 200), Color3.fromRGB(170, 215, 255), Color3.fromRGB(215, 185, 255) }
local TINT_FILL = 0.55 -- the tint's own see-through at the start

local Afterimage = {}

local folder: Folder? = nil
local function container(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "MidoriAfterimages"
		f.Parent = workspace.CurrentCamera -- under the camera: drawn, but out of the physics world
		folder = f
	end
	return folder :: Folder
end

-- A frozen copy of one visible part: no joints or movers (they'd point back at the real body).
local function copyPart(p: BasePart, parent: Instance): BasePart?
	if p.Transparency >= 1 then
		return nil
	end
	local was = p.Archivable
	p.Archivable = true
	local c = p:Clone()
	p.Archivable = was
	if not c then
		return nil
	end
	for _, d in c:GetDescendants() do
		if d:IsA("JointInstance") or d:IsA("Constraint") or d:IsA("Attachment") or d:IsA("Sound")
			or d:IsA("ParticleEmitter") or d:IsA("Light") or d:IsA("LuaSourceContainer") or d:IsA("GuiBase")
			or d:IsA("BasePart") then
			d:Destroy()
		end
	end
	c.CFrame = p.CFrame
	c.Anchored = true
	c.CanCollide = false
	c.CanQuery = false
	c.CanTouch = false
	c.CastShadow = false
	c.Massless = true
	c.CollisionGroup = NO_CHARACTERS
	c.Transparency = START
	c.Parent = parent
	return c
end

-- One afterimage of `character` as it stands right now, fading (and tinting) over `fade` seconds (default FADE).
function Afterimage.snap(character: Model, fade: number?)
	local FADE = fade or FADE
	local model = Instance.new("Model")
	model.Name = "Afterimage"
	local fading: { Instance } = {}
	for _, child in character:GetChildren() do
		if child:IsA("BasePart") and child.Name ~= "HumanoidRootPart" then
			local c = copyPart(child, model)
			if c then
				table.insert(fading, c)
			end
		elseif child:IsA("Accessory") then
			local handle = child:FindFirstChild("Handle")
			local c = handle and handle:IsA("BasePart") and copyPart(handle, model)
			if c then
				table.insert(fading, c)
			end
		elseif child:IsA("Clothing") or child:IsA("ShirtGraphic") or child:IsA("BodyColors") then
			local was = child.Archivable
			child.Archivable = true
			local c = child:Clone()
			child.Archivable = was
			if c then
				c.Parent = model
			end
		end
	end
	-- Classic clothing needs a Humanoid in the model to draw; this one shows nothing else.
	local humanoid = Instance.new("Humanoid")
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	humanoid.EvaluateStateMachine = false
	humanoid.RequiresNeck = false
	humanoid.Parent = model
	for _, d in model:GetDescendants() do
		if d:IsA("Decal") then
			d.Transparency = START
			table.insert(fading, d)
		end
	end

	local tint = Instance.new("Highlight")
	tint.DepthMode = Enum.HighlightDepthMode.Occluded
	tint.OutlineTransparency = 1
	tint.FillColor = TINTS[1]
	tint.FillTransparency = TINT_FILL
	tint.Adornee = model
	tint.Parent = model
	model.Parent = container()

	local fade = TweenInfo.new(FADE, Enum.EasingStyle.Linear)
	for _, inst in fading do
		TweenService:Create(inst, fade, { Transparency = 1 }):Play()
	end
	TweenService:Create(tint, fade, { FillTransparency = 1 }):Play()
	-- Green -> blue over the first half, blue -> purple over the second.
	local half = TweenInfo.new(FADE / 2, Enum.EasingStyle.Linear)
	TweenService:Create(tint, half, { FillColor = TINTS[2] }):Play()
	task.delay(FADE / 2, function()
		if tint.Parent then
			TweenService:Create(tint, half, { FillColor = TINTS[3] }):Play()
		end
	end)
	Debris:AddItem(model, FADE + 0.05)
end

-- Rush moves with `afterimage` (Prodigy Reentry; user 2026-11-02): a trail on every fighter while it's in
-- Rush / RushMiss. Your own character follows LocalMState (CombatController's prediction, no ping wait),
-- everyone else the server's MState. Capped at TRAIL_MAX seconds in case a state sticks.
local TRAIL_MAX = 2
-- Rush trail fade (user, 2026-11-02): longer on the screens it matters to (the dasher's own and its
-- target's: FeedbackController marks the attacker "TargetingMe" locally), short for everyone watching.
local FADE_INVOLVED, FADE_OBSERVER = 0.5, 0.2
local RUSHING = { Rush = true, RushMiss = true }

local function hasAfterimageRush(model: Model): boolean
	local style = Paths.shared("MoveSchema").ofModel(model)
	for _, move in style.moves do
		if move.rush and move.afterimage then
			return true
		end
	end
	return false
end

local trailing: { [Model]: boolean } = {}
local function watchFighter(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local character = model :: Model
	local attr = if character == game:GetService("Players").LocalPlayer.Character then "LocalMState" else "MState"
	character:GetAttributeChangedSignal(attr):Connect(function()
		if trailing[character] or not RUSHING[character:GetAttribute(attr) :: any] or not hasAfterimageRush(character) then
			return
		end
		trailing[character] = true
		task.spawn(function()
			local started = os.clock()
			local involved = attr == "LocalMState" or character:GetAttribute("TargetingMe") == true
			local fade = if involved then FADE_INVOLVED else FADE_OBSERVER
			while character.Parent and RUSHING[character:GetAttribute(attr) :: any] and os.clock() - started < TRAIL_MAX do
				Afterimage.snap(character, fade)
				task.wait(INTERVAL)
			end
			trailing[character] = nil
		end)
	end)
end

function Afterimage.init()
	local CollectionService = game:GetService("CollectionService")
	for _, m in CollectionService:GetTagged("MidoriFighter") do
		watchFighter(m)
	end
	CollectionService:GetInstanceAddedSignal("MidoriFighter"):Connect(watchFighter)
end

-- Afterimages every INTERVAL for `duration` (a dash).
function Afterimage.trail(character: Model, duration: number)
	task.spawn(function()
		local t = 0
		while t < duration and character.Parent do
			Afterimage.snap(character)
			t += task.wait(INTERVAL)
		end
	end)
end

return Afterimage