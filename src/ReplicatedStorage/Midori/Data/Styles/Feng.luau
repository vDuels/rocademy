--!strict
-- Feng style. Fields left out fall back to Data/Defaults via MoveSchema.
-- animHit = time the hit lands in the animation at 1x speed (Feng/1, 2026-10-03: hit @ 0.4,
-- clip 1.0, no marker in the clip). The client scales playback so that moment lands
-- exactly on `startup`.
local M1_BOX = { size = Vector3.new(5, 5, 6), offset = CFrame.new(0, 0, -3) }

local function m1(anim: string, animHit: number, startup: number)
	return {
		kind = "M1",
		anim = anim,
		animHit = animHit,
		startup = startup,
		endlag = 0.3,
		damage = 8,
		antiHeal = 0.3, -- user, 2026-10-29
		hitbox = M1_BOX,
		swingSfx = "Swing", -- sounds live in Assets/Sfx/Styles/Feng
		hitSfx = "M1",
		knockback = { distance = 3, duration = 0.15 }, -- along Feng's facing
	}
end

return {
	name = "Feng",
	rarity = "Legendary", -- style reroll tier (Shared/Rarity); styles without one are Common
	-- Combat-mode idle (played while in combat mode and standing still). Leave the
	-- Animation's AnimationId empty to keep the normal idle.
	idle = "Feng/Idle",
	m1Chain = { "M1_1"},
	comboEndDelay = 0.6, -- after M1 endlag, wait this long before M1 is usable again
	guardMax = 12, -- user, 2026-10-10
	perks = { "ChamberedDash" }, -- style perks (always on), see Data/Perks (TwoLeftFeet taken off 2026-10-29; the perk still exists)
	m2 = "M2",
	r = "Critical",
	moves = {
		-- Critical: CriticalStart windup, then a CriticalLoop rush paid for with adrenaline
		-- (now a flat 10 studs, adrenaline buys none: user, 2026-10-29). Steers slightly toward the camera. The first
		-- contact ends it; running dry plays CriticalMiss with a 0.4s easing carry, then endlag.
		Critical = {
			kind = "R",
			limbFx = "Right Leg", -- crit limb flash (user, 2026-10-16)
			anim = "Feng/CriticalStart", -- no animHit: the windup clip is stretched over startup
			startup = 0.4, -- user nerf 2026-10-06 (was 0.3)
			endlag = 0.1, -- after a hit / block (user, 2026-10-06); a whiff uses rush.missEndlag
			hitstun = 0.5,
			damage = 4, -- + rush.damagePerStud for every stud crossed
			hitbox = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -3.5) }, -- along the rush direction, reaches 6 studs out (user, 2026-10-29: was 8 long at -5 = 9 out)
			knockback = { distance = 3, duration = 0.2, direction = "Away" }, -- + rush.knockbackPerStud per stud
			swingSfx = "Critical", -- Sfx/Styles/Feng, on startup
			-- guard breaks like every R by default (user, 2026-10-31; was GuardBreak = false)
			hitSfx = "CriticalHit", -- on a landed hit
			rush = {
				speed = 50, -- studs/s
				freeStuds = 16, -- rush distance (user, 2026-10-29; was 16 + adrenaline/20)
				adrPerStud = 0, -- adrenaline buys no distance (user, 2026-10-29; was 20)
				turnRate = 200, -- deg/s toward the camera (user wanted more control than 90)
				carry = 0.17, -- hit or miss: keeps going this long, easing to a stop = speed * carry / 2 = 4.25 studs (user, 2026-10-29; was 0.25)
				missEndlag = 0.7, -- whiff: endlag after the carry, rooted in place (user, 2026-10-06)
				damagePerStud = 0.5,
				knockbackPerStud = 0.1,
				loopAnim = "Feng/CriticalLoop",
				missAnim = "Feng/CriticalMiss",
			},
		},
		M1_1 = m1("Feng/1", 0.4, 0.4), -- startup 0.4 -> 0.37 (user, 2026-10-30)
		M2 = {
			kind = "M2",
			limbFx = "Right Leg", -- M2 limb flash (user, 2026-10-16)
			antiHeal = 0.5, -- user, 2026-10-29 (was 0.7)
			anim = "Feng/M2",
			animHit = 0.1, -- hit lands at 0.1 in Feng/M2 (user, 2026-10-03)
			startup = 0.1,
			endlag = 0.2,
			hitstun = 0.5,
			cooldown = 3.4, -- after endlag (above the 1.2 universal minimum, so it wins)
			damage = 3,
			-- Upright cylinder centred on the root (hits all around).
			hitbox = { shape = "Cylinder", radius = 4.3, height = 5, offset = CFrame.new(0, 0, 0) },
			swingSfx = "M2",
			-- Hits all around, so push straight away from Feng (server-run, inside the hitstun).
			knockback = { distance = 3, duration = 0.25, direction = "Away" },
		},
	},
	-- Follow-ups allowed to break the section 2 invariants, with the reason.
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
