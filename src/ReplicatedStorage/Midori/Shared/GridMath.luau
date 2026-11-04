--!strict
-- Apartment placement grid (user, 2026-10-31): 2-stud cells, one grid per room, starting at the min corner
-- of that room's floor part (Assets.Apartment.<style>.Rooms), so the 2-stud walls never break the grid.
-- Pure: the client's green / red ghost and ApartmentService's checks call the same functions.
-- Three kinds of spot, exactly one per placed item:
--   floor    { item, room = room name, x, z = min-corner cell, rot = 0..3 quarter turns }
--   surface  { item, parent = uid (on that item's surface), x, z, rot }       (tabletop items only)
--   wall     { item, wall = "<room>/<N|E|S|W>", x = WALL cells along it, z = WALL cells UP it, rot = 0 } (wall items only)
-- Walls use their own finer grid (user, 2026-11-01): WALL_CELL = 1 stud, so wall items move in 1-stud steps.
-- Defs still give wall items' size in CELLs; GridMath.wallSize turns that into wall cells. A wall's size is in
-- wall cells too. (Saved wall spots were 2-stud cells before PlayerData v11 doubled them.)
-- Walls come from each room floor's four edges, `WallHeight` studs tall (attribute on the floor part,
-- default WALL_HEIGHT): the style's real wall parts must stand on those edges. Doorways aren't known, so a
-- wall item can be hung across one (ponytail: per-wall gaps as attributes if that matters).
-- Uids are strings: profiles save as JSON, which mangles sparse number keys.
local GridMath = {}

local CELL = 2
local WALL_CELL = 1
local WALL_HEIGHT = 10 -- studs, a room's walls when its floor has no WallHeight attribute
GridMath.CELL = CELL
GridMath.WALL_CELL = WALL_CELL

-- offset (studs, item space) moves the surface off the item's pivot: a wall shelf's top sticks out forward.
export type Surface = { size: { number }, height: number, offset: Vector3? }
-- wall = hangs on walls only: size = { cells across, cells up }, pivot at the centre of its back face.
-- rug = lies flat on the floor: rugs only block rugs, so furniture stands on them.
export type Def = { size: { number }, height: number, tabletop: boolean?, wall: boolean?, rug: boolean?, surface: Surface? }
export type Room = { size: { number }, origin: CFrame, height: number? }
export type Wall = { size: { number }, origin: CFrame }
export type Item = { item: string, room: string?, parent: string?, wall: string?, x: number, z: number, rot: number }
type GetDef = (id: string) -> Def?

-- Cells an item covers at `rot`: odd quarter turns swap width and depth.
function GridMath.footprint(size: { number }, rot: number): (number, number)
	if rot % 2 == 1 then
		return size[2], size[1]
	end
	return size[1], size[2]
end

local function whole(n: any): boolean
	return typeof(n) == "number" and n == math.floor(n) and math.abs(n) < 1e6
end

-- An item's pivot (bottom centre) relative to its area's min corner.
function GridMath.toLocal(x: number, z: number, w: number, d: number, rot: number): CFrame
	return CFrame.new((x + w / 2) * CELL, 0, (z + d / 2) * CELL) * CFrame.Angles(0, rot * math.pi / 2, 0)
end

-- A wall item's size in wall cells: { across, up } (its def's size is in CELLs).
function GridMath.wallSize(def: Def): (number, number)
	local k = CELL / WALL_CELL
	return def.size[1] * k, def.size[2] * k
end

-- A wall item's pivot (back-face centre) relative to its wall's origin. x along, z up; all in wall cells.
function GridMath.toWall(x: number, z: number, w: number, h: number): CFrame
	return CFrame.new((x + w / 2) * WALL_CELL, (z + h / 2) * WALL_CELL, 0)
end

-- The cell whose footprint is centred nearest `pos` (local to an area's min corner). For the ghost.
function GridMath.snap(pos: Vector3, w: number, d: number): (number, number)
	return math.round(pos.X / CELL - w / 2), math.round(pos.Z / CELL - d / 2)
end

-- Same for a wall: `pos` local to the wall's origin (X along, Y up).
function GridMath.snapWall(pos: Vector3, w: number, h: number): (number, number)
	return math.round(pos.X / WALL_CELL - w / 2), math.round(pos.Y / WALL_CELL - h / 2)
end

-- A surface's min corner relative to its item's pivot: centred on the item (moved by `offset`), `height` up.
function GridMath.surfaceOrigin(surface: Surface): CFrame
	return CFrame.new(surface.offset or Vector3.zero) * CFrame.new(-surface.size[1] * CELL / 2, surface.height, -surface.size[2] * CELL / 2)
end

-- Rooms of a style model: every BasePart in its Rooms folder is a floor, named by the room. Origin = the min
-- corner of its top face, relative to the model's pivot. Floor X / Z sizes must be multiples of CELL.
function GridMath.rooms(shell: Model): { [string]: Room }
	local pivot = shell:GetPivot()
	local out: { [string]: Room } = {}
	local folder = shell:FindFirstChild("Rooms")
	for _, p in if folder then folder:GetChildren() else {} do
		if p:IsA("BasePart") then
			local cx, cz = p.Size.X / CELL, p.Size.Z / CELL
			if cx ~= math.floor(cx) or cz ~= math.floor(cz) then
				warn(`[GridMath] room {p.Name} is {p.Size.X}x{p.Size.Z}, not a multiple of {CELL} studs`)
			end
			local h = p:GetAttribute("WallHeight")
			out[p.Name] = {
				size = { math.floor(cx), math.floor(cz) },
				origin = pivot:ToObjectSpace(p.CFrame) * CFrame.new(-p.Size.X / 2, p.Size.Y / 2, -p.Size.Z / 2),
				height = math.floor((if typeof(h) == "number" then h else WALL_HEIGHT) / CELL),
			}
		end
	end
	return out
end

-- Every room's four walls, "<room>/<side>". A wall's origin is its bottom-left corner seen from inside the
-- room, X along it, Y up, LookVector into the room (so a wall item's front, -Z, faces the room).
function GridMath.walls(rooms: { [string]: Room }): { [string]: Wall }
	local out: { [string]: Wall } = {}
	for name, room in rooms do
		local w, d = room.size[1] * CELL, room.size[2] * CELL
		-- in wall cells: along = the floor edge, up = the wall height
		local along1, along2 = w / WALL_CELL, d / WALL_CELL
		local h = (room.height or math.floor(WALL_HEIGHT / CELL)) * CELL / WALL_CELL
		local o = room.origin
		out[name .. "/N"] = { size = { along1, h }, origin = o * CFrame.new(w, 0, 0) * CFrame.Angles(0, math.pi, 0) } -- the z = 0 edge
		out[name .. "/S"] = { size = { along1, h }, origin = o * CFrame.new(0, 0, d) } -- the z = depth edge
		out[name .. "/W"] = { size = { along2, h }, origin = o * CFrame.Angles(0, -math.pi / 2, 0) } -- the x = 0 edge
		out[name .. "/E"] = { size = { along2, h }, origin = o * CFrame.new(w, 0, d) * CFrame.Angles(0, math.pi / 2, 0) } -- the x = width edge
	end
	return out
end

-- Where item `uid` sits, relative to the plot (style model pivot). Nil if it (or what it's on) is gone.
function GridMath.cframe(items: { [string]: Item }, rooms: { [string]: Room }, getDef: GetDef, uid: string): CFrame?
	local it = items[uid]
	local def = it and getDef(it.item)
	if not it or not def then
		return nil
	end
	if it.wall then
		local wall = GridMath.walls(rooms)[it.wall]
		local ww, wh = GridMath.wallSize(def)
		return if wall then wall.origin * GridMath.toWall(it.x, it.z, ww, wh) else nil
	end
	local area: CFrame?
	if it.parent then
		local parent = items[it.parent]
		local pdef = parent and getDef(parent.item)
		local at = if pdef and pdef.surface then GridMath.cframe(items, rooms, getDef, it.parent) else nil
		area = if at and pdef and pdef.surface then at * GridMath.surfaceOrigin(pdef.surface) else nil
	else
		local room = it.room and rooms[it.room]
		area = if room then room.origin else nil
	end
	if not area then
		return nil
	end
	local w, d = GridMath.footprint(def.size, it.rot)
	return area * GridMath.toLocal(it.x, it.z, w, d, it.rot)
end

-- Why `place` can't go where it says (nil = it can). `ignore` = the uid being moved (it doesn't block itself).
function GridMath.check(items: { [string]: Item }, rooms: { [string]: Room }, getDef: GetDef, place: Item, ignore: string?): string?
	local def = typeof(place.item) == "string" and getDef(place.item) or nil
	if not def then
		return "no such item"
	end
	if not (whole(place.x) and whole(place.z) and whole(place.rot)) or place.rot < 0 or place.rot > 3 then
		return "bad cell"
	end
	local area: { number }
	if place.wall ~= nil then
		local wall = typeof(place.wall) == "string" and GridMath.walls(rooms)[place.wall] or nil
		if not wall then
			return "no such wall"
		end
		if not def.wall then
			return "doesn't hang on walls"
		end
		if place.rot ~= 0 then
			return "bad cell"
		end
		area = wall.size
	elseif def.wall then
		return "goes on a wall"
	elseif place.parent ~= nil then
		local parent = typeof(place.parent) == "string" and items[place.parent] or nil
		local pdef = parent and getDef(parent.item)
		if place.parent == ignore or not pdef or not pdef.surface then
			return "nothing to put it on"
		end
		if not def.tabletop or def.surface then
			return "can't go on a surface"
		end
		area = pdef.surface.size
	else
		local room = typeof(place.room) == "string" and rooms[place.room] or nil
		if not room then
			return "no such room"
		end
		area = room.size
	end
	local w, d -- wall items: { across, up } in wall cells
	if place.wall ~= nil then
		w, d = GridMath.wallSize(def)
	else
		w, d = GridMath.footprint(def.size, place.rot)
	end
	if place.x < 0 or place.z < 0 or place.x + w > area[1] or place.z + d > area[2] then
		return "out of bounds"
	end
	for uid, other in items do
		-- Same spot kind and same room / surface / wall.
		local same = other.parent == place.parent and other.room == place.room and other.wall == place.wall
		local odef = if uid ~= ignore and same then getDef(other.item) else nil
		if odef and (odef.rug == true) == (def.rug == true) then
			local ow, od
			if place.wall ~= nil then
				ow, od = GridMath.wallSize(odef)
			else
				ow, od = GridMath.footprint(odef.size, other.rot)
			end
			if place.x < other.x + ow and other.x < place.x + w and place.z < other.z + od and other.z < place.z + d then
				return "overlaps"
			end
		end
	end
	return nil
end

return GridMath
