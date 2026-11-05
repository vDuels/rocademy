--!strict
-- Decides what one hitbox contact does to one victim, in spec order:
--   miss (dead / i-frames) -> counter crit -> guard (parry / break / strip / block) -> hit
-- Clashes are detected by CombatService before calling in here.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Enums = Paths.shared("Enums")
local CombatMath = Paths.shared("CombatMath")
local Fighter = Paths.server("Fighter")
local GuardSystem = Paths.server("GuardSystem")
local HealthSystem = Paths.server("HealthSystem")
local AdrenalineSystem = Paths.server("AdrenalineSystem")
local FocusSystem = Paths.server("FocusSystem")
local Knockback = Paths.server("Knockback")
local PerkService = Paths.server("PerkService")
local Ragdoll = Paths.shared("Ragdoll")
local Height = Paths.shared("Height")

local State, Result = Enums.State, Enums.Result
local COOLDOWN_TIMER = { M2 = "m2CooldownUntil", R = "rCooldownUntil" }
-- Mid-attack states a NoInterrupt move leaves alone (MoveSchema Tags).
local INTERRUPTIBLE = { [State.Startup] = true, [State.Rush] = true, [State.Barrage] = true }

export type Emit = (attacker: any, victim: any, result: string, pos: Vector3, info: { [string]: any }) -> ()

local HitResolver = {}

local function hitPos(a: any, v: any): Vector3
	local from = v.root.Position
	local d = a.root.Position - from
	if d.Magnitude < 1e-3 then
		return from
	end
	return from + d.Unit * math.min(1, d.Magnitude * 0.5)
end

-- move.ragdollLand (Furious Feng's dash kick): once the launched body is back on the ground, the ragdoll ends
-- `after` seconds later and this hit's hitstun with it; the move's ragdoll / hitstun are only the caps.
-- Watches the body the server sees (a player's limp body replicates from their client). Gives up if
-- anything else takes over first: a newer ragdoll, a knock, another stun (v.gen moves on every state).
local LAND_MIN_AIR = 0.15 -- s before a landing can count (the launch starts on the floor)
local LAND_RAY = 3.5 -- studs under the torso that count as ground
local function getUpOnLanding(v: any, after: number)
	local model = v.model
	local seed = model:GetAttribute("Ragdolled")
	local gen = v.gen -- this hit's hitstun
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = game:GetService("CollectionService"):GetTagged("MidoriFighter")
	params.RespectCanCollide = true
	task.spawn(function()
		task.wait(LAND_MIN_AIR)
		while model.Parent and model:GetAttribute("Ragdolled") == seed and v.gen == gen do
			local torso = model:FindFirstChild("Torso") :: BasePart?
			if torso and torso.AssemblyLinearVelocity.Y <= 1 and workspace:Raycast(torso.Position, Vector3.new(0, -LAND_RAY, 0), params) then
				Ragdoll.hold(v, after) -- limp `after` more, then up
				task.delay(after, function()
					if v.gen == gen and v.state == State.Hitstun then
						local now = workspace:GetServerTimeNow()
						v.stateEndsAt = now -- the stun ends as they stand (CombatService expires it to Idle)
						model:SetAttribute("MStateEnds", now)
					end
				end)
				return
			end
			game:GetService("RunService").Heartbeat:Wait()
		end
	end)
end

-- A clean hit: health damage, hitstun, cancels whatever the victim was doing.
function HitResolver.applyHit(a: any, v: any, move: any, dmgMult: number, now: number, result: string, emit: Emit)
	if not Fighter.hittable(v) then
		return -- knocked (immune until it gets up) or dead: every hit path ends here
	end
	-- Hit while sitting (SeatService) = knocked out of the seat (user, 2026-10-31). Seated players can't block,
	-- so every hit on them comes through here. Breaking the seat's weld is what actually frees them.
	if v.humanoid.Sit then
		local seat = v.humanoid.SeatPart
		local weld = seat and seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		v.humanoid.Sit = false
	end
	local counter = result == Result.Counter or result == Result.Clash
	-- Guard break and perfect-blocked stuns are never overridden by hitstun (user, 2026-10-10):
	-- the hit still deals damage, but the victim keeps the stun (and what follows it) unchanged.
	-- NoInterrupt moves (Slugger Critical) do the same to a victim mid-attack: damage, their move runs on.
	local spared = move.tags.NoInterrupt == true and INTERRUPTIBLE[v.state] == true
	local held = v.state == State.GuardBreakStun or v.state == State.ParryStun or spared
	-- A move's cutscene (-> CutsceneService) needs Lightshow (mods.focusCutscene) and full Focus, which it
	-- spends, on a clean hit. The cutscene deals the damage, so this hit deals none and doesn't push
	-- (user, 2026-10-23: the critical's cutscene only via Lightshow).
	local cutscene = move.cutscene ~= nil and not held and (result == Result.Hit or result == Result.Counter)
		-- Full when the attack STARTED (snapshot), with FocusSystem.full's 1-point slack: Spacesuit drains
		-- Focus whenever you hold adrenaline, so an exact-max check almost never passed live (bug, 2026-10-24).
		and a.mods.focusCutscene > 0 and a.attackFocusFull
	-- Perk mods. Checked before this hit's own hitstun lands, so the first hit of a combo isn't "on a stunned target".
	if a.mods.stunnedDamage ~= 0 and Fighter.recentlyStunned(v, now) then
		dmgMult *= 1 + a.mods.stunnedDamage
		Fighter.proc(a, "stunnedDamage")
	end
	-- Counter multiplier extras: perks, Focus (the attacker's), Spacesuit (the victim's adrenaline).
	local counterBonus = a.mods.counterDamage + (if result == Result.Clash then a.mods.clashDamage else 0)
		+ FocusSystem.counterDamage(a, move) + FocusSystem.counterTaken(v)
	-- attackBonusDamage (Charged Return) is flat, added after the multipliers.
	local damage = if cutscene then 0
		elseif move.maxHpDamage > 0 then v.humanoid.MaxHealth * move.maxHpDamage -- an exact share of max HP (user): no multipliers
		else (CombatMath.damage(FocusSystem.baseDamage(a, move), dmgMult, counter, counterBonus) + a.attackBonusDamage) * (1 - v.mods.damageReduction)
	-- Focus adds anti-heal to every attack (doubled on M2s with Uppercut to the Moon).
	-- Height (D.HEIGHT): taller attackers apply more anti-heal, shorter less.
	local antiHeal = math.min(1, (move.antiHeal + a.mods.antiHeal + FocusSystem.antiHeal(a, move)) * Height.ofModel(a.model).antiHeal)
	local knocked = HealthSystem.damage(a, v, damage, antiHeal) -- lethal: knocked once this hit is done
	-- Drunk on Bloxy Cola (tier 2+): any hit knocks you out, for longer (BloxyService; user, 2026-10-27).
	local knockFor: number? = nil
	if not knocked and Fighter.alive(v) then
		knockFor = Paths.server("BloxyService").hitKnock(v)
		knocked = knockFor ~= nil
	end
	if cutscene then
		FocusSystem.empty(a) -- Lightshow spends it all
		-- Spent: anyone else this same hitbox reaches gets a normal hit (they used to pass the attack-start
		-- snapshot too, take no damage, and have their cutscene refused: the attacker was already in one).
		a.attackFocusFull = false
		Fighter.proc(a, "focusCutscene")
	else
		FocusSystem.onLanded(a, move, counter)
	end
	FocusSystem.onStruck(v, a, move, counter) -- flat Focus loss by move kind (user, 2026-10-24)
	if move.maxHpDamage <= 0 then
		if counter and a.mods.counterDamage ~= 0 then
			Fighter.proc(a, "counterDamage")
		end
		if result == Result.Clash and a.mods.clashDamage ~= 0 then
			Fighter.proc(a, "clashDamage")
		end
		if a.attackBonusDamage > 0 then
			Fighter.proc(a, "parryBonusDamage")
		end
		if v.mods.damageReduction > 0 then
			Fighter.proc(v, "damageReduction")
		end
	end
	if move.kind == "R" and a.mods.critSelfDamage > 0 then
		-- Mutually Assured Destruction: landing a crit hurts you too. True damage: straight off Health,
		-- so none of it becomes healable and the existing healable pool is left alone. Never kills: floors at 1 HP.
		a.humanoid.Health = math.max(math.min(1, a.humanoid.Health), a.humanoid.Health - a.mods.critSelfDamage)
		Fighter.proc(a, "critSelfDamage")
	end
	if a.mods.adrenalineHeal > 0 and a.attackAdrRatio > 0 and a.humanoid.Health > 0 then
		HealthSystem.heal(a, a.mods.adrenalineHeal * a.attackAdrRatio) -- heals only refill healable HP (user)
		Fighter.proc(a, "adrenalineHeal")
	end
	-- Fury: landed hits take its refund off the dash cooldown. Before onLanded, so the hit that lights it doesn't refund.
	if a.mods.hitDashRefund > 0 and a.dashCooldownUntil > now then
		Fighter.setTimer(a, "dashCooldownUntil", math.max(now, a.dashCooldownUntil - a.mods.hitDashRefund))
	end
	PerkService.event(v, "onDamaged", damage, now) -- after the hit, so a stack never reduces the hit that made it
	PerkService.event(a, "onLanded", move, now) -- the attacker's landed hit (Hit / Counter / Clash)
	-- Landing an M2 (hit, counter or clash) cuts a fraction of the crit's full cooldown off what's left.
	local r = a.style.r and a.style.moves[a.style.r]
	if move.kind == "M2" and r and a.mods.m2RCooldownCut > 0 then
		Fighter.proc(a, "m2RCooldownCut") -- every landed M2 lights the card, even with the crit already ready (user)
		if a.rCooldownUntil > now then
			Fighter.setTimer(a, "rCooldownUntil", math.max(now, a.rCooldownUntil - r.cooldown * a.mods.m2RCooldownCut))
		end
	end
	-- Landed hits slow the victim's walk + run (Microgravity, Prodigy). RunController reads the attributes.
	if a.mods.hitSlow > 0 then
		v.model:SetAttribute("HitSlowMult", 1 - a.mods.hitSlow)
		v.model:SetAttribute("HitSlowUntil", now + a.mods.hitSlowTime)
		Fighter.proc(a, "hitSlow")
	end
	-- A landed counter (or clash) cuts a share of the FULL dash cooldown off what's left (Reflex Step, Taekwondo).
	if counter and a.mods.counterDashRefund > 0 and a.dashCooldownUntil > now then
		Fighter.setTimer(a, "dashCooldownUntil", math.max(now, a.dashCooldownUntil - D.DASH_COOLDOWN * a.mods.counterDashRefund))
		Fighter.proc(a, "counterDashRefund")
	end
	if move.dashRefresh and a.dashCooldownUntil > now then
		Fighter.setTimer(a, "dashCooldownUntil", now) -- Prodigy Eject / Reentry: landing it gives the dash back
	end
	local refresh = move.cooldownRefresh
	if refresh then
		-- Prodigy Eject: landing it cuts these shares of the M2 / R full cooldowns off what's left;
		-- its own cooldown is cut by its share at endlag end (CombatService).
		local m2 = a.style.m2 and a.style.moves[a.style.m2]
		if m2 and refresh.M2 > 0 then
			Fighter.setTimer(a, "m2CooldownUntil", math.max(now, a.m2CooldownUntil - m2.cooldown * refresh.M2))
		end
		if r and refresh.R > 0 then
			Fighter.setTimer(a, "rCooldownUntil", math.max(now, a.rCooldownUntil - r.cooldown * refresh.R))
		end
		a.cooldownRefreshed = move
	end
	if move.unlocks then
		Fighter.unlockMove(a, move.unlocks.move, now + move.unlocks.window) -- a landed Eject opens Reentry for 2s
	end
	if counter and a.mods.counterGuardRatio > 0 then
		GuardSystem.damage(v, math.min(damage * a.mods.counterGuardRatio, a.mods.counterGuardCap), move.guardRegenDelay, now)
		Fighter.proc(a, "counterGuardRatio")
	end
	-- A countered (or clashed) M2/crit still goes on cooldown (user, 2026-10-10): its endlag
	-- never runs, which is where the cooldown normally starts.
	local cancelled = if counter and v.move and v.move.cooldown > 0 then COOLDOWN_TIMER[v.move.kind] else nil
	if cancelled then
		Fighter.setTimer(v, cancelled, now + v.move.cooldown)
	end
	v.blockHeld = false
	v.freshPress = false
	v.stripPending = false
	v.parryUnguard = false
	-- Grab (MoveSchema Grab): the swing's first clean hit holds the victim for pull + hold, then
	-- CombatService.grabTick starts the follow-up. The attacker waits in endlag with i-frames.
	local g = move.grab
	local grabbing = g ~= nil and not held and a.grab == nil and a.move == move
		and (result == Result.Hit or result == Result.Counter)
	if grabbing then
		local at = now + g.pull + g.hold
		a.grab = { v = v, at = at, move = move }
		a.attackIframesFrom = math.min(a.attackIframesFrom, now)
		a.attackIframesUntil = math.max(a.attackIframesUntil, at)
		if a.state == State.Endlag then
			-- A held (grace) hit lands after the endlag began: stretch it to the follow-up.
			a.stateEndsAt = at
			a.model:SetAttribute("MStateEnds", at)
		end
	end
	-- Countered out of a move that says how (MoveSchema `countered`, Taekwondo Critical): its own stun clip
	-- and push, same stun length. Read before the hitstun replaces the victim's state.
	local outOf = if result == Result.Counter and not held and v.state == State.Startup and v.move then v.move.countered else nil
	-- Already at max adrenaline (user, 2026-10-30): the next clean hit guard-break-stuns instead of hitstun
	-- (a grab keeps its own hold; the guard meter itself isn't touched). Read before this hit's gain.
	local maxed = not held and not grabbing and v.adrenaline >= Fighter.adrMax(v)
	local stun
	if held then
		local left = v.stateEndsAt - now
		stun = if left < math.huge then math.max(0, left) else 0 -- a held charge windup has no end yet
	elseif maxed then
		v.queued = nil
		stun = D.GUARD_BREAK_STUN
		Fighter.setState(v, State.GuardBreakStun, stun, now)
	else
		v.queued = nil
		-- A clash (both counter-critted) stuns both sides for the same fixed time.
		-- Height (D.HEIGHT): a tall victim shakes hitstun off sooner, a short one is stunned longer.
		stun = if result == Result.Clash then D.CLASH_STUN elseif grabbing then g.pull + g.hold else move.hitstun * Height.ofModel(v.model).stunTaken
		Fighter.setState(v, State.Hitstun, stun, now)
	end
	-- A hit that ragdolls or knocks its victim throws the limp body (Knockback.launch -> Ragdoll.apply's
	-- launch, D.RAGDOLL) instead of motoring it: one ragdoll physics model for every case.
	local ragdolls = move.ragdoll > 0 and not held and result ~= Result.Clash
	local launch: Vector3? = nil
	if grabbing then
		Knockback.pullTo(v, a.root.Position + CombatMath.flat(a.root.CFrame.LookVector) * g.gap, g.pull)
	else
		-- The push must end inside the stun (a clash stun can be shorter than the move's hitstun).
		-- A clash always pushes both apart by the same fixed amount instead.
		local kb = if result == Result.Clash then D.CLASH_KNOCKBACK
			elseif outOf and outOf.knockback then outOf.knockback
			else move.knockback
		-- (vs the unscaled stun too: a tall victim's shorter hitstun still gets the move's push)
		if kb and kb.duration <= math.max(stun, if held or maxed or grabbing or result == Result.Clash then 0 else move.hitstun) and not cutscene and not spared then -- (a cutscene places them itself; a spared attacker keeps its footing)
			if ragdolls or knocked then
				launch = Knockback.launch(a, v, kb)
			else
				Knockback.apply(a, v, kb)
			end
		end
	end
	if ragdolls then
		Ragdoll.apply(v, move.ragdoll, if move.knockback then move.knockback.spin else 0, launch)
		if move.ragdollLand > 0 and v.state == State.Hitstun then
			getUpOnLanding(v, move.ragdollLand)
		end
		if move.strongRagdoll then
			Paths.shared("WindTrail").whileRagdolled(v.model) -- strong ragdoll: trail until they get up
		end
	end
	if maxed then
		-- The adrenaline break spends it all (user, 2026-10-30), so it can't chain stun after stun.
		AdrenalineSystem.markAttacked(v, now)
		AdrenalineSystem.gain(v, -v.adrenaline)
	else
		AdrenalineSystem.onStruck(v, if counter then D.ADR_GAIN_COUNTERED else D.ADR_GAIN_HIT, now)
	end
	-- `cutscene`: clients play the start sound + impact frame on this hit (FeedbackController).
	emit(a, v, result, hitPos(a, v), { stun = stun, damage = damage, move = move.id, gbs = maxed or nil, clip = if outOf then outOf.clip else nil, held = held or nil, grab = if grabbing then now + g.pull + g.hold else nil, rootUntil = if grabbing then now + g.pull + g.hold + a.style.moves[g.move].startup else nil, cutscene = if cutscene and not knocked then true else nil })
	if cutscene and not knocked then
		-- Deferred: CombatService finishes this swing first (its endlag would overwrite the cutscene state).
		task.defer(Paths.server("CutsceneService").play1v1, move.cutscene, a, v)
	end
	if knocked then
		-- After the hit's knockback / ragdoll / VFX: the finishing blow still launches them, then
		-- they're down (overrides the hitstun just set). A grab on them ends with it.
		if a.grab and a.grab.v == v then
			a.grab = nil
		end
		Paths.server("KnockService").knock(v, now, knockFor, launch)
	end
end

function HitResolver.resolve(a: any, v: any, move: any, now: number, emit: Emit, allowCounter: boolean): string?
	if not Fighter.hittable(v) or Fighter.inIframes(v, now) then
		return nil -- dead, knocked (immune) or on i-frames
	end

	if allowCounter and v.state == State.Startup and not move.tags.NoCounter then
		HitResolver.applyHit(a, v, move, a.attackDmgMult, now, Result.Counter, emit)
		return Result.Counter
	end

	-- `now` can be a held hit's past time (defence grace): a block pressed after it doesn't count.
	local guarded = Fighter.isGuarding(v)
		and v.blockPressAt <= now
		and not move.tags.Unblockable
		and CombatMath.inFrontArc(v.root.CFrame, a.root.Position, D.BLOCK_ARC_DEG)
	if not guarded then
		HitResolver.applyHit(a, v, move, a.attackDmgMult, now, Result.Hit, emit)
		return Result.Hit
	end

	local pos = hitPos(a, v)

	-- Parry: every move but Unparryable ones, only the first press, only inside the window (plus network tolerance).
	local inParryWindow = not move.tags.Unparryable and v.freshPress and now - v.blockPressAt <= D.PARRY_WINDOW + D.PARRY_NET_TOL
	-- Clumsy parry (Two Left Feet): the attacker is still parry-stunned, but the parrier just blocks it
	-- (weak guard, guard damage) below. Clients read info.parried on that Strip / GuardBreak.
	local clumsy = inParryWindow and v.mods.clumsyParry > 0
	if clumsy then
		a.queued = nil
		Fighter.setState(a, State.ParryStun, D.PARRY_STUN, now)
		FocusSystem.onParried(a)
		Fighter.proc(v, "clumsyParry")
		inParryWindow = false
	end
	if inParryWindow then
		v.freshPress = false
		v.parryBonus = v.mods.parryBonusDamage -- Charged Return: banked for the parrier's next attack
		if v.parryBonus > 0 then
			Fighter.proc(v, "parryBonusDamage")
		end
		-- A landed parry always drops guard once recovery ends (see CombatService onExpire).
		v.blockHeld = false
		v.parryUnguard = true
		a.queued = nil
		Fighter.setState(a, State.ParryStun, D.PARRY_STUN, now)
		Fighter.setState(v, State.BlockRecovery, D.PARRY_RECOVERY, now)
		-- Parrying empties the parrier's own adrenaline (user, 2026-10-30; was +160).
		AdrenalineSystem.markAttacked(v, now)
		AdrenalineSystem.gain(v, -v.adrenaline)
		FocusSystem.onParried(a) -- the parried attacker loses a share of their Focus
		emit(a, v, Result.Parried, pos, { stun = D.PARRY_RECOVERY, attackerStun = D.PARRY_STUN, move = move.id })
		return Result.Parried
	end
	v.freshPress = false

	-- ParryOnly: a block that wasn't a parry doesn't stop it.
	if move.tags.ParryOnly then
		HitResolver.applyHit(a, v, move, a.attackDmgMult, now, Result.Hit, emit)
		return Result.Hit
	end

	-- Guard damage ignores adrenaline.
	GuardSystem.damage(v, if move.tags.GuardBreak then math.huge else move.guardDamage, move.guardRegenDelay, now)
	if v.guard <= 0 then
		GuardSystem.breakGuard(v, now)
		v.blockHeld = false
		v.stripPending = false
		v.parryUnguard = false
		v.queued = nil
		if move.tags.Pierce then
			-- 100% guard chip (Dema M2): the guard is gone and the whole hit lands through it.
			HitResolver.applyHit(a, v, move, a.attackDmgMult, now, Result.Hit, emit)
			return Result.Hit
		end
		Fighter.setState(v, State.GuardBreakStun, D.GUARD_BREAK_STUN, now)
		AdrenalineSystem.onStruck(v, D.ADR_GAIN_GUARDBREAK, now)
		emit(a, v, Result.GuardBreak, pos, { stun = D.GUARD_BREAK_STUN, move = move.id, parried = clumsy or nil, attackerStun = if clumsy then D.PARRY_STUN else nil })
		return Result.GuardBreak
	end

	-- Held too long (or a Strip move, or a weakGuard fighter): this hit is still blocked, then the block is
	-- stripped when recovery ends.
	local strip = move.tags.Strip or v.mods.weakGuard > 0 or now - v.blockPressAt >= D.HOLD_STRIP_THRESHOLD
	AdrenalineSystem.markAttacked(v, now)
	Fighter.setState(v, State.BlockRecovery, move.blockstun, now)
	-- Moves with knockback.onBlock push through a block too (it must end inside the blockstun).
	local kb = move.knockback
	if kb and kb.onBlock and kb.duration <= move.blockstun then
		Knockback.apply(a, v, kb)
	end
	v.stripPending = strip
	v.blockedHit = not strip -- a strip keeps its cooldown; a clean block releases without one
	local result = if strip then Result.Strip else Result.Blocked
	emit(a, v, result, pos, { stun = move.blockstun, move = move.id, parried = clumsy or nil, attackerStun = if clumsy then D.PARRY_STUN else nil })
	return result
end

return HitResolver
