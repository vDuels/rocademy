--!strict
-- Prodigy style perk (user, 2026-10-29: "hitting enemy slows them down by 10% for 0.7 seconds"; the name is
-- mine). Every landed hit (hit / counter / clash, any move) slows the victim's walk and run by 10% for 0.7s;
-- a new hit restarts the 0.7s. Logic: HitResolver.applyHit (hitSlow mods) + RunController.
return {
	id = "Microgravity",
	name = "Microgravity",
	desc = "Landing a hit slows your target's movement by 10% for 0.7s.",
	style = "Prodigy", -- style perk: always on for Prodigy
	icon = 1, -- ponytail: borrowed (Fleet Foot's) until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(150, 180, 255),
	behaviour = "Modifiers",
	mods = { hitSlow = 0.1, hitSlowTime = 0.7 },
}