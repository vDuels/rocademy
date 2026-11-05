--!strict
-- Apartments, client side (server: ApartmentService). The SERVER builds the apartment we're in
-- (workspace.Apartments.<owner>: "Shell" + furniture models with attribute Uid, real parts like the rest of the
-- map, user 2026-11-01) and sends its data ("Load": plot CFrame, owner UserId, style, items); "Set" / "Remove"
-- update one item's data, "Unload" = we're out. state.models follows the server's furniture models.
-- Also hides every other character and every other apartment that isn't where we are (same apartment, or out
-- on the map): parts + decals via LocalTransparencyModifier, and characters' MidoriNametag (NametagController).
-- Zones (Zone+ fromRegion, so nothing extra sits in the world): the whole apartment is an area for
-- LocationController (NOW ENTERING card, OST pool "Apartment"), and each room is a zone too: state.room = the
-- room we're in (kept while we're in a doorway between two), roomChanged fires (DJController mixes by it).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Net = Paths.shared("Net")
local GridMath = Paths.shared("GridMath")
local Zone = Paths.lib("Zone")
local Location = require(script.Parent:WaitForChild("LocationController"))

local player = Players.LocalPlayer

local ApartmentController = {}

-- The apartment we're in (BuildController reads these). owner = nil: not in one.
-- decor = how many of each furniture we own (only sent when it's our own apartment).
-- style = the Assets.Apartment model it's built from.
-- walls = paint target ("<room>" walls / "<room>/Ceiling") -> { m = material?, c = hex? } (the server paints).
-- folder = the server's built apartment model.
-- dj = the booth's pick { song, at } (ApartmentService.setDJ), nil = shuffle everything.
type State = { dj: { song: string, at: number }?, room: string?, owner: number?, plot: CFrame, items: { [string]: GridMath.Item }, rooms: { [string]: GridMath.Room }, models: { [string]: Model }, folder: Model?, decor: { [string]: number }, style: string, walls: { [string]: { m: string?, c: string? } } }
local state: State = { dj = nil, room = nil, owner = nil, plot = CFrame.new(), items = {}, rooms = {}, models = {}, folder = nil, decor = {}, style = "", walls = {} }
ApartmentController.state = state
local changedEvent = Instance.new("BindableEvent")
ApartmentController.changed = changedEvent.Event -- (uid?) an item changed; nil = the whole apartment (in / out)
local ownedEvent = Instance.new("BindableEvent")
ApartmentController.ownedChanged = ownedEvent.Event -- state.decor changed (bought something / a code)
local djEvent = Instance.new("BindableEvent")
ApartmentController.djChanged = djEvent.Event -- state.dj changed (someone picked a song)
local roomEvent = Instance.new("BindableEvent")
ApartmentController.roomChanged = roomEvent.Event -- (room?) state.room changed
local zoneCleanup: { () -> () } = {} -- the zones of the apartment we're in

local function clearZones()
	for _, f in zoneCleanup do
		f()
	end
	zoneCleanup = {}
	if state.room then
		state.room = nil
		roomEvent:Fire(nil)
	end
end

local function makeZones(shell: Model, owner: number)
	local cf, size = shell:GetBoundingBox()
	local whole = Zone.fromRegion(cf, size)
	table.insert(zoneCleanup, function()
		whole:destroy()
	end)
	local track = Location.track
	if track then
		local who = Players:GetPlayerByUserId(owner)
		local name = if owner == player.UserId then "YOUR APARTMENT" else `{string.upper(if who then who.DisplayName else "SOMEONE")}'S APARTMENT`
		table.insert(zoneCleanup, track(whole, name, "Apartment"))
	end
	for name, room in state.rooms do
		local w, d, h = room.size[1] * GridMath.CELL, room.size[2] * GridMath.CELL, room.height or 10
		local zone = Zone.fromRegion(state.plot * room.origin * CFrame.new(w / 2, h / 2, d / 2), Vector3.new(w, h, d))
		zone.localPlayerEntered:Connect(function()
			if state.room ~= name then
				state.room = name
				roomEvent:Fire(name)
			end
		end)
		table.insert(zoneCleanup, function()
			zone:destroy()
		end)
	end
end

local function getDef(id: string): any?
	return Paths.furniture(id)
end

-- Furniture models in the apartment we're in (the server's, attribute Uid) -> state.models.
local function track(m: Instance)
	local uid = m:GetAttribute("Uid")
	if not (m:IsA("Model") and typeof(uid) == "string") then
		return
	end
	state.models[uid] = m
	local def = getDef(m.Name) -- clones keep the furniture id as their name
	if def and def.dj and state.owner == player.UserId then
		m:SetAttribute("DJBooth", true) -- hover + E = pick the music (InteractController -> DJController); owner only
	end
	if def and def.image and state.owner == player.UserId then
		m:SetAttribute("PosterEdit", true) -- hover + E = type a decal id (ApartmentController.openPoster); owner only
	end
	changedEvent:Fire(uid)
end

local function untrack(m: Instance)
	local uid = m:GetAttribute("Uid")
	if typeof(uid) == "string" and state.models[uid] == m then
		state.models[uid] = nil
		changedEvent:Fire(uid)
	end
end

local folderConns: { RBXScriptConnection } = {}
local loadGen = 0

-- `quiet`: a reload (style swap) is about to follow, so don't tell listeners we left.
local function unload(quiet: boolean?)
	loadGen += 1 -- a load still waiting for the apartment to stream in gives up
	clearZones()
	for _, c in folderConns do
		c:Disconnect()
	end
	folderConns = {}
	state.owner, state.folder, state.items, state.models, state.walls = nil, nil, {}, {}, {}
	if not quiet then
		changedEvent:Fire(nil)
	end
end

-- The server built the apartment (workspace.Apartments.<owner>, streamed to us while we're inside); we
-- keep its data and wait for it to arrive.
local function load(plot: CFrame, owner: number, style: string, items: { [string]: GridMath.Item }, decor: { [string]: number }?, walls: { [string]: any }?, dj: any?): boolean
	unload(true)
	local my = loadGen
	local template = Paths.Assets:WaitForChild("Apartment"):FindFirstChild(style)
	local list = workspace:WaitForChild("Apartments", 10)
	local apt = list and list:WaitForChild(tostring(owner), 10)
	local shell = apt and apt:WaitForChild("Shell", 10)
	if my ~= loadGen then
		return false -- left (or went somewhere else) while it streamed in
	end
	if not (template and template:IsA("Model") and apt and shell and shell:IsA("Model")) then
		warn(`[Apartment] apartment {owner} ({style}) never arrived`)
		changedEvent:Fire(nil)
		return false
	end
	state.rooms = GridMath.rooms(template)
	state.owner, state.plot, state.items, state.decor, state.style, state.walls, state.dj = owner, plot, items, decor or {}, style, walls or {}, dj
	state.folder = apt
	for _, m in apt:GetChildren() do
		track(m)
	end
	table.insert(folderConns, apt.ChildAdded:Connect(track))
	table.insert(folderConns, apt.ChildRemoved:Connect(untrack))
	makeZones(shell, owner)
	changedEvent:Fire(nil)
	return true
end

-- Poster picture (user, 2026-11-01: "enter in decal ids to make the poster") ------------------------------
-- E on your own poster: a box for a decal id (or a pasted library link: the first long number in it).
local posterUi: { gui: ScreenGui, box: TextBox, close: TextButton, uid: string? }? = nil

local function closePoster()
	if posterUi then
		posterUi.gui.Enabled = false
		posterUi.close.Modal = false
		posterUi.uid = nil
	end
end

function ApartmentController.openPoster(model: Model)
	local uid = model:GetAttribute("Uid")
	local it = if typeof(uid) == "string" then state.items[uid] else nil
	if not it or state.owner ~= player.UserId then
		return
	end
	if not posterUi then
		local S = require(script.Parent:WaitForChild("StickerUi"))
		local gui = S.new("ScreenGui", { Name = "MidoriPoster", ResetOnSpawn = false, Enabled = false, DisplayOrder = 4, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
		local panel, fill = S.sticker(gui, S.WELL, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.34, 0.26), Rotation = -1 }, Vector2.new(0.015, 0.03), Vector2.new(0.02, 0.04))
		S.new("UIAspectRatioConstraint", { AspectRatio = 2.6 }, panel)
		local _, headFill = S.sticker(panel, S.RED, { Position = UDim2.fromScale(-0.03, -0.12), Size = UDim2.fromScale(0.5, 0.24), Rotation = -3, ZIndex = 5 }, Vector2.new(0.02, 0.08))
		S.label(headFill, "POSTER", S.WHITE, { Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1), TextXAlignment = Enum.TextXAlignment.Left })
		local closeOuter, closeFill = S.sticker(panel, S.YELLOW, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.98, 0.04), Size = UDim2.fromScale(0.09, 0.24), Rotation = 6, ZIndex = 6 }, Vector2.new(0.08, 0.08))
		S.label(closeFill, "X", S.BLACK, { Size = UDim2.fromScale(0.8, 0.8), Position = UDim2.fromScale(0.1, 0.1) })
		local close = S.new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, closeOuter)
		close.Activated:Connect(closePoster)
		S.label(fill, "DECAL ID", S.DIM, { Position = UDim2.fromScale(0.05, 0.16), Size = UDim2.fromScale(0.9, 0.16), TextXAlignment = Enum.TextXAlignment.Left })
		local _, boxFill = S.sticker(fill, S.CARD, { Position = UDim2.fromScale(0.05, 0.36), Size = UDim2.fromScale(0.62, 0.3) }, Vector2.new(0.012, 0.06))
		local box = S.new("TextBox", {
			Size = UDim2.fromScale(0.92, 0.7), Position = UDim2.fromScale(0.04, 0.15), ZIndex = 5, Font = S.FONT, TextScaled = true,
			TextColor3 = S.WHITE, PlaceholderText = "12179880823", PlaceholderColor3 = S.DIM, ClearTextOnFocus = false, Text = "",
			TextXAlignment = Enum.TextXAlignment.Left,
		}, boxFill)
		local _, _, _, set = S.button(fill, "SET", S.RED, S.WHITE, { Position = UDim2.fromScale(0.71, 0.36), Size = UDim2.fromScale(0.24, 0.3) })
		local function submit()
			local id = tonumber(string.match(box.Text, "%d%d%d+") or "")
			local ui = posterUi
			if id and ui and ui.uid then
				Net.get(Net.Names.Apartment):FireServer("Poster", ui.uid, id)
				closePoster()
			end
		end
		set.Activated:Connect(submit)
		box.FocusLost:Connect(function(enter: boolean)
			if enter then
				submit()
			end
		end)
		posterUi = { gui = gui, box = box, close = close, uid = nil }
	end
	local ui = posterUi :: any
	local def = getDef(it.item)
	ui.uid = uid
	ui.box.Text = tostring((it :: any).img or (def and def.image) or "")
	ui.gui.Enabled = true
	ui.close.Modal = true -- frees the mouse while it's up
end

-- Character hiding -------------------------------------------------------------------------------------
local hidden: { [Model]: boolean } = {}

local function setPart(d: Instance, hide: boolean)
	if d:IsA("BasePart") or d:IsA("Decal") then
		d.LocalTransparencyModifier = if hide then 1 else 0
	elseif d:IsA("BillboardGui") and d.Name == "MidoriNametag" then
		d.Enabled = not hide
	end
end

local function where(character: Model?): any
	return character and character:GetAttribute("InApartment")
end

local function refresh(other: Player)
	local character = other.Character
	if other == player or not character then
		return
	end
	local hide = where(character) ~= where(player.Character)
	if hidden[character] == hide then
		return
	end
	hidden[character] = hide
	for _, d in character:GetDescendants() do
		setPart(d, hide)
	end
end

-- Every built apartment but the one we're in is hidden (neighbouring plots are only 300 studs apart).
local hiddenApt: { [Instance]: boolean } = {}
local function refreshApartments()
	local list = workspace:FindFirstChild("Apartments")
	local mine = tostring(where(player.Character))
	for _, apt in if list then list:GetChildren() else {} do
		local hide = apt.Name ~= mine
		if hiddenApt[apt] ~= hide then
			hiddenApt[apt] = hide
			for _, d in apt:GetDescendants() do
				setPart(d, hide)
			end
		end
	end
end

local function refreshAll()
	for _, p in Players:GetPlayers() do
		refresh(p)
	end
	refreshApartments()
end

local function watchCharacter(other: Player, character: Model)
	if other == player then
		character:GetAttributeChangedSignal("InApartment"):Connect(refreshAll)
		refreshAll()
		return
	end
	character:GetAttributeChangedSignal("InApartment"):Connect(function()
		refresh(other)
	end)
	-- Accessories / the nametag arriving late, and parts streaming back in (StreamingEnabled; plots are
	-- 3000+ studs out): a part that was streamed out while we unhid this character can come back still at
	-- LTM 1, so set BOTH ways, not only when hiding.
	character.DescendantAdded:Connect(function(d)
		setPart(d, hidden[character] == true)
	end)
	character.Destroying:Connect(function()
		hidden[character] = nil
	end)
	refresh(other)
end

function ApartmentController.init()
	-- "Locked": we tried to visit someone in build mode.
	local toastGui = Instance.new("ScreenGui")
	toastGui.Name = "MidoriApartmentToast"
	toastGui.ResetOnSpawn = false
	local toast = Instance.new("TextLabel")
	toast.AnchorPoint = Vector2.new(0.5, 0)
	toast.Position = UDim2.fromScale(0.5, 0.15)
	toast.Size = UDim2.fromScale(0.4, 0.05)
	toast.BackgroundTransparency = 1
	toast.Font = Enum.Font.LuckiestGuy
	toast.TextScaled = true
	toast.TextColor3 = Color3.fromRGB(255, 110, 110)
	toast.TextStrokeTransparency = 0
	toast.Text = ""
	toast.Parent = toastGui
	toastGui.Parent = player:WaitForChild("PlayerGui")
	local toastGen = 0

	Net.get(Net.Names.Apartment).OnClientEvent:Connect(function(action: string, a: any, b: any, c: any, d: any, e: any, f: any, g: any, h: any)
		if action == "Locked" then
			-- a = why (ApartmentService): Build / Locked / Taken / HaveDoor
			toastGen += 1
			local my = toastGen
			toast.Text = if a == "Locked" then "LOCKED: YOU'RE NOT ON THEIR LIST"
				elseif a == "Taken" then "SOMEONE ALREADY CLAIMED THIS DOOR"
				elseif a == "HaveDoor" then "YOU ALREADY HAVE A DOOR (UNCLAIM IT FIRST)"
				else "THEY'RE DECORATING, TRY AGAIN LATER"
			task.delay(2.5, function()
				if toastGen == my then
					toast.Text = ""
				end
			end)
		elseif action == "Load" then
			-- h = where to stand (a style swap): hold still (anchored HERE only; we own our physics) until the
			-- new apartment has streamed in, so we don't fall through where the old floor was.
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local hold = typeof(h) == "CFrame" and root and root:IsA("BasePart") and root or nil
			if hold then
				hold.AssemblyLinearVelocity = Vector3.zero
				hold.Anchored = true
			end
			local ok = load(a, b, c, d, e, f, g)
			if hold then
				if ok and character and player.Character == character then
					character:PivotTo(h)
				end
				hold.Anchored = false
			end
		elseif action == "DJ" and state.folder then
			state.dj = a
			djEvent:Fire()
		elseif action == "Paint" and state.folder then
			state.walls[a] = b -- the server painted the walls
		elseif action == "Unload" then
			-- a = where the server put us (leaving): move there ourselves first, we own our character's
			-- physics, so the floor never goes away under us before the server's move lands.
			local character = player.Character
			if typeof(a) == "CFrame" and character then
				local root = character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") then
					root.AssemblyLinearVelocity = Vector3.zero
				end
				character:PivotTo(a)
			end
			closePoster()
			unload()
		elseif action == "Set" and state.folder then
			state.items[a] = b -- the server redrew its model (track picks it up)
			changedEvent:Fire(a)
		elseif action == "Owned" and state.folder then
			state.decor = a
			ownedEvent:Fire()
		elseif action == "Remove" and state.folder then
			state.items[a] = nil -- the server took its model down (untrack)
			changedEvent:Fire(a)
		end
	end)

	-- Props by place (user, 2026-11-01: "cans/props unload from non visible locations (club kuro,
	-- apartments)"): a place = an apartment (whose), an Enclosed area (LocationController), or the open map.
	-- Cans (dropped / in the world) in another place than ours aren't drawn here. Held cans ride on their
	-- holder's character, which the character hiding above already handles.
	local SODA_TAG = Paths.data("Defaults").SODA.tag
	local function placeOf(pos: Vector3, apartment: any): string
		if apartment ~= nil then
			return "apt:" .. tostring(apartment)
		end
		return "area:" .. (Location.enclosedAt(pos) or "map")
	end
	local function setProp(part: BasePart, hide: boolean)
		local v = if hide then 1 else 0
		if part.LocalTransparencyModifier ~= v then
			part.LocalTransparencyModifier = v
			for _, d in part:GetDescendants() do
				if d:IsA("BasePart") or d:IsA("Decal") then
					d.LocalTransparencyModifier = v
				end
			end
		end
	end
	task.spawn(function()
		while true do
			task.wait(0.5)
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local mine = placeOf(root.Position, where(character))
				local seen = {}
				local function check(can: Instance)
					if can:IsA("BasePart") and not seen[can] and can.Parent == workspace then
						seen[can] = true
						setProp(can, placeOf(can.Position, can:GetAttribute("InApartment")) ~= mine)
					end
				end
				for _, can in game:GetService("CollectionService"):GetTagged(SODA_TAG) do
					check(can)
				end
				for _, c in workspace:GetChildren() do
					if c.Name == "Soda" then -- dropped cans between their drop and being taggable again
						check(c)
					end
				end
				-- Held cans go wherever their holder goes (user, 2026-11-01: "after changing location with a
				-- drink in ur hands it doesnt carry over"): a can we hid on another place's floor stays hidden
				-- once picked up unless it's reset here. Seen = seen with its holder (character hiding).
				for _, p in Players:GetPlayers() do
					local holder = p.Character
					local arm = holder and holder:FindFirstChild("Right Arm")
					local motor = arm and arm:FindFirstChild("Soda") -- SodaService's hand Motor6D
					local can = if motor and motor:IsA("Motor6D") then motor.Part1 else nil
					if holder and can then
						setProp(can, hidden[holder] == true)
					end
				end
			end
		end
	end)

	local function onPlayer(p: Player)
		p.CharacterAdded:Connect(function(character)
			watchCharacter(p, character)
		end)
		if p.Character then
			watchCharacter(p, p.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end

	task.spawn(function()
		local list = workspace:WaitForChild("Apartments")
		local function watchApartment(apt: Instance)
			apt.DescendantAdded:Connect(function(d) -- streamed in late / furniture placed: both ways, like characters
				setPart(d, hiddenApt[apt] == true)
			end)
			apt.Destroying:Connect(function()
				hiddenApt[apt] = nil
			end)
			refreshApartments()
		end
		list.ChildAdded:Connect(watchApartment)
		for _, apt in list:GetChildren() do
			watchApartment(apt)
		end
	end)
end

return ApartmentController
