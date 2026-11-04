--!strict
-- Rollable common perk (PerkRollService). Stat mods, see Fighter.Mods.
return {
	id = "FleetFoot",
	name = "Fleet Foot",
	desc = "You run 12% faster.",
	rollable = true,
	rarity = "Common",
	icon = 1, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(140, 255, 60), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { runSpeed = 0.12 },
}
