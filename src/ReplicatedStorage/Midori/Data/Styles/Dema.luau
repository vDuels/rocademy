--!strict
-- Dema style (user, 2026-10-28): unobtainable, owner-given only (`rollable = false`, RoleService.canGiveStyle).
-- M1s / Crit are Basic's (placeholders). Assets/Animations/Dema holds copies of Basic's clips + Slugger's
-- M2 / M2Swing until Dema's own are uploaded. animHit = the copied clips' markers.
local M1_BOX = { size = Vector3.new(5, 5, 8), offset = CFrame.new(0, 0, -5.25) }

local function m1(anim: string, animHit: number, startup: number)
	return {
		kind = "M1",
		anim = anim,
		animHit = 0.35,
		startup = 0.3,
		endlag = 0,
		damage = 9,
		antiHeal = 0.4, -- user, 2026-10-28
		swingSfx = "Swing", -- Sfx/Styles/Dema: a folder, one at random
		hitSfx = "Hit",
		hitbox = M1_BOX,
	}
end

return {
	name = "Dema",
	rollable = false, -- unob: not in rolls; only the owner can give it
	weapon = "Dema", -- Assets/Weapons/Dema on the Right Arm ("Handle" joint, rig workspace.DemaAnim)
	idle = "Dema/Idle",
	-- In combat mode the idle plays like every style's (standing still only; idleWhileMoving turned off
	-- by the user). Out of combat mode (T off) the sword is put away: no idle, and its Handle joint sits
	-- at `holster` (user, 2026-10-28).
	holster = CFrame.new(0, -1, 0) * CFrame.Angles(math.rad(-90), 0, 0),
	m1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" },
	guardMax = 25,
	m2 = "M2",
	r = "Crit",
	moves = {
		M1_1 = m1("Dema/1", 0.267, 0.267),
		M1_2 = m1("Dema/2", 0.283, 0.27),
		M1_3 = m1("Dema/3", 0.25, 0.25),
		M1_4 = m1("Dema/4", 0.267, 0.267),
		-- Blink (user, 2026-10-28): Slugger's hold-to-charge M2 (tap = release at startup, auto release at
		-- startup + charge.time). The hit is a 20-wide lane ahead that grows while you hold: 0 at the press,
		-- 40 at startup, 60 at full charge (client BlinkLane draws it). At the hit you teleport to its end,
		-- through whoever's in it, with a wind trail for the jump. I-frames from the press until 1s after
		-- the hit. Landed: ragdoll + knocked along your facing (toward where you landed) with a launch, a
		-- strong ragdoll (wind trail). Tier damage / anti-heal / guard break are Slugger's (placeholders).
		M2 = {
			kind = "M2",
			limbFx = "Right Arm",
			anim = "Dema/M2", -- windup, held on its last frame
			startup = 0.35, -- tap release; the lane reaches blink.min here
			endlag = 0.45,
			cooldown = 0.3,
			damage = 10,
			antiHeal = 1, -- every charge level: full anti-heal (user, 2026-10-28)
			charge = {
				time = 0.65, -- past startup: auto release at 1s, lane at blink.max
				swing = { anim = "Dema/M2Swing", hit = 0.08 },
				tiers = {
					{ at = 0, damage = 10, antiHeal = 1, guardBreak = true }, -- user, 2026-10-28
					{ at = 0.6, damage = 14, antiHeal = 1, guardBreak = true },
					{ at = 1, damage = 24, antiHeal = 1, guardBreak = true },
				},
			},
			-- 100% guard chip (user, 2026-10-28): at every charge level a block breaks the guard and the whole
			-- hit goes through it (Pierce: damage, knockback, ragdoll). Can't be parried.
			tags = { GuardBreak = true, Pierce = true, Unparryable = true },
			swingSfx = "DemaM2", -- on press (Sfx/Styles/Dema)
			impactSfx = "DemaRelease", -- on release
			hitSfx = "Hit",
			blink = { width = 20, height = 6, min = 40, max = 60, stand = 0.3 }, -- stand: still for 0.3s after the TP (user)
			iframes = 1, -- after the hit (user)
			-- Placeholder: the real hitbox is the blink lane (CombatMath.blinkHitbox).
			hitbox = { size = Vector3.new(20, 6, 40), offset = CFrame.new(0, 0, -20) },
			hitstun = 1.5, -- covers the ragdoll
			ragdoll = 1.5,
			strongRagdoll = true,
			-- distance / up / spin: my picks.
			knockback = { distance = 10, duration = 0.4, direction = "Facing", up = 40, spin = 12 },
		},
		Crit = {
			kind = "R",
			anim = "Dema/4", -- placeholder (Basic's)
			animHit = 0.267,
			startup = 0.6,
			endlag = 0.5,
			damage = 12,
			hitstun = 0.5,
			hitbox = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -3) },
		},
	},
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
