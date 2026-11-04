--!strict
-- Your style + traits (traits are called perks in code), in the saved Loadout, and the Locker of stored
-- items (PlayerData; storing / swapping is RerollService's). Rolls go through RerollService: the style
-- (1 reroll), or all UNLOCKED traits at once (D.TRAIT_LOCK_MULT ^ locks rerolls; all locked = no
-- reroll). Each trait lands, with D.PERK_ROLL_CHANCE, a random rollable trait (`rollable = true`, rarity
-- tier by Shared/Rarity.tier) that the style can use, never one you already have; otherwise nothing.
-- Replicates as Player attributes: "Locker" (JSON list of the stored items), "TraitLocks" ("1,0,1"),
-- "Spins", "PerkSlots" ("id,,id", read by PerkService) + "Style" (StyleService).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local Rarity = Paths.shared("Rarity")
local Registry = Paths.server("FighterRegistry")
local Fighter = Paths.server("Fighter")
local PerkService = Paths.server("PerkService")
local PlayerData = Paths.server("PlayerData")
local RateLimit = Paths.server("RateLimit")
local StyleService = Paths.server("StyleService")

local PerkRollService = {}

local RARITIES = { "Common", "Rare", "Epic", "Legendary" } -- fixed order keeps seeded rolls repeatable

export type Pool = { [string]: { string } } -- rarity -> trait ids

-- Ids of every trait a roll for `style` can land on, split by rarity (style-locked traits only on their style).
function PerkRollService.pool(style: string?): Pool
	local pool: Pool = {}
	for _, rarity in RARITIES do
		pool[rarity] = {}
	end
	for _, id in Paths.perkIds() do
		local data = Paths.perk(id)
		if data.rollable == true and (data.style == nil or data.style == style) then
			local list = pool[data.rarity]
			assert(list, `trait {id} has unknown rarity {tostring(data.rarity)}`)
			table.insert(list, id)
		end
	end
	return pool
end

-- One trait slot's roll: hits with D.PERK_ROLL_CHANCE, then a rarity by weight among the rarities
-- that still have traits not in `taken`, then a random one of those. "" = nothing.
function PerkRollService.rollOne(pool: Pool, random: Random, taken: { string }): string
	local left: Pool = {}
	local present = {}
	for _, rarity in RARITIES do
		local ids = {}
		for _, id in pool[rarity] or {} do
			if not table.find(taken, id) then
				table.insert(ids, id)
			end
		end
		left[rarity] = ids
		if #ids > 0 then
			present[rarity] = true
		end
	end
	-- Legendary keeps its flat per-roll chance; nothing only shares the rest.
	local rarity = if next(present) then Rarity.tier(present, random, 1 - D.PERK_ROLL_CHANCE) else nil
	if not rarity or rarity == "None" then
		return ""
	end
	local ids = left[rarity]
	return ids[random:NextInteger(1, #ids)]
end

-- All of a locker's traits at once (user, 2026-10-13: back to rerolling all 3): each rolls like
-- rollOne, never repeating one already rolled in this roll. Trait t with `locks[t]` keeps `keep[t]`
-- instead (and nothing else can roll it).
function PerkRollService.roll(pool: Pool, random: Random, keep: { string }?, locks: { boolean }?): { string }
	local slots, taken = {}, {}
	for i = 1, D.PERK_SLOTS do
		if locks and locks[i] and keep then
			slots[i] = keep[i]
			table.insert(taken, keep[i])
		end
	end
	for i = 1, D.PERK_SLOTS do
		if slots[i] == nil then
			slots[i] = PerkRollService.rollOne(pool, random, taken)
			table.insert(taken, slots[i])
		end
	end
	return slots
end

-- Rerolls one traits roll of `locker` costs: D.TRAIT_LOCK_MULT per locked trait, multiplied
-- (0 = 1, 1 = 10, 2 = 100). nil = every trait is locked, nothing left to roll.
function PerkRollService.lockCost(locker: any): number?
	local locked = 0
	for t = 1, D.PERK_SLOTS do
		if locker.Locks[t] then
			locked += 1
		end
	end
	return if locked >= D.PERK_SLOTS then nil else D.TRAIT_LOCK_MULT ^ locked
end

-- The style a slot fights with ("" = the default).
function PerkRollService.styleOf(slot: any): string
	return if slot.Style ~= "" then slot.Style else D.DEFAULT_STYLE
end

-- Pushes the saved style, traits and locker out: attributes for the menu, and the style + traits onto
-- the fighter (the look is RerollService's).
function PerkRollService.publish(player: Player, data: any)
	local slot = PlayerData.worn(data)
	player:SetAttribute("Spins", data.Spins)
	player:SetAttribute("Locker", HttpService:JSONEncode(data.Locker))
	local locks = {}
	for t, on in slot.Locks do
		locks[t] = if on then "1" else "0"
	end
	player:SetAttribute("TraitLocks", table.concat(locks, ","))
	player:SetAttribute("PerkSlots", table.concat(slot.Traits, ","))
	if not StyleService.select(player, PerkRollService.styleOf(slot)) then
		StyleService.select(player, D.DEFAULT_STYLE) -- a saved style that no longer exists
	end
	local f = Registry.getByPlayer(player)
	if f then
		PerkService.attach(f) -- traits may change without the style changing
	end
end

-- Dev: put trait `id` ("" = empty) in your trait `t`, no roll, no cost.
function PerkRollService.setSlot(player: Player, t: number, id: string): boolean
	local data = PlayerData.get(player)
	local slot = data and PlayerData.worn(data)
	if not slot or not slot.Traits[t] then
		return false
	end
	slot.Traits[t] = id
	if id == "" then
		slot.Locks[t] = false
	end
	PerkRollService.publish(player, data)
	return true
end

-- Data loaded and the same lock as rerolls: out of combat mode, Idle, not attacked lately.
local function changeable(player: Player): any?
	local data = PlayerData.get(player)
	local f = Registry.getByPlayer(player)
	if not data or (f and Fighter.loadoutLocked(f, workspace:GetServerTimeNow())) then
		return nil
	end
	return data
end

-- Toggles the lock on your trait `t` (free). An empty trait can't be locked.
-- Returns the new lock state, or nil if refused.
local function toggleLock(player: Player, t: any): boolean?
	local data = changeable(player)
	local slot = data and PlayerData.worn(data)
	if not slot or typeof(t) ~= "number" or slot.Traits[t] == nil then
		return nil
	end
	if not slot.Locks[t] and slot.Traits[t] == "" then
		return nil
	end
	slot.Locks[t] = not slot.Locks[t]
	PerkRollService.publish(player, data)
	return slot.Locks[t]
end

function PerkRollService.init()
	for productId, spins in D.SPIN_PRODUCTS do
		PlayerData.onProduct(productId, function(player, data)
			data.Spins += spins
			player:SetAttribute("Spins", data.Spins)
		end)
	end
	for productId, slots in D.LOCKER_PRODUCTS do
		PlayerData.onProduct(productId, function(player, data)
			data.ExtraSlots += slots
			PlayerData.fitLocker(data)
			PerkRollService.publish(player, data)
		end)
	end
	PlayerData.init(PerkRollService.publish)

	local result = Net.get(Net.Names.RerollResult)
	Net.get(Net.Names.TraitLock).OnServerEvent:Connect(function(player, t)
		if RateLimit.take(player, "Reroll") then
			result:FireClient(player, "Lock", t, toggleLock(player, t))
		end
	end)
end

return PerkRollService
