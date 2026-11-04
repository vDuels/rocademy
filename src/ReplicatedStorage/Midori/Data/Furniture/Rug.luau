--!strict
-- Furniture (Shared/GridMath; category = the build inventory tab; price = Bux in the build SHOP, none = not
-- for sale): size = cells (2 studs) at rot 0, height = studs, tabletop = can go on a surface, surface = a top
-- that tabletop items go on (cells, centred on the item + offset, `height` up). wall = hangs on walls: size =
-- { across, up }, pivot at its back face's centre. Model: Assets.Furniture.<id>, floor items pivot at their
-- bottom centre.
return { category = "Decor", name = "Rug", price = 15, size = { 2, 3 }, height = 0.12, rug = true } -- under furniture (GridMath rug), 2026-11-01
