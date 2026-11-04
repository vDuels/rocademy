--!strict
-- Furious Feng (user, 2026-11-02): unobtainable, owner-given only (`rollable = false`, RoleService.canGiveStyle),
-- rarity Evolved. Kit = a copy of Feng's (clips copied into Animations/FuriousFeng; sounds in Sfx/Styles/FuriousFeng, copied from Feng's)
-- until it gets its own. Fields left out fall back to Data/Defaults via MoveSchema.
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
		swingSfx = "Swing", -- sounds live in Assets/Sfx/Styles/FuriousFeng
		hitSfx = "M1",
		knockback = { distance = 3, duration = 0.15 }, -- along Feng's facing
	}
end

return {
	name = "FuriousFeng",
	display = "Furious Feng", -- what the menus show; `name` stays the id (saves, assets, Style attribute)
	rarity = "Evolved", -- Shared/Rarity; never rolled
	rollable = false, -- unob: not in rolls; only the owner can give it
	evolvedFrom = "Feng", -- may carry Feng's style perks (MoveSchema)
	-- Combat-mode idle (played while in combat mode and standing still). Leave the
	-- Animation's AnimationId empty to keep the normal idle.
	idle = "FuriousFeng/Idle",
	equip = "FuriousFeng/Equip", -- once on entering combat mode (user, 2026-11-02)
	m1Chain = { "M1_1"},
	comboEndDelay = 0.6, -- after M1 endlag, wait this long before M1 is usable again
	guardMax = 12, -- user, 2026-10-10
	-- Fury after ChamberedDash: it lights after ChamberedDash.onLanded, so the kick that lights it gets no Fury refund
	-- on top of the kick's own (user, 2026-11-03).
	perks = { "ChamberedDash", "ChamberedKick", "Fury" }, -- style perks (always on), see Data/Perks (TwoLeftFeet taken off 2026-10-29; the perk still exists)
	m2 = "M2",
	r = "Critical",
	dashM1 = "DashKick", -- M1 during a dash (MoveSchema)
	dashM2 = "KickCan", -- M2 during a dash (MoveSchema)
	moves = {
		-- KickCan (user, 2026-11-03): M2 during a dash. A Bloxy Cola appears welded in front of you, gets a purple
		-- highlight + Vfx.FuriousFengFire at 0.1, and is kicked off at 0.25: 50 studs/s, up to 40 studs (client
		-- KickCan draws it; CombatService shots hits with it). Light poke. Same swing fx as the KickUp. Landing it lights Fury.
		KickCan = {
			kind = "M2",
			vfx = "KickCan", -- StarterPlayerScripts/Midori/KickCan
			-- Animations/FuriousFeng/KickCan holds KickUp's clip id as a placeholder (user, 2026-11-03). When the real
			-- clip goes in, set animHit to when its kick lands (the client scales it to hit at startup).
			anim = "FuriousFeng/KickCan",
			animHit = 0.33, -- KickUp's
			startup = 0.25, -- the can leaves at the hit (user, 2026-11-03: was 0.17); the clip re-times to it (animHit / startup)
			fixedStartup = true, -- the can's timing is fixed (the client vfx assumes it)
			endlag = 0.3, -- my pick
			cooldown = 3.4, -- shares the M2 cooldown (my pick: the M2's own)
			damage = 3,
			hitstun = 0.5,
			hitbox = { size = Vector3.new(4, 5, 4), offset = CFrame.identity }, -- on the can: forgiving sideways, full body height (was 3x3x3)
			tags = { Unparryable = true }, -- a parry can't stun a thrower 40 studs away; it just blocks
			swingSfx = "KickCan", -- Sfx/Styles/FuriousFeng (user, 2026-11-03)
			hitSfx = "CanHit", -- a copy of Sfx/Generic/SodaHit (user, 2026-11-03)
			limbFx = "Left Leg",
			limbColor = Color3.fromRGB(70, 0, 110),
			trail = { limb = "Left Leg", from = 0, to = 0.6, color = Color3.fromRGB(130, 40, 220) },
			limbTime = 0.6, -- the leg ghost + squares last 0-0.6, with the trail (user, 2026-11-03)
			-- Keeps dashing for 0.3s like the dash kick (user, 2026-11-03); the can still leaves at 0.25, mid-slide.
			step = { at = 0, distance = 9, duration = 0.3, dash = true },
			projectile = {
				model = "BloxyCola", -- Assets/Models
				offset = CFrame.new(0, -0.75, -2.5), -- in front of the root (user, 2026-11-03: raised from -1.5)
				spin = 20, -- rad/s tumble in flight, visual only (my pick)
				fxAt = 0.1,
				color = Color3.fromRGB(130, 40, 220),
				speed = 50,
				range = 40,
			},
		},
		-- Dash kick (user, 2026-11-02): click during a dash. The dash carries on for 0.3s (LeepIn), then KickUp,
		-- its hit 0.33 in. A landed hit launches straight up; the victim gets up 0.2s after landing. 0.5 endlag.
		-- LeepIn / KickUp are empty placeholders in Animations/FuriousFeng until their ids are in.
		DashKick = {
			kind = "M1",
			anim = "FuriousFeng/KickUp",
			animHit = 0.33,
			lead = { anim = "FuriousFeng/LeepIn", time = 0.3 },
			startup = 0.63, -- 0.3 LeepIn + 0.33 to the KickUp's hit
			fixedStartup = true, -- the extension is a fixed 0.3s: adrenaline doesn't shorten it
			endlag = 0.5, -- hit or miss (user)
			damage = 8, -- like an M1 (user)
			antiHeal = 0.3,
			hitbox = M1_BOX,
			swingSfx = "Kickup", -- on the click (dive start)
			hitSfx = "M1",
			landSfx = "KickupHit", -- layered on the M1 hit sound when it lands
			-- Swing fx (user, 2026-11-02): the left leg ghosts dark purple when the KickUp starts (after the dive),
			-- and the foot trails wind 0 -> 0.6 into the KickUp swing (not the dive; the hit is 0.33 in).
			limbFx = "Left Leg",
			limbColor = Color3.fromRGB(70, 0, 110),
			trail = { limb = "Left Leg", from = 0, to = 0.6, color = Color3.fromRGB(130, 40, 220) },
			step = { at = 0, distance = 9, duration = 0.3, dash = true }, -- follows the dash; 9 = a 6-stud / 0.2s dash's speed x 0.3 (fallback)
			knockback = { distance = 0, duration = 0.1, up = 50 }, -- straight up: ~6 studs high, ~0.5s in the air (my pick)
			ragdoll = 2.5, -- cap; normally ends 0.2s after landing (ragdollLand)
			ragdollLand = 0.2,
			hitstun = 2.5, -- cap; ends with the ragdoll
		},
		-- Critical: CriticalStart windup, then a CriticalLoop rush paid for with adrenaline
		-- (now a flat 10 studs, adrenaline buys none: user, 2026-10-29). Steers slightly toward the camera. The first
		-- contact ends it; running dry plays CriticalMiss with a 0.4s easing carry, then endlag.
		Critical = {
			kind = "R",
			limbFx = "Right Leg", -- crit limb flash (user, 2026-10-16)
			anim = "FuriousFeng/CriticalStart", -- no animHit: the windup clip is stretched over startup
			startup = 0.4, -- user nerf 2026-10-06 (was 0.3)
			endlag = 0.1, -- after a hit / block (user, 2026-10-06); a whiff uses rush.missEndlag
			hitstun = 0.5,
			damage = 4, -- + rush.damagePerStud for every stud crossed
			hitbox = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -3.5) }, -- along the rush direction, reaches 6 studs out (user, 2026-10-29: was 8 long at -5 = 9 out)
			knockback = { distance = 3, duration = 0.2, direction = "Away" }, -- + rush.knockbackPerStud per stud
			swingSfx = "Critical", -- Sfx/Styles/FuriousFeng, on startup
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
				loopAnim = "FuriousFeng/CriticalLoop",
				missAnim = "FuriousFeng/CriticalMiss",
			},
		},
		M1_1 = m1("FuriousFeng/1", 0.4, 0.4), -- startup 0.4 -> 0.37 (user, 2026-10-30)
		M2 = {
			kind = "M2",
			limbFx = "Right Leg", -- M2 limb flash (user, 2026-10-16)
			antiHeal = 0.5, -- user, 2026-10-29 (was 0.7)
			anim = "FuriousFeng/M2",
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
