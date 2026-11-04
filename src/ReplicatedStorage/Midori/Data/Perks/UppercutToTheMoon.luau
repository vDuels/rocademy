--!strict
-- Prodigy perk (user, 2026-10-23): a landed M2 gains as much Focus as a dodge (user, 2026-10-24; was 3x
-- a hit), and Focus counts double on the M2: at full Focus it has 50% anti-heal (30% base + 2 x 10%),
-- 60% less endlag, and a 0.3s windup.
return {
	id = "UppercutToTheMoon",
	name = "Uppercut to the Moon",
	desc = "Landing your M2 builds 15 Focus, and Focus counts double on it: at full Focus it has 50% anti-heal, 60% less endlag and a 0.3s windup.",
	style = "Prodigy", -- style perk: always on for Prodigy (user, 2026-10-24; was a rollable trait)
	icon = 7, -- ponytail: borrowed (Technical's) until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(120, 200, 255),
	behaviour = "Modifiers",
	mods = { m2FocusGain = 1, m2FocusPower = 1, m2FocusStartup = 0.3 }, -- m2FocusGain is on/off (FocusSystem.onLanded)
}
