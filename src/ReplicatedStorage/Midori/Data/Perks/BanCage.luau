--!strict
-- Ban Hammer style perk (user, 2026-10-15): the critical gives i-frames from the press until the hitbox.
return {
	id = "BanCage",
	name = "Ban Cage",
	style = "BanHammer", -- style perk: only Ban Hammer has it
	behaviour = "AttackIframes", -- ServerScriptService/Midori/PerkBehaviours/<behaviour>
	kind = "R", -- which move kind gets the i-frames
	at = 0, -- seconds into startup
	duration = nil, -- nil = until the hitbox
}
