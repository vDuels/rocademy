--!strict
-- Brick Wall (data: Data/Perks/BrickWall). Every hit taken adds a stack of damage reduction
-- with its own timer; at maxStacks a new hit refreshes the oldest stack. It only writes the
-- generic f.mods.damageReduction (by its own contribution, so other sources still stack).
type State = { expiries: { number }, applied: number }

local BrickWall = {}

local function apply(f: any, data: any, s: State)
	local dr = #s.expiries * data.stack
	if dr ~= s.applied then
		f.mods.damageReduction += dr - s.applied
		s.applied = dr
	end
end

function BrickWall.attach(_f: any, _data: any): State
	return { expiries = {}, applied = 0 }
end

function BrickWall.detach(f: any, _data: any, s: State)
	f.mods.damageReduction -= s.applied
end

function BrickWall.onDamaged(f: any, data: any, s: State, _damage: number, now: number)
	if #s.expiries >= data.maxStacks then
		table.remove(s.expiries, 1)
	end
	table.insert(s.expiries, now + data.duration)
	apply(f, data, s)
end

function BrickWall.tick(f: any, data: any, s: State, now: number, _dt: number)
	while s.expiries[1] and s.expiries[1] <= now do
		table.remove(s.expiries, 1)
	end
	apply(f, data, s)
end

return BrickWall
