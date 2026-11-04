--!strict
-- Prodigy style perk, the drawback (user, 2026-10-23): adrenaline drains Focus (scales with how much you
-- hold), and counters always deal a flat 35% more to you (user, 2026-10-25; was up to 25% with adrenaline).
return {
	id = "Spacesuit",
	name = "Spacesuit",
	desc = "Adrenaline drains your Focus (up to 4/s at full). Counters deal 35% more to you.",
	style = "Prodigy", -- style perk: always on for Prodigy
	behaviour = "Modifiers",
	mods = { adrFocusDrain = 4, counterTaken = 0.35 },
}
