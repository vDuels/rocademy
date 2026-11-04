--!strict
-- Rollable Legendary trait (PerkRollService).
return {
	id = "CalmTheNerves",
	name = "Calm The Nerves",
	desc = "Landing a hit heals you, scaled by your adrenaline (full meter = 3 HP).",
	rollable = true,
	rarity = "Legendary",
	icon = 9, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(255, 110, 160), -- HUD trait card colour
	behaviour = "Modifiers",
	mods = { adrenalineHeal = 3 }, -- HP healed per landed hit at a full meter (user nerf 2026-10-10, was damage-based)
}
