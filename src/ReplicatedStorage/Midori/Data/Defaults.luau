--!strict
-- Global combat constants for Project Midori. Every number here is a balance knob.
-- Values tagged [TBD] / [Assumed] / [Recommended] are placeholders from the design spec.
return table.freeze({
	DEFAULT_STYLE = "Basic", -- players (until they pick one with ",e <Style>") and dummies
	OWNER_USER_ID = 3515559402, -- 77noK: the Owner tab (set anyone's role, RoleService). Roles + default roles: Data/Roles
	-- The owners by UserId (not a role; user, 2026-10-27): the Panel's RIG NEXT CAN (SodaService) and GIVE
	-- rerolls / Bux (AdminService). Everyone in Studio too.
	OWNER_IDS = { 3515559402, 2314601548 },
	GENDERS = table.freeze({ "Male", "Female" }),
	FEMALE_TORSO = 48474356, -- "ROBLOX Girl - Torso"; Female characters wear its R6 CharacterMesh

	-- Attacks
	HITSTUN_PAD = 0.22, -- default hitstun = endlag + pad (user, 2026-10-10; was 0.15)
	BLOCKSTUN_PAD = 0.07, -- default blockstun = endlag + pad (user, 2026-10-10; was 0.1)
	CHAIN_RESET = 1.0, -- idle seconds before the M1 chain returns to hit 1
	M2_FLASH = { peak = 0.4, peakAt = 0.05, rest = 0.8, fade = 0.3 }, -- white Highlight on M2 start: 1 -> peak in peakAt, -> rest over fade, then removed
	CRIT_FLASH_COLOR = Color3.fromRGB(255, 30, 30), -- crit (R) start flash; same timing as M2_FLASH (user, 2026-10-10)
	M2_COOLDOWN = 2.8, -- minimum M2 cooldown after endlag (user, 2026-10-10; a higher own `cooldown` wins)
	R_COOLDOWN = 4.2, -- minimum crit (R) cooldown after endlag (user, 2026-10-10; a higher own `cooldown` wins)
	COMBO_END_DELAY = 0.5, -- M1 lockout after the last chain hit's endlag (styles can override: comboEndDelay)
	INPUT_BUFFER = 0.3, -- an action this early is held and run as soon as it is legal

	-- Block / parry
	BLOCK_START_DURATION = 0.35, -- uncancelable block-start; the Block clip is stretched to fit
	BLOCK_COOLDOWN = 0.4,
	BLOCK_COOLDOWN_AFTER_BLOCK = 0.15, -- instead, when the released block blocked a hit (not a strip; user, 2026-10-10)
	RELEASE_ACT_DELAY = 0.1,
	HOLD_STRIP_THRESHOLD = 0.8, -- weak guard: held this long, the next hit strips the block (user, 2026-10-10; back from 1.7)
	BLOCK_ARC_DEG = 180, -- [Assumed] front arc that counts as guarded
	PARRY_WINDOW = 0.15, -- parry: a fresh block press this recent parries any move (back, user 2026-10-10)
	PARRY_NET_TOL = 0.05, -- [Recommended] extra server-side tolerance for latency
	PARRY_STUN = 0.35, -- attacker's "Parried" stun (user, 2026-10-11; was 0.3), then half the parried move's endlag
	PARRY_RECOVERY = 0.15, -- parrier's recovery; parrier is 0.15s ahead

	-- Guard health
	GUARD_MAX = 20,
	GUARD_REGEN_PER_SEC = 2, -- 50% -> full in ~5s
	GUARD_REGEN_BLOCKING_MULT = 1.5, -- regen speed while holding block (user, 2026-10-10; was 1.25)
	GUARD_REGEN_DELAY = 2, -- guard regen pauses this long after ANY hit on your guard (user, 2026-10-10; was 0.6)
	GUARD_BREAK_STUN = 1, -- user, 2026-10-28 (was 0.85 from 2026-10-25; 0.65 from 2026-10-11; 0.7 earlier that day; was 1; briefly 0.6 on 2026-10-10)
	GUARD_BREAK_NO_BLOCK = 1.0,
	GUARD_BREAK_RESTORE = 0.5,
	GUARD_BREAK_REGEN_PAUSE = 3.0,

	-- Dash
	-- Shorter + snappier, Gakuran-style (user, 2026-10-11; was 0.4s / 9 studs): dash goes exactly where
	-- the input points, locked for the dash, flat (no vertical drift), no input = backdash.
	DASH_DURATION = 0.2, -- user, 2026-10-12 (was 0.25): 6 studs = 30 st/s constant, steerable (DashMotor.burst)
	DASH_ENDLAG = 0.1, -- user, 2026-10-13 (back to 0.1; was 0 since 2026-10-11)
	DASH_IFRAMES = 0.3, -- user, 2026-10-11; now outlasts the 0.2s dash by 0.1 (like Gakuran)
	RUN_AFTER_ENDLAG = 0.125, -- no running for this long after an attack's endlag ends (user, 2026-10-10)
	DASH_COOLDOWN = 1.9, -- user, 2026-10-11 (was 2.25)
	-- Player settings (user, 2026-10-29; P menu Settings page, saved by SettingsService in PlayerData.Settings,
	-- replicated as Player attributes "SetFov" / "SetToggleRun"). FOV range + slider step are my picks.
	SETTINGS = { fovMin = 50, fovMax = 110, fovDefault = 70, fovStep = 5, musicStep = 10 }, -- music volume: 0..100 % of D.MUSIC.volume (user, 2026-11-01; step mine)
	-- In combat (user, 2026-10-29; ServerScriptService.Midori.CombatTag): two fighters are fighting once they've
	-- exchanged `threshold` damage (health + guard, both ways, user's number); any hit / block / parry / dodge
	-- between them keeps it up; `timeout` seconds without one ends it (my number) and the count starts over.
	COMBAT = { threshold = 10, timeout = 15 },
	-- Dash direction vs the NEAREST fighter you're in combat with (D.COMBAT; user, 2026-10-29; every number
	-- here is my pick). CombatMath.dashIntent.
	-- Away from a close enemy = longer dash cooldown + a chunk of the flee meter (D.FLEE); toward a far one
	-- = shorter cooldown; sideways / around them (or nobody in range) = normal.
	DASH_INTENT = {
		awayRange = 25, -- "away" only counts with the nearest enemy this close (studs)
		awayDot = -0.7, -- dash dir . dir to them at or below this = away (~135 deg+ off them)
		awayCooldownMult = 1.4, -- 1.9s -> 2.66s
		towardMinRange = 20, -- "toward" only rewards closing a real gap: nearest enemy at least this far...
		towardMaxRange = 80, -- ...and no farther than this
		towardDot = 0.85, -- within ~30 deg of them
		towardCooldownMult = 0.65, -- 1.9s -> 1.24s
	},
	-- Anti-run flee meter (user, 2026-10-30; ServerScriptService.Midori.FleeSystem; every number is my pick).
	-- 0-1. Fills while you move away from the nearest fighter you're in combat with, by your speed straight
	-- away from them; walk + run slow from 1x (empty) to minMult (full); full = no running until unlockAt.
	FLEE = table.freeze({
		range = 30, -- nearest combat foe within this (studs); past it you've got away, the meter drains
		minSpeed = 8, -- st/s straight away from them; slower (stepping back for spacing) doesn't count
		fullStuds = 40, -- studs fled to fill it: ~2s running straight away, ~2.5s walking
		dash = 0.3, -- a dash away (DASH_INTENT "Away") adds this
		drainDelay = 0.5, -- after you stop fleeing
		drainPerSec = 0.35, -- full -> empty in ~3s
		minMult = 0.6, -- walk + run speed at a full meter (CombatMath.fleeMult)
		lockAt = 1, -- no running from here...
		unlockAt = 0.4, -- ...until it drains to here
		sendStep = 0.02, -- attribute resolution (replication)
		focusMax = 1.2, -- the speed check's best Focus run mult (RunController FOCUS_WALK.max)
		speedSlack = 6, -- st/s over the cap before the speed check logs
	}),
	ADRENALINE_MOVE_MULT = 0.85, -- any adrenaline: walk + run 15% slower (user, 2026-10-30; RunController)
	-- Kind = direction relative to the BODY (front/side/back); diagonals count as the nearer one.
	DASH_DISTANCE = table.freeze({ Front = 6, Side = 6, Back = 6 }), -- studs; Back 6 = Gakuran's (2026-10-13; was 4.8, 9/9/7.2 before)
	-- Slow zone (a `slowZone` move's hitbox, hit or not; Slugger Critical, user 2026-10-25): a `radius`-stud
	-- circle at the attacker for `duration` s. The attacker and every fighter inside it at the hitbox, while
	-- inside: walk/run x walkMult,
	-- dash cooldown regens at dashRegenMult speed, dashes go dashDistance studs, no back dash.
	-- Fighters carry it as SlowZoneAt / SlowZoneEnds attributes (CombatMath.inSlowZone).
	-- Screen colour shifts (client ColorShift; moves' landShift / useShift name one). No hue rotation in
	-- Roblox, so red -> blue = drain the colour + tint blue. tint/saturation/contrast are ColorCorrection
	-- values; hold = seconds at full (pulses), fade = ease out; dof = depth of field on the move's target.
	-- ponytail: values picked blind (user, 2026-10-25 asked for the looks, not numbers); tune in game.
	COLOR_SHIFT = table.freeze({
		-- Landing Eject (attacker + victim): a quick, light pseudo impact frame.
		-- saturation must be -1: at -0.8 reds still read red (checked in Studio).
		Eject = { tint = Color3.fromRGB(165, 195, 255), saturation = -1, contrast = 0.1, hold = 0.12, fade = 0.3 },
		-- Throwing Reentry (your screen, windup -> end of the swing): target in focus, the rest blurred,
		-- easing in over the windup. No tint (user, 2026-10-25: removed; was blue 105,150,255 / -1 / 0.35);
		-- colours punched up instead (saturation 0.6 = my pick; ColorCorrection goes to 1), fading in with it.
		Reentry = { tint = Color3.new(1, 1, 1), saturation = 0.6, contrast = 0, fadeIn = 0.4, fade = 0.35,
			dof = { far = 0.4, near = 0.3, radius = 3 } },
		-- The Reentry victim's screen (user, 2026-10-25): the same focus, locked on the attacker. Blur only.
		-- Both dofs: softer blur, tighter focus (user, 2026-10-25; was far 0.75 / near 0.6 / radius 6).
		ReentryTarget = { tint = Color3.new(1, 1, 1), saturation = 0, contrast = 0, fadeIn = 0.4, fade = 0.35,
			dof = { far = 0.4, near = 0.3, radius = 3 } },
	}),
	-- Lib/RockModule debris fades out as the camera nears it (client): opaque from `far` studs, gone by
	-- `near` (measured to the rock's surface, roughly). ponytail: picked blind, tune in game.
	ROCK_FADE = table.freeze({ near = 1, far = 5 }), -- was 2 / 10: faded most of the zone with the camera behind you
	SLOW_ZONE = table.freeze({ radius = 10, duration = 5, walkMult = 0.75, dashRegenMult = 0.75, dashDistance = 4 }), -- duration 5 = my number
	-- Escape detection only (user, 2026-10-13): while dashing on i-frames, a hitbox touching this upright
	-- cylinder around the root (bigger than the body) counts as an escape (ghost, ESCAPED, dodge adrenaline).
	-- It never makes the dasher hittable.
	DASH_ESCAPE_CYLINDER = { radius = 2.5, height = 5 },
	DASH_FLASH = { color = Color3.fromRGB(159, 160, 161), peak = 0.65, peakAt = 0.05, rest = 1, fade = 0.12 }, -- grey Highlight on every dash (Gakuran's EvasiveHighlight); same fields as M2_FLASH
	-- Knockback + move steps only (player/dummy dashes use DashMotor.burst).
	-- Fast first, ease down later (user, 2026-10-11): full speed for DASH_HOLD of the dash, then
	-- speed eases out to 0 over the rest by DASH_EASE_POWER (0 = constant, higher = earlier slowdown).
	-- Was a pure ease from t=0 with power 0.6 (fast, then a sudden stop). Also drives knockback + steps.
	DASH_HOLD = 0.35,
	DASH_EASE_POWER = 3, -- user, 2026-10-11: "harsher" (was 1.5)
	DASH_MAX_FORCE = 60000,
	POST_STUN_DASH_DELAY = 0.1, -- user, 2026-10-11 (was 0.2)
	DASH_CANCEL_RANGE_MULT = 0.7, -- [TBD]
	DASH_CANCEL_IFRAMES = 0.1, -- [TBD]
	DASH_BUFFER = 0.15, -- [Recommended]
	DASH_DISPLACEMENT_SLACK = 6, -- studs of tolerance before the server logs a suspicious dash
	-- Body blocking (Shared/DashMotor): dashes and knockback stop driving into other fighters
	-- just before contact, so the motor never shoves another player's body (they collide).
	BODY_BLOCK_DIST = 2.5, -- studs between root centres where movement into the other fighter stops
	BODY_BLOCK_HEIGHT = 4, -- ignore fighters further above/below than this

	-- Rush moves (Feng Critical; per-move numbers live in the move's `rush` table)
	RUSH_CARRY_EASE_POWER = 1, -- miss carry speed = speed * (1 - t/carry)^power

	-- Knockback (moves opt in with knockback = { distance, duration }; same ease as the dash)
	KNOCKBACK_MAX_FORCE = 60000,

	-- Counter crits / clashes
	COUNTER_MULT = 1.35,
	CLASH_TOLERANCE = 1 / 30, -- [Recommended] ~2 server ticks
	CLASH_STUN = 0.8, -- both fighters' hitstun when a clash counter-crits both (user, 2026-10-14; 0.4 -> 0.5 -> 0.6 -> 0.8)
	-- Clash pushes both fighters apart, replacing the moves' own knockback (user: 3 studs, 2026-10-11;
	-- duration 0.6, user 2026-10-14, was 0.2). Must stay <= CLASH_STUN.
	CLASH_KNOCKBACK = table.freeze({ distance = 3, duration = 0.6, direction = "Away" }),
	COUNTER_REQUIRES_TARGETING = false, -- [TBD] group fights: victim must be swinging at the attacker

	-- Adrenaline
	ADR_MAX = 500,
	ADR_MAX_DAMAGE_BONUS = 0.35,
	ADR_MAX_SPEED_BONUS = 0.15,
	ADR_DRAIN_DELAY = 1.0, -- drain starts after this long without being attacked (hit, blocked or parried)
	ADR_DRAIN_PER_SEC = 80,
	ADR_GAIN_HIT = 78,
	ADR_GAIN_COUNTERED = 169, -- taking a counter crit (clashes count for both), replaces ADR_GAIN_HIT
	ADR_GAIN_GUARDBREAK = 78,
	-- (ADR_GAIN_PARRY removed 2026-10-30: parrying now empties your own adrenaline, HitResolver.)
	-- Adrenaline resists anti-heal (user, 2026-10-30): up to `max` of it ignored, linear, maxed at `full`.
	ADR_ANTIHEAL_RESIST = table.freeze({ max = 0.3, full = 250 }),
	-- At max adrenaline the next clean hit guard-break-stuns you instead of hitstun (user, 2026-10-30; HitResolver).
	ADR_GAIN_DODGE = 130, -- a dash that whiffs a hit on i-frames (once per dash)
	ADR_COST_ON_HIT = math.huge, -- landing a hit (hit, counter crit, clash) spends ALL adrenaline;
	-- the bonus is snapshotted at attack start, so only that first landed hit is boosted
	ADR_COST_ON_BLOCKED = 70, -- attacker loses this per hit into a block (blocked, strip, guard break)

	-- Focus (user, 2026-10-23): Prodigy's second meter (the Astronaut perk turns it on; ServerScriptService
	-- .Midori.FocusSystem). No damage bonus; at full it adds these, scaling linearly with Focus, snapshotted
	-- when an attack starts like adrenaline. Starting numbers, tune after testing.
	FOCUS = table.freeze({
		max = 100,
		-- Dodges give no Focus (user, 2026-10-25; was 25), and still no adrenaline.
		hitGain = 5, -- every landed hit (hit, counter, clash)
		m2Gain = 15, -- a landed M2 with Uppercut to the Moon (user, 2026-10-25; was the dodge gain, 25)
		counterGainMult = 5, -- landing a counter (or clash) gains this x hitGain (user, 2026-10-25: "increase"; 3 -> 5 is my number)
		m1Damage = table.freeze({ at = 0.6, damage = 3 }), -- at 60%+ Focus (attack start) M1s deal 3 (user, 2026-10-25)
		-- Focus lost when an attack hits you, by its kind, once per attack (a barrage costs it once)
		-- (user, 2026-10-24; was 2 per point of health damage).
		hitLoss = table.freeze({ M1 = 15, M2 = 10, R = 10 }), -- user, 2026-10-25 (M2 / R were 35)
		dashCdFocus = 80, -- at this much Focus or more, the dash cooldown is cut by dashCdCut (user, 2026-10-24)
		dashCdCut = 0.3,
		parriedLoss = 0.4, -- being parried costs this share of your CURRENT Focus (user, 2026-10-25)
		counterLossMult = 1.5, -- ...times this when it's a counter on you (user: "more"; 1.5 is my number)
		antiHeal = 0.1, -- added to every attack's anti-heal at full Focus (user, 2026-10-25: "reduce"; 0.2 -> 0.1 is my number)
		counterDamage = 0.25, -- added to COUNTER_MULT on your counters
		endlag = 0.3, -- share of every attack's endlag cut
	}),

	-- Networking
	MAX_COMP = 0.15, -- max seconds a client timestamp may backdate an input
	-- Lag compensation (ServerScriptService.Midori.LagComp): a player's hitbox is checked
	-- against victims as they were ping + LAGCOMP_INTERP ago, at most LAGCOMP_MAX ago.
	LAGCOMP_INTERP = 0.1, -- [Assumed] Roblox's character interpolation delay (it varies; ~0.1 is the usual estimate);
	-- only used for victims on plain Roblox replication. Chrono victims use the attacker's measured delay.
	-- Chrono (Lib/Chrono, custom character replication). OFF (user, 2026-10-14: "laggy and teleporty"):
	-- in NATIVE mode Roblox's own replication and Chrono's delayed CFrame both move remote characters,
	-- so they get pulled between two spots. Off = plain Roblox replication; LagComp uses its own history.
	CHRONO_ENABLED = false,
	-- When on: a client's Chrono packet further than this from its character's real (server) root is dropped
	-- (ChronoService), so lag comp never rewinds to a spot the client made up. Dashes / rushes lead by ~6-12.
	CHRONO_MAX_DRIFT = 15,
	-- When on, every living player runs on it.
	-- Seconds per position update: 60/s (user, 2026-10-14; was 1/30). Not exactly 1/60: Chrono's
	-- senders reset their timer to "now" on each send, so frames a hair under 1/60 would be skipped.
	CHRONO_TICK_RATE = 1 / 66,
	CHRONO_FULL_RATE_DISTANCE = 80, -- viewers further than this get half rate (never zero: removal hides the character)
	-- No style swaps / rerolls / trait spins this long after last being attacked (a swap refills
	-- guard, so leaving combat mode mid-fight must not be a free heal). 5 is my pick.
	LOADOUT_COMBAT_LOCK = 5,
	CHRONO_DELAY_MAX = 0.4, -- cap on a client's reported render delay
	LAGCOMP_MAX = 0.25, -- cap, so high ping can't hit people who are long gone
	-- Defence grace: a hit on an idle player is held this long (their one-way ping, capped) so a
	-- block/parry/dash they pressed before the hit, still in flight, counts. Hits feel this much later.
	DEFENSE_GRACE_MAX = 0.1,
	-- Drag hitboxes (user, 2026-10-11): every non-rush hitbox is live from DRAG_LEAD before its
	-- hitbox time to DRAG_TAIL after it, following the attacker; each victim is hit once per swing.
	-- DRAG_HITBOX = false (user, 2026-10-11): off, so each hitbox fires once at its hitbox time.
	DRAG_HITBOX = false,
	-- Attacker pose (2026-10-11, user: hitboxes spawning behind / late). While attacking, a player's
	-- client streams its root CFrame (POSE_SEND_INTERVAL); the server places that player's hitboxes
	-- there instead of at its own copy of the root, which lags (one-way ping + replication smoothing,
	-- many studs mid-dash). Used only if it arrived within POSE_MAX_AGE and is within POSE_MAX_OFFSET
	-- studs of the server's root; otherwise the server's root is used as before.
	POSE_SEND_INTERVAL = 1 / 30,
	POSE_MAX_AGE = 0.2,
	POSE_MAX_OFFSET = 12,
	-- POSE_MAX_OFFSET is for moving fast on purpose (dash, rush, barrage advance, step / blink windups, just out
	-- of a dash). Otherwise a pose may lead the server's copy only as far as running could take you in your lag:
	-- RUN_SPEED * POSE_SPEED_MARGIN * min(ping + LAGCOMP_INTERP, LAGCOMP_MAX) + POSE_WALK_SLACK (~7-9 studs);
	-- a pose past that is pulled back to it (audit, 2026-11-05: 12 studs everywhere was free reach for exploiters).
	POSE_SPEED_MARGIN = 1.4, -- covers short heights' move speed bonus (D.HEIGHT) and jitter
	POSE_WALK_SLACK = 2,
	DRAG_LEAD = 0.05,
	DRAG_TAIL = 0.1,
	RATE = table.freeze({
		Attack = table.freeze({ burst = 4, perSec = 8 }),
		Block = table.freeze({ burst = 6, perSec = 12 }),
		Dash = table.freeze({ burst = 3, perSec = 3 }),
		CombatMode = table.freeze({ burst = 4, perSec = 4 }),
		AttackPose = table.freeze({ burst = 10, perSec = 45 }),
		Code = table.freeze({ burst = 3, perSec = 0.2 }), -- code guesses: 3 quick tries, then one per 5s
		Reroll = table.freeze({ burst = 8, perSec = 4 }), -- several rolls can run at once (was 2/2)
		ChronoDelay = table.freeze({ burst = 2, perSec = 4 }),
		Skate = table.freeze({ burst = 4, perSec = 2 }),
		Carry = table.freeze({ burst = 3, perSec = 2 }),
		Server = table.freeze({ burst = 2, perSec = 0.2 }), -- private server create / join / leave (DataStore + teleports)
		Furnish = table.freeze({ burst = 6, perSec = 4 }), -- apartment place / move / pick up
		Apartment = table.freeze({ burst = 4, perSec = 2 }), -- apartment leave / build mode / style swap
	}),

	-- Flat chances for every roll (appearance, styles, traits; Shared/Rarity), whenever the pool has
	-- that tier: Mythic 0.05%, Legendary 1% (user, 2026-10-10). The rest goes by PERK_RARITY_WEIGHTS.
	ROLL_FIXED_CHANCE = table.freeze({ Mythic = 0.0005, Legendary = 0.01 }),
	-- Auto roll (P menu AUTO selector): most rerolls one press can spend chasing a rarity.
	-- ponytail: a fixed cap; Mythic averages 2000 rolls, so 10000 lands it ~99% of the time.
	AUTO_ROLL_MAX = 10000,

	-- Traits ("perks" in code): PERK_SLOTS on your style; a trait roll gives each unlocked one a random
	-- rollable trait your style can use with PERK_ROLL_CHANCE, else nothing.
	-- Locker (user, 2026-10-22; replaced style slots): LOCKER_SLOTS free slots, each keeps ONE item you
	-- own (a hat, hair, face, accessory, or a style with its traits); more slots are bought.
	LOCKER_SLOTS = 3,
	-- Buying more (user, 2026-11-01), two separate ways that never use each other up:
	--   Bux: one slot per price, in order (6 slots); then Bux can't buy more (PlayerData.BuxSlots).
	--   Robux: each purchase of a LOCKER_PRODUCTS product adds its slots (50 Robux, 1 slot, no limit; ExtraSlots).
	LOCKER_BUX_PRICES = table.freeze({ 50, 100, 250, 250, 500, 1000 }),
	LOCKER_PRODUCTS = table.freeze({ [3726390140] = 1 }), -- [developer product id] = slots it adds, e.g. [123456789] = 1 (the 50 Robux one); empty = the Robux button is hidden
	-- Trait locks: a reroll costs TRAIT_LOCK_MULT ^ (locked traits); all PERK_SLOTS locked = no reroll.
	TRAIT_LOCK_MULT = 10,
	PERK_SLOTS = 3,
	PERK_ROLL_CHANCE = 0.5,
	-- Relative weights of the non-fixed tiers (Legendary/Mythic are ROLL_FIXED_CHANCE), for every roll.
	PERK_RARITY_WEIGHTS = table.freeze({ Common = 60, Rare = 25, Epic = 12 }),
	RECENT_STUN_WINDOW = 0.1, -- "stunned in the last X seconds" for perk mods (Opportunist)
	STARTING_SPINS = 50, -- rerolls a brand-new player starts with (user, 2026-10-17)
	STARTING_BUX = 0, -- Bux (clothing store currency, store not built yet) a brand-new player starts with
	FREE_SPINS = false, -- rerolls cost a spin (user turned free spins off 2026-10-17)
	SPIN_PRODUCTS = table.freeze({ -- developer product id -> spins it grants (first one is the shop button)
		-- [1234567890] = 1,
	}),

	-- Running (hold Left Shift while moving; walk speed is StarterPlayer.CharacterWalkSpeed)
	RUN_SPEED = 20,
	RUN_BACKWARD_DOT = -0.5, -- moving this far against your facing ends the run
	ACTION_WALK_MULT = 0.7, -- walk speed while attacking (startup/endlag) or blocking (user, 2026-10-10)
	SWING_SLOW_LINGER = 0.05, -- the attack slow stays this long after startup/endlag ends; just bridges chained M1s (user, 2026-10-11: 0.5 lasted way too long)
	HITSTUN_WALK_MULT = 0.6, -- walk speed in hitstun (user, 2026-10-10); parried / guard-break stuns root instead
	PARRIED_WALK_MULT = 0.5, -- walk speed in the endlag after getting parried (the stun itself roots)

	-- Head look + camera on head (StarterPlayerScripts.HeadRotation, ServerScriptService.Communication)
	HEAD_YAW_STRENGTH = 0.45, -- fraction of the camera's yaw (relative to the body) the head follows
	HEAD_PITCH_STRENGTH = 0.8,
	HEAD_MAX_YAW = math.rad(45),
	HEAD_MAX_PITCH = math.rad(20),
	HEAD_SMOOTHING = 0.1, -- fraction of the remaining turn covered per 60fps frame
	HEAD_SEND_INTERVAL = 0.1, -- seconds between head-angle updates sent to other players
	HEAD_CAMERA_FOLLOW = 1, -- 1 = camera follows the animated head fully, 0 = off
	-- (2026-10-22, user: "improve camera look") Looking further behind you than this, the head eases back
	-- to straight instead of whipping from one shoulder to the other as the camera crosses your back.
	HEAD_BEHIND_FADE = math.rad(110),
	-- Camera-on-head: the head's ANIMATED movement only (not the look turn), smoothed so keyframe snaps
	-- and hit reactions don't shake the view, with walk-bob-sized wobble ignored and a hard cap.
	HEAD_CAMERA_SMOOTHING = 0.25, -- fraction of the remaining offset covered per 60fps frame
	HEAD_CAMERA_DEADZONE = 0.12, -- studs of head movement ignored (idle / walk bob)
	HEAD_CAMERA_MAX = 2.5, -- studs the camera can be pulled from rest

	-- Shield billboard (StarterPlayerScripts.Midori.ShieldController, Assets/2d)
	SHIELD_SIZE = 3.5, -- studs; world-sized, so it scales with distance like the character
	-- Screen HUD, top-left (StarterPlayerScripts.Midori.HudController): Hi-Fi Rush bars + trait cards.
	-- Art is white/black and tinted in code. Never point these at rbxasset:// (that only exists in one Studio install)
	-- (uploaded 2026-10-17; for a NEW art version upload the PNG again and paste its new id here).
	HUD_ATLAS = "rbxassetid://94755132035867", -- 1024x1024: 12 trait icons (256 cells, row-major), card at cell 12
	HUD_CRIT_CD_COLOR = Color3.fromRGB(255, 40, 40), -- crit cooldown sticker (user, 2026-10-17)
	HUD_M2_CD_COLOR = Color3.fromRGB(255, 255, 255), -- M2 cooldown sticker (user, 2026-10-17)
	-- Bloxy Cola (user, 2026-10-17; ServerScriptService.Midori.SodaService). Any part tagged `tag` in the
	-- world is a can you can pick up (e.g. a copy of Assets.Models.BloxyCola). The first click opens it;
	-- each drink after adds `heal` to your healable HP (regen heals it back), `sips` drinks per can (user, 2026-10-17).
	-- `sipTimeout`: the heal lands this long after starting to drink if the Drink animation never sends
	-- its "Sip" marker; a Sip sooner than `minSip` is ignored.
	-- emptyDespawn: an empty can (0 sips) left in the world is removed after this many seconds.
	-- vendorTag: a vending machine (model or part) that sells a fresh can for `price` Bux (hover + E), usable
	-- within `vendReach` studs of its bounding box (any side; Shared/Reach), once per `buyCooldown` s. The can
	-- drops out of the side facing you at `dispenseSpeed`; `fatalChance` (1 in 1000) it fires at you at
	-- `fatalSpeed` and kills you: `blast` = ragdolled + launched (`distance` studs over `duration` s, `up`
	-- studs/s upward, `spin`) with Vfx.WindTrail on the Torso at `trailScale` x, taking `damage` (lethal = knocked).
	SODA = { tag = "MidoriSoda", heal = 20, sips = 8, reach = 8, minSip = 0.15, sipTimeout = 3, dropSpeed = 6, emptyDespawn = 30, fullDespawn = 240, floodCount = 100, floodCooldown = 5, vendorTag = "MidoriSodaVendor", price = 1, vendReach = 5, buyCooldown = 0.5, dispenseSpeed = 5, fatalChance = 0.001, fatalSpeed = 160,
		blast = { distance = 45, duration = 0.7, up = 45, spin = 14, ragdoll = 6, trailScale = 1.5, damage = 999 } },
	-- Vfx.WindTrail size on strong ragdolls (move.strongRagdoll) and blinks (move.blink); ServerScriptService.Midori.WindTrail.
	WIND_TRAIL_SCALE = 1.5,
	-- Stuck-animation diagnostic on server + client (Shared/AnimDebug, 2026-10-28). Off in live games (audit,
	-- 2026-11-05: it scanned every fighter's tracks 4x a second); set true again to hunt stuck animations.
	ANIM_DEBUG = false,
	-- Blink moves (Dema M2): land this many studs short of a wall in the lane (CombatMath.blinkTarget).
	BLINK_WALL_GAP = 2,
	-- The blink's teleport is drawn as a wind-trail streak flying start -> landing over this long (WindTrail.streak).
	BLINK_STREAK_TIME = 0.1,
	-- ...and the streak stays up this long after the teleport before fading (user, 2026-10-28).
	BLINK_TRAIL_STAY = 0.3,
	-- Blink release VFX (client BlinkLane; user, 2026-10-28): each Vfx.GlassSlash grows to `slashGrow` x while
	-- fading out over `slashTime` (slashGrow / slashTime: my picks). (A windup Vfx.Glass pulse was removed by the user.)
	-- Release: a wave of GlassSlashes every `waveEvery` s (user: 0.1) for `storm` s, `perStud` per stud of the lane's
	-- range per wave (user: scales with distance; 40 studs = 3, 60 = 5), scattered over the lane
	-- at a random angle / height (up to `slashHeight`) / size (`slashSize` range, x the asset's 24 studs)
	-- (user: spread out like a domain of cuts; perStud / storm / sizes are mine).
	BLINK_GLASS = { slashGrow = 1.6, slashTime = 0.35, waveEvery = 0.1, perStud = 0.08, storm = 0.5, slashHeight = 6, slashSize = { 0.35, 0.8 } },
	-- Blink lane look (client BlinkLane): fill + neon edge colour, edge thickness, fill transparency,
	-- fade-out after the hit.
	-- centerFade / nearFade (user, 2026-10-29; my numbers): extra see-through down the middle of the fill and
	-- at the user's end (0 = as the fill, 1 = gone); the fill glows off the side + far lines.
	-- Softer, lighter golden yellow (user, 2026-10-29; was fill 255,240,150 / lines 255,235,90; shades are my pick).
	BLINK_LANE = { color = Color3.fromRGB(255, 236, 190), edge = Color3.fromRGB(255, 222, 145), edgeWidth = 0.35, fill = 0.75, fade = 0.35, centerFade = 0.3, nearFade = 0.9 }, -- centerFade 0.85 -> 0.3 (user, 2026-10-29: middle only slightly see-through)
	-- Location travel (user, 2026-10-27; ServerScriptService.Midori.TravelService + client LocationController).
	-- A part tagged `tag` with a string attribute "To" = the Name of another tagged part is a pad/door: hover + E
	-- sends you in front of "To". Every part in workspace[`folder`] (a Persistent Model) is an area named by its
	-- Name; entering one shows the name at the top of the screen for `popupHold` s.
	-- fadeOut / fadeIn: the screen fade around the teleport (s); you move while it's black.
	TRAVEL = { tag = "MidoriTeleport", folder = "Locations", reach = 10, cooldown = 1, popupHold = 2.5, fadeOut = 0.3, fadeIn = 0.4 },
	-- Apartments (user, 2026-10-31; ServerScriptService.Midori.ApartmentService, client ApartmentController /
	-- BuildController). Parts tagged `tag` are plot anchors (one apartment each, far off the map). Styles = the
	-- Models in Assets.Apartment, built only on the clients inside; `defaultStyle` = everyone's first one.
	-- A travel pad with Apartment = true takes you to your own. `starter` = furniture every profile starts with.
	-- Wall paint (user, 2026-11-01; free, build mode, per room): `wallMaterials` = Enum.Material names,
	-- `wallColors` = hex. Models under a style's Walls with a Paint attribute ("<room>" = its walls, "<room>/Ceiling")
	-- are what gets painted, each on its own. Lists are my picks.
	APARTMENT = {
		tag = "ApartmentPlot", defaultStyle = "Starter", starter = { Table = 1, Chair = 2, Bed = 1 },
		listMax = 50, -- whitelist size (door access; my pick)
		wallMaterials = { "SmoothPlastic", "Plaster", "Brick", "WoodPlanks", "Wood", "Concrete", "Marble", "Fabric", "Cobblestone", "Granite" },
		wallColors = { "E1DCCD", "FFFFFF", "2B2A30", "C8A27A", "8C5A3C", "A9C6E8", "9CC59A", "F2B8C6", "F4D35E", "C0392B", "4A6FA5", "6B4E8C" },
	},
	-- DJ Booth (user, 2026-11-01; client DJController, pure Shared/RoomSound). A placed furniture with `dj = true`
	-- plays the owner's pick from EVERY song in Assets.Music (hover + E on the booth; or shuffle all) through the
	-- whole apartment, in sync for everyone inside (server clock), and the area OST steps aside. Rooms are a graph: two floors whose edges are within `wallGap` studs
	-- and overlap along the wall are neighbours. Hops = rooms between you (your room = a Zone+ zone) and the
	-- booth; each hop multiplies volume by `volumePerHop` and cuts `highCut` / `midCut` dB more off the top
	-- (muffled through walls); past `maxHops` it's silent. A `speaker = true` item (Sound Extender) in a room makes
	-- that room `extenderHops` from the booth (0 = as clear as the booth's room) and the sound carries on from it.
	-- `fade` = s to ease into a new mix when you change room. Numbers are my picks (untuned).
	DJ = { wallGap = 3, volumePerHop = 0.6, highCut = 14, midCut = 5, maxHops = 4, extenderHops = 0, fade = 0.5 },
	-- OST pools (user, 2026-10-27; client MusicController): Assets.Music/<area name or Default>/<Sound>.
	-- volume = the music SoundGroup; fade = crossfade s; cardHold = how long NOW PLAYING stays up.
	MUSIC = { volume = 0.5, fade = 1.5, cardHold = 4 },
	-- Too much Bloxy Cola (user, 2026-10-27; ServerScriptService.Midori.BloxyService + client BloxyController).
	-- Sobering up (user, 2026-11-01: "the effects never wear off"; was a window that every sip pushed back,
	-- ~28 min at drunk): `soberDelay` s after your last sip you start losing `soberRate` sips per second, so
	-- the effects fade as the count drops. The thresholds below are WHOLE DRINKS (a full can =
	-- SODA.sips sips; half a can = half a drink). Tier (character attribute "Drunk"):
	--   blurAt+  (1): screen blur (BlurEffect Size) that grows with every sip, up to `blurMax` just before drunkAt
	--   drunkAt+ (2): heavy blur (`blurFull`), can't run, attacks at `attackSpeed` x, any hit knocks you out for `hitKnock` s
	--   blackoutAt (3): knocked out for `blackout` s with a black screen ("BlackedOut"), and the count resets
	-- Sound (SIPS, not drinks; user): from `muffleAt` sips everything gets muffled, worse each sip, fully garbled
	-- at `garbleAt` (EQ cut + distortion + wobbling pitch; client BloxyController).
	-- Trip (SIPS): from `tripAt` sips each dash has `tripChance` to ragdoll you for `tripRagdoll` s (CombatService.requestDash).
	BLOXY = { soberDelay = 30, soberRate = 0.4, blurAt = 5, drunkAt = 9, blackoutAt = 14, blurMax = 6, blurFull = 12, attackSpeed = 0.75, hitKnock = 30, blackout = 120, muffleAt = 50, garbleAt = 100, tripAt = 75, tripChance = 0.25, tripRagdoll = 1.5 },
	-- Height (user, 2026-11-02; owner-set only, Panel / HeightService; Shared/Height): a body scale from `min` to `max`, 1 = normal.
	-- Torso, limbs and root scale, the head and model don't. Effects grow linearly to their full size at min / max:
	-- Attack range = the style's hitbox x height, always (user: "proportional to height and style").
	-- tall (at max): +damage, +hp (max HP), +dashDistance, swingSlow (startup + anim this much slower),
	--   +antiHeal (x on the move's anti-heal), stunResist (hitstun TAKEN this much shorter).
	-- short (at min): -hp, dash + M2 cooldowns cut, swingFast, moveSpeed (walk + run), -antiHeal (x),
	--   stunWeak (hitstun taken this much longer). No damage change (user, 2026-11-02: less anti-heal instead).
	-- Numbers are my defaults (user gave directions only, "greatly" = half).
	HEIGHT = {
		min = 0.6, -- user, 2026-11-02 (was 0.75)
		max = 2, -- user, 2026-11-02 (was 1.3)
		-- Harsher (user, 2026-11-02: "more major and harsher"; was tall dmg .1 hp .3 dash .25 swing .3 ah .5 stun .25 /
		-- short hp .25 cds .5 swing .05 move .15 ah .5 stun .25).
		tall = { damage = 0.25, hp = 0.6, dashDistance = 0.5, swingSlow = 0.5, antiHeal = 1, stunResist = 0.5 },
		short = { hp = 0.5, dashCooldownCut = 0.7, m2CooldownCut = 0.7, swingFast = 0.15, moveSpeed = 0.35, antiHeal = 0.8, stunWeak = 0.6 },
	},
	-- Ragdolls (user, 2026-11-02: "improve ragdolls as a whole", "behave differently for each situation"):
	-- one physics model everywhere (Shared/Ragdoll). Every ragdoll start is ONE launch: the same velocity on
	-- the root and every limb (a knockback becomes a ballistic arc that lands about where it would have:
	-- airtime = max(kb duration, minAir), up = max(kb up, what that airtime needs)), then plain physics with
	-- friction. No motor ever drags a limp body and nothing freezes it at a distance. No knockback = the
	-- body keeps the momentum it had (a trip mid-dash flies on).
	-- Tipping: the body turns away from the push, tip rad/s per stud/s of flat launch speed, capped at
	-- tipMax; a move's knockback.spin adds a seeded random wobble x wobble (same on every screen).
	-- jointFriction: MaxFrictionTorque on the ragdoll sockets (limbs settle instead of flopping forever).
	-- density: the ragdoll colliders' density (a heavy core leads, light limbs follow).
	-- All my numbers (tune here).
	RAGDOLL = {
		minAir = 0.3,
		tip = 0.25,
		tipMax = 8,
		wobble = 0.5,
		jointFriction = { Head = 15, Arm = 10, Leg = 20 },
		density = { Torso = 2.5, Head = 0.8, Limb = 0.5 },
		-- Anti-heal (user, 2026-11-03; HealthSystem.damage): hits on a ragdolled body take NO anti-heal, and for
		-- `getUpWindow` s after getting up you resist `getUpResist` of it (on top of adrenaline's resist).
		getUpWindow = 2,
		getUpResist = 0.5,
	},
	-- Seats (user, 2026-10-27; SeatService): hover + E sits you, walking into a seat no longer does. Jump to stand.
	SEAT = { reach = 8 },
	-- Skateboard (SkateController, user 2026-10-18): B toggles, out of combat mode. Speed is studs/s.
	-- Knocked (KnockService, user 2026-10-18): a hit that would kill knocks you down instead: HP sits at
	-- `hp`, you're ragdolled, can't act and can't be hit, and get up after `duration` with
	-- recoverHp x max HP, unless someone grips them first (GRIP). The timer is PAUSED while someone carries you (user).
	-- `bob` = the down body's breathing / twitching: VISUAL only (offsets drawn onto each client's own
	-- ragdoll, Shared/Ragdoll; no physics, so it can't make the body bounce): the chest rises `breathe`
	-- studs once per `breathePeriod` s; a random limb swings up to `twitch` radians over `twitchTime` s,
	-- every `twitchEvery` s. Untuned.
	KNOCKED = {
		duration = 10, -- my pick
		hp = 0.01, -- above 0 so the Humanoid never dies; the HUD shows 0
		recoverHp = 0.25, -- my pick
		bob = { breathe = 0.12, breathePeriod = 2.6, twitch = math.rad(14), twitchTime = 0.35, twitchEvery = NumberRange.new(0.8, 2.2) },
	},
	-- Carrying a knocked player (KnockService + CarryController, user 2026-10-18): hover them and press
	-- E (InteractController) to put them on your shoulder, E again drops them. No attacking, blocking
	-- or dashing while carrying; getting stunned or knocked drops them. Anims: Assets.Animations.Knocked.
	CARRY = {
		range = 8, -- studs from you (hover pick + server check)
		offset = CFrame.new(1.1, 1.4, 0), -- their root, relative to yours: over your right shoulder
		-- (user) an invisible box around the carried body, so you can't carry it through walls; it
		-- never hits characters. Size + where it sits, relative to your root.
		colliderSize = Vector3.new(2.2, 3, 2.2),
		colliderOffset = CFrame.new(1.1, 1, 0),
		-- (user) the carried torso's rotation is limited to this, in your root's space: chest facing
		-- the floor, head back over your shoulder. Soft (torque / responsiveness), so it still sways.
		torsoRot = CFrame.fromMatrix(Vector3.zero, Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 1, 0)),
		torsoTorque = 20000, -- my pick
		torsoResponsiveness = 30, -- my pick
	},
	-- Grip (KnockService, user 2026-10-18): hover a knocked fighter and press V to finish them. You're
	-- rooted in State.Gripping; at `at` s they die (Assets.Animations.Knocked.Grip, Sfx.Generic.Grip).
	-- While gripping you hold them up by the HEAD at `offset` from your root (2 studs in front, 1 stud up,
	-- facing you; user): their body dangles under it (Shared/Ragdoll). At `at` they die, are let go and
	-- launched away (`knockback` studs/s; my picks). Getting hit before then cancels it. Can't grip
	-- someone being carried.
	GRIP = {
		at = 0.8,
		range = 8,
		offset = CFrame.new(0, 1, -2) * CFrame.Angles(0, math.pi, 0), -- 2 in front (user), 1 up
		knockback = { speed = 45, up = 20 },
	},
	-- Skateboard (SkateController + SkateService, user 2026-10-18): B toggles, out of combat mode.
	-- A 1:1 port of the reference game's skate MOVEMENT (no hitboxes / damage / ult). Speed is studs/s;
	-- "per frame" = per 60fps frame (scaled by dt). Marked (user) = the user's tuning from playing it.
	SKATE = {
		enabled = false, -- (user, 2026-10-18) skating is locked for now: B does nothing, the server refuses the board
		-- speed lost per frame by tier (first `at` you're at or over), halved in the air.
		-- (user: gentle from 20, harsh at 40; the reference: 0.1 / 0.25 / 0.3 / 0.35)
		decay = { { at = 40, rate = 0.45 }, { at = 35, rate = 0.2 }, { at = 30, rate = 0.16 }, { at = 25, rate = 0.12 }, { at = 20, rate = 0.08 }, { at = 0, rate = 0.05 } },
		damageDrain = 1 / 4, -- speed lost per HP of damage taken
		maxSpeed = 100,
		startSpeed = 25 / 1.5, -- on hop-on (a dash's speed instead, if you dashed within dashCarry)
		dashCarry = 0.75,
		-- board toggle: can't step off for onLock after hopping on; after stepping off, hop-on waits
		-- offCooldown (offForcedCooldown if you were knocked off: combat mode, hit, out of speed)
		onLock = 2, offCooldown = 4, offForcedCooldown = 7,
		idleBail = 8, -- at 0 speed you're knocked off, once it's been this long since hop-on / last Q
		-- ground ray: from 1 stud above the root, groundRay long, along the body's lean
		groundRay = 5.5,
		wallDrain = 0.25, wallReach = 3, -- per frame while something solid is this close ahead
		slopeGain = 1 / 7, slopeCap = 15, -- per frame per unit of downhill, only under slopeCap
		rampMin = 0.15, rampTime = 0.2, -- steeper than this, for longer than this, then leave it...
		rampLaunch = 1.75, -- ...= up speed steepness x speed x this, fading 10% a frame (cut at 5)
		lean = 0.2, leanBack = 0.01, -- body lean to the ground per frame (on the ground / in the air)
		pushBonus = 5, pushDelay = 0.5, pushBusy = 0.25, pushCooldown = 1, -- M1, ground only
		trickBonus = 10, ollieTrickBonus = 5, -- landing a trick (+5 if you ollied during it)
		trickLedge = 0.3, -- trick = jump within this long of rolling off a ledge (not after a jump)
		trickWindow = 0.25, comboWindow = 0.5, -- re-trick presses in the same air (cosmetic)
		jumpMult = 0.5, -- (user) a plain board jump reaches this x your normal JumpHeight
		jumpCooldown = 1, -- (user) a plain board jump locks jumping this long (tricks never do)
		ollieHeight = 7.2, -- (user) M2 hop, studs; the reference: 15 up for 0.2s
		ollieBusy = 0.2, ollieCooldown = 3.5,
		lungeMaxHold = 1.5, -- Q held: frozen in place (mid-air too), aiming; let go (or this) to lunge
		lungeBonus = 8, -- lunge speed = what you had + this
		lungeHold = 0.3, -- after the lunge you hold your height this long...
		lungeLift = 15, -- ...rising this x how far up the camera looks (if up)
		lungeCooldown = 6,
		maxForce = 40000,
		hipLift = 0.35, -- HipHeight added while riding (the board is under your feet)
		fovPerSpeed = 10 / 25, -- FOV degrees per speed (smoothed, no cap)
		fovSmooth = 0.25, -- per frame
		fovHop = 5, fovLunge = 10, -- degree pops on hop-on / lunge, gone over 0.5s
		hot = 25, -- the speed meter turns red and shakes from here
		meterFull = 25, -- the meter ring is full at this speed
		linesFrom = 10, -- speed lines (rate = speed) above this speed
	},
	-- Everyone's clothes (user, 2026-10-15 picks; shirts/pants aren't appearance slots since 2026-10-17).
	-- RHS Uniform T-Shirt + pants 2028500139 / RHS Female Uniform Sleeves + Bottoms.
	UNIFORM = {
		Male = { Shirt = 2028787356, Pants = 2028500139 }, -- pants: user, 2026-10-18
		Female = { Shirt = 2649736301, Pants = 473173027 },
	},
	MENU_ART = "rbxassetid://71346810321619", -- side menu stickers (Desktop/MidoriHUD/menu_art.py); new filename per change (Studio caches)
	MENU_WINDOW = "rbxassetid://137292041107468", -- the P menu's page panel (menu_art.py -> midori_menu_window.png), same caveat
	HUD_CD_FADE_DELAY = 3, -- cooldown stickers fade out this long after they're ready (user, 2026-10-17)
	HUD_FRAME = "rbxassetid://111609066959075", -- v7: translucent card-style drops; v6: + cooldown stickers; v5: opaque slab shadow, no rim line, light blue-grey empty tracks (new name dodges Studio's texture cache) -- 1024x1024: housing (top half) + one fill strip per bar
	HUD_BPM = 135, -- the whole HUD bops on this beat
	HUD_TRAIT_IDLE_SAT = 0.3, -- trait card saturation when it hasn't procced lately
	HUD_TRAIT_PROC_HOLD = 2.5, -- seconds at full colour after a proc
	HUD_GUARD_COLOR = Color3.fromRGB(255, 255, 255),
	HUD_HP_COLOR = Color3.fromRGB(120, 240, 60),
	HUD_HEALABLE_COLOR = Color3.fromRGB(40, 120, 30), -- healable HP (HealthSystem), right after the fill
	HUD_ADR_COLOR = Color3.fromRGB(240, 36, 60),
	HUD_FOCUS_COLOR = Color3.fromRGB(150, 215, 255), -- Focus bar under adrenaline (only while Focus is on)
	HUD_SLASH_COLOR = Color3.fromRGB(225, 18, 40), -- Persona red slash behind the bars
	-- Healable HP (user, 2026-10-14; ServerScriptService.Midori.HealthSystem). Of every hit's damage,
	-- HEAL_KEEP comes back over time (shown dark red); the rest is gone for good. A move's `antiHeal`
	-- (0-1) wipes that fraction of the victim's healable pool and of the hit's own healable part.
	HEAL_KEEP = 0.75,
	HEAL_MAX = 25, -- hits never push the healable pool past this (user); a siphon still can
	HEAL_REGEN_PER_SEC = 3, -- user, 2026-10-17 (was 4, before that 2)
	HEAL_REGEN_DELAY = 0.7, -- user, 2026-10-17 (was 0.5): regen waits this long after being attacked AND after leaving a stun (not endlag)
	-- Siphon (user): a kill makes ALL your missing HP healable, then heals `heal` of it over `duration`.
	SIPHON = { heal = 35, duration = 0.5 }, -- duration is my pick for "quickly"
	SHIELD_FADE = 0.1, -- show / hide fade
	-- Guard meter inside the shield (user, 2026-10-10): the shield fills bottom-up with guard.
	SHIELD_EMPTY_OPACITY = 0.3, -- how visible the empty (lost-guard) part of the shield is
	SHIELD_WEAK_PULSE_SPEED = 4, -- weak guard ghost pulses per second
	SHIELD_WEAK_PULSE_SCALE = 0.3, -- ghost grows up to this much bigger than the shield
	SHIELD_WEAK_TRANSPARENCY = 0.55, -- ghost transparency at its smallest (fades as it grows)
	SHIELD_BROKEN_COLOR = Color3.fromRGB(85, 85, 95), -- guard-broken shield tint
	PARRY_COLOR = Color3.fromRGB(255, 215, 60), -- parry shield tint + parry hit effect
	SHIELD_BROKEN_TRANSPARENCY = 0.25,
	SHIELD_CRACK_GROW = 0.15, -- crack grows in over this long
	SHIELD_VISIBLE_DIST = 20, -- studs from YOUR character: fully opaque up to here
	SHIELD_HIDE_DIST = 30, -- fades out between VISIBLE and HIDE, gone beyond
	SHIELD_LOS_INTERVAL = 0.1, -- seconds between line-of-sight rays per visible shield
	SHIELD_LOS_FADE = 0.15, -- fade in/out when line of sight changes

	-- Ghost (universal afterimage VFX, StarterPlayerScripts.Midori.Ghost)
	GHOST_START_TRANSPARENCY = 0.5,
	GHOST_FADE = 0.3, -- seconds to fade fully out
	GHOST_COLOR = Color3.new(1, 1, 1),
	GHOST_MATERIAL = Enum.Material.SmoothPlastic,

	-- Ban Hammer critical's cage (Midori.Bancage, user 2026-10-15). Transparencies are the user's; times
	-- are seconds from the swing. It drops `drop` studs onto the feet over `fall` (= the 0.3 hit) fading
	-- startT -> landT, snaps to flashT at the hit, eases back to holdT over `flash`, then fades out over `linger`.
	BANCAGE = table.freeze({
		drop = 8, -- my pick
		fall = 0.3,
		startT = 0.8,
		landT = 0.5,
		flashT = 0.1,
		flash = 0.1, -- my pick
		holdT = 0.7,
		linger = 1,
	}),

	-- Impact frames (Midori.ImpactFrame, user 2026-10-11): stark black/white flash + silhouettes +
	-- hitstop + camera kick, shown only to the attacker and the victim. What triggers one is the
	-- user's call: a move with `impact = true` (style data) on a landed hit (Hit / Counter / Clash),
	-- or any result switched on in IMPACT_RESULTS below (for every move). All off to start.
	IMPACT_RESULTS = {
		Counter = false, -- counter crits
		Clash = false,
		Parried = false,
		GuardBreak = false,
	},
	-- M2 / crit limb flash (Midori.LimbFx, move.limbFx; user 2026-10-16). time/spin/squares/ghostTransparency are my picks.
	LIMB_FX = table.freeze({
		time = 0.35, -- seconds until fully gone
		ghostScale = 1.1, -- ghost is 10% bigger than the limb (user)
		ghostTransparency = 0.5,
		squares = 3, -- HallowSquares at the limb's end
		size = 2.6, -- studs at the start (user, 2026-10-16; was 1.7 -> 2.2)
		endSize = 0.4, -- shrinks to this (user)
		shrinkStyle = Enum.EasingStyle.Quad, -- eased In (user): slow first, fast at the end; Quad is my pick
		startTransparency = 0.7, -- user, 2026-10-16 (was 0.3 -> 0.7 -> 0.1 -> 0.7)
		spin = 25, -- rad/s
		color = Color3.new(1, 1, 1), -- ghost + squares (user: white)
	}),
	-- Crits (R) use LIMB_FX with these on top (user, 2026-10-16).
	LIMB_FX_CRIT = table.freeze({
		size = 3.6, -- user
		color = Color3.fromRGB(255, 30, 30), -- red (user); same red as CRIT_FLASH_COLOR
		time = 0.45, -- "a tiny bit longer" than the M2's 0.35 (user); 0.45 is my pick
	}),
	-- Lit-fuse crits (Firecracker, user 2026-10-16): crit squares (no ghost) keep popping on the
	-- crit's limbFx limbs from the light until the barrage ends, spinning slower.
	LIMB_FX_FUSE = table.freeze({
		every = 0.3, -- seconds between bursts (my pick)
		spinMult = 0.5, -- "slower" (user); half speed is my pick
	}),
	LAND_BLUR_FADE = 5, -- seconds a move's landed-hit blur (move.blur) takes to fade back to normal (user, 2026-10-16)
	IMPACT_POP_RANGE = 12, -- a fuse with `impact` going off flashes for anyone this close (studs), plus its user
	IMPACT = {
		-- Each frame: "light" (washed-out world, black silhouettes) or "dark" (dark world, white ones).
		-- One soft frame, then a fade back (user: the light/dark strobe was too flashy).
		frames = { { look = "light", time = 0.06 } },
		fade = 0.2, -- seconds to ease the world colour and silhouettes back to normal
		hitstop = 0.08, -- both fighters' animations freeze this long (visual only; server timing unchanged)
		shake = 0.3, -- camera kick, studs
		shakeTime = 0.12,
	},

	-- Fuse camera (user, 2026-10-11): only on the Firecracker user's own screen, via Midori.CameraFov
	-- (multipliers on the player's base FOV, so the planned FOV slider keeps working).
	FUSE_CAMERA = {
		zoomAt = 0.3, -- seconds of fuse left when the zoom-in starts (user, 2026-10-11)
		zoom = 0.5, -- FOV multiplier for that zoom-in: 50% (user, 2026-10-11)
		zoomStyle = Enum.EasingStyle.Quad, -- zoom-in eases OUT over the whole zoomAt (Exponential front-loaded it into ~0.1s)
		barrage = 1.35, -- FOV multiplier during the barrage (user: more; was 1.2)
		barrageIn = 0.1, -- seconds to widen when it goes off
		out = 0.3, -- seconds back to normal after the barrage (or a fizzle)
	},

	-- Fuse meter (FeedbackController, user 2026-10-11): Assets.2d.Bomb above a lit fuse, draining top to bottom.
	FUSE_METER = {
		size = 2, -- studs
		height = 4.5, -- studs above the root (over the head)
		maxDistance = 80,
		emptyColor = Color3.fromRGB(60, 60, 60), -- the burnt part
		emptyTransparency = 0.5,
	},

	-- Barrage fists (clones of the attacker's arms, FeedbackController; count = barrage.fists).
	-- Offsets are studs in the attacker's root space (arm centre; -Z is forward).
	BARRAGE_FIST = {
		startTransparency = 0.3, -- slightly see-through when it appears
		thrustTransparency = 0.6, -- fades to this while punching forward
		thrust = 0.12, -- seconds punching forward
		from = 2, -- offset at spawn (+ = behind the root; user: start 2 studs behind)
		tipEnd = 6.5, -- where the fist's tip ends the thrust, in front of the root (= Firecracker crit hitbox front, user)
		scale = 1.25, -- arm size multiplier (user: bigger arms, then reduced from 1.5)
		fade = 0.1, -- seconds for the fade-out right after
		drift = 0.5, -- studs of leftover momentum during the fade-out
		height = 1, -- above the root
		spread = Vector2.new(3.5, 0.6), -- random +- sideways / up-down (X = half the Firecracker crit hitbox width)
	},

	-- Debug
	CHECK_INVARIANTS = false, -- frame-data invariant report at boot + its test (Shared/Invariants)
	DEBUG_HITBOXES = true, -- Studio playtests only
})
