--!strict
-- Furniture (Shared/GridMath; category = the build inventory tab; price = Bux in the build SHOP, none = not
-- for sale): size = cells (2 studs) at rot 0, height = studs, tabletop = can go on a surface, surface = a top
-- that tabletop items go on (cells, centred on the item + offset, `height` up). wall = hangs on walls: size =
-- { across, up }, pivot at its back face's centre. Model: Assets.Furniture.<id>, floor items pivot at their
-- bottom centre.
-- dj = plays music through the apartment (D.DJ, client DJController).
return { category = "Music", name = "DJ Booth", price = 150, size = { 2, 1 }, height = 3.1, dj = true }
