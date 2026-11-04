--!strict
-- Relays head-look angles to the other players. Purely cosmetic, so it rides an unreliable
-- remote; values are validated and clamped, and floods from one client are dropped.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local HeadRotation = ReplicatedStorage:WaitForChild("HeadRotation") :: UnreliableRemoteEvent

local MIN_INTERVAL = D.HEAD_SEND_INTERVAL * 0.5 -- legit clients send every HEAD_SEND_INTERVAL

local lastReceived: { [Player]: number } = {}

HeadRotation.OnServerEvent:Connect(function(player: Player, yaw: any, pitch: any)
	if typeof(yaw) ~= "number" or typeof(pitch) ~= "number" or yaw ~= yaw or pitch ~= pitch then
		return
	end
	local now = os.clock()
	if now - (lastReceived[player] or 0) < MIN_INTERVAL then
		return
	end
	lastReceived[player] = now

	local safeYaw = math.clamp(yaw, -D.HEAD_MAX_YAW, D.HEAD_MAX_YAW)
	local safePitch = math.clamp(pitch, -D.HEAD_MAX_PITCH, D.HEAD_MAX_PITCH)
	for _, other in Players:GetPlayers() do
		if other ~= player then
			HeadRotation:FireClient(other, player, safeYaw, safePitch)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player)
	lastReceived[player] = nil
end)
