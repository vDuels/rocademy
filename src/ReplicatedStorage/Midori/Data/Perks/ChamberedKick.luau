--!strict
-- Furious Feng style perk (user, 2026-11-02): the dash M1 (dash kick) only works with a chambered dash.
-- Throwing it burns the chamber and gives the normal dash's cooldown back, so: raw dash -> kick (spends the
-- chamber, dash is ready again) -> dash again. Logic: CombatService.requestAttack / CombatController.tryAttack
-- (dashM1Chamber).
return {
	id = "ChamberedKick",
	name = "Chambered Kick",
	desc = "Dash attacks need a chambered dash. Using one burns it and refunds your dash cooldown.", -- all dash moves (user, 2026-11-03)
	style = "FuriousFeng", -- style perk: always on for Furious Feng
	icon = 1, -- ponytail: borrowed (Fleet Foot's) until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(40, 255, 190),
	behaviour = "Modifiers",
	mods = { dashM1Chamber = 1 },
}
