--!strict
-- Server-authoritative combat. Owns every timer (startup, endlag, stun, block, dash) and
-- resolves hits. One Heartbeat step drives all fighters; there are no per-event task.delay
-- timers, so an old timer can never end a newer state early. Animations are visual only.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local MoveSchema = Paths.shared("MoveSchema")
local Enums = Paths.shared("Enums")
local CombatMath = Paths.shared("CombatMath")
local Hitbox = Paths.shared("Hitbox")
local Net = Paths.shared("Net")
local Signal = Paths.shared("Signal")
local DashMotor = Paths.shared("DashMotor")
local RushMotor = Paths.shared("RushMotor")
local Fighter = Paths.server("Fighter")
local Registry = Paths.server("FighterRegistry")
local HitResolver = Paths.server("HitResolver")
local GuardSystem = Paths.server("GuardSystem")
local HealthSystem = Paths.server("HealthSystem")
local AdrenalineSystem = Paths.server("AdrenalineSystem")
local FocusSystem = Paths.server("FocusSystem")
local RateLimit = Paths.server("RateLimit")
local PerkService = Paths.server("PerkService")
local LagComp = Paths.server("LagComp")
local KnockService = Paths.server("KnockService")
local CombatTag = Paths.server("CombatTag")
local FleeSystem = Paths.server("FleeSystem")
local Height = Paths.shared("Height")

local State, Result, Action = Enums.State, Enums.Result, Enums.Action

-- Drag hitbox window (D.DRAG_HITBOX). Off = 0 / 0: the hitbox fires once, at its hitbox time.
local DRAG_LEAD = if D.DRAG_HITBOX then D.DRAG_LEAD else 0
local DRAG_TAIL = if D.DRAG_HITBOX then D.DRAG_TAIL else 0

-- The server holds early inputs a little longer than the client buffers them, to absorb
-- network jitter (the client never has more than one unconfirmed attack in flight).
local QUEUE_TTL: { [string]: number } = {
	attack = D.INPUT_BUFFER + D.MAX_COMP,
	block = D.INPUT_BUFFER + D.MAX_COMP,
	dash = D.DASH_BUFFER + D.MAX_COMP,
}

local CombatService = {}

-- In-process signals for server listeners (dummy animations, tests).
CombatService.attackStarted = Signal.new() -- (fighter, move, speed)
CombatService.blockChanged = Signal.new() -- (fighter, held)
CombatService.dashStarted = Signal.new() -- (fighter, direction, distance)
CombatService.hitResult = Signal.new() -- (attacker, victim, result, position, info)
CombatService.dodged = Signal.new() -- (dodger, attacker)

local remotes: { [string]: RemoteEvent }? = nil -- stays nil in tests: no networking

local function broadcast(name: string, ...: any)
	if remotes then
		remotes[name]:FireAllClients(...)
	end
end

local function emit(a: any, v: any, result: string, pos: Vector3, info: { [string]: any })
	-- When the new states end on the server clock, so clients time them from that instead of
	-- from the packet's arrival (else a block buffered through hitstun goes out late and can't parry).
	info.ends = if v.stateEndsAt ~= math.huge then v.stateEndsAt else nil
	if result == Result.Parried or info.parried then -- (info.parried: a clumsy parry, Two Left Feet)
		info.attackerEnds = a.stateEndsAt
	end
	-- In combat (CombatTag): health damage, plus guard damage on blocked results.
	local amount = if typeof(info.damage) == "number" then info.damage else 0
	if result == Result.Blocked or result == Result.Strip or result == Result.GuardBreak then
		local move = if typeof(info.move) == "string" then a.style.moves[info.move] else nil
		amount += if move then math.min(move.guardDamage, D.COMBAT.threshold) else 0
	end
	CombatTag.exchange(a, v, amount)
	broadcast("HitResult", a.model, v.model, result, pos, info)
	CombatService.hitResult:Fire(a, v, result, pos, info)
end

-- Tells a player's client its prediction was wrong.
local function sync(f: any, reason: string)
	if remotes and f.player then
		local endsAt = if f.stateEndsAt == math.huge then -1 else f.stateEndsAt
		remotes.StateSync:FireClient(f.player, f.state, endsAt, reason)
	end
end

-- Where a fighter's hitbox goes: a player's own recent client pose (see D.POSE_*), else the
-- server's root. Second value: true when it came from the client.
function CombatService.attackOrigin(f: any, now: number): (CFrame, boolean)
	local pose = f.clientPose
	if f.player and pose and now - f.clientPoseAt <= D.POSE_MAX_AGE
		and (pose.Position - f.root.Position).Magnitude <= D.POSE_MAX_OFFSET
	then
		return pose, true
	end
	return f.root.CFrame, false
end

local function canAct(f: any, now: number): boolean
	return f.state == State.Idle and now >= f.actLockUntil
end

-- Per-kind cooldown timers: a move's `cooldown` starts when its endlag ends.
local COOLDOWN_TIMER: { [string]: string } = {
	[Action.M2] = "m2CooldownUntil",
	[Action.R] = "rCooldownUntil",
}

-- When an attack of this kind is next allowed (M1 also has the combo-end lock).
local function kindLock(f: any, kind: string): number
	if kind == Action.M1 then
		return f.m1LockUntil
	end
	local timer = COOLDOWN_TIMER[kind]
	return if timer then f[timer] else 0
end

-- Does an attack of this kind light a fuse (Firecracker Critical)?
local function lightsFuse(f: any, kind: any): boolean
	local id = if kind == Action.R then f.style.r elseif kind == Action.M2 then f.style.m2 else nil
	local move = id and f.style.moves[id]
	return move ~= nil and move.fuse ~= nil
end

local function enqueue(f: any, kind: string, arg: any, now: number, allowQueue: boolean?): (boolean, string)
	if allowQueue == false then
		return false, "busy"
	end
	-- A queued fuse isn't replaced by later inputs (bug, 2026-10-25: R pressed as the server was still
	-- finishing an M1, then the next M1 click took the queue slot and the fuse never lit).
	local q = f.queued
	if q and q.kind == "attack" and q.arg ~= arg and lightsFuse(f, q.arg) then
		return false, "busy"
	end
	f.queued = { kind = kind, arg = arg, at = now }
	return true, "queued"
end

local function release(f: any, now: number)
	f.blockHeld = false
	f.stripPending = false
	f.parryUnguard = false
	Fighter.setState(f, State.Idle, nil, now)
	-- A block that blocked a hit gets the shorter cooldown (user, 2026-10-10).
	Fighter.setTimer(f, "blockCooldownUntil", now + (if f.blockedHit then D.BLOCK_COOLDOWN_AFTER_BLOCK else D.BLOCK_COOLDOWN))
	Fighter.setTimer(f, "actLockUntil", now + D.RELEASE_ACT_DELAY)
	CombatService.blockChanged:Fire(f, false)
end

-- The server owns the chain: clients only say "M1", never which hit of the chain.
local function resolveMove(f: any, kind: string, now: number): any?
	local style = f.style
	if kind == Action.M1 then
		if now >= f.chainResetAt then
			f.chainIndex = 1
		end
		local id = style.m1Chain[f.chainIndex]
		f.chainIndex = f.chainIndex % #style.m1Chain + 1
		f.chainResetAt = math.huge
		return style.moves[id]
	elseif kind == Action.M2 then
		f.chainIndex = 1
		return if style.m2 then style.moves[style.m2] else nil
	elseif kind == Action.R then
		-- Measured as the player's screen saw it (their pose, others where they saw them), so the
		-- server picks the same Eject / Reentry the client predicted.
		-- While a `locked` R (Reentry) is unlocked, R always throws it: no close-range swap to Eject
		-- (user, 2026-10-25).
		local main = style.r and style.moves[style.r]
		if main and main.locked and Fighter.moveUsable(f, main, now) then
			return main
		end
		local origin = CombatService.attackOrigin(f, now)
		local move = CombatMath.rMove(style, f.root, origin.Position, function(model: Model): Vector3?
			local v = Registry.get(model)
			return if v then LagComp.seenAt(f, v, now).Position else nil
		end)
		-- A `locked` move (Reentry) needs a landed unlock (Eject) first.
		return if move and Fighter.moveUsable(f, move, now) then move else nil
	end
	return nil
end

-- The adrenaline an attack runs on. With the m1AdrenalineFree mod (Firecracker perk) M1s ignore
-- the meter entirely: no damage/speed bonus, no heal ratio (and payHitCost spends nothing).
local function attackAdrenaline(f: any, move: any): number
	return if move.kind == Action.M1 and f.mods.m1AdrenalineFree > 0 then 0 else f.adrenaline
end

-- Adrenaline is snapshotted when an attack starts and used for the whole attack.
local function snapshot(f: any, move: any)
	local adr = attackAdrenaline(f, move)
	f.move = move
	f.attackSeq += 1 -- one id per attack (FocusSystem.onStruck charges its Focus loss once)
	f.attackFocus = FocusSystem.ratio(f) -- Focus bonuses for this attack (FocusSystem)
	f.attackFocusFull = FocusSystem.full(f) -- Lightshow reads this at contact (HitResolver)
	f.attackDmgMult = CombatMath.damageMult(adr) * Height.ofModel(f.model).damage -- taller hits harder (D.HEIGHT)
	f.attackAdrRatio = CombatMath.ratio(adr)
	-- A banked parry bonus (Charged Return) is spent by this attack, landed or not.
	f.cooldownRefreshed = nil
	f.attackBonusDamage = f.parryBonus
	f.parryBonus = 0
	if move.cost > 0 then
		AdrenalineSystem.gain(f, -move.cost)
	end
end

local function startAttack(f: any, move: any, now: number)
	move = CombatMath.chainMove(f.style, move, f.mods.m1ChainEndlag)
	-- Focus (Astronaut): shorter endlag, and Uppercut to the Moon's quicker M2 windup (via speed).
	local focusSpeed
	move, focusSpeed = CombatMath.focusMove(move, FocusSystem.ratio(f), 1 + f.mods.m2FocusPower, f.mods.m2FocusStartup)
	move = Height.move(move, Height.of(f.model)) -- height: hitbox range, M2 cooldown (CombatController mirrors)
	local speed = (if move.fixedStartup then 1 else CombatMath.speed(attackAdrenaline(f, move))) * focusSpeed
	-- Slugger: speed bonuses turn into damage instead (+1% speed = +speedToDamage % damage).
	local speedDamage = 1
	if f.mods.speedToDamage > 0 and speed > 1 then
		speedDamage = 1 + (speed - 1) * f.mods.speedToDamage
		speed = 1
	end
	snapshot(f, move)
	f.attackDmgMult *= speedDamage
	if move.locked then
		Fighter.unlockMove(f, move.id, nil) -- spent: the next one needs a new unlock
	end
	-- Chain mods (Measured Strikes): later M1s in the chain are slower and hit harder.
	local step = CombatMath.chainStep(f.style, move)
	speed /= 1 + f.mods.m1ChainSlow * step
	f.attackDmgMult *= 1 + f.mods.m1ChainDamage * step
	-- Drunk on Bloxy Cola (tier 2+): every attack slower (BloxyService; CombatController mirrors it).
	local drunk = f.model:GetAttribute("Drunk")
	if typeof(drunk) == "number" and drunk >= 2 then
		speed *= D.BLOXY.attackSpeed
	end
	speed *= Height.ofModel(f.model).swingSpeed -- tall swings slower, short slightly faster
	f.attackSpeed = speed
	if move.rush then
		-- Free distance, plus whatever the adrenaline you have when you press it can buy.
		f.rushAdr = f.adrenaline
		f.rushBudget = move.rush.freeStuds + (if move.rush.adrPerStud > 0 then f.adrenaline / move.rush.adrPerStud else 0)
	end
	local startup = move.startup / speed
	-- Charge move with the button still held: the windup runs on, open-ended, until releaseCharge
	-- (user: hold as long as you like; the bonus caps at charge.time). A tap, or a queued press
	-- already released, launches at the minimum (startup).
	-- A swing charge (Slugger M2) auto-releases at startup + charge.time; its hit is swing.hit after release.
	local charging = move.charge ~= nil and f.chargeHeld == move.kind
	local swing = move.charge and move.charge.swing
	local duration = if swing then (if charging then startup + move.charge.time else startup) + swing.hit
		elseif charging then nil
		else startup
	Fighter.setState(f, State.Startup, duration, now)
	f.hitboxAt = f.stateEndsAt
	f.chargeMinEnd = now + startup
	f.rushCharge = 0
	f.blinkFrom = nil
	if move.iframes then
		f.moveIframesUntil = math.huge -- until the hit (fireHitbox), then move.iframes more
	end
	-- Drag hitbox for this swing (rushes have their own live hitbox; a blink hits once, from where it was released).
	f.swing = if move.rush or move.blink then nil else { move = move, hits = {} }
	if move.step and not f.player then
		-- Server-owned fighters (dummies) step here; players step themselves.
		-- ponytail: not cut short if the dummy is stunned mid-step (0.3s, harmless so far).
		local step, gen = move.step, f.gen
		task.delay(step.at / speed, function()
			if f.gen == gen and f.move == move and Fighter.alive(f) then
				DashMotor.apply(f.root, CombatMath.flat(f.root.CFrame.LookVector), step.distance, step.duration, D.DASH_MAX_FORCE)
			end
		end)
	end
	broadcast("AttackStarted", f.model, move.id, speed)
	CombatService.attackStarted:Fire(f, move, speed)
end

-- The attack button for `kind` was let go at `t`: a charging windup ends there (never before
-- its base startup), launching the rush at that moment.
function CombatService.releaseCharge(f: any, kind: string, t: number)
	if f.chargeHeld == kind then
		f.chargeHeld = nil
	end
	if f.state ~= State.Startup or not (f.move and f.move.charge and f.move.kind == kind) then
		return
	end
	local swing = f.move.charge.swing
	local endAt = math.max(f.chargeMinEnd, t) + (if swing then swing.hit else 0)
	if endAt < f.stateEndsAt then
		f.stateEndsAt = endAt
		f.hitboxAt = endAt
		f.model:SetAttribute("MStateEnds", endAt)
	end
end

function CombatService.setCombatMode(f: any, on: boolean)
	f.combatMode = on
	f.model:SetAttribute("CombatMode", on)
end

local DASH_M1_GRACE = 0.1 -- s into the dash endlag a dash M1 still counts (see requestAttack)

-- Sitting (user, 2026-10-29: no fighting styles while seated): no attacks, blocks or dashes.
-- Same inside an apartment (ApartmentService sets "InApartment"): no attacks or blocks there (2026-10-31); dashes are fine.
local function seated(f: any): boolean
	return f.humanoid.Sit or f.model:GetAttribute("InApartment") ~= nil
end

-- Was this press DURING the fighter's dash? Live: dashing now, or just into the dash endlag (DASH_M1_GRACE).
-- `pressAt` (a player's press time, clamped by compTime): the click left their client during the dash but
-- arrived a ping late; it still counts as long as nothing else happened since that dash (still in its endlag,
-- or idle straight out of it). Judging by arrival alone, a laggy dash attack became a plain M1 / M2 here
-- while the client was already playing the dash attack (bug, 2026-11-03: dash attacks "animation bugged").
local function pressedInDash(f: any, now: number, pressAt: number?): boolean
	if f.state == State.Dash or (f.state == State.DashEndlag and now - f.stateStartedAt <= DASH_M1_GRACE) then
		return true
	end
	if not pressAt or pressAt < f.dashPressAt or pressAt > f.dashPressAt + D.DASH_DURATION then
		return false
	end
	return f.state == State.DashEndlag
		or (f.state == State.Idle and f.stateStartedAt <= f.dashPressAt + D.DASH_DURATION + D.DASH_ENDLAG + DASH_M1_GRACE)
end

function CombatService.requestAttack(f: any, kind: string, now: number, allowQueue: boolean?, pressAt: number?): (boolean, string)
	if not Fighter.alive(f) then
		return false, "dead"
	end
	if not f.combatMode then
		return false, "not in combat mode"
	end
	if seated(f) then
		return false, "seated"
	end
	if kind == "M1" and f.model:GetAttribute("HoldingSoda") then
		return false, "holding a soda" -- click drinks instead (SodaService)
	end
	-- Dash M1 (Furious Feng's dash kick): a click DURING a dash throws style.dashM1 right away, cutting the
	-- dash (no queue, no chain, no combo-end lock). The click arrives a ping late, as the dash did, so the
	-- first DASH_M1_GRACE of the dash endlag still counts (jitter).
	-- Dash M2 (KickCan) the same way. No M2 cooldown gate (user, 2026-11-03: it made dash M2 unreliable next to
	-- dash M1); like the dash kick, only the chamber (Chambered Kick) limits it.
	local dashId = if kind == Action.M1 then f.style.dashM1 elseif kind == Action.M2 then f.style.dashM2 else nil
	local dashMove = if dashId and pressedInDash(f, now, pressAt) then f.style.moves[dashId] else nil
	-- Chambered Kick (Furious Feng): every dash attack needs a chambered (bonus) dash; no chamber = the plain press.
	if dashMove and f.mods.dashM1Chamber > 0 and f.bonusDashes <= 0 then
		dashMove = nil
	end
	if not dashMove and (not canAct(f, now) or now < kindLock(f, kind)) then
		return enqueue(f, "attack", kind, now, allowQueue)
	end
	local move = dashMove or resolveMove(f, kind, now)
	if not move then
		return false, "no move"
	end
	if dashMove then
		f.dashOrigin = nil -- the dash carries on as the move's step: not a dash-length outlier
		f.queued = nil
		if f.mods.dashM1Chamber > 0 and move.cost <= f.adrenaline then
			-- Chambered Kick: burn the chamber, get the normal dash back.
			Fighter.addBonusDashes(f, -1)
			Fighter.setTimer(f, "dashCooldownUntil", math.min(f.dashCooldownUntil, now))
			Fighter.proc(f, "dashM1Chamber")
		end
	end
	if move.cost > f.adrenaline then
		return false, "cost"
	end
	if move.fuse then
		-- Lit fuse: the fighter stays free (M1, block, dash...) until it goes off (see fuseTick).
		-- Its length comes from the adrenaline held right now: empty = fuse.max, full (D.ADR_MAX) = fuse.min.
		local full = math.clamp(f.adrenaline / D.ADR_MAX, 0, 1)
		local fuse = move.fuse.max - (move.fuse.max - move.fuse.min) * full
		f.fuseMove = move
		f.fuseAt = now + fuse
		-- Can't relight it meanwhile. This is the cooldown if the barrage runs its full course;
		-- endlag sets the same value, a fizzle sets a shorter one.
		Fighter.setTimer(f, COOLDOWN_TIMER[move.kind], f.fuseAt + move.barrage.duration + move.endlag + move.cooldown)
		broadcast("AttackStarted", f.model, move.id, 1, fuse)
		CombatService.attackStarted:Fire(f, move, 1)
		return true, "ok"
	end
	startAttack(f, move, now)
	return true, "ok"
end

-- Barrage hits are thrown by barrageTick while the state lasts. Server-owned fighters (dummies)
-- advance straight here; players advance (and steer) themselves.
local function startBarrage(f: any, move: any, at: number)
	local b = move.barrage
	f.barrageHits = 0
	Fighter.setState(f, State.Barrage, b.duration, at)
	if b.advance > 0 and not f.player then
		f.barrageMotor = RushMotor.start(f.root, CombatMath.flat(f.root.CFrame.LookVector), b.advance / b.duration, 0, nil, false)
	end
end

-- Cuts `share` of the R move's full cooldown off what's left (Gravity Assist; nothing if it's ready).
local function cutRCooldown(f: any, share: number, mod: string, now: number)
	local r = f.style.r and f.style.moves[f.style.r]
	if share <= 0 or not r then
		return
	end
	Fighter.proc(f, mod)
	if f.rCooldownUntil > now then
		Fighter.setTimer(f, "rCooldownUntil", math.max(now, f.rCooldownUntil - r.cooldown * share))
	end
end

-- The only states a fuse can go off in; anything else (stuns, rushes, knocked, cutscene, gripping,
-- dead...) fizzles it, the cooldown still runs. An allow-list so new states fizzle by default
-- (bug, 2026-10-24: a fuse going off while knocked replaced Knocked, stuck downed forever).
local FUSE_OK: { [string]: boolean } = {
	[State.Idle] = true,
	[State.Startup] = true,
	[State.Endlag] = true,
	[State.BlockStart] = true,
	[State.Blocking] = true,
	[State.BlockRecovery] = true,
	[State.Dash] = true,
	[State.DashEndlag] = true,
}

-- A lit fuse going off: the barrage starts right away, cutting off whatever the fighter was
-- doing (attack, block, dash), unless they're stunned, out of combat mode or dead.
local function fuseTick(f: any, now: number)
	local move = f.fuseMove
	if not move or now < f.fuseAt then
		return
	end
	f.fuseMove = nil
	local at = f.fuseAt
	if not FUSE_OK[f.state] or not f.combatMode or not Fighter.alive(f) then
		Fighter.setTimer(f, COOLDOWN_TIMER[move.kind], now + move.cooldown)
		return
	end
	if Enums.GUARDING[f.state] then
		f.blockHeld = false
		f.stripPending = false
		f.parryUnguard = false
		CombatService.blockChanged:Fire(f, false)
	end
	f.queued = nil
	f.swing = nil
	f.dashOrigin = nil
	snapshot(f, move)
	f.attackSpeed = 1
	startBarrage(f, move, math.max(at, now - 0.05))
	sync(f, "fuse") -- the owner can't predict this; it learns here
end

function CombatService.requestBlock(f: any, pressed: boolean, pressTime: number, now: number, allowQueue: boolean?): (boolean, string)
	if not Fighter.alive(f) then
		return false, "dead"
	end
	if not pressed then
		f.blockHeld = false
		if f.queued and f.queued.kind == "block" then
			f.queued = nil
		end
		-- BlockStart (a tap still plays the full animation) and BlockRecovery release when they end.
		if f.state == State.Blocking then
			release(f, now)
		end
		return true, "ok"
	end
	if f.blockHeld then
		return false, "held"
	end
	if not f.combatMode then
		return false, "not in combat mode"
	end
	if seated(f) then
		return false, "seated"
	end
	if not canAct(f, now) or now < f.blockCooldownUntil or now < f.noBlockUntil then
		return enqueue(f, "block", nil, now, allowQueue)
	end
	f.blockHeld = true
	f.freshPress = true
	f.blockPressAt = pressTime
	f.blockedHit = false
	f.model:SetAttribute("BlockPressAt", pressTime) -- clients show the weak guard from this
	f.stripPending = false
	Fighter.setState(f, State.BlockStart, D.BLOCK_START_DURATION, now)
	CombatService.blockChanged:Fire(f, true)
	return true, "ok"
end

-- `kind` is Front / Side / Back relative to the dasher's body. The client owns its movement, so
-- the server trusts the kind only to pick the distance; any kind is a legitimate choice.
function CombatService.requestDash(f: any, dir: Vector3, kind: string, pressTime: number, now: number, allowQueue: boolean?): (boolean, string)
	if not Fighter.alive(f) then
		return false, "dead"
	end
	if D.DASH_DISTANCE[kind] == nil then
		return false, "bad dash"
	end
	if f.humanoid.Sit then -- not seated(): dashing works inside apartments (user, 2026-11-01), like Club Kuro
		return false, "seated"
	end
	-- Slow zone (Slugger Critical): no back dash, shorter dashes.
	local slowed = CombatMath.inSlowZone(f.model, f.root.Position, now)
	if slowed and kind == "Back" then
		return false, "no back dash"
	end
	-- Dash-cancel: hitbox has not fired yet. A drag hitbox can already have reached someone up to
	-- DRAG_LEAD early, still in Startup; that swing has landed, so it can't be cancelled out of its endlag.
	local fromStartup = f.state == State.Startup and not (f.swing and next(f.swing.hits) ~= nil)
	local fromBlock = f.state == State.Blocking -- block -> dash is a valid escape
	local legal = fromStartup or fromBlock or canAct(f, now)
	-- The normal dash goes first; a bonus dash (perks) is only spent while it is on cooldown.
	local onCooldown = now < f.dashCooldownUntil
	local useBonus = onCooldown and f.bonusDashes > 0
	if not legal or (onCooldown and not useBonus) or now < f.dashLockUntil then
		return enqueue(f, "dash", { dir = dir, kind = kind }, now, allowQueue)
	end
	if fromBlock then
		f.blockHeld = false
		Fighter.setTimer(f, "blockCooldownUntil", now + (if f.blockedHit then D.BLOCK_COOLDOWN_AFTER_BLOCK else D.BLOCK_COOLDOWN))
		CombatService.blockChanged:Fire(f, false)
	end
	-- Dash-cancelling an M2/crit windup still puts it on cooldown (user, 2026-10-10), so it can't
	-- be feinted for free.
	local cancelTimer = if fromStartup and f.move and f.move.cooldown > 0 then COOLDOWN_TIMER[f.move.kind] else nil
	if cancelTimer then
		Fighter.setTimer(f, cancelTimer, now + f.move.cooldown)
	end
	local iframes = if fromStartup then D.DASH_CANCEL_IFRAMES else D.DASH_IFRAMES
	local heightStats = Height.ofModel(f.model)
	local distance = DashMotor.distance(kind, fromStartup, slowed) * heightStats.dashDistance
	f.move = nil
	f.dashPressAt = pressTime
	f.iframesUntil = pressTime + iframes
	f.dashOrigin = f.root.Position
	f.dashDistance = distance
	Fighter.setState(f, State.Dash, D.DASH_DURATION, now)
	-- Away from the nearest close foe / toward a far one (D.DASH_INTENT). Only fighters we're in combat
	-- with (CombatTag); the client predicts from the same list.
	local enemies = {}
	for _, other in CombatTag.foes(f) do
		if Fighter.alive(other) then
			table.insert(enemies, other.root.Position)
		end
	end
	local intent = CombatMath.dashIntent(f.root.Position, dir, enemies)
	if intent == "Away" then
		FleeSystem.dashAway(f, now) -- a chunk of the flee meter (D.FLEE)
	end
	if useBonus then
		Fighter.addBonusDashes(f, -1) -- the normal dash's cooldown keeps running untouched
	else
		-- 30% shorter at 80+ Focus (Prodigy; CombatMath.dashCooldown).
		local cooldown = CombatMath.dashCooldown(if f.mods.focus > 0 then f.focus else 0) * CombatMath.dashIntentMult(intent) * heightStats.dashCooldown
		Fighter.setTimer(f, "dashCooldownUntil", now + cooldown)
	end
	cutRCooldown(f, f.mods.dashRCooldownCut, "dashRCooldownCut", now) -- Gravity Assist (Prodigy)
	if not f.player then
		-- Server-owned fighters (dummies) are moved here; players move themselves.
		DashMotor.burst(f.root, dir, distance, D.DASH_DURATION, D.DASH_MAX_FORCE)
	end
	broadcast("DashStarted", f.model, dir, fromStartup)
	CombatService.dashStarted:Fire(f, dir, distance)
	-- Bloxy Cola (user, 2026-10-27): from tripAt sips, a dash can trip you into a ragdoll mid-dash.
	local sips = f.model:GetAttribute("BloxySips")
	if typeof(sips) == "number" and sips >= D.BLOXY.tripAt and math.random() < D.BLOXY.tripChance then
		task.defer(Paths.shared("Ragdoll").apply, f, D.BLOXY.tripRagdoll, 6)
	end
	return true, "ok"
end

-- Logged, not punished: the client moves its own character, so this only flags outliers.
local function checkDashDistance(f: any)
	local origin = f.dashOrigin
	if not origin then
		return
	end
	f.dashOrigin = nil
	local moved = ((f.root.Position - origin) * Vector3.new(1, 0, 1)).Magnitude
	local limit = f.dashDistance + f.humanoid.WalkSpeed * (D.DASH_DURATION + D.MAX_COMP) + D.DASH_DISPLACEMENT_SLACK
	if moved > limit then
		warn(string.format("[Midori] %s dashed %.1f studs (limit %.1f)", f.model.Name, moved, limit))
	end
end

local function onExpire(f: any, batch: { any })
	local s = f.state
	-- Transition at the state's scheduled end, not this frame's time. Otherwise every
	-- transition stretches by up to a frame, the server drifts behind the client's
	-- prediction over a chain, and buffered inputs start expiring (the spam-click bug).
	local now = f.stateEndsAt
	if s == State.Startup then
		table.insert(batch, f)
	elseif s == State.Endlag then
		local chain = f.style.m1Chain
		if f.move and f.move.id == chain[#chain] then
			-- Combo finished: restart the chain and lock M1 briefly (all styles).
			f.chainIndex = 1
			Fighter.setTimer(f, "m1LockUntil", now + f.style.comboEndDelay)
		end
		local cooldownTimer = if f.move and f.move.cooldown > 0 then COOLDOWN_TIMER[f.move.kind] else nil
		if cooldownTimer then
			-- A landed Eject cuts its own cooldown by its cooldownRefresh share (R = 1: none).
			local refresh = if f.cooldownRefreshed == f.move then f.move.cooldownRefresh else nil
			Fighter.setTimer(f, cooldownTimer, now + f.move.cooldown * (1 - (if refresh then refresh[f.move.kind] or 0 else 0)))
		end
		f.cooldownRefreshed = nil
		f.move = nil
		f.chainResetAt = now + D.CHAIN_RESET
		Fighter.setState(f, State.Idle, nil, now)
	elseif s == State.BlockStart or s == State.BlockRecovery then
		if f.parryUnguard then
			-- Landed parry: guard drops with no block cooldown and no act delay, so the
			-- parrier can follow up. Blocking again needs a new press (the client drops the hold).
			f.parryUnguard = false
			f.blockHeld = false
			Fighter.setState(f, State.Idle, nil, now)
		elseif f.stripPending or not f.blockHeld then
			release(f, now)
		else
			Fighter.setState(f, State.Blocking, nil, now)
		end
	elseif s == State.ParryStun and f.move then
		-- Parried: the stun, then half the parried move's endlag (cooldowns start after it as usual).
		Fighter.setState(f, State.Endlag, f.move.endlag / 2, now)
	elseif Enums.STUNS[s] then
		local ended = f.stateEndsAt
		f.move = nil
		f.chainIndex = 1
		Fighter.setState(f, State.Idle, nil, now)
		Fighter.setTimer(f, "dashLockUntil", ended + D.POST_STUN_DASH_DELAY)
		if s == State.GuardBreakStun then
			Fighter.setTimer(f, "noBlockUntil", ended + D.GUARD_BREAK_NO_BLOCK)
		end
	elseif s == State.Rush then
		-- Out of distance without connecting: the miss carry, then endlag.
		local carry = if f.move and f.move.rush then f.move.rush.carry else 0
		-- The whole budget was spent, including the part after the last step's tick.
		if f.move and f.move.rush and f.move.rush.adrPerStud > 0 then
			local r = f.move.rush
			local left = math.max(0, f.rushAdr - math.max(0, f.rushBudget - r.freeStuds) * r.adrPerStud)
			if f.adrenaline > left then
				f.adrenaline = left
				Fighter.syncMeters(f)
			end
		end
		Fighter.setState(f, State.RushMiss, carry, now)
		if f.move then
			PerkService.event(f, "onMissed", f.move, now)
		end
		if f.rushMotor then
			f.rushMotor:easeOut(carry)
		end
	elseif s == State.RushMiss then
		Fighter.setState(f, State.Endlag, if f.move and f.move.rush then f.move.rush.missEndlag else 0, now)
	elseif s == State.Barrage then
		Fighter.setState(f, State.Endlag, if f.move then f.move.endlag else 0, now)
	elseif s == State.Dash then
		checkDashDistance(f)
		Fighter.setState(f, State.DashEndlag, D.DASH_ENDLAG, now)
	elseif s == State.DashEndlag then
		Fighter.setState(f, State.Idle, nil, now)
	elseif s == State.Knocked then
		KnockService.recover(f, now) -- the knock ran out: back up
	elseif s == State.Gripping then
		KnockService.finishGrip(f, now) -- D.GRIP.at reached: they die
	elseif s == State.Cutscene then
		Fighter.setState(f, State.Idle, nil, now) -- the cutscene ran its duration (CutsceneService)
		sync(f, "cutscene")
	end
end

local function wouldHit(a: any, target: any): boolean
	return a.move ~= nil and Hitbox.contains(a.root.CFrame, a.move.hitbox, target.model)
end

-- Clash check: would `f`'s pending hit land on `target`? A move `step` (Lethwei / Gio crit) carries
-- the body forward before its hit, and a player's step reaches the server late, so count it as taken.
-- ponytail: adds the whole step even when it's half done (clash-only reach bonus); track step progress if that over-clashes.
local function wouldClash(f: any, target: any, now: number): boolean
	local s = f.move and f.move.step
	local stepEnds = if s then f.stateStartedAt + (s.at + s.duration) / f.attackSpeed + (if f.player then D.LAGCOMP_MAX else 0) else 0
	local cf = if s and now < stepEnds then f.root.CFrame * CFrame.new(0, 0, -s.distance) else f.root.CFrame
	return f.move ~= nil and Hitbox.contains(cf, f.move.hitbox, target.model)
end

-- What connecting costs the attacker in adrenaline. Parried hits are free.
local HIT_COST: { [string]: number } = {
	[Result.Hit] = D.ADR_COST_ON_HIT,
	[Result.Counter] = D.ADR_COST_ON_HIT,
	[Result.Clash] = D.ADR_COST_ON_HIT,
	[Result.Blocked] = D.ADR_COST_ON_BLOCKED,
	[Result.Strip] = D.ADR_COST_ON_BLOCKED,
	[Result.GuardBreak] = D.ADR_COST_ON_BLOCKED,
}

local function payHitCost(f: any, result: string, move: any)
	-- Perks (Firecracker) can make a move kind's hits free; the adrenaline damage bonus still applies.
	if (move.kind == Action.M1 and f.mods.m1AdrenalineFree > 0) or (move.kind == Action.R and f.mods.rAdrenalineFree > 0) then
		return
	end
	local cost = HIT_COST[result]
	if cost then
		AdrenalineSystem.gain(f, -cost)
	end
end

-- Hits on idle players waiting out their defence grace (LagComp.grace).
type Held = { a: any, v: any, move: any, t: number, at: number }
local held: { Held } = {}

-- One contact landing on `v` at time `now`: a dodge on i-frames, else HitResolver.
-- True if it connected (a whiff on i-frames doesn't count).
-- A hit that whiffs on i-frames is a successful dodge (announced once per dash).
-- `afterDash`: the hit struck a past pose of `v` that was on dash i-frames (see strike).
local function escape(a: any, v: any, now: number, afterDash: boolean?)
	-- Once per dash (keyed by its press, so a lag-compensated escape after the dash doesn't repeat it),
	-- or once per attack for attack i-frames.
	local key = if afterDash or v.state == State.Dash then v.dashPressAt else v.stateStartedAt
	if (afterDash or Fighter.inIframes(v, now)) and v.dodgedDashAt ~= key then
		v.dodgedDashAt = key
		-- Like a parry, a dodge counts as being attacked (restarts the drain delay).
		if v.mods.focus > 0 then
			-- Astronaut: dodges give no adrenaline, and no Focus either (user, 2026-10-25).
			AdrenalineSystem.markAttacked(v, now)
		else
			AdrenalineSystem.onStruck(v, D.ADR_GAIN_DODGE * (1 + v.mods.dodgeAdrenaline), now)
			if v.mods.dodgeAdrenaline ~= 0 then
				Fighter.proc(v, "dodgeAdrenaline")
			end
		end
		-- Afterburner: a dodge cuts a share of the full dash cooldown off what's left.
		if v.mods.dodgeDashRefund > 0 and v.dashCooldownUntil > now then
			Fighter.setTimer(v, "dashCooldownUntil", math.max(now, v.dashCooldownUntil - D.DASH_COOLDOWN * v.mods.dodgeDashRefund))
			Fighter.proc(v, "dodgeDashRefund")
		end
		cutRCooldown(v, v.mods.dodgeRCooldownCut, "dodgeRCooldownCut", now) -- Gravity Assist (Prodigy)
		broadcast("Dodged", v.model, a.model)
		CombatTag.exchange(a, v, 0) -- keeps an ongoing fight going
		CombatService.dodged:Fire(v, a)
	end
end

local function land(a: any, v: any, move: any, now: number, allowCounter: boolean): boolean
	escape(a, v, now)
	local result = HitResolver.resolve(a, v, move, now, emit, allowCounter)
	if result then
		payHitCost(a, result, move)
		return true
	end
	return false
end

-- A held hit lands at its own time `h.t`. A block or dash pressed by then (it arrived during
-- the grace) counts; anything pressed later doesn't. Stuns run from h.t, unless another hit
-- already stunned the victim after it (then from now, so that later stun isn't cut short).
local function resolveHeld(h: Held, now: number)
	local v = h.v
	if Registry.get(v.model) ~= v or not Fighter.alive(v) or Registry.get(h.a.model) ~= h.a or not Fighter.alive(h.a) then
		return
	end
	local t = h.t
	local rescued = (Fighter.isGuarding(v) and v.blockPressAt <= t) or Fighter.inIframes(v, t)
	local at = if not rescued and Fighter.isStunned(v) and v.stateStartedAt > t then now else t
	-- Idle at the hit, so never a counter crit (an attack started during the grace is just hit).
	land(h.a, v, h.move, at, false)
end

-- A swing charge move's hit (Slugger M2): the move with its charge tier's damage / anti-heal /
-- guard break, by how long the windup was held (press -> release). Other moves pass through.
-- ponytail: dummies always tap, so they never take a tier's step-in; add one here if a tap tier gets a step.
local tierMoves: { [any]: any } = {}
local function chargedMove(f: any, move: any): any
	local swing = move.charge and move.charge.swing
	if not swing then
		return move
	end
	local pressedAt = f.chargeMinEnd - move.startup / f.attackSpeed
	local tier = CombatMath.chargeTier(move, f.hitboxAt - swing.hit - pressedAt)
	local m = tierMoves[tier]
	if not m then
		m = table.clone(move)
		m.damage = tier.damage
		m.guardDamage = tier.damage
		m.antiHeal = tier.antiHeal
		local tags = table.clone(move.tags)
		tags.GuardBreak = tier.guardBreak
		m.tags = table.freeze(tags)
		m = table.freeze(m)
		tierMoves[tier] = m
	end
	if move.blink then
		-- The lane is as long as the range at release (CombatMath.blinkRange).
		f.blinkRange = CombatMath.blinkRange(move, f.hitboxAt - swing.hit - pressedAt, move.startup / f.attackSpeed)
		m = table.clone(m)
		m.hitbox = table.freeze(CombatMath.blinkHitbox(move, f.blinkRange))
	end
	return m
end

-- Resolves `move`'s hitbox placed at `cf` against everyone it overlaps. Returns true if it
-- connected with anyone (hit, counter, clash, block, parry...); a whiff on i-frames doesn't count.
-- `swing` (drag hitboxes) skips victims this swing already reached and may hold hits for grace.
local function strike(a: any, move: any, cf: CFrame, now: number, swing: any?): boolean
	local connected = false
	if swing then
		swing.at = now
	end
	Hitbox.draw(cf * move.hitbox.offset, move.hitbox)

	-- Players are checked against where victims were on their screen (see LagComp).
	local candidates = Registry.models(a.model)
	local targets = if a.player
		then LagComp.query(a, cf, move.hitbox, candidates, Registry.get, now)
		else Hitbox.query(cf, move.hitbox, candidates)
	local gen = a.gen
	-- Escape cylinder (detection only): a dasher on i-frames the hitbox missed bodily but came
	-- close to still escaped it. Checked where the attacker saw them, like the hit itself.
	local hitSet = {}
	for _, model in targets do
		hitSet[model] = true
	end
	local esc = D.DASH_ESCAPE_CYLINDER
	for _, model in candidates do
		local v = Registry.get(model)
		if hitSet[model] or not v or not Fighter.hittable(v) then
			continue
		end
		local dashing = v.state == State.Dash or v.state == State.DashEndlag
		if dashing and Fighter.inIframes(v, now)
			and Hitbox.touchesCylinder(cf, move.hitbox, LagComp.seenAt(a, v, now).Position, esc.radius, esc.height) then
			escape(a, v, now)
		end
	end
	for _, model in targets do
		if a.gen ~= gen or not Fighter.alive(a) then
			break -- parried / clashed / killed by an earlier target: the swing is over for everyone else
		end
		local v = Registry.get(model)
		if not v or not Fighter.hittable(v) or (swing and swing.hits[v]) then
			continue -- dead, knocked (immune: the swing goes through them), or already hit by this swing
		end
		if swing then
			swing.hits[v] = true -- once per swing, dodged or not
		end
		-- Lag comp tests where the attacker saw `v`, up to LAGCOMP_MAX ago. If that pose was on dash
		-- i-frames, it's an escape, never a hit, even though the dash has ended by now (else a dash
		-- gets caught at its start point after it's over: "extendo reach").
		local seen = now - LagComp.rewind(a, v)
		if seen >= v.dashPressAt and seen < v.iframesUntil and not Fighter.inIframes(v, now) then
			escape(a, v, now, true)
			continue
		end
		-- Clash: the victim's own hit is due within tolerance and would land on us
		-- (a drag hitbox is due DRAG_LEAD before its hitbox time).
		local due = v.hitboxAt - (if v.swing then DRAG_LEAD else 0)
		-- A NoCounter move on either side (Slugger Critical) never clashes: each hit lands on its own.
		local imminent = v.state == State.Startup and due <= now + D.CLASH_TOLERANCE
			and not move.tags.NoCounter and not (v.move and v.move.tags.NoCounter)
		-- Either side on i-frames (dash, Aerial Ace) can't be clashed: it goes through land() as a dodge.
		if imminent and wouldClash(v, a, now) and not Fighter.inIframes(a, now) and not Fighter.inIframes(v, now) then
			local vMove, vMult = chargedMove(v, v.move), v.attackDmgMult
			HitResolver.applyHit(a, v, move, a.attackDmgMult, now, Result.Clash, emit)
			payHitCost(a, Result.Clash, move)
			-- Our hitbox fired first; a victim it killed or knocked doesn't hit back.
			if Fighter.hittable(v) then
				HitResolver.applyHit(v, a, vMove, vMult, now, Result.Clash, emit)
				payHitCost(v, Result.Clash, vMove)
			end
			connected = true
		else
			-- An idle player's block / parry / dash may still be in flight: decide once it would have arrived.
			local grace = if swing and v.state == State.Idle then LagComp.grace(v) else 0
			if grace > 0 then
				table.insert(held, { a = a, v = v, move = move, t = now, at = now + grace })
				connected = true
			else
				local allowCounter = not D.COUNTER_REQUIRES_TARGETING or (v.state == State.Startup and wouldHit(v, a))
				if land(a, v, move, now, allowCounter) then
					connected = true
				end
			end
		end
	end
	return connected
end

-- A rush move's hit, scaled by how far the rush got before connecting.
local function rushScaled(move: any, studs: number, charge: number): any
	local rush = move.rush
	local m = table.clone(move)
	local bonus = rush.damagePerStud * studs + (if move.charge then move.charge.damage * charge else 0)
	m.damage = move.damage + bonus
	m.guardDamage = move.guardDamage + bonus
	if move.knockback then
		local kb = table.clone(move.knockback)
		kb.distance = move.knockback.distance + rush.knockbackPerStud * studs
		m.knockback = kb
	end
	return m
end

-- Where the rush is heading. Players steer their own rush, so the server reads the
-- direction off the root's velocity (the body may face elsewhere, e.g. shift-lock).
local function rushDirection(f: any): Vector3
	local dir = CombatMath.flat(f.root.AssemblyLinearVelocity)
	if dir == Vector3.zero then
		dir = CombatMath.flat(f.root.CFrame.LookVector)
	end
	return if dir == Vector3.zero then Vector3.new(0, 0, -1) else dir
end

-- Startup done: start charging. The rush lasts as long as its adrenaline budget allows.
local function startRush(f: any)
	local rush = f.move.rush
	local charge = f.move.charge
	if charge then
		-- How long the windup was held past its base startup, as 0..1 of a full charge.
		f.rushCharge = math.clamp((f.hitboxAt - f.chargeMinEnd) / charge.time, 0, 1)
		f.rushBudget += charge.studs * f.rushCharge
	end
	-- Players move their own rush, and that movement reaches the server late. Keep the hitbox live
	-- that much longer (ping + interpolation, capped like lag comp), or a short dash ends here before
	-- its body ever arrives at the target. Distance (and so damage) still caps at the budget.
	local tail = if f.player then math.clamp(f.player:GetNetworkPing() + D.LAGCOMP_INTERP, 0, D.LAGCOMP_MAX) else 0
	f.rushSpeed = MoveSchema.rushSpeed(rush, f.rushBudget)
	Fighter.setState(f, State.Rush, f.rushBudget / f.rushSpeed + tail, f.hitboxAt)
	if not f.player then
		-- Server-owned fighters (dummies) are moved here; players move themselves.
		f.rushMotor = RushMotor.start(f.root, rushDirection(f), f.rushSpeed, 0, nil, false)
	end
end

-- One rush step: drain adrenaline for the distance covered, then the live hitbox.
-- Distance is time-based (speed * elapsed), so it can't be inflated by the client.
local function rushTick(f: any, now: number)
	local move = f.move
	local rush = move.rush
	local studs = math.clamp((now - f.stateStartedAt) * f.rushSpeed, 0, f.rushBudget)
	if rush.adrPerStud > 0 then
		local left = math.max(0, f.rushAdr - math.max(0, studs - rush.freeStuds) * rush.adrPerStud)
		if f.adrenaline > left then
			f.adrenaline = left
			Fighter.syncMeters(f)
		end
	end
	local gen = f.gen
	-- A player's own pose faces the rush (their client turns the body with it); else read the
	-- direction off the server's root velocity.
	local origin, fromClient = CombatService.attackOrigin(f, now)
	local look = CombatMath.flat(origin.LookVector)
	local cf = if fromClient and look ~= Vector3.zero
		then CFrame.lookAlong(origin.Position, look)
		else CFrame.lookAlong(f.root.Position, rushDirection(f))
	if strike(f, rushScaled(move, studs, f.rushCharge), cf, now) and f.gen == gen then
		-- Connected (hit or blocked): the rush ends here but the momentum carries on, the same
		-- carry as a miss, through endlag. Parry / clash already moved us on (and stop dead).
		Fighter.setState(f, State.Endlag, move.endlag, now)
		if f.rushMotor then
			f.rushMotor:easeOut(rush.carry)
		end
	end
end

-- Throws every barrage hit due by `now` (hit i at (i-1) * duration/hits into the state). A parry,
-- clash or stun changes the state and ends it.
local function barrageTick(f: any, now: number)
	local move = f.move
	local b = move.barrage
	local due = math.min(b.hits, math.floor((now - f.stateStartedAt) / (b.duration / b.hits)) + 1)
	while f.barrageHits < due and f.state == State.Barrage and f.move == move and Fighter.alive(f) do
		f.barrageHits += 1
		local finisher = f.barrageHits == b.hits and f.mods.barrageFinisher > 0
		local hit = move
		if finisher then
			-- Finisher perk (Firecracker): the last punch scales with the adrenaline held right now
			-- (on top of the usual adrenaline damage bonus, like every hit)...
			hit = table.clone(move)
			hit.damage = f.mods.barrageFinisher * f.adrenaline / D.ADR_MAX
		end
		strike(f, hit, (CombatService.attackOrigin(f, now)), now)
		if finisher and f.adrenaline > 0 then
			AdrenalineSystem.gain(f, -f.adrenaline) -- ...and burns all of it, landed or not (user, 2026-10-11)
		end
	end
end

-- Thrown projectiles (move.projectile; Furious Feng's KickCan). The server owns the shot: it runs the hitbox
-- and tells every client the real path ("Shot" Fire: from / dir / launch time) and where it ended ("Shot"
-- End), so every screen draws the same flight (client KickCan). A player's shot checks victims where that
-- player saw them (LagComp, like a swing), so a can that touches someone on the thrower's screen hits.
-- Walls (anything collidable that isn't a fighter) stop it: a miss.
type Shot = { id: number, a: any, move: any, from: Vector3, dir: Vector3, at: number, dist: number, skip: { [any]: boolean } }
local shots: { Shot } = {}
local shotSeq = 0

local function shoot(a: any, move: any, now: number)
	local origin = CombatService.attackOrigin(a, now)
	local dir = CombatMath.flat(origin.LookVector)
	shotSeq += 1
	local s: Shot = {
		id = shotSeq,
		a = a,
		move = move,
		from = (origin * move.projectile.offset).Position,
		dir = if dir == Vector3.zero then Vector3.new(0, 0, -1) else dir.Unit,
		at = now,
		dist = 0,
		skip = {},
	}
	table.insert(shots, s)
	broadcast("Shot", "Fire", s.id, a.model, s.from, s.dir, s.at)
end

-- The first wall between `d0` and `d1` studs along the shot, as a distance (nil = clear).
local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude
wallParams.RespectCanCollide = true
local function wallAt(s: Shot, d0: number, d1: number): number?
	if d1 <= d0 then
		return nil
	end
	wallParams.FilterDescendantsInstances = game:GetService("CollectionService"):GetTagged("MidoriFighter")
	local hit = workspace:Raycast(s.from + s.dir * d0, s.dir * (d1 - d0), wallParams)
	return if hit then d0 + hit.Distance else nil
end

-- Moves every shot on; the first fighter it reaches is hit (or blocks it) and it's gone. Reaching its range
-- or a wall touching nobody is a miss (PerkService "onMissed"). A dodge on i-frames lets it fly through that fighter.
local function shotTick(now: number, only: { [any]: boolean }?)
	for i = #shots, 1, -1 do
		local s = shots[i]
		local a = s.a
		if only and not only[a] then
			continue
		end
		if Registry.get(a.model) ~= a or not Fighter.alive(a) then
			table.remove(shots, i) -- thrower gone: the can just drops
			broadcast("Shot", "End", s.id, s.from + s.dir * s.dist)
			continue
		end
		local p = s.move.projectile
		local dist = math.min(p.range, (now - s.at) * p.speed)
		local wall = wallAt(s, s.dist, dist)
		if wall then
			dist = wall -- nobody behind the wall can be reached
		end
		s.dist = dist
		local cf = CFrame.lookAlong(s.from + s.dir * dist, s.dir)
		local connected = false
		local candidates = Registry.models(a.model)
		local targets = if a.player
			then LagComp.query(a, cf, s.move.hitbox, candidates, Registry.get, now)
			else Hitbox.query(cf, s.move.hitbox, candidates)
		for _, model in targets do
			local v = Registry.get(model)
			if v and not s.skip[v] and Fighter.hittable(v) then
				s.skip[v] = true
				if land(a, v, s.move, now, false) then
					connected = true
					break
				end
			end
		end
		if connected or wall or dist >= p.range then
			table.remove(shots, i)
			broadcast("Shot", "End", s.id, cf.Position)
			if not connected then
				PerkService.event(a, "onMissed", s.move, now)
			end
		end
	end
end

local function fireHitbox(a: any, now: number)
	local move = a.move
	if not move then
		return
	end
	if move.rush then
		startRush(a)
		return
	end
	if move.barrage then
		startBarrage(a, move, a.hitboxAt)
		return
	end
	if move.slowZone then
		-- Slugger Critical: the slow zone drops at the hitbox, hit or not (user, 2026-10-25), on the
		-- attacker and every fighter inside its radius right now (D.SLOW_ZONE).
		local at = CombatService.attackOrigin(a, now).Position
		local Z = D.SLOW_ZONE
		for _, f in Registry.all() do
			if f == a or (Fighter.alive(f) and ((f.root.Position - at) * Vector3.new(1, 0, 1)).Magnitude <= Z.radius) then
				f.model:SetAttribute("SlowZoneAt", at)
				f.model:SetAttribute("SlowZoneEnds", a.hitboxAt + Z.duration)
			end
		end
	end
	local genBefore = a.gen
	local target = a.grabTarget
	a.grabTarget = nil
	if target and target.id == move.id then
		-- A grab's follow-up is guaranteed (user): it lands on the grabbed victim, no hitbox.
		-- A parry or i-frames (dash) still stop it (HitResolver).
		if Fighter.alive(target.v) and Registry.get(target.v.model) == target.v then
			land(a, target.v, move, now, false)
		end
	elseif move.projectile then
		shoot(a, move, now) -- its hit (or miss) comes later, from shotTick
	else
		-- A blink strikes from where it was released (its owner may already have teleported).
		local origin = a.blinkFrom or CombatService.attackOrigin(a, now)
		if not strike(a, chargedMove(a, move), origin, now, a.swing) and Fighter.alive(a) then
			PerkService.event(a, "onMissed", move, now) -- connected with nobody (Fury ends)
		end
	end
	if move.iframes then
		a.moveIframesUntil = a.hitboxAt + move.iframes
	end
	if move.blink then
		-- Players teleport themselves (CombatController); the server does it for dummies.
		if not a.player and Fighter.alive(a) then
			a.root.CFrame = CombatMath.blinkTarget(a.root, a.blinkRange or 0, { a.model })
			a.root.AssemblyLinearVelocity = Vector3.zero
		end
	end

	-- Endlag starts at the scheduled hitbox time (not this frame), unless something (parry,
	-- clash) already moved us on.
	if a.gen == genBefore then
		-- A landed grab holds the attacker in endlag until its follow-up starts (grabTick).
		local g = a.grab
		Fighter.setState(a, State.Endlag, if g and g.move == move then g.at - a.hitboxAt else move.endlag, a.hitboxAt)
	end
end

-- A landed grab's hold is over: start its follow-up move (server-started; the owner predicts it
-- from the HitResult's info.grab). Called before onExpire, since the endlag ends at the same time.
local function grabTick(f: any, now: number)
	local g = f.grab
	if not g or now < g.at then
		return
	end
	f.grab = nil
	local follow = f.style.moves[g.move.grab.move]
	if f.state ~= State.Endlag or f.move ~= g.move or not follow or not Fighter.alive(g.v) then
		sync(f, "grab") -- interrupted, or the victim died: the endlag just ends; the client predicted a follow-up
		return
	end
	startAttack(f, follow, g.at)
	f.grabTarget = { v = g.v, id = follow.id }
	sync(f, "grabFollow") -- the owner adopts it if it didn't predict it (stays rooted, plays the clip)
end

local function processQueue(f: any, now: number)
	local q = f.queued
	if not q then
		return
	end
	if now - q.at > QUEUE_TTL[q.kind] then
		f.queued = nil
		sync(f, "expired")
		return
	end
	-- Start the buffered action at the moment it became legal (clamped to now), not at
	-- whichever frame noticed it, so buffered chains keep exact data timing. An input is
	-- only queued because it wasn't legal yet, so that moment is always after the request
	-- (q.at is refreshed by repeat clicks, so it must not be used here).
	local legal = f.stateStartedAt
	if q.kind == "attack" then
		legal = math.max(legal, f.actLockUntil, kindLock(f, q.arg))
	elseif q.kind == "block" then
		legal = math.max(legal, f.actLockUntil, f.blockCooldownUntil, f.noBlockUntil)
	else
		local cooldown = if f.bonusDashes > 0 then 0 else f.dashCooldownUntil
		legal = math.max(legal, cooldown, f.dashLockUntil)
	end
	local t = math.clamp(legal, now - 0.05, now) -- back-date by a few frames at most
	local ok
	if q.kind == "attack" then
		ok = CombatService.requestAttack(f, q.arg, t, false)
	elseif q.kind == "block" then
		ok = CombatService.requestBlock(f, true, t, t, false)
	else
		ok = CombatService.requestDash(f, q.arg.dir, q.arg.kind, t, t, false)
	end
	if ok then
		f.queued = nil
	end
end

-- One simulation step. `only` limits it to a set of fighters (tests use this).
function CombatService.step(now: number, dt: number, only: { [any]: boolean }?)
	CombatTag.tick(now)
	local batch = {}
	for _, f in Registry.all() do
		if only and not only[f] then
			continue
		end
		if not Fighter.alive(f) then
			continue
		end
		LagComp.record(f, now)
		-- Slow zone: the dash cooldown regens at dashRegenMult speed. Field only (no attribute): the
		-- owner's client runs the same rule on its own prediction.
		if f.dashCooldownUntil > now and CombatMath.inSlowZone(f.model, f.root.Position, now) then
			f.dashCooldownUntil += dt * (1 - D.SLOW_ZONE.dashRegenMult)
		end
		grabTick(f, now)
		if now >= f.stateEndsAt then
			onExpire(f, batch)
		end
		processQueue(f, now)
		fuseTick(f, now)
		GuardSystem.tick(f, now, dt)
		HealthSystem.tick(f, now, dt)
		-- A rush owns the meter from windup to the end of the carry (only distance drains it).
		local rushing = f.move ~= nil and f.move.rush ~= nil and f.move.rush.adrPerStud > 0
			and (f.state == State.Startup or f.state == State.Rush or f.state == State.RushMiss)
		if not rushing then
			AdrenalineSystem.tick(f, now, dt)
		end
		FocusSystem.tick(f, now, dt)
		FleeSystem.tick(f, now, dt)
		PerkService.tick(f, now, dt)
	end
	-- Resolve every hitbox due this step in time order, so clashes see each other.
	table.sort(batch, function(x, y)
		return x.hitboxAt < y.hitboxAt
	end)
	for _, a in batch do
		if a.state == State.Startup and now >= a.hitboxAt and Fighter.alive(a) then
			fireHitbox(a, now)
		end
	end
	for _, f in Registry.all() do
		if only and not only[f] then
			continue
		end
		local carrying = f.state == State.Rush or f.state == State.RushMiss or f.state == State.Endlag
		if f.rushMotor and not carrying then
			f.rushMotor:stop() -- the rush was cut short (stunned, parried, died)
			f.rushMotor = nil
		end
		if f.state == State.Rush and f.move and f.move.rush and Fighter.alive(f) then
			rushTick(f, now)
		end
		if f.state == State.Barrage and f.move and f.move.barrage and Fighter.alive(f) then
			barrageTick(f, now)
		end
		if f.barrageMotor and f.state ~= State.Barrage then
			f.barrageMotor:stop() -- the barrage ended or was cut short
			f.barrageMotor = nil
		end
		-- Blink released: lock in where the lane starts (before the owner teleports).
		local bm = f.move
		if f.state == State.Startup and bm and bm.blink and not f.blinkFrom and now >= f.hitboxAt - bm.charge.swing.hit then
			f.blinkFrom = CombatService.attackOrigin(f, now)
		end
		-- Drag hitbox: live from DRAG_LEAD before the hitbox time to DRAG_TAIL after it.
		local sw = f.swing
		if sw and sw.at ~= now and f.move == sw.move and Fighter.alive(f)
			and now >= f.hitboxAt - DRAG_LEAD and now <= f.hitboxAt + DRAG_TAIL
		then
			strike(f, chargedMove(f, sw.move), (CombatService.attackOrigin(f, now)), now, sw)
		end
	end
	KnockService.step(now) -- drop carries that can't go on (carrier stunned / knocked, they got up...)
	-- Held hits whose grace is over, oldest first.
	local due: { Held } = {}
	for i = #held, 1, -1 do
		local h = held[i]
		if now >= h.at and (not only or only[h.v]) then
			table.insert(due, table.remove(held, i) :: Held)
		end
	end
	table.sort(due, function(x, y)
		return x.t < y.t
	end)
	for _, h in due do
		resolveHeld(h, now)
	end
	shotTick(now, only)
end

local function compTime(t: any, now: number): number
	if typeof(t) ~= "number" or t ~= t then
		return now
	end
	return math.clamp(t, now - D.MAX_COMP, now)
end

function CombatService.init()
	Net.init()
	local r: { [string]: RemoteEvent } = {}
	for name in Net.Names do
		r[name] = Net.get(name)
	end
	remotes = r

	r.Attack.OnServerEvent:Connect(function(player: Player, kind: any, clientTime: any)
		if not RateLimit.take(player, "Attack") then
			return
		end
		if typeof(kind) ~= "string" or (Action :: any)[kind] == nil then
			return
		end
		local f = Registry.getByPlayer(player)
		if not f then
			return
		end
		if KnockService.isCarrying(f) then
			sync(f, "carrying") -- hands full: no attacks
			return
		end
		f.chargeHeld = kind -- until AttackRelease (charge moves read it)
		local now = workspace:GetServerTimeNow()
		-- The press time only decides "was it during the dash" (pressedInDash); the attack itself starts now.
		local ok, reason = CombatService.requestAttack(f, kind, now, true, compTime(clientTime, now))
		if not ok then
			sync(f, reason)
		end
	end)

	r.AttackPose.OnServerEvent:Connect(function(player: Player, cf: any)
		if typeof(cf) ~= "CFrame" or not RateLimit.take(player, "AttackPose") then
			return
		end
		local p = cf.Position
		if p.X ~= p.X or p.Y ~= p.Y or p.Z ~= p.Z then
			return -- NaN
		end
		local f = Registry.getByPlayer(player)
		if f then
			f.clientPose = cf
			f.clientPoseAt = workspace:GetServerTimeNow()
		end
	end)

	-- Never rate limited, like block releases: a dropped release would leave a charge running.
	r.AttackRelease.OnServerEvent:Connect(function(player: Player, kind: any, _clientTime: any)
		if typeof(kind) ~= "string" or (Action :: any)[kind] == nil then
			return
		end
		local f = Registry.getByPlayer(player)
		if f then
			-- Launch on ARRIVAL, not the client's release time: the player moves their own dash, and
			-- its movement only reaches the server about now. Backdating (up to MAX_COMP) put the
			-- server's short live-hitbox window before the dash ever showed up here, so it never hit.
			CombatService.releaseCharge(f, kind, workspace:GetServerTimeNow())
		end
	end)

	r.Block.OnServerEvent:Connect(function(player: Player, pressed: any, t: any)
		if typeof(pressed) ~= "boolean" then
			return
		end
		-- Releases are never rate limited: dropping one would leave a block stuck on.
		if pressed and not RateLimit.take(player, "Block") then
			return
		end
		local f = Registry.getByPlayer(player)
		if not f then
			return
		end
		if pressed and KnockService.isCarrying(f) then
			sync(f, "carrying") -- hands full: no blocking (releases always go through)
			return
		end
		local now = workspace:GetServerTimeNow()
		local ok, reason = CombatService.requestBlock(f, pressed, compTime(t, now), now, true)
		if not ok and reason ~= "held" then
			sync(f, reason)
		end
	end)

	r.Dash.OnServerEvent:Connect(function(player: Player, dir: any, kind: any, t: any)
		if not RateLimit.take(player, "Dash") then
			return
		end
		if typeof(dir) ~= "Vector3" or typeof(kind) ~= "string" then
			return
		end
		local f = Registry.getByPlayer(player)
		if not f then
			return
		end
		if KnockService.isCarrying(f) then
			sync(f, "carrying") -- no dashing with someone on your shoulder
			return
		end
		local flat = CombatMath.flat(dir)
		if flat == Vector3.zero then
			flat = CombatMath.flat(f.root.CFrame.LookVector)
		end
		local now = workspace:GetServerTimeNow()
		local ok, reason = CombatService.requestDash(f, flat, kind, compTime(t, now), now, true)
		if not ok then
			sync(f, reason)
		end
	end)

	r.CombatMode.OnServerEvent:Connect(function(player: Player, on: any)
		if typeof(on) ~= "boolean" or not RateLimit.take(player, "CombatMode") then
			return
		end
		local f = Registry.getByPlayer(player)
		if f then
			CombatService.setCombatMode(f, on)
		end
	end)

	RunService.Heartbeat:Connect(function(dt)
		CombatService.step(workspace:GetServerTimeNow(), dt)
	end)
end

return CombatService
