--!strict
-- Style selection. A dev types ",e <Style>" in chat (any letter case; it must name a
-- module in Data/Styles). The pick is stored as the Player's "Style" attribute, which is
-- used for every new character. The live fighter switches as soon as it is safe: out of
-- combat mode and Idle. Until then the pick waits.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Enums = Paths.shared("Enums")
local MoveSchema = Paths.shared("MoveSchema")
local D = Paths.data("Defaults")
local Registry = Paths.server("FighterRegistry")
local Fighter = Paths.server("Fighter")
local PerkService = Paths.server("PerkService")

local COMMAND = "^%s*,[eE]%s+(%S+)%s*$"

local pending: { [Player]: true } = {}

local StyleService = {}

-- The style a player's next fighter uses.
function StyleService.styleFor(player: Player): any
	local name = player:GetAttribute("Style")
	if typeof(name) == "string" and Paths.findStyle(name) == name then
		local ok, style = pcall(MoveSchema.style, name)
		if ok then
			return style
		end
	end
	return MoveSchema.style(D.DEFAULT_STYLE)
end

-- Swaps the picked style onto the live fighter if that is safe now. True = nothing left to do.
local function tryApply(player: Player): boolean
	local f = Registry.getByPlayer(player)
	if not f then
		return true -- no fighter: the next character spawns with the pick
	end
	if Fighter.loadoutLocked(f, workspace:GetServerTimeNow()) then
		return false
	end
	local style = StyleService.styleFor(player)
	if f.style ~= style then
		f.style = style
		f.chainIndex = 1
		f.queued = nil
		PerkService.attach(f) -- swaps style perks (drops the old style's, e.g. a chambered dash)
		-- New style, new guard size: start it full (swaps only happen idle, out of combat).
		f.guard = Fighter.guardMax(f)
		f.model:SetAttribute("GuardMax", f.guard)
		Fighter.syncMeters(f, true)
		f.model:SetAttribute("Style", style.name) -- clients rebuild their animations from this
	end
	return true
end

function StyleService.select(player: Player, requested: string): boolean
	local name = Paths.findStyle(requested)
	if not name then
		return false
	end
	local ok, err = pcall(MoveSchema.style, name)
	if not ok then
		warn(`[StyleService] style {name} failed to load: {err}`)
		return false
	end
	player:SetAttribute("Style", name)
	pending[player] = true
	warn("[STYLEDEBUG] select ok:", player.Name, name, "(applies once Idle + out of combat mode)") -- TEMP
	return true
end

function StyleService.init()
	local function onPlayer(player: Player)
		player.Chatted:Connect(function(message: string)
			-- Devs only: styles are rolled (RerollService), so a free chat pick would skip the gacha.
			local requested = string.match(message, COMMAND)
			local Roles = Paths.server("RoleService")
			if requested then -- TEMP STYLEDEBUG
				warn("[STYLEDEBUG] ,e:", player.Name, player.UserId, "requested =", requested, "isDev =", Roles.isDev(player), "isOwner =", Roles.isOwner(player), "canGiveStyle =", Roles.canGiveStyle(player, requested))
			end
			if requested and Roles.isDev(player) and Roles.canGiveStyle(player, requested) then
				-- Save it like the P menu's Dev setter does, so a given (unob) style survives a rejoin.
				local PlayerData = Paths.server("PlayerData")
				local data = PlayerData.get(player)
				if StyleService.select(player, requested) and data then
					PlayerData.worn(data).Style = player:GetAttribute("Style")
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		pending[player] = nil
	end)

	RunService.Heartbeat:Connect(function()
		for player in pending do
			if tryApply(player) then
				pending[player] = nil
			end
		end
	end)
end

return StyleService