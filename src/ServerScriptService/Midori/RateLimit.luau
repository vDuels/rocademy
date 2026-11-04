--!strict
-- Per-player token buckets for client remotes. Legit input never comes close to these limits.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

type Bucket = { tokens: number, last: number }

local buckets: { [Player]: { [string]: Bucket } } = {}

local RateLimit = {}

function RateLimit.take(player: Player, key: string): boolean
	local cfg = D.RATE[key]
	if not cfg then
		return true
	end
	local now = os.clock()
	local perPlayer = buckets[player]
	if not perPlayer then
		perPlayer = {}
		buckets[player] = perPlayer
	end
	local b = perPlayer[key]
	if not b then
		b = { tokens = cfg.burst, last = now }
		perPlayer[key] = b
	end
	b.tokens = math.min(cfg.burst, b.tokens + (now - b.last) * cfg.perSec)
	b.last = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

Players.PlayerRemoving:Connect(function(player)
	buckets[player] = nil
end)

return RateLimit
