--!strict
-- Firecracker style (copy of Basic, own animations). Fields left out fall back to Data/Defaults via MoveSchema.
-- animHit = time of the "hitbox" marker in the animation at 1x speed (measured 2026-10-02).
-- The client scales playback so the marker lands exactly on `startup`.
local M1_BOX = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -2.25) } -- reach 5 (user, 2026-10-11: -0.5)

local function m1(anim: string, animHit: number, startup: number)
	return {
		kind = "M1",
		anim = anim,
		animHit = animHit,
		startup = startup,
		endlag = 0.2,
		damage = 6,
		hitbox = M1_BOX,
	}
end

return {
	name = "Firecracker",
	rarity = "Legendary", -- style reroll tier (Shared/Rarity), user 2026-10-11
	-- Combat-mode idle (played while in combat mode and standing still). Leave the
	-- Animation's AnimationId empty to keep the normal idle.
	idle = "Firecracker/Idle",
	m1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" },
	guardMax = 25, -- user, 2026-10-10
	perks = { "Firecracker" }, -- style perks (always on), see Data/Perks
	m2 = "M2",
	r = "Crit",
	moves = {
		M1_1 = m1("Firecracker/1", 0.267, 0.267),
		M1_2 = m1("Firecracker/2", 0.283, 0.27),
		M1_3 = m1("Firecracker/3", 0.25, 0.25),
		M1_4 = m1("Firecracker/4", 0.267, 0.267),
		-- Dash (user, 2026-10-11): 0.5s windup, then dash 5 studs in 0.1s for 6 damage. The hitbox is live
		-- for the whole dash and it stops on the first contact (rush). The hold-to-charge was removed
		-- (user); the generic `charge` field still exists if a move wants it. Clips: M2windup over the
		-- windup, M2Swing for the dash.
		M2 = {
			kind = "M2",
			limbFx = "Right Arm", -- M2 limb flash (user, 2026-10-16)
			antiHeal = 1, -- user, 2026-10-14
			anim = "Firecracker/M2windup", -- 0.3s clip, stretched over the windup
			startup = 0.5, -- windup (user, 2026-10-11: 0.5 -> 0.3 -> back to 0.5)
			fixedStartup = true, -- always exactly 0.5s: adrenaline doesn't speed it up (user)
			endlag = 0.4, -- after a connected dash
			cooldown = 0.3, -- after endlag
			damage = 6,
			-- Along the dash. Shorter reach (user, 2026-10-11; was 5x5x5.5 at -3.25, reach 6): reach 4,
			-- same width, so the dash carries you closer before it connects.
			hitbox = { size = Vector3.new(5, 5, 3.5), offset = CFrame.new(0, 0, -2.25) },
			knockback = { distance = 2, duration = 0.2 }, -- along the dash (user, 2026-10-11; 0.2s is my pick)
			rush = {
				duration = 0.1, -- the dash arrives in 0.1s (user, 2026-10-11; was speed 40)
				freeStuds = 5, -- dash distance (user, 2026-10-11; was 6, 4, 7.5); adrenaline doesn't buy any more
				carry = 0, -- no momentum after contact / at the end: stops dead (user, 2026-10-11; was 0.15)
				aim = "Facing", -- dashes where the body faces; no turning toward the camera (user, 2026-10-11)
				missEndlag = 0.4, -- endlag after a whiffed dash
				loopAnim = "Firecracker/M2Swing", -- the dash (skipped while its AnimationId is empty)
			},

		},
		-- Firecracker (user, 2026-10-11): R lights a 1.3s fuse (Fuse sound) and you stay free
		-- to act; when it goes off, 15 punches over 1.5s, 1 damage each (Crack + Start + looped WindLoop
		-- at the start, Pop per punch) while stepping 12 studs forward, steered by the camera.
		-- No guard break (opted out of the R default); endlag/hitstun are Basic's.
		Crit = {
			kind = "R",
			limbFx = { "Right Arm", "Left Arm" }, -- crit limb flash (user, 2026-10-16)
			anim = "Firecracker/CriticalAnimations/1", -- not played: the fuse has no windup clip
			-- Always 1.3s (user, 2026-10-11; was 2s at 0 adrenaline -> 1s at 500, before that random 1.2-2.4).
			-- min = max turns the adrenaline scaling off. Impact frame as it goes off (user).
			fuse = { min = 1.3, max = 1.3, sfx = "Fuse", impact = true },
			barrage = {
				hits = 15,
				duration = 1.5,
				anims = {
					"Firecracker/CriticalAnimations/1",
					"Firecracker/CriticalAnimations/2",
					"Firecracker/CriticalAnimations/3",
					"Firecracker/CriticalAnimations/4",
					"Firecracker/CriticalAnimations/5",
				},
				animSpeed = 4, -- each punch gets 1/15s; tune by eye
				startSfx = { "Crack", "Start" },
				loopSfx = "WindLoop",
				punchSfx = "Pop",
				advance = 12, -- studs over the barrage, steerable (user, 2026-10-11)
				fists = 30, -- arm-clone fists flying out (look: D.BARRAGE_FIST)
			},
			endlag = 0.5,
			damage = 1.7, -- per punch (user, 2026-10-11; was 1, then 1.3)
			hitstun = 0.5,
			tags = { GuardBreak = false }, -- blocked punches just chip guard (user, 2026-10-11)
			knockback = { distance = 0.75, duration = 0.1, onBlock = true }, -- per punch, along the attacker's facing (user, 2026-10-11)
			hitbox = { size = Vector3.new(7, 6, 6), offset = CFrame.new(0, 0, -3.5) }, -- reach 6.5 (Basic's crit reach until 2026-10-25), wider
		},
	},
	-- Follow-ups allowed to break the section 2 invariants, with the reason.
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
