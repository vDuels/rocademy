--!strict
-- Lethwei style perk (user, 2026-10-16). Clashes deal +35% damage, additive with the counter
-- multiplier (1.35 -> 1.70), and landing your crit also deals 4 damage to you.
return {
	id = "MutuallyAssuredDestruction",
	name = "Mutually Assured Destruction",
	desc = "Clashes deal 35% bonus damage. Landing your critical deals 4 damage to you.",
	style = "Lethwei", -- style perk: only Lethwei can have it
	behaviour = "Modifiers",
	mods = { clashDamage = 0.35, critSelfDamage = 4 },
}
