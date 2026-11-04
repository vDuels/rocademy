--!strict
-- Free private servers with share codes (user, 2026-10-22). P menu SERVERS page:
--   CREATE: reserves a server (TeleportService:ReserveServer), gives it a 6-character code, saves
--     code -> { access, owner } and serverId -> code in the "MidoriServerCodes" DataStore, and sends you there.
--   JOIN(code): looks the code up and teleports you into that server (the access code never leaves the server).
--   LEAVE: back to a public server.
-- Inside a code server the workspace has attributes "ServerCode" and "ServerOwner" (UserId) for the menu.
-- Codes never expire: a reserved server's access code stays valid, and Roblox starts it again on the next join.
-- Teleports don't work in Studio (the buttons answer that). No owner powers yet (kick etc.).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Net = Paths.shared("Net")
local Fighter = Paths.server("Fighter")
local Registry = Paths.server("FighterRegistry")
local RateLimit = Paths.server("RateLimit")

local ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" -- no 0/O, 1/I
local CODE_LENGTH = 6

local PrivateServerService = {}

-- Trimmed, upper-case, and only alphabet characters of the right length; else nil.
function PrivateServerService.normalize(raw: any): string?
	if typeof(raw) ~= "string" then
		return nil
	end
	local code = string.upper((string.gsub(raw, "%s", "")))
	if #code ~= CODE_LENGTH or string.find(code, "[^" .. ALPHABET .. "]") then
		return nil
	end
	return code
end

function PrivateServerService.newCode(random: Random): string
	local chars = table.create(CODE_LENGTH)
	for i = 1, CODE_LENGTH do
		local n = random:NextInteger(1, #ALPHABET)
		chars[i] = string.sub(ALPHABET, n, n)
	end
	return table.concat(chars)
end

local rng = Random.new()
local store: DataStore? = nil
local function codes(): DataStore
	store = store or DataStoreService:GetDataStore("MidoriServerCodes")
	return store :: DataStore
end

local function inPrivate(): boolean
	return game.PrivateServerId ~= "" and game.PrivateServerOwnerId == 0
end

local function teleport(player: Player, access: string?, code: string?): (boolean, string)
	local options = Instance.new("TeleportOptions")
	if access then
		options.ReservedServerAccessCode = access
		options:SetTeleportData({ code = code })
	end
	local ok, err = pcall(TeleportService.TeleportAsync, TeleportService, game.PlaceId, { player }, options)
	if not ok then
		warn(`[PrivateServerService] teleport failed for {player.Name}: {err}`)
		return false, "TELEPORT FAILED, TRY AGAIN"
	end
	return true, "TELEPORTING..."
end

-- Out of combat (same rule as loadout changes), and not in Studio.
local function blocked(player: Player): string?
	if RunService:IsStudio() then
		return "TELEPORTS ONLY WORK IN A LIVE GAME"
	end
	local f = Registry.getByPlayer(player)
	if f and Fighter.loadoutLocked(f, workspace:GetServerTimeNow()) then
		return "LEAVE COMBAT FIRST"
	end
	return nil
end

local function create(player: Player): (boolean, string)
	local why = blocked(player)
	if why then
		return false, why
	end
	local ok, access, serverId = pcall(TeleportService.ReserveServer, TeleportService, game.PlaceId)
	if not ok then
		warn(`[PrivateServerService] ReserveServer failed: {access}`)
		return false, "COULDN'T MAKE A SERVER, TRY AGAIN"
	end
	for _ = 1, 5 do
		local code = PrivateServerService.newCode(rng)
		local claimed = false
		local saved = pcall(function()
			codes():UpdateAsync("code_" .. code, function(old)
				if old ~= nil then
					return nil -- taken: try another code
				end
				claimed = true
				return { access = access, owner = player.UserId, created = os.time() }
			end)
			if claimed then
				codes():SetAsync("ps_" .. serverId, code)
			end
		end)
		if saved and claimed then
			return teleport(player, access, code)
		end
	end
	return false, "COULDN'T SAVE THE CODE, TRY AGAIN"
end

local function join(player: Player, raw: any): (boolean, string)
	local code = PrivateServerService.normalize(raw)
	if not code then
		return false, "CODES ARE 6 LETTERS / NUMBERS"
	end
	if code == workspace:GetAttribute("ServerCode") then
		return false, "YOU'RE ALREADY HERE"
	end
	local why = blocked(player)
	if why then
		return false, why
	end
	local ok, entry = pcall(codes().GetAsync, codes(), "code_" .. code)
	if not ok then
		return false, "COULDN'T LOOK THAT UP, TRY AGAIN"
	end
	if typeof(entry) ~= "table" or typeof(entry.access) ~= "string" then
		return false, "NO SERVER WITH THAT CODE"
	end
	return teleport(player, entry.access, code)
end

local function leave(player: Player): (boolean, string)
	if not inPrivate() then
		return false, "YOU'RE ALREADY IN A PUBLIC SERVER"
	end
	local why = blocked(player)
	if why then
		return false, why
	end
	return teleport(player, nil, nil)
end

-- In a code server: find our code (saved at creation; the first arrival's teleport data as a fallback).
local function publishCode(player: Player?)
	if not inPrivate() or workspace:GetAttribute("ServerCode") then
		return
	end
	local code: string? = nil
	local ok, saved = pcall(codes().GetAsync, codes(), "ps_" .. game.PrivateServerId)
	if ok and typeof(saved) == "string" then
		code = saved
	elseif player then
		local data = player:GetJoinData().TeleportData
		code = if typeof(data) == "table" then PrivateServerService.normalize(data.code) else nil
	end
	if not code then
		return
	end
	local entryOk, entry = pcall(codes().GetAsync, codes(), "code_" .. code)
	workspace:SetAttribute("ServerCode", code)
	if entryOk and typeof(entry) == "table" then
		workspace:SetAttribute("ServerOwner", entry.owner)
	end
end

function PrivateServerService.init()
	local answer = Net.get(Net.Names.ServerResult)
	local function handle(fn: (Player, any) -> (boolean, string))
		return function(player: Player, arg: any)
			if RateLimit.take(player, "Server") then
				answer:FireClient(player, fn(player, arg))
			else
				answer:FireClient(player, false, "SLOW DOWN")
			end
		end
	end
	Net.get(Net.Names.ServerCreate).OnServerEvent:Connect(handle(create))
	Net.get(Net.Names.ServerJoin).OnServerEvent:Connect(handle(join))
	Net.get(Net.Names.ServerLeave).OnServerEvent:Connect(handle(leave))
	TeleportService.TeleportInitFailed:Connect(function(player, _result, message)
		warn(`[PrivateServerService] teleport init failed for {player.Name}: {message}`)
		answer:FireClient(player, false, "TELEPORT FAILED, TRY AGAIN")
	end)
	if inPrivate() then
		Players.PlayerAdded:Connect(publishCode)
		for _, p in Players:GetPlayers() do
			task.spawn(publishCode, p)
		end
	end
end

return PrivateServerService
