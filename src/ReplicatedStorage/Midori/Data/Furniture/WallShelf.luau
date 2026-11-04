--!strict
-- Furniture (Shared/GridMath; category = the build inventory tab; price = Bux in the build SHOP, none = not
-- for sale): size = cells (2 studs) at rot 0, height = studs, tabletop = can go on a surface, surface = a top
-- that tabletop items go on (cells, centred on the item + offset, `height` up). wall = hangs on walls: size =
-- { across, up }, pivot at its back face's centre. Model: Assets.Furniture.<id>, floor items pivot at their
-- bottom centre.
return { category = "Wall", name = "Wall Shelf", price = 20, wall = true, size = { 2, 1 }, height = 2,
	-- the plank's top (0.475 below the pivot), sticking out from the wall: things on it can't poke into it
	surface = { size = { 2, 1 }, height = -0.475, offset = Vector3.new(0, 0, -1) } }
