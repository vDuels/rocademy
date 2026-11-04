--!strict
-- Apartment doors, client side (server: ApartmentService; user, 2026-11-01).
--   Signs: every apartment door (travel pad with Apartment = true) gets a world-sized sign above it: its unit
--     (attribute Unit, else the part's Name), then FREE / the owner's name, then E TO CLAIM / OPEN / LOCKED.
--     It fades out with distance from your character: solid up to SIGN_FADE[1] studs, gone at SIGN_FADE[2].
--   Panel: hover + E on YOUR door (InteractController "door"), or the DOOR button inside your apartment
--     (BuildController): ENTER (at the door only), LOCKED / UNLOCKED, FRIENDS ON / OFF, the whitelist (everyone
--     in this server with ADD / REMOVE, plus anyone listed who isn't here, REMOVE only) and UNCLAIM.
--   Everything shown comes from the server's attributes (door: Owner / OwnerName / Locked; you: AptDoor,
--   AptLocked, AptFriends, AptList), so the panel just asks (Apartment "Lock" / "Friends" / "Allow" / ...).
local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local Ui = require(script.Parent:WaitForChild("StickerUi"))

local player = Players.LocalPlayer
local new, sticker, label, button = Ui.new, Ui.sticker, Ui.label, Ui.button

local DoorController = {}

local SIGN_FADE = { 10, 25 } -- studs (user, 2026-11-01)
-- Per sign: every piece with its own transparencies (a CanvasGroup's GroupTransparency is ignored inside a
-- BillboardGui, so each piece is faded itself). base = { [object] = { [property] = its normal value } }.
type Fade = { gui: BillboardGui, base: { [Instance]: { [string]: number } }, last: number, refresh: () -> () }
local fades: { [BasePart]: Fade } = {}

local FADE_PROPS = { "BackgroundTransparency", "TextTransparency", "TextStrokeTransparency" }

local function remember(gui: BillboardGui): { [Instance]: { [string]: number } }
	local base = {}
	for _, o in gui:GetDescendants() do
		if o:IsA("GuiObject") then
			local props = {}
			for _, p in FADE_PROPS do
				local ok, v = pcall(function()
					return (o :: any)[p]
				end)
				if ok and typeof(v) == "number" then
					props[p] = v
				end
			end
			base[o] = props
		end
	end
	return base
end

local function setFade(f: Fade, t: number)
	if math.abs(t - f.last) < 1e-3 then
		return
	end
	f.last = t
	for o, props in f.base do
		for p, v in props do
			(o :: any)[p] = v + (1 - v) * t
		end
	end
end

local function isDoor(inst: Instance): boolean
	return inst:IsA("BasePart") and inst:GetAttribute("Apartment") == true
end

local function unitName(door: BasePart): string
	local unit = door:GetAttribute("Unit")
	return string.upper(if unit ~= nil then `UNIT {unit}` else door.Name)
end

-- Signs ---------------------------------------------------------------------------------------------
local function sign(door: BasePart, signs: Instance)
	if fades[door] then
		return -- already has one (a door streamed back in as the same part)
	end
	-- ResetOnSpawn = false (user, 2026-11-01: the signs vanished "after a while"): they used to sit in a Folder
	-- in PlayerGui, and respawning empties PlayerGui of everything but ResetOnSpawn = false GUIs.
	local gui = new("BillboardGui", {
		Name = "MidoriDoorSign", Adornee = door, Size = UDim2.fromScale(5, 2.2), -- studs: scales with distance like the door
		StudsOffsetWorldSpace = Vector3.new(0, door.Size.Y / 2 + 1.4, 0), LightInfluence = 0, Enabled = false,
		ResetOnSpawn = false,
	}, signs)
	local billboard = gui
	local _, top = sticker(gui, Ui.BLACK, { Size = UDim2.fromScale(0.6, 0.3), Position = UDim2.fromScale(0.2, 0), Rotation = -3 }, Vector2.new(0, 0))
	label(top, unitName(door), Ui.YELLOW, { Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1) })
	local _, mid = sticker(gui, Ui.RED, { Size = UDim2.fromScale(1, 0.4), Position = UDim2.fromScale(0, 0.3) }, Vector2.new(0.02, 0.08))
	local who = label(mid, "", Ui.WHITE, { Size = UDim2.fromScale(0.92, 0.8), Position = UDim2.fromScale(0.04, 0.1) })
	local state = label(gui, "", Ui.WHITE, { Size = UDim2.fromScale(0.8, 0.26), Position = UDim2.fromScale(0.1, 0.73), TextStrokeTransparency = 0 })
	local function refresh()
		local owner = door:GetAttribute("Owner")
		if owner == nil then
			mid.BackgroundColor3 = Ui.CARD
			who.Text = "FREE"
			state.Text, state.TextColor3 = "E TO CLAIM", Ui.YELLOW
		else
			mid.BackgroundColor3 = if owner == player.UserId then Ui.RED else Ui.CARD
			who.Text = string.upper(tostring(door:GetAttribute("OwnerName") or "?"))
			local locked = door:GetAttribute("Locked") == true
			state.Text = if locked then "LOCKED" else "OPEN"
			state.TextColor3 = if locked then Ui.RED else Ui.GOOD
		end
	end
	for _, a in { "Owner", "OwnerName", "Locked" } do
		door:GetAttributeChangedSignal(a):Connect(refresh)
	end
	refresh()
	-- Built: remember every piece's normal look (refresh only changes colours / text, never transparency).
	fades[door] = { gui = billboard, base = remember(billboard), last = -1, refresh = refresh }
	-- Streamed back in (bug, 2026-11-02: the sign "sometimes doesnt update who owns the unit"): an owner change
	-- made while the door was streamed out arrives with it, without the attribute signals firing. Re-read.
	door.AncestryChanged:Connect(function()
		if door:IsDescendantOf(workspace) then
			refresh()
		end
	end)
	door.Destroying:Connect(function()
		fades[door] = nil
		billboard:Destroy()
	end)
end

-- Panel ---------------------------------------------------------------------------------------------
type Panel = { gui: ScreenGui, close: TextButton, refresh: () -> () }
local panel: Panel? = nil
local atDoor: BasePart? = nil -- the door we opened it at (ENTER goes through it); nil = from inside

local function remote(...: any)
	Net.get(Net.Names.Apartment):FireServer(...)
end

local function close()
	if panel then
		panel.gui.Enabled = false
		panel.close.Modal = false
	end
end

local function build(): Panel
	local gui = new("ScreenGui", { Name = "MidoriDoor", ResetOnSpawn = false, Enabled = false, DisplayOrder = 4, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
	local outer, fill = sticker(gui, Ui.WELL, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.36, 0.72), Rotation = 1 }, Vector2.new(0.02, 0.012), Vector2.new(0.025, 0.018))
	new("UIAspectRatioConstraint", { AspectRatio = 0.75 }, outer)
	local _, headFill = sticker(outer, Ui.RED, { Position = UDim2.fromScale(-0.04, -0.045), Size = UDim2.fromScale(0.72, 0.1), Rotation = -3, ZIndex = 5 }, Vector2.new(0.02, 0.08))
	local head = label(headFill, "", Ui.WHITE, { Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1), TextXAlignment = Enum.TextXAlignment.Left })
	local closeOuter, _, _, closeButton = button(outer, "X", Ui.YELLOW, Ui.BLACK, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.97, 0.02), Size = UDim2.fromScale(0.12, 0.09), Rotation = 6, ZIndex = 6 })
	closeButton.Activated:Connect(close)
	local _ = closeOuter

	local enterOuter, _, _, enterButton = button(fill, "ENTER", Ui.GOOD, Ui.BLACK, { Position = UDim2.fromScale(0.05, 0.08), Size = UDim2.fromScale(0.9, 0.09) })
	enterButton.Activated:Connect(function()
		if atDoor then
			remote("Visit", atDoor)
			close()
		end
	end)
	local lockOuter, lockFill, lockLabel, lockButton = button(fill, "", Ui.CARD, Ui.WHITE, { Position = UDim2.fromScale(0.05, 0.2), Size = UDim2.fromScale(0.43, 0.08), Rotation = -1 })
	lockButton.Activated:Connect(function()
		remote("Lock", player:GetAttribute("AptLocked") ~= true)
	end)
	local _, friendsFill, friendsLabel, friendsButton = button(fill, "", Ui.CARD, Ui.WHITE, { Position = UDim2.fromScale(0.52, 0.2), Size = UDim2.fromScale(0.43, 0.08), Rotation = 1 })
	friendsButton.Activated:Connect(function()
		remote("Friends", player:GetAttribute("AptFriends") ~= true)
	end)
	local _ = lockOuter
	local hint = label(fill, "", Ui.DIM, { Position = UDim2.fromScale(0.05, 0.3), Size = UDim2.fromScale(0.9, 0.04) })
	label(fill, "WHITELIST", Ui.YELLOW, { Position = UDim2.fromScale(0.05, 0.355), Size = UDim2.fromScale(0.5, 0.05), TextXAlignment = Enum.TextXAlignment.Left })
	local list = new("ScrollingFrame", {
		Position = UDim2.fromScale(0.05, 0.42), Size = UDim2.fromScale(0.9, 0.44), CanvasSize = UDim2.new(), ZIndex = 3,
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.Y,
	}, fill)
	local layout = new("UIGridLayout", { CellSize = UDim2.fromScale(1, 1), CellPadding = UDim2.fromScale(0, 0.015), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	new("UIAspectRatioConstraint", { AspectRatio = 7, DominantAxis = Enum.DominantAxis.Width }, layout)
	local empty = label(fill, "NOBODY ELSE HERE YET", Ui.DIM, { Position = UDim2.fromScale(0.05, 0.5), Size = UDim2.fromScale(0.9, 0.05) })
	local unclaimOuter, _, _, unclaimButton = button(fill, "UNCLAIM DOOR", Color3.fromRGB(90, 20, 30), Ui.WHITE, { Position = UDim2.fromScale(0.05, 0.885), Size = UDim2.fromScale(0.9, 0.08) })
	unclaimButton.Activated:Connect(function()
		remote("Unclaim")
		close()
	end)

	local function row(order: number, id: number, name: string, listed: boolean, here: boolean)
		local o, f = sticker(list, if listed then Ui.CARD else Ui.WELL, { LayoutOrder = order }, Vector2.new(0.008, 0.06))
		label(f, string.upper(name), if listed then Ui.WHITE else Ui.DIM, { Position = UDim2.fromScale(0.04, 0.15), Size = UDim2.fromScale(0.6, 0.7), TextXAlignment = Enum.TextXAlignment.Left })
		local _ = o
		if listed or here then
			local _, _, _, b = button(f, if listed then "REMOVE" else "ADD", if listed then Ui.RED else Ui.GOOD, if listed then Ui.WHITE else Ui.BLACK, { Position = UDim2.fromScale(0.68, 0.14), Size = UDim2.fromScale(0.29, 0.72), ZIndex = 5 })
			b.Activated:Connect(function()
				remote("Allow", id, if listed then false else true)
			end)
		end
	end

	local function refresh()
		local door = player:GetAttribute("AptDoor")
		head.Text = if typeof(door) == "string" then `YOUR DOOR · {door}` else "YOUR DOOR"
		enterOuter.Visible = atDoor ~= nil
		unclaimOuter.Visible = typeof(door) == "string"
		local locked = player:GetAttribute("AptLocked") == true
		local friends = player:GetAttribute("AptFriends") == true
		lockLabel.Text = if locked then "LOCKED" else "UNLOCKED"
		lockFill.BackgroundColor3 = if locked then Ui.RED else Ui.CARD
		friendsLabel.Text = if friends then "FRIENDS: ON" else "FRIENDS: OFF"
		friendsFill.BackgroundColor3 = if friends then Ui.RED else Ui.CARD
		hint.Text = if locked then (if friends then "ONLY YOU, YOUR LIST AND YOUR FRIENDS" else "ONLY YOU AND YOUR LIST") else "ANYONE CAN VISIT"
		for _, c in list:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		local ok, decoded = pcall(HttpService.JSONDecode, HttpService, (player:GetAttribute("AptList") or "{}") :: string)
		local onList: { [string]: string } = if ok and typeof(decoded) == "table" then decoded else {}
		local order, seen = 0, {}
		-- Listed people first (here or not), then everyone else in the server.
		for key, name in onList do
			order += 1
			seen[key] = true
			row(order, tonumber(key) :: number, name, true, Players:GetPlayerByUserId(tonumber(key) :: number) ~= nil)
		end
		for _, p in Players:GetPlayers() do
			if p ~= player and not seen[tostring(p.UserId)] then
				order += 100
				row(order, p.UserId, p.DisplayName, false, true)
			end
		end
		empty.Visible = order == 0
	end

	for _, a in { "AptDoor", "AptLocked", "AptFriends", "AptList" } do
		player:GetAttributeChangedSignal(a):Connect(function()
			if gui.Enabled then
				refresh()
			end
		end)
	end
	Players.PlayerAdded:Connect(function()
		if gui.Enabled then
			refresh()
		end
	end)
	Players.PlayerRemoving:Connect(function()
		if gui.Enabled then
			task.defer(refresh)
		end
	end)
	return { gui = gui, close = closeButton, refresh = refresh }
end

-- `door` = the door we're at (gives the ENTER button); nil = opened from inside (BuildController's DOOR).
function DoorController.open(door: BasePart?)
	panel = panel or build()
	local p = panel :: Panel
	atDoor = door
	p.refresh()
	p.gui.Enabled = true
	p.close.Modal = true -- frees the mouse while it's up
	local outer = p.gui:FindFirstChildWhichIsA("Frame")
	if outer then
		local scale = outer:FindFirstChildWhichIsA("UIScale") or new("UIScale", {}, outer)
		scale.Scale = 0.85
		TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
	end
end

function DoorController.init()
	local signs = player:WaitForChild("PlayerGui")
	local function add(inst: Instance)
		if isDoor(inst) then
			sign(inst :: BasePart, signs)
		end
	end
	for _, inst in CollectionService:GetTagged(D.TRAVEL.tag) do
		add(inst)
	end
	CollectionService:GetInstanceAddedSignal(D.TRAVEL.tag):Connect(add)
	-- Walking away from the door closes the panel (it was opened there); signs fade with distance.
	game:GetService("RunService").Heartbeat:Connect(function()
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		for door, f in fades do
			local d = if root and root:IsA("BasePart") then (root.Position - door.Position).Magnitude else math.huge
			local t = math.clamp((d - SIGN_FADE[1]) / (SIGN_FADE[2] - SIGN_FADE[1]), 0, 1)
			setFade(f, t)
			-- Only while the door is really here (user, 2026-11-01: after leaving an apartment the signs stayed
			-- blank until you walked off and back): the doors stream out while you're 3000+ studs away, you land
			-- next to them before they stream back, and a billboard switched on with its adornee missing doesn't
			-- draw once it arrives. Off until then, so it switches on fresh.
			local on = t < 1 and door:IsDescendantOf(workspace)
			if on and not f.gui.Enabled then
				f.refresh() -- coming into view: show what the attributes say now, not what they said last time
			end
			f.gui.Enabled = on
		end
		if panel and panel.gui.Enabled and atDoor and root and root:IsA("BasePart") and (root.Position - atDoor.Position).Magnitude > D.TRAVEL.reach + 6 then
			close()
		end
	end)
end

return DoorController
