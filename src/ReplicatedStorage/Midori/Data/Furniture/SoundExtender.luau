--!strict
-- Furniture (Shared/GridMath; category = the build inventory tab; price = Bux in the build SHOP, none = not
-- for sale): size = cells (2 studs) at rot 0, height = studs, tabletop = can go on a surface, surface = a top
-- that tabletop items go on (cells, centred on the item + offset, `height` up). wall = hangs on walls: size =
-- { across, up }, pivot at its back face's centre. Model: Assets.Furniture.<id>, floor items pivot at their
-- bottom centre.
-- speaker = a DJ booth's music is clear in this room too (D.DJ.extenderHops) and carries on from it.
return { category = "Music", name = "Sound Extender", price = 40, size = { 1, 1 }, height = 2.3, tabletop = true, speaker = true }
