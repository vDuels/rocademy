--!strict
-- Slugger style perk (user, 2026-10-24). Attack speed bonuses (adrenaline, Focus windups) no longer
-- speed you up; each 1% of speed you would have gained is 2.5% more damage instead (CombatService.startAttack).
-- The M1s' natural 30% anti-heal lives in Data/Styles/Slugger (antiHeal = 0.3).
return {
	id = "Slugger",
	name = "Slugger",
	desc = "Attack speed bonuses no longer affect you; each 1% becomes 2.5% damage instead. M1s have 30% anti-heal.",
	style = "Slugger", -- style perk: only Slugger can have it
	behaviour = "Modifiers",
	mods = { speedToDamage = 2.5 },
}
