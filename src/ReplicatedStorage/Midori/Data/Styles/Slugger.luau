--!strict
-- Slugger style (user, 2026-10-24). Placeholder numbers (Gio's, heavier), my pick until the user tunes them.
-- Assets/Animations/Slugger holds copies of Gio's anims until the Workspace "[Converted] Slugger" AnimSaves are uploaded.
-- No hitbox markers, so animHit = startup. Fields left out fall back to Data/Defaults via MoveSchema.
local M1_BOX = { size = Vector3.new(5, 5, 5.5), offset = CFrame.new(0, 0, -2.75) } -- same as Gio

local function m1(anim: string)
	return {
		kind = "M1",
		anim = anim,
		animHit = 0.35,
		startup = 0.37,
		endlag = 0.1,
		hitstun = 0.1 + 0.22, -- endlag + HITSTUN_PAD (0.22) + 0.1 extra (user, 2026-10-24)
		antiHeal = 0.3, -- natural 30% anti-heal on M1s (Slugger perk, user 2026-10-24)
		damage = 6, -- user, 2026-10-25 (nerf, was 8)
		hitSfx = "Hit", -- Slugger's own hit sound, Assets/Sfx/Styles/Slugger (user, 2026-10-24)
		hitbox = M1_BOX,
	}
end

return {
	name = "Slugger",
	rarity = "Legendary", -- user, 2026-10-25 (was Epic)
	idle = "Slugger/Idle", -- combat-mode idle
	m1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" },
	m2 = "M2",
	r = "Critical",
	perks = { "Slugger" }, -- style perk (always on), see Data/Perks
	guardMax = 25,
	moves = {
		M1_1 = m1("Slugger/1"),
		M1_2 = m1("Slugger/2"),
		M1_3 = m1("Slugger/3"),
		M1_4 = m1("Slugger/4"),
		-- Hold to charge (user, 2026-10-25): M2 is the windup (no walking), held up to 1s then auto release;
		-- a tap releases at 0.35. Release plays M2Swing, its hit 0.08 in. Tier by windup length:
		-- tap 4 dmg / 10% anti-heal; 0.6s 8 / 50% + 2.7-stud step-in; full 1s 10 / 100%, guard break, 6.2 studs.
		M2 = {
			kind = "M2",
			limbFx = "Right Arm",
			antiHeal = 0.1,
			anim = "Slugger/M2", -- windup, held on its last frame
			startup = 0.35, -- tap release
			endlag = 0.45,
			cooldown = 0.3,
			damage = 4,
			charge = {
				time = 0.65, -- past startup: auto release at 0.35 + 0.65 = 1s
				swing = { anim = "Slugger/M2Swing", hit = 0.08 },
				tiers = {
					{ at = 0, damage = 4, antiHeal = 0.1 },
					{ at = 0.6, damage = 8, antiHeal = 0.5, step = 2.7 }, -- user, 2026-10-31 (was 2)
					{ at = 1, damage = 10, antiHeal = 1, step = 6.2, guardBreak = true }, -- user, 2026-10-31 (was 5)
				},
			},
			swingSfx = "M2Start", -- on press
			impactSfx = "M2Release", -- on release
			hitSfx = "M2Hit",
			hitbox = { size = Vector3.new(5, 5, 5.5), offset = CFrame.new(0, 0, -3.25) },
			knockback = { distance = 3, duration = 0.3 },
		},
		-- User, 2026-10-25: 0.4 click to hitbox, 0.7 stun, 0.2 endlag. No guard break: a blocked hit
		-- strips the guard as if weak. Never counters / clashes (NoCounter), and doesn't cancel a move
		-- it hits (NoInterrupt): someone mid-attack takes the damage and carries on.
		-- User, 2026-10-31: Unparryable again, and no more slow zone (was slowZone = true).
		Critical = {
			kind = "R",
			limbFx = "Right Arm",
			anim = "Slugger/Critical",
			animHit = 0.6, -- the clip's hit: plays at 1.5x so it lands at 0.4
			startup = 0.4,
			endlag = 0.35,
			cooldown = 8, -- user, 2026-10-25 (was 10); starts when endlag ends
			hitstun = 0.7,
			damage = 4,
			tags = { GuardBreak = false, Strip = true, NoCounter = true, NoInterrupt = true, Unparryable = true },
			impactSfx = "CriticalSlam", -- the slam, at the hitbox time, hit or not
			slamFx = true, -- its rocks (user, 2026-11-01: they went with the slow zone; visual only now)
			contactSfx = "CriticalHit", -- whenever it connects: hit, guard, anything (user, 2026-10-25)
			-- All around you, 10 studs (user, 2026-10-25; was sized to match the old slow zone).
			hitbox = { shape = "Cylinder", radius = 10, offset = CFrame.new() },
			-- Pulls them in at you (user, 2026-10-25), from anywhere in the radius: up to 10 studs, stopping in front.
			-- arc: a slight bump up on the way in, landing as the pull ends (user: 2 was far too high).
			knockback = { distance = 10, duration = 0.35, direction = "Toward", arc = 1 },
		},
	},
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
