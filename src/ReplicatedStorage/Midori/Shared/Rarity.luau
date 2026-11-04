--!strict
-- Rarity tiers shared by every roll (appearance, styles, traits). Items are tables with a `rarity`
-- field. Mythic and Legendary are flat chances (D.ROLL_FIXED_CHANCE: 0.05% / 1%) whenever the pool
-- has them; the rest is split by D.PERK_RARITY_WEIGHTS over the other tiers that have items.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local Rarity = {}

-- Evolved (user, 2026-11-02): above Mythic, never rolled (no ROLL_FIXED_CHANCE / PERK_RARITY_WEIGHTS entry,
-- so tierChances gives it 0); only on unobtainable, owner-given things (Furious Feng).
Rarity.ORDER = table.freeze({ "Common", "Rare", "Epic", "Legendary", "Mythic", "Evolved" })

Rarity.COLORS = table.freeze({
	Common = Color3.new(1, 1, 1),
	Rare = Color3.fromRGB(80, 160, 255),
	Epic = Color3.fromRGB(175, 90, 255),
	Legendary = Color3.fromRGB(255, 190, 60),
	Mythic = Color3.fromRGB(255, 40, 40),
	Evolved = Color3.fromRGB(40, 255, 190),
})

function Rarity.color(rarity: string?): Color3
	return Rarity.COLORS[rarity or "Common"] or Rarity.COLORS.Common
end

local TINT = 0.22 -- how far a cell's background leans toward its rarity colour

-- A subdued, rarity-coloured background for a cell/row (`base` = the normal cell colour).
function Rarity.tint(rarity: string?, base: Color3): Color3
	return base:Lerp(Rarity.color(rarity), TINT)
end

-- Fixed-chance tiers are tried first, rarest first; a tier the pool doesn't have is skipped.
local FIXED_ORDER = { "Mythic", "Legendary" }

-- Marker pick() returns when the roll lands on "nothing" (see `none` below).
Rarity.NONE = table.freeze({ id = "None" })

-- The chance of each tier in `present` (rarity -> true). Fixed tiers (D.ROLL_FIXED_CHANCE) get
-- exactly their chance PER ROLL; `none` (0-1, optional) is the share of the rest that lands on
-- nothing (result key "None"), and what's left is split by D.PERK_RARITY_WEIGHTS over the weighted
-- tiers present. With no weighted tier present, the leftover goes to "None" if there is a none
-- chance, else to the most common fixed tier present, and `fallback` is true in that last case.
function Rarity.tierChances(present: { [string]: boolean }, none: number?): ({ [string]: number }, boolean)
	local out: { [string]: number } = {}
	local left = 1
	for _, r in FIXED_ORDER do
		if present[r] then
			out[r] = D.ROLL_FIXED_CHANCE[r]
			left -= out[r]
		end
	end
	if none and none > 0 then
		out.None = left * none
		left -= out.None
	end
	local total = 0
	for r, w in D.PERK_RARITY_WEIGHTS do
		if present[r] and not D.ROLL_FIXED_CHANCE[r] then
			total += w
		end
	end
	if total > 0 then
		for r, w in D.PERK_RARITY_WEIGHTS do
			if present[r] and not D.ROLL_FIXED_CHANCE[r] then
				out[r] = left * w / total
			end
		end
		return out, false
	end
	if out.None then
		out.None += left -- only fixed tiers: the rest is nothing
		return out, false
	end
	-- Only fixed tiers: the most common one present absorbs the leftover.
	for i = #FIXED_ORDER, 1, -1 do
		local r = FIXED_ORDER[i]
		if out[r] then
			out[r] += left
			break
		end
	end
	return out, true
end

local TIER_ORDER = { "None", "Common", "Rare", "Epic", "Legendary", "Mythic" }

-- A tier from `present` by tierChances: a rarity, "None", or nil for an empty pool.
function Rarity.tier(present: { [string]: boolean }, random: Random, none: number?): string?
	local chances = Rarity.tierChances(present, none)
	local roll = random:NextNumber()
	local last = nil
	for _, r in TIER_ORDER do
		local p = chances[r]
		if p then
			last = r
			if roll < p then
				return r
			end
			roll -= p
		end
	end
	return last -- float leftovers
end

-- A random item from `items` (never one whose id is `exclude`, unless nothing else is left), or
-- Rarity.NONE when it lands on the `none` share (see tierChances).
function Rarity.pick(items: { any }, random: Random, exclude: any?, none: number?): any?
	local tiers: { [string]: { any } } = {}
	local present: { [string]: boolean } = {}
	for _, item in items do
		if item.id ~= exclude then
			local r = item.rarity or "Common"
			tiers[r] = tiers[r] or {}
			table.insert(tiers[r], item)
			present[r] = true
		end
	end
	local function from(list: { any }): any
		return list[random:NextInteger(1, #list)]
	end
	if next(tiers) == nil then
		return if exclude ~= nil and #items > 0 then from(items) else nil
	end
	local _, fallback = Rarity.tierChances(present, none)
	-- Skipping the current item left only fixed-chance tiers: land on the current item again instead
	-- of handing out a free Legendary/Mythic (wearing the only Common hat must not make every reroll a limited).
	if fallback and exclude ~= nil then
		for _, item in items do
			if item.id == exclude and not D.ROLL_FIXED_CHANCE[item.rarity or "Common"] then
				return item
			end
		end
	end
	local t = Rarity.tier(present, random, none) :: string
	return if t == "None" then Rarity.NONE else from(tiers[t])
end

-- The chance pick() lands on each item (by index in `items`), with no exclude and the same `none`.
-- Matches pick() exactly; the second value is the chance of landing on nothing.
function Rarity.odds(items: { any }, none: number?): ({ number }, number)
	local count: { [string]: number } = {}
	local present: { [string]: boolean } = {}
	for _, item in items do
		local r = item.rarity or "Common"
		count[r] = (count[r] or 0) + 1
		present[r] = true
	end
	if next(count) == nil then
		return {}, 0
	end
	local chances = Rarity.tierChances(present, none)
	local out = {}
	for i, item in items do
		local r = item.rarity or "Common"
		out[i] = (chances[r] or 0) / count[r]
	end
	return out, chances.None or 0
end

return Rarity
