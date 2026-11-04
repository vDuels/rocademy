--!strict
-- Rollable common perk (PerkRollService). Stat mods, see Fighter.Mods.
return {
	id = "ReinforcedGuard",
	name = "Reinforced Guard",
	desc = "Your max guard goes up by 4.",
	rollable = true,
	rarity = "Common",
	icon = 5, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(60, 120, 255), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { guardMax = 4 },
}
