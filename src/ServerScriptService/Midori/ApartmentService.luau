--!strict
-- Apartments (user, 2026-10-31): plots in the main server, invisible to anyone not inside. The server keeps
-- each apartment's data, checks every edit and BUILDS it while someone is inside (user, 2026-11-01: "make
-- it like club kuro": real server parts, so seats, cans and physics follow the map's rules):
-- workspace.Apartments.<owner UserId> = "Shell" (the style's model) + one model per placed item (attribute
-- Uid). It streams to whoever is inside (PersistentPerPlayer); plots are 3000+ studs out, and clients hide
-- every apartment that isn't theirs (ApartmentController). Gone a moment after the last person leaves.
-- Styles: every Model in Assets.Apartment (edit / duplicate them in Studio; each needs a Rooms folder of
-- floor parts sized in 2-stud cells, a Spawn and an Exit part). Each style keeps its own furniture layout
-- (PlayerData.Apartment.Layouts[style]); D.APARTMENT.defaultStyle is where everyone starts.
-- Plots: parts tagged D.APARTMENT.tag; an owner gets a free one the first time they go in, kept until they leave.
-- Doors (user, 2026-11-01): every travel pad with Apartment = true is a unit door on the map. Hover + E on a
-- free one = CLAIM (Apartment "Claim": one door per player, this server only, freed when you leave or
-- "Unclaim"); it then leads to YOUR apartment (your saved layout, any door in any server). Others' doors =
-- VISIT (Apartment "Visit"), yours = the door panel (client DoorController: ENTER, lock, whitelist).
-- Door attributes: Owner (UserId), OwnerName, Locked. Owner's Player attributes: AptDoor (door name),
-- AptLocked, AptFriends, AptList (JSON UserId -> name).
-- Access (saved, data.Apartment.Access): unlocked = anyone; locked = you + your whitelist (+ your Roblox
-- friends if Friends is on). Locking / removing someone puts out whoever isn't allowed any more. Staff ,apt
-- skips it. Out: the style's Exit (client -> Apartment "Leave"), respawning, or the owner leaving the server.
-- Build mode (Apartment "Build", on): kicks every visitor out and keeps them out until it's off. Edits
-- (Furnish) and style swaps (Apartment "Style") only work in it. Placement rules: Shared/GridMath.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local GridMath = Paths.shared("GridMath")

local APT = D.APARTMENT

local ApartmentService = {}

local plotOf: { [number]: BasePart } = {} -- owner UserId -> plot
local ownerOf: { [BasePart]: number } = {}
local inside: { [Player]: { owner: number, back: CFrame } } = {} -- who is in which apartment; `back` = where leaving puts you
local building: { [number]: boolean } = {} -- owner UserId -> in build mode (no visitors)
local doorOwner: { [BasePart]: number } = {} -- claimed unit doors (this server)
local doorOf: { [number]: BasePart } = {}
local friendCache: { [Player]: { [number]: boolean } } = {}

local function getDef(id: string): any?
	return Paths.furniture(id)
end

-- Every style's model (Assets.Apartment.<style>), or nil for an unknown name.
local function styleModel(style: any): Model?
	local m = if typeof(style) == "string" then Paths.Assets:WaitForChild("Apartment"):FindFirstChild(style) else nil
	return if m and m:IsA("Model") then m else nil
end

-- A style's rooms + where you arrive, relative to the plot (cached: the models don't change at runtime).
local shells: { [string]: { rooms: { [string]: GridMath.Room }, spawn: CFrame } } = {}
local function shell(style: string): { rooms: { [string]: GridMath.Room }, spawn: CFrame }
	local info = shells[style]
	if not info then
		local m = styleModel(style) :: Model
		local spawn = m:FindFirstChild("Spawn")
		info = {
			rooms = GridMath.rooms(m),
			spawn = if spawn and spawn:IsA("BasePart")
				then m:GetPivot():ToObjectSpace(spawn.CFrame) * CFrame.new(0, -spawn.Size.Y / 2 + 3, 0) -- R6 root 3 up
				else CFrame.new(0, 3, 0),
		}
		shells[style] = info
	end
	return info
end

-- The style a profile shows (falls back to the default if theirs was removed).
function ApartmentService.styleOf(data: any): string
	local style = data.Apartment.Style
	return if styleModel(style) then style else APT.defaultStyle
end

-- The current style's placed items (uid -> item), created on first use.
function ApartmentService.layout(data: any): { [string]: GridMath.Item }
	local apt = data.Apartment
	local style = ApartmentService.styleOf(data)
	apt.Layouts[style] = apt.Layouts[style] or {}
	return apt.Layouts[style]
end

-- Only the fields GridMath knows, type-checked; exactly one of room / parent / wall.
local function sanitize(raw: any): GridMath.Item?
	if typeof(raw) ~= "table" or typeof(raw.item) ~= "string" then
		return nil
	end
	local spots = 0
	for _, key in { "room", "parent", "wall" } do
		local v = raw[key]
		if v ~= nil and typeof(v) ~= "string" then
			return nil
		end
		spots += if v ~= nil then 1 else 0
	end
	if spots ~= 1 then
		return nil
	end
	return { item = raw.item, room = raw.room, parent = raw.parent, wall = raw.wall, x = raw.x, z = raw.z, rot = raw.rot }
end

local function placedCount(items: { [string]: GridMath.Item }, id: string): number
	local n = 0
	for _, it in items do
		n += if it.item == id then 1 else 0
	end
	return n
end

-- Pure: one edit to `data`'s current layout. Returns ok, message (the uid on success), set = { [uid]: item },
-- removed = { uid }. "Place" (place), "Move" (uid, place), "PickUp" (uid; whatever is on it comes off too).
-- Owned counts are per layout: a table placed in one style is still free in another.
function ApartmentService.edit(data: any, roomList: { [string]: GridMath.Room }, action: any, a: any, b: any): (boolean, string, { [string]: GridMath.Item }, { string })
	local apt = data.Apartment
	local items = ApartmentService.layout(data)
	if action == "Place" then
		local place = sanitize(a)
		if not place then
			return false, "bad request", {}, {}
		end
		local why = GridMath.check(items, roomList, getDef, place, nil)
		if why then
			return false, why, {}, {}
		end
		if placedCount(items, place.item) >= (data.Decor[place.item] or 0) then
			return false, "none left", {}, {}
		end
		local uid = tostring(apt.NextUid)
		apt.NextUid += 1
		items[uid] = place
		return true, uid, { [uid] = place }, {}
	elseif action == "Move" then
		local place = sanitize(b)
		if typeof(a) ~= "string" or not items[a] or not place or place.item ~= items[a].item then
			return false, "bad request", {}, {}
		end
		local why = GridMath.check(items, roomList, getDef, place, a)
		if why then
			return false, why, {}, {}
		end
		(place :: any).img = (items[a] :: any).img -- a moved poster keeps its picture
		items[a] = place
		return true, a, { [a] = place }, {}
	elseif action == "PickUp" then
		if typeof(a) ~= "string" or not items[a] then
			return false, "bad request", {}, {}
		end
		items[a] = nil
		local gone = { a }
		for uid, it in items do -- surfaces don't stack (GridMath.check), so one level is all there is
			if it.parent == a then
				items[uid] = nil
				table.insert(gone, uid)
			end
		end
		return true, a, {}, gone
	end
	return false, "bad request", {}, {}
end

-- Pure: sets the picture of placed item `uid` (a Data/Furniture def with `image`, e.g. Poster) to decal id `id`
-- (user, 2026-11-01). Returns ok.
function ApartmentService.setImage(data: any, uid: any, id: any): boolean
	local it = if typeof(uid) == "string" then ApartmentService.layout(data)[uid] else nil
	local def = it and getDef(it.item)
	if not def or not def.image or typeof(id) ~= "number" or id ~= math.floor(id) or id < 1 or id > 2 ^ 53 then
		return false
	end
	(it :: any).img = id
	return true
end

-- The current style's paint (target "<room>" | "<room>/Ceiling" -> { m = material name?, c = hex? }), created on first use.
function ApartmentService.walls(data: any): { [string]: { m: string?, c: string? } }
	local apt = data.Apartment
	local style = ApartmentService.styleOf(data)
	apt.Walls = apt.Walls or {}
	apt.Walls[style] = apt.Walls[style] or {}
	return apt.Walls[style]
end

-- Pure: paints one surface in the current style: `target` = "<room>" (its walls) or "<room>/Ceiling". kind "m" =
-- a material in APT.wallMaterials, "c" = a colour in APT.wallColors; the other half of the finish stays.
-- Returns ok, message.
function ApartmentService.paint(data: any, roomList: { [string]: any }, room: any, kind: any, value: any): (boolean, string)
	local list = if kind == "m" then APT.wallMaterials elseif kind == "c" then APT.wallColors else nil
	local base = if typeof(room) == "string" then string.gsub(room, "/Ceiling$", "") else nil
	if not base or not roomList[base] or not list or not table.find(list, value) then
		return false, "bad request"
	end
	local walls = ApartmentService.walls(data)
	walls[room] = walls[room] or {}
	walls[room][kind] = value
	return true, room
end

-- A song by its path under Assets.Music ("<folder>/<Sound name>"), or nil.
function ApartmentService.song(path: any): Sound?
	if typeof(path) ~= "string" or #path > 200 then
		return nil
	end
	local at: Instance? = Paths.Assets:FindFirstChild("Music")
	for name in string.gmatch(path, "[^/]+") do
		at = at and at:FindFirstChild(name)
	end
	return if at and at:IsA("Sound") then at else nil
end

-- Pure: what the DJ booth plays (client DJController): path = a song (ApartmentService.song), "" = shuffle
-- everything in Assets.Music, "off" = the booth is silent and the normal background music plays (user,
-- 2026-11-01); `at` = the server time it was picked (everyone inside plays from there).
function ApartmentService.setDJ(data: any, path: any, now: number): boolean
	if path ~= "" and path ~= "off" and not ApartmentService.song(path) then
		return false
	end
	data.Apartment.DJ = { song = path, at = now }
	return true
end

-- Pure: gives `n` (1..999) of furniture `id` to `data` (Panel, RerollService devSet "Furniture"). Returns the
-- new owned count, or nil for an unknown id / bad amount.
function ApartmentService.give(data: any, id: any, n: any): number?
	if typeof(id) ~= "string" or not getDef(id) or typeof(n) ~= "number" or n ~= math.floor(n) or n < 1 or n > 999 then
		return nil
	end
	data.Decor[id] = (data.Decor[id] or 0) + n
	return data.Decor[id]
end

-- A style's Bux price (attribute Price on its Assets.Apartment model; none = free, like Starter).
function ApartmentService.stylePrice(style: string): number
	local m = styleModel(style)
	local price = m and m:GetAttribute("Price")
	return if typeof(price) == "number" and price > 0 then price else 0
end

-- Pure: does `data` own `style` (free styles always), given its `price`?
function ApartmentService.ownsStyle(data: any, style: string, price: number): boolean
	return price <= 0 or style == APT.defaultStyle or (typeof(data.Apartment.Styles) == "table" and data.Apartment.Styles[style] == true)
end

-- Pure: buys `style` for `price` Bux (user, 2026-11-01: Flat = 800). Owned styles are free to pick again.
-- Returns ok, message.
function ApartmentService.buyStyle(data: any, style: string, price: number): (boolean, string)
	if ApartmentService.ownsStyle(data, style, price) then
		return true, "owned"
	end
	if data.Bux < price then
		return false, "not enough bux"
	end
	data.Bux -= price
	data.Apartment.Styles = data.Apartment.Styles or {}
	data.Apartment.Styles[style] = true
	return true, "bought"
end

-- Pure: buys one `id` (Data/Furniture `price`, in Bux) into `data`. Returns ok, message.
function ApartmentService.buy(data: any, id: any): (boolean, string)
	local def = if typeof(id) == "string" then getDef(id) else nil
	local price = def and def.price
	if typeof(price) ~= "number" or price < 0 then
		return false, "not for sale"
	end
	if data.Bux < price then
		return false, "not enough bux"
	end
	data.Bux -= price
	data.Decor[id] = (data.Decor[id] or 0) + 1
	return true, string.upper(def.name)
end

-- A profile's door access, created on first use (old saves: unlocked, friends on).
export type Access = { Locked: boolean, Friends: boolean, List: { [string]: string } }
function ApartmentService.access(data: any): Access
	local apt = data.Apartment
	apt.Access = apt.Access or { Locked = false, Friends = true, List = {} }
	return apt.Access
end

-- Pure: may `visitor` come into `owner`'s apartment? `friend` = they're Roblox friends.
function ApartmentService.allowed(access: Access, owner: number, visitor: number, friend: boolean): boolean
	return visitor == owner or not access.Locked or access.List[tostring(visitor)] ~= nil or (access.Friends and friend)
end

-- Pure: one access change. "Lock" (bool), "Friends" (bool), "Allow" (UserId, display name | false = remove).
-- Adding needs a name (the server only adds players who are in it) and room on the list (D.APARTMENT.listMax).
function ApartmentService.setAccess(data: any, action: any, a: any, b: any): boolean
	local access = ApartmentService.access(data)
	if (action == "Lock" or action == "Friends") and typeof(a) == "boolean" then
		access[if action == "Lock" then "Locked" else "Friends"] = a
		return true
	elseif action == "Allow" and typeof(a) == "number" and a == math.floor(a) and a > 0 then
		local key = tostring(a)
		if b == false then
			local had = access.List[key] ~= nil
			access.List[key] = nil
			return had
		end
		local count = 0
		for _ in access.List do
			count += 1
		end
		if typeof(b) ~= "string" or #b > 40 or access.List[key] or count >= APT.listMax then
			return false
		end
		access.List[key] = b
		return true
	end
	return false
end

-- Roblox friends (a web call: cached per visitor for the session; a failed call = not friends).
local function isFriend(player: Player, owner: number): boolean
	local cache = friendCache[player] or {}
	friendCache[player] = cache
	if cache[owner] == nil then
		local ok, yes = pcall(player.IsFriendsWith, player, owner)
		cache[owner] = ok and yes == true
	end
	return cache[owner]
end

-- Can `player` come in now? (yields for the friends check when it matters)
local function mayEnter(player: Player, owner: number, data: any): boolean
	local access = ApartmentService.access(data)
	local friend = access.Locked and access.Friends and player.UserId ~= owner and isFriend(player, owner)
	return ApartmentService.allowed(access, owner, player.UserId, friend)
end

-- The owner's door + Player attributes follow their access (DoorController reads them).
local function publishAccess(owner: Player, data: any)
	local access = ApartmentService.access(data)
	owner:SetAttribute("AptLocked", access.Locked)
	owner:SetAttribute("AptFriends", access.Friends)
	owner:SetAttribute("AptList", game:GetService("HttpService"):JSONEncode(access.List))
	-- Styles you own (bought ones; free styles are always yours): BuildController's style strip.
	local owned = {}
	for style, yes in if typeof(data.Apartment.Styles) == "table" then data.Apartment.Styles else {} do
		if yes == true then
			table.insert(owned, style)
		end
	end
	owner:SetAttribute("AptStyles", table.concat(owned, ","))
	local door = doorOf[owner.UserId]
	if door then
		door:SetAttribute("Locked", access.Locked)
	end
end

local function setDoor(pad: BasePart, owner: Player?, data: any?)
	local old = doorOwner[pad]
	if old then
		doorOf[old] = nil
		local p = Players:GetPlayerByUserId(old)
		if p then
			p:SetAttribute("AptDoor", nil)
		end
	end
	doorOwner[pad] = if owner then owner.UserId else nil
	pad:SetAttribute("Owner", if owner then owner.UserId else nil)
	pad:SetAttribute("OwnerName", if owner then owner.DisplayName else nil)
	pad:SetAttribute("Locked", if owner and data then ApartmentService.access(data).Locked else nil)
	if owner then
		doorOf[owner.UserId] = pad
		owner:SetAttribute("AptDoor", pad.Name)
	end
end

local function isDoor(pad: any): boolean
	return typeof(pad) == "Instance" and pad:IsA("BasePart") and CollectionService:HasTag(pad, D.TRAVEL.tag) and pad:GetAttribute("Apartment") == true
end

local function plotFor(owner: number): BasePart?
	local plot = plotOf[owner]
	if plot then
		return plot
	end
	for _, p in CollectionService:GetTagged(APT.tag) do
		if p:IsA("BasePart") and not ownerOf[p] then
			ownerOf[p] = owner
			plotOf[owner] = p
			return p
		end
	end
	warn(`[Apartment] no free plot for {owner}: tag more {APT.tag} parts`)
	return nil
end

-- Fires the Apartment remote to everyone inside `owner`'s apartment.
local function send(owner: number, ...: any)
	local remote = Net.get(Net.Names.Apartment)
	for p, at in inside do
		if at.owner == owner then
			remote:FireClient(p, ...)
		end
	end
end

-- Built apartments -------------------------------------------------------------------------------------
local built: { [number]: Model } = {} -- owner UserId -> workspace.Apartments.<owner>

local function container(): Folder
	local f = workspace:FindFirstChild("Apartments")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Apartments"
		f.Parent = workspace
	end
	return f :: Folder
end

-- Paints target `room` ("<room>" walls / "<room>/Ceiling") of a built apartment with `paint` { m?, c? }.
local function paintBuilt(apt: Model, room: string, paint: any)
	local s = apt:FindFirstChild("Shell")
	local walls = s and s:FindFirstChild("Walls")
	if not walls or typeof(paint) ~= "table" then
		return
	end
	local material = if typeof(paint.m) == "string" then (Enum.Material :: any)[paint.m] else nil
	for _, m in walls:GetChildren() do
		if m:IsA("Model") and m:GetAttribute("Paint") == room then
			for _, p in m:GetDescendants() do
				if p:IsA("BasePart") then
					if material then
						p.Material = material
					end
					if typeof(paint.c) == "string" then
						p.Color = Color3.fromHex(paint.c)
					end
				end
			end
		end
	end
end

-- (Re)builds item `uid`'s model (none if it was picked up), then everything sitting on it.
local function drawItem(owner: number, data: any, uid: string)
	local apt, plot = built[owner], plotOf[owner]
	if not apt or not plot then
		return
	end
	for _, m in apt:GetChildren() do
		if m:GetAttribute("Uid") == uid then
			m:Destroy()
		end
	end
	local items = ApartmentService.layout(data)
	local it = items[uid]
	local cf = it and GridMath.cframe(items, shell(ApartmentService.styleOf(data)).rooms, getDef, uid)
	local template = it and Paths.Assets:WaitForChild("Furniture"):FindFirstChild(it.item)
	if cf and template and template:IsA("Model") then
		local m = template:Clone()
		m:PivotTo(plot.CFrame * cf)
		m:SetAttribute("Uid", uid)
		local def = getDef(it.item)
		if def and def.image then
			-- Pictures (Poster): a decal id shows through its thumbnail, so any public decal works.
			local id = (it :: any).img or def.image
			for _, d in m:GetDescendants() do
				if d:IsA("Decal") and d.Name == "Image" then
					d.Texture = `rbxthumb://type=Asset&id={id}&w=420&h=420`
				end
			end
		end
		m.Parent = apt
	end
	for child, c in items do
		if c.parent == uid then
			drawItem(owner, data, child)
		end
	end
end

local function unbuild(owner: number)
	local apt = built[owner]
	built[owner] = nil
	if apt then
		apt:Destroy()
	end
	-- Its dropped cans (SodaService) go with it.
	for _, c in workspace:GetChildren() do
		if c:IsA("BasePart") and c:GetAttribute("InApartment") == owner then
			c:Destroy()
		end
	end
end

-- Builds `owner`'s apartment at their plot as it is now (style, paint, furniture).
local function build(owner: number, data: any): Model?
	local plot = plotFor(owner)
	local template = styleModel(ApartmentService.styleOf(data))
	if not plot or not template then
		return nil
	end
	unbuild(owner)
	local apt = Instance.new("Model")
	apt.Name = tostring(owner)
	apt.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	local s = template:Clone()
	s.Name = "Shell"
	s:PivotTo(plot.CFrame)
	s.Parent = apt
	local exit = s:FindFirstChild("Exit")
	if exit then
		for _, p in { exit, table.unpack(exit:GetDescendants()) } do
			p:SetAttribute("ApartmentExit", true) -- hover + E = LEAVE (InteractController); the Knob counts too
		end
	end
	built[owner] = apt
	for room, paint in ApartmentService.walls(data) do
		paintBuilt(apt, room, paint)
	end
	for uid, it in ApartmentService.layout(data) do
		if not it.parent then
			drawItem(owner, data, uid) -- floor items draw what's on them
		end
	end
	apt.Parent = container()
	return apt
end

-- A moment after someone left (so the floor is still there while they're moved out): they stop getting
-- the apartment streamed, and it's taken down once nobody is in it.
local function vacated(player: Player, owner: number)
	task.delay(2, function()
		local apt = built[owner]
		if not apt then
			return
		end
		local at = inside[player]
		if not at or at.owner ~= owner then
			pcall(apt.RemovePersistentPlayer, apt, player)
		end
		for _, other in inside do
			if other.owner == owner then
				return
			end
		end
		unbuild(owner)
	end)
end

local function clearInside(player: Player)
	local at = inside[player]
	if at and at.owner == player.UserId then
		building[player.UserId] = nil -- the owner leaving ends build mode
	end
	inside[player] = nil
	if at then
		vacated(player, at.owner)
	end
	local character = player.Character
	if character then
		character:SetAttribute("InApartment", nil)
		character:SetAttribute("Building", nil)
	end
end

-- Sends `owner`'s apartment as it is now (style + layout) to `player`; the owner also gets their counts.
-- `arrive` (style swaps): the client holds still until the new apartment has streamed in, then stands there
-- (user, 2026-11-01: swapping Flat -> Starter dropped you into the void before the new floor arrived).
local function sendLoad(player: Player, owner: number, data: any, plot: BasePart, arrive: CFrame?)
	local style = ApartmentService.styleOf(data)
	Net.get(Net.Names.Apartment):FireClient(player, "Load", plot.CFrame, owner, style, ApartmentService.layout(data), if player.UserId == owner then data.Decor else nil, ApartmentService.walls(data), data.Apartment.DJ, arrive)
end

-- `player`'s owned furniture changed (bought, a code): if they're in their own apartment, its inventory updates.
function ApartmentService.ownedChanged(player: Player)
	local at = inside[player]
	local data = Paths.server("PlayerData").get(player)
	if at and at.owner == player.UserId and data then
		Net.get(Net.Names.Apartment):FireClient(player, "Owned", data.Decor)
	end
end

-- Who `player` is inside the apartment of (UserId), or nil.
function ApartmentService.insideOf(player: Player): number?
	local at = inside[player]
	return if at then at.owner else nil
end

-- Takes `player` into `owner`'s apartment behind a screen fade. `back` = where leaving puts them; `still()`
-- is re-checked right before the move (TravelService passes its refusal check). The client gets the data
-- before the move so the floor is there when they land. Nobody but the owner gets in during build mode.
-- `bypass` (staff ,apt) skips the lock / whitelist, not build mode.
function ApartmentService.enter(player: Player, owner: number, back: CFrame, still: () -> boolean, bypass: boolean?)
	if building[owner] and player.UserId ~= owner then
		Net.get(Net.Names.Apartment):FireClient(player, "Locked", "Build") -- the client says "they're building"
		return
	end
	local ownerPlayer = Players:GetPlayerByUserId(owner)
	local data = ownerPlayer and Paths.server("PlayerData").get(ownerPlayer)
	if data and not bypass and not mayEnter(player, owner, data) then
		Net.get(Net.Names.Apartment):FireClient(player, "Locked", "Locked")
		return
	end
	local plot = data and plotFor(owner)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not data or not plot or not character or not root or not root:IsA("BasePart") then
		return
	end
	local travel = Net.get(Net.Names.Travel)
	local remote = Net.get(Net.Names.Apartment)
	local start = os.clock()
	-- Carrying someone (user, 2026-11-01): they come in with you, as a visitor of their own (data,
	-- streaming, InApartment), so their client shows the apartment too. Not while the owner decorates.
	local Travel = Paths.server("TravelService")
	local f = Paths.server("FighterRegistry").get(character)
	local carried, rider = nil, nil
	if f then
		carried, rider = Travel.rider(f)
	end
	if carried and building[owner] then
		Paths.server("KnockService").drop(f) -- the body stays at the door
		carried, rider = nil, nil
	end
	local prev = inside[player]
	if prev then
		back = prev.back -- hopping between apartments: still leave to where you first came in
		clearInside(player)
		remote:FireClient(player, "Unload")
	end
	local apt = built[owner] or build(owner, data)
	if not apt then
		return
	end
	pcall(apt.AddPersistentPlayer, apt, player) -- streamed to them while they're inside
	travel:FireClient(player, "Out")
	inside[player] = { owner = owner, back = back } -- now, so edits during the fade reach them too
	sendLoad(player, owner, data, plot)
	if rider then
		if inside[rider] then
			clearInside(rider)
			remote:FireClient(rider, "Unload")
		end
		pcall(apt.AddPersistentPlayer, apt, rider)
		travel:FireClient(rider, "Out")
		inside[rider] = { owner = owner, back = back }
		sendLoad(rider, owner, data, plot)
	end
	local cf = plot.CFrame * shell(ApartmentService.styleOf(data)).spawn
	task.wait(math.max(0, D.TRAVEL.fadeOut - (os.clock() - start)))
	local at = inside[player]
	local blocked = building[owner] and player.UserId ~= owner -- build mode started during the fade
	if blocked or not still() or player.Character ~= character or plotOf[owner] ~= plot or not at or at.owner ~= owner then
		for _, p in { player, rider } do
			local was = inside[p]
			if was and was.owner == owner then
				clearInside(p)
				remote:FireClient(p, "Unload")
			end
			travel:FireClient(p, "In")
		end
		return
	end
	root.AssemblyLinearVelocity = Vector3.zero
	character:PivotTo(cf)
	character:SetAttribute("InApartment", owner)
	if f then
		Travel.bring(f, cf)
	end
	local kept = carried and f and Travel.rider(f) == carried
	if kept then
		carried.model:SetAttribute("InApartment", owner)
	end
	if rider then
		local was = inside[rider]
		if not kept and was and was.owner == owner then -- dropped during the fade: they stay outside
			clearInside(rider)
			remote:FireClient(rider, "Unload")
		end
		travel:FireClient(rider, "In")
	end
	travel:FireClient(player, "In")
end

-- Takes `player` out to where they came in (fade = the screen fade; no fade when they're being moved anyway).
function ApartmentService.leave(player: Player, fade: boolean)
	local at = inside[player]
	if not at then
		return
	end
	local travel = Net.get(Net.Names.Travel)
	local character = player.Character
	local start = os.clock()
	-- Whoever you carry in this apartment goes out with you (user, 2026-11-01).
	local Travel = Paths.server("TravelService")
	local f = character and Paths.server("FighterRegistry").get(character)
	local carried, rider = nil, nil
	if f then
		carried, rider = Travel.rider(f)
	end
	local riderAt = rider and inside[rider]
	if not riderAt or riderAt.owner ~= at.owner then
		rider = nil
	end
	local movers = { player, rider }
	for _, p in movers do
		if fade then
			travel:FireClient(p, "Out")
		end
		-- Load the map where they land first (streaming: the apartment is 3000+ studs out), like TravelService.
		pcall(p.RequestStreamAroundAsync, p, at.back.Position, 3)
	end
	if fade then
		task.wait(math.max(0, D.TRAVEL.fadeOut - (os.clock() - start)))
		if inside[player] ~= at then
			for _, p in movers do
				travel:FireClient(p, "In")
			end
			return
		end
	end
	clearInside(player)
	if rider then
		clearInside(rider)
	end
	if carried then
		carried.model:SetAttribute("InApartment", nil)
	end
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local moved = false
	if character and player.Character == character and root and root:IsA("BasePart") then
		root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(at.back)
		if f then
			Travel.bring(f, at.back)
		end
		moved = true
	end
	-- The client owns its character's physics, so it moves itself too, BEFORE dropping the apartment floor
	-- (user, 2026-11-01: owner left -> the apartment vanished and the visitor stayed put / fell).
	Net.get(Net.Names.Apartment):FireClient(player, "Unload", if moved then at.back else nil)
	if rider then
		Net.get(Net.Names.Apartment):FireClient(rider, "Unload") -- their body is on your shoulder, not theirs to move
	end
	if fade then
		for _, p in movers do
			travel:FireClient(p, "In")
		end
	end
end

-- Build mode on: everyone but the owner is put out (and kept out by enter) until it's off.
local function setBuilding(owner: Player, on: boolean)
	building[owner.UserId] = if on then true else nil
	if owner.Character then
		owner.Character:SetAttribute("Building", if on then true else nil) -- no sitting while building (SeatService / InteractController)
	end
	if on then
		for p, at in inside do
			if at.owner == owner.UserId and p ~= owner then
				task.spawn(ApartmentService.leave, p, true)
			end
		end
	end
end

-- Swaps the owner's style and rebuilds it around them (they arrive at the new style's Spawn).
local function setStyle(owner: Player, data: any, style: string)
	local plot = plotOf[owner.UserId]
	local character = owner.Character
	if not plot or not character then
		return
	end
	data.Apartment.Style = style
	local travel = Net.get(Net.Names.Travel)
	travel:FireClient(owner, "Out")
	task.wait(D.TRAVEL.fadeOut)
	if not inside[owner] or owner.Character ~= character then
		travel:FireClient(owner, "In")
		return
	end
	local apt = build(owner.UserId, data)
	for p, at in inside do -- only the owner can be in during build mode, but still
		if apt and at.owner == owner.UserId then
			pcall(apt.AddPersistentPlayer, apt, p)
		end
	end
	local arrive = plot.CFrame * shell(style).spawn
	sendLoad(owner, owner.UserId, data, plot, arrive)
	character:PivotTo(arrive)
	travel:FireClient(owner, "In")
end

function ApartmentService.init()
	local PlayerData = Paths.server("PlayerData")
	local RateLimit = Paths.server("RateLimit")
	shell(APT.defaultStyle) -- warns now if the default style's model is broken
	container() -- clients wait for workspace.Apartments

	-- The owner, inside their own apartment, with their data loaded: else nil.
	local function ownerInside(player: Player): any?
		local at = inside[player]
		local data = PlayerData.get(player)
		return if at and at.owner == player.UserId and data then data else nil
	end

	local furnish = Net.get(Net.Names.Furnish)
	furnish.OnServerEvent:Connect(function(player: Player, action: unknown, a: unknown, b: unknown)
		if not RateLimit.take(player, "Furnish") then
			furnish:FireClient(player, false, "SLOW DOWN")
			return
		end
		local data = ownerInside(player)
		if not data or not building[player.UserId] then
			furnish:FireClient(player, false, "NOT IN BUILD MODE")
			return
		end
		if action == "Buy" then
			local ok, message = ApartmentService.buy(data, a)
			furnish:FireClient(player, ok, message, "Buy")
			if ok then
				player:SetAttribute("Bux", data.Bux)
				ApartmentService.ownedChanged(player)
			end
			return
		end
		local ok, message, set, gone = ApartmentService.edit(data, shell(ApartmentService.styleOf(data)).rooms, action, a, b)
		furnish:FireClient(player, ok, message, action)
		for uid, it in set do
			drawItem(player.UserId, data, uid)
			send(player.UserId, "Set", uid, it)
		end
		for _, uid in gone do
			drawItem(player.UserId, data, uid) -- picked up: its model goes
			send(player.UserId, "Remove", uid)
		end
	end)

	local TravelService = Paths.server("TravelService")
	local remote = Net.get(Net.Names.Apartment)
	local function toast(player: Player, why: string)
		remote:FireClient(player, "Locked", why)
	end

	-- Puts out every visitor of `owner` who isn't allowed in any more (after a lock / whitelist change).
	local function recheck(owner: Player, data: any)
		for p, at in inside do
			if at.owner == owner.UserId and p ~= owner then
				task.spawn(function()
					if not mayEnter(p, owner.UserId, data) and inside[p] == at then
						ApartmentService.leave(p, true)
					end
				end)
			end
		end
	end

	-- Door / access actions (the owner needn't be inside). True = handled.
	local function doorAction(player: Player, action: unknown, value: unknown, b: unknown, c: unknown): boolean
		local data = PlayerData.get(player)
		if action == "Claim" and isDoor(value) and data then
			local pad = value :: BasePart
			if doorOwner[pad] then
				toast(player, "Taken")
			elseif doorOf[player.UserId] then
				toast(player, "HaveDoor")
			else
				local still = TravelService.check(player, pad)
				if still then
					setDoor(pad, player, data)
					publishAccess(player, data)
					ApartmentService.enter(player, player.UserId, TravelService.arrival(pad), still)
				end
			end
		elseif action == "Visit" and isDoor(value) then
			local pad = value :: BasePart
			local owner = doorOwner[pad]
			local still = owner and TravelService.check(player, pad)
			if owner and still then
				ApartmentService.enter(player, owner, TravelService.arrival(pad), still)
			end
		elseif action == "Unclaim" then
			local pad = doorOf[player.UserId]
			if pad then
				setDoor(pad, nil)
			end
		elseif (action == "Lock" or action == "Friends" or action == "Allow") and data then
			if action == "Allow" and value ~= nil and b ~= false then
				-- Only people in this server can be added (their name comes from here, not the client).
				local target = if typeof(value) == "number" then Players:GetPlayerByUserId(value) else nil
				b = if target and target ~= player then target.DisplayName else nil
			end
			if ApartmentService.setAccess(data, action, value, b) then
				publishAccess(player, data)
				recheck(player, data)
			end
		else
			return false
		end
		return true
	end

	remote.OnServerEvent:Connect(function(player: Player, action: unknown, value: unknown, b: unknown, c: unknown)
		if not RateLimit.take(player, "Apartment") then
			return
		end
		if doorAction(player, action, value, b, c) or not inside[player] then
			return
		end
		if action == "Leave" then
			ApartmentService.leave(player, true)
			return
		end
		local data = ownerInside(player)
		if not data then
			return
		end
		if action == "Build" and typeof(value) == "boolean" then
			setBuilding(player, value)
		elseif action == "Style" and building[player.UserId] and styleModel(value) and value ~= ApartmentService.styleOf(data) then
			-- Not owned yet = buying it (the strip asks first).
			local ok, message = ApartmentService.buyStyle(data, value :: string, ApartmentService.stylePrice(value :: string))
			if not ok then
				furnish:FireClient(player, false, message, "Style")
				return
			end
			if message == "bought" then
				player:SetAttribute("Bux", data.Bux)
				publishAccess(player, data) -- AptStyles
				furnish:FireClient(player, true, string.upper(value :: string), "BuyStyle")
			end
			setStyle(player, data, value :: string)
		elseif action == "DJ" then
			-- The owner picked the booth's music (hover + E on it); not build-mode only.
			if ApartmentService.setDJ(data, value, workspace:GetServerTimeNow()) then
				send(player.UserId, "DJ", data.Apartment.DJ)
			end
		elseif action == "Poster" then
			-- (uid, decal id): the owner set a poster's picture (hover + E on it); not build-mode only.
			if ApartmentService.setImage(data, value, b) then
				drawItem(player.UserId, data, value :: string)
				send(player.UserId, "Set", value, ApartmentService.layout(data)[value :: string])
			end
		elseif action == "Paint" and building[player.UserId] then
			-- (room, kind, value): everyone inside sees it (only the owner can be, in build mode, but still).
			if ApartmentService.paint(data, shell(ApartmentService.styleOf(data)).rooms, value, b, c) then
				local apt = built[player.UserId]
				if apt then
					paintBuilt(apt, value :: string, ApartmentService.walls(data)[value :: string])
				end
				send(player.UserId, "Paint", value, ApartmentService.walls(data)[value :: string])
			end
		end
	end)

	PlayerData.onLoaded(function(player, data)
		publishAccess(player, data)
	end)

	local function onPlayer(player: Player)
		-- Respawning puts you back on the map; the client drops the apartment it was showing.
		player.CharacterAdded:Connect(function()
			if inside[player] then
				clearInside(player)
				Net.get(Net.Names.Apartment):FireClient(player, "Unload")
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		clearInside(player) -- the apartment they were in comes down if they were the last one there
		building[player.UserId] = nil
		friendCache[player] = nil
		local door = doorOf[player.UserId]
		if door then
			setDoor(door, nil)
		end
		local plot = plotOf[player.UserId]
		if plot then
			-- Everyone visiting is put out, then the plot is free for the next owner.
			for p, at in inside do
				if at.owner == player.UserId then
					task.spawn(ApartmentService.leave, p, true)
				end
			end
			plotOf[player.UserId] = nil
			ownerOf[plot] = nil -- the built apartment (and its cans) comes down once the visitors are out (vacated)
		end
	end)
end

return ApartmentService
