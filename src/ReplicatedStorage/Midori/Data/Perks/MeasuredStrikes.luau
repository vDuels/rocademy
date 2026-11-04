--!strict
-- Karate style perk (user, 2026-10-13): every M1 further into the chain is slower (startup +
-- animation) and deals more damage, both additive per swing (numbers in `mods`). Resets
-- with the chain. The startup slow stacks with the adrenaline speed bonus; the damage multiplies on top.
return {
	id = "MeasuredStrikes",
	name = "Measured Strikes",
	desc = "Each M1 in your chain is 10% slower with 5% more endlag, but deals 15% more damage. Resets when the chain does.",
	style = "Karate", -- style perk: only Karate can have it
	behaviour = "Modifiers",
	-- user, 2026-10-14 (slow 0.05 -> 0.1 -> 0.15 -> 0.1; damage 0.1 -> 0.075 -> 0.15; endlag new)
	mods = { m1ChainSlow = 0.15, m1ChainDamage = 0.15, m1ChainEndlag = 0.05 },
}