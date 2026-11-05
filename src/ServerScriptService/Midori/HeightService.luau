--!strict
-- Height (D.HEIGHT, user 2026-11-02): owner-set only (RerollService DevSet "Height"), saved as data.Height.
-- Replicates as the Player's and character's "Height" attribute; Shared/Height turns it into combat stats.
-- The body: torso, limbs and root scale (the model and head don't), max HP follows.
-- A player can switch their set height off (Settings "UseHeight"); a style with `height` overrides both.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Height = Paths.shared("Height")
local MoveSchema = Paths.shared("MoveSchema")

local HeightService = {}

-- Length only (user, 2026-11-02): parts stretch along Y, thickness (X / Z) stays.
local function stretch(k: number): Vector3
	return Vector3.new(1, k, 1)
end

local function scalePos(cf: CFrame, k: number): CFrame
	return CFrame.new(cf.Position * stretch(k)) * cf.Rotation
end

-- Lengths only: Y stretches, X / Z don't.
-- Rescales from whatever scale the body has now ("HeightScale"), so calling it again is safe.
-- Every BasePart directly in the model except the Head (R6: Torso, arms, legs, root) plus the parts
-- welded inside them (ragdoll colliders); their attachments (ragdoll sockets, accessory points) and
-- every joint end on them move with the surface.
function HeightService.scaleBody(model: Model, h: number)
	local prev = model:GetAttribute("HeightScale")
	local k = h / (if typeof(prev) == "number" then prev else 1)
	if math.abs(k - 1) < 1e-4 then
		return
	end
	local scaled: { [Instance]: boolean } = {}
	for _, p in model:GetChildren() do
		if p:IsA("BasePart") and p.Name ~= "Head" then
			scaled[p] = true
			for _, c in p:GetChildren() do
				if c:IsA("BasePart") then
					scaled[c] = true
				end
			end
		end
	end
	for p in scaled do
		local part = p :: BasePart
		part.Size *= stretch(k)
		for _, a in part:GetChildren() do
			if a:IsA("Attachment") then
				a.Position *= stretch(k)
			end
		end
	end
	for _, j in model:GetDescendants() do
		if j:IsA("JointInstance") then
			if j.Part0 and scaled[j.Part0] then
				j.C0 = scalePos(j.C0, k)
			end
			if j.Part1 and scaled[j.Part1] then
				j.C1 = scalePos(j.C1, k)
			end
		end
	end
	model:SetAttribute("HeightScale", h)
end

-- Body, max HP (keeps the same share of health) and the "Height" attribute the combat code reads.
function HeightService.apply(model: Model, h: number)
	h = Height.clamp(h)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local base = model:GetAttribute("BaseMaxHealth")
	if typeof(base) ~= "number" then
		base = humanoid.MaxHealth
		model:SetAttribute("BaseMaxHealth", base)
	end
	HeightService.scaleBody(model, h)
	local share = if humanoid.MaxHealth > 0 then humanoid.Health / humanoid.MaxHealth else 1
	humanoid.MaxHealth = (base :: number) * Height.stats(h).hp
	humanoid.Health = humanoid.MaxHealth * share
	model:SetAttribute("Height", if h == 1 then nil else h)
end

-- Owner path (RerollService devSet): validates, saves into `data`, applies now. Returns the height or nil.
function HeightService.set(player: Player, data: any, value: string): number?
	local h = tonumber(value)
	if not h or h ~= h then
		return nil
	end
	h = math.round(Height.clamp(h) * 100) / 100
	data.Height = h
	player:SetAttribute("Height", h) -- refresh follows (init)
	return h
end

-- The height `character` wears (user, 2026-11-04): its style's `height` if the style sets one (no opting
-- out), else the owner-set height unless the player turned it off (Settings "UseHeight" -> "SetUseHeight").
function HeightService.effective(player: Player, character: Model): number
	local forced = MoveSchema.ofModel(character).height
	if forced then
		return forced
	end
	local h = player:GetAttribute("Height")
	return if typeof(h) == "number" and player:GetAttribute("SetUseHeight") ~= false then Height.clamp(h) else 1
end

-- Re-applies the effective height to `player`'s character if it changed.
function HeightService.refresh(player: Player)
	local character = player.Character
	if not character or not character:FindFirstChildOfClass("Humanoid") then
		return
	end
	local h = HeightService.effective(player, character)
	local now = character:GetAttribute("HeightScale")
	if h ~= (if typeof(now) == "number" then now else 1) then
		HeightService.apply(character, h)
	end
end

function HeightService.init()
	local PlayerData = Paths.server("PlayerData")
	local function onCharacter(player: Player, character: Model)
		character:GetAttributeChangedSignal("Style"):Connect(function() -- a style swap may force a height
			if player.Character == character then
				HeightService.refresh(player)
			end
		end)
		character:WaitForChild("Humanoid", 10)
		if character.Parent and player.Character == character then
			HeightService.refresh(player)
		end
	end
	PlayerData.onLoaded(function(player: Player, data: any)
		player:SetAttribute("Height", data.Height)
	end)
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		for _, attr in { "Height", "SetUseHeight" } do
			player:GetAttributeChangedSignal(attr):Connect(function()
				HeightService.refresh(player)
			end)
		end
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return HeightService
