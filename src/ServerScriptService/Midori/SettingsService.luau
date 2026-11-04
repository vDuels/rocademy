--!strict
-- Player settings (user, 2026-10-29): the P menu's Settings page. Saved in PlayerData (data.Settings, created
-- on first change, so old saves need no migration) and replicated as Player attributes the client applies:
--   "SetFov" (number, D.SETTINGS.fovMin..fovMax)  -> CameraFov.setBase
--   "SetToggleRun" (bool)                          -> RunController: Shift toggles running instead of hold
--   "SetMusic" (number, 0..100 %)                  -> MusicController: OST + DJ booth volume
--   "SetHideTitle" (bool)                          -> NametagController: your title isn't drawn (you keep it)
--   Title (a Data/Titles id)                       -> RoleService.title: which of your roles' titles shows
--                                                     (one you don't own is ignored there); seen as "Title"
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local PlayerData = Paths.server("PlayerData")
local RateLimit = Paths.server("RateLimit")

local S = D.SETTINGS

local SettingsService = {}

-- The saved value for `key`, or nil if it isn't valid.
local function clean(key: any, value: any): any
	if key == "Fov" then
		local n = tonumber(value)
		return if n and n == n then math.clamp(math.round(n), S.fovMin, S.fovMax) else nil
	elseif key == "Music" then
		local n = tonumber(value)
		return if n and n == n then math.clamp(math.round(n), 0, 100) else nil
	elseif key == "Title" then
		return if typeof(value) == "string" and #value <= 40 and Paths.data("Titles")[value] ~= nil then value else nil
	elseif key == "ToggleRun" or key == "HideTitle" then
		return if typeof(value) == "boolean" then value else nil
	end
	return nil
end

local function publish(player: Player, settings: any)
	player:SetAttribute("SetFov", clean("Fov", settings.Fov) or S.fovDefault)
	player:SetAttribute("SetToggleRun", settings.ToggleRun == true)
	player:SetAttribute("SetMusic", clean("Music", settings.Music) or 100)
	player:SetAttribute("SetHideTitle", settings.HideTitle == true)
end

function SettingsService.init()
	PlayerData.onLoaded(function(player, data)
		publish(player, if typeof(data.Settings) == "table" then data.Settings else {})
	end)
	Net.get(Net.Names.Settings).OnServerEvent:Connect(function(player, key, value)
		local v = clean(key, value)
		local data = PlayerData.get(player)
		if v == nil or not data or not RateLimit.take(player, "Reroll") then
			return
		end
		if typeof(data.Settings) ~= "table" then
			data.Settings = {}
		end
		data.Settings[key] = v
		publish(player, data.Settings)
		if key == "Title" then
			Paths.server("RoleService").refresh(player) -- the nametag follows the pick
		end
	end)
end

return SettingsService