--!strict
-- Rollable Prodigy trait (user, 2026-10-23): every dash throws a mirage of you dashing the opposite way,
-- fainter the more Focus you have (client visual: StarterPlayerScripts.Midori.Mirage).
return {
	id = "CosmicRay",
	name = "Cosmic Ray",
	desc = "With 10+ Focus, dashing sends a mirage of you dashing the opposite way. It starts blue and see-through; by 80 Focus it looks almost real.",
	style = "Prodigy", -- style perk: always on for Prodigy (user, 2026-10-24; was a rollable trait)
	icon = 6, -- ponytail: borrowed (Close Call's) until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(190, 160, 255),
	behaviour = "Modifiers",
	mods = { mirage = 1 },
}
