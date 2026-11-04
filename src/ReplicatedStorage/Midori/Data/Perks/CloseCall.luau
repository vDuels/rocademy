--!strict
-- Rollable Common trait (PerkRollService).
return {
	id = "CloseCall",
	name = "Close Call",
	desc = "Gain 40% more adrenaline when you escape a hit.",
	rollable = true,
	rarity = "Common",
	icon = 6, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(0, 230, 180), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { dodgeAdrenaline = 0.4 },
}
