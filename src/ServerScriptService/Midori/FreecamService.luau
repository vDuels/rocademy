--!strict
-- Freecam for every role but Player, and anyone with a title (user, 2026-10-24; roles 2026-11-01). It's Roblox's own Freecam (Shift+P), copied
-- byte for byte from Studio's CoreScripts (FreeCamera.lua) into ServerStorage.Freecam, and installed
-- into PlayerGui the way Roblox's FreeCameraInstaller does it, so only they get the code.
-- Place managers (and everyone in Studio) already get Roblox's copy, so they're skipped: two copies
-- would both toggle on Shift+P.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local TEMPLATE = ServerStorage:WaitForChild("Freecam")
local MARK = "MidoriFreecam" -- attribute on our copy, so we never touch Roblox's own "Freecam" gui

local FreecamService = {}

local builtIn: { [Player]: boolean } = {} -- already has Roblox's Freecam (looked up once)

local function ours(gui: PlayerGui): Instance?
	for _, child in gui:GetChildren() do
		if child:GetAttribute(MARK) then
			return child
		end
	end
	return nil
end

local function sync(player: Player)
	if builtIn[player] then
		return
	end
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if not gui then
		return
	end
	-- Role = their highest role (RoleService), so anything but Player means they hold at least one.
	local role = player:GetAttribute("Role")
	local want = (typeof(role) == "string" and role ~= "Player") or typeof(player:GetAttribute("Title")) == "string"
	local have = ours(gui)
	if want and not have then
		local copy = TEMPLATE:Clone()
		copy:SetAttribute(MARK, true)
		copy.Parent = gui
	elseif have and not want then
		-- Role / title taken away: turn it off first (the script stops on this attribute), then remove it.
		-- ponytail: relies on Roblox's FreecamEnabled attribute hook; if a Roblox update drops it, a
		-- player losing their title mid-freecam keeps the camera until they respawn.
		local script = have:FindFirstChild("FreecamScript")
		if script then
			script:SetAttribute("FreecamEnabled", false)
		end
		task.delay(0.5, function()
			have:Destroy()
		end)
	end
end

FreecamService.sync = sync -- (edit-mode check)

local function onPlayer(player: Player)
	-- Same test as Roblox's installer: these players already have Shift+P.
	local ok, canManage = pcall(player.GetCanManageAsync, player)
	builtIn[player] = RunService:IsStudio() or (ok and canManage == true)
	player:WaitForChild("PlayerGui")
	for _, attr in { "Title", "Role" } do
		player:GetAttributeChangedSignal(attr):Connect(function()
			sync(player)
		end)
	end
	sync(player)
end

function FreecamService.init()
	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(function(player)
		builtIn[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

return FreecamService
