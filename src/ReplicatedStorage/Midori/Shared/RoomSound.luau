--!strict
-- Apartment sound through rooms (user, 2026-11-01; DJController plays it). Pure, so Tests can check it.
-- Rooms (GridMath.rooms) are a graph: two floors are neighbours when their edges are within `gap` studs (the
-- wall between them) and they overlap along that wall. hops() = rooms between each room and the nearest source
-- (the DJ booth's room; a Sound Extender's room starts at D.DJ.extenderHops); mix() turns hops into a level.
local GridMath = require(script.Parent:WaitForChild("GridMath"))

local RoomSound = {}

type Rect = { minX: number, maxX: number, minZ: number, maxZ: number }

local function rect(room: GridMath.Room): Rect
	local a = room.origin.Position
	local b = room.origin:PointToWorldSpace(Vector3.new(room.size[1] * GridMath.CELL, 0, room.size[2] * GridMath.CELL))
	return { minX = math.min(a.X, b.X), maxX = math.max(a.X, b.X), minZ = math.min(a.Z, b.Z), maxZ = math.max(a.Z, b.Z) }
end

-- room -> { neighbour = true }
function RoomSound.neighbours(rooms: { [string]: GridMath.Room }, gap: number): { [string]: { [string]: boolean } }
	local rects, out = {}, {}
	for name, room in rooms do
		rects[name] = rect(room)
		out[name] = {}
	end
	for a, ra in rects do
		for b, rb in rects do
			if a ~= b then
				local gapX = math.max(ra.minX - rb.maxX, rb.minX - ra.maxX) -- < 0 = they overlap along X
				local gapZ = math.max(ra.minZ - rb.maxZ, rb.minZ - ra.maxZ)
				if (gapX <= gap and gapZ < 0) or (gapZ <= gap and gapX < 0) then
					out[a][b] = true
				end
			end
		end
	end
	return out
end

-- room -> hops from the nearest source; sources = room -> the hops it starts at. Unreachable rooms = math.huge.
function RoomSound.hops(rooms: { [string]: GridMath.Room }, sources: { [string]: number }, gap: number): { [string]: number }
	local graph = RoomSound.neighbours(rooms, gap)
	local dist: { [string]: number } = {}
	for name in rooms do
		dist[name] = math.huge
	end
	for name, start in sources do
		if dist[name] then
			dist[name] = math.min(dist[name], start)
		end
	end
	-- Few rooms: relax until nothing changes (every edge costs 1).
	local changed = true
	while changed do
		changed = false
		for a, ns in graph do
			for b in ns do
				if dist[a] + 1 < dist[b] then
					dist[b] = dist[a] + 1
					changed = true
				end
			end
		end
	end
	return dist
end

-- hops -> volume (x the song's), high / mid EQ gain (dB, <= 0). cfg = D.DJ.
function RoomSound.mix(hops: number, cfg: any): (number, number, number)
	if hops > cfg.maxHops then
		return 0, -80, -80
	end
	return cfg.volumePerHop ^ hops, math.max(-80, -cfg.highCut * hops), math.max(-80, -cfg.midCut * hops)
end

return RoomSound
