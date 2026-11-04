--!strict
-- Per-fighter combat record (players and dummies alike) plus the transition helpers.
-- A new Fighter is created for every character, so nothing survives death.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

-- Fighters always collide with each other (design decision, 2026-10-04). Dash and knockback
-- motors also stop driving into other fighters (Shared/DashMotor), so two owners don't
-- shove each other over a contact each sees late.
local FIGHTER_TAG = "MidoriFighter"

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Enums = Paths.shared("Enums")
local D = Paths.data("Defaults")

local State = Enums.State

export type Queued = { kind: string, arg: any, at: number }

-- Generic perk stat modifiers. All start at 0 and perks add to them, so they stack.
export type Mods = {
	guardDamageTaken: number, -- flat change to guard damage this fighter takes (-1 = 1 less)
	runSpeed: number, -- run speed bonus (0.08 = +8%), mirrored as "RunSpeedMult"
	counterDamage: number, -- added to D.COUNTER_MULT on this fighter's counter hits
	clashDamage: number, -- added to D.COUNTER_MULT on this fighter's clash hits only (on top of counterDamage)
	critSelfDamage: number, -- health damage this fighter takes whenever its crit (R) lands (hit, counter, clash)
	stunnedDamage: number, -- damage bonus vs victims stunned now or within D.RECENT_STUN_WINDOW
	counterGuardRatio: number, -- landed counters also deal this fraction of their damage to guard (1 = all of it)
	counterGuardCap: number, -- ...capped at this much guard damage
	guardMax: number, -- added to the style's guardMax (Fighter.guardMax)
	dodgeAdrenaline: number, -- bonus on D.ADR_GAIN_DODGE (0.4 = +40%)
	m2RCooldownCut: number, -- each landed M2 cuts this fraction of the R move's full cooldown off what's left
	damageReduction: number, -- fraction of incoming health damage ignored (Brick Wall writes this live)
	adrenalineHeal: number, -- HP healed per landed hit, times the attack's adrenaline ratio
	adrenalineMax: number, -- added to D.ADR_MAX (Fighter.adrMax); the bonus scales past the base max
	adrenalineGain: number, -- adrenaline gains are this much bigger (0.2 = +20%); costs and drain unchanged
	parryBonusDamage: number, -- after a landed parry, the next attack deals this much more damage
	m1AdrenalineFree: number, -- > 0: M1s ignore adrenaline: no bonuses, never spend it ("M1NoAdrenaline" attribute)
	rAdrenalineFree: number, -- > 0: crit (R) hits don't spend adrenaline
	barrageFinisher: number, -- > 0: a barrage's last hit deals this x (adrenaline / D.ADR_MAX) damage
	m1ChainSlow: number, -- each M1 further into the chain is this much slower (startup + anim), additive ("M1ChainSlow" attribute)
	m1ChainDamage: number, -- each M1 further into the chain deals this much more damage, additive
	m1ChainEndlag: number, -- each M1 further into the chain has this much more endlag, additive ("M1ChainEndlag" attribute)
	-- Focus (D.FOCUS, FocusSystem; user 2026-10-23, Prodigy's perks):
	focus: number, -- > 0: this fighter has Focus; dodges give Focus instead of adrenaline ("FocusOn" attribute)
	adrFocusDrain: number, -- Focus drained per second at full adrenaline (scales with it)
	counterTaken: number, -- added to COUNTER_MULT on counters this fighter TAKES (flat)
	m2FocusGain: number, -- > 0: landed M2s gain D.FOCUS.m2Gain Focus instead of hitGain
	m2FocusPower: number, -- Focus's bonuses count this much more on M2s (1 = x2) ("M2FocusPower" = 1 + this)
	m2FocusStartup: number, -- > 0: the M2's windup eases to this many seconds at full Focus ("M2FocusStartup")
	dodgeDashRefund: number, -- a dash that dodges a hit cuts this share of the full dash cooldown off what's left
	mirage: number, -- > 0: dashes throw a mirage the other way, fainter the more Focus (client; "CosmicRay")
	focusCutscene: number, -- > 0: the critical's cutscene plays only at full Focus, spending it all
	dashRCooldownCut: number, -- every dash cuts this fraction of the R move's full cooldown off what's left
	dodgeRCooldownCut: number, -- a dash that dodges a hit cuts this much more (once per dash)
	speedToDamage: number, -- > 0: attack speed bonuses are dropped; each +1% speed is this many % more damage ("SpeedToDamage" attribute)
	weakGuard: number, -- > 0: every hit this fighter blocks counts as a weak guard (Strip)
	clumsyParry: number, -- > 0: a parry-window block still parry-stuns the attacker but is otherwise a normal (weak) block
	guardRegenDelayCut: number, -- the guard regen pause after a blocked hit is this much shorter (0.5 = half)
	hitSlow: number, -- landed hits slow the victim's walk + run by this fraction ("HitSlowMult" / "HitSlowUntil")...
	hitSlowTime: number, -- ...for this many seconds
	counterDashRefund: number, -- a landed counter / clash cuts this share of the full dash cooldown off what's left
	dashM1Chamber: number, -- > 0: every dash attack (dashM1 / dashM2) needs a bonus dash (spends it) and gives the normal dash's cooldown back
	antiHeal: number, -- added to every landed hit's anti-heal (0.2 = +20%)
	hitDashRefund: number, -- seconds every landed hit takes off the dash cooldown (and adds to a Chambered Dash's fill)
	noRegen: number, -- > 0: no passive healable regen (a kill's siphon still heals)
}

export type Fighter = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	player: Player?,
	style: any,

	combatMode: boolean, -- attacks and blocks need this; players toggle it (T), dummies always on

	state: string,
	stateStartedAt: number,
	stateEndsAt: number,
	gen: number,

	move: any?,
	attackSpeed: number,
	attackDmgMult: number,
	attackAdrRatio: number, -- adrenaline / ADR_MAX when the current attack started
	hitboxAt: number,
	chainIndex: number,
	chainResetAt: number,

	blockHeld: boolean,
	freshPress: boolean,
	blockPressAt: number,
	blockedHit: boolean, -- this block took a hit (not a strip): releasing it has no block cooldown
	stripPending: boolean,
	parryUnguard: boolean,

	blockCooldownUntil: number,
	actLockUntil: number,
	noBlockUntil: number,
	dashCooldownUntil: number,
	dashLockUntil: number,
	m1LockUntil: number,
	m2CooldownUntil: number,
	rCooldownUntil: number,
	iframesUntil: number,
	dashPressAt: number, -- client press time of the current dash (i-frames start here)
	swing: { move: any, hits: { [any]: boolean } }?, -- the live drag hitbox's swing (Startup/Endlag only)
	-- Startup i-frame window for the current attack (set by perks, e.g. Aerial Ace).
	attackIframesFrom: number,
	attackIframesUntil: number,
	moveIframesUntil: number, -- a move's own i-frames (move.iframes): math.huge until its hit, then hit + iframes; any state
	grab: { v: any, at: number, move: any }?, -- a landed grab (MoveSchema Grab): follow-up starts at `at`
	grabTarget: { v: any, id: string }?, -- the running grab follow-up lands on `v`, no hitbox
	dodgedDashAt: number, -- stateStartedAt of the dash that already announced a dodge
	dashOrigin: Vector3?,
	dashDistance: number,
	rushAdr: number, -- adrenaline when the rush move started (the rush drains from this)
	rushBudget: number, -- studs the rush can cover (rushAdr / adrPerStud)
	rushMotor: any?, -- server-run rush motor (dummies only; players move themselves)
	bonusDashes: number, -- extra dashes usable while the normal dash is on cooldown (granted by perks)
	perks: { any }, -- equipped perks (PerkService)
	mods: Mods, -- stat modifiers granted by perks (Fighter.addMods)
	parryBonus: number, -- extra damage banked by a landed parry, spent by the next attack (Charged Return)
	attackBonusDamage: number, -- flat damage added to the current attack's hits (snapshotted at attack start)
	stunEndedAt: number, -- when the fighter last left a stun state
	cooldownRefreshed: any?, -- this move landed with cooldownRefresh: its endlag skips its own cooldown
	moveUnlocks: { [string]: number }, -- `locked` move id -> usable until this time (MoveSchema unlocks), "MoveUnlock_<id>"

	guard: number,
	guardRegenPausedUntil: number,
	adrenaline: number,
	focus: number, -- 0..D.FOCUS.max, only moves with mods.focus (FocusSystem), mirrored as "Focus"
	attackFocus: number, -- Focus / max when the current attack started (its bonuses use this)
	attackFocusFull: boolean, -- Focus was full (FocusSystem.full) when the current attack started
	attackSeq: number, -- counts attacks started (snapshot); identifies "this attack"
	focusLossFrom: any, -- the attacker + attackSeq that last cost us Focus (FocusSystem.onStruck)
	focusLossSeq: number,
	mirroredFocus: number,
	lastHitTakenAt: number,
	gotUpAt: number?, -- server time the last ragdoll ended (Ragdoll.stop): D.RAGDOLL.getUpResist window
	selfDamagedAt: number, -- last self damage (Fury's burn): pauses healable regen like a hit, nothing else
	healable: number, -- missing HP that regens back (HealthSystem), mirrored as "Healable"
	siphonLeft: number, -- HP a kill's siphon still has to heal quickly
	mirroredGuard: number,
	mirroredAdrenaline: number,
	mirroredHealable: number,

	queued: Queued?,
}

-- Timers mirrored to character attributes so clients, the HUD and debugging can read them.
local MIRRORED: { [string]: string } = {
	blockCooldownUntil = "BlockCooldownUntil",
	actLockUntil = "ActLockUntil",
	noBlockUntil = "NoBlockUntil",
	dashCooldownUntil = "DashCooldownUntil",
	dashLockUntil = "DashLockUntil",
	m1LockUntil = "M1LockUntil",
	m2CooldownUntil = "M2CooldownUntil",
	rCooldownUntil = "RCooldownUntil",
}

local Fighter = {}

function Fighter.new(model: Model, humanoid: Humanoid, root: BasePart, player: Player?, style: any, now: number): Fighter
	local f: Fighter = {
		model = model,
		humanoid = humanoid,
		root = root,
		player = player,
		style = style,

		combatMode = player == nil,

		state = State.Idle,
		stateStartedAt = now,
		stateEndsAt = math.huge,
		gen = 0,

		move = nil,
		attackSpeed = 1,
		attackDmgMult = 1,
		attackAdrRatio = 0,
		hitboxAt = math.huge,
		chainIndex = 1,
		chainResetAt = 0,

		blockHeld = false,
		freshPress = false,
		blockPressAt = 0,
		blockedHit = false,
		stripPending = false,
		parryUnguard = false,

		blockCooldownUntil = 0,
		actLockUntil = 0,
		noBlockUntil = 0,
		dashCooldownUntil = 0,
		dashLockUntil = 0,
		m1LockUntil = 0,
		m2CooldownUntil = 0,
		rCooldownUntil = 0,
		iframesUntil = 0,
		dashPressAt = 0,
		swing = nil,
		attackIframesFrom = 0,
		attackIframesUntil = 0,
		moveIframesUntil = 0,
		grab = nil,
		grabTarget = nil,
		dodgedDashAt = -1,
		dashOrigin = nil,
		dashDistance = 0,
		rushAdr = 0,
		rushBudget = 0,
		rushMotor = nil,
		bonusDashes = 0,
		perks = {},
		mods = { guardDamageTaken = 0, runSpeed = 0, counterDamage = 0, clashDamage = 0, critSelfDamage = 0, stunnedDamage = 0, counterGuardRatio = 0, counterGuardCap = 0, guardMax = 0,
			dodgeAdrenaline = 0, m2RCooldownCut = 0, damageReduction = 0, adrenalineHeal = 0,
			adrenalineMax = 0, adrenalineGain = 0, parryBonusDamage = 0,
			m1AdrenalineFree = 0, rAdrenalineFree = 0, barrageFinisher = 0, m1ChainSlow = 0, m1ChainDamage = 0, m1ChainEndlag = 0,
			focus = 0, adrFocusDrain = 0, counterTaken = 0, m2FocusGain = 0, m2FocusPower = 0, m2FocusStartup = 0,
			dodgeDashRefund = 0, mirage = 0, focusCutscene = 0,
			dashRCooldownCut = 0, dodgeRCooldownCut = 0, speedToDamage = 0,
			weakGuard = 0, clumsyParry = 0, guardRegenDelayCut = 0, hitSlow = 0, hitSlowTime = 0, counterDashRefund = 0, dashM1Chamber = 0,
			antiHeal = 0, hitDashRefund = 0, noRegen = 0 },
		parryBonus = 0,
		attackBonusDamage = 0,
		stunEndedAt = -math.huge,
		cooldownRefreshed = nil,
		moveUnlocks = {},

		guard = style.guardMax,
		guardRegenPausedUntil = 0,
		adrenaline = 0,
		focus = 0,
		attackFocus = 0,
		attackFocusFull = false,
		attackSeq = 0,
		focusLossFrom = nil,
		focusLossSeq = 0,
		mirroredFocus = -1,
		lastHitTakenAt = 0,
		selfDamagedAt = -math.huge,
		healable = 0,
		siphonLeft = 0,
		mirroredGuard = -1,
		mirroredAdrenaline = -1,
		mirroredHealable = -1,

		queued = nil,
	}
	CollectionService:AddTag(model, FIGHTER_TAG) -- clients find fighters for the shield VFX
	CollectionService:AddTag(model, "RockModuleIgnore") -- Lib/RockModule's ground rays go through fighters (dummies too)
	Paths.shared("Ragdoll").characterGroup(model) -- ragdolls / carried bodies never collide with characters
	Paths.shared("Ragdoll").rig(model) -- the ragdoll's sockets + colliders, off until ragdolled
	humanoid.BreakJointsOnDeath = false -- every death is a limp ragdoll corpse (FighterRegistry: Ragdoll.corpse)
	model:SetAttribute("Style", style.name) -- other clients animate this fighter with it
	model:SetAttribute("CombatMode", f.combatMode)
	model:SetAttribute("GuardMax", style.guardMax)
	model:SetAttribute("AdrenalineMax", D.ADR_MAX)
	model:SetAttribute("FocusMax", D.FOCUS.max)
	model:SetAttribute("BonusDashes", 0)
	model:SetAttribute("RunSpeedMult", 1)
	for _, attr in MIRRORED do
		model:SetAttribute(attr, 0)
	end
	Fighter.setState(f, State.Idle, nil, now)
	Fighter.syncMeters(f, true)
	return f
end

-- Every transition goes through here; `gen` lets callers detect that state moved on.
function Fighter.setState(f: Fighter, state: string, duration: number?, now: number)
	if Enums.STUNS[f.state] and not Enums.STUNS[state] then
		f.stunEndedAt = now
	end
	if state ~= State.Startup and state ~= State.Endlag then
		f.swing = nil -- stunned, parried, dashed out...: the drag hitbox is gone
	end
	f.state = state
	f.stateStartedAt = now
	f.stateEndsAt = if duration then now + duration else math.huge
	f.gen += 1
	f.model:SetAttribute("MState", state)
	f.model:SetAttribute("MStateEnds", if duration then f.stateEndsAt else -1)
	f.model:SetAttribute("Cutscene", if state == State.Cutscene then true else nil) -- shift lock hands off the body
end

function Fighter.setTimer(f: Fighter, field: string, value: number)
	(f :: any)[field] = value
	local attr = MIRRORED[field]
	if attr then
		f.model:SetAttribute(attr, value)
	end
end

-- A `locked` move is usable until time `untilT` (nil = locked again). Mirrored for the client.
function Fighter.unlockMove(f: Fighter, id: string, untilT: number?)
	f.moveUnlocks[id] = untilT
	f.model:SetAttribute("MoveUnlock_" .. id, untilT)
end

function Fighter.moveUsable(f: Fighter, move: any, now: number): boolean
	local untilT = f.moveUnlocks[move.id]
	return not move.locked or (untilT ~= nil and now <= untilT)
end

-- Adds (sign 1) or removes (sign -1) a perk's mods, e.g. { runSpeed = 0.08 }.
function Fighter.addMods(f: Fighter, mods: { [string]: number }, sign: number)
	for key, value in mods do
		local current = (f.mods :: any)[key]
		assert(current ~= nil, `unknown perk mod {key}`)
		;(f.mods :: any)[key] = current + value * sign
	end
	f.model:SetAttribute("RunSpeedMult", 1 + f.mods.runSpeed)
	f.model:SetAttribute("M1NoAdrenaline", f.mods.m1AdrenalineFree > 0) -- the client times M1 startup without the speed bonus
	f.model:SetAttribute("M1ChainSlow", f.mods.m1ChainSlow) -- the client slows later chain M1s the same way
	f.model:SetAttribute("M1ChainEndlag", f.mods.m1ChainEndlag)
	f.model:SetAttribute("SpeedToDamage", f.mods.speedToDamage > 0) -- the client times startups without speed bonuses
	-- Focus: the client predicts its own endlag / M2 windup from these, the HUD shows the bar while on.
	f.model:SetAttribute("FocusOn", f.mods.focus > 0)
	f.model:SetAttribute("M2FocusPower", 1 + f.mods.m2FocusPower)
	f.model:SetAttribute("M2FocusStartup", f.mods.m2FocusStartup)
	f.model:SetAttribute("CosmicRay", f.mods.mirage > 0)
	if mods.focus and f.mods.focus <= 0 then
		f.focus = 0 -- lost the meter (style swap): it empties
		Fighter.syncMeters(f, true)
	end
	if mods.adrenalineMax then
		f.adrenaline = math.min(f.adrenaline, Fighter.adrMax(f)) -- losing max clamps
		f.model:SetAttribute("AdrenalineMax", Fighter.adrMax(f))
		Fighter.syncMeters(f, true)
	end
	if mods.guardMax then
		-- Gaining max guard fills the new space; losing it just clamps.
		local max = Fighter.guardMax(f)
		f.guard = math.min(if sign > 0 then f.guard + mods.guardMax else f.guard, max)
		f.model:SetAttribute("GuardMax", max)
		Fighter.syncMeters(f, true)
	end
end

-- A perk mod (key = a Mods field, or a perk's `proc` key) just changed an outcome: tell the player's
-- HUD so the trait card that grants it lights up. Server code stays perk-agnostic; the client maps key -> trait.
function Fighter.proc(f: Fighter, key: string)
	if typeof(f.player) == "Instance" then
		Paths.shared("Net").get("TraitProc"):FireClient(f.player :: Player, key)
	end
end

-- Max adrenaline: the base plus perk bonuses.
function Fighter.adrMax(f: Fighter): number
	return D.ADR_MAX + f.mods.adrenalineMax
end

-- Max guard: the style's plus perk bonuses.
function Fighter.guardMax(f: Fighter): number
	return f.style.guardMax + f.mods.guardMax
end

-- Stunned now, in attack endlag (user, 2026-10-10), or left a stun within D.RECENT_STUN_WINDOW.
function Fighter.recentlyStunned(f: Fighter, now: number): boolean
	return Enums.STUNS[f.state] == true or f.state == Enums.State.Endlag or now - f.stunEndedAt <= D.RECENT_STUN_WINDOW
end

-- Bonus dash charges (mirrored so the client can predict spending one).
function Fighter.addBonusDashes(f: Fighter, delta: number)
	f.bonusDashes = math.max(0, f.bonusDashes + delta)
	f.model:SetAttribute("BonusDashes", f.bonusDashes)
end

-- Meters change every frame while regenerating/draining; only replicate meaningful changes.
function Fighter.syncMeters(f: Fighter, force: boolean?)
	if force or math.abs(f.guard - f.mirroredGuard) >= 0.1 or (f.guard >= Fighter.guardMax(f) and f.mirroredGuard < Fighter.guardMax(f)) then
		f.mirroredGuard = f.guard
		f.model:SetAttribute("Guard", math.round(f.guard * 10) / 10)
	end
	if force or math.abs(f.adrenaline - f.mirroredAdrenaline) >= 1 or (f.adrenaline <= 0 and f.mirroredAdrenaline > 0) then
		f.mirroredAdrenaline = f.adrenaline
		f.model:SetAttribute("Adrenaline", math.round(f.adrenaline))
	end
	if force or math.abs(f.focus - f.mirroredFocus) >= 1 or (f.focus <= 0 and f.mirroredFocus > 0) or (f.focus >= D.FOCUS.max and f.mirroredFocus < D.FOCUS.max) then
		f.mirroredFocus = f.focus
		f.model:SetAttribute("Focus", math.round(f.focus * 10) / 10)
	end
	if force or math.abs(f.healable - f.mirroredHealable) >= 0.5 or (f.healable <= 0 and f.mirroredHealable > 0) then
		f.mirroredHealable = f.healable
		f.model:SetAttribute("Healable", math.round(f.healable * 10) / 10)
	end
end

function Fighter.alive(f: Fighter): boolean
	return f.state ~= State.Dead and f.humanoid.Health > 0 and f.model.Parent ~= nil
end

-- Can be hit: alive and not knocked (a knocked fighter is immune until it gets up; user, 2026-10-18)
-- or in a cutscene (user, 2026-10-22).
function Fighter.hittable(f: Fighter): boolean
	return Fighter.alive(f) and f.state ~= State.Knocked and f.state ~= State.Cutscene
end

-- Style swaps, rerolls and trait spins wait until the fighter is out of combat mode, Idle, and
-- hasn't been attacked for D.LOADOUT_COMBAT_LOCK (else T + swap would refill guard mid-fight).
function Fighter.loadoutLocked(f: Fighter, now: number): boolean
	return f.combatMode or f.state ~= State.Idle or now - f.lastHitTakenAt < D.LOADOUT_COMBAT_LOCK
end

function Fighter.isStunned(f: Fighter): boolean
	return Enums.STUNS[f.state] == true
end

function Fighter.isGuarding(f: Fighter): boolean
	return Enums.GUARDING[f.state] == true
end

function Fighter.inIframes(f: Fighter, now: number): boolean
	return (f.state == State.Dash and now >= f.dashPressAt and now < f.iframesUntil)
		-- Attack i-frames (perks) can run past the hit into the same attack's endlag.
		or ((f.state == State.Startup or f.state == State.Endlag) and now >= f.attackIframesFrom and now < f.attackIframesUntil)
		-- A move's own (move.iframes, Dema M2): open-ended only while that move is still winding up, so a
		-- cancelled windup can't keep them; after its hit they run their set time in any state.
		or (now < f.moveIframesUntil and (f.moveIframesUntil < math.huge or (f.state == State.Startup and f.move ~= nil and f.move.iframes ~= nil)))
end

return Fighter
