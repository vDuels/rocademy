--!strict
-- Titles for nametags. Give or remove a title from any server script:
--   local NametagService = require(game.ServerScriptService.NametagService)
--   NametagService.SetTitle(player, "Developer")  -- Contributor / Developer / Helper / Staff / Tester
--   NametagService.SetTitle(player, nil)          -- remove
-- Everyone's default title comes from their role (ServerScriptService.Midori.RoleService, Data/Roles).
-- How each title looks lives in ReplicatedStorage.Midori.Data.Titles; the nametag itself
-- is drawn on each client by StarterPlayerScripts.Midori.NametagController (Text+).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Titles = Paths.data("Titles")

-- Where default titles come from (RoleService sets it in init: the player's role's title).
local defaultTitle: (Player) -> string? = function()
	return nil
end

local NametagService = {}

-- The title replicates to every client through the player's "Title" attribute.
function NametagService.SetTitle(player: Player, titleId: string?)
	if titleId ~= nil and Titles[titleId] == nil then
		warn(`[NametagService] Unknown title "{titleId}"`)
		return
	end
	player:SetAttribute("Title", titleId)
end

function NametagService.GetTitle(player: Player): string?
	local title = player:GetAttribute("Title")
	return if type(title) == "string" then title else nil
end

-- Their role's title (nil if none). A title set from the Dev panel is saved and overrides this.
function NametagService.default(player: Player): string?
	return defaultTitle(player)
end

function NametagService.setDefault(fn: (Player) -> string?)
	defaultTitle = fn
end

function NametagService.init()
	local function onCharacter(character: Model)
		-- Hide Roblox's built-in name; the custom nametag replaces it.
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	local function onPlayer(player: Player)
		-- The title itself is set by RoleService (role) / RerollService (Dev-panel override).
		player.CharacterAdded:Connect(onCharacter)
		if player.Character then
			task.spawn(onCharacter, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return NametagService
