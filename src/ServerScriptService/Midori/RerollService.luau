--!strict
-- Single rerolls from the P menu: ONE appearance slot (Data/Appearance), your style or your traits
-- (PerkRollService), or ONE emote wheel slot ("Emote<n>", Data/Emotes,
-- replicated as "Emote<n>" attributes). Each costs 1 reroll (traits: D.TRAIT_LOCK_MULT ^ locked traits)
-- (saved as Spins) unless free (D.FREE_SPINS, or a role with freeSpins), and only out of combat mode
-- and Idle. Picks go through Shared/Rarity, only from items your gender can have, and never land on
-- what you already have. Switching gender is free and keeps everything except `perGender` slots (hair):
-- those are shelved per gender in Loadout.Shelf. The Locker stores single items to swap in (store / swap).
-- Devs (RoleService: a Dev role, or anyone in Studio) can set any slot to any catalog id of the right type.
-- Appearance is saved as slot -> item id and put on the character with Humanoid:ApplyDescription.
-- Replicates as Player attributes "Look_<slot>" (item id), "Gender" and "Dev"; lockers via PerkRollService.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")
local InsertService = game:GetService("InsertService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Appearance = Paths.data("Appearance")
local Enums = Paths.shared("Enums")
local Net = Paths.shared("Net")
local Rarity = Paths.shared("Rarity")
local Registry = Paths.server("FighterRegistry")
local Fighter = Paths.server("Fighter")
local PlayerData = Paths.server("PlayerData")
local RateLimit = Paths.server("RateLimit")
local PerkRollService = Paths.server("PerkRollService")
local RoleService = Paths.server("RoleService")
local Titles = Paths.data("Titles")
local Emotes = Paths.data("Emotes")
local NametagService = require(game:GetService("ServerScriptService"):WaitForChild("NametagService"))

-- Accessory fields take a comma list of ids as a string; Face/Shirt/Pants take a number.
local ACCESSORY_FIELDS = {
	HatAccessory = true, HairAccessory = true, FaceAccessory = true, BackAccessory = true,
	NeckAccessory = true, ShouldersAccessory = true, FrontAccessory = true, WaistAccessory = true,
}
-- An accessory only loads from the HumanoidDescription field that matches its catalog type ("Asset type
-- does not match requested type" otherwise), and UGC is often Neck / Shoulder / Front / Waist. So every
-- accessory goes to the field of its real AssetTypeId, whatever menu slot holds it. Ear (57) / Eye (58)
-- have no field of their own: best effort in FaceAccessory.
local FIELD_BY_ASSET_TYPE = {
	[8] = "HatAccessory", [41] = "HairAccessory", [42] = "FaceAccessory", [43] = "NeckAccessory",
	[44] = "ShouldersAccessory", [45] = "FrontAccessory", [46] = "BackAccessory", [47] = "WaistAccessory",
	[57] = "FaceAccessory", [58] = "FaceAccessory",
}
local SKIN_FIELDS = { "HeadColor", "TorsoColor", "LeftArmColor", "RightArmColor", "LeftLegColor", "RightLegColor" }
local MAX_ASSET_ID = 2 ^ 53
local HEADLESS = "Headless" -- special Face id (Data/Appearance)
local CLOTHES = { Shirt = 11, Pants = 12 } -- dev-set clothing: look key / HumanoidDescription field -> AssetTypeId

local rng = Random.new()

-- Catalog AssetTypeId of `id`, cached for the server's life (types never change). Retries: the catalog
-- call fails or throttles now and then, which made some dev SETs come back INVALID. nil = unknown.
local assetTypes: { [number]: number } = {}
local function assetType(id: number): number?
	local known = assetTypes[id]
	if known then
		return known
	end
	for attempt = 1, 3 do
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, Enum.InfoType.Asset)
		if ok and info and typeof(info.AssetTypeId) == "number" then
			assetTypes[id] = info.AssetTypeId
			return info.AssetTypeId
		end
		if attempt < 3 then
			task.wait(attempt * 0.5)
		end
	end
	return nil
end
local applying: { [Player]: true } = {}

local RerollService = {}

-- Rerolls cost nothing: everyone while D.FREE_SPINS, or this player's role has freeSpins (RoleService
-- publishes it as the server-set "FreeSpins" attribute). Never touches the saved Spins.
local function free(player: Player): boolean
	return D.FREE_SPINS or player:GetAttribute("FreeSpins") == true
end

local function isDev(player: Player): boolean
	return RoleService.isDev(player)
end


-- `base` with the saved look on top (unknown or 0 ids = nothing in that slot). `typeOf` (an id's
-- AssetTypeId, may yield) routes each accessory to its type's field; without it (tests) an accessory
-- uses its slot's field. Every accessory field is rebuilt from the look, so leftovers from the
-- player's own avatar don't stick around. Female wears
-- D.FEMALE_TORSO as the Torso body part (R6: ApplyDescription turns it into a CharacterMesh).
-- Shirt/pants aren't appearance slots (no rerolls, not in the Catalog): everyone wears their gender's
-- D.UNIFORM unless a dev set look.Shirt / look.Pants (an asset id; 0 = nothing) (user, 2026-10-17).
function RerollService.describe(base: HumanoidDescription, look: { [string]: any }, gender: string?, typeOf: ((number) -> number?)?): HumanoidDescription
	local desc = base:Clone()
	desc.Torso = if gender == "Female" then D.FEMALE_TORSO else 0
	local uniform = D.UNIFORM[gender or "Male"] or D.UNIFORM.Male
	for field in CLOTHES do
		local id = look[field]
		;(desc :: any)[field] = if typeof(id) == "number" then id else uniform[field]
	end
	local accessories: { [string]: { string } } = {}
	for field in ACCESSORY_FIELDS do
		accessories[field] = {}
	end
	for _, slot in Appearance.order do
		local id = look[slot]
		local def = Appearance.slots[slot]
		local field = def.field
		if slot == "SkinTone" then
			if typeof(id) == "string" then
				local color = BrickColor.new(id).Color
				for _, f in SKIN_FIELDS do
					(desc :: any)[f] = color
				end
			end
		elseif field then
			local n = if typeof(id) == "number" then id else 0
			if ACCESSORY_FIELDS[field] then
				if n ~= 0 then
					local t = typeOf and typeOf(n)
					table.insert(accessories[t and FIELD_BY_ASSET_TYPE[t] or field], tostring(n))
				end
			else
				(desc :: any)[field] = n
			end
		end
	end
	for field, ids in accessories do
		(desc :: any)[field] = table.concat(ids, ",")
	end
	return desc
end

-- The R6 torso mesh of D.FEMALE_TORSO, loaded once (nil if the load failed; retried next apply).
local femaleTorso: CharacterMesh? = nil
local function femaleTorsoMesh(): CharacterMesh?
	if not femaleTorso then
		local ok, model = pcall(InsertService.LoadAsset, InsertService, D.FEMALE_TORSO)
		if ok then
			for _, d in model:GetDescendants() do
				if d:IsA("CharacterMesh") and d.BodyPart == Enum.BodyPart.Torso then
					femaleTorso = d:Clone()
					break
				end
			end
			model:Destroy()
		end
		if not femaleTorso then
			warn(`[RerollService] couldn't load the female torso {D.FEMALE_TORSO}`)
		end
	end
	return femaleTorso
end

local function apply(player: Player)
	local data = PlayerData.get(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not data or not character or not humanoid then
		return
	end
	-- CharacterAdded can fire before the character is parented. Bounded: a character destroyed
	-- unparented never fires AncestryChanged again, which used to hang here forever.
	local waitUntil = os.clock() + 10
	while character.Parent == nil and player.Character == character and os.clock() < waitUntil do
		task.wait()
	end
	if character.Parent == nil or player.Character ~= character then
		return
	end
	local L = PlayerData.worn(data)
	-- ponytail: one bad (moderated/deleted) id fails the whole apply; drop that id per slot if it ever happens.
	local ok, err = pcall(function()
		humanoid:ApplyDescription(RerollService.describe(humanoid:GetAppliedDescription(), L.Appearance, L.Gender, assetType))
	end)
	if not ok then
		warn(`[RerollService] appearance failed for {player.Name}: {err}`)
	end
	-- Headless: the head (and its face) go invisible; accessories on it still show.
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		head.Transparency = if L.Appearance.Face == HEADLESS then 1 else 0
		local face = head:FindFirstChild("face")
		if face and face:IsA("Decal") then
			face.Transparency = head.Transparency
		end
	end
	-- Torso mesh check: ApplyDescription should have handled it; if it didn't, fix it by hand.
	local torsoMesh: CharacterMesh? = nil
	for _, m in character:GetChildren() do
		if m:IsA("CharacterMesh") and m.BodyPart == Enum.BodyPart.Torso then
			torsoMesh = m
		end
	end
	if L.Gender == "Female" and not torsoMesh then
		local mesh = femaleTorsoMesh()
		if mesh then
			mesh:Clone().Parent = character
		end
		warn(`[RerollService] ApplyDescription gave {player.Name} no torso mesh; added it by hand`)
	elseif L.Gender ~= "Female" and torsoMesh then
		torsoMesh:Destroy()
	end
end

local function publish(player: Player, data: any)
	local L = PlayerData.worn(data)
	for _, slot in Appearance.order do
		player:SetAttribute("Look_" .. slot, L.Appearance[slot])
	end
	for field in CLOTHES do
		player:SetAttribute("Look_" .. field, L.Appearance[field]) -- nil = the uniform
	end
	player:SetAttribute("Gender", L.Gender)
end

-- Every apply goes through here: one runs at a time per player, and a request made during one
-- runs once more after it, so the newest look always lands last (spawn, avatar fetch, data load
-- and rerolls used to race, and an older ApplyDescription could finish last).
local reapply: { [Player]: true } = {}
local function requestApply(player: Player)
	if applying[player] then
		reapply[player] = true
		return
	end
	applying[player] = true
	repeat
		reapply[player] = nil
		local ok, err = pcall(apply, player)
		if not ok then
			warn(`[RerollService] apply failed for {player.Name}: {err}`)
		end
	until not reapply[player] or player.Parent ~= Players
	applying[player] = nil
	reapply[player] = nil
end

-- Saves and wears the new look.
local function commit(player: Player, data: any)
	publish(player, data)
	requestApply(player)
end
RerollService.commit = commit -- CodeService: a code that changes your look (headless)

-- Every style, as rarity items ({ id = name, rarity }); a style module may set `rarity`, and
-- `rollable = false` keeps it out of rolls (dev-only styles, e.g. BanHammer).
function RerollService.stylePool(): { any }
	local pool = {}
	for _, name in Paths.styleIds() do
		if Paths.style(name).rollable == false then
			continue
		end
		table.insert(pool, { id = name, rarity = Paths.style(name).rarity or "Common" })
	end
	return pool
end

-- One roll of an appearance slot for `gender`: a rarity pick that never repeats `exclude` (the current
-- id), where the slot's `none` chance is a share of the non-Mythic/Legendary part (skipped when you
-- already have nothing). `pool` = Appearance.eligible(slot, gender) when the caller already has it (auto
-- rolls run this up to D.AUTO_ROLL_MAX times in one request: build the list once, not every roll).
function RerollService.rollSlot(slot: string, gender: string?, random: Random, exclude: any?, pool: { any }?): any?
	local def = Appearance.slots[slot]
	-- Mythic/Legendary keep their flat per-reroll chance; `none` only shares the rest.
	local item = Rarity.pick(pool or Appearance.eligible(slot, gender), random, exclude, if exclude ~= 0 then def.none else nil)
	if item == Rarity.NONE then
		return 0
	end
	return if item then item.id elseif def.none then 0 else nil
end

-- Data loaded, and out of combat mode and Idle. A change mid-apply is fine (user, 2026-10-17: several
-- rerolls at once): requestApply runs once more after the current apply, so the newest look lands last.
local function canChange(player: Player): any?
	local data = PlayerData.get(player)
	if not data then
		return nil
	end
	local f = Registry.getByPlayer(player)
	if f and Fighter.loadoutLocked(f, workspace:GetServerTimeNow()) then
		return nil
	end
	return data
end

-- Loadout keys: "Style" = your style, "Traits" = all your unlocked traits (rolled together).
-- Returns the Loadout and whether it's the traits, or nil for a bad key.
local function loadoutSlot(data: any, key: any): (any?, boolean)
	if key == "Style" or key == "Traits" then
		return PlayerData.worn(data), key == "Traits"
	end
	return nil, false
end

-- Emote keys: "Emote<n>" = wheel slot n (1..Emotes.SLOTS), or nil for a bad key.
local function emoteSlot(key: any): number?
	local n = if typeof(key) == "string" then tonumber(string.match(key, "^Emote(%d+)$")) else nil
	return if n and n >= 1 and n <= Emotes.SLOTS then n else nil
end

-- What slot `n` can roll: every emote not held in another slot (no doubles on the wheel).
function RerollService.emotePool(held: { string }, n: number): { any }
	local pool = {}
	for _, item in Emotes.items do
		if not table.find(held, item.id) or held[n] == item.id then
			table.insert(pool, item)
		end
	end
	return pool
end

-- Free roll for every empty slot, or one holding an emote no longer in Data/Emotes or a double (new players).
function RerollService.fillEmotes(data: any, random: Random)
	for n = 1, Emotes.SLOTS do
		local known = false
		for _, item in Emotes.items do
			known = known or item.id == data.Emotes[n]
		end
		if not known or table.find(data.Emotes, data.Emotes[n]) < n then
			data.Emotes[n] = "" -- keeps the array dense while the others fill
		end
	end
	for n = 1, Emotes.SLOTS do
		if data.Emotes[n] == "" then
			local item = Rarity.pick(RerollService.emotePool(data.Emotes, n), random)
			data.Emotes[n] = if item then item.id else ""
		end
	end
end

local function publishEmotes(player: Player, data: any)
	for n = 1, Emotes.SLOTS do
		player:SetAttribute("Emote" .. n, data.Emotes[n])
	end
end

local function setLoadout(slot: any, traits: boolean, value: any)
	if traits then
		slot.Traits = table.clone(value)
	else
		slot.Style = value
	end
end

-- Rerolled traits as a single rarity: the best one rolled (nil = nothing at all). Locked traits
-- (`locks[t]`) didn't roll, so they never count.
local function bestTrait(ids: { string }, locks: { boolean }?): string?
	local best: string? = nil
	for t, id in ids do
		local rarity = if id ~= "" and not (locks and locks[t]) then Paths.perk(id).rarity else nil
		if rarity and (not best or table.find(Rarity.ORDER, rarity) > table.find(Rarity.ORDER, best)) then
			best = rarity
		end
	end
	return best
end

-- Every trait a roll for `style` can land on, as rarity items, plus nothing ("").
local function traitItems(style: string): { any }
	local items = { { id = "" } }
	for rarity, ids in PerkRollService.pool(style) do
		for _, id in ids do
			table.insert(items, { id = id, rarity = rarity })
		end
	end
	return items
end

-- Undo: per player, key (an appearance slot or a loadout key) -> what the last reroll of it replaced.
-- Session only. Undoing swaps it back for free (the reroll stays spent, so undo can't be used to
-- reroll for free); pressing again swaps forward, so you can compare the two. The "Undo_<key>"
-- attribute ("UNDO"/"REDO", nil = nothing to undo) drives the menu's button.
local undo: { [Player]: { [string]: any } } = {}

local function remember(player: Player, key: string, previous: any)
	undo[player] = undo[player] or {}
	undo[player][key] = previous
	player:SetAttribute("Undo_" .. key, "UNDO")
end

local function forget(player: Player, keys: { string })
	for _, key in keys do
		if undo[player] then
			undo[player][key] = nil
		end
		player:SetAttribute("Undo_" .. key, nil)
	end
end

local function undoLast(player: Player, key: any): any
	local data = canChange(player)
	local saved = if typeof(key) == "string" and undo[player] then undo[player][key] else nil
	if not data or saved == nil then
		return nil
	end
	local slot, traits = loadoutSlot(data, key)
	if slot then
		undo[player][key] = if traits then slot.Traits else slot.Style
		setLoadout(slot, traits, saved)
		PerkRollService.publish(player, data)
	elseif Appearance.slots[key] then
		local look = PlayerData.worn(data).Appearance
		undo[player][key] = look[key]
		look[key] = saved
		commit(player, data)
	elseif emoteSlot(key) then
		local n = emoteSlot(key) :: number
		if saved ~= data.Emotes[n] and table.find(data.Emotes, saved) then
			return nil -- another slot rolled it meanwhile: no doubles
		end
		undo[player][key] = data.Emotes[n]
		data.Emotes[n] = saved
		publishEmotes(player, data)
	else
		return nil
	end
	player:SetAttribute("Undo_" .. key, if player:GetAttribute("Undo_" .. key) == "UNDO" then "REDO" else "UNDO")
	return saved
end

local function rank(rarity: string?): number
	return if rarity then table.find(Rarity.ORDER, rarity) or 0 else 0
end

-- Rarity of a rolled id in `pool` (nothing / custom ids rank below every target).
local function rolledRarity(pool: { any }, id: any): string?
	for _, item in pool do
		if item.id == id then
			return item.rarity or "Common"
		end
	end
	return nil
end

-- Rolls with `rollOnce` once, or with `target` (a rarity) until it lands that rarity or better, the
-- `budget` (rerolls you can spend) can't pay another `cost`-reroll roll, or D.AUTO_ROLL_MAX. `locks`
-- (trait rolls) keeps locked traits out of the rarity check. Returns the last id and the roll count.
local function rollUntil(rollOnce: () -> any, pool: { any }, target: string?, budget: number, cost: number?, locks: { boolean }?): (any, number)
	local id, rolls = nil, 0
	cost = cost or 1
	repeat
		id = rollOnce()
		rolls += 1
	until id == nil
		or not target
		or rank(if typeof(id) == "table" then bestTrait(id, locks) else rolledRarity(pool, id)) >= rank(target)
		or rolls >= D.AUTO_ROLL_MAX
		or (rolls + 1) * (cost :: number) > budget
	return id, rolls
end

-- Can an auto roll for `target` ever land? (Appearance never lands on what you have.)
local function reachable(pool: { any }, target: string, current: any, appearance: boolean): boolean
	for _, item in pool do
		if rank(item.rarity or "Common") >= rank(target) and (not appearance or item.id ~= current) then
			return true
		end
	end
	return false
end

-- One reroll, or with `target` (a rarity) an auto roll: keeps rolling (1 reroll each) until it lands
-- that rarity or better, you run out, or D.AUTO_ROLL_MAX. The last roll is kept either way; undo
-- goes back to what you had before the whole run. Returns the id and how many rolls it took.
local function reroll(player: Player, tab: any, slot: any, target: any): (any, number?)
	local data = canChange(player)
	if not data or (data.Spins < 1 and not free(player)) then
		return nil
	end
	if target ~= nil and (typeof(target) ~= "string" or rank(target) <= 1) then
		return nil -- Common (or junk) isn't a target
	end
	local rollOnce: () -> any
	local current: any
	local pool: { any }
	local cost, locks = 1, nil
	local L = PlayerData.worn(data)
	if tab == "Appearance" then
		local def = if typeof(slot) == "string" then Appearance.slots[slot] else nil
		if not def or def.rerollable == false then
			return nil
		end
		current = L.Appearance[slot]
		pool = Appearance.eligible(slot, L.Gender)
		local eligible = pool
		rollOnce = function()
			return RerollService.rollSlot(slot, L.Gender, rng, current, eligible)
		end
	elseif tab == "Loadout" then
		local s, traits = loadoutSlot(data, slot)
		if not s then
			return nil
		end
		if traits then
			local lockCost = PerkRollService.lockCost(s)
			if not lockCost or (data.Spins < lockCost and not free(player)) then
				return nil -- everything locked, or can't pay the locked price
			end
			cost, locks = lockCost, table.clone(s.Locks)
			current = table.clone(s.Traits)
			local style = PerkRollService.styleOf(s)
			local traitPool = PerkRollService.pool(style)
			pool = traitItems(style)
			rollOnce = function()
				return PerkRollService.roll(traitPool, rng, current, locks)
			end
		else
			-- No "never your current style" rule here: with few styles it would force the rare one
			-- (Basic -> Feng 100%). A style reroll can land on the style you already have.
			current = s.Style
			pool = RerollService.stylePool()
			rollOnce = function()
				local item = Rarity.pick(pool, rng)
				return item and item.id
			end
		end
	elseif tab == "Emotes" then
		local n = emoteSlot(slot)
		if not n then
			return nil
		end
		current = data.Emotes[n]
		pool = RerollService.emotePool(data.Emotes, n)
		rollOnce = function()
			local item = Rarity.pick(pool, rng, current)
			return item and item.id
		end
	else
		return nil
	end
	-- An auto roll that can never hit would just burn rerolls.
	if target and not reachable(pool, target, current, tab ~= "Loadout") then
		return nil
	end
	local id, rolls = rollUntil(rollOnce, pool, target, if free(player) then math.huge else data.Spins, cost, locks)
	if id == nil then
		return nil
	end
	remember(player, slot, current)
	if not free(player) then
		data.Spins -= rolls * cost
		player:SetAttribute("Spins", data.Spins)
	end
	if tab == "Loadout" then
		local s, traits = loadoutSlot(data, slot)
		setLoadout(s, traits, id)
		PerkRollService.publish(player, data)
	elseif tab == "Emotes" then
		data.Emotes[emoteSlot(slot) :: number] = id
		publishEmotes(player, data)
	else
		L.Appearance[slot] = id
		commit(player, data)
	end
	return id, rolls
end

-- Several appearance slots in ONE request (user, 2026-10-17): each is a normal reroll (or an auto roll
-- for `target`), the cost is the sum of every slot's rolls, and it's all-or-nothing: every slot is
-- checked and rolled first, and nothing is saved or spent unless all of them landed and you could pay
-- for all of them. One save + one ApplyDescription for the lot (single rerolls back to back used to
-- trip over each other's apply). Each slot keeps its own undo. Returns { slot = id } and total rolls.
local function rerollMany(player: Player, slots: any, target: any): ({ [string]: any }?, number?)
	local data = canChange(player)
	if not data or typeof(slots) ~= "table" or #slots < 1 or #slots > #Appearance.order then
		return nil
	end
	if target ~= nil and (typeof(target) ~= "string" or rank(target) <= 1) then
		return nil
	end
	local budget = if free(player) then math.huge else data.Spins
	if budget < #slots then
		return nil
	end
	local results: { [string]: any } = {}
	local spent, landed = 0, 0
	local L = PlayerData.worn(data)
	for i = 1, #slots do -- array part only: extra keys in a crafted table must not roll unpaid slots
		local slot = slots[i]
		local def = if typeof(slot) == "string" then Appearance.slots[slot] else nil
		if not def or def.rerollable == false or results[slot] ~= nil then
			return nil -- unknown, not rerollable or listed twice
		end
		local current = L.Appearance[slot]
		local pool = Appearance.eligible(slot, L.Gender)
		if target and not reachable(pool, target, current, true) then
			return nil
		end
		-- an auto roll leaves at least 1 reroll for every slot still to come
		landed += 1
		local id, rolls = rollUntil(function()
			return RerollService.rollSlot(slot, L.Gender, rng, current, pool)
		end, pool, target, budget - spent - (#slots - landed))
		if id == nil then
			return nil
		end
		results[slot] = id
		spent += rolls
	end
	if spent > budget then
		return nil -- can't happen (each slot's budget leaves room for the rest); never go negative
	end
	-- Everything landed: save it all at once.
	for slot, id in results do
		remember(player, slot, L.Appearance[slot])
		L.Appearance[slot] = id
	end
	if not free(player) then
		data.Spins -= spent
		player:SetAttribute("Spins", data.Spins)
	end
	commit(player, data)
	return results, spent
end

-- Free roll for every slot of a locker's look that has nothing saved yet (new players, new lockers,
-- hair on a gender's first wear, slots added to Data/Appearance later). `locker` = { Appearance, Gender }.
function RerollService.fillLook(locker: any, random: Random)
	for _, slot in Appearance.order do
		if locker.Appearance[slot] == nil then
			locker.Appearance[slot] = RerollService.rollSlot(slot, locker.Gender, random)
		end
	end
end

-- Switching gender keeps the look, except `perGender` slots (hair, user 2026-10-22): the current ones go
-- on the locker's Shelf for this gender and the new gender's come back (rolled fresh, free, the first
-- time). Pure data change; no cost.
function RerollService.swapLook(locker: any, gender: string, random: Random)
	if locker.Gender == gender then
		return
	end
	local shelved = {}
	for _, slot in Appearance.order do
		if Appearance.slots[slot].perGender then
			shelved[slot] = locker.Appearance[slot]
			locker.Appearance[slot] = (locker.Shelf[gender] or {})[slot]
		end
	end
	locker.Shelf[locker.Gender] = shelved
	locker.Shelf[gender] = nil
	locker.Gender = gender
	RerollService.fillLook(locker, random)
end

local function perGenderSlots(): { string }
	local slots = {}
	for _, slot in Appearance.order do
		if Appearance.slots[slot].perGender then
			table.insert(slots, slot)
		end
	end
	return slots
end

local function applyGender(player: Player, data: any, gender: string): string
	local L = PlayerData.worn(data)
	if L.Gender ~= gender then
		RerollService.swapLook(L, gender, rng)
		forget(player, perGenderSlots()) -- those undo targets belonged to the other gender's hair
		commit(player, data)
	end
	return gender
end

local function setGender(player: Player, gender: any): any
	local data = canChange(player)
	if not data or not table.find(D.GENDERS, gender) then
		return nil
	end
	return applyGender(player, data, gender)
end

-- Lowercase, no spaces: "Calm The Nerves" finds CalmTheNerves.
local function squash(s: string): string
	return (string.gsub(string.lower(s), "%s", ""))
end

-- Dev: set one thing directly, free. `key`:
--   appearance slot: SkinTone = exact BrickColor name; Face may be "Headless"; others 0/"nil"/"none" or an asset id
--     whose catalog type fits the slot (custom ids are kept as-is, gender swaps don't touch them)
--   "Bux": a whole number >= 0 (sets the balance)
--   "Furniture": "<furniture id>:<amount>" adds that many to their apartment bag (Data/Furniture ids)
--   "Gender": one of D.GENDERS (any case); swaps to that gender's saved look
--   "Style": a style name (any case)
--   "Reset": rerolls every appearance slot (free, no undo)
--   "Trait<n>": a trait id or name (any case/spaces), or "" / "none" to empty the slot
-- `player` is who gets changed (the dev themselves, or for the owner whoever's UserId they picked);
-- the caller checks isDev / isOwner.
local function devSet(player: Player, key: any, value: any): any
	local data = PlayerData.get(player)
	if not data or applying[player] or typeof(key) ~= "string" or typeof(value) ~= "string" then
		return nil
	end
	if key == "Furniture" then
		local id, count = string.match(value, "^([%w_]+):(%d+)$")
		local Apartment = Paths.server("ApartmentService")
		local owned = Apartment.give(data, id, tonumber(count))
		if owned then
			Apartment.ownedChanged(player) -- shows up in their bag now if they're in their apartment
		end
		return owned
	elseif key == "Bux" then
		local n = tonumber(value)
		if not n or n ~= math.floor(n) or n < 0 or n >= 1e12 then
			return nil
		end
		data.Bux = n
		player:SetAttribute("Bux", n)
		return n
	elseif key == "Gender" then
		for _, g in D.GENDERS do
			if squash(g) == squash(value) then
				return applyGender(player, data, g)
			end
		end
		return nil
	elseif key == "Reset" then
		-- Rerolls your whole look for free and clears undo.
		local L = PlayerData.worn(data)
		L.Appearance = {}
		RerollService.fillLook(L, rng)
		forget(player, Appearance.order)
		commit(player, data)
		return "look"
	elseif key == "Height" then
		return Paths.server("HeightService").set(player, data, value) -- owner only (gate in the DevSet handler)
	elseif key == "Style" then
		-- Your style.
		local name = Paths.findStyle(value)
		if not name then
			return nil
		end
		PlayerData.worn(data).Style = name
		forget(player, { "Style" })
		PerkRollService.publish(player, data)
		return name
	end
	local traitSlot = tonumber(string.match(key, "^Trait(%d+)$"))
	if traitSlot then
		local id = ""
		if squash(value) ~= "" and squash(value) ~= "none" then
			for _, perk in Paths.perkIds() do
				if squash(perk) == squash(value) or squash(Paths.perk(perk).name or "") == squash(value) then
					id = perk
				end
			end
			if id == "" then
				return nil
			end
		end
		if not PerkRollService.setSlot(player, traitSlot, id) then
			return nil
		end
		forget(player, { "Traits" })
		return if id == "" then "none" else id
	end
	local clothType = CLOTHES[key]
	if clothType then
		-- "default" / "" = back to the gender's uniform; "none" / "nil" / 0 = nothing; else a shirt / pants id
		local v = squash(value)
		local id: number?
		if v == "" or v == "default" then
			id = nil
		elseif v == "none" or v == "nil" then
			id = 0
		else
			local n = tonumber(value)
			if not n or n ~= math.floor(n) or n < 0 or n >= MAX_ASSET_ID then
				return nil
			end
			if n ~= 0 and assetType(n) ~= clothType then
				return nil
			end
			id = n
		end
		PlayerData.worn(data).Appearance[key] = id
		commit(player, data)
		return if id == nil then "default" else id
	end
	local slot = key
	local def = Appearance.slots[slot]
	if not def then
		return nil
	end
	if slot == "Face" and squash(value) == squash(HEADLESS) then
		value = HEADLESS
	elseif slot ~= "SkinTone" and (squash(value) == "nil" or squash(value) == "none") then
		value = 0
	elseif slot == "SkinTone" then
		if typeof(value) ~= "string" or BrickColor.new(value).Name ~= value then
			return nil
		end
	else
		value = tonumber(value)
		if not value or value ~= math.floor(value) or value < 0 or value >= MAX_ASSET_ID then
			return nil
		end
		local t = if value ~= 0 then assetType(value) else nil
		if value ~= 0 and (not t or not table.find(def.types, t)) then
			return nil
		end
	end
	PlayerData.worn(data).Appearance[slot] = value
	forget(player, { slot })
	commit(player, data)
	return value
end

-- Locker (user, 2026-10-22: "lockers are supposed to store individual items, so if someone wants to own
-- 2 mythic hats and swap between them they can"). Skin tone isn't an item.
local function storable(slot: any): boolean
	local def = if typeof(slot) == "string" then Appearance.slots[slot] else nil
	return def ~= nil and slot ~= "SkinTone" and def.rerollable ~= false
end

-- Puts what you wear in `what` (an appearance slot or "Style") into the first empty locker slot; you
-- then wear nothing there (the default style with no traits). Pure data change. Returns the slot used.
function RerollService.store(data: any, what: any): number?
	local worn = PlayerData.worn(data)
	local n: number? = nil
	for i, item in data.Locker do
		if item.Kind == "" then
			n = i
			break
		end
	end
	if not n then
		return nil
	end
	if what == "Style" then
		if PlayerData.blankStyle(worn) then
			return nil
		end
		data.Locker[n] = { Kind = "Style", Style = worn.Style, Traits = table.clone(worn.Traits), Locks = table.clone(worn.Locks) }
		PlayerData.clearStyle(worn)
	elseif storable(what) then
		local id = worn.Appearance[what]
		if id == nil or id == 0 then
			return nil
		end
		data.Locker[n] = { Kind = "Look", Slot = what, Id = id }
		worn.Appearance[what] = 0
	else
		return nil
	end
	return n
end

-- Wears locker slot `n`'s item; what you wore there goes into that slot (nothing / a blank style
-- leaves it empty). Pure data change. Returns the key that changed ("Style" or an appearance slot).
function RerollService.swap(data: any, n: any): string?
	local item = if typeof(n) == "number" then data.Locker[n] else nil
	if not item or item.Kind == "" then
		return nil
	end
	local worn = PlayerData.worn(data)
	if item.Kind == "Style" then
		local old = { Kind = "Style", Style = worn.Style, Traits = worn.Traits, Locks = worn.Locks }
		worn.Style, worn.Traits, worn.Locks = item.Style, item.Traits, item.Locks
		data.Locker[n] = if PlayerData.blankStyle(old) then { Kind = "" } else old
		return "Style"
	end
	if not storable(item.Slot) then
		return nil
	end
	local old = worn.Appearance[item.Slot]
	worn.Appearance[item.Slot] = item.Id
	data.Locker[n] = if old == nil or old == 0 then { Kind = "" } else { Kind = "Look", Slot = item.Slot, Id = old }
	return item.Slot
end

-- Pure: buys the next Bux locker slot (D.LOCKER_BUX_PRICES, in order). Robux slots (ExtraSlots) don't
-- count toward it. Returns ok, message.
function RerollService.buySlot(data: any): (boolean, string)
	local bought = data.BuxSlots or 0
	local price = D.LOCKER_BUX_PRICES[bought + 1]
	if not price then
		return false, "all bux slots bought"
	end
	if data.Bux < price then
		return false, "not enough bux"
	end
	data.Bux -= price
	data.BuxSlots = bought + 1
	PlayerData.fitLocker(data)
	return true, "ok"
end

-- Pure: throws away locker slot `n`'s item for good (the slot stays, empty). Returns true if there was one.
function RerollService.trash(data: any, n: any): boolean
	local item = if typeof(n) == "number" then data.Locker[n] else nil
	if not item or item.Kind == "" then
		return false
	end
	data.Locker[n] = { Kind = "" }
	return true
end

local function lockerAction(player: Player, action: any, arg: any): boolean?
	local data = canChange(player)
	if not data then
		return nil
	end
	if action == "Trash" then
		if not RerollService.trash(data, arg) then
			return nil
		end
		PerkRollService.publish(player, data) -- the Locker attribute
		return true
	elseif action == "BuySlot" then
		if not RerollService.buySlot(data) then
			return nil
		end
		player:SetAttribute("Bux", data.Bux)
		player:SetAttribute("LockerBuxSlots", data.BuxSlots)
		PerkRollService.publish(player, data) -- the Locker attribute, one slot longer
		return true
	end
	local key: string? = nil
	if action == "Store" then
		key = if RerollService.store(data, arg) then arg else nil
	elseif action == "Swap" then
		key = RerollService.swap(data, arg)
	end
	if not key then
		return nil
	end
	forget(player, if key == "Style" then { "Style", "Traits" } else { key })
	PerkRollService.publish(player, data) -- the Locker attribute (+ style / traits)
	if key ~= "Style" then
		commit(player, data)
	end
	return true
end

function RerollService.init()
	PlayerData.onLoaded(function(player, data)
		-- New players get a random gender; then free rolls for empty slots (new players, slots added later).
		local worn = PlayerData.worn(data)
		if not table.find(D.GENDERS, worn.Gender) then
			worn.Gender = D.GENDERS[rng:NextInteger(1, #D.GENDERS)]
		end
		RerollService.fillLook(worn, rng)
		RerollService.fillEmotes(data, rng)
		publishEmotes(player, data)
		player:SetAttribute("LockerBuxSlots", data.BuxSlots or 0) -- the locker page's next Bux price
		publish(player, data)
		requestApply(player)
	end)

	local function onPlayer(player: Player)
		-- The "Dev" attribute is RoleService's.
		player.CharacterAdded:Connect(function()
			requestApply(player)
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
	Players.PlayerRemoving:Connect(function(player)
		applying[player] = nil
		reapply[player] = nil
		undo[player] = nil
	end)

	local result = Net.get(Net.Names.RerollResult)
	Net.get(Net.Names.Reroll).OnServerEvent:Connect(function(player, tab, slot, target)
		if RateLimit.take(player, "Reroll") then
			result:FireClient(player, tab, slot, reroll(player, tab, slot, target))
		end
	end)
	Net.get(Net.Names.RerollMany).OnServerEvent:Connect(function(player, slots, target)
		if RateLimit.take(player, "Reroll") then
			local results, rolls = rerollMany(player, slots, target)
			result:FireClient(player, "Many", nil, results, rolls)
		end
	end)
	Net.get(Net.Names.Locker).OnServerEvent:Connect(function(player, action, arg)
		if RateLimit.take(player, "Reroll") then
			result:FireClient(player, "Locker", action, lockerAction(player, action, arg))
		end
	end)
	Net.get(Net.Names.Undo).OnServerEvent:Connect(function(player, key)
		if RateLimit.take(player, "Reroll") then
			result:FireClient(player, "Undo", key, undoLast(player, key))
		end
	end)
	Net.get(Net.Names.SetGender).OnServerEvent:Connect(function(player, gender)
		if RateLimit.take(player, "Reroll") then
			result:FireClient(player, "Gender", nil, setGender(player, gender))
		end
	end)
	Net.get(Net.Names.DevSet).OnServerEvent:Connect(function(player, key, value, targetId)
		if not RateLimit.take(player, "Reroll") or not isDev(player) then
			return
		end
		-- Devs change only themselves and never titles. Staff may also change other people's cosmetics;
		-- everything else on other people, and titles, is for the owner and Managers (user, 2026-10-22).
		local other = targetId ~= nil and targetId ~= player.UserId
		local cosmetic = typeof(key) == "string" and (Appearance.slots[key] ~= nil or CLOTHES[key] ~= nil or key == "Gender" or key == "Reset")
		local allowed = RoleService.canManage(player)
			or (key ~= "Title" and (not other or (cosmetic and RoleService.canSetCosmetics(player))))
		-- Height (D.HEIGHT; user, 2026-11-02) and Bux (user, 2026-11-03: not Managers): the owners only (D.OWNER_IDS), self or others.
		local ownerOnly = key == "Height" or key == "Bux"
		if not allowed or (key == "Style" and not RoleService.canGiveStyle(player, value)) or (ownerOnly and not RoleService.isOwner(player)) then
			result:FireClient(player, "Dev", key, nil)
			return
		end
		-- Target: another player in THIS server by UserId (their data only loads where they play), else yourself.
		local target = if targetId == nil then player
			elseif typeof(targetId) == "number" then Players:GetPlayerByUserId(targetId)
			else nil
		local out = if target then devSet(target, key, value) else nil
		-- No webhook for a Developer's sets (user, 2026-11-03). Owners / Managers / Staff are still logged.
		local developer = table.find(RoleService.roles(player), "Developer") ~= nil
		if target and out ~= nil and not developer then
			local id, n = string.match(tostring(value), "^([%w_]+):(%d+)$")
			Paths.server("GiveLog").log(player, target, if key == "Furniture" and id then `furniture {id} x{n}`
				elseif key == "Bux" then `Bux set to {value}`
				else `{key} = {value}`)
		end
		result:FireClient(player, "Dev", key, out)
	end)
end

return RerollService
