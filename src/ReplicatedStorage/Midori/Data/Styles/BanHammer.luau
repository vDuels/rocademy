--!strict
-- Ban Hammer style (user, 2026-10-15). Carries Assets/Weapons/BanHammer, jointed to the Torso by its
-- "handle" Motor6D (WeaponService), same names and C0/C1 as workspace.BanHammerRig (the user's anim rig).
-- Clips that don't key "handle" leave the hammer at C0 = the Torso's centre.
-- All numbers are Basic's (placeholders). Assets/Animations/BanHammer/* are EMPTY until the user publishes
-- them; an empty clip is skipped silently. animHit = startup until real clips are measured.
local M1_BOX = { size = Vector3.new(5, 5, 8), offset = CFrame.new(0, 0, -3.75) } -- reach 7.75 (user, 2026-10-15: +3 over Basic's 4.75; back edge unchanged)

return {
	name = "BanHammer",
	display = "Ban Hammer", -- what the menus show (user, 2026-11-01); `name` stays the id (saves, assets, Style attribute)
	rollable = false, -- not in the style reroll pool (user, 2026-10-15)
	weapon = "BanHammer",
	idle = "BanHammer/Idle",
	-- The idle is the hammer hold: it plays all the time (moving, in or out of combat mode) at Idle priority,
	-- over walk/run (Core). Key only the arms + handle in it, or it freezes the legs while walking.
	idleWhileMoving = true,
	m1Chain = { "M1_1" }, -- 1-hit chain (user): the combo-end lock (D.COMBO_END_DELAY) follows every M1
	guardMax = 25,
	perks = { "BanCage" }, -- crit i-frames
	m2 = "M2",
	r = "Crit",
	moves = {
		M1_1 = {
			kind = "M1",
			anim = "BanHammer/1",
			animHit = 0.3, -- hit event in the clip (user)
			startup = 0.3, -- user
			endlag = 0.2,
			damage = 6,
			hitbox = M1_BOX,
		},
		M2 = {
			kind = "M2",
			antiHeal = 1,
			anim = "BanHammer/M2",
			animHit = 0.36,
			startup = 0.36,
			endlag = 0.4,
			damage = 10,
			hitbox = { size = Vector3.new(5, 5, 5.5), offset = CFrame.new(0, 0, -3.25) },
		},
		-- Ban cage (user, 2026-10-15): an all-around hit at 0.3 with i-frames until it lands (perk BanCage),
		-- rooted in place, and the Bancage VFX dropping onto the user. Endlag/damage/hitstun are Basic's.
		Crit = {
			kind = "R",
			anim = "BanHammer/Critical",
			animHit = 0.3, -- hit event in the clip (user)
			startup = 0.3, -- user
			endlag = 0.5,
			damage = 12,
			hitstun = 0.5,
			-- Upright cylinder centred on the root; radius 6 = the cage's 12-stud width (my pick).
			hitbox = { shape = "Cylinder", radius = 6, height = 7, offset = CFrame.new() },
			rooted = true, -- can't walk during the crit (user)
			tags = { Unblockable = true }, -- can't be blocked or parried (user); only a dash gets out
			vfx = "Bancage", -- StarterPlayerScripts/Midori/Bancage
			-- Sounds in Assets/Sfx/Styles/BanHammer (user): on press, on a landed hit, and the whole
			-- CriticalImpact folder together at the hitbox time.
			swingSfx = "Critical",
			hitSfx = "CriticalHit",
			impactSfx = "CriticalImpact",
			-- Landed (user): the victim is pulled right in front of you over 0.5 (gap 3 = my pick) and held,
			-- you keep i-frames, and Execute starts as the pull ends (hold 0: user removed the 0.5 wait).
			grab = { move = "Execute", pull = 0.5, hold = 0, gap = 3 },
		},
		-- The crit's grab follow-up (user, 2026-10-15). Not on a key: CombatService starts it when the
		-- grab's hold ends. M1's clip at half speed (hit at 0.6), 50% of the victim's max HP, unblockable
		-- but parryable (ParryOnly), knocks back + ragdolls. No hitbox: it always lands on the grabbed victim
		-- (CombatService grabTarget) unless they parry or dash; the victim can't walk until the hit. kind R: the crit's cooldown starts after it.
		-- My picks: endlag 0.4 (M1's 0.2 at half speed), knockback 15 studs / 0.4s, ragdoll 1.5s.
		Execute = {
			kind = "R",
			anim = "BanHammer/1",
			animHit = 0.3, -- M1's hit event
			startup = 0.6, -- = the clip at 50% speed
			fixedStartup = true, -- adrenaline doesn't speed it up
			endlag = 0.4,
			damage = 0,
			maxHpDamage = 0.5,
			tags = { ParryOnly = true, GuardBreak = false },
			hitbox = M1_BOX,
			rooted = true,
			hitstun = 1.5, -- covers the ragdoll
			ragdoll = 1.5,
			-- up = launch speed in studs/s (user asked for upward force; 50 = my pick, ~6 studs high).
			-- spin = random tumble up to this rad/s (user asked for random rotation; 15 = my pick).
			knockback = { distance = 15, duration = 0.4, direction = "Away", up = 50, spin = 15 },
		},
	},
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
