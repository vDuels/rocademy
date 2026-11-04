--!strict
-- Roles (user, 2026-10-16; the list lives in Data/Roles). The owner (D.OWNER_USER_ID) and Managers
-- give roles from the P menu's Panel (a Manager only gives roles ranked below Manager, to people who
-- don't have Manager). Saved in the "MidoriRoles" DataStore (UserId -> a list of role names; old saves
-- hold one name, still read); with nothing saved, Data/Roles.defaults, else Player.
-- SEVERAL ROLES (user, 2026-11-01): a player can hold any number. What they can do = everything any of
-- them gives (Panel, cosmetics, manage, free rerolls). role(player) = the highest one (rank checks, the
-- "Role" attribute). The nametag title = the one they pick in Settings (data.Settings.Title, if one of
-- their roles gives it), else their highest role's. The Panel's role chips ADD / REMOVE one role;
-- Player clears them all.
-- A role gives a nametag title, maybe the Panel (dev = yourself, manage = anyone) and free rerolls.
-- Everyone is a Dev in Studio.
-- Replicates as Player attributes "Role" (highest), "Roles" ("A,B"), "OwnedTitles" ("A,B": the title ids
-- their roles give, for the Settings picker), "Dev", "Manage", "Owner", "SetCosmetics" and "FreeSpins"
-- (RerollService reads it to skip charging).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Roles = Paths.data("Roles")
local Net = Paths.shared("Net")
local RateLimit = Paths.server("RateLimit")
local PlayerData = Paths.server("PlayerData")
local NametagService = require(game:GetService("ServerScriptService"):WaitForChild("NametagService"))

local okStore, store = pcall(DataStoreService.GetDataStore, DataStoreService, "MidoriRoles")
local saved: { [number]: any } = {} -- saved value (a list, or an old single name) of players in this server

local RoleService = {}

-- The owners: D.OWNER_IDS (user, 2026-10-27; UserIds, not a role). Only D.OWNER_USER_ID shows the "Owner" role.
function RoleService.isOwner(player: Player): boolean
	return table.find(D.OWNER_IDS, player.UserId) ~= nil
end

-- Unob styles (`rollable = false`: BanHammer, Dema) are given by the owners only (user, 2026-10-28).
-- An unknown name passes here; the setter rejects it anyway.
function RoleService.canGiveStyle(player: Player, name: any): boolean
	local real = if typeof(name) == "string" then Paths.findStyle(name) else nil
	return real == nil or Paths.style(real).rollable ~= false or RoleService.isOwner(player)
end

local function squash(s: string): string
	return string.lower((string.gsub(s, "%s", "")))
end

-- A settable role name (any case/spaces: "content creator", "ContentCreator"), or nil.
local function settable(name: any): string?
	if typeof(name) ~= "string" then
		return nil
	end
	local want = squash(name)
	for _, role in Roles.order do
		if squash(role) == want then
			return role
		end
	end
	return nil
end

local function rank(role: string): number
	return table.find(Roles.order, role) or math.huge -- Owner (not in the list) outranks everything
end

-- Pure: `userId`'s roles, highest first. Owner (D.OWNER_USER_ID) always has "Owner"; then the saved list
-- (or an old save's single name); nothing saved = Data/Roles.defaults; none at all = { "Player" }.
function RoleService.rolesOf(userId: number, stored: any): { string }
	local list: { string } = {}
	local function add(role: string?)
		if role and role ~= "Player" and not table.find(list, role) then
			table.insert(list, role)
		end
	end
	if userId == D.OWNER_USER_ID then
		add("Owner")
	end
	if type(stored) == "table" then
		for _, r in stored do
			add(settable(r))
		end
	elseif type(stored) == "string" then
		add(settable(stored))
	else
		add(Roles.defaults[userId])
	end
	if #list == 0 then
		return { "Player" }
	end
	table.sort(list, function(a, b)
		return rank(a) > rank(b)
	end)
	return list
end

-- Pure: the saved list after the Panel's chip for `role`: Player = none; a role they have = taken away;
-- one they don't = added. (Owner is never saved; it comes from D.OWNER_USER_ID.)
function RoleService.toggle(stored: any, userId: number, role: string): { string }
	if role == "Player" then
		return {}
	end
	local out: { string } = {}
	local had = false
	for _, r in RoleService.rolesOf(userId, stored) do
		if r == role then
			had = true
		elseif r ~= "Owner" and r ~= "Player" then
			table.insert(out, r)
		end
	end
	if not had then
		table.insert(out, role)
	end
	return out
end

function RoleService.roles(player: Player): { string }
	return RoleService.rolesOf(player.UserId, saved[player.UserId])
end

-- Their highest role.
function RoleService.role(player: Player): string
	return RoleService.roles(player)[1]
end

local function any(player: Player, field: string): boolean
	for _, r in RoleService.roles(player) do
		if (Roles.roles[r] :: any)[field] == true then
			return true
		end
	end
	return false
end

-- Can use the Panel on other people (and give roles / titles): the owner and Managers.
function RoleService.canManage(player: Player): boolean
	return RoleService.isOwner(player) or any(player, "manage")
end

-- Can set OTHER players' cosmetics from the Panel (Staff), or more (Managers / owner).
function RoleService.canSetCosmetics(player: Player): boolean
	return RoleService.canManage(player) or any(player, "cosmetics")
end

function RoleService.isDev(player: Player): boolean
	return RunService:IsStudio() or any(player, "dev")
end

-- The title ids `player`'s roles give, highest role first.
function RoleService.titles(player: Player): { string }
	local out = {}
	for _, r in RoleService.roles(player) do
		local t = Roles.roles[r].title
		if t and not table.find(out, t) then
			table.insert(out, t)
		end
	end
	return out
end

-- The nametag title: their Settings pick if one of their roles gives it, else the highest role's (nil = none).
function RoleService.title(player: Player): string?
	local owned = RoleService.titles(player)
	local data = PlayerData.get(player)
	local pick = data and typeof(data.Settings) == "table" and data.Settings.Title
	if typeof(pick) == "string" and table.find(owned, pick) then
		return pick
	end
	return owned[1]
end

-- Pushes the roles to attributes and the nametag.
local function publish(player: Player)
	local roles = RoleService.roles(player)
	player:SetAttribute("Role", roles[1])
	player:SetAttribute("Roles", table.concat(roles, ","))
	player:SetAttribute("OwnedTitles", table.concat(RoleService.titles(player), ","))
	player:SetAttribute("Owner", RoleService.isOwner(player))
	player:SetAttribute("Dev", RoleService.isDev(player))
	player:SetAttribute("Manage", RoleService.canManage(player))
	player:SetAttribute("SetCosmetics", RoleService.canSetCosmetics(player))
	-- Every role but Player rerolls free unless it says freeSpins = false (user, 2026-10-22); any one is enough.
	local free = false
	for _, r in roles do
		free = free or (r ~= "Player" and Roles.roles[r].freeSpins ~= false)
	end
	player:SetAttribute("FreeSpins", free)
	NametagService.SetTitle(player, RoleService.title(player))
end
-- After a Settings title pick (SettingsService) or the profile loading.
RoleService.refresh = publish

local function load(player: Player)
	publish(player) -- the default until the saved roles arrive
	if not okStore then
		return
	end
	local ok, stored = pcall(store.GetAsync, store, tostring(player.UserId))
	if not ok then
		warn(`[RoleService] couldn't load {player.Name}'s roles: {stored}`)
		return
	end
	if player.Parent == Players and (type(stored) == "string" or type(stored) == "table") then
		saved[player.UserId] = stored
		publish(player)
	end
end

-- A UserId (number or digits), else a username looked up on Roblox.
local function resolve(target: any): (number?, string?)
	if typeof(target) == "number" then
		return target, nil
	end
	if typeof(target) ~= "string" or #target == 0 or #target > 40 then
		return nil, "bad target"
	end
	local id = tonumber(target)
	if id then
		return id, nil
	end
	local ok, found = pcall(Players.GetUserIdFromNameAsync, Players, target)
	if ok and typeof(found) == "number" then
		return found, nil
	end
	return nil, "no such user"
end

-- What's saved for `userId` (this server's copy, else the DataStore). ok = false if the load failed.
local function storedFor(userId: number): (boolean, any)
	if saved[userId] ~= nil then
		return true, saved[userId]
	end
	if not okStore then
		return true, nil
	end
	local ok, value = pcall(store.GetAsync, store, tostring(userId))
	if not ok then
		return false, value
	end
	return true, value
end

-- The owner, or a Manager for roles below Manager: toggles one role (Player = clear all).
-- Returns (ok, message, their roles joined).
function RoleService.set(owner: Player, target: any, roleName: any): (boolean, string, string?)
	if not RoleService.canManage(owner) then
		return false, "managers only", nil
	end
	local role = settable(roleName)
	if not role then
		return false, `unknown role (try {table.concat(Roles.order, ", ")})`, nil
	end
	local boss = RoleService.isOwner(owner)
	if not boss and rank(role) >= rank("Manager") then
		return false, "only the owner gives Manager", nil
	end
	local userId, err = resolve(target)
	if not userId or userId <= 0 or userId % 1 ~= 0 then
		return false, err or "bad user id", nil
	end
	if table.find(D.OWNER_IDS, userId) and userId ~= owner.UserId then
		return false, "that's an owner", nil
	end
	if not okStore then
		return false, "no DataStore (publish the place / enable API access)", nil
	end
	local okGet, stored = storedFor(userId)
	if not okGet then
		return false, `load failed: {stored}`, nil
	end
	if not boss and rank(RoleService.rolesOf(userId, stored)[1]) >= rank("Manager") then
		return false, "only the owner changes a Manager", nil
	end
	local list = RoleService.toggle(stored, userId, role)
	local ok, setErr = pcall(store.SetAsync, store, tostring(userId), list)
	if not ok then
		return false, `save failed: {setErr}`, nil
	end
	local now = table.concat(RoleService.rolesOf(userId, list), ", ")
	local online = Players:GetPlayerByUserId(userId)
	if online then
		saved[userId] = list
		publish(online)
	end
	Paths.server("GiveLog").log(owner, online or `offline user {userId}`, `role toggle {role}, roles now: {now}`)
	return true, `{userId}: {now}` .. (if online then "" else " (offline: applies when they join)"), now
end

-- Owner / Managers: a user's current roles, for the Panel's lookup.
function RoleService.get(owner: Player, target: any): (boolean, string, string?)
	if not RoleService.canManage(owner) then
		return false, "managers only", nil
	end
	local userId, err = resolve(target)
	if not userId then
		return false, err or "bad user id", nil
	end
	local ok, stored = storedFor(userId)
	if not ok then
		return false, `load failed: {stored}`, nil
	end
	local now = table.concat(RoleService.rolesOf(userId, stored), ", ")
	return true, `{userId}: {now}`, now
end

-- Owners: everyone who has a role right now (not just Player, not an owner), online or not: every UserId
-- saved in MidoriRoles, plus Data/Roles.defaults that nothing saved overrides. Sorted highest role first.
-- Returns (ok, message, { { id, name, role (joined) } }?).
function RoleService.list(owner: Player): (boolean, string, { any }?)
	if not RoleService.isOwner(owner) then
		return false, "owners only", nil
	end
	if not okStore then
		return false, "no DataStore (publish the place / enable API access)", nil
	end
	local stored: { [number]: any } = {}
	local okList, pages = pcall(store.ListKeysAsync, store)
	if not okList then
		return false, `list failed: {pages}`, nil
	end
	while true do
		for _, key in pages:GetCurrentPage() do
			local id = tonumber(key.KeyName)
			if id then
				local okGet, value = pcall(store.GetAsync, store, key.KeyName)
				if okGet and (type(value) == "string" or type(value) == "table") then
					stored[id] = value
				end
			end
		end
		if pages.IsFinished or not pcall(pages.AdvanceToNextPageAsync, pages) then
			break
		end
	end
	local entries: { any } = {}
	local function add(id: number, value: any)
		local roles = RoleService.rolesOf(id, value)
		if roles[1] ~= "Player" and not table.find(D.OWNER_IDS, id) then
			table.insert(entries, { id = id, role = table.concat(roles, ", "), top = roles[1], name = tostring(id) })
		end
	end
	for id, value in stored do
		add(id, value)
	end
	for id in Roles.defaults do
		if stored[id] == nil then
			add(id, nil)
		end
	end
	for _, e in entries do
		local okName, name = pcall(Players.GetNameFromUserIdAsync, Players, e.id)
		if okName and typeof(name) == "string" then
			e.name = name
		end
	end
	table.sort(entries, function(a, b)
		if rank(a.top) ~= rank(b.top) then
			return rank(a.top) > rank(b.top)
		end
		return a.name:lower() < b.name:lower()
	end)
	return true, `{#entries} with a role`, entries
end

function RoleService.init()
	NametagService.setDefault(RoleService.title)
	-- The Settings title pick lives in the profile: publish again once it's loaded.
	PlayerData.onLoaded(function(player)
		publish(player)
	end)
	-- Owner role list: ("List") or ("Strip", userId) -> (ok, message, list?). Strip saves no roles for
	-- them (online or not, same as the Player chip), then sends the fresh list.
	local roleList = Net.get(Net.Names.RoleList)
	roleList.OnServerEvent:Connect(function(player, action, userId)
		if not RoleService.isOwner(player) or not RateLimit.take(player, "Reroll") then
			return
		end
		if action == "Strip" then
			local ok, message = RoleService.set(player, if typeof(userId) == "number" then userId else nil, "Player")
			if not ok then
				roleList:FireClient(player, false, message, nil)
				return
			end
		end
		roleList:FireClient(player, RoleService.list(player))
	end)
	Players.PlayerAdded:Connect(function(player)
		task.spawn(load, player)
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		saved[player.UserId] = nil
	end)

	local result = Net.get(Net.Names.RoleResult)
	Net.get(Net.Names.SetRole).OnServerEvent:Connect(function(player, target, role)
		if not RoleService.canManage(player) or not RateLimit.take(player, "Reroll") then
			return
		end
		if role == nil then
			result:FireClient(player, RoleService.get(player, target))
		else
			result:FireClient(player, RoleService.set(player, target, role))
		end
	end)
end

return RoleService
