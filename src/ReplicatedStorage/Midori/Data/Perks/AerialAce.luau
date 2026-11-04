--!strict
-- Gio style perk (user, 2026-10-10). The critical gives i-frames from `at` seconds into its
-- startup, for `duration` seconds (user, 2026-10-11: 0.2 -> 0.7, so 0.1s past the 0.6 hit).
return {
	id = "AerialAce",
	name = "Aerial Ace",
	style = "Gio", -- style perk: only Gio can have it
	behaviour = "AttackIframes", -- ServerScriptService/Midori/PerkBehaviours/<behaviour>
	kind = "R", -- which move kind gets the i-frames
	at = 0.2, -- seconds into startup (scaled with attack speed like startup)
	duration = 0.5, -- how long they last (scaled the same way), may run into endlag; nil = until the hitbox
}
