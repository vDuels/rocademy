--!strict
-- Lethwei style (user, 2026-10-16). Fields left out fall back to Data/Defaults via MoveSchema.
-- M1: animHit 0.37 / startup 0.37 (user). M2 is Basic's numbers on Lethwei's clip,
-- animHit = startup until the clip is measured.
local M1_BOX = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -2.25) } -- same as Basic

local function m1(anim: string)
	return {
		kind = "M1",
		anim = anim,
		animHit = 0.37, -- user
		startup = 0.3, -- user
		endlag = 0.25,
		damage = 5,
		hitbox = M1_BOX,
	}
end

return {
	name = "Lethwei",
	rarity = "Epic", -- user
	idle = "Lethwei/Idle",
	m1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" },
	guardMax = 27,
	perks = { "MutuallyAssuredDestruction" }, -- style perk (always on), see Data/Perks
	m2 = "M2",
	r = "Crit",
	moves = {
		M1_1 = m1("Lethwei/1"),
		M1_2 = m1("Lethwei/2"),
		M1_3 = m1("Lethwei/3"),
		M1_4 = m1("Lethwei/4"),
		M2 = {
			kind = "M2",
			limbFx = "Right Leg", -- M2 limb flash (user, 2026-10-16)
			antiHeal = 1,
			anim = "Lethwei/M2",
			animHit = 0.36,
			startup = 0.43,
			endlag = 0.6,
			cooldown = 0.3,
			damage = 10,
			hitbox = { size = Vector3.new(5, 5, 5.5), offset = CFrame.new(0, 0, -3.25) },
		},
		-- user, 2026-10-16. Unparryable, no guard break; a blocked hit always strips the block.
		Crit = {
			kind = "R",
			limbFx = "Head", -- crit limb flash (user, 2026-10-16)
			anim = "Lethwei/Critical",
			animHit = 0.47,
			startup = 0.45,
			endlag = 0.4,
			damage = 14,
			cooldown = 6,
			guardDamage = 10, -- user, 2026-10-16 (was = damage, 16)
			antiHeal = 1, -- 100% (user, 2026-10-16)
			blur = 4, -- very subtle landed-hit blur for both fighters (user); 4 of BlurEffect's 0-56 is my pick
			hitstun = 1.0, -- endlag + 0.6 extra stun (user)
			tags = { GuardBreak = false, Unparryable = true, Strip = true },
			cleanHitSfx = "Criticalhit", -- folder in Sfx/Styles/Lethwei, all played on a clean hit (user)
			clashSfx = "DualExchange", -- Sfx/Styles/Lethwei, played when the crit clashes (user)
			step = { at = 0.3, distance = 2, duration = 0.15 }, -- steps in 0.3 -> 0.45
			knockback = { distance = 1.5, duration = 0.3 }, -- 1.5 studs (user); 0.3s is my pick
			-- Shorter than usual (user): reach 5 vs Basic crit's 6.5; numbers are my pick.
			hitbox = { size = Vector3.new(5, 5, 3.5), offset = CFrame.new(0, 0, -1.75) },
		},
	},
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
