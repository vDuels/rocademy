--!strict
-- Rollable Epic trait (PerkRollService).
return {
	id = "Technical",
	name = "Technical",
	desc = "Each M2 you land cuts your critical's cooldown by 35% of its full length.",
	rollable = true,
	rarity = "Epic",
	icon = 7, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(160, 90, 255), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { m2RCooldownCut = 0.35 }, -- fraction of the R move's full cooldown, per landed M2 (user, 2026-10-10)
}
