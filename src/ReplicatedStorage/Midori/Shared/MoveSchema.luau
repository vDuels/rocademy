--!strict
-- Validates raw style tables, fills defaults and freezes the result.
local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")

-- Box: { size, offset }. Cylinder: { shape = "Cylinder", radius, height?, offset }, upright
-- (axis along the root's up); its size is filled in as the bounding box (2r, height, 2r).
export type Hitbox = { shape: string, size: Vector3, offset: CFrame, radius: number? }
-- GuardBreak: a blocked hit breaks guard outright (on by default for R moves; set false to opt out).
-- ParryOnly: a block doesn't stop it (it hits through); only a parry does.
-- Unparryable: a fresh block press just blocks it (no parry window).
-- Strip: a blocked hit always strips the block, as if the guard were weak (held past HOLD_STRIP_THRESHOLD).
-- NoCounter: never counter-crits (a hit on a victim in Startup is a plain hit) and never clashes.
-- Pierce ("100% guard chip"): a blocked hit that breaks the guard (GuardBreak) goes through it as a full
-- hit: damage, knockback, ragdoll, everything, instead of the guard-break stun.
-- NoInterrupt: a hit on a victim mid-attack (Startup / Rush / Barrage) deals damage but no stun or push; their move runs on.
export type Tags = { Unblockable: boolean?, GuardBreak: boolean?, NoCounter: boolean?, ParryOnly: boolean?, Unparryable: boolean?, Strip: boolean?, NoInterrupt: boolean?, Pierce: boolean? }
-- Grab: the first clean hit (Hit / Counter) pulls the victim `gap` studs in front of the attacker over
-- `pull`, holds them for `hold` (victim stunned + rooted, attacker in endlag with i-frames), then the
-- server starts the style's move `move` (CombatService grabTick).
export type Grab = { move: string, pull: number, hold: number, gap: number }
export type Move = {
	id: string,
	kind: string,
	anim: string,
	animHit: number?,
	startup: number,
	active: number,
	endlag: number,
	cooldown: number, -- move can't be used again until this long after its endlag ends
	hitstun: number,
	blockstun: number,
	damage: number,
	guardDamage: number,
	guardRegenDelay: number,
	hitbox: Hitbox,
	cost: number,
	tags: Tags,
	swingSfx: string?, -- sound name in Sfx/Styles/<style>, played on swing (else shared Swingsounds)
	hitSfx: string?, -- sound name in Sfx/Styles/<style>, played on a landed hit (else shared Hitsounds)
	cleanHitSfx: string?, -- sound or folder (every sound in it) in Sfx/Styles/<style>, played on a clean Hit only, instead of the hit sound
	clashSfx: string?, -- sound or folder (every sound in it) in Sfx/Styles/<style>, played when this move clashes, on top of the clash sounds
	contactSfx: string?, -- sound or folder in Sfx/Styles/<style>, played whenever it connects (hit, block, strip, parry, break...); on a hit it replaces the shared hit sound
	landSfx: string?, -- layered on a landed hit's sound (Hit / Counter / Clash), Sfx/Styles/<style>
	chamberRefund: number, -- 0-1: landing it refills this share of a Chambered Dash chamber (PerkBehaviours/ChamberedDash.onLanded)
	impactSfx: string?, -- sound or folder (every sound in it) in Sfx/Styles/<style>, played at the hitbox time, hit or not
	fixedStartup: boolean, -- adrenaline's attack-speed bonus doesn't shorten this move's startup
	antiHeal: number, -- 0-1: landed hits wipe this fraction of the victim's healable HP and make that much less (HealthSystem)
	rooted: boolean, -- the attacker can't walk during startup + endlag (client root lock)
	vfx: string?, -- client module in StarterPlayerScripts/Midori played on swing for everyone (.play(root))
	grab: Grab?,
	countered: { clip: string?, knockback: Knockback? }?, -- what being countered out of this move looks like (see parse)
	maxHpDamage: number, -- > 0: a landed hit deals exactly this share of the victim's max HP (no multipliers)
	ragdoll: number, -- > 0: a landed hit ragdolls the victim this long (Shared/Ragdoll); must fit in hitstun
	impact: boolean, -- landed hits (Hit / Counter / Clash) play an impact frame for attacker + victim
	limbFx: { string }?, -- limb name(s) (e.g. "Right Leg" or { "Left Arm", "Right Arm" }): on swing start the limb ghosts + HallowSquares spin at its end (client LimbFx)
	limbColor: Color3?, -- overrides the limb flash colour (ghost + squares)
	limbTime: number?, -- the limb flash's ghost + squares last this long from the swing (default: ghost cfg.time, squares to the hit)
	trail: { limb: string, from: number, to: number, color: Color3? }?, -- a WindTrail on that limb's end from `from` to `to` s into the swing (after `lead`, if any) (client)
	afterimage: boolean, -- rush moves: the cutscene's ghost trail (client Afterimage) while dashing, on every screen
	blur: number, -- > 0: landed hits blur attacker + victim's screens (BlurEffect size), fading over D.LAND_BLUR_FADE
	knockback: Knockback?, -- landed hits push the victim along the attacker's facing (server-run)
	rush: Rush?, -- startup is a windup, then the fighter charges with the hitbox live (see Rush)
	charge: Charge?, -- hold to extend the windup for a longer, harder rush (see Charge)
	step: Step?, -- the attacker steps forward during startup (see Step)
	fuse: Fuse?, -- startup is a random timer instead of `startup` (see Fuse)
	barrage: Barrage?, -- after startup, `hits` hits spread over `duration` (see Barrage)
	cutscene: string?, -- a clean landed hit (Hit / Counter) plays this Data/Cutscenes id 1v1 on attacker + victim
	close: Close?, -- R only: thrown as another move when a fighter is close (CombatMath.rMove)
	dashRefresh: boolean, -- a landed hit (Hit / Counter / Clash) makes the dash ready again
	cooldownRefresh: { M2: number, R: number }?, -- a landed hit cuts these shares of the M2 / R full cooldowns (this move's own included)
	unlocks: { move: string, window: number }?, -- a landed hit unlocks that `locked` move (same style) for the next `window` seconds
	focusShare: number, -- > 0: a landed hit gains this share of the attacker's CURRENT Focus (replaces the usual gain)
	locked: boolean, -- can't be thrown until another move's `unlocks` lands; throwing it locks it again
	landShift: string?, -- D.COLOR_SHIFT key: a landed hit pulses it on the attacker's + victim's screens
	useShift: string?, -- D.COLOR_SHIFT key: on the user's screen while the move runs (its dof focuses the unlock target)
	targetShift: string?, -- D.COLOR_SHIFT key: on that unlock target's screen while it runs, its dof on the user
	slowZone: boolean, -- the hitbox drops a slow zone, hit or not, on the attacker + every fighter inside it (D.SLOW_ZONE)
	slamFx: boolean, -- the slam's rocks at the hitbox (FeedbackController.release), visual only; a slowZone shows them too
	blink: Blink?, -- swing charge only: the hit is a lane that grows with the charge, and the attacker teleports to its end (see Blink)
	iframes: number?, -- i-frames from the press until the hit, plus this many seconds after it (any state)
	strongRagdoll: boolean, -- a landed ragdoll also puts Vfx.WindTrail on the victim until they get up
	-- > 0: the ragdoll (and the hitstun with it) ends this long after the launched body lands, instead of
	-- running its full `ragdoll` (which stays the cap). HitResolver.getUpOnLanding.
	ragdollLand: number,
	-- Two clips over startup (Furious Feng dash kick): `lead.anim` holds for the first `lead.time`, then
	-- `anim` plays so its animHit lands at startup. AnimationHandler.playAttack.
	lead: { anim: string, time: number }?,
	projectile: Projectile?, -- the hit is a thrown object instead of a hitbox on the attacker (see Projectile)
}
-- Projectile (Furious Feng KickCan): at the hit time (startup) an object leaves `offset` from the attacker's
-- root and flies straight along their facing at `speed` studs/s for up to `range` studs; the move's hitbox
-- rides on it and its first contact is the hit (CombatService shots). Look (client, move.vfx): `model` in
-- Assets/Models welded at `offset` from the swing start, a `color` Highlight + Vfx.FuriousFengFire from `fxAt`.
-- `spin`: rad/s the object tumbles end over end in flight (visual only).
export type Projectile = { speed: number, range: number, offset: CFrame, model: string, fxAt: number, color: Color3, spin: number }
-- Blink (Dema M2, needs a swing charge): the hitbox is a `width` x `height` lane straight ahead whose
-- length is the range at release: 0 at the press growing to `min` at startup (a tap), then to `max`
-- at full charge (CombatMath.blinkRange). At the hit the attacker teleports to the lane's end (short
-- of walls), with a wind trail on for the jump. The owner of the body teleports it (client / server).
-- stand: after the teleport the user can't walk for this long (client root lock).
export type Blink = { width: number, height: number, min: number, max: number, stand: number }
-- Close: with another living fighter within `range` studs, R throws `move` (same style) instead.
-- No `range`: R always throws `move`.
export type Close = { range: number?, move: string }
-- Fuse: pressing the move only lights it; the fighter stays free to act. Its length comes from the
-- adrenaline when lit: max at 0, min at D.ADR_MAX, linear (sent as AttackStarted's 4th arg). Then
-- the barrage starts, cutting off whatever the fighter is doing (a stun fizzles it). `sfx`
-- (Sfx/Styles/<style>) plays while lit.
-- impact: an impact frame the moment it goes off (the user + anyone within D.IMPACT_POP_RANGE).
export type Fuse = { min: number, max: number, sfx: string?, impact: boolean }
-- Barrage: state Barrage for `duration`, hitting `hits` times evenly from its start (each hit is
-- the move's damage/hitstun). `anims` cycle one per hit at `animSpeed`. Sounds (Sfx/Styles/<style>):
-- `startSfx` once at the start, `loopSfx` looped through it, `punchSfx` on every punch thrown.
export type Barrage = {
	hits: number,
	duration: number,
	anims: { string },
	animSpeed: number,
	startSfx: { string },
	loopSfx: string?,
	punchSfx: string?,
	-- Studs moved forward at constant speed over the barrage, steering freely toward the camera
	-- (the body turns with it, so the hitbox follows). 0 = stand still. Dummies go straight.
	advance: number,
	fists: number, -- visual only: clones of the attacker's arms punching out, spread over the barrage
}
-- Rush move: after startup the fighter charges at `speed` studs/s, steering toward the camera
-- at up to `turnRate` deg/s, with the hitbox live every step. The first `freeStuds` are free;
-- after that distance is bought with adrenaline (`adrPerStud`, snapshotted at attack start).
-- The first contact ends it; running
-- out of distance is a miss: `carry` seconds of easing momentum, then endlag. Damage and
-- knockback distance grow by the per-stud amounts for every stud crossed before contact.
export type Rush = {
	speed: number,
	duration: number, -- > 0: every rush takes exactly this long, so speed = distance / duration (speed unused)
	freeStuds: number, -- distance every rush gets before adrenaline starts paying
	adrPerStud: number,
	turnRate: number,
	aim: string, -- launch direction: "Camera" (default; the body turns to it), "Facing" (where the body already faces, no turn)
	-- or "Target" (at + steering toward whoever our last `unlocks` hit landed on, capped by turnRate; camera if gone)
	carry: number,
	missEndlag: number, -- endlag after the miss carry (defaults to the move's endlag); the player can't walk during it
	damagePerStud: number,
	knockbackPerStud: number,
	loopAnim: string?, -- nil: no clip of its own (the windup clip keeps holding its pose)
	missAnim: string?,
	contactAnim: string?, -- played once when the rush reaches someone (the strike), replacing the loop
}
-- Charge (needs a rush): holding the button past `startup` keeps winding up for up to `time`
-- more seconds (not sped up by adrenaline); releasing (or the time running out) launches the
-- rush. A full charge adds `studs` to the rush distance and `damage` to its hit, linearly.
-- A tap = no charge. Players send the release (AttackRelease); dummies always tap.
-- loopAnim: looped clip played once the minimum windup is over, while the charge is held.
-- swing (no rush needed; Slugger M2): releasing (or `time` running out = auto release) plays
-- swing.anim and the hit lands swing.hit later. `tiers` (ascending `at` = seconds of windup from
-- the press, incl. startup) set that hit's damage / antiHeal / guardBreak and a step-in of `step`
-- studs over swing.hit; the last tier whose `at` was reached wins. The attacker can't walk during
-- the windup. See CombatMath.chargeTier.
export type ChargeTier = { at: number, damage: number, antiHeal: number, step: number, guardBreak: boolean }
export type Charge = { time: number, studs: number, damage: number, loopAnim: string?, swing: { anim: string, hit: number }?, tiers: { ChargeTier }? }
-- direction: "Facing" (default) pushes along the attacker's facing; "Away" pushes straight
-- away from the attacker (for hitboxes that reach behind, like an all-around cylinder); "Toward" pulls
-- the victim in at the attacker (at most `distance`, stopping in front of them; Server/Knockback).
-- onBlock: blocked hits (Blocked / Strip) push too, not just landed ones.
-- up: upward launch speed (studs/s) added when the push starts (0 = flat).
-- spin: random tumble up to this many rad/s; only shows on a ragdolled victim (Shared/Ragdoll).
-- arc: the push bows up this many studs and lands at its end (a Bezier arc, DashMotor.apply); 0 = flat.
export type Knockback = { distance: number, duration: number, direction: string, onBlock: boolean, up: number, spin: number, arc: number }
-- Step-in: `at` seconds into startup (scaled by attack speed like startup) the attacker moves
-- `distance` studs along their facing over `duration`. Run by whoever owns the body.
-- `steer`: the step follows the camera every frame with no turn cap, and the body turns with it.
-- `dash`: the step carries on the dash the move was thrown from (style.dashM1): the dash's direction and
-- speed for `duration` (`distance` is only the fallback when there's no dash to follow).
export type Step = { at: number, distance: number, duration: number, steer: boolean, dash: boolean }
export type Style = {
	name: string,
	idle: string?, -- combat-mode idle animation path under Assets/Animations
	equip: string?, -- played once on entering combat mode (CombatModeController), path under Assets/Animations
	equip: string?, -- played once on entering combat mode (CombatModeController), path under Assets/Animations
	idleWhileMoving: boolean, -- idle also plays while moving/out of combat mode, layered over walk/run (Core)
	weapon: string?, -- weapon model in Assets/Weapons, jointed to its "Limb" attribute's limb, default Torso (server WeaponService)
	holster: CFrame?, -- weapon joint C0 out of combat mode, where the idle doesn't play either (client HolsterController)
	m1Chain: { string },
	comboEndDelay: number, -- M1 lockout after the last chain hit's endlag
	guardMax: number, -- guard health for fighters using this style (default D.GUARD_MAX)
	perks: { string }, -- style perks, always on (ids in Data/Perks)
	m2: string?,
	r: string?,
	-- M1 pressed DURING a dash throws this move instead of the chain (Furious Feng's dash kick); the press
	-- cuts the dash. CombatService.requestAttack / CombatController.tryAttack.
	dashM1: string?,
	dashM2: string?, -- the same for M2 (Furious Feng's KickCan); ignores the M2 cooldown, like dashM1 ignores M1 locks
	moves: { [string]: Move },
	invariantExceptions: { [string]: string },
}

local KINDS = { M1 = true, M2 = true, R = true }
local TAGS = { Unblockable = true, GuardBreak = true, NoCounter = true, ParryOnly = true, Unparryable = true, Strip = true, NoInterrupt = true, Pierce = true }

local function need(cond: boolean, msg: string)
	if not cond then
		error("[MoveSchema] " .. msg, 3)
	end
end

local function num(raw: any, key: string, id: string, fallback: number?): number
	local v = raw[key]
	if v == nil then
		v = fallback
	end
	need(typeof(v) == "number" and v >= 0, `{id}.{key} must be a non-negative number`)
	return v
end

local function resolveHitbox(id: string, hitbox: any): Hitbox
	need(type(hitbox) == "table" and typeof(hitbox.offset) == "CFrame", `{id}.hitbox needs offset: CFrame`)
	local shape = hitbox.shape or "Box"
	if shape == "Cylinder" then
		local radius = num(hitbox, "radius", id .. ".hitbox")
		local height = num(hitbox, "height", id .. ".hitbox", 5)
		need(radius > 0 and height > 0, `{id}.hitbox radius and height must be > 0`)
		return table.freeze({
			shape = shape,
			size = Vector3.new(radius * 2, height, radius * 2),
			offset = hitbox.offset,
			radius = radius,
		})
	end
	need(shape == "Box", `{id}.hitbox.shape must be Box or Cylinder`)
	need(typeof(hitbox.size) == "Vector3", `{id}.hitbox needs size: Vector3`)
	return table.freeze({ shape = shape, size = hitbox.size, offset = hitbox.offset })
end

local function optString(raw: any, key: string, id: string): string?
	need(raw[key] == nil or type(raw[key]) == "string", `{id}.{key} must be a string`)
	return raw[key]
end

local MoveSchema = {}

function MoveSchema.resolve(id: string, raw: any): Move
	need(type(raw) == "table", `{id} must be a table`)
	need(KINDS[raw.kind] == true, `{id}.kind must be M1, M2 or R`)
	need(raw.impact == nil or type(raw.impact) == "boolean", `{id}.impact must be true or false`)
	need(type(raw.anim) == "string", `{id}.anim must be a string`)
	local hitbox = resolveHitbox(id, raw.hitbox)
	local tags = {}
	for k, v in pairs(raw.tags or {}) do
		need(TAGS[k] == true, `{id}.tags.{k} is not a known tag`)
		tags[k] = v == true
	end
	if tags.GuardBreak == nil and raw.kind == "R" then
		tags.GuardBreak = true -- criticals guard break unless they opt out
	end

	local endlag = num(raw, "endlag", id)
	local damage = num(raw, "damage", id)
	local move: Move = {
		id = id,
		kind = raw.kind,
		anim = raw.anim,
		animHit = if raw.animHit ~= nil then num(raw, "animHit", id) else nil,
		startup = num(raw, "startup", id, if raw.fuse ~= nil then 1 else nil), -- fuse moves overwrite it below
		active = num(raw, "active", id, 0),
		endlag = endlag,
		-- M2s / crits never go below the universal D.M2_COOLDOWN / D.R_COOLDOWN; a longer own cooldown wins.
		cooldown = math.max(num(raw, "cooldown", id, 0), if raw.kind == "M2" then D.M2_COOLDOWN elseif raw.kind == "R" then D.R_COOLDOWN else 0),
		hitstun = num(raw, "hitstun", id, endlag + D.HITSTUN_PAD),
		blockstun = num(raw, "blockstun", id, endlag + D.BLOCKSTUN_PAD),
		damage = damage,
		guardDamage = num(raw, "guardDamage", id, damage),
		guardRegenDelay = D.GUARD_REGEN_DELAY, -- universal, every hit (user, 2026-10-10); not per move
		hitbox = hitbox,
		cost = num(raw, "cost", id, 0),
		tags = table.freeze(tags),
		swingSfx = optString(raw, "swingSfx", id),
		hitSfx = optString(raw, "hitSfx", id),
		cleanHitSfx = optString(raw, "cleanHitSfx", id),
		clashSfx = optString(raw, "clashSfx", id),
		contactSfx = optString(raw, "contactSfx", id),
		landSfx = optString(raw, "landSfx", id),
		chamberRefund = math.clamp(num(raw, "chamberRefund", id, 0), 0, 1),
		impactSfx = optString(raw, "impactSfx", id),
		impact = raw.impact == true,
		afterimage = raw.afterimage == true,
		blur = num(raw, "blur", id, 0),
		limbFx = if type(raw.limbFx) == "string" then table.freeze({ raw.limbFx :: string })
			elseif type(raw.limbFx) == "table" then table.freeze(table.clone(raw.limbFx))
			else nil,
		limbColor = if typeof(raw.limbColor) == "Color3" then raw.limbColor else nil,
		limbTime = if raw.limbTime ~= nil then num(raw, "limbTime", id) else nil,
		trail = if type(raw.trail) == "table" then table.freeze(table.clone(raw.trail)) else nil,
		fixedStartup = raw.fixedStartup == true,
		antiHeal = math.clamp(num(raw, "antiHeal", id, 0), 0, 1),
		rooted = raw.rooted == true,
		vfx = optString(raw, "vfx", id),
		grab = nil,
		countered = nil,
		maxHpDamage = math.clamp(num(raw, "maxHpDamage", id, 0), 0, 1),
		ragdoll = num(raw, "ragdoll", id, 0),
		knockback = nil,
		rush = nil,
		charge = nil,
		step = nil,
		fuse = nil,
		barrage = nil,
		cutscene = optString(raw, "cutscene", id),
		close = nil,
		dashRefresh = raw.dashRefresh == true,
		cooldownRefresh = if type(raw.cooldownRefresh) == "table"
			then table.freeze({ M2 = num(raw.cooldownRefresh, "M2", id .. ".cooldownRefresh", 0), R = num(raw.cooldownRefresh, "R", id .. ".cooldownRefresh", 0) })
			else nil,
		unlocks = nil,
		locked = raw.locked == true,
		slowZone = raw.slowZone == true,
		slamFx = raw.slamFx == true,
		landShift = optString(raw, "landShift", id),
		useShift = optString(raw, "useShift", id),
		targetShift = optString(raw, "targetShift", id),
		focusShare = num(raw, "focusShare", id, 0),
		blink = nil,
		iframes = if raw.iframes ~= nil then num(raw, "iframes", id) else nil,
		strongRagdoll = raw.strongRagdoll == true,
		ragdollLand = num(raw, "ragdollLand", id, 0),
		lead = nil,
		projectile = nil,
	}
	if raw.projectile ~= nil then
		local p = raw.projectile
		local pid = id .. ".projectile"
		need(type(p) == "table" and typeof(p.offset) == "CFrame" and type(p.model) == "string", pid .. " needs offset: CFrame and model")
		need(typeof(p.color) == "Color3", pid .. ".color must be a Color3")
		local proj: Projectile = { speed = num(p, "speed", pid), range = num(p, "range", pid), offset = p.offset, model = p.model, fxAt = num(p, "fxAt", pid, 0), color = p.color, spin = num(p, "spin", pid, 0) }
		need(proj.speed > 0 and proj.range > 0, pid .. " needs speed and range > 0")
		move.projectile = table.freeze(proj)
	end
	if raw.lead ~= nil then
		local l = raw.lead
		need(type(l) == "table" and type(l.anim) == "string", `{id}.lead needs anim + time`)
		local lead = { anim = l.anim, time = num(l, "time", id .. ".lead") }
		need(lead.time > 0 and lead.time < move.startup, `{id}.lead.time must be between 0 and startup ({move.startup})`)
		move.lead = table.freeze(lead)
	end
	if raw.unlocks ~= nil then
		local u = raw.unlocks
		need(type(u) == "table" and type(u.move) == "string", `{id}.unlocks needs move + window`)
		move.unlocks = table.freeze({ move = u.move, window = num(u, "window", id .. ".unlocks") })
	end
	if raw.close ~= nil then
		local c = raw.close
		need(type(c) == "table" and type(c.move) == "string" and raw.kind == "R", `{id}.close needs a move, on an R move`)
		move.close = table.freeze({ range = if c.range == nil then nil else num(c, "range", id .. ".close"), move = c.move })
	end
	for _, key in { move.landShift, move.useShift, move.targetShift } do
		need(D.COLOR_SHIFT[key] ~= nil, `{id}: no colour shift {key} in D.COLOR_SHIFT`)
	end
	need(move.cutscene == nil or Paths.data("Cutscenes")[move.cutscene] ~= nil, `{id}.cutscene: no cutscene {move.cutscene} in Data/Cutscenes`)
	if raw.knockback ~= nil then
		local kb = raw.knockback
		need(type(kb) == "table", id .. ".knockback must be a table with distance and duration")
		local distance = num(kb, "distance", id .. ".knockback")
		local duration = num(kb, "duration", id .. ".knockback")
		need(duration > 0, `{id}.knockback.duration must be > 0`)
		-- The server holds the victim's physics for the push, so it must end inside hitstun.
		need(duration <= move.hitstun, `{id}.knockback.duration must not exceed hitstun ({move.hitstun})`)
		local direction = kb.direction or "Facing"
		need(direction == "Facing" or direction == "Away" or direction == "Toward", `{id}.knockback.direction must be Facing, Away or Toward`)
		need(kb.onBlock == nil or type(kb.onBlock) == "boolean", `{id}.knockback.onBlock must be true or false`)
		move.knockback = table.freeze({ distance = distance, duration = duration, direction = direction, onBlock = kb.onBlock == true, up = num(kb, "up", id .. ".knockback", 0), spin = num(kb, "spin", id .. ".knockback", 0), arc = num(kb, "arc", id .. ".knockback", 0) })
	end
	if raw.rush ~= nil then
		local r = raw.rush
		local rid = id .. ".rush"
		need(type(r) == "table", rid .. " must be a table")
		local rush: Rush = {
			speed = num(r, "speed", rid, 0),
			duration = num(r, "duration", rid, 0),
			freeStuds = num(r, "freeStuds", rid, 0),
			adrPerStud = num(r, "adrPerStud", rid, 0), -- 0: adrenaline buys no distance (and isn't drained)
			turnRate = num(r, "turnRate", rid, 0),
			aim = r.aim or "Camera",
			carry = num(r, "carry", rid, 0),
			missEndlag = num(r, "missEndlag", rid, move.endlag),
			damagePerStud = num(r, "damagePerStud", rid, 0),
			knockbackPerStud = num(r, "knockbackPerStud", rid, 0),
			loopAnim = optString(r, "loopAnim", rid),
			missAnim = optString(r, "missAnim", rid),
			contactAnim = optString(r, "contactAnim", rid),
		}
		need(rush.speed > 0 or rush.duration > 0, `{rid} needs speed or duration > 0`)
		need(rush.aim == "Camera" or rush.aim == "Facing" or rush.aim == "Target", `{rid}.aim must be Camera, Facing or Target`)
		need(rush.freeStuds > 0 or rush.adrPerStud > 0, `{rid} needs freeStuds or adrPerStud`)
		move.rush = table.freeze(rush)
	end
	if raw.charge ~= nil then
		local c = raw.charge
		local cid = id .. ".charge"
		need(type(c) == "table" and (move.rush ~= nil) ~= (c.swing ~= nil), cid .. " must be a table, on a rush move or with a swing (not both)")
		local charge: Charge = { time = num(c, "time", cid), studs = num(c, "studs", cid, 0), damage = num(c, "damage", cid, 0), loopAnim = optString(c, "loopAnim", cid) }
		need(charge.time > 0, `{cid}.time must be > 0`)
		if c.swing ~= nil then
			local s = c.swing
			need(type(s) == "table" and type(s.anim) == "string", cid .. ".swing needs anim + hit")
			charge.swing = table.freeze({ anim = s.anim, hit = num(s, "hit", cid .. ".swing") })
			need(type(c.tiers) == "table" and #c.tiers > 0, cid .. ".tiers must list at least one tier")
			local tiers = {}
			for i, t in ipairs(c.tiers) do
				local tid = `{cid}.tiers[{i}]`
				local tier: ChargeTier = {
					at = num(t, "at", tid, 0),
					damage = num(t, "damage", tid, move.damage),
					antiHeal = math.clamp(num(t, "antiHeal", tid, move.antiHeal), 0, 1),
					step = num(t, "step", tid, 0),
					guardBreak = t.guardBreak == true,
				}
				need(i == 1 or tier.at >= tiers[i - 1].at, tid .. ".at must not be below the tier before it")
				tiers[i] = table.freeze(tier)
			end
			charge.tiers = table.freeze(tiers)
		end
		move.charge = table.freeze(charge)
	end
	if raw.step ~= nil then
		local st = raw.step
		local sid = id .. ".step"
		need(type(st) == "table", sid .. " must be a table with at, distance and duration")
		local step: Step = { at = num(st, "at", sid), distance = num(st, "distance", sid), duration = num(st, "duration", sid), steer = st.steer == true, dash = st.dash == true }
		need(step.duration > 0, `{sid}.duration must be > 0`)
		need(step.at < move.startup, `{sid}.at must be before the hit (startup {move.startup})`)
		move.step = table.freeze(step)
	end
	if raw.fuse ~= nil then
		local fu = raw.fuse
		local fid = id .. ".fuse"
		need(type(fu) == "table", fid .. " must be a table with min and max")
		local fuse: Fuse = { min = num(fu, "min", fid), max = num(fu, "max", fid), sfx = optString(fu, "sfx", fid), impact = fu.impact == true }
		need(fuse.min > 0 and fuse.max >= fuse.min, `{fid} needs 0 < min <= max`)
		move.fuse = table.freeze(fuse)
		move.startup = fuse.min -- placeholder; the real startup is rolled per attack
	end
	if raw.barrage ~= nil then
		local b = raw.barrage
		local bid = id .. ".barrage"
		need(type(b) == "table", bid .. " must be a table")
		need(type(b.anims) == "table" and #b.anims > 0, bid .. ".anims must list at least one animation")
		local startSfx = b.startSfx or {}
		need(type(startSfx) == "table", bid .. ".startSfx must be a list of sound names")
		local barrage: Barrage = {
			hits = num(b, "hits", bid),
			duration = num(b, "duration", bid),
			anims = table.freeze(table.clone(b.anims)),
			animSpeed = num(b, "animSpeed", bid, 1),
			startSfx = table.freeze(table.clone(startSfx)),
			loopSfx = optString(b, "loopSfx", bid),
			punchSfx = optString(b, "punchSfx", bid),
			advance = num(b, "advance", bid, 0),
			fists = num(b, "fists", bid, 0),
		}
		need(barrage.hits >= 1 and barrage.hits % 1 == 0 and barrage.duration > 0, `{bid} needs whole hits >= 1 and duration > 0`)
		need(move.rush == nil, `{id} can't be both a rush and a barrage`)
		move.barrage = table.freeze(barrage)
	end
	need(move.fuse == nil or (move.barrage ~= nil and move.kind ~= "M1"), `{id}.fuse needs a barrage and an M2/R kind`)
	if raw.grab ~= nil then
		local g = raw.grab
		local gid = id .. ".grab"
		need(type(g) == "table" and type(g.move) == "string", gid .. " needs the follow-up move id")
		move.grab = table.freeze({ move = g.move, pull = num(g, "pull", gid), hold = num(g, "hold", gid), gap = num(g, "gap", gid) })
	end
	-- Countered out of this move (a Counter landing in its startup): the victim's stun plays `clip` (an
	-- AnimationHandler stun clip, e.g. "Clash") instead of Hitstun, same length, and the push is `knockback`
	-- instead of the attacker's move's own. Taekwondo Critical (user, 2026-10-29). HitResolver.applyHit.
	if raw.countered ~= nil then
		local c = raw.countered
		local cid = id .. ".countered"
		need(type(c) == "table", cid .. " must be a table with clip and/or knockback")
		local knock = nil
		if c.knockback ~= nil then
			local kb = c.knockback
			local kid = cid .. ".knockback"
			need(type(kb) == "table", kid .. " must be a table with distance and duration")
			local direction = kb.direction or "Facing"
			need(direction == "Facing" or direction == "Away" or direction == "Toward", `{kid}.direction must be Facing, Away or Toward`)
			knock = table.freeze({ distance = num(kb, "distance", kid), duration = num(kb, "duration", kid), direction = direction, onBlock = false, up = 0, spin = 0, arc = 0 })
			need(knock.duration > 0, `{kid}.duration must be > 0`)
		end
		move.countered = table.freeze({ clip = optString(c, "clip", cid), knockback = knock })
	end
	if raw.blink ~= nil then
		local bl = raw.blink
		local bid = id .. ".blink"
		need(type(bl) == "table" and move.charge ~= nil and move.charge.swing ~= nil, bid .. " needs a table and a swing charge")
		local blink: Blink = { width = num(bl, "width", bid), height = num(bl, "height", bid, 6), min = num(bl, "min", bid), max = num(bl, "max", bid), stand = num(bl, "stand", bid, 0) }
		need(blink.width > 0 and blink.height > 0 and blink.max >= blink.min, `{bid} needs width, height > 0 and max >= min`)
		move.blink = table.freeze(blink)
	end
	need(move.ragdoll <= move.hitstun, `{id}.ragdoll must not outlast hitstun ({move.hitstun})`)
	need(move.ragdollLand == 0 or move.ragdoll > 0, `{id}.ragdollLand needs a ragdoll (its cap)`)
	need(move.startup > 0, `{id}.startup must be > 0`)
	return table.freeze(move)
end

-- Studs per second for a rush covering `studs` (a fixed-duration rush goes faster the further it goes).
function MoveSchema.rushSpeed(rush: Rush, studs: number): number
	return if rush.duration > 0 then math.max(studs, 0.01) / rush.duration else rush.speed
end

function MoveSchema.resolveStyle(raw: any): Style
	need(type(raw) == "table" and type(raw.name) == "string", "style.name must be a string")
	local moves: { [string]: Move } = {}
	for id, m in pairs(raw.moves) do
		moves[id] = MoveSchema.resolve(id, m)
	end
	need(type(raw.m1Chain) == "table" and #raw.m1Chain > 0, `{raw.name}.m1Chain must list at least one move`)
	for _, id in ipairs(raw.m1Chain) do
		need(moves[id] ~= nil and moves[id].kind == "M1", `{raw.name}.m1Chain entry {id} must be an M1 move`)
	end
	if raw.m2 ~= nil then
		need(moves[raw.m2] ~= nil and moves[raw.m2].kind == "M2", `{raw.name}.m2 must be an M2 move`)
	end
	if raw.r ~= nil then
		need(moves[raw.r] ~= nil and moves[raw.r].kind == "R", `{raw.name}.r must be an R move`)
	end
	for id, m in moves do
		need(m.grab == nil or moves[m.grab.move] ~= nil, `{raw.name}.{id}.grab: no move {m.grab and m.grab.move}`)
		need(m.close == nil or (moves[m.close.move] ~= nil and moves[m.close.move].kind == "R"), `{raw.name}.{id}.close: no R move {m.close and m.close.move}`)
	end
	need(raw.dashM1 == nil or (moves[raw.dashM1] ~= nil and moves[raw.dashM1].kind == "M1"), `{raw.name}.dashM1 must be an M1 move`)
	need(raw.dashM2 == nil or (moves[raw.dashM2] ~= nil and moves[raw.dashM2].kind == "M2"), `{raw.name}.dashM2 must be an M2 move`)
	need(raw.idle == nil or type(raw.idle) == "string", `{raw.name}.idle must be an animation path`)
	need(raw.equip == nil or type(raw.equip) == "string", `{raw.name}.equip must be an animation path`)
	need(raw.holster == nil or typeof(raw.holster) == "CFrame", `{raw.name}.holster must be a CFrame`)
	need(raw.weapon == nil or (type(raw.weapon) == "string" and Paths.Assets.Weapons:FindFirstChild(raw.weapon) ~= nil), `{raw.name}.weapon: no model {tostring(raw.weapon)} in Assets/Weapons`)
	local perks = raw.perks or {}
	need(type(perks) == "table", `{raw.name}.perks must be a list of perk ids`)
	for _, id in ipairs(perks) do
		need(type(id) == "string" and Paths.findPerk(id), `{raw.name}.perks: no perk {tostring(id)} in Data/Perks`)
		local perk = Paths.perk(id)
		-- `evolvedFrom` (e.g. Furious Feng from Feng) may also carry its base style's perks.
		need(perk.style == nil or perk.style == raw.name or perk.style == raw.evolvedFrom, `{raw.name}.perks: {id} is a {perk.style} perk`)
	end
	return table.freeze({
		name = raw.name,
		idle = raw.idle,
		equip = raw.equip,
		weapon = raw.weapon,
		idleWhileMoving = raw.idleWhileMoving == true,
		holster = raw.holster,
		m1Chain = table.freeze(table.clone(raw.m1Chain)),
		comboEndDelay = num(raw, "comboEndDelay", raw.name, D.COMBO_END_DELAY),
		guardMax = num(raw, "guardMax", raw.name, D.GUARD_MAX),
		perks = table.freeze(table.clone(perks)),
		m2 = raw.m2,
		r = raw.r,
		dashM1 = raw.dashM1,
		dashM2 = raw.dashM2,
		moves = table.freeze(moves),
		invariantExceptions = table.freeze(table.clone(raw.invariantExceptions or {})),
	})
end

local cache: { [string]: Style } = {}

function MoveSchema.style(name: string): Style
	local style = cache[name]
	if not style then
		style = MoveSchema.resolveStyle(Paths.style(name))
		cache[name] = style
	end
	return style
end

-- The style a fighter model uses (its replicated "Style" attribute), else the default style.
function MoveSchema.ofModel(model: Instance): Style
	local name = model:GetAttribute("Style")
	if typeof(name) == "string" and Paths.findStyle(name) == name then
		local ok, style = pcall(MoveSchema.style, name)
		if ok then
			return style
		end
	end
	return MoveSchema.style(D.DEFAULT_STYLE)
end

return MoveSchema
