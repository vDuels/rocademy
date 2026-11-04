--!strict
-- Rollable Prodigy trait (user, 2026-10-23): a dash that dodges a hit refunds 70% of the dash cooldown.
return {
	id = "Afterburner",
	name = "Afterburner",
	desc = "Dodging a hit with a dash refunds 70% of your dash cooldown.",
	style = "Prodigy", -- style perk: always on for Prodigy (user, 2026-10-24; was a rollable trait)
	icon = 1, -- ponytail: borrowed (Fleet Foot's) until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(255, 160, 110),
	behaviour = "Modifiers",
	mods = { dodgeDashRefund = 0.7 },
}
