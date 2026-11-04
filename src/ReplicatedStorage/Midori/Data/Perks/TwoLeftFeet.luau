--!strict
-- Feng style perk (user, 2026-10-29). No real parries: every blocked hit is a weak guard (Strip: blocked,
-- guard damage, then the block drops with its cooldown). A block pressed in the parry window still
-- parry-stuns the attacker (Parryed), but you take the weak guard too. In exchange the guard regen pause
-- after a blocked hit is cut (guardRegenDelayCut 0.5 = D.GUARD_REGEN_DELAY 0.6s -> 0.3s; my number).
-- Logic: HitResolver.resolve (weakGuard / clumsyParry), GuardSystem.damage (guardRegenDelayCut).
return {
	id = "TwoLeftFeet",
	name = "Two Left Feet",
	desc = "You can't parry: every hit you block counts as a weak guard. A block in the parry window still staggers the attacker as if parried. Your guard starts regenerating twice as soon after a blocked hit.",
	style = "Feng", -- style perk: always on for Feng
	icon = 1, -- ponytail: borrowed (Fleet Foot's) until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(150, 220, 120),
	behaviour = "Modifiers",
	mods = { weakGuard = 1, clumsyParry = 1, guardRegenDelayCut = 0.5 },
}