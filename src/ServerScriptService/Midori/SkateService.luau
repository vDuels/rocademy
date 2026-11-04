--!strict
-- Skateboard, server half (user, 2026-10-18). The rider's client runs the movement on its own
-- character (SkateController); the server only says who is riding: the "Skating" character
-- attribute + a board welded under the feet, so everyone sees it. Off in combat mode, or dead.
-- Board = a clone of Assets.Models.Skateboard (a Model with a PrimaryPart, or a BasePart) when it
-- exists, else a placeholder plank.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Net = Paths.shared("Net")
local D = Paths.data("Defaults")
local RateLimit = Paths.server("RateLimit")

local BOARD = "MidoriSkateboard"
local UNDER_ROOT = 3.15 -- R6: root centre to the soles (1 + 2 leg) + half the deck

local SkateService = {}

local function makeBoard(): BasePart
	local template = Paths.Assets:FindFirstChild("Models") and Paths.Assets.Models:FindFirstChild("Skateboard")
	local inst: Instance
	if template then
		inst = template:Clone()
	else
		local p = Instance.new("Part")
		p.Size = Vector3.new(1.5, 0.25, 4.4)
		p.Color = Color3.fromRGB(30, 28, 36)
		p.Material = Enum.Material.SmoothPlastic
		inst = p
	end
	local main = if inst:IsA("Model") then inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true) else inst
	assert(main and main:IsA("BasePart"), "Assets.Models.Skateboard needs a part")
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored, d.CanCollide, d.CanQuery, d.CanTouch, d.Massless = false, false, false, false, true
		end
	end
	if inst:IsA("BasePart") then
		inst.Anchored, inst.CanCollide, inst.CanQuery, inst.CanTouch, inst.Massless = false, false, false, false, true
	end
	inst.Name = BOARD
	return main :: BasePart
end

local function set(character: Model, on: boolean)
	local old = character:FindFirstChild(BOARD)
	if old then
		old:Destroy()
	end
	character:SetAttribute("Skating", if on then true else nil)
	-- On the torso, so it leans with the body on slopes (SkateController tilts the RootJoint).
	local root = (character:FindFirstChild("Torso") or character:FindFirstChild("HumanoidRootPart")) :: BasePart?
	if not on or not root then
		return
	end
	local main = makeBoard()
	local top = main:FindFirstAncestorOfClass("Model") or main
	if top:IsA("Model") then
		top:PivotTo(root.CFrame * CFrame.new(0, -UNDER_ROOT, 0))
	else
		main.CFrame = root.CFrame * CFrame.new(0, -UNDER_ROOT, 0)
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1 = root, main
	weld.Parent = main
	top.Parent = character
end

function SkateService.init()
	local function onCharacter(character: Model)
		character:GetAttributeChangedSignal("CombatMode"):Connect(function()
			if character:GetAttribute("CombatMode") and character:GetAttribute("Skating") then
				set(character, false)
			end
		end)
		local humanoid = character:WaitForChild("Humanoid") :: Humanoid
		humanoid.Died:Connect(function()
			set(character, false)
		end)
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(onCharacter)
		if player.Character then
			onCharacter(player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end

	Net.get(Net.Names.Skate).OnServerEvent:Connect(function(player, on)
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if typeof(on) ~= "boolean" or not character or not humanoid or not RateLimit.take(player, "Skate") then
			return
		end
		if on and (not D.SKATE.enabled or humanoid.Health <= 0 or character:GetAttribute("CombatMode")) then
			on = false -- refused: the client sees "Skating" stay off and gets off its board
		end
		if on ~= (character:GetAttribute("Skating") == true) then
			set(character, on)
		end
	end)
end

return SkateService
