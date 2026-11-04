--!strict
-- Rollable common perk (PerkRollService). Stat mods, see Fighter.Mods.
return {
	id = "KeenEye",
	name = "Keen Eye",
	desc = "Counter hits deal +10% damage (added to the counter multiplier).",
	rollable = true,
	rarity = "Common",
	icon = 2, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(255, 214, 0), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { counterDamage = 0.1 },
}
