--!strict
-- Saved player data through ProfileStore (session-locked: one server owns a player's data
-- at a time, so rejoining fast can't duplicate spins). Robux purchases also land here:
-- systems register a product with onProduct, and ProcessReceipt only reports a purchase
-- granted once its PurchaseId is confirmed SAVED (ProfileStore's PurchaseIdCache pattern).
local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local SCHEMA_VERSION = 11
local PURCHASE_ID_CACHE_SIZE = 100

local TEMPLATE = {
	SchemaVersion = SCHEMA_VERSION,
	Spins = D.STARTING_SPINS,
	-- What you wear and fight with:
	-- { Style = name ("" = D.DEFAULT_STYLE), Traits = { trait id or "" }, Locks = { bool per trait },
	--   Appearance = slot -> item id (Data/Appearance; missing slots get a free roll on load),
	--   Gender = one of D.GENDERS ("" = random on load),
	--   Shelf = gender -> { perGender slot -> id } (hair kept for the gender you're not wearing) }.
	Loadout = {},
	-- Locker (user, 2026-10-22): slots that each keep ONE item you own, so you can own two Mythic hats and
	-- swap between them (RerollService: Store / Swap). A slot is { Kind = "" } (empty),
	-- { Kind = "Look", Slot = appearance slot, Id = item id } or { Kind = "Style", Style, Traits, Locks }.
	-- D.LOCKER_SLOTS free + BuxSlots (bought with Bux, D.LOCKER_BUX_PRICES) + ExtraSlots (Robux); fitLocker keeps it that long.
	Locker = {},
	ExtraSlots = 0,
	BuxSlots = 0,
	PurchaseIdCache = {},
	Bux = D.STARTING_BUX, -- soft currency for the (future) clothing store; replicates as the "Bux" attribute
	Codes = {}, -- code -> true once redeemed (CodeService)
	Decor = table.clone(D.APARTMENT.starter), -- furniture id (Data/Furniture) -> how many you own (placed or not)
	-- Your apartment (ApartmentService): Style = the Assets.Apartment model you show; Layouts = style -> placed
	-- items, uid (string) -> { item, room?, parent?, x, z, rot } (Shared/GridMath). Uids are unique across styles.
	-- Walls = style -> room -> { m = material?, c = hex? } (wall paint; old profiles get it lazily, no migration).
	-- DJ = the booth's pick { song = "<Music folder>/<Sound>" | "" (shuffle all), at = server time }, nil = shuffle.
	Apartment = { Style = D.APARTMENT.defaultStyle, Layouts = {}, NextUid = 1, Walls = {} },
	Emotes = {}, -- wheel slot n -> Data/Emotes id; empty / removed ones get a free roll on load
	Nick = "", -- ,nick name (AdminService); "" = your DisplayName
	NickLockRank = 0, -- rank (Roles.order index) of whoever nicked you (,nick <player>); 0 = unlocked. Only that rank and up may change it (AdminService)
	Height = 1, -- body scale the owner set (HeightService, D.HEIGHT); 1 = normal
	Title = "", -- nametag title the owner gave (Owner tab): "" = their role's title (RoleService), "none" = no title, else a Data/Titles id
}

local profiles: { [Player]: any } = {}
local loadedHooks: { (Player, any) -> () } = {}
local products: { [number]: (player: Player, data: any) -> () } = {}

-- Versioned migrations: migrations[n] upgrades a version n-1 profile to version n.
local migrations: { [number]: (data: any) -> () } = {
	-- v2 (2026-10-06): shirts/pants were auto-rolled for everyone; unset now means "wear your own
	-- Roblox avatar's", so clear the rolled ones (in every saved look) and players start on theirs.
	[2] = function(data)
		local looks = { data.Appearance }
		for _, look in data.StoredLooks or {} do
			table.insert(looks, look)
		end
		for _, look in looks do
			look.Shirt = nil
			look.Pants = nil
		end
	end,
	-- v3 (2026-10-10): Down to Earth Hair was removed from the game; owners get a fresh hair roll.
	[3] = function(data)
		local looks = { data.Appearance }
		for _, look in data.StoredLooks or {} do
			table.insert(looks, look)
		end
		for _, look in looks do
			if look.Hair == 1772336109 then
				look.Hair = nil
			end
		end
	end,
	-- v4 (2026-10-13): style slots. The one style + traits you had become slot 1.
	[4] = function(data)
		data.StyleSlots = { { Style = data.Style or "", Traits = data.PerkSlots or {} } }
		data.Style = nil
		data.PerkSlots = nil
	end,
	-- v5 (2026-10-18): titles moved to the owner; every title the Dev tab gave is taken back (user).
	-- Back to their role's title.
	[5] = function(data)
		data.Title = ""
	end,
	-- v6 (2026-10-22): style slots became lockers that also hold a look. Every locker starts with the
	-- look you wore; the other gender's saved look only keeps its hair (hair is per gender, the rest
	-- carries over).
	[6] = function(data)
		local shelf = {}
		for gender, look in data.StoredLooks or {} do
			shelf[gender] = { Hair = look.Hair }
		end
		data.Lockers = {}
		for i, slot in data.StyleSlots or {} do
			data.Lockers[i] = {
				Style = slot.Style,
				Traits = slot.Traits,
				Locks = {},
				Appearance = table.clone(data.Appearance or {}),
				Gender = data.Gender or "",
				Shelf = HttpService:JSONDecode(HttpService:JSONEncode(shelf)),
			}
		end
		data.EquippedLocker = data.EquippedSlot or 1
		data.StyleSlots = nil
		data.EquippedSlot = nil
		data.Appearance = nil
		data.Gender = nil
		data.StoredLooks = nil
	end,
	-- v7 (2026-10-22, same day; user: "lockers are supposed to store individual items"): the equipped
	-- v6 locker is what you wear; every other locker that had a style or a trait keeps it as a stored
	-- Style item (their looks were copies of yours).
	[7] = function(data)
		local lockers = data.Lockers or {}
		local worn = lockers[data.EquippedLocker or 1] or lockers[1] or {}
		data.Loadout = worn
		data.Locker = {}
		for _, locker in lockers do
			local hasTrait = false
			for _, id in locker.Traits or {} do
				hasTrait = hasTrait or id ~= ""
			end
			if locker ~= worn and ((locker.Style or "") ~= "" or hasTrait) then
				table.insert(data.Locker, { Kind = "Style", Style = locker.Style or "", Traits = locker.Traits or {}, Locks = locker.Locks or {} })
			end
		end
		data.Lockers = nil
		data.EquippedLocker = nil
	end,
	-- v8 (2026-10-31): apartments. Decor went from id -> true to id -> owned count, and everyone gets the
	-- starter furniture (D.APARTMENT.starter).
	[8] = function(data)
		local decor = data.Decor or {}
		for id, v in decor do
			decor[id] = if v == true then 1 elseif typeof(v) == "number" then v else nil
		end
		for id, n in D.APARTMENT.starter do
			decor[id] = math.max(decor[id] or 0, n)
		end
		data.Decor = decor
	end,
	-- v9 (2026-10-31, same day): apartment styles. The one layout (Apartment.Items) becomes the default style's.
	[9] = function(data)
		local apt = data.Apartment or {}
		apt.Layouts = apt.Layouts or {}
		if apt.Items then
			apt.Layouts[D.APARTMENT.defaultStyle] = apt.Items
			apt.Items = nil
		end
		apt.Style = apt.Style or D.APARTMENT.defaultStyle
		apt.NextUid = apt.NextUid or 1
		data.Apartment = apt
	end,
	-- v10 (2026-10-31, same day): furniture "TV" was renamed "Monitor" (a new, 2x "TV" took the id). Owned and
	-- placed ones become Monitors.
	[10] = function(data)
		local decor = data.Decor or {}
		if decor.TV then
			decor.Monitor = (decor.Monitor or 0) + decor.TV
			decor.TV = nil
		end
		for _, items in (data.Apartment or {}).Layouts or {} do
			for _, it in items do
				if it.item == "TV" then
					it.item = "Monitor"
				end
			end
		end
	end,
	-- v11 (2026-11-01): walls got a 1-stud grid (was 2, GridMath.WALL_CELL). Placed wall items' x / z double,
	-- which is the exact same spot on the finer grid.
	[11] = function(data)
		for _, items in (data.Apartment or {}).Layouts or {} do
			for _, it in items do
				if it.wall and typeof(it.x) == "number" and typeof(it.z) == "number" then
					it.x, it.z = it.x * 2, it.z * 2
				end
			end
		end
	end,
}

local PlayerData = {}

local EMPTY_TRAITS = function(): ({ string }, { boolean })
	local traits, locks = {}, {}
	for t = 1, D.PERK_SLOTS do
		traits[t], locks[t] = "", false
	end
	return traits, locks
end

-- Pads / trims a style's Traits + Locks to D.PERK_SLOTS.
local function fitTraits(s: any)
	s.Style = if typeof(s.Style) == "string" then s.Style else ""
	s.Traits = s.Traits or {}
	s.Locks = s.Locks or {}
	for t = 1, math.max(#s.Traits, #s.Locks, D.PERK_SLOTS) do
		s.Traits[t] = if t <= D.PERK_SLOTS then s.Traits[t] or "" else nil
		s.Locks[t] = if t <= D.PERK_SLOTS then s.Locks[t] == true else nil
	end
end

-- A worn style that has nothing in it (default style, no traits): storing it is pointless.
function PlayerData.blankStyle(s: any): boolean
	for _, id in s.Traits do
		if id ~= "" then
			return false
		end
	end
	return s.Style == ""
end

function PlayerData.clearStyle(s: any)
	s.Style = ""
	s.Traits, s.Locks = EMPTY_TRAITS()
end

-- Fills the Loadout's fields, and makes the Locker at least D.LOCKER_SLOTS + ExtraSlots long (empty slots
-- past that are trimmed; slots holding an item never are).
function PlayerData.fitLocker(data: any)
	local worn = data.Loadout
	fitTraits(worn)
	worn.Appearance = worn.Appearance or {}
	worn.Gender = if typeof(worn.Gender) == "string" then worn.Gender else ""
	worn.Shelf = worn.Shelf or {}
	local count = D.LOCKER_SLOTS + (data.BuxSlots or 0) + data.ExtraSlots
	for i = 1, math.max(count, #data.Locker) do
		local item = data.Locker[i]
		if typeof(item) ~= "table" or (item.Kind ~= "Look" and item.Kind ~= "Style") then
			item = { Kind = "" }
		elseif item.Kind == "Style" then
			fitTraits(item)
		end
		data.Locker[i] = item
	end
	for i = #data.Locker, count + 1, -1 do
		if data.Locker[i].Kind ~= "" then
			break
		end
		data.Locker[i] = nil
	end
end

-- What you wear and fight with.
function PlayerData.worn(data: any): any
	return data.Loadout
end

local function migrate(data: any)
	local version = data.SchemaVersion or 1
	while version < SCHEMA_VERSION do
		version += 1
		local step = migrations[version]
		if step then
			step(data)
		end
	end
	data.SchemaVersion = SCHEMA_VERSION
	-- LOCKER_SLOTS / PERK_SLOTS may change: Reconcile never resizes an existing list.
	PlayerData.fitLocker(data)
end
PlayerData.migrate = migrate -- tests

-- The player's live saved data, or nil while it is still loading.
function PlayerData.get(player: Player): any?
	local profile = profiles[player]
	return if profile and profile:IsActive() then profile.Data else nil
end

-- `grant(player, data)` runs once per purchase of `productId`.
function PlayerData.onProduct(productId: number, grant: (player: Player, data: any) -> ())
	products[productId] = grant
end

local function purchaseIdCheckAsync(profile: any, purchaseId: string, grant: () -> ()): Enum.ProductPurchaseDecision
	if not profile:IsActive() then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local cache = profile.Data.PurchaseIdCache
	if not table.find(cache, purchaseId) then
		local ok, err = pcall(grant)
		if not ok then
			warn(`[PlayerData] failed to grant purchase {purchaseId}: {err}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		while #cache >= PURCHASE_ID_CACHE_SIZE do
			table.remove(cache, 1)
		end
		table.insert(cache, purchaseId)
	end

	local function saved(): boolean
		local savedCache = profile.LastSavedData and profile.LastSavedData.PurchaseIdCache
		return savedCache ~= nil and table.find(savedCache, purchaseId) ~= nil
	end
	while profile:IsActive() do
		if saved() then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		local last = profile.LastSavedData
		profile:Save()
		if profile.LastSavedData == last then
			profile.OnAfterSave:Wait()
		end
		if saved() then
			return Enum.ProductPurchaseDecision.PurchaseGranted
		end
		task.wait(10)
	end
	return Enum.ProductPurchaseDecision.NotProcessedYet
end

local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local grant = products[receipt.ProductId]
	if not player or not grant then
		if not grant then
			warn(`[PlayerData] no grant for product {receipt.ProductId}`)
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local profile = profiles[player]
	while profile == nil and player.Parent == Players do
		task.wait()
		profile = profiles[player]
	end
	if profile == nil then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	return purchaseIdCheckAsync(profile, receipt.PurchaseId, function()
		grant(player, profile.Data)
	end)
end

-- Extra `fn(player, data)` to run when a player's data is ready (register before init).
function PlayerData.onLoaded(fn: (Player, any) -> ())
	table.insert(loadedHooks, fn)
end

-- `onLoaded(player, data)` runs once a player's data is ready.
function PlayerData.init(onLoaded: (Player, any) -> ())
	-- Required here, not at the top: ProfileStore starts loops on require (keeps tests side-effect free).
	local store = Paths.server("ProfileStore").New("MidoriPlayer", TEMPLATE)
	local function load(player: Player)
		local profile = store:StartSessionAsync(`Player_{player.UserId}`, {
			Cancel = function()
				return player.Parent ~= Players
			end,
		})
		if profile == nil then
			player:Kick("Your data failed to load, please rejoin.")
			return
		end
		profile:AddUserId(player.UserId)
		profile:Reconcile()
		migrate(profile.Data)
		profile.OnSessionEnd:Connect(function()
			profiles[player] = nil
			player:Kick("Your data was loaded on another server, please rejoin.")
		end)
		if player.Parent ~= Players then
			profile:EndSession()
			return
		end
		profiles[player] = profile
		player:SetAttribute("Bux", profile.Data.Bux)
		onLoaded(player, profile.Data)
		for _, fn in loadedHooks do
			task.spawn(fn, player, profile.Data)
		end
	end
	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		task.spawn(load, player)
	end
	Players.PlayerRemoving:Connect(function(player)
		local profile = profiles[player]
		if profile then
			profile:EndSession()
		end
	end)
	MarketplaceService.ProcessReceipt = processReceipt
end

return PlayerData
