--!strict
-- Cutscenes (user, 2026-10-22; for fight moves later). Played by ServerScriptService.Midori.CutsceneService:
--   1v1 (play1v1): only the attacker's and victim's screens run the camera; everyone else just sees the
--     actors' animations.
--   3P  (play3P): every player's screen runs the camera.
-- A move with `cutscene = "<id>"` plays it 1v1 when it lands clean (Hit / Counter; HitResolver).
-- Actors are in State.Cutscene for `duration`: rooted, can't act, can't be hit.
-- Fields:
--   duration  seconds
--   camera    keyframes { t, cf, fov?, style?, dir? }: `cf` is RELATIVE to the anchor (the attacker's root
--             CFrame when it starts; -Z = where they face). Eases from the previous keyframe to this one
--             with `style`/`dir` (Enum.EasingStyle / EasingDirection, default Quad / InOut). `fov` = a
--             multiplier on the player's FOV (CameraFov), default 1. Two keys at the same t = a hard cut.
--   returnTime  the last this-many seconds blend the camera from where the keyframes left it into the
--             player's normal (shift-lock) camera, which ends up behind them looking where they face.
--   kicks     { { t, s } }: camera punch (FOV squeeze + shake) of strength s at t, decaying fast.
--   actors    role -> { offset?, anim?, cues? }: `offset` = CFrame from the anchor the actor is put at (the
--             attacker usually has none); `anim` = path under Assets.Animations, played on the server;
--             `cues` = timed teleports / dashes / clips (Shared/CutsceneTimeline: moves by whoever owns the
--             body, clips locally on every screen).
--   hits      { { t, damage } } flat damage on the victim (no multipliers), `antiHeal` 0-1 each.
--   barrages  { { t, duration, swings, speed, fists, copies, copyTransparency, leftArm } }: client-side
--             barrage dressing (StarterPlayerScripts.Midori.CutsceneBarrage): trailed arm clones, see-through
--             copies punching `swings` alongside the attacker, the attacker's left arm faded.
--   finisher  { t, damage, knockback, ragdoll }: the last hit; the victim leaves the cutscene into
--             hitstun with the knockback + ragdoll (knocked here if a hit took them to the floor).
--   hitSound  { id, volume = { min, max }, pitch = { min, max }, minStep }: plays at the victim on every
--             hit for everyone; random volume and PlaybackSpeed (pitch + speed together), the speed at
--             least minStep away from the last punch's. Preloaded on every client.
--   music     { sound, fade, at? }: path under Assets.Sfx, played on each watching screen from `at`
--             (default 0) and faded out over `fade` so it's silent exactly at `duration`.
--   intro     seconds the gameplay camera stays (the move's impact frame) while the screen fades to
--             black (`black` = { fadeIn, fadeOut }); the cutscene camera swaps in under full black at
--             `intro`, then the black lifts.
--   stage     { center, radius, height, light, floorImage? }: the local "stage" round the
--             fighters on watching screens (StarterPlayerScripts.Midori.CutsceneStage), up under the
--             intro's black, faded out over `returnTime`.
--   startSound  { sound, fadeAt, fade }: a Sound in Assets.Sfx.Cutscenes, played with the hit sound of
--             the hit that starts the cutscene (FeedbackController, fighters only), faded out linearly
--             from fadeAt over fade, the same every time.
--   sfx       { { t, sound } }: path under Assets.Sfx, played locally on each watching screen.
--   letterbox true = black bars in; hideHud true = the HUD slides out.

-- A camera shot relative to Prodigy (see prodigyCrit), and the camera rig's state.
type Shot = { rel: number, h: number, fov: number, scale: number, drift: number }
type Cam = { phi: number, h: number, fov: number, scale: number }

local function look(from: Vector3, at: Vector3): CFrame
	return CFrame.lookAt(from, at)
end

local function lerp(a: number, b: number, u: number): number
	return a + (b - a) * u
end

-- The dash's own curve, so the camera rides each dash exactly.
local dashEase = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("DashMotor")).ease

-- Prodigy's crit (user, 2026-10-23): 1-2-3 flurries, dashing round the victim to a new angle between
-- them; midway the victim swings 3 M1s (their own style's) and Prodigy slips every one; then the 4th M1
-- launches them, after one long dash round their whiffed critical. 30 damage total, 100% anti-heal.
-- M1 clips at 1.4x, dash clips fitted to each dash (user). Every dash plays the normal dash sound.
-- Camera (user: readable, rule of thirds, follow the dashes): every shot is a two-shot of both fighters,
-- its distance solved so they sit on the vertical thirds and their heads on the upper third; over each
-- dash the camera rides along on the dash's own curve.
local function prodigyCrit()
	local DURATION, RETURN = 14, 2
	local INTRO = 0.45 -- black is full here (impact frame, then the fade; user 2026-10-23)
	local FINISHER_DAMAGE = 6
	local M1_SPEED = 1.4
	-- Dash clips (~0.95s at 1x) sped up to fit each dash: 0.7s of clip over the dash's time, 1.6x-2.6x
	-- (user, 2026-10-23: faster dash anims; was a flat 1.25x).
	local function dashSpeed(dur: number): number
		return math.clamp(0.7 / dur, 1.6, 2.6)
	end
	local M1_LAND = 0.27 / M1_SPEED -- Prodigy's M1s land 0.27s into the clip at 1x (style animHit)
	local GAP = 0.3 -- between Prodigy's M1s (each clip is ~0.34s at 1.4x; the next cuts its recovery)
	-- After the victim's 3 swings (user, 2026-10-24): back in for a "bang bang" (M1s 1, 2), a pause,
	-- then the barrage carrying on from 3: 3-1-2-3-1-2-3-1-2-3, faster clips, arm clones with trails
	-- flying past, two 0.9-transparency copies punching alongside, the left arm half see-through
	-- (client: StarterPlayerScripts.Midori.CutsceneBarrage), and a camera sweeping round it.
	local BARRAGE_PUNCHES = 10
	local BARRAGE_SPEED = 1.8
	local BARRAGE_LAND = 0.27 / BARRAGE_SPEED
	local BARRAGE_GAP = 0.2
	local BANG_PAUSE = 0.2 -- after the bang bang's 2nd punch lands (user: 0.5 -> 0.2)
	local DODGE_AFTER = 3 -- the victim's counter-flurry (then the barrage) comes after this many 1-2-3s; always played
	local V = Vector3.new(0, 0, -4.5) -- the victim's root, relative to the anchor (4.5 in front, user)
	local REACH = 4.5 -- Prodigy punches from this far (same as the start, so nobody closes in)
	local SAMPLE = 0.05 -- camera keys this far apart (linear between them)
	-- Framing assumes the default 70 deg FOV on a 16:9 screen; others land close enough.
	local BASE_HALF_FOV, ASPECT = 35, 16 / 9
	local R_MIN, R_MAX = 4, 11
	local HEAD_Y = 1.5 -- head height above the root

	-- A point round the victim: theta 0 = where Prodigy started (anchor side), y relative to the root.
	local function around(theta: number, r: number, y: number): Vector3
		return V + Vector3.new(math.sin(theta) * r, y, math.cos(theta) * r)
	end
	local function facing(theta: number, r: number): CFrame
		return CFrame.lookAt(around(theta, r, 0), V)
	end

	-- Prodigy's path: { t0, t1, th0, th1, r0, r1 } in time order (each eased like the dash itself).
	local path = {}
	local function prodigyAt(t: number): (number, number)
		local th, r = 0, REACH
		for _, m in path do
			if t >= m.t1 then
				th, r = m.th1, m.r1
			elseif t > m.t0 then
				local e = dashEase((t - m.t0) / (m.t1 - m.t0))
				return lerp(m.th0, m.th1, e), lerp(m.r0, m.r1, e)
			else
				break
			end
		end
		return th, r
	end

	-- Two-shot from angle `phi` round the pair's midpoint. Distance is solved so the fighters land on
	-- the vertical thirds (clamped, then x `scale`), aimed so heads sit on the upper third.
	local function twoShot(t: number, phi: number, height: number, fov: number, scale: number): (CFrame, number)
		local th, r = prodigyAt(t)
		local p = around(th, r, 0)
		local mid = (p + V) / 2
		local dir = Vector3.new(math.sin(phi), 0, math.cos(phi))
		local line = p - V
		local across = line.Magnitude / 2 * math.abs(line.Unit:Cross(dir).Y) -- half the gap as seen from the camera
		local tanV = math.tan(math.rad(BASE_HALF_FOV * fov))
		local dist = math.clamp(across / (tanV * ASPECT / 3), R_MIN, R_MAX) * scale
		local aimY = math.clamp(HEAD_Y - dist * tanV / 3, -0.5, 1.2)
		return look(mid + dir * dist + Vector3.yAxis * height, mid + Vector3.yAxis * aimY), fov
	end

	-- Shots, relative to Prodigy: rel = the camera's angle off the victim->Prodigy line (0 = behind
	-- Prodigy, pi/2 = side-on, past that = round on Prodigy's face side), drift = how far it creeps round
	-- through the flurry.
	local SHOTS: { Shot } = {
		{ rel = 1.15, h = 1.6, fov = 0.9, scale = 1, drift = 0.15 }, -- 3/4 behind Prodigy, right
		{ rel = -1.6, h = 1, fov = 0.85, scale = 1, drift = -0.12 }, -- side-on, left
		{ rel = 2.2, h = 2.2, fov = 0.9, scale = 1.05, drift = 0.12 }, -- Prodigy's face, over the victim's side
		{ rel = -1, h = 3.6, fov = 0.95, scale = 1.2, drift = -0.15 }, -- high 3/4, left
		{ rel = 1.7, h = 0.2, fov = 0.85, scale = 1, drift = 0.1 }, -- low side-on, looking up a touch
		{ rel = -2.2, h = 1.8, fov = 0.85, scale = 1, drift = -0.12 }, -- Prodigy's face, left
		{ rel = 1.35, h = 4.5, fov = 1, scale = 1.4, drift = 0.18 }, -- high wide
	}
	local OPEN: Shot = { rel = 2, h = 1.3, fov = 0.75, scale = 0.9, drift = 0.15 } -- Prodigy's face, tight
	local DODGE: Shot = { rel = 1.45, h = 1.4, fov = 0.95, scale = 1.25, drift = 0 } -- side-on, full bodies
	local FINISH: Shot = { rel = 1.57, h = 1.3, fov = 0.85, scale = 1, drift = 0 }
	-- How far round each dash between flurries goes (radians; + = Prodigy's right).
	local TURNS = { 1.9, -2.5, 2.2, -1.8, 2.4, -2.1, 1.7, -2.3 }

	local camera, attacker, victim, hitTimes, kicks = {}, {}, {}, {}, {}
	local function key(t: number, cf: CFrame, fov: number?)
		table.insert(camera, { t = t, cf = cf, fov = fov, style = Enum.EasingStyle.Linear })
	end
	-- Samples fn over [t0, t1]. A segment starting where the last one ended is a cut if they disagree.
	local function segment(t0: number, t1: number, fn: (number) -> (CFrame, number))
		local n = math.max(1, math.ceil((t1 - t0) / SAMPLE))
		for i = 0, n do
			local t = t0 + (t1 - t0) * i / n
			key(t, fn(t))
		end
	end

	local cam: Cam = { phi = 0, h = 0, fov = 1, scale = 1 } -- where the camera rig is at the end of the last segment
	local function shotAt(s: Shot, th: number, u: number): Cam
		return { phi = th + s.rel + s.drift * u, h = s.h, fov = s.fov, scale = s.scale * (1 - 0.06 * u) }
	end
	local function frame(t: number, c: Cam): (CFrame, number)
		return twoShot(t, c.phi, c.h, c.fov, c.scale)
	end
	-- Creep through shot `s` while Prodigy stands at th.
	local function hold(t0: number, t1: number, s: Shot, th: number)
		segment(t0, t1, function(t)
			return frame(t, shotAt(s, th, (t - t0) / (t1 - t0)))
		end)
		cam = shotAt(s, th, 1)
	end
-- Hard cut at t0 to shot `s` (framed for Prodigy's angle th) and hold its rig still to t1; the
	-- framing still follows them, so a dash plays out inside the shot (user: hard cuts are fine).
	local function cut(t0: number, t1: number, s: Shot, th: number)
		segment(t0, t1, function(t)
			return frame(t, shotAt(s, th, 0))
		end)
		cam = shotAt(s, th, 0)
	end

	local function hit(t: number, s: number)
		table.insert(hitTimes, t)
		table.insert(kicks, { t = t, s = s })
		table.insert(victim, { t = t, anim = "Generic/Hitstun", speed = 1.6 })
	end

	local th, r = 0, REACH -- where Prodigy is
	-- Dash round the victim to angle `to`, staying `r` out and facing them.
	local function orbitTo(t: number, to: number, dur: number)
		table.insert(attacker, {
			t = t,
			orbit = { center = V, radius = r, from = th, to = to, duration = dur },
			anim = if to > th then "Dash/Right" else "Dash/Left",
			speed = dashSpeed(dur),
		})
		table.insert(attacker, { t = t + dur, cf = facing(to, r) }) -- settle exactly on the circle
		table.insert(path, { t0 = t, t1 = t + dur, th0 = th, th1 = to, r0 = r, r1 = r })
		th = to
	end
	-- Straight dash along the facing ("Front" closes in, "Back" backs off).
	local function step(t: number, dir: string, distance: number, dur: number)
		local r1 = r + (if dir == "Back" then distance else -distance)
		table.insert(attacker, { t = t, dash = { dir = dir, distance = distance, duration = dur }, anim = `Dash/{dir}`, speed = dashSpeed(dur) })
		table.insert(attacker, { t = t + dur, cf = facing(th, r1) })
		table.insert(path, { t0 = t, t1 = t + dur, th0 = th, th1 = th, r0 = r, r1 = r1 })
		r = r1
	end
	local function flurry(t: number, s: Shot): number
		hold(t, t + GAP * 3, s, th)
		for i = 0, 2 do
			local at = t + i * GAP
			table.insert(attacker, { t = at, anim = `Prodigy/{i + 1}`, speed = M1_SPEED })
			hit(at + M1_LAND, 0.6)
		end
		return t + GAP * 3
	end
	-- The barrage: carries the chain on from 3 (3-1-2-3...), BARRAGE_GAP apart. Camera: a low hero
	-- angle sweeping round the pair (from over Prodigy's right shoulder, past side-on, round to Prodigy's
	-- face) while pushing in and rising, so the clones and copies read from every side. The sweep starts
	-- at `panFrom` (Prodigy dashing back in), so the bang bang and the barrage are one move (user).
	local barrages = {}
	-- (angles as SHOTS: 0 = behind Prodigy; ends at 2.3 = Prodigy's face 3/4, never behind the victim)
	local PAN = { from = 0.7, sweep = 1.6, h0 = 0.4, h1 = 1.9, fov0 = 0.95, fov1 = 0.78, scale0 = 1.1, scale1 = 0.85 }
	local function barrage(t: number, panFrom: number): number
		local len = BARRAGE_GAP * BARRAGE_PUNCHES
		local side = if th >= 0 then 1 else -1 -- sweep away from the side Prodigy came round
		local panLen = t + len - panFrom
		segment(panFrom, t + len, function(at)
			local u = 0.5 - 0.5 * math.cos(math.pi * (at - panFrom) / panLen) -- sine in-out
			return twoShot(at, th + side * (PAN.from + PAN.sweep * u), lerp(PAN.h0, PAN.h1, u), lerp(PAN.fov0, PAN.fov1, u), lerp(PAN.scale0, PAN.scale1, u))
		end)
		local swings = {}
		for i = 0, BARRAGE_PUNCHES - 1 do
			local at = t + i * BARRAGE_GAP
			local anim = `Prodigy/{(i + 2) % 3 + 1}` -- 3, 1, 2, 3, ...
			table.insert(attacker, { t = at, anim = anim, speed = BARRAGE_SPEED })
			table.insert(swings, { t = at, anim = anim })
			hit(at + BARRAGE_LAND, 0.35)
		end
		table.insert(barrages, {
			t = t,
			duration = len,
			swings = swings, -- the copies punch these too
			speed = BARRAGE_SPEED,
			fists = 22, -- arm clones over the barrage; each plays the hit sound too (CutsceneService)
			copies = { CFrame.new(-2.4, 0, 1.3), CFrame.new(2.4, 0, 1.3) }, -- off Prodigy's root
			copyTransparency = 0.9,
			leftArm = 0.5, -- the real left arm's local transparency while it lasts
		})
		return t + len
	end

	-- Intro: the crit's impact frame on the gameplay camera, a fade to black, and under it the victim
	-- is set in place and the cutscene camera takes over (CutsceneController `intro`).
	table.insert(victim, { t = INTRO, cf = CFrame.new(V) * CFrame.Angles(0, math.pi, 0) })
	-- Prodigy too, onto the anchor facing them: the anchor is the server's view of Prodigy, which trails a
	-- dashing Reentry by the ping, so without this Prodigy starts a few studs off and punches air.
	table.insert(attacker, { t = INTRO, cf = facing(0, REACH) })
	-- Opening: tight on Prodigy's face side as the black lifts, creeping round, then a cut to the first flurry.
	hold(0, INTRO + 0.45, OPEN, 0)
	local t = flurry(INTRO + 0.45, SHOTS[1])

	-- The finale: the victim's critical (their style's, started early enough for any style: Firecracker's
	-- needs 0.93s at 1.4x) whiffs as Prodigy takes one long dash round them, straight into the 4th M1.
	local CRIT_WIND, LONG_DASH = 0.95, 0.55
	local FINALE_LEN = CRIT_WIND - 0.15 + LONG_DASH + M1_LAND
	local DODGE_LEN = 1.75 -- the M1 exchange + the dash back in
	local k = 1
	while true do
		local dash = 0.36 - 0.02 * k -- the dashes get snappier
		local nextShot = SHOTS[(k % #SHOTS) + 1]
		local need = (if k == DODGE_AFTER then DODGE_LEN + GAP + M1_LAND + BANG_PAUSE + BARRAGE_GAP * BARRAGE_PUNCHES else dash + GAP * 3) + FINALE_LEN
		if k ~= DODGE_AFTER and t + need > DURATION - RETURN - 0.4 then
			break -- no room for another dash + flurry before the finale (the dodge + barrage always plays)
		end
		if k == DODGE_AFTER then
			-- The victim fights back: 3 of their own M1s (their style's clip and timing), Prodigy slips each.
			local t0, th0 = t, th
			local land1, land2, land3 = t + 0.3, t + 0.75, t + 1.2
			table.insert(victim, { t = t, cf = CFrame.lookAt(V, around(th, r, 0)) })
			table.insert(victim, { t = land1, m1 = 1, speed = M1_SPEED })
			step(land1 - 0.12, "Back", 2.5, 0.25) -- swing 1: backs out of reach
			table.insert(victim, { t = land2, m1 = 2, speed = M1_SPEED })
			orbitTo(land2 - 0.12, th + 1, 0.28) -- swing 2: slides round to the right
			table.insert(victim, { t = land3 - 0.25, cf = CFrame.lookAt(V, around(th, r, 0)) }) -- they turn to follow
			table.insert(victim, { t = land3, m1 = 3, speed = M1_SPEED })
			orbitTo(land3 - 0.12, th - 2, 0.32) -- swing 3: whips round the other way, past it
			for _, at in { land1, land2, land3 } do
				table.insert(kicks, { t = at, s = 0.3 })
			end
			t = land3 + 0.3
			-- A steady side-on wide for the whole exchange (the framing follows them), then a cut as
			-- Prodigy dashes back in.
			hold(t0, t, DODGE, th0)
			step(t, "Front", r - REACH, 0.25)
			-- Back in: bang, bang (M1s 1 and 2), a pause, then the barrage from 3 (user, 2026-10-24).
			local bangAt = t + 0.25
			for i = 0, 1 do
				local at = bangAt + i * GAP
				table.insert(attacker, { t = at, anim = `Prodigy/{i + 1}`, speed = M1_SPEED })
				hit(at + M1_LAND, 0.6)
			end
			local barrageAt = bangAt + GAP + M1_LAND + BANG_PAUSE
			t = barrage(barrageAt, t) -- the pan starts as Prodigy dashes back in
		else
			local turn = TURNS[(k - 1) % #TURNS + 1]
			orbitTo(t, th + turn, dash)
			cut(t, t + dash, nextShot, th)
			t = flurry(t + dash, nextShot)
		end
		k += 1
	end

	-- Finale: they turn and throw their critical; Prodigy goes the long way round as it whiffs.
	local critLand = t + CRIT_WIND
	table.insert(victim, { t = t, cf = CFrame.lookAt(V, around(th, r, 0)) })
	table.insert(victim, { t = critLand, crit = true, speed = M1_SPEED })
	table.insert(kicks, { t = critLand, s = 0.45 })
	local th0, dashAt = th, critLand - 0.15
	local turn = if th > 0 then -2.8 else 2.8
	orbitTo(dashAt, th + turn, LONG_DASH)
	-- Beat 1, the wind-up: from behind Prodigy's right shoulder, curving round their right side to a
	-- 3/4 angle (user: more curve, the victim was hidden). Prodigy holds the left of frame, the victim
	-- opens up toward the right third (checked: their heads stay 0.4-0.8 of the screen apart).
	do
		local p = around(th0, REACH, 0)
		local toV = (V - p).Unit
		local right = CFrame.lookAt(Vector3.zero, toV).RightVector
		segment(t, dashAt, function(at)
			local u = 0.5 - 0.5 * math.cos(math.pi * (at - t) / (dashAt - t)) -- sine in-out
			local yaw = lerp(0.75, 1.3, u) -- off Prodigy's back, swinging out to their right
			local from = p + (-toV * math.cos(yaw) + right * math.sin(yaw)) * lerp(4.2, 3.8, u) + Vector3.yAxis * lerp(2.3, 2, u)
			return look(from, V:Lerp(p, 0.5) + Vector3.yAxis * 1.1), 0.8
		end)
	end
	-- Beat 2, the whiff: a still, high wide aimed at the victim from opposite the middle of the arc, so
	-- Prodigy carves a clean C round them across the frame while the critical hits air.
	do
		local away = th0 + turn / 2 + math.pi
		local from = around(away, 9, 8.5)
		segment(dashAt, dashAt + LONG_DASH, function()
			return look(from, V + Vector3.yAxis * 0.5), 0.9
		end)
	end
	t = dashAt + LONG_DASH
	-- Cut in close as the 4th M1 launches them straight away from Prodigy.
	table.insert(attacker, { t = t, anim = "Prodigy/4", speed = M1_SPEED })
	local finAt = t + M1_LAND
	local wind = t
	segment(wind, finAt, function(at) -- push in on the wind-up
		local u = (at - wind) / (finAt - wind)
		u *= u
		return twoShot(at, th + FINISH.rel, FINISH.h, lerp(0.85, 0.75, u), lerp(1, 0.8, u))
	end)
	table.insert(kicks, { t = finAt, s = 1.6 })
	table.insert(attacker, { t = finAt + 0.35, idle = true }) -- punches done: back to idle
	table.insert(victim, { t = finAt, idle = true }) -- the ragdoll takes over
	-- Impact: cut behind Prodigy's right shoulder and watch them fly off down the line, drifting back.
	local p = around(th, REACH, 0)
	local launch = (V - p).Unit
	local right = CFrame.lookAt(Vector3.zero, launch).RightVector
	segment(finAt, DURATION - RETURN, function(at)
		local u = math.sin((at - finAt) / (DURATION - RETURN - finAt) * math.pi / 2)
		local from = p - launch * lerp(4.5, 6, u) + right * lerp(2, 1.75, u) + Vector3.yAxis * lerp(2.6, 2.4, u)
		return look(from, V + launch * lerp(12, 18, u) + Vector3.yAxis), lerp(1.1, 1, u)
	end)
	assert(finAt < DURATION - RETURN, "ProdigyCrit: the finisher must land before the camera heads home")

	local per = (30 - FINISHER_DAMAGE) / #hitTimes
	local hits = {}
	for _, at in hitTimes do
		table.insert(hits, { t = at, damage = per })
	end
	return table.freeze({
		duration = DURATION,
		returnTime = RETURN,
		intro = INTRO,
		black = { fadeIn = 0.3, fadeOut = 0.4 },
		startSound = { sound = "ProdigyStart", fadeAt = 0.6, fade = 1.2 }, -- Sfx/Cutscenes/ProdigyStart (135993007037904)
		camera = camera,
		kicks = kicks,
		actors = {
			attacker = { cues = attacker },
			victim = { cues = victim }, -- placed by its first cue, under the black
		},
		hits = hits,
		antiHeal = 1,
		finisher = {
			t = finAt,
			damage = FINISHER_DAMAGE,
			knockback = { distance = 10, duration = 0.5, direction = "Away", up = 14, spin = 10 }, -- user: shorter again (28 -> 16 -> 10; up 35 -> 20 -> 14)
			ragdoll = 3, -- user: 2 -> 5 -> 3; also their hitstun
		},
		hitSound = { id = "rbxassetid://96938149340654", volume = { 0.3, 0.5 }, pitch = { 0.75, 1.35 }, minStep = 0.12 },
		music = { sound = "Cutscenes/ProdigyOST", fade = 0.6, at = INTRO }, -- comes in as the black lifts
		barrages = barrages,
		-- The boxing-match stage (user): black void, lit floor (CutsceneStage), plus floor searchlights aimed
		-- up the middle (user, 2026-10-24; the beat flashes were removed the same day).
		stage = {
			center = V,
			radius = 60, -- the launch carries them ~28 studs: still well inside
			height = 40,
			light = { color = Color3.fromRGB(255, 244, 225), brightness = 2.5 }, -- user: dimmer (was 6)
			uplights = true,
		},
		sfx = {},
		letterbox = true,
		hideHud = true,
	})
end

return table.freeze({
	-- Placeholder to prove the pipeline: swing round the attacker's right side, then push in.
	Test = table.freeze({
		duration = 3,
		camera = {
			{ t = 0, cf = look(Vector3.new(7, 3, -2), Vector3.new(0, 1, -2.5)) },
			{ t = 1.6, cf = look(Vector3.new(3, 2.5, -8), Vector3.new(0, 1, -2.5)), style = Enum.EasingStyle.Sine },
			{ t = 2.6, cf = look(Vector3.new(1.5, 2, -6), Vector3.new(0, 1.5, -4)), fov = 0.75, style = Enum.EasingStyle.Quint, dir = Enum.EasingDirection.Out },
			{ t = 3, cf = look(Vector3.new(1.5, 2, -6), Vector3.new(0, 1.5, -4)), fov = 0.75 },
		},
		actors = {
			attacker = {},
			victim = { offset = CFrame.new(0, 0, -5) * CFrame.Angles(0, math.pi, 0) },
		},
		sfx = {},
		letterbox = true,
		hideHud = true,
	}),
	ProdigyCrit = prodigyCrit(),
})