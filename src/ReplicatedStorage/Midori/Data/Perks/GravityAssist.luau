--!strict
-- Prodigy style perk (user, 2026-10-24): every dash cuts 10% of the critical's full cooldown off what's
-- left, and a dash that dodges a hit cuts another 20% (once per dash). CombatService.cutRCooldown.
return {
	id = "GravityAssist",
	name = "Gravity Assist",
	desc = "Every dash cuts 10% off your critical's cooldown. Dodging a hit with it cuts another 20%.",
	style = "Prodigy", -- style perk: always on for Prodigy
	icon = 7, -- ponytail: borrowed (Technical's) until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(150, 210, 255),
	behaviour = "Modifiers",
	mods = { dashRCooldownCut = 0.1, dodgeRCooldownCut = 0.2 },
}
