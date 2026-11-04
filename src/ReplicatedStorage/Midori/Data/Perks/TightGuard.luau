--!strict
-- Rollable common perk (PerkRollService). Stat mods, see Fighter.Mods.
return {
	id = "TightGuard",
	name = "Tight Guard",
	desc = "Blocked hits deal 1 less guard damage.",
	rollable = true,
	rarity = "Common",
	icon = 0, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(0, 200, 255), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { guardDamageTaken = -1 },
}
