--!strict
-- Rollable rare perk (PerkRollService). Stat mods, see Fighter.Mods.
return {
	id = "CounterPuncher",
	name = "Counter Puncher",
	desc = "Landing a counter also deals its damage to guard (max 4).",
	rollable = true,
	rarity = "Rare",
	icon = 4, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(255, 128, 0), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { counterGuardRatio = 1, counterGuardCap = 4 },
}
