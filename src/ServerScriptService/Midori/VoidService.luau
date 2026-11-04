--!strict
-- Void safety net (user, 2026-11-02: "void deaths cause soft locks"). Falling past FallenPartsDestroyHeight
-- destroys body parts instead of dealing damage; a body that was ragdolled / knocked / carried can end up
-- half gone without the Humanoid dying, or dead with no respawn. Twice a second, per player:
--   below VOID_MARGIN studs above the destroy height, or the root gone -> Health = 0 (normal death path)
--   still dead / bodyless STUCK_AFTER seconds past the respawn time -> LoadCharacter
local Players = game:GetService("Players")

local VOID_MARGIN = 50 -- studs above workspace.FallenPartsDestroyHeight (map's lowest floor is far above)
local STUCK_AFTER = 3 -- seconds past Players.RespawnTime before forcing a respawn
local INTERVAL = 0.5

local VoidService = {}

local brokenSince: { [Player]: number } = {}

-- One player's check. Returns what it did (edit-mode check): "kill", "respawn" or nil.
function VoidService.check(player: Player, now: number): string?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local alive = humanoid ~= nil and humanoid.Health > 0 and character ~= nil and character.Parent ~= nil
	if alive and (not root or not root:IsA("BasePart") or root.Position.Y < workspace.FallenPartsDestroyHeight + VOID_MARGIN) then
		(humanoid :: Humanoid).Health = 0
		alive = false
		brokenSince[player] = brokenSince[player] or now
		return "kill"
	end
	if alive or not character then
		brokenSince[player] = nil
		return nil
	end
	local since = brokenSince[player]
	if not since then
		brokenSince[player] = now
	elseif now - since > Players.RespawnTime + STUCK_AFTER then
		brokenSince[player] = nil
		player:LoadCharacter()
		return "respawn"
	end
	return nil
end

function VoidService.init()
	Players.PlayerRemoving:Connect(function(player)
		brokenSince[player] = nil
	end)
	Players.PlayerAdded:Connect(function(player)
		player.CharacterAdded:Connect(function()
			brokenSince[player] = nil
		end)
	end)
	for _, player in Players:GetPlayers() do
		player.CharacterAdded:Connect(function()
			brokenSince[player] = nil
		end)
	end
	task.spawn(function()
		while true do
			task.wait(INTERVAL)
			local now = os.clock()
			for _, player in Players:GetPlayers() do
				local ok, err = pcall(VoidService.check, player, now)
				if not ok then
					warn("[VoidService]", player.Name, err)
				end
			end
		end
	end)
end

return VoidService
