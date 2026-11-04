--!strict
-- Rollable Common trait (PerkRollService), user 2026-10-11. Stat mods, see Fighter.Mods.
return {
	id = "ChargedReturn",
	name = "Charged Return",
	desc = "After parrying a hit, your next attack deals 2 additional damage.",
	rollable = true,
	rarity = "Common",
	icon = 10, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(255, 180, 30), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { parryBonusDamage = 2 },
}
