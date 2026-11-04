--!strict
-- Karate style (user, 2026-10-12). Fields left out fall back to Data/Defaults via MoveSchema.
-- M1: 4-hit chain, hitbox 0.3s after the click (user). Karate/1 is a 0.5s clip with no marker, so animHit = startup.
-- M2/Crit are Basic's numbers and anims (placeholders until Karate ones exist).
local M1_BOX = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -2.25) } -- same as Basic

-- Every M1 hits 0.27s after the click (user). animHit = when the punch lands in the clip; equal to
-- startup = clips play at their real speed (1x). 0.45 was my keyframe guess (2026-10-14), user said wrong.
local function m1(anim: string)
	return {
		kind = "M1",
		anim = anim,
		animHit = 0.4,
		startup = 0.27,
		endlag = 0.25,
		damage = 6, -- user, 2026-10-13 (6 -> 5 -> 5.5 -> 6); Measured Strikes scales hits 2-4
		hitbox = M1_BOX,
	}
end

return {
	name = "Karate",
	rarity = "Rare", -- style reroll tier (Shared/Rarity), user 2026-10-12
	idle = "Karate/Idle",
	m1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" },
	guardMax = 25,
	perks = { "MeasuredStrikes" }, -- style perks (always on), see Data/Perks
	m2 = "M2",
	r = "Crit",
	moves = {
		M1_1 = m1("Karate/1"),
		M1_2 = m1("Karate/2"),
		M1_3 = m1("Karate/3"),
		M1_4 = m1("Karate/4"),
		M2 = {
			kind = "M2",
			limbFx = "Left Leg", -- M2 limb flash (user, 2026-10-16)
			antiHeal = 1, -- user, 2026-10-14
			anim = "Karate/M2", -- user, 2026-10-15
			animHit = 0.55, -- hit in the clip (user); played at 0.7/0.5 = 1.4x so it lands on startup
			startup = 0.475, -- user
			endlag = 0.5,
			damage = 9,
			hitbox = { size = Vector3.new(5, 5, 5.5), offset = CFrame.new(0, 0, -2.25) },
		},
		Crit = {
			kind = "R",
			limbFx = "Right Leg", -- crit limb flash (user, 2026-10-16)
			anim = "Karate/Critical",
			animHit = 0.7,
			startup = 0.57,
			endlag = 0.5,
			damage = 14,
			hitstun = 0.8,
			antiHeal = 1, -- user, 2026-10-14
			knockback = { distance = 4, duration = 0.3, direction = "Away" }, -- user asked for knockback; 6 studs / 0.3s are my pick
			hitbox = { size = Vector3.new(4, 4, 5), offset = CFrame.new(0, 0, -3.25) }
		},
	},
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
