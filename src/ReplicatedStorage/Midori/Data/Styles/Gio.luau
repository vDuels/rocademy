--!strict
-- Gio style. Fields left out fall back to Data/Defaults via MoveSchema.
-- Gio/1-4 have no hitbox marker, so animHit = startup (clips play at 1x, hit at 0.27).
local M1_BOX = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -2.25) } -- reach 5 (user, 2026-10-11: -0.5)

local function m1(anim: string)
	return {
		kind = "M1",
		anim = anim,
		animHit = 0.28,
		startup = 0.28, -- user, 2026-10-10
		endlag = 0.2,
		damage = 5, -- user, 2026-10-30 (nerf, was 6)
		hitstun = 0.2 + 0.22 - 0.1, -- endlag + HITSTUN_PAD (0.22) - 0.1 (user, 2026-10-30)
		hitbox = M1_BOX,
	}
end

return {
	name = "Gio",
	rarity = "Rare", -- style reroll tier (Shared/Rarity)
	idle = "Gio/Idle", -- combat-mode idle
	m1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" },
	m2 = "M2",
	r = "Critical",
	perks = { "AerialAce" }, -- style perks (always on), see Data/Perks
	guardMax = 20, -- user, 2026-10-10
	moves = {
		M1_1 = m1("Gio/1"),
		M1_2 = m1("Gio/2"),
		M1_3 = m1("Gio/3"),
		M1_4 = m1("Gio/4"),
		M2 = {
			kind = "M2",
			limbFx = "Right Leg", -- M2 limb flash (user, 2026-10-16)
			antiHeal = 0.6, -- user, 2026-10-30 (nerf, was 1)
			anim = "Gio/M2",
			animHit = 0.4, -- hit at 0.4 (user, 2026-10-10)
			startup = 0.4,
			endlag = 0.4, -- user gave 0.4 "on whiff"; hits use it too for now
			cooldown = 0.3, -- after endlag (copied from Basic M2)
			damage = 8, -- user, 2026-10-10
			hitbox = { size = Vector3.new(5, 5, 5.5), offset = CFrame.new(0, 0, -3.25) }, -- reach 6 (user, 2026-10-11: -0.5)
			step = { at = 0.27, distance = 3, duration = 0.3 }, -- steps in along the facing
			knockback = { distance = 2, duration = 0.3 },
		},
		-- GuardBreak (R default); parryable like everything else.
		Critical = {
			kind = "R",
			limbFx = "Left Leg", -- crit limb flash (user, 2026-10-16)
			anim = "Gio/Critical",
			animHit = 0.6, -- user, 2026-10-10
			startup = 0.6,
			endlag = 0.6,
			damage = 11, -- user, 2026-10-10
			-- hitstun: the default endlag + HITSTUN_PAD (0.82), longer stun (user, 2026-10-11; was 0.5)
			hitbox = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -3) }, -- reach 5.5 (nerfed from 6.5, user 2026-10-11; a cylinder was tried and reverted)
			-- 0.3 -> 0.65, runs past the hit; steers with the camera, no turn cap (user, 2026-10-11)
			step = { at = 0.3, distance = 6, duration = 0.35, steer = true },
		},
	},
	-- Follow-ups allowed to break the section 2 invariants, with the reason.
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
