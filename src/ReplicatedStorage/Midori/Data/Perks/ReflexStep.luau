--!strict
-- Taekwondo style perk (user, 2026-10-29: "landing a counter reduces dash cd by 35%"; named by me on request).
-- A landed counter crit (clashes count: both sides counter) cuts 35% of the FULL dash cooldown off what's
-- left, like Afterburner. Logic: HitResolver.applyHit (counterDashRefund).
return {
	id = "ReflexStep",
	name = "Reflex Step",
	desc = "Landing a counter cuts 35% of your dash cooldown.",
	style = "Taekwondo", -- style perk: always on for Taekwondo
	icon = 1, -- ponytail: borrowed (Fleet Foot's) until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(120, 220, 255),
	behaviour = "Modifiers",
	mods = { counterDashRefund = 0.35 },
}