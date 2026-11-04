--!strict
-- Rollable rare perk (PerkRollService). Stat mods, see Fighter.Mods.
return {
	id = "Opportunist",
	name = "Opportunist",
	desc = "Deal 15% more damage to targets that are stunned or in attack endlag, or were stunned in the last 0.1s.",
	rollable = true,
	rarity = "Rare",
	icon = 3, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(255, 50, 170), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { stunnedDamage = 0.15 },
}
