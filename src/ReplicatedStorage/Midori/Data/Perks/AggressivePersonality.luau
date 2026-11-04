--!strict
-- Rollable Rare trait (PerkRollService), user 2026-10-11. Stat mods, see Fighter.Mods.
-- Calm Mind (user, 2026-10-30; was Aggressive Personality, +20% adrenaline gain removed). The id stays
-- AggressivePersonality so saved trait slots keep it.
return {
	id = "AggressivePersonality",
	name = "Calm Mind",
	desc = "+100 max adrenaline.",
	rollable = true,
	rarity = "Rare",
	icon = 11, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(255, 36, 56), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { adrenalineMax = 100 },
}
