--!strict
-- Firecracker style perk (user, 2026-10-11): M1s ignore adrenaline completely (no damage/speed
-- bonus, never spend it), the critical never spends it (its hits still get the adrenaline damage
-- bonus), and the barrage's final punch deals barrageFinisher x (adrenaline / 500) damage.
return {
	id = "Firecracker",
	name = "Firecracker",
	desc = "M1s ignore adrenaline. Your critical never spends it, and its final punch deals 1.5 x (adrenaline / 500) damage.",
	style = "Firecracker", -- style perk: only Firecracker can have it
	behaviour = "Modifiers",
	mods = { m1AdrenalineFree = 1, rAdrenalineFree = 1, barrageFinisher = 1.5 },
}
