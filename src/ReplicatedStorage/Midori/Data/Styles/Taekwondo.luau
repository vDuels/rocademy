--!strict
-- Taekwondo style (user, 2026-10-18). Placeholder: Gio's numbers; Assets/Animations/Taekwondo holds copies of Gio's anims until real ones exist. Fields left out fall back to Data/Defaults via MoveSchema.
-- Taekwondo/1-4 (Gio copies) have no hitbox marker, so animHit = startup (clips play at 1x, hit at 0.27).
-- Every Taekwondo hitbox: front edge 0.75 closer (user, 2026-10-29); depth -0.75, centre +0.375, so the
-- near edge stays put. M1 front edge 5.25 -> 4.5 studs out.
local M1_BOX = { size = Vector3.new(5, 5, 4.25), offset = CFrame.new(0, 0, -2.375) } -- was 5x5x5 at -2.75 (user, 2026-10-11: -0.5)

local M1_DAMAGE = 4 -- the M2 deals the same (user, 2026-10-29); nerf 5 -> 4 (user, 2026-10-30)

local function m1(anim: string)
	return {
		kind = "M1",
		anim = anim,
		animHit = 0.265,
		startup = 0.28, -- user, 2026-10-10
		endlag = 0.175, -- user, 2026-10-18
		damage = M1_DAMAGE,
		hitbox = M1_BOX,
	}
end

return {
	name = "Taekwondo",
	rarity = "Rare", -- style reroll tier (Shared/Rarity)
	idle = "Taekwondo/Idle", -- combat-mode idle
	m1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" },
	m2 = "M2",
	r = "Critical",
	perks = { "ReflexStep" }, -- style perks (always on), see Data/Perks (Aerial Ace is Gio-only)
	guardMax = 16, -- user, 2026-10-10
	moves = {
		M1_1 = m1("Taekwondo/1"),
		M1_2 = m1("Taekwondo/2"),
		M1_3 = m1("Taekwondo/3"),
		M1_4 = m1("Taekwondo/4"),
		-- Step-in kick (user, 2026-10-29): the 4-stud step-in starts ON CLICK and takes 0.4s (was a 0.3s dash
		-- after the windup), the kick lands at 0.5 (startup), then 0.2s endlag. M1_4's clip, 50% anti-heal.
		-- The step goes along the facing (no camera steer). Damage / hitbox unchanged.
		M2 = {
			kind = "M2",
			limbFx = "Left Leg", -- M2 limb flash (user, 2026-10-16)
			antiHeal = 0.5, -- user, 2026-10-29 (was 1)
			anim = "Taekwondo/1", -- M1_1's clip (user, 2026-10-29; was Taekwondo/4, Karate/M2)
			animHit = 0.265, -- M1_1's hit, played at 0.265/0.4 so it lands on the hit
			startup = 0.4, -- the hit (user, 2026-10-29; was 0.5, 0.55)
			endlag = 0.2, -- user, 2026-10-29 (was 0.5)
			damage = M1_DAMAGE, -- same as an M1 (user, 2026-10-29; was 9)
			hitbox = { size = Vector3.new(5, 5, 4.75), offset = CFrame.new(0, 0, -2.875) }, -- front 6 -> 5.25 (user, 2026-10-29; was 5x5x5.5 at -3.25)
			step = { at = 0, distance = 4, duration = 0.37 }, -- on click, 4 studs over 0.37s (user, 2026-10-29; was 0.3, 0.4)
		},
		-- No guard break (user, 2026-10-29; a guard-breaking follow-up kick was added and removed the same day).
		-- Parryable like everything else.
		Critical = {
			kind = "R",
			limbFx = "Left Leg", -- crit limb flash (user, 2026-10-16)
			anim = "Taekwondo/Critical",
			animHit = 0.6, -- user, 2026-10-10
			startup = 0.6,
			endlag = 0.1, -- user, 2026-10-18
			damage = 7, -- user, 2026-10-29 (was 11)
			antiHeal = 0.2, -- user, 2026-10-29 (was none)
			tags = { GuardBreak = false, Strip = true }, -- no guard break; any block counts as a weak guard (stripped) (user, 2026-10-29)
			-- hitstun: the default endlag + HITSTUN_PAD (0.82), longer stun (user, 2026-10-11; was 0.5)
			hitbox = { size = Vector3.new(5, 5, 4.25), offset = CFrame.new(0, 0, -2.625) }, -- front 5.5 -> 4.75 (user, 2026-10-29; was 5x5x5 at -3; nerfed from 6.5 2026-10-11; a cylinder was tried and reverted)
			-- 0.3 -> 0.65, runs past the hit; steers with the camera, no turn cap (user, 2026-10-11)
			step = { at = 0.3, distance = 6, duration = 0.35, steer = true },
			-- Countered out of the windup (user, 2026-10-29): the "dual exchange" (Clash) stun clip for the same
			-- stun, and pushed 3 studs instead of the counter's own knockback (0.2s is my pick).
			countered = { clip = "Clash", knockback = { distance = 3, duration = 0.2 } },
		},
	},
	-- Follow-ups allowed to break the section 2 invariants, with the reason.
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
