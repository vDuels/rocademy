--!strict
-- Model -> Fighter. Keyed by model (not player) so dummies and NPCs share the pipeline.
-- A fighter is dropped on death and a fresh one is made for the next character.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Enums = Paths.shared("Enums")
local Fighter = Paths.server("Fighter")
local PerkService = Paths.server("PerkService")

local byModel: { [Model]: any } = {}
local byPlayer: { [Player]: any } = {}

local FighterRegistry = {}

function FighterRegistry.add(model: Model, player: Player?, style: any, now: number): any
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	assert(humanoid and root and root:IsA("BasePart"), `{model:GetFullName()} needs a Humanoid and HumanoidRootPart`)

	local f = Fighter.new(model, humanoid, root, player, style, now)
	PerkService.attach(f)
	byModel[model] = f
	if player then
		byPlayer[player] = f
	end

	humanoid.Died:Connect(function()
		-- Every death: a limp corpse, thrown with whatever momentum it had (D.RAGDOLL; user 2026-11-02).
		local ok, err = pcall(Paths.shared("Ragdoll").corpse, f)
		if not ok then
			warn("[FighterRegistry] corpse", model.Name, err)
		end
		if byModel[model] == f then
			Fighter.setState(f, Enums.State.Dead, nil, workspace:GetServerTimeNow())
			FighterRegistry.remove(model)
		end
	end)
	model.Destroying:Connect(function()
		if byModel[model] == f then
			FighterRegistry.remove(model)
		end
	end)
	return f
end

function FighterRegistry.remove(model: Model)
	local f = byModel[model]
	if not f then
		return
	end
	byModel[model] = nil
	if f.player and byPlayer[f.player] == f then
		byPlayer[f.player] = nil
	end
end

function FighterRegistry.get(model: Model): any?
	return byModel[model]
end

function FighterRegistry.getByPlayer(player: Player): any?
	return byPlayer[player]
end

function FighterRegistry.all(): { [Model]: any }
	return byModel
end

function FighterRegistry.models(except: Model?): { Model }
	local list = {}
	for model in byModel do
		if model ~= except then
			table.insert(list, model)
		end
	end
	return list
end

-- `styleFor` picks each new character's style (StyleService.styleFor).
function FighterRegistry.trackPlayers(styleFor: (Player) -> any)
	local function onCharacter(player: Player, character: Model)
		character:WaitForChild("Humanoid", 10)
		character:WaitForChild("HumanoidRootPart", 10)
		if character.Parent == nil or player.Character ~= character then
			return
		end
		FighterRegistry.add(character, player, styleFor(player), workspace:GetServerTimeNow())
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local f = byPlayer[player]
		if f then
			FighterRegistry.remove(f.model)
		end
	end)
end

return FighterRegistry
