--!strict
-- "In combat" (user, 2026-10-29), pairwise like normal games. Two fighters are fighting each other once
-- they've exchanged D.COMBAT.threshold damage (health + guard, both ways). After that any exchange between
-- them (hit, block, parry, dodge) keeps it going; D.COMBAT.timeout seconds without one ends it, and the
-- count starts over. CombatService feeds it (emit / dodges) and ticks it from step().
-- Replicates on each fighter's model: "InCombat" attribute + a "CombatWith" folder of ObjectValues (one
-- per foe), so the owner's client can predict with the same foes (dash intent).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Registry = Paths.server("FighterRegistry")

type Link = { amount: number, last: number, active: boolean }

-- links[a][b] and links[b][a] are the same record.
local links: { [any]: { [any]: Link } } = setmetatable({}, { __mode = "k" }) :: any
local clock = 0 -- the last step's time (hits are resolved inside step)

local CombatTag = {}

local function publish(f: any)
	local want: { [Instance]: boolean } = {}
	for other, link in links[f] or {} do
		if link.active then
			want[other.model] = true
		end
	end
	local folder = f.model:FindFirstChild("CombatWith")
	if not folder and next(want) then
		folder = Instance.new("Folder")
		folder.Name = "CombatWith"
		folder.Parent = f.model
	end
	if folder then
		for _, value in folder:GetChildren() do
			local model = (value :: ObjectValue).Value
			if model and want[model] then
				want[model] = nil
			else
				value:Destroy()
			end
		end
		for model in want do
			local value = Instance.new("ObjectValue")
			value.Name = "Foe"
			value.Value = model
			value.Parent = folder
		end
	end
	f.model:SetAttribute("InCombat", if folder and #folder:GetChildren() > 0 then true else nil)
end

local function drop(a: any, b: any)
	if links[a] then
		links[a][b] = nil
	end
	if links[b] then
		links[b][a] = nil
	end
	publish(a)
	publish(b)
end

-- `amount` of damage went between `a` and `b` (either way; 0 = an exchange that only keeps it going).
function CombatTag.exchange(a: any, b: any, amount: number)
	if a == b then
		return
	end
	links[a] = links[a] or {}
	links[b] = links[b] or {}
	local link = links[a][b]
	if not link then
		link = { amount = 0, last = clock, active = false }
		links[a][b] = link
		links[b][a] = link
	end
	link.amount += amount
	link.last = clock
	if not link.active and link.amount >= D.COMBAT.threshold then
		link.active = true
		publish(a)
		publish(b)
	end
end

-- The fighters `f` is in combat with.
function CombatTag.foes(f: any): { any }
	local out = {}
	for other, link in links[f] or {} do
		if link.active then
			table.insert(out, other)
		end
	end
	return out
end

function CombatTag.inCombat(a: any, b: any): boolean
	local link = links[a] and links[a][b]
	return link ~= nil and link.active
end

-- Ends links that timed out or whose fighter is gone (died / respawned / left).
function CombatTag.tick(now: number)
	clock = now
	local ended = {}
	for f, foes in links do
		for other, link in foes do
			local gone = Registry.get(f.model) ~= f or Registry.get(other.model) ~= other
			if gone or now - link.last > D.COMBAT.timeout then
				table.insert(ended, { f, other })
			end
		end
	end
	for _, pair in ended do
		drop(pair[1], pair[2])
	end
end

return CombatTag