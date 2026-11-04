--!strict
-- Rollable Prodigy trait (user, 2026-10-23): landing Reentry (the critical) at full Focus plays the
-- ProdigyCrit cutscene (30 damage, 100% anti-heal) and spends all your Focus. Without it the critical
-- never plays its cutscene.
return {
	id = "Lightshow",
	name = "Lightshow",
	desc = "Land Reentry at full Focus to spend it all on a 30-damage cutscene.",
	style = "Prodigy", -- style perk: always on for Prodigy (user, 2026-10-24; was a rollable trait)
	icon = 9, -- ponytail: borrowed (Calm the Nerves') until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(255, 225, 140),
	behaviour = "Modifiers",
	mods = { focusCutscene = 1 },
}
