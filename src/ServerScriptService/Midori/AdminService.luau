--!strict
-- Chat admin commands (user, 2026-10-25). Ranks come from Data/Roles' order (RoleService).
--   ,nick                    you get a random Data/Nicknames name (anyone)
--   ,nick <player>           they get a random one (Helper and up)
--   ,nick <player> <name>    they get <name>, text-filtered (Staff and up)
--   ,unick [player]          back to the DisplayName (others: Helper and up)
--   A nick given to someone else is LOCKED at the giver's rank (user, 2026-10-28): after that only someone of
--   the same rank or higher (the player themselves included) can ,nick / ,unick them. A ,unick unlocks it.
--   ,bring <player>          in front of you (Staff and up)
--   ,freeze / ,unfreeze <player>   anchor / unanchor their root (Staff and up)
--   ,apt <player>            into their apartment, "me" = yours (Staff and up; ApartmentService)
--   ,m <message>             banner to everyone in this server, text-filtered (owners only)
--   ,prompt <player> <id>    Roblox's buy prompt for dev product <id> on their screen (owners only)
--   ,soda flood              D.SODA.floodCount cans spill out in front of you (Staff and up; SodaService.flood)
--   ,hypercharge             toggles the HyperchargeVFX test aura on you (Staff and up)
-- The nick is saved (PlayerData.Nick) and shown by NametagController through the "Nick" attribute.
-- <player> = "me", or the start of a username / display name.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Roles = Paths.data("Roles")
local Nicknames = Paths.data("Nicknames")
local RoleService = Paths.server("RoleService")
local PlayerData = Paths.server("PlayerData")
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")

local MAX_NICK = 20
local MAX_ANNOUNCE = 200

local AdminService = {}

-- At least `role` (the owner, and everyone in Studio, pass everything).
local function atLeast(player: Player, role: string): boolean
	if RunService:IsStudio() or RoleService.isOwner(player) then
		return true
	end
	return (table.find(Roles.order, RoleService.role(player)) or 0) >= (table.find(Roles.order, role) or math.huge)
end

local function findPlayer(from: Player, query: string): Player?
	query = string.lower(query)
	if query == "me" then
		return from
	end
	local id = string.match(query, "^#(%d+)$") -- exact UserId (the Panel's GIVE sends this)
	if id then
		return Players:GetPlayerByUserId(tonumber(id) :: number)
	end
	for _, p in Players:GetPlayers() do
		if string.lower(p.Name) == query or string.lower(p.DisplayName) == query then
			return p
		end
	end
	for _, p in Players:GetPlayers() do
		if string.sub(string.lower(p.Name), 1, #query) == query or string.sub(string.lower(p.DisplayName), 1, #query) == query then
			return p
		end
	end
	return nil
end

-- Rank for nick locks: index in Roles.order; owners (and everyone in Studio, like atLeast) outrank all.
-- (#order + 1, not math.huge: the lock is saved and DataStore JSON can't hold infinity.)
local function rank(player: Player): number
	if RunService:IsStudio() or RoleService.isOwner(player) then
		return #Roles.order + 1
	end
	return table.find(Roles.order, RoleService.role(player)) or 0
end

-- `lockRank` = the giver's rank (0 = not locked).
local function setNick(player: Player, nick: string, lockRank: number)
	player:SetAttribute("Nick", if nick == "" then nil else nick)
	local data = PlayerData.get(player)
	if data then
		data.Nick = nick
		data.NickLockRank = lockRank
	end
end

-- Whether `by` may change `target`'s nick: unlocked, or `by` is of the locker's rank or higher.
local function canChangeNick(by: Player, target: Player): boolean
	local data = PlayerData.get(target)
	local lock = if data and typeof(data.NickLockRank) == "number" then data.NickLockRank else 0
	return lock <= 0 or rank(by) >= lock
end

-- Roblox's filter for text everyone sees; nil if it can't be checked or got tagged.
local function filtered(text: string, by: Player): string?
	local ok, result = pcall(TextService.FilterStringAsync, TextService, text, by.UserId)
	if not ok then
		return nil
	end
	local okText, clean = pcall(result.GetNonChatStringForBroadcastAsync, result)
	return if okText and clean == text then clean else nil
end

local function root(player: Player): BasePart?
	local character = player.Character
	return if character then character:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
end

local function run(player: Player, message: string)
	local command, rest = string.match(message, "^,(%a+)%s*(.-)%s*$")
	if not command then
		return
	end
	command = string.lower(command)
	if command == "m" then
		-- Owners only (everyone in Studio): a banner for everyone in this server.
		if (RunService:IsStudio() or RoleService.isOwner(player)) and rest ~= "" then
			local clean = filtered(string.sub(rest, 1, MAX_ANNOUNCE), player)
			if clean then
				Net.get(Net.Names.Announce):FireAllClients(player.DisplayName, clean)
			end
		end
		return
	end
	if command == "hypercharge" then
		-- Toggles the test aura on your own character. Visual only, no stats.
		-- The look is the editable "HyperchargeVFX" part (ServerStorage, else Workspace): a stand-in R6
		-- HumanoidRootPart whose Attachments (+ emitters) are copied onto your root at the same offsets.
		-- Each emitter is ONE big flipbook sprite: Lifetime = one loop (16 frames / FlipbookFramerate) and
		-- Rate = 1 / Lifetime, so the next particle is born as the last dies at frame 0 (keep those in step).
		-- ponytail: Rate-timed handoff can flicker a frame on hitches; client-side Emit loop if it shows.
		local mine = root(player)
		if not mine or not atLeast(player, "Staff") then
			return
		end
		local vfx = game:GetService("ServerStorage"):FindFirstChild("HyperchargeVFX") or workspace:FindFirstChild("HyperchargeVFX")
		if not vfx then
			warn(",hypercharge: no HyperchargeVFX part in ServerStorage or Workspace")
			return
		end
		local removed = false
		for _, a in vfx:GetChildren() do
			local on = a:IsA("Attachment") and mine:FindFirstChild(a.Name)
			if on then
				on:Destroy()
				removed = true
			end
		end
		if removed then
			return
		end
		for _, a in vfx:GetChildren() do
			if a:IsA("Attachment") then
				a:Clone().Parent = mine
			end
		end
		return
	end
	if command == "soda" then
		if string.lower(rest) == "flood" and atLeast(player, "Staff") then
			Paths.server("SodaService").flood(player)
		end
		return
	end
	local targetName, extra = string.match(rest, "^(%S+)%s*(.-)$")
	local target = if targetName then findPlayer(player, targetName) else player
	if not target then
		return
	end
	local other = target ~= player

	if command == "prompt" then
		-- Owners only (everyone in Studio; user, 2026-11-04): Roblox's buy prompt for dev product <id> on their
		-- screen. What buying it grants is that product's PlayerData.onProduct handler (none = just the Robux).
		local id = tonumber(extra or "")
		if (RunService:IsStudio() or RoleService.isOwner(player)) and id and id == math.floor(id) and id > 0 then
			game:GetService("MarketplaceService"):PromptProductPurchase(target, id)
		end
		return
	end
	if (command == "nick" or command == "unick") and not canChangeNick(player, target) then
		return -- locked by someone ranked above you
	end
	if command == "nick" then
		if extra ~= "" then
			if not atLeast(player, "Staff") then
				return
			end
			local nick = string.sub(string.gsub(extra, "%s+", " "), 1, MAX_NICK)
			local clean = filtered(nick, player)
			if clean then
				setNick(target, clean, if other then rank(player) else 0) -- given to someone else = locked at your rank
			end
		elseif not other or atLeast(player, "Helper") then
			setNick(target, Nicknames[math.random(#Nicknames)], if other then rank(player) else 0)
		end
	elseif command == "unick" then
		if not other or atLeast(player, "Helper") then
			setNick(target, "", 0) -- a reset also unlocks it
		end
	elseif not atLeast(player, "Staff") or not targetName then
		return
	elseif command == "bring" then
		local mine, theirs = root(player), root(target)
		if mine and theirs and other then
			target.Character:PivotTo(mine.CFrame * CFrame.new(0, 0, -4) * CFrame.Angles(0, math.pi, 0))
		end
	elseif command == "apt" then
		-- Into their apartment (or yours with "me"); leaving puts you back here.
		local mine = root(player)
		if mine then
			task.spawn(Paths.server("ApartmentService").enter, player, target.UserId, mine.CFrame, function()
				return true
			end, true) -- staff skip the lock / whitelist
		end
	elseif command == "freeze" or command == "unfreeze" then
		local theirs = root(target)
		if theirs then
			-- ponytail: KnockService unanchors roots when knocked/carried; re-freeze after if needed.
			theirs.Anchored = command == "freeze"
		end
	end
end

-- Owners (D.OWNER_IDS: UserIds, not a role; everyone in Studio) give rerolls ("Spins") or "Bux" to anyone in
-- this server from the Panel's GIVE row (user, 2026-10-27). Adds to what they have. Returns (ok, message).
local MAX_GIVE = 1e6
function AdminService.give(from: Player, who: any, kind: any, amount: any): (boolean, string)
	if not (RunService:IsStudio() or table.find(D.OWNER_IDS, from.UserId)) then
		return false, "owners only"
	end
	if kind ~= "Spins" and kind ~= "Bux" then
		return false, "bad kind"
	end
	local n = tonumber(amount)
	if not n or n ~= math.floor(n) or n < 1 or n > MAX_GIVE then
		return false, `amount: a whole number 1-{MAX_GIVE}`
	end
	local target = if typeof(who) == "string" and who ~= "" then findPlayer(from, who) else from
	if not target then
		return false, "no such player here"
	end
	local data = PlayerData.get(target)
	if not data then
		return false, "their data isn't loaded"
	end
	data[kind] += n
	target:SetAttribute(kind, data[kind])
	Paths.server("GiveLog").log(from, target, `+{n} {if kind == "Spins" then "rerolls" else "Bux"} (now {data[kind]})`)
	return true, `+{n} {if kind == "Spins" then "rerolls" else "bux"} to {target.Name}`
end

function AdminService.init()
	local giveRemote = Net.get(Net.Names.OwnerGive)
	giveRemote.OnServerEvent:Connect(function(player, who, kind, amount)
		giveRemote:FireClient(player, AdminService.give(player, who, kind, amount))
	end)
	PlayerData.onLoaded(function(player, data)
		if typeof(data.Nick) == "string" and data.Nick ~= "" then
			player:SetAttribute("Nick", data.Nick)
		end
	end)
	local function watch(player: Player)
		player.Chatted:Connect(function(message: string)
			run(player, message)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end
end

return AdminService
