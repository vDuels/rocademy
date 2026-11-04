--!strict
-- Runs a fighter's perks. Perks are data (Data/Perks/<id>) that name a behaviour module
-- (PerkBehaviours/<behaviour>) holding their logic. The combat core never knows which perk
-- is which: behaviours only touch generic fighter fields (e.g. bonusDashes).
--
-- A fighter's perks = its style's `perks` list (always on) + the player's rolled perks
-- (the Player's "PerkSlots" attribute, set by PerkRollService). A rolled perk with a
-- `style` only works on that style; duplicates of a style perk are skipped.
--
-- Behaviour module API (all optional except attach):
--   attach(f, data) -> state      when the perk is equipped
--   tick(f, data, state, now, dt) every server step
--   detach(f, data, state)        when it is removed (style swap); undo anything it granted
--   onDamaged(f, data, state, damage, now)  after the fighter takes health damage from a hit
--   onLanded(f, data, state, move, now)     the fighter's hit landed (Hit / Counter / Clash)
--   onMissed(f, data, state, move, now)     the fighter's hitbox connected with nobody (rush: ran dry)
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Fighter = Paths.server("Fighter")

export type Active = { data: any, behaviour: any, state: any }

local PerkService = {}

local function perkIds(f: any): { string }
	local ids = table.clone(f.style.perks)
	local slots = f.player and f.player:GetAttribute("PerkSlots")
	if typeof(slots) == "string" then
		for _, id in string.split(slots, ",") do
			if id ~= "" and not table.find(ids, id) and Paths.findPerk(id) then
				local style = Paths.perk(id).style
				if style == nil or style == f.style.name then
					table.insert(ids, id)
				end
			end
		end
	end
	return ids
end

-- Equips the style's perks and the player's rolled perks (drops any previous ones first).
function PerkService.attach(f: any)
	-- Re-attaching must not heal: detach clamps guard and a guardMax perk's attach adds its bonus
	-- back, so keep the old guard (or full, if it was full).
	local wasFull, guard = f.guard >= Fighter.guardMax(f), f.guard
	PerkService.detach(f)
	local list: { Active } = {}
	for _, id in perkIds(f) do
		local data = Paths.perk(id)
		local behaviour = Paths.perkBehaviour(data.behaviour)
		table.insert(list, { data = data, behaviour = behaviour, state = behaviour.attach(f, data) })
	end
	f.perks = list
	f.guard = if wasFull then Fighter.guardMax(f) else math.min(guard, Fighter.guardMax(f))
	Fighter.syncMeters(f, true)
end

function PerkService.detach(f: any)
	for _, p in f.perks do
		if p.behaviour.detach then
			p.behaviour.detach(f, p.data, p.state)
		end
	end
	f.perks = {}
end

function PerkService.tick(f: any, now: number, dt: number)
	for _, p in f.perks do
		if p.behaviour.tick then
			p.behaviour.tick(f, p.data, p.state, now, dt)
		end
	end
end

-- Calls hook `name` (e.g. "onDamaged") on every equipped perk that has it.
function PerkService.event(f: any, name: string, ...: any)
	for _, p in f.perks do
		local hook = p.behaviour[name]
		if hook then
			hook(f, p.data, p.state, ...)
		end
	end
end

-- The live state of perk `id` on `f`, if equipped (tests, debugging).
function PerkService.state(f: any, id: string): any?
	for _, p in f.perks do
		if p.data.id == id then
			return p.state
		end
	end
	return nil
end

return PerkService
