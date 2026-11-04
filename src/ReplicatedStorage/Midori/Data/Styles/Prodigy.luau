--!strict
-- Prodigy style (user, 2026-10-23): copy of Karate's stats + anims for now (Prodigy anim folder = Karate clones).
-- M1: 4-hit chain, hitbox 0.3s after the click (user). Prodigy/1 is a 0.5s clip with no marker, so animHit = startup.
-- M2/Crit are Basic's numbers and anims (placeholders until Karate ones exist).
local M1_BOX = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -1.75) } -- reach 3.75 (user, 2026-10-25: -1, was Basic's 4.75)

-- Every M1 hits 0.27s after the click (user). animHit = when the punch lands in the clip; equal to
-- startup = clips play at their real speed (1x). 0.45 was my keyframe guess (2026-10-14), user said wrong.
local function m1(anim: string)
	return {
		kind = "M1",
		anim = anim,
		animHit = 0.27,
		startup = 0.2,
		endlag = 0.25,
		step = { at = 0, distance = 1, duration = 0.2 }, -- 1 stud, click -> hitbox (= startup) (user, 2026-10-23)
		damage = 4, -- user, 2026-10-13 (6 -> 5 -> 5.5 -> 6); Measured Strikes scales hits 2-4
		hitstun = 0.25 + 0.1, -- endlag + 0.1 instead of + HITSTUN_PAD (0.22) (user, 2026-10-24)
		hitbox = M1_BOX,
	}
end

return {
	name = "Prodigy",
	rarity = "Mythic", -- style reroll tier (Shared/Rarity); user 2026-10-24 (was Rare)
	idle = "Prodigy/Idle",
	m1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" },
	guardMax = 7,
	m2 = "M2",
	r = "Reentry", -- R = Eject, or Reentry within 2s of landing one (user, 2026-10-25; CombatMath.rMove)
	-- Focus (user, 2026-10-23): Astronaut turns it on, Spacesuit is its drawback. Every Prodigy perk is a
	-- style perk, always on (user, 2026-10-24: Cosmic Ray, Uppercut, Lightshow, Afterburner were rollable).
	perks = { "Astronaut", "Spacesuit", "CosmicRay", "UppercutToTheMoon", "Lightshow", "Afterburner", "GravityAssist" }, -- Microgravity (10% on-hit slow) removed (user, 2026-10-31)
	moves = {
		M1_1 = m1("Prodigy/1"),
		M1_2 = m1("Prodigy/2"),
		M1_3 = m1("Prodigy/3"),
		M1_4 = m1("Prodigy/4"),
		M2 = {
			kind = "M2",
			limbFx = "Right Arm", -- M2 limb flash (user, 2026-10-16)
			-- 30% (user, 2026-10-25; was 0.4): Uppercut to the Moon reaches 50% at full Focus (+10% x2).
			antiHeal = 0.3,
			anim = "Prodigy/M2", -- user, 2026-10-15
			animHit = 0.27, -- hit in the clip (user); played at 0.7/0.5 = 1.4x so it lands on startup
			startup = 0.55, -- user
			endlag = 0.5,
			damage = 9,
			hitbox = { size = Vector3.new(5, 5, 5.5), offset = CFrame.new(0, 0, -1.25) }, -- reach 4 (user, 2026-10-25: -2, was 6)
			-- Steps in 3 studs, 0.25 -> 0.55 = the hit (user asked for a step-in; numbers are my pick).
			step = { at = 0.25, distance = 3, duration = 0.3 },
		},
		-- Reentry (user, 2026-10-24): from range, dash at the target (up to 20 studs, with travel time) and
		-- punch on contact. Doesn't need or use the dash (user, 2026-10-24); landing it gives the dash back.
		-- Neutral on hit: hitstun = endlag, both act again at the same moment.
		-- Slugger's M2 clips (user, 2026-10-25): the windup over 0.4, held through the dash forward, then
		-- M2Swing on reaching the target (or at the end of a whiffed dash).
		Reentry = {
			kind = "R",
			limbFx = "Right Arm", -- user, 2026-10-25
			afterimage = true, -- the cutscene's ghost trail while it dashes (user, 2026-11-02)
			useShift = "Reentry", -- your screen: colours up, the target in focus (D.COLOR_SHIFT)
			targetShift = "ReentryTarget", -- their screen: you in focus
			anim = "Slugger/M2", -- windup, stretched over startup and held through the dash
			startup = 0.4, -- user, 2026-10-25 (was 0.1)
			endlag = 0.3,
			hitstun = 0.3, -- = endlag: neutral
			damage = 4,
			antiHeal = 0, -- user, 2026-10-25 (was 0.2)
			dashRefresh = true,
			locked = true, -- only within 2s of landing Eject; each Reentry needs a new one (user, 2026-10-25)
			close = { move = "Eject" }, -- R throws Eject at any range unless Reentry is unlocked (user, 2026-10-25; was 7 studs)
			-- With Lightshow at full Focus, landing it clean plays the ProdigyCrit cutscene instead (user,
			-- 2026-10-23): that hit deals no damage or push here, the cutscene does it all (HitResolver).
			cutscene = "ProdigyCrit",
			swingSfx = "ReentryStart", -- Sfx/Styles/Prodigy, on press (user, 2026-10-25)
			hitSfx = "ReentryLand", -- on a landed hit
			hitbox = { size = Vector3.new(5, 5, 4), offset = CFrame.new(0, 0, -2.5) }, -- along the dash
			rush = {
				speed = 70, -- studs/s: 20 studs in ~0.3s (my number)
				freeStuds = 20,
				turnRate = 200, -- deg/s, also caps the auto-aim so it can be dodged
				aim = "Target", -- auto-aims at whoever the Eject landed on (user, 2026-10-25; client)
				carry = 0, -- stops dead on the punch
				missEndlag = 0.4,
				contactAnim = "Slugger/M2Swing", -- the swing on reaching the target
				missAnim = "Slugger/M2Swing", -- ran out without reaching anyone: swings at air
			},
		},
		-- Eject (user, 2026-10-24): up close, a quick shove 8 studs back. Landing it gives the dash back.
		Eject = {
			kind = "R",
			limbFx = "Right Arm", -- user, 2026-10-25
			landShift = "Eject", -- landing it: a blue pseudo impact frame (D.COLOR_SHIFT)
			anim = "Slugger/1", -- Slugger's 1st M1 (user, 2026-10-25)
			hitSfx = "EjectLand", -- Sfx/Styles/Prodigy, on a landed hit (user, 2026-10-25)
			animHit = 0.35, -- the punch in Slugger/1 (Slugger's own animHit): plays at 0.35 / 0.2 = 1.75x so it lands on the hitbox
			startup = 0.2, -- "quickly" (my number)
			endlag = 0.35,
			hitstun = 0.35,
			damage = 0, -- a shove (user gave no damage)
			antiHeal = 0.2, -- wipes 20% of the victim's healable HP (user, 2026-10-25)
			focusShare = 0.4, -- landing it gains 40% of your current Focus (user, 2026-10-25)
			-- No guard break (user, 2026-10-25): a blocked Eject is a normal blocked hit, so it still
			-- strips a weak guard (block held past D.HOLD_STRIP_THRESHOLD).
			tags = { GuardBreak = false },
			dashRefresh = true,
			-- Landing it: the crit is ready again, and 80% of the M2's cooldown is cut (user, 2026-10-25).
			cooldownRefresh = { R = 1, M2 = 0.8 },
			-- Landing it opens Reentry for the next 2s only (user, 2026-10-25).
			unlocks = { move = "Reentry", window = 2 },
			knockback = { distance = 8, duration = 0.3, direction = "Away" },
			hitbox = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -2.75) },
		},
	},
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
