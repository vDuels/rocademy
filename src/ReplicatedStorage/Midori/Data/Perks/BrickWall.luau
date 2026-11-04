--!strict
-- Rollable Epic trait (PerkRollService).
return {
	id = "BrickWall",
	name = "Brick Wall",
	desc = "Taking damage grants 3% damage reduction for 3s. Stacks to 30%, each stack has its own timer.",
	rollable = true,
	rarity = "Epic",
	icon = 8, -- HUD trait card: cell in D.HUD_ATLAS
	color = Color3.fromRGB(230, 80, 50), -- HUD trait card colour
	proc = "damageReduction", -- Fighter.proc key that lights the HUD card (no mods table)
	behaviour = "BrickWall",
	stack = 0.03, -- damage reduction per stack (user buff 2026-10-11, was 0.02)
	duration = 3, -- seconds each stack lasts
	maxStacks = 10, -- 10 x 3% = 30% cap; a hit at the cap refreshes the oldest stack
}
