--!strict
-- Deterministic combat tests. Run from a playtest server:
--   require(game.ServerScriptService.Midori.Tests).run()
-- Uses a fake clock and calls CombatService.step directly on two isolated fighters, so
-- nothing depends on frame timing or touches real players.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Enums = Paths.shared("Enums")
local MoveSchema = Paths.shared("MoveSchema")
local Invariants = Paths.shared("Invariants")
local CombatMath = Paths.shared("CombatMath")
local Registry = Paths.server("FighterRegistry")
local CombatService = Paths.server("CombatService")
local HitResolver = Paths.server("HitResolver")

local State, Result = Enums.State, Enums.Result

local ORIGIN = Vector3.new(0, 1000, 0)
local STEP = 1 / 60
-- Effective drag window (0 / 0 while D.DRAG_HITBOX is off).
local LEAD = if D.DRAG_HITBOX then D.DRAG_LEAD else 0
local TAIL = if D.DRAG_HITBOX then D.DRAG_TAIL else 0

local Tests = {}

local function makeModel(name: string): Model
	local model = Instance.new("Model")
	model.Name = name
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = true
	root.CanCollide = false
	root.Parent = model
	model.PrimaryPart = root
	local hum = Instance.new("Humanoid")
	hum.RequiresNeck = false
	hum.EvaluateStateMachine = false
	hum.Parent = model
	model.Parent = workspace
	return model
end

local function near(a: number, b: number, eps: number?): boolean
	return math.abs(a - b) <= (eps or 1e-4)
end

function Tests.run(): string
	local style = MoveSchema.style("Basic")
	local M1 = style.moves.M1_1 -- read numbers from data so balance tweaks don't break tests
	local M2 = style.moves[style.m2] -- perfect blocks only work on M2s (and opted-in moves)
	local A, B = makeModel("MidoriTestA"), makeModel("MidoriTestB")
	local rootA = A:FindFirstChild("HumanoidRootPart") :: BasePart
	local rootB = B:FindFirstChild("HumanoidRootPart") :: BasePart
	local humA = A:FindFirstChildOfClass("Humanoid") :: Humanoid
	local humB = B:FindFirstChildOfClass("Humanoid") :: Humanoid

	local log: { { a: Model, v: Model, r: string, info: any } } = {}
	local disconnect = CombatService.hitResult:Connect(function(a, v, r, _pos, info)
		table.insert(log, { a = a.model, v = v.model, r = r, info = info })
	end)

	local clock = workspace:GetServerTimeNow()
	local a: any, v: any
	local only: { [any]: boolean } = {}

	-- Fresh fighters for each test. B stands 3 studs in front of A, facing A unless told otherwise.
	local function setup(victimFacesAttacker: boolean?)
		Registry.remove(A)
		Registry.remove(B)
		table.clear(log)
		clock += 5
		rootA.CFrame = CFrame.lookAt(ORIGIN, ORIGIN + Vector3.new(0, 0, -3))
		local bPos = ORIGIN + Vector3.new(0, 0, -3)
		local bLook = if victimFacesAttacker == false then bPos + Vector3.new(0, 0, -1) else ORIGIN
		rootB.CFrame = CFrame.lookAt(bPos, bLook)
		humA.Health = humA.MaxHealth
		humB.Health = humB.MaxHealth
		-- A ragdoll from an earlier test is still flagged on the reused models (its real-time timer hasn't run):
		-- start clean, or hits here count as "on a limp body" (no anti-heal, D.RAGDOLL).
		A:SetAttribute("Ragdolled", nil)
		B:SetAttribute("Ragdolled", nil)
		a = Registry.add(A, nil, style, clock)
		v = Registry.add(B, nil, style, clock)
		only = { [a] = true, [v] = true }
	end

	local function run(seconds: number)
		local steps = math.max(1, math.ceil(seconds / STEP - 1e-9))
		for _ = 1, steps do
			clock += seconds / steps
			CombatService.step(clock, seconds / steps, only)
		end
	end

	local function last(): any
		return log[#log]
	end

	local lines: { string } = {}
	local passed, failed = 0, 0
	local function test(name: string, fn: () -> ())
		local ok, err = pcall(fn)
		if ok then
			passed += 1
			table.insert(lines, "PASS " .. name)
		else
			failed += 1
			table.insert(lines, "FAIL " .. name .. ": " .. tostring(err))
		end
	end

	test("invariants hold for every follow-up (with allowlist)", function()
		if not D.CHECK_INVARIANTS then
			return -- disabled in Defaults
		end
		local _, failures = Invariants.check(style)
		assert(failures == 0, failures .. " unexpected invariant failures")
	end)

	test("M1 hit: damage, hitstun, adrenaline", function()
		setup()
		assert(CombatService.requestAttack(a, "M1", clock, false))
		assert(a.move.id == "M1_1", "server picked " .. tostring(a.move.id))
		run(0.27)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
		assert(v.state == State.Hitstun, "victim state " .. v.state)
		assert(near(humB.Health, 100 - M1.damage), "health " .. humB.Health)
		assert(near(v.adrenaline, D.ADR_GAIN_HIT), "adrenaline " .. v.adrenaline)
		assert(a.state == State.Endlag, "attacker state " .. a.state)
	end)

	test("re-hit extends stun; old stun never ends it early (bug 2)", function()
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		local firstEnd = v.stateEndsAt
		run(0.2)
		HitResolver.applyHit(a, v, style.moves.M1_2, 1, clock, Result.Hit, function() end)
		run(firstEnd - clock + 0.05) -- just past where the first stun would have ended
		assert(v.state == State.Hitstun, "victim left stun early: " .. v.state)
		run(0.35)
		assert(v.state == State.Idle, "victim stuck in " .. v.state)
	end)

	test("block from the front: guard damage, no health damage, blockstun E+pad", function()
		setup()
		assert(CombatService.requestBlock(v, true, clock, clock, false))
		run(D.BLOCK_START_DURATION + 0.05)
		assert(v.state == State.Blocking, "not blocking: " .. v.state)
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		assert(last() and last().r == Result.Blocked, "expected Blocked, got " .. tostring(last() and last().r))
		assert(near(humB.Health, 100), "took damage " .. humB.Health)
		assert(near(v.guard, style.guardMax - M1.guardDamage, 0.1), "guard " .. v.guard)
		assert(v.state == State.BlockRecovery and near(last().info.stun, M1.endlag + D.BLOCKSTUN_PAD), "recovery")
		run(M1.endlag + D.BLOCKSTUN_PAD + 0.01)
		assert(v.state == State.Blocking, "should return to Blocking while held: " .. v.state)
	end)

	test("hit from behind ignores block", function()
		setup(false)
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
	end)

	test("parry inside window: attacker ParryStun then half the move's endlag, no damage", function()
		setup()
		v.adrenaline, v.lastHitTakenAt = 200, clock + 10 -- parrying should empty it (no drain meanwhile)
		CombatService.requestAttack(a, "M2", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03) -- just before the drag hitbox goes live
		CombatService.requestBlock(v, true, clock, clock, false)
		run(0.07)
		assert(last() and last().r == Result.Parried, "expected Parried, got " .. tostring(last() and last().r))
		assert(a.state == State.ParryStun and near(a.stateEndsAt - a.stateStartedAt, D.PARRY_STUN), "attacker " .. a.state)
		assert(v.state == State.BlockRecovery, "victim " .. v.state)
		assert(near(humB.Health, 100) and near(v.guard, style.guardMax), "parry should cost nothing")
		assert(v.adrenaline == 0, "parrying should empty the parrier's adrenaline, left " .. v.adrenaline)
		local endlag = a.move.endlag / 2
		run(D.PARRY_STUN + 0.02)
		assert(a.state == State.Endlag and near(a.stateEndsAt - a.stateStartedAt, endlag), "after parry stun: " .. a.state)
		run(endlag)
		assert(a.state == State.Idle, "after parry endlag: " .. a.state)
	end)

	test("press outside the parry window is a normal block", function()
		setup()
		CombatService.requestAttack(a, "M2", clock, false)
		run(M2.startup - D.PARRY_WINDOW - D.PARRY_NET_TOL - 0.06)
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.PARRY_WINDOW + D.PARRY_NET_TOL + 0.08)
		assert(last() and last().r == Result.Blocked, "expected Blocked, got " .. tostring(last() and last().r))
	end)

	test("M1s are parryable", function()
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03) -- just before the drag hitbox goes live
		CombatService.requestBlock(v, true, clock, clock, false)
		run(0.07)
		assert(last() and last().r == Result.Parried, "expected Parried, got " .. tostring(last() and last().r))
	end)

	test("guard break: no health damage, stun, then no-block window", function()
		setup()
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		v.guard = M1.guardDamage - 1 -- the next M1 breaks it
		v.guardRegenPausedUntil = math.huge
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		assert(last() and last().r == Result.GuardBreak, "expected GuardBreak, got " .. tostring(last() and last().r))
		assert(near(humB.Health, 100), "break hit dealt damage")
		assert(near(v.guard, style.guardMax * D.GUARD_BREAK_RESTORE), "guard " .. v.guard)
		local stunEnd = v.stateEndsAt
		run(stunEnd - clock + 0.02)
		assert(v.state == State.Idle, "state " .. v.state)
		assert(near(v.noBlockUntil, stunEnd + D.GUARD_BREAK_NO_BLOCK), "noBlockUntil")
		assert(not CombatService.requestBlock(v, true, clock, clock, false), "blocked during no-block window")
		run(1.0)
		assert(CombatService.requestBlock(v, true, clock, clock, false), "should block again after window")
	end)

	test("hits during guard-break / perfect-blocked stun deal damage but keep that stun", function()
		local Fighter = Paths.server("Fighter")
		for _, st in { State.GuardBreakStun, State.ParryStun } do
			setup()
			local stun = if st == State.GuardBreakStun then D.GUARD_BREAK_STUN else D.PARRY_STUN
			Fighter.setState(v, st, stun, clock)
			local ends = v.stateEndsAt
			local hp = humB.Health
			HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, function() end)
			assert(v.state == st, `{st}: hitstun overrode it ({v.state})`)
			assert(near(v.stateEndsAt, ends), `{st}: stun end moved`)
			assert(humB.Health < hp, `{st}: no damage`)
		end
	end)

	test("releasing a block that blocked a hit has the short block cooldown; a strip has the full one", function()
		setup()
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		CombatService.requestAttack(a, "M1", clock, false)
		run(M1.startup + 0.003)
		assert(last() and last().r == Result.Blocked, "expected Blocked, got " .. tostring(last() and last().r))
		run(M1.blockstun + 0.01)
		CombatService.requestBlock(v, false, clock, clock, false)
		assert(v.state == State.Idle and near(v.blockCooldownUntil - clock, D.BLOCK_COOLDOWN_AFTER_BLOCK), "short cooldown after a blocked hit")
		run(math.max(D.BLOCK_COOLDOWN_AFTER_BLOCK, D.RELEASE_ACT_DELAY) + 0.01)
		assert(CombatService.requestBlock(v, true, clock, clock, false), "couldn't re-block after the short cooldown")
		-- Strip: still released with the cooldown.
		setup()
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.HOLD_STRIP_THRESHOLD)
		CombatService.requestAttack(a, "M1", clock, false)
		run(M1.startup + 0.003)
		assert(last() and last().r == Result.Strip, "expected Strip, got " .. tostring(last() and last().r))
		run(M1.blockstun + 0.01)
		assert(v.state == State.Idle and near(v.blockCooldownUntil - v.stateStartedAt, D.BLOCK_COOLDOWN), "strip lost its full cooldown")
	end)

	test("getting countered out of an M2 windup puts the M2 on cooldown", function()
		setup()
		CombatService.requestAttack(v, "M2", clock, false) -- B winds up the slow M2...
		CombatService.requestAttack(a, "M1", clock, false) -- ...and A's faster M1 counters it
		assert(M1.startup < M2.startup, "test assumes M1 lands before M2")
		run(M1.startup + 0.003)
		assert(last() and last().r == Result.Counter, "expected Counter, got " .. tostring(last() and last().r))
		-- from the hit (= the hitstun's start; drag hitboxes can land before the hitbox time)
		assert(near(v.m2CooldownUntil - v.stateStartedAt, M2.cooldown), "countered M2 cooldown " .. (v.m2CooldownUntil - v.stateStartedAt))
	end)

	test("dash-cancelling an M2 windup puts the M2 on cooldown", function()
		setup()
		a.dashCooldownUntil = 0
		CombatService.requestAttack(a, "M2", clock, false)
		run(M2.startup / 2)
		assert(a.state == State.Startup, "not in windup: " .. a.state)
		assert(CombatService.requestDash(a, Vector3.zAxis, "Front", clock, clock, false), "dash-cancel refused")
		assert(near(a.m2CooldownUntil - clock, M2.cooldown), "M2 cooldown after cancel " .. (a.m2CooldownUntil - clock))
		assert(A:GetAttribute("M2CooldownUntil") == a.m2CooldownUntil, "cooldown not mirrored")
	end)

	test("guard regens GUARD_REGEN_BLOCKING_MULT faster while holding block", function()
		setup()
		v.guard = 0
		v.guardRegenPausedUntil = 0
		run(1)
		assert(near(v.guard, D.GUARD_REGEN_PER_SEC, 0.1), "idle regen " .. v.guard)
		setup()
		CombatService.requestBlock(v, true, clock, clock, false)
		v.guard = 0
		v.guardRegenPausedUntil = 0
		run(1)
		assert(near(v.guard, D.GUARD_REGEN_PER_SEC * D.GUARD_REGEN_BLOCKING_MULT, 0.1), "blocking regen " .. v.guard)
	end)

	test("weak guard: held past the threshold, hit still blocked, then block stripped with cooldown", function()
		setup()
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.HOLD_STRIP_THRESHOLD)
		CombatService.requestAttack(a, "M1", clock, false)
		run(M1.startup + 0.003)
		assert(last() and last().r == Result.Strip, "expected Strip, got " .. tostring(last() and last().r))
		assert(near(humB.Health, 100), "strip hit dealt damage")
		run(0.32)
		assert(v.state == State.Idle and not v.blockHeld, "block not stripped: " .. v.state)
		assert(v.blockCooldownUntil > clock, "no cooldown after strip")
		assert(not CombatService.requestBlock(v, true, clock, clock, false), "re-blocked during cooldown")
	end)

	test("dash i-frames dodge the hit", function()
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.17)
		assert(CombatService.requestDash(v, Vector3.xAxis, "Front", clock, clock, false))
		run(0.12)
		assert(#log == 0, "hit landed through i-frames: " .. tostring(last() and last().r))
		assert(near(humB.Health, 100), "health " .. humB.Health)
		assert(near(v.adrenaline, D.ADR_GAIN_DODGE), "dodge adrenaline " .. v.adrenaline)
	end)

	test("escape cylinder: a near miss on a dasher counts as an escape; further out or not dashing doesn't", function()
		local esc = D.DASH_ESCAPE_CYLINDER
		local box = M1.hitbox
		-- B's body (2 studs wide) just outside the M1 box's side edge, but inside the escape radius.
		local function placeB(gap: number)
			local x = box.size.X / 2 + gap
			rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(x, 0, -3), ORIGIN + Vector3.new(x, 0, 0))
		end
		for _, case in { { esc.radius - 0.3, true, true }, { esc.radius + 0.3, true, false }, { esc.radius - 0.3, false, false } } do
			local gap, dash, want = case[1], case[2], case[3]
			assert(gap > rootB.Size.X / 2, "test body would be inside the hitbox")
			setup()
			placeB(gap)
			CombatService.requestAttack(a, "M1", clock, false)
			run(0.17)
			if dash then
				assert(CombatService.requestDash(v, Vector3.xAxis, "Front", clock, clock, false), "dash refused")
			end
			run(0.12)
			assert(#log == 0, "near miss connected: " .. tostring(last() and last().r))
			local escaped = v.adrenaline > 0
			assert(escaped == want, `gap {gap} dash {dash}: escaped {escaped}, want {want}`)
		end
	end)

	test("hit after i-frames on a dasher is a normal hit (no counter)", function()
		setup()
		CombatService.requestDash(v, Vector3.xAxis, "Front", clock, clock, false)
		-- Time the swing so the drag hitbox goes live just after the i-frames end (read from data).
		-- (A swing that touches the dasher during i-frames is dodged for its whole drag.)
		run(math.max(0, D.DASH_IFRAMES - (M1.startup - LEAD)) + 0.02)
		CombatService.requestAttack(a, "M1", clock, false)
		run(M1.startup + 0.01)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
	end)

	test("counter crit: x1.35 damage and cancels the victim's attack", function()
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.15)
		CombatService.requestAttack(v, "M1", clock, false)
		run(0.12)
		assert(last() and last().r == Result.Counter, "expected Counter, got " .. tostring(last() and last().r))
		assert(near(humB.Health, 100 - M1.damage * D.COUNTER_MULT), "health " .. humB.Health)
		assert(near(v.adrenaline, D.ADR_GAIN_COUNTERED), "countered victim adrenaline " .. v.adrenaline)
		run(0.4)
		assert(near(humA.Health, 100), "cancelled attack still landed")
	end)

	test("clash: simultaneous hits counter-crit both", function()
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		CombatService.requestAttack(v, "M1", clock, false)
		run(0.27)
		assert(#log == 2 and log[1].r == Result.Clash and log[2].r == Result.Clash, "expected two Clash results, got " .. #log)
		local expected = 100 - M1.damage * D.COUNTER_MULT
		assert(near(humA.Health, expected) and near(humB.Health, expected), "health A " .. humA.Health .. " B " .. humB.Health)
		for _, f in { a, v } do
			assert(f.state == State.Hitstun, "clash left " .. f.state)
			assert(near(f.stateEndsAt - f.stateStartedAt, D.CLASH_STUN), "clash stun " .. (f.stateEndsAt - f.stateStartedAt))
		end
		assert(log[1].info.stun == D.CLASH_STUN and log[2].info.stun == D.CLASH_STUN, "clients told the wrong clash stun")
	end)

	test("server owns the M1 chain and resets it after idling", function()
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.5)
		CombatService.requestAttack(a, "M1", clock, false)
		assert(a.move.id == "M1_2", "second swing was " .. tostring(a.move.id))
		run(0.5 + D.CHAIN_RESET + 0.05)
		CombatService.requestAttack(a, "M1", clock, false)
		assert(a.move.id == "M1_1", "chain did not reset: " .. tostring(a.move.id))
	end)

	test("cannot block while stunned", function()
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		assert(v.state == State.Hitstun)
		assert(not CombatService.requestBlock(v, true, clock, clock, false), "blocked in hitstun")
	end)

	test("post-stun dash delay of 0.2s", function()
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		local stunEnd = v.stateEndsAt
		run(stunEnd - clock + 0.02)
		assert(v.state == State.Idle, "state " .. v.state)
		assert(not CombatService.requestDash(v, Vector3.xAxis, "Front", clock, clock, false), "dashed inside the delay")
		run(0.2)
		assert(CombatService.requestDash(v, Vector3.xAxis, "Front", clock, clock, false), "dash still locked")
	end)

	test("release starts the 0.4s block cooldown", function()
		setup()
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		CombatService.requestBlock(v, false, clock, clock, false)
		assert(v.state == State.Idle, "state " .. v.state)
		assert(not CombatService.requestBlock(v, true, clock, clock, false), "re-blocked during cooldown")
		run(0.41)
		assert(CombatService.requestBlock(v, true, clock, clock, false), "cooldown never ended")
	end)

	test("adrenaline 500: faster startup, max damage bonus, endlag unchanged", function()
		setup()
		a.adrenaline = 500
		CombatService.requestAttack(a, "M1", clock, false)
		local boosted = M1.startup / (1 + D.ADR_MAX_SPEED_BONUS)
		assert(near(a.hitboxAt - clock, boosted), "startup " .. (a.hitboxAt - clock))
		run(boosted + 0.01)
		assert(near(humB.Health, 100 - M1.damage * (1 + D.ADR_MAX_DAMAGE_BONUS)), "health " .. humB.Health)
		assert(near(a.stateEndsAt - a.stateStartedAt, M1.endlag), "endlag scaled")
	end)

	test("Slugger: speed bonus becomes damage (1% = 2.5%), M1s stun +0.1 and anti-heal 30%", function()
		local sl = MoveSchema.style("Slugger")
		local SM1 = sl.moves[sl.m1Chain[1]]
		assert(near(SM1.hitstun, SM1.endlag + D.HITSTUN_PAD + 0.1), "hitstun " .. SM1.hitstun)
		assert(near(SM1.antiHeal, 0.3), "antiHeal " .. SM1.antiHeal)
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, sl, clock)
		only = { [a] = true, [v] = true }
		assert(A:GetAttribute("SpeedToDamage") == true, "client attribute not set")
		a.adrenaline = 500
		CombatService.requestAttack(a, "M1", clock, false)
		assert(near(a.hitboxAt - clock, SM1.startup), "startup sped up: " .. (a.hitboxAt - clock))
		local want = (1 + D.ADR_MAX_DAMAGE_BONUS) * (1 + D.ADR_MAX_SPEED_BONUS * 2.5)
		assert(near(a.attackDmgMult, want), `damage mult {a.attackDmgMult} want {want}`)
	end)

	test("dash snaps to front/back/side with per-direction distances", function()
		local DashMotor = Paths.shared("DashMotor")
		local facing = Vector3.new(0, 0, -1)
		local diag = Vector3.new(0.6, 0, -0.8).Unit
		assert(DashMotor.snap(facing, diag) == facing, "diagonal-forward should snap forward")
		local right = DashMotor.snap(facing, Vector3.new(0.9, 0, 0.1).Unit)
		assert(right:FuzzyEq(Vector3.xAxis), "should snap right, got " .. tostring(right))
		assert(DashMotor.classify(facing, facing) == "Front")
		assert(DashMotor.classify(facing, -facing) == "Back")
		assert(DashMotor.classify(facing, Vector3.xAxis) == "Side")
		assert(DashMotor.distance("Side", false) == D.DASH_DISTANCE.Side)
		assert(near(DashMotor.distance("Front", true), D.DASH_DISTANCE.Front * D.DASH_CANCEL_RANGE_MULT))
	end)

	test("dash distance comes from a validated kind", function()
		setup()
		local DashMotor = Paths.shared("DashMotor")
		assert(not CombatService.requestDash(a, Vector3.xAxis, "Mega", clock, clock, false), "accepted unknown kind")
		assert(CombatService.requestDash(a, Vector3.xAxis, "Side", clock, clock, false))
		assert(near(a.dashDistance, DashMotor.distance("Side", false)), "distance " .. a.dashDistance)
	end)

	test("landed parry forces unguard with no block cooldown, then the parrier can follow up", function()
		setup()
		CombatService.requestAttack(a, "M2", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03) -- just before the drag hitbox goes live
		CombatService.requestBlock(v, true, clock, clock, false)
		run(0.07)
		assert(last() and last().r == Result.Parried, "expected Parried")
		assert(not v.blockHeld, "parry should drop the held block")
		run(D.PARRY_RECOVERY + 0.02)
		assert(v.state == State.Idle, "parrier still guarding: " .. v.state)
		assert(v.blockCooldownUntil <= clock and v.actLockUntil <= clock, "parry put us on the guard timer")
		assert(CombatService.requestAttack(v, "M1", clock, false), "could not follow up")
		run(0.28)
		assert(last() and last().v == A, "follow-up did not land on the parried attacker")
	end)

	test("re-pressing F right after a parry gives a fresh block", function()
		setup()
		CombatService.requestAttack(a, "M2", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03) -- just before the drag hitbox goes live
		CombatService.requestBlock(v, true, clock, clock, false)
		run(0.07 + D.PARRY_RECOVERY + 0.02)
		assert(CombatService.requestBlock(v, true, clock, clock, false), "buffered re-block rejected")
		assert(v.freshPress and v.state == State.BlockStart, "re-block is not a fresh press")
	end)

	test("buffered block is legal the instant hitstun ends", function()
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		local stunEnd = v.stateEndsAt
		assert(not CombatService.requestBlock(v, true, clock, clock, false), "blocked inside hitstun")
		run(stunEnd - clock + STEP)
		assert(CombatService.requestBlock(v, true, clock, clock, false), "block not available right after stun")
		assert(v.freshPress, "post-stun block should be able to parry")
	end)

	test("landed parry leaves guard unchanged", function()
		setup()
		v.guard = 5
		v.guardRegenPausedUntil = math.huge -- isolate from passive regen
		CombatService.requestAttack(a, "M2", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03) -- just before the drag hitbox goes live
		CombatService.requestBlock(v, true, clock, clock, false)
		run(0.07)
		assert(last() and last().r == Result.Parried, "expected Parried")
		assert(near(v.guard, 5), "parry changed guard: " .. v.guard)
	end)

	test("finishing the M1 combo locks M1 for COMBO_END_DELAY, then restarts at hit 1", function()
		setup()
		rootB.CFrame = rootB.CFrame + Vector3.new(0, 50, 0) -- out of range: whiff the whole chain
		for i = 1, #style.m1Chain do
			assert(CombatService.requestAttack(a, "M1", clock, false), "chain hit " .. i .. " rejected")
			assert(a.move.id == style.m1Chain[i], "expected " .. style.m1Chain[i])
			run(a.move.startup + a.move.endlag + 0.05)
		end
		assert(a.state == State.Idle, "state " .. a.state)
		assert(not CombatService.requestAttack(a, "M1", clock, false), "M1 allowed during combo-end delay")
		assert(CombatService.requestAttack(a, "M2", clock, false), "M2 should not be locked")
		setup()
		rootB.CFrame = rootB.CFrame + Vector3.new(0, 50, 0)
		for _ = 1, #style.m1Chain do
			CombatService.requestAttack(a, "M1", clock, false)
			run(a.move.startup + a.move.endlag + 0.05)
		end
		run(style.comboEndDelay)
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 still locked after the delay")
		assert(a.move.id == style.m1Chain[1], "combo did not restart at hit 1: " .. a.move.id)
	end)

	test("M2 goes on cooldown for move.cooldown after its endlag; M1 is unaffected", function()
		setup()
		rootB.CFrame = rootB.CFrame + Vector3.new(0, 50, 0) -- whiff
		assert(CombatService.requestAttack(a, "M2", clock, false), "M2 rejected")
		local m2 = a.move
		assert(m2.cooldown > 0, "M2 has no cooldown in data")
		run(m2.startup + m2.endlag + 0.05)
		assert(a.state == State.Idle, "state " .. a.state)
		assert(not CombatService.requestAttack(a, "M2", clock, false), "M2 allowed during cooldown")
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 should not be locked by M2 cooldown")
		setup()
		rootB.CFrame = rootB.CFrame + Vector3.new(0, 50, 0)
		CombatService.requestAttack(a, "M2", clock, false)
		run(m2.startup + m2.endlag + m2.cooldown + 0.02)
		assert(CombatService.requestAttack(a, "M2", clock, false), "M2 still on cooldown")
	end)

	test("crit guard breaks a held block but can be parried", function()
		local crit = style.moves[style.r]
		setup()
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		assert(CombatService.requestAttack(a, "R", clock, false), "crit rejected")
		run(crit.startup + 0.02)
		assert(last() and last().r == Result.GuardBreak, "held block: expected GuardBreak, got " .. tostring(last() and last().r))
		assert(near(humB.Health, 100), "guard break dealt damage " .. humB.Health)

		setup()
		CombatService.requestAttack(a, "R", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03) -- just before the drag hitbox goes live
		CombatService.requestBlock(v, true, clock, clock, false) -- parry press right before it lands
		run(0.07)
		assert(last() and last().r == Result.Parried, "fresh press: expected Parried, got " .. tostring(last() and last().r))
	end)

	test("crit goes on cooldown after its endlag; M1/M2 are unaffected", function()
		local crit = style.moves[style.r]
		setup()
		rootB.CFrame = rootB.CFrame + Vector3.new(0, 50, 0) -- whiff
		CombatService.requestAttack(a, "R", clock, false)
		run(crit.startup + crit.endlag + 0.05)
		assert(a.state == State.Idle, "state " .. a.state)
		assert(not CombatService.requestAttack(a, "R", clock, false), "crit allowed during cooldown")
		assert(CombatService.requestAttack(a, "M2", clock, false), "M2 locked by crit cooldown")
		setup()
		rootB.CFrame = rootB.CFrame + Vector3.new(0, 50, 0)
		CombatService.requestAttack(a, "R", clock, false)
		run(crit.startup + crit.endlag + crit.cooldown + 0.02)
		assert(CombatService.requestAttack(a, "R", clock, false), "crit still on cooldown")
	end)

	test("attacker pays adrenaline per connecting hit, blocked hits included, parried hits free", function()
		setup()
		a.adrenaline = 200
		a.lastHitTakenAt = math.huge -- freeze passive drain so only the hit cost shows
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		assert(last() and last().r == Result.Hit)
		assert(a.adrenaline == 0, "landed hit should spend all adrenaline, left " .. a.adrenaline)

		setup()
		a.adrenaline = 200
		a.lastHitTakenAt = math.huge -- freeze passive drain so only the hit cost shows
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		assert(last() and last().r == Result.Blocked)
		assert(near(a.adrenaline, 200 - D.ADR_COST_ON_BLOCKED, 1), "after blocked hit " .. a.adrenaline)

		setup()
		a.adrenaline = 200
		a.lastHitTakenAt = math.huge -- freeze passive drain so only the hit cost shows
		CombatService.requestAttack(a, "M2", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03) -- just before the drag hitbox goes live
		CombatService.requestBlock(v, true, clock, clock, false)
		run(0.07)
		assert(last() and last().r == Result.Parried)
		assert(near(a.adrenaline, 200, 1), "parried hit still cost adrenaline: " .. a.adrenaline)
	end)

	test("only the first landed hit gets the adrenaline bonus", function()
		setup()
		a.adrenaline = 500
		a.lastHitTakenAt = math.huge
		CombatService.requestAttack(a, "M1", clock, false)
		run(M1.startup / (1 + D.ADR_MAX_SPEED_BONUS) + 0.01)
		assert(near(humB.Health, 100 - M1.damage * (1 + D.ADR_MAX_DAMAGE_BONUS)), "first hit not boosted: " .. humB.Health)
		assert(a.adrenaline == 0, "adrenaline left after landing: " .. a.adrenaline)
		run(0.6) -- endlag over and victim out of hitstun
		v.healable = 0 -- no healable regen inside the measurement
		local before = humB.Health
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.3)
		assert(near(before - humB.Health, style.moves.M1_2.damage), "second hit was boosted: " .. (before - humB.Health))
	end)

	test("blocking an attack pauses adrenaline drain", function()
		setup()
		v.adrenaline = 300
		v.lastHitTakenAt = clock - 10 -- already draining
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.27)
		assert(last() and last().r == Result.Blocked)
		local after = v.adrenaline
		run(0.5)
		assert(near(v.adrenaline, after), "drain did not pause after a blocked hit: " .. after .. " -> " .. v.adrenaline)
	end)

	test("attacks and blocks need combat mode (server-enforced)", function()
		setup()
		CombatService.setCombatMode(v, false) -- players start out of combat mode
		assert(not CombatService.requestAttack(v, "M1", clock, false), "attacked out of combat mode")
		assert(not CombatService.requestBlock(v, true, clock, clock, false), "blocked out of combat mode")
		assert(CombatService.requestDash(v, Vector3.xAxis, "Front", clock, clock, false), "dash should not need combat mode")
		run(D.DASH_DURATION + D.DASH_ENDLAG + 0.1)
		CombatService.setCombatMode(v, true)
		assert(CombatService.requestBlock(v, true, clock, clock, false), "block refused in combat mode")
	end)

	test("respawn gets a fresh fighter (bug 1)", function()
		setup()
		CombatService.requestBlock(v, true, clock, clock, false)
		v.adrenaline = 300
		Registry.remove(B)
		local fresh = Registry.add(B, nil, style, clock)
		assert(fresh.state == State.Idle and not fresh.blockHeld and fresh.adrenaline == 0, "state carried over")
	end)

	test("knockback: landed hits push (server-run), blocked hits and clash-short stuns don't", function()
		local Knockback = Paths.server("Knockback")
		local raw = {
			kind = "M1",
			anim = M1.anim,
			startup = M1.startup,
			endlag = M1.endlag,
			hitstun = 0.5,
			damage = 1,
			hitbox = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -3) },
			knockback = { distance = 6, duration = 0.25, direction = "Away" },
		}
		local kbMove = MoveSchema.resolve("KbTest", raw)
		assert(kbMove.knockback and kbMove.knockback.direction == "Away", "knockback not resolved")
		local tooLong = table.clone(raw)
		tooLong.knockback = { distance = 6, duration = 0.6 }
		assert(not pcall(MoveSchema.resolve, "KbTooLong", tooLong), "knockback longer than hitstun was accepted")

		setup()
		HitResolver.applyHit(a, v, kbMove, 1, clock, Result.Hit, function() end)
		assert(Knockback.isActive(v), "hit did not start a knockback")
		Knockback.stop(v)
		assert(not Knockback.isActive(v), "stop did not end the knockback")

		setup()
		HitResolver.applyHit(a, v, kbMove, 1, clock, Result.Clash, function() end)
		-- A clash always pushes by D.CLASH_KNOCKBACK (both sides), not the move's knockback.
		assert(D.CLASH_KNOCKBACK.duration <= D.CLASH_STUN, "CLASH_KNOCKBACK outlasts CLASH_STUN")
		assert(Knockback.isActive(v), "clash didn't push")
		Knockback.stop(v)

		-- "Toward" (Slugger Critical): pulls in at the attacker, at most `distance`, stopping 3 studs in front.
		local realPush = Knockback.push
		local got: any = nil
		Knockback.push = function(_, dir, distance, _duration, target)
			got = { dir = dir, distance = distance, target = target }
		end
		local ok, err = pcall(function()
			local toward = { distance = 10, duration = 0.3, direction = "Toward" }
			for _, case in { { gap = 8, pulled = 5 }, { gap = 20, pulled = 10 }, { gap = 2, pulled = nil } } do
				setup()
				rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -case.gap), ORIGIN)
				got = nil
				Knockback.apply(a, v, toward)
				if case.pulled then
					assert(got and near(got.distance, case.pulled, 1e-3) and got.dir:Dot(Vector3.zAxis) > 0.99, `gap {case.gap}: pulled {got and got.distance} along {got and got.dir}`)
					-- A landing spot the victim's client aims at from where it really is (never past the gap).
					local landsAt = ORIGIN + Vector3.new(0, 0, -(case.gap - case.pulled))
					assert(got.target and (got.target - landsAt).Magnitude < 1e-3, `gap {case.gap}: lands at {got.target}, want {landsAt}`)
				else
					assert(got == nil, `gap {case.gap}: already close, still pulled`)
				end
			end
		end)
		Knockback.push = realPush
		assert(ok, err)
	end)

	test("Aerial Ace: Gio's crit has i-frames from `at` into startup for `duration`", function()
		local Fighter = Paths.server("Fighter")
		local ace = Paths.perk("AerialAce")
		local gio = MoveSchema.style("Gio")
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, gio, clock)
		only = { [a] = true, [v] = true }
		assert(CombatService.requestAttack(a, "R", clock, false), "R refused")
		run(STEP) -- let the perk tick see the startup
		local t0 = a.stateStartedAt
		local scale = (a.stateEndsAt - t0) / gio.moves[gio.r].startup
		local from = t0 + ace.at * scale
		assert(not Fighter.inIframes(a, from - 0.01), "i-frames before `at`")
		assert(Fighter.inIframes(a, from + 0.01), "no i-frames after `at`")
		if ace.duration then
			assert(not Fighter.inIframes(a, from + ace.duration * scale + 0.01), "i-frames past `duration`")
		end
		local untilT = from + ace.duration * scale
		if untilT > a.hitboxAt then
			-- they carry on past the hit into endlag, then stop
			rootB.CFrame += Vector3.new(0, 50, 0) -- whiff, so A goes straight to endlag
			run(a.hitboxAt - clock + 0.01)
			assert(a.state == State.Endlag and Fighter.inIframes(a, clock), "i-frames didn't run into endlag")
			assert(not Fighter.inIframes(a, untilT + 0.01), "i-frames past `duration` in endlag")
		end
		-- M1 startup never gets them
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, gio, clock)
		only = { [a] = true, [v] = true }
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
		run(STEP)
		assert(not Fighter.inIframes(a, a.hitboxAt - 0.01), "M1 got Aerial Ace i-frames")
	end)

	test("Measured Strikes: each Karate chain M1 is slower and hits harder, reset with the chain", function()
		local karate = MoveSchema.style("Karate")
		local mods = Paths.perk("MeasuredStrikes").mods
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, karate, clock)
		only = { [a] = true, [v] = true }
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -80), ORIGIN) -- whiff: no adrenaline muddying the numbers
		local function swing(want: number)
			assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
			local move = a.move
			local startup = a.stateEndsAt - clock
			assert(near(startup, move.startup * (1 + mods.m1ChainSlow * want)), `step {want}: startup {startup}`)
			assert(near(a.attackDmgMult, 1 + mods.m1ChainDamage * want), `step {want}: damage mult {a.attackDmgMult}`)
			assert(near(a.attackSpeed * (1 + mods.m1ChainSlow * want), 1), `step {want}: anim speed {a.attackSpeed}`)
			local base = karate.moves[move.id].endlag
			assert(near(move.endlag, base * (1 + mods.m1ChainEndlag * want)), `step {want}: endlag {move.endlag}`)
			run(startup + 0.001)
			assert(a.state == State.Endlag and near(a.stateEndsAt - a.stateStartedAt, move.endlag), `step {want}: endlag state`)
			run(move.endlag + 0.01)
		end
		for step = 0, #karate.m1Chain - 1 do
			swing(step)
		end
		run((karate.comboEndDelay or D.COMBO_END_DELAY) + 0.01)
		swing(0) -- chain restarted: back to normal
	end)

	test("Measured Strikes: landed chain hits deal the bonus damage at the slowed timing", function()
		local karate = MoveSchema.style("Karate")
		local mods = Paths.perk("MeasuredStrikes").mods
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, karate, clock)
		only = { [a] = true, [v] = true }
		for step = 0, #karate.m1Chain - 1 do
			a.adrenaline = 0 -- landed hits gain adrenaline; keep its bonus out of the numbers
			table.clear(log)
			assert(CombatService.requestAttack(a, "M1", clock, false), `step {step}: M1 refused`)
			local move = a.move
			local startup = move.startup * (1 + mods.m1ChainSlow * step)
			run(startup - 0.005)
			assert(#log == 0, `step {step}: hit landed before the slowed startup`)
			run(0.01)
			assert(last() and last().r == Result.Hit, `step {step}: didn't land`)
			local want = move.damage * (1 + mods.m1ChainDamage * step)
			assert(near(last().info.damage, want, 1e-3), `step {step}: damage {last().info.damage} want {want}`)
			run(move.endlag + 0.01)
		end
	end)

	local fc = MoveSchema.style("Firecracker")
	local FC_CRIT = fc.moves[fc.r]
	local function setupFirecracker()
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, fc, clock)
		only = { [a] = true, [v] = true }
	end

	test("Firecracker Critical: fuse leaves you free (M1 works), then every barrage hit lands, then endlag", function()
		local fuse, b = FC_CRIT.fuse, FC_CRIT.barrage
		setupFirecracker()
		assert(CombatService.requestAttack(a, "R", clock, false), "R refused")
		local burn = a.fuseAt - clock
		assert(burn >= fuse.min - 1e-6 and burn <= fuse.max + 1e-6, "fuse " .. burn)
		assert(a.state == State.Idle, "lighting the fuse changed state: " .. a.state)
		assert(not CombatService.requestAttack(a, "R", clock, false), "relit a lit fuse")
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused during the fuse")
		run(fc.moves.M1_1.startup + 0.01)
		assert(last() and last().r == Result.Hit, "M1 during the fuse didn't land")
		run(a.fuseAt - clock - 0.05)
		assert(a.state ~= State.Barrage, "fuse went off early")
		table.clear(log)
		run(0.06)
		assert(a.state == State.Barrage, "expected Barrage, got " .. a.state)
		run(b.duration - 0.03)
		assert(#log == b.hits, `hits {#log} want {b.hits}`)
		for _, e in log do
			assert(e.r == Result.Hit, "barrage result " .. e.r)
		end
		run(0.06)
		assert(a.state == State.Endlag, "expected Endlag, got " .. a.state)
		run(FC_CRIT.endlag + 0.02)
		assert(a.state == State.Idle and a.rCooldownUntil > clock, "no cooldown after the barrage")
	end)

	test("Firecracker perk: M1 and crit hits spend no adrenaline; last punch = 1.5 x adr/500 (x adrenaline bonus)", function()
		setupFirecracker()
		a.adrenaline = 400
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
		assert(near(a.stateEndsAt - clock, fc.moves.M1_1.startup), "M1 got the adrenaline speed bonus")
		assert(A:GetAttribute("M1NoAdrenaline") == true, "client attribute not set")
		run(fc.moves.M1_1.startup + 0.01)
		assert(last() and last().r == Result.Hit, "M1 didn't land")
		assert(near(last().info.damage, fc.moves.M1_1.damage), "M1 got the adrenaline damage bonus: " .. last().info.damage)
		-- A landed hit normally spends ALL of it; only the passive drain may have taken a little.
		assert(a.adrenaline > 400 - D.ADR_DRAIN_PER_SEC * 0.5, "M1 spent adrenaline: " .. a.adrenaline)
		run(fc.moves.M1_1.endlag + 0.05)
		local adrAtHit: { number } = {}
		local conn = CombatService.hitResult:Connect(function(att)
			if att == a then
				table.insert(adrAtHit, a.adrenaline)
			end
		end)
		local ok, err = pcall(function()
			a.adrenaline = 400
			assert(CombatService.requestAttack(a, "R", clock, false), "R refused")
			table.clear(log)
			run(a.fuseAt - clock + 0.01)
			local mult = a.attackDmgMult
			assert(a.state == State.Barrage, "expected Barrage, got " .. a.state)
			run(FC_CRIT.barrage.duration - 0.02)
			assert(#log == FC_CRIT.barrage.hits, `hits {#log}`)
			for i = 2, #adrAtHit do
				-- Only the passive drain between punches (a spent hit would zero it).
				local gap = FC_CRIT.barrage.duration / FC_CRIT.barrage.hits
				assert(adrAtHit[i] >= adrAtHit[i - 1] - D.ADR_DRAIN_PER_SEC * gap * 1.5, `a punch spent adrenaline: {adrAtHit[i - 1]} -> {adrAtHit[i]}`)
			end
			local finisher = log[#log].info.damage
			local want = 1.5 * adrAtHit[#adrAtHit] / D.ADR_MAX * mult
			assert(near(finisher, want, 1e-3), `finisher {finisher} want {want}`)
			assert(near(log[1].info.damage, FC_CRIT.damage * mult, 1e-3), "normal punch " .. log[1].info.damage)
			assert(adrAtHit[#adrAtHit] > 0 and a.adrenaline == 0, "the final punch didn't burn the meter: " .. a.adrenaline)
		end)
		conn() -- Signal:Connect returns a disconnect function
		assert(ok, err)
	end)

	test("Firecracker Critical: blocked punches still knock back, no guard break", function()
		local Knockback = Paths.server("Knockback")
		local pushes = 0
		local real = Knockback.apply
		Knockback.apply = function(_a, victim, kb)
			if victim == v and kb == FC_CRIT.knockback then
				pushes += 1
			end
		end
		local ok, err = pcall(function()
			setupFirecracker()
			assert(CombatService.requestBlock(v, true, clock, clock, false), "block refused")
			run(D.PARRY_WINDOW + D.PARRY_NET_TOL + 0.05) -- past the parry window
			HitResolver.resolve(a, v, FC_CRIT, clock, function() end, false)
			assert(v.state == State.BlockRecovery, "expected a block, got " .. v.state)
			assert(pushes == 1, "blocked punch pushed " .. pushes .. " times")
		end)
		Knockback.apply = real
		assert(ok, err)
	end)

	test("attack pose: a player's fresh, nearby client pose places the hitbox; stale or far ones don't", function()
		local root = { CFrame = CFrame.new(0, 0, 0), Position = Vector3.zero }
		local near5 = CFrame.new(0, 0, -5)
		local f = { player = true, root = root, clientPose = near5, clientPoseAt = 10 }
		local cf, fromClient = CombatService.attackOrigin(f, 10.05)
		assert(fromClient and cf == near5, "fresh nearby pose ignored")
		_, fromClient = CombatService.attackOrigin(f, 10 + D.POSE_MAX_AGE + 0.01)
		assert(not fromClient, "stale pose used")
		f.clientPose = CFrame.new(0, 0, -(D.POSE_MAX_OFFSET + 1))
		_, fromClient = CombatService.attackOrigin(f, 10.05)
		assert(not fromClient, "pose too far from the server's root used")
		f.player = nil
		f.clientPose = near5
		_, fromClient = CombatService.attackOrigin(f, 10.05)
		assert(not fromClient, "server-run fighter used a client pose")
	end)

	test("Firecracker M2: the dash takes rush.duration, whatever the distance", function()
		local r = fc.moves.M2.rush
		assert(r.duration > 0, "M2 rush has no fixed duration")
		for _, studs in { r.freeStuds, r.freeStuds * 2 } do
			assert(near(studs / MoveSchema.rushSpeed(r, studs), r.duration), "travel time for " .. studs)
		end
	end)

	-- Firecracker M2: a plain dash (the hold-to-charge was removed, user 2026-10-11).
	local FC_M2 = fc.moves.M2
	test("Firecracker M2: fixedStartup - full adrenaline doesn't shorten the 0.5s windup", function()
		setupFirecracker()
		a.adrenaline = D.ADR_MAX
		assert(CombatService.requestAttack(a, "M2", clock, false), "M2 refused")
		assert(near(a.stateEndsAt - clock, FC_M2.startup) and near(FC_M2.startup, 0.5), "windup " .. (a.stateEndsAt - clock))

	end)

	test("Firecracker M2: windup, then a 5-stud dash for 6, even with the button held", function()
		assert(FC_M2.charge == nil, "M2 still has a charge")
		setupFirecracker()
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -80), ORIGIN)
		a.chargeHeld = "M2" -- holding M2 must not stretch the windup any more
		assert(CombatService.requestAttack(a, "M2", clock, false), "M2 refused")
		local mult = a.attackDmgMult
		run(FC_M2.startup / a.attackSpeed + 0.001)
		assert(a.state == State.Rush, "expected Rush after the windup, got " .. a.state)
		assert(near(a.rushBudget, 5) and near(FC_M2.damage, 6), "dash numbers changed")
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -3), ORIGIN) -- step into the dash
		run(STEP)
		assert(last() and last().r == Result.Hit, "dash didn't connect")
		assert(near(last().info.damage, FC_M2.damage * mult, 0.05), "damage " .. last().info.damage)
	end)

	test("Firecracker Critical: fuse length comes from adrenaline when lit (max at 0, min at full, linear)", function()
		local fuse = FC_CRIT.fuse
		for _, case in { { 0, fuse.max }, { D.ADR_MAX, fuse.min }, { D.ADR_MAX / 2, (fuse.min + fuse.max) / 2 } } do
			setupFirecracker()
			a.adrenaline = case[1]
			assert(CombatService.requestAttack(a, "R", clock, false), "R refused")
			assert(near(a.fuseAt - clock, case[2]), `adrenaline {case[1]}: fuse {a.fuseAt - clock}, want {case[2]}`)
		end
		assert(near(fuse.min, 1.3) and near(fuse.max, 1.3), "fuse should always be 1.3s")
	end)

	test("Firecracker Critical: a queued fuse isn't replaced by a later M1 (bug 2026-10-25)", function()
		setupFirecracker()
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
		run(fc.moves.M1_1.startup + 0.01) -- in the M1's endlag: R can only queue
		local ok, why = CombatService.requestAttack(a, "R", clock, true)
		assert(ok and why == "queued", "R not queued: " .. tostring(why))
		assert(not CombatService.requestAttack(a, "M1", clock, true), "a later M1 replaced the queued fuse")
		run(fc.moves.M1_1.endlag + 0.05)
		assert(a.fuseMove ~= nil, "the queued fuse never lit")
		assert(A:GetAttribute("RCooldownUntil") > clock, "lighting didn't set the cooldown attribute the client waits for")
	end)

	test("Firecracker Critical: a fuse going off mid-stun fizzles (no barrage, cooldown runs)", function()
		setupFirecracker()
		assert(CombatService.requestAttack(a, "R", clock, false), "R refused")
		run(a.fuseAt - clock - 0.1)
		HitResolver.applyHit(v, a, style.moves.M1_1, 1, clock, Result.Hit, function() end)
		run(0.2)
		assert(a.state == State.Hitstun and a.fuseMove == nil, "fuse didn't fizzle: " .. a.state)
		assert(near(a.rCooldownUntil, a.fuseAt + FC_CRIT.cooldown, 0.05), "fizzle cooldown " .. (a.rCooldownUntil - clock))
	end)

	test("Firecracker fuse: a knock clears it; it never goes off outside the free states (bug 2026-10-24)", function()
		local KnockService = Paths.server("KnockService")
		setupFirecracker()
		assert(CombatService.requestAttack(a, "R", clock, false), "R refused")
		KnockService.knock(a, clock)
		assert(a.state == State.Knocked and a.fuseMove == nil, "the knock should clear the fuse")
		run(FC_CRIT.fuse.max + 0.1)
		assert(a.state == State.Knocked, "fuse went off while knocked: " .. a.state)
		KnockService.recover(a, clock)
		-- still lit when a cutscene starts: fizzles instead of breaking the cutscene
		setupFirecracker()
		assert(CombatService.requestAttack(a, "R", clock, false), "R refused (2)")
		Paths.server("Fighter").setState(a, State.Cutscene, 10, clock)
		run(a.fuseAt - clock + 0.05)
		assert(a.state == State.Cutscene and a.fuseMove == nil, "fuse went off in a cutscene: " .. a.state)
	end)

	test("ragdoll: rig builds disabled sockets + colliders; apply goes limp (RootJoint stays); stop restores", function()
		local Ragdoll = Paths.shared("Ragdoll")
		local m = Instance.new("Model")
		m.Name = "MidoriTestR6"
		local base = CFrame.new(0, 500, 0)
		local function newPart(name: string, size: Vector3): BasePart
			local p = Instance.new("Part")
			p.Name, p.Size, p.CFrame, p.Anchored = name, size, base, true
			p.Parent = m
			return p
		end
		local function motor(name: string, p0: BasePart, p1: BasePart, c0: Vector3, c1: Vector3): Motor6D
			local mo = Instance.new("Motor6D")
			mo.Name, mo.Part0, mo.Part1, mo.C0, mo.C1 = name, p0, p1, CFrame.new(c0), CFrame.new(c1)
			mo.Parent = p0
			return mo
		end
		local hrp = newPart("HumanoidRootPart", Vector3.new(2, 2, 1))
		local torso = newPart("Torso", Vector3.new(2, 2, 1))
		local rootJoint = motor("RootJoint", hrp, torso, Vector3.zero, Vector3.zero)
		local R6 = {
			Head = { "Neck", Vector3.new(0, 1, 0), Vector3.new(0, -0.5, 0) },
			["Left Arm"] = { "Left Shoulder", Vector3.new(-1, 0.5, 0), Vector3.new(0.5, 0.5, 0) },
			["Right Arm"] = { "Right Shoulder", Vector3.new(1, 0.5, 0), Vector3.new(-0.5, 0.5, 0) },
			["Left Leg"] = { "Left Hip", Vector3.new(-1, -1, 0), Vector3.new(-0.5, 1, 0) },
			["Right Leg"] = { "Right Hip", Vector3.new(1, -1, 0), Vector3.new(0.5, 1, 0) },
		}
		for name, j in R6 do
			motor(j[1], torso, newPart(name, Vector3.new(1, 2, 1)), j[2], j[3])
		end
		local hum = Instance.new("Humanoid")
		hum.EvaluateStateMachine = false
		hum.RequiresNeck = false
		hum.Parent = m
		m.Parent = workspace
		local ok, err = pcall(function()
			local function count(): (number, number, number, number)
				local sockets, socketsOn, colliders, collidersOn = 0, 0, 0, 0
				for _, d in m:GetDescendants() do
					if d:IsA("BallSocketConstraint") then
						sockets += 1
						socketsOn += if d.Enabled then 1 else 0
					elseif d:IsA("BasePart") and d.Name == "MidoriRagdollCollider" then
						assert(d.Parent ~= m and d.Transparency == 1 and not d.CanQuery, "collider: under its part, invisible, unqueryable")
						colliders += 1
						collidersOn += if d.CanCollide then 1 else 0
					end
				end
				return sockets, socketsOn, colliders, collidersOn
			end
			local function motorsOn(): number
				local n = 0
				for _, mo in torso:GetChildren() do
					n += if mo:IsA("Motor6D") and mo.Enabled then 1 else 0
				end
				return n
			end
			Ragdoll.rig(m)
			Ragdoll.rig(m) -- twice: still one set
			local s, sOn, c, cOn = count()
			assert(s == 5 and sOn == 0 and c == 6 and cOn == 0, `at rest: sockets {s}/{sOn} on, colliders {c}/{cOn} on`)
			local f = { model = m, humanoid = hum, root = hrp }
			Ragdoll.apply(f, 60, 0)
			s, sOn, c, cOn = count()
			assert(sOn == 5 and cOn == 6 and motorsOn() == 0 and rootJoint.Enabled, `limp: sockets {sOn}, colliders {cOn}, motors {motorsOn()}, root joint {rootJoint.Enabled}`)
			assert(m:GetAttribute("Ragdolled") ~= nil, "Ragdolled attribute")
			Ragdoll.stop(f)
			s, sOn, c, cOn = count()
			assert(sOn == 0 and cOn == 0 and motorsOn() == 5 and m:GetAttribute("Ragdolled") == nil, "stop should restore")
		end)
		m:Destroy()
		assert(ok, err)
	end)

	-- Feng Critical (rush). A is re-added as Feng; B starts far away so nothing connects early.
	local feng = MoveSchema.style("Feng")
	local CRIT = feng.moves.Critical
	local RUSH = CRIT.rush
	local function setupFeng(adrenaline: number)
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, feng, clock)
		only = { [a] = true, [v] = true }
		a.adrenaline = adrenaline
		local far = ORIGIN + Vector3.new(0, 0, -80)
		rootB.CFrame = CFrame.lookAt(far, ORIGIN)
	end

	test("Feng Critical: rush hit scales with distance, ends on contact, then cooldown", function()
		setupFeng(400)
		assert(CombatService.requestAttack(a, "R", clock, false), "R refused")
		local mult = a.attackDmgMult
		run(CRIT.startup / a.attackSpeed + 0.001)
		assert(a.state == State.Rush, "expected Rush after the windup, got " .. a.state)
		local rushStart = a.stateStartedAt
		run((RUSH.freeStuds - 2) / RUSH.speed)
		assert(a.state == State.Rush and #log == 0, "rush ended early / hit something: " .. a.state)
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -3), ORIGIN) -- step into the hitbox
		run(STEP)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
		local studs = (clock - rushStart) * RUSH.speed
		local want = (CRIT.damage + RUSH.damagePerStud * studs) * mult
		assert(near(last().info.damage, want, 1e-3), `damage {last().info.damage} want {want}`)
		assert(a.state == State.Endlag, "attacker state " .. a.state)
		run(CRIT.endlag + 0.05)
		assert(a.state == State.Idle and a.rCooldownUntil > clock, "no cooldown after the rush")
	end)

	test("Feng Critical: out of distance = miss carry, then endlag; adrenaline buys no distance", function()
		assert(RUSH.adrPerStud == 0, "Feng rush distance should not scale with adrenaline (user, 2026-10-29)")
		setupFeng(500) -- a full meter still only gets the free studs
		assert(CombatService.requestAttack(a, "R", clock, false), "R refused")
		run(CRIT.startup / a.attackSpeed + RUSH.freeStuds / RUSH.speed + 0.02)
		assert(a.state == State.RushMiss, "expected RushMiss, got " .. a.state)
		run(RUSH.carry)
		assert(a.state == State.Endlag, "expected Endlag after the carry, got " .. a.state)
		assert(near(a.stateEndsAt - a.stateStartedAt, RUSH.missEndlag), "whiff endlag " .. (a.stateEndsAt - a.stateStartedAt))
		run(RUSH.missEndlag + 0.02)
		assert(a.state == State.Idle and #log == 0, "miss path ended in " .. a.state)

		setupFeng(0)
		assert(CombatService.requestAttack(a, "R", clock, false), "R refused at 0 adrenaline")
		run(CRIT.startup / a.attackSpeed + 0.001)
		assert(a.state == State.Rush, "0 adrenaline should still rush the free studs, got " .. a.state)
		run(RUSH.freeStuds / RUSH.speed + 0.02)
		assert(a.state == State.RushMiss, "expected RushMiss after the free studs, got " .. a.state)
		run(RUSH.carry + RUSH.missEndlag + 0.05)
		assert(a.state == State.Idle, "stuck in " .. a.state)
	end)

	test("Furious Feng dash kick: M1 in a dash throws it (no chain), fixed 0.63 windup, 8 dmg launch + ragdoll, 0.5 endlag", function()
		local ff = MoveSchema.style("FuriousFeng")
		local KICK = ff.moves[ff.dashM1]
		assert(KICK and KICK.lead and KICK.ragdollLand > 0 and KICK.step and KICK.step.dash, "dash kick data")
		local function asFuriousFeng()
			setup()
			Registry.remove(A)
			a = Registry.add(A, nil, ff, clock)
			only = { [a] = true, [v] = true }
		end
		-- Not dashing: M1 is the normal chain.
		asFuriousFeng()
		assert(CombatService.requestAttack(a, "M1", clock, false), "idle M1 refused")
		assert(a.move.id == ff.m1Chain[1], "idle M1 should be the chain, got " .. tostring(a.move.id))
		-- Chambered Kick: no chamber = no kick (the click queues like a normal M1 in a dash).
		asFuriousFeng()
		assert(a.mods.dashM1Chamber > 0 and a.bonusDashes == 0, "Chambered Kick missing / chamber pre-filled")
		assert(CombatService.requestDash(a, Vector3.new(0, 0, -1), "Front", clock, clock, false), "dash refused")
		run(0.05)
		CombatService.requestAttack(a, "M1", clock, true)
		assert(a.state == State.Dash, "kicked without a chamber, state " .. a.state)
		-- Dashing with a chamber: M1 throws the kick at once (no queue), fixed startup, burns the chamber,
		-- and the normal dash comes off cooldown.
		asFuriousFeng()
		Paths.server("Fighter").addBonusDashes(a, 1)
		a.adrenaline = 500 -- would shorten a normal windup
		assert(CombatService.requestDash(a, Vector3.new(0, 0, -1), "Front", clock, clock, false), "dash refused")
		run(0.05)
		assert(a.state == State.Dash, "not dashing: " .. a.state)
		assert(a.bonusDashes == 1 and a.dashCooldownUntil > clock, "raw dash should go first")
		local chainBefore = a.chainIndex
		assert(CombatService.requestAttack(a, "M1", clock, false), "dash M1 refused")
		assert(a.move.id == ff.dashM1 and a.state == State.Startup, `dash M1 threw {tostring(a.move and a.move.id)} / {a.state}`)
		assert(a.bonusDashes == 0, "kick didn't burn the chamber")
		assert(a.dashCooldownUntil <= clock, "kick didn't refund the dash cooldown")
		assert(near(a.stateEndsAt - clock, KICK.startup), "windup " .. (a.stateEndsAt - clock))
		assert(a.chainIndex == chainBefore, "the dash kick advanced the M1 chain")
		local mult = a.attackDmgMult
		run(KICK.startup + 0.01)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
		assert(near(last().info.damage, KICK.damage * mult, 1e-3), "damage " .. last().info.damage)
		assert(B:GetAttribute("Ragdolled") ~= nil, "victim not ragdolled")
		-- Landing it gives no chamber refund (user, 2026-11-03: the 30% is gone), just the normal fill (the dash was refunded, so it fills),
		-- and no Fury refund on top (the kick lights Fury after the refunds ran).
		local fill = KICK.startup / Paths.perk("ChamberedDash").fillTime
		assert(near(A:GetAttribute("Chamber"), KICK.chamberRefund + fill, 0.05), "chamber after landing " .. tostring(A:GetAttribute("Chamber")))
		assert(v.state == State.Hitstun and near(v.stateEndsAt - v.stateStartedAt, KICK.hitstun, 0.05), "victim stun cap")
		assert(a.state == State.Endlag and near(a.stateEndsAt - a.stateStartedAt, KICK.endlag), "attacker endlag")
		run(KICK.endlag + 0.02)
		assert(a.state == State.Idle, "attacker stuck in " .. a.state)
		-- Pressed during the dash but arriving a ping late (past the live grace): judged by the press time,
		-- it's still the dash kick. Pressed after the dash: a plain M1.
		asFuriousFeng()
		Paths.server("Fighter").addBonusDashes(a, 1)
		local pressT = clock
		assert(CombatService.requestDash(a, Vector3.new(0, 0, -1), "Front", clock, clock, false), "dash refused")
		run(0.1)
		pressT = clock -- mid-dash on the client
		run(D.DASH_DURATION) -- arrives after the dash + its grace
		assert(a.state ~= State.Dash, "still dashing: " .. a.state)
		assert(CombatService.requestAttack(a, "M1", clock, true, pressT), "late dash M1 refused")
		assert(a.move.id == ff.dashM1, "late dash M1 threw " .. tostring(a.move and a.move.id))
		asFuriousFeng()
		Paths.server("Fighter").addBonusDashes(a, 1)
		assert(CombatService.requestDash(a, Vector3.new(0, 0, -1), "Front", clock, clock, false), "dash refused")
		run(D.DASH_DURATION + D.DASH_ENDLAG + 0.05)
		CombatService.requestAttack(a, "M1", clock, true, clock)
		assert(a.move == nil or a.move.id ~= ff.dashM1, "an M1 after the dash threw the dash kick")
		-- Plain Feng has no dash kick: M1 in a dash queues as before.
		setupFeng(0)
		assert(CombatService.requestDash(a, Vector3.new(0, 0, -1), "Front", clock, clock, false), "feng dash refused")
		run(0.05)
		CombatService.requestAttack(a, "M1", clock, true)
		assert(a.state == State.Dash, "Feng's dash M1 should queue, state " .. a.state)
	end)

	test("Ragdoll anti-heal: none on a limp body, getUpResist of it for getUpWindow after getting up", function()
		local Ragdoll = Paths.shared("Ragdoll")
		local R = D.RAGDOLL
		local full = setmetatable({ antiHeal = 1 }, { __index = M1 })
		local function hit(): number
			v.healable, v.adrenaline = 0, 0
			humB.Health = humB.MaxHealth
			local before = humB.Health
			HitResolver.applyHit(a, v, full, 1, clock, Result.Hit, function() end)
			return before - humB.Health
		end
		setup()
		Ragdoll.apply(v, 60, 0)
		local dealt = hit()
		assert(near(v.healable, math.min(D.HEAL_MAX, dealt * D.HEAL_KEEP), 0.01), "limp body took anti-heal: healable " .. v.healable)
		Ragdoll.stop(v)
		dealt = hit()
		local want = math.min(D.HEAL_MAX, dealt * D.HEAL_KEEP * (1 - (1 - R.getUpResist)))
		assert(near(v.healable, want, 0.01), `just up: healable {v.healable}, want {want}`)
		v.gotUpAt -= R.getUpWindow + 0.1 -- window over: the full anti-heal again
		hit()
		assert(near(v.healable, 0, 0.01), "after the window: healable " .. v.healable)
	end)

	test("KickCan: M2 in a dash throws a can (50 st/s, 40 range); landing it lights Fury, a miss at range puts it out", function()
		local ff = MoveSchema.style("FuriousFeng")
		local CAN = ff.moves[ff.dashM2]
		local P = CAN.projectile
		local PerkService = Paths.server("PerkService")
		local function asFuriousFeng(dist: number)
			setup()
			Registry.remove(A)
			a = Registry.add(A, nil, ff, clock)
			rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -dist), ORIGIN)
			only = { [a] = true, [v] = true }
		end
		local Fighter = Paths.server("Fighter")
		local function throw()
			Fighter.addBonusDashes(a, 1) -- Chambered Kick: every dash attack needs a chambered dash
			assert(CombatService.requestDash(a, Vector3.new(0, 0, -1), "Front", clock, clock, false), "dash refused")
			run(0.05)
			assert(CombatService.requestAttack(a, "M2", clock, false), "dash M2 refused")
			assert(a.move.id == ff.dashM2 and a.state == State.Startup, `dash M2 threw {tostring(a.move and a.move.id)} / {a.state}`)
			assert(a.bonusDashes == 0 and a.dashCooldownUntil <= clock, "KickCan didn't burn the chamber / refund the dash")
		end
		-- No chamber: no can (the press queues like a normal M2 in a dash).
		asFuriousFeng(20)
		assert(CombatService.requestDash(a, Vector3.new(0, 0, -1), "Front", clock, clock, false), "dash refused")
		run(0.05)
		CombatService.requestAttack(a, "M2", clock, true)
		assert(a.state == State.Dash, "KickCan thrown without a chamber, state " .. a.state)
		-- 20 studs out: nothing at the kick, the hit lands once the can gets there.
		asFuriousFeng(20)
		throw()
		run(CAN.startup + 0.01)
		assert(last() == nil, "hit before the can arrived")
		run((20 - 2.5) / P.speed) -- by the time the can's centre reaches B
		assert(last() and last().r == Result.Hit and near(last().info.damage, CAN.damage * a.attackDmgMult, 1e-3), "can didn't land: " .. tostring(last() and last().r))
		assert(PerkService.state(a, "Fury").fx ~= nil, "landing KickCan didn't light Fury")
		-- The M2 cooldown doesn't gate it (only the chamber does): straight away again, chambered, it throws.
		run(CAN.endlag + 0.05)
		assert(a.m2CooldownUntil > clock, "KickCan should still put M2 on cooldown")
		Fighter.setTimer(a, "dashCooldownUntil", clock)
		throw()
		-- Out of range: flies its 40 studs, touches nobody = a miss, and that puts Fury out.
		asFuriousFeng(80)
		local fury = PerkService.state(a, "Fury")
		PerkService.event(a, "onLanded", ff.moves[ff.dashM1], clock)
		assert(fury.fx ~= nil, "couldn't light Fury")
		throw()
		run(CAN.startup + P.range / P.speed - 0.1)
		assert(fury.fx ~= nil, "Fury out before the can reached its range")
		run(0.15)
		assert(last() == nil and fury.fx == nil, "the can's miss didn't put Fury out")
		-- A wall in the way: the can stops there, B behind it is never hit, and it's a miss (Fury out).
		asFuriousFeng(20)
		local wall = Instance.new("Part")
		wall.Anchored = true
		wall.Size = Vector3.new(20, 20, 1)
		wall.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 0, -10))
		wall.Parent = workspace
		fury = PerkService.state(a, "Fury")
		PerkService.event(a, "onLanded", ff.moves[ff.dashM1], clock)
		throw()
		run(CAN.startup + 20 / P.speed)
		wall:Destroy()
		assert(last() == nil, "the can went through the wall: " .. tostring(last() and last().r))
		assert(fury.fx == nil, "the can hitting a wall didn't count as a miss")
	end)

	test("Fury: the dash kick lights it, landed hits refund dash, healable burn, a whiff puts it out", function()
		local ff = MoveSchema.style("FuriousFeng")
		local P = Paths.perk("Fury")
		local PerkService = Paths.server("PerkService")
		local Fighter = Paths.server("Fighter")
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, ff, clock)
		only = { [a] = true, [v] = true }
		local s = PerkService.state(a, "Fury")
		assert(s and s.fx == nil, "perk missing / pre-lit")
		PerkService.event(a, "onLanded", ff.moves.M1_1, clock)
		assert(s.fx == nil, "an M1 lit it")
		-- The kick that lights it gets no Fury dash refund on top of its own.
		Fighter.setTimer(a, "dashCooldownUntil", clock + 3)
		HitResolver.applyHit(a, v, ff.moves[ff.dashM1], 1, clock, Result.Hit, function() end)
		assert(s.fx and near(a.mods.antiHeal, P.mods.antiHeal), "the kick didn't light it")
		assert(near(a.dashCooldownUntil, clock + 3), "the lighting kick got Fury's refund")
		Registry.remove(B)
		humB.Health = humB.MaxHealth
		B:SetAttribute("Ragdolled", nil) -- the kick launched B; this M1 is on a standing body
		v = Registry.add(B, nil, style, clock)
		only = { [a] = true, [v] = true }
		-- +20% anti-heal on a landed M1, and 1s off the dash cooldown.
		Fighter.setTimer(a, "dashCooldownUntil", clock + 3)
		HitResolver.applyHit(a, v, ff.moves.M1_1, 1, clock, Result.Hit, function() end)
		assert(near(a.dashCooldownUntil, clock + 3 - P.mods.hitDashRefund), "dash refund " .. (a.dashCooldownUntil - clock))
		local keep = 1 - math.min(1, ff.moves.M1_1.antiHeal + P.mods.antiHeal)
		assert(near(v.healable, math.min(D.HEAL_MAX, ff.moves.M1_1.damage * D.HEAL_KEEP * keep), 0.01), "anti-heal: healable " .. v.healable)
		-- Burns P.burn HP a second, all healable, and the burn itself pauses regen like a hit.
		local hp = humA.Health
		run(1.05)
		assert(near(hp - humA.Health, P.burn) and near(a.healable, P.burn), `burn: hp {hp - humA.Health}, healable {a.healable}`)
		assert(near(a.selfDamagedAt, clock, 0.06), "burn didn't mark self damage")
		-- No natural healing while lit, even long past the regen delay (burn floored so it can't mask it).
		a.selfDamagedAt, a.lastHitTakenAt, s.burnAt = -math.huge, -math.huge, math.huge
		local healable = a.healable
		run(D.HEAL_REGEN_DELAY + 0.5)
		assert(near(a.healable, healable), "regenerated during Fury: " .. a.healable)
		s.burnAt = clock
		-- A whiffed M1 puts it out and takes the mods back off.
		rootB.CFrame += Vector3.new(0, 50, 0)
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
		run(ff.moves.M1_1.startup + 0.02)
		assert(s.fx == nil and a.mods.antiHeal == 0 and a.mods.hitDashRefund == 0 and a.mods.noRegen == 0, "the whiff didn't put it out")
	end)

	test("dash intent: away from a close enemy = longer cooldown + slow; toward a far one = shorter; around = normal", function()
		local I = D.DASH_INTENT
		local CombatTag = Paths.server("CombatTag")
		local function dash(dir: Vector3, bOffset: Vector3, fighting: boolean?): number
			setup()
			if fighting ~= false then
				CombatTag.exchange(a, v, D.COMBAT.threshold)
			end
			a.model:SetAttribute("Flee", nil)
			rootB.CFrame = CFrame.new(ORIGIN + bOffset)
			assert(CombatService.requestDash(a, dir, "Front", clock, clock, false), "dash refused")
			return a.dashCooldownUntil - clock
		end
		-- B 3 studs ahead (-Z). Dashing +Z flees it.
		assert(near(dash(Vector3.zAxis, Vector3.new(0, 0, -3)), D.DASH_COOLDOWN * I.awayCooldownMult), "away cooldown")
		assert(near(a.flee, D.FLEE.dash), "away should add the flee chunk, got " .. tostring(a.flee))
		-- Sideways past them: normal, no slow.
		assert(near(dash(Vector3.xAxis, Vector3.new(0, 0, -3)), D.DASH_COOLDOWN), "around cooldown")
		assert((a.flee or 0) == 0, "around shouldn't fill the flee meter")
		-- Fleeing someone past awayRange: normal.
		assert(near(dash(Vector3.zAxis, Vector3.new(0, 0, -(I.awayRange + 5))), D.DASH_COOLDOWN), "far away = normal")
		-- Toward a far enemy: shorter; toward a close one (under towardMinRange): normal.
		assert(near(dash(-Vector3.zAxis, Vector3.new(0, 0, -(I.towardMinRange + 10))), D.DASH_COOLDOWN * I.towardCooldownMult), "toward far cooldown")
		assert(near(dash(-Vector3.zAxis, Vector3.new(0, 0, -(I.towardMinRange - 5))), D.DASH_COOLDOWN), "toward close = normal")
		-- Nobody within towardMaxRange: normal.
		assert(near(dash(-Vector3.zAxis, Vector3.new(0, 0, -(I.towardMaxRange + 10))), D.DASH_COOLDOWN), "out of range = normal")
		-- Someone close you're NOT fighting: normal (user, 2026-10-29: only people you're in combat with).
		assert(near(dash(Vector3.zAxis, Vector3.new(0, 0, -3), false), D.DASH_COOLDOWN), "not in combat = normal")
		a.model:SetAttribute("Flee", nil)
	end)

	test("adrenaline: resists anti-heal (30% at 250); at max the next clean hit guard-break-stuns", function()
		local R = D.ADR_ANTIHEAL_RESIST
		assert(near(CombatMath.antiHealResist(0), 0) and near(CombatMath.antiHealResist(R.full / 2), R.max / 2), "resist ramp")
		assert(near(CombatMath.antiHealResist(R.full), R.max) and near(CombatMath.antiHealResist(D.ADR_MAX), R.max), "resist cap")
		local full = setmetatable({ antiHeal = 1 }, { __index = M1 })
		local noop = function() end
		for _, adr in { 0, R.full } do
			setup()
			v.adrenaline = adr
			HitResolver.applyHit(a, v, full, 1, clock, Result.Hit, noop)
			local dealt = 100 - humB.Health
			local want = math.min(D.HEAL_MAX, dealt * D.HEAL_KEEP * CombatMath.antiHealResist(adr))
			assert(near(v.healable, want, 1e-3), `adrenaline {adr}: healable {v.healable} want {want}`)
		end
		-- Max adrenaline: clean hit = GuardBreakStun for D.GUARD_BREAK_STUN, guard meter untouched.
		setup()
		v.adrenaline = Paths.server("Fighter").adrMax(v)
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(v.state == State.GuardBreakStun and near(v.stateEndsAt - clock, D.GUARD_BREAK_STUN), "maxed hit: " .. v.state)
		assert(near(v.guard, style.guardMax), "maxed hit touched the guard meter")
		assert(v.adrenaline == 0, "the adrenaline break should reset it, left " .. v.adrenaline)
		-- One short of max: a normal hitstun.
		setup()
		v.adrenaline = Paths.server("Fighter").adrMax(v) - 1
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(v.state == State.Hitstun, "under max: " .. v.state)
	end)

	test("flee meter: running away fills + locks the run, circling / knockback don't, drains smoothly", function()
		local F = D.FLEE
		local CombatTag = Paths.server("CombatTag")
		local function fresh(fighting: boolean?)
			setup()
			for _, k in { "Flee", "FleeLocked" } do
				A:SetAttribute(k, nil)
			end
			if fighting ~= false then
				run(STEP) -- CombatTag stamps the link with its last step's time: make that now, not the last test's
				CombatTag.exchange(a, v, D.COMBAT.threshold)
			end
		end
		-- B is 3 studs ahead (-Z); +Z is straight away. Anchored rig: the velocity is just the property.
		fresh()
		rootA.AssemblyLinearVelocity = Vector3.new(0, 0, D.RUN_SPEED)
		run(1)
		assert(near(a.flee, D.RUN_SPEED / F.fullStuds, 0.02), "1s running away: flee " .. a.flee)
		assert(near(A:GetAttribute("Flee") :: number, a.flee, F.sendStep), "attribute lags the meter")
		run(F.fullStuds / D.RUN_SPEED)
		assert(a.flee == 1 and a.fleeLocked and A:GetAttribute("FleeLocked") == true, "full meter should lock the run")
		assert(near(CombatMath.fleeMult(1), F.minMult), "full meter slow")
		-- Stop: holds for drainDelay, then drains; stays locked until unlockAt.
		rootA.AssemblyLinearVelocity = Vector3.zero
		run(F.drainDelay - 0.05)
		assert(a.flee == 1, "drained before drainDelay")
		run(0.05 + (1 - F.unlockAt) / F.drainPerSec - 0.1)
		assert(a.fleeLocked, "unlocked above unlockAt (" .. a.flee .. ")")
		run(0.2)
		assert(not a.fleeLocked and A:GetAttribute("FleeLocked") == nil, "still locked at " .. a.flee)
		run(1 / F.drainPerSec)
		assert(a.flee == 0 and A:GetAttribute("Flee") == nil, "didn't drain to 0: " .. a.flee)

		-- Circling them (sideways), stepping back slower than minSpeed: nothing.
		fresh()
		rootA.AssemblyLinearVelocity = Vector3.new(D.RUN_SPEED, 0, 0)
		run(1)
		assert(a.flee == 0, "circling filled " .. a.flee)
		rootA.AssemblyLinearVelocity = Vector3.new(0, 0, F.minSpeed - 1)
		run(1)
		assert(a.flee == 0, "spacing filled " .. a.flee)
		-- Knocked back (hitstun) away from them: nothing.
		HitResolver.applyHit(v, a, M1, 1, clock, Result.Hit, function() end)
		rootA.AssemblyLinearVelocity = Vector3.new(0, 0, 40)
		run(0.1)
		assert(a.state == State.Hitstun and a.flee == 0, "knockback filled " .. a.flee)
		-- Not in combat with them, or out of range: nothing.
		fresh(false)
		rootA.AssemblyLinearVelocity = Vector3.new(0, 0, D.RUN_SPEED)
		run(1)
		assert(a.flee == 0, "not in combat filled " .. a.flee)
		fresh()
		rootB.CFrame = CFrame.new(ORIGIN + Vector3.new(0, 0, -(F.range + 5)))
		run(1)
		assert(a.flee == 0, "out of range filled " .. a.flee)
		rootA.AssemblyLinearVelocity = Vector3.zero
		A:SetAttribute("Flee", nil)
		A:SetAttribute("FleeLocked", nil)
	end)

	test("in combat: 10 damage exchanged links two fighters, hits keep it up, the timeout ends it", function()
		local CombatTag = Paths.server("CombatTag")
		setup()
		run(STEP) -- CombatTag's clock
		assert(not CombatTag.inCombat(a, v), "in combat before anything happened")
		-- Hits until the exchanged damage reaches the threshold (M1 damage from data).
		local hits = math.ceil(D.COMBAT.threshold / M1.damage)
		for i = 1, hits do
			if i < hits then
				assert(not CombatTag.inCombat(a, v), `in combat after {i - 1} hit(s)`)
			end
			humB.Health = humB.MaxHealth
			assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
			run(M1.startup + 0.01)
			assert(last() and last().r == Result.Hit, "M1 didn't land")
			run(M1.endlag + D.COMBO_END_DELAY + 0.6)
		end
		assert(CombatTag.inCombat(a, v) and CombatTag.inCombat(v, a), "not in combat after the threshold")
		assert(A:GetAttribute("InCombat") == true and B:GetAttribute("InCombat") == true, "InCombat attribute")
		local foes = A:FindFirstChild("CombatWith")
		assert(foes and #foes:GetChildren() == 1 and (foes:GetChildren()[1] :: ObjectValue).Value == B, "CombatWith folder")
		-- Quiet for the timeout: over, and replicated.
		run(D.COMBAT.timeout + 0.1)
		assert(not CombatTag.inCombat(a, v), "combat outlived its timeout")
		assert(A:GetAttribute("InCombat") == nil and #A:FindFirstChild("CombatWith"):GetChildren() == 0, "combat state not cleared")
	end)

	test("style guardMax: Feng starts, regens and restores against its own max", function()
		local GuardSystem = Paths.server("GuardSystem")
		assert(feng.guardMax < style.guardMax, "Feng guardMax should be below Basic's")
		setupFeng(0)
		assert(near(a.guard, feng.guardMax) and A:GetAttribute("GuardMax") == feng.guardMax, "start guard " .. a.guard)
		GuardSystem.breakGuard(a, clock)
		assert(near(a.guard, feng.guardMax * D.GUARD_BREAK_RESTORE), "restore " .. a.guard)
		a.guardRegenPausedUntil = 0
		run(feng.guardMax / D.GUARD_REGEN_PER_SEC + 1)
		assert(near(a.guard, feng.guardMax), "regen went past Feng's max: " .. a.guard)
		assert(near(v.guard, style.guardMax), "Basic fighter guard " .. v.guard)
	end)

	test("Two Left Feet: every block is a weak guard; a parry-window block parry-stuns the attacker but still strips", function()
		-- Not on any style right now (taken off Feng 2026-10-29): the victim gets its mods directly.
		local mods = Paths.perk("TwoLeftFeet").mods
		local function asFengVictim()
			setup()
			Registry.remove(B)
			v = Registry.add(B, nil, feng, clock)
			only = { [a] = true, [v] = true }
			Paths.server("Fighter").addMods(v, mods, 1)
		end
		-- A fresh, short block (normally Blocked) is a weak guard.
		asFengVictim()
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		CombatService.requestAttack(a, "M1", clock, false)
		run(M1.startup + 0.01)
		assert(last() and last().r == Result.Strip, "short block: expected Strip, got " .. tostring(last() and last().r))
		assert(a.state ~= State.ParryStun and not last().info.parried, "outside the window shouldn't parry")
		-- Guard regen pause is cut.
		assert(v.guardRegenPausedUntil <= clock + D.GUARD_REGEN_DELAY * (1 - mods.guardRegenDelayCut) + 1e-3, "regen pause not cut")
		-- Parry window: the attacker is parry-stunned, the Feng still takes the weak guard (no real parry).
		asFengVictim()
		CombatService.requestAttack(a, "M1", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03)
		CombatService.requestBlock(v, true, clock, clock, false)
		run(0.07)
		assert(last() and last().r == Result.Strip and last().info.parried == true, "parry window: expected parried Strip, got " .. tostring(last() and last().r))
		assert(a.state == State.ParryStun and near(a.stateEndsAt - a.stateStartedAt, D.PARRY_STUN), "attacker " .. a.state)
		assert(v.state == State.BlockRecovery and v.stripPending and v.guard < feng.guardMax, "victim didn't take the weak guard")
		assert(not v.parryUnguard and near(v.adrenaline, 0), "clumsy parry gave real-parry rewards")
		run(M1.blockstun + 0.02)
		assert(v.state == State.Idle and v.blockCooldownUntil > clock, "strip didn't drop the block")
	end)

	test("Chambered Dash: fills only off cooldown, gives one extra dash after the normal one", function()
		local PerkService = Paths.server("PerkService")
		local PERK = Paths.perk("ChamberedDash")
		setupFeng(0)
		local chamber = PerkService.state(a, "ChamberedDash")
		assert(chamber and a.bonusDashes == 0, "perk not attached / chamber pre-filled")
		assert(PerkService.state(v, "ChamberedDash") == nil, "Basic fighter got a Feng perk")
		run(PERK.fillTime + 0.05)
		assert(a.bonusDashes == PERK.charges and A:GetAttribute("Chamber") == 1, "chamber did not fill")
		local dashTotal = D.DASH_DURATION + D.DASH_ENDLAG + 0.02
		assert(CombatService.requestDash(a, Vector3.xAxis, "Front", clock, clock, false), "normal dash refused")
		assert(a.bonusDashes == PERK.charges and a.dashCooldownUntil > clock, "normal dash spent the chamber")
		run(dashTotal)
		assert(CombatService.requestDash(a, Vector3.xAxis, "Front", clock, clock, false), "chambered dash refused")
		assert(a.bonusDashes == 0, "chambered dash not spent")
		run(dashTotal)
		assert(not CombatService.requestDash(a, Vector3.xAxis, "Front", clock, clock, false), "third dash allowed")
		-- No filling while the normal dash is on cooldown; filling resumes after it.
		run(a.dashCooldownUntil - clock - 0.05)
		assert(chamber.progress == 0, "filled during cooldown: " .. chamber.progress)
		run(0.05 + PERK.fillTime / 2)
		assert(chamber.progress > 0.4 and chamber.progress < 0.6, "progress " .. chamber.progress)
	end)

	test("lag comp: a hitbox hits where the victim was, not where it is now", function()
		local LagComp = Paths.server("LagComp")
		setup()
		local before = clock
		LagComp.record(v, clock) -- B 3 studs in front of A: inside the M1 box
		clock += 0.2
		rootB.CFrame += Vector3.new(30, 0, 0) -- B has since moved far away
		LagComp.record(v, clock)
		local box, cands = M1.hitbox, { B }
		assert(LagComp.rewind(a, v) == 0, "server-run attackers should not rewind")
		-- Pretend A is a player who sees B `rewind` seconds in the past.
		local realRewind = LagComp.rewind
		local function query(rewind: number): number
			LagComp.rewind = function()
				return rewind
			end
			local ok, n = pcall(LagComp.query, a, rootA.CFrame, box, cands, Registry.get, clock)
			LagComp.rewind = realRewind
			assert(ok, n)
			return #n
		end
		assert(query(0) == 0, "hit B where it is now")
		assert(query(0.2) == 1, "missed B where it was")
		assert(query(0.05) == 0, "75% of the way there should miss")
	end)

	test("stat perks: Tight Guard, Fleet Foot, Keen Eye, Counter Puncher, Reinforced Guard, Opportunist", function()
		local Fighter = Paths.server("Fighter")
		local GuardSystem = Paths.server("GuardSystem")
		local function mods(id: string): any
			return Paths.perk(id).mods
		end
		local noop = function() end
		setup()
		-- Keen Eye + Counter Puncher on a counter.
		Fighter.addMods(a, mods("KeenEye"), 1)
		Fighter.addMods(a, mods("CounterPuncher"), 1)
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Counter, noop)
		assert(near(humB.Health, 100 - M1.damage * (D.COUNTER_MULT + mods("KeenEye").counterDamage)), "keen eye health " .. humB.Health)
		local cp = mods("CounterPuncher")
		assert(near(v.guard, style.guardMax - math.min((100 - humB.Health) * cp.counterGuardRatio, cp.counterGuardCap)), "counter puncher guard " .. v.guard)
		-- A big counter only takes the cap.
		v.guard = style.guardMax
		local big = table.clone(M1) :: any
		big.damage = 50
		HitResolver.applyHit(a, v, big, 1, clock, Result.Counter, noop)
		assert(near(v.guard, style.guardMax - cp.counterGuardCap), "counter puncher cap " .. v.guard)
		humB.Health = 100 - M1.damage * (D.COUNTER_MULT + mods("KeenEye").counterDamage)
		-- Tight Guard on the victim.
		Fighter.addMods(v, mods("TightGuard"), 1)
		local g = v.guard
		GuardSystem.damage(v, 5, 0, clock)
		assert(near(v.guard, g - (5 + mods("TightGuard").guardDamageTaken)), "tight guard " .. v.guard)
		-- Fleet Foot mirrors the run multiplier, and detaching undoes it.
		Fighter.addMods(a, mods("FleetFoot"), 1)
		assert(near(A:GetAttribute("RunSpeedMult") :: number, 1 + mods("FleetFoot").runSpeed), "fleet foot attr")
		Fighter.addMods(a, mods("FleetFoot"), -1)
		assert(near(A:GetAttribute("RunSpeedMult") :: number, 1), "fleet foot detach")

		-- Reinforced Guard: raises max, fills the new space, regen/restore use the new max, detach clamps.
		setup()
		local rg = mods("ReinforcedGuard")
		Fighter.addMods(v, rg, 1)
		local max = style.guardMax + rg.guardMax
		assert(near(v.guard, max) and B:GetAttribute("GuardMax") == max, "reinforced start " .. v.guard)
		GuardSystem.breakGuard(v, clock)
		assert(near(v.guard, max * D.GUARD_BREAK_RESTORE), "reinforced restore " .. v.guard)
		v.guardRegenPausedUntil = 0
		run(max / D.GUARD_REGEN_PER_SEC + 1)
		assert(near(v.guard, max), "reinforced regen " .. v.guard)
		Fighter.addMods(v, rg, -1)
		assert(near(v.guard, style.guardMax) and B:GetAttribute("GuardMax") == style.guardMax, "reinforced detach " .. v.guard)

		-- Opportunist: no bonus on a fresh target, bonus while stunned and just after.
		setup()
		Fighter.addMods(a, mods("Opportunist"), 1)
		local bonus = 1 + mods("Opportunist").stunnedDamage
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(humB.Health, 100 - M1.damage), "opportunist hit a fresh target " .. humB.Health)
		humB.Health = 100
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(humB.Health, 100 - M1.damage * bonus), "opportunist missed a stunned target " .. humB.Health)
		run(v.stateEndsAt - clock + D.RECENT_STUN_WINDOW / 2)
		assert(v.state ~= State.Hitstun, "still stunned")
		humB.Health = 100
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(humB.Health, 100 - M1.damage * bonus), "opportunist missed a just-stunned target " .. humB.Health)
		run(v.stateEndsAt - clock + D.RECENT_STUN_WINDOW * 2)
		humB.Health = 100
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(humB.Health, 100 - M1.damage), "opportunist bonus outlived the window " .. humB.Health)
	end)

	test("trait roll: hit rate and rarity weights hold, never a trait the slot already has", function()
		local PerkRollService = Paths.server("PerkRollService")
		local random = Random.new(1)
		local pool = {}
		local rarityOf = {}
		for _, rarity in { "Common", "Rare", "Epic", "Legendary" } do
			pool[rarity] = {}
			for n = 1, 10 do
				local id = rarity .. n
				table.insert(pool[rarity], id)
				rarityOf[id] = rarity
			end
		end
		local taken = { "Common1", "Rare1" }
		local hits, total, byRarity = 0, 4000, {}
		for _ = 1, total do
			local id = PerkRollService.rollOne(pool, random, taken)
			if id ~= "" then
				assert(not table.find(taken, id), "rolled a trait the slot already has: " .. id)
				hits += 1
				byRarity[rarityOf[id]] = (byRarity[rarityOf[id]] or 0) + 1
			end
		end
		assert(math.abs(hits / total - D.PERK_ROLL_CHANCE) < 0.03, "hit rate " .. hits / total)
		-- Per roll (nothing included): Legendary is the flat chance, the rest shares the remainder.
		local want = Paths.shared("Rarity").tierChances({ Common = true, Rare = true, Epic = true, Legendary = true }, 1 - D.PERK_ROLL_CHANCE)
		assert(want.Legendary == D.ROLL_FIXED_CHANCE.Legendary, "Legendary isn't the flat chance")
		for rarity, p in want do
			if rarity ~= "None" then
				local rate = (byRarity[rarity] or 0) / total
				assert(math.abs(rate - p) < 0.02, rarity .. " rate " .. rate)
			end
		end
		assert(PerkRollService.rollOne({}, random, {}) == "", "empty pool rolled a trait")
		-- REROLL TRAITS rolls all of a slot's traits at once: PERK_SLOTS of them, no duplicates.
		for _ = 1, 500 do
			local slots = PerkRollService.roll(pool, random)
			assert(#slots == D.PERK_SLOTS, "wrong trait count " .. #slots)
			local seen = {}
			for _, id in slots do
				if id ~= "" then
					assert(not seen[id], "duplicate trait " .. id)
					seen[id] = true
				end
			end
		end
		-- Style-locked rollable traits only roll on their own style.
		for _, id in Paths.perkIds() do
			local data = Paths.perk(id)
			if data.rollable and data.style then
				for _, ids in PerkRollService.pool("NotAStyle") do
					assert(not table.find(ids, id), id .. " rolls on the wrong style")
				end
			end
		end
	end)

	test("locker: old saves keep what you wore, spare style slots become stored styles, other gender keeps its hair", function()
		local PlayerData = Paths.server("PlayerData")
		local data = { SchemaVersion = 3, Appearance = { Hat = 111, Hair = 222 }, Gender = "Male", StoredLooks = { Female = { Hat = 333, Hair = 444 } },
			Style = "Feng", PerkSlots = { "TightGuard", "", "KeenEye" }, StyleSlots = {}, EquippedSlot = 9, ExtraSlots = 0, Loadout = {}, Locker = {} }
		PlayerData.migrate(data)
		assert(data.Style == nil and data.PerkSlots == nil, "old fields left behind")
		-- v5: every Dev-tab title is taken back (owner-only from now on)
		local titled = { SchemaVersion = 4, Appearance = {}, StoredLooks = {}, StyleSlots = {}, EquippedSlot = 1, ExtraSlots = 0, Title = "Staff", Loadout = {}, Locker = {} }
		PlayerData.migrate(titled)
		assert(titled.Title == "" and titled.SchemaVersion >= 5, "v5 should clear the saved title, got " .. tostring(titled.Title))
		local worn = data.Loadout
		assert(worn.Style == "Feng" and worn.Traits[1] == "TightGuard" and worn.Traits[3] == "KeenEye", "lost the worn style")
		assert(worn.Appearance.Hat == 111 and worn.Appearance.Hair == 222 and worn.Gender == "Male", "lost the worn look")
		assert(worn.Shelf.Female and worn.Shelf.Female.Hair == 444 and worn.Shelf.Female.Hat == nil, "the other gender should keep only its hair")
		assert(#worn.Locks == D.PERK_SLOTS and worn.Locks[1] == false, "locks not filled")
		assert(#data.Locker == D.LOCKER_SLOTS and data.Locker[1].Kind == "", "locker should be LOCKER_SLOTS empty slots")
		for _, k in { "StyleSlots", "EquippedSlot", "Appearance", "Gender", "StoredLooks", "Lockers", "EquippedLocker" } do
			assert(data[k] == nil, "pre-locker field left behind: " .. k)
		end
		-- a v6 save with 3 lockers: the equipped one is worn, the others' styles are stored
		local v6 = { SchemaVersion = 6, ExtraSlots = 0, Loadout = {}, Locker = {}, EquippedLocker = 2, Lockers = {
			{ Style = "Karate", Traits = { "", "", "" }, Locks = {}, Appearance = { Hat = 1 }, Gender = "Male", Shelf = {} },
			{ Style = "Feng", Traits = { "KeenEye", "", "" }, Locks = { true }, Appearance = { Hat = 2 }, Gender = "Female", Shelf = {} },
			{ Style = "", Traits = { "", "", "" }, Locks = {}, Appearance = { Hat = 3 }, Gender = "Male", Shelf = {} },
		} }
		PlayerData.migrate(v6)
		assert(v6.Loadout.Style == "Feng" and v6.Loadout.Appearance.Hat == 2 and v6.Loadout.Locks[1] == true, "v6: the equipped locker should be worn")
		assert(v6.Locker[1].Kind == "Style" and v6.Locker[1].Style == "Karate" and v6.Locker[2].Kind == "", "v6: only the other non-blank style should be stored")
		v6.ExtraSlots = 2
		PlayerData.fitLocker(v6)
		assert(#v6.Locker == D.LOCKER_SLOTS + 2, "bought slots not added")
	end)

	test("locker: store an item, reroll a new one, swap between them; styles keep their traits", function()
		local PlayerData = Paths.server("PlayerData")
		local RerollService = Paths.server("RerollService")
		local data = { SchemaVersion = 7, ExtraSlots = 0, Loadout = { Style = "Feng", Traits = { "KeenEye", "", "" }, Locks = { true },
			Appearance = { Hat = 1080949, Hair = 0, SkinTone = "Brown" }, Gender = "Male", Shelf = {} }, Locker = {} }
		PlayerData.migrate(data)
		assert(RerollService.store(data, "Hat") == 1, "store the hat")
		assert(data.Loadout.Appearance.Hat == 0 and data.Locker[1].Id == 1080949, "the hat should move into slot 1")
		assert(RerollService.store(data, "Hair") == nil, "can't store nothing")
		assert(RerollService.store(data, "SkinTone") == nil, "skin tone isn't an item")
		data.Loadout.Appearance.Hat = 555 -- "rerolled" a second hat
		assert(RerollService.swap(data, 1) == "Hat", "swap in")
		assert(data.Loadout.Appearance.Hat == 1080949 and data.Locker[1].Id == 555, "swapping should trade the two hats")
		assert(RerollService.store(data, "Style") == 2, "store the style")
		assert(data.Loadout.Style == "" and data.Loadout.Traits[1] == "" and data.Loadout.Locks[1] == false, "worn style should be blank after storing")
		assert(data.Locker[2].Style == "Feng" and data.Locker[2].Traits[1] == "KeenEye" and data.Locker[2].Locks[1] == true, "stored style lost its traits / locks")
		assert(RerollService.store(data, "Style") == nil, "a blank style can't be stored")
		assert(RerollService.swap(data, 2) == "Style" and data.Loadout.Style == "Feng" and data.Locker[2].Kind == "", "swapping a blank style back should empty the slot")
		assert(RerollService.swap(data, 3) == nil, "an empty slot can't be swapped in")
		data.Loadout.Appearance.Face = 144075659
		for _ = 1, #data.Locker do
			RerollService.store(data, if data.Loadout.Style ~= "" then "Style" else "Face")
			data.Loadout.Style = "Feng" -- something to store again
		end
		data.Loadout.Appearance.Hat = 1080949
		assert(RerollService.store(data, "Hat") == nil, "a full locker must refuse")
	end)

	test("trait locks: locked traits stay, no duplicates, cost x10 per lock, all locked refused", function()
		local PerkRollService = Paths.server("PerkRollService")
		local random = Random.new(7)
		local pool = PerkRollService.pool(D.DEFAULT_STYLE)
		local keep = { "TightGuard", "", "KeenEye" }
		for _ = 1, 300 do
			local rolled = PerkRollService.roll(pool, random, keep, { true, false, true })
			assert(rolled[1] == "TightGuard" and rolled[3] == "KeenEye", "a locked trait changed")
			assert(rolled[2] ~= "TightGuard" and rolled[2] ~= "KeenEye", "rolled a duplicate of a locked trait: " .. rolled[2])
		end
		local function locker(locks)
			return { Locks = locks }
		end
		assert(PerkRollService.lockCost(locker({ false, false, false })) == 1, "no locks should cost 1")
		assert(PerkRollService.lockCost(locker({ true, false, false })) == D.TRAIT_LOCK_MULT, "1 lock")
		assert(PerkRollService.lockCost(locker({ true, true, false })) == D.TRAIT_LOCK_MULT ^ 2, "2 locks")
		assert(PerkRollService.lockCost(locker({ true, true, true })) == nil, "all locked must refuse")
	end)

	test("rarity pick: mythic rate, never the current item, appearance data is valid", function()
		local Rarity = Paths.shared("Rarity")
		local Appearance = Paths.data("Appearance")
		local random = Random.new(2)
		local items = { { id = "c", rarity = "Common" }, { id = "m", rarity = "Mythic" } }
		local mythics, n = 0, 200000
		for _ = 1, n do
			if Rarity.pick(items, random).id == "m" then
				mythics += 1
			end
		end
		local M = D.ROLL_FIXED_CHANCE.Mythic
		assert(math.abs(mythics / n - M) < M * 0.5, "mythic rate " .. mythics / n)
		-- Legendary is a flat 1% no matter what else is in the pool.
		for _, pool in { { "Common" }, { "Common", "Rare", "Epic" }, { "Epic", "Mythic" } } do
			local present = { Legendary = true }
			for _, r in pool do
				present[r] = true
			end
			local c = Rarity.tierChances(present)
			assert(math.abs(c.Legendary - D.ROLL_FIXED_CHANCE.Legendary) < 1e-12, "legendary chance " .. c.Legendary)
			if present.Mythic then
				assert(math.abs(c.Mythic - M) < 1e-12, "mythic chance " .. c.Mythic)
			end
		end
		local commons = { { id = "a", rarity = "Common" }, { id = "b", rarity = "Common" } }
		for _ = 1, 200 do
			assert(Rarity.pick(commons, random, "a").id == "b", "rerolled onto the current item")
		end
		-- Excluding the only non-Mythic must NOT turn every reroll into a Mythic.
		local freeMythics = 0
		for _ = 1, 4000 do
			if Rarity.pick(items, random, "c").id == "m" then
				freeMythics += 1
			end
		end
		assert(freeMythics / 4000 < M * 5, "excluding the only non-Mythic handed out Mythics: " .. freeMythics)
		assert(Rarity.pick({ { id = "c" } }, random, "c").id == "c", "a one-item pool must still land")
		assert(Rarity.pick({}, random) == nil, "empty pool picked something")
		-- odds() (the dev Catalog %) must match what pick() really does.
		local mixed = {
			{ id = 1, rarity = "Common" }, { id = 2, rarity = "Common" }, { id = 3, rarity = "Rare" },
			{ id = 4, rarity = "Legendary" }, { id = 5, rarity = "Mythic" },
		}
		local odds = Rarity.odds(mixed)
		local sum, hitsById = 0, {}
		for _, p in odds do
			sum += p
		end
		assert(math.abs(sum - 1) < 1e-9, "odds don't sum to 1: " .. sum)
		for _ = 1, 40000 do
			local id = Rarity.pick(mixed, random).id
			hitsById[id] = (hitsById[id] or 0) + 1
		end
		for i, item in mixed do
			local rate = (hitsById[item.id] or 0) / 40000
			assert(math.abs(rate - odds[i]) < 0.015, `odds {odds[i]} vs real {rate} for {item.rarity}`)
		end
		assert(Rarity.odds({ { id = 1, rarity = "Mythic" } })[1] == 1, "an all-Mythic pool always lands")
		-- A `none` chance only shares the non-fixed part: Mythic/Legendary stay flat per roll.
		local withNone, noneP = Rarity.odds(mixed, 0.5)
		assert(math.abs(withNone[5] - D.ROLL_FIXED_CHANCE.Mythic) < 1e-12, "mythic diluted by none: " .. withNone[5])
		assert(math.abs(withNone[4] - D.ROLL_FIXED_CHANCE.Legendary) < 1e-12, "legendary diluted by none: " .. withNone[4])
		local s2 = noneP
		for _, p in withNone do
			s2 += p
		end
		assert(math.abs(s2 - 1) < 1e-9, "odds + none don't sum to 1: " .. s2)
		local nones = 0
		for _ = 1, 40000 do
			if Rarity.pick(mixed, random, nil, 0.5) == Rarity.NONE then
				nones += 1
			end
		end
		assert(math.abs(nones / 40000 - noneP) < 0.015, `none rate {nones / 40000} vs {noneP}`)
		for _, slot in Appearance.order do
			local def = Appearance.slots[slot]
			assert(def and #def.items > 0, slot .. " has no items")
			for _, item in def.items do
				assert(Rarity.COLORS[item.rarity], `{slot} {item.name} has bad rarity {item.rarity}`)
				if slot == "SkinTone" then
					assert(BrickColor.new(item.id).Name == item.id, "bad BrickColor " .. item.id)
				end
				assert(item.gender == nil or table.find(D.GENDERS, item.gender), `{slot} {item.name} has bad gender {item.gender}`)
			end
			assert(slot == "SkinTone" or def.types, slot .. " needs dev `types`")
			for _, g in D.GENDERS do
				local pool = Appearance.eligible(slot, g)
				assert(#pool > 0, `{slot} has nothing for {g}`)
				for _ = 1, 50 do
					local item = Rarity.pick(pool, random)
					assert(item.gender == nil or item.gender == g, `{g} rolled {item.name}`)
				end
			end
		end

		-- Gender swap (lockers, user 2026-10-22): everything carries over except perGender slots (hair),
		-- which each gender keeps on the locker's Shelf; swapping away and back restores them exactly.
		local RerollService = Paths.server("RerollService")
		local data = { Gender = "Male", Appearance = {}, Shelf = {} }
		RerollService.fillLook(data, random)
		local male = table.clone(data.Appearance)
		RerollService.swapLook(data, "Female", random)
		assert(data.Gender == "Female" and data.Shelf.Male, "male hair wasn't shelved")
		for _, slot in Appearance.order do
			assert(data.Appearance[slot] ~= nil, "female look missing " .. slot)
			if Appearance.slots[slot].perGender then
				local item = nil
				for _, it in Appearance.slots[slot].items do
					if it.id == data.Appearance[slot] then
						item = it
					end
				end
				assert(not item or item.gender ~= "Male", "female look rolled male-only " .. slot)
			else
				assert(data.Appearance[slot] == male[slot], slot .. " should carry over to the other gender")
			end
		end
		local female = table.clone(data.Appearance)
		RerollService.swapLook(data, "Male", random)
		RerollService.swapLook(data, "Female", random)
		RerollService.swapLook(data, "Male", random)
		for _, slot in Appearance.order do
			assert(data.Appearance[slot] == male[slot], "male look changed at " .. slot)
			if Appearance.slots[slot].perGender then
				assert(data.Shelf.Female[slot] == female[slot], "female hair changed at " .. slot)
			end
		end

		-- Skateboard speed: faster drains faster, air halves it, walls drain, downhill speeds you up
		-- only under slopeCap, uphill slows, never below 0 or over maxSpeed.
		local SkateMath = Paths.shared("SkateMath")
		local SK = D.SKATE
		local dt = 1 / 60
		assert(SkateMath.decayRate(45) > SkateMath.decayRate(22) and SkateMath.decayRate(22) > SkateMath.decayRate(5), "faster should drain faster")
		local flat = SkateMath.step(30, dt, true, 0, false)
		assert(math.abs((30 - flat) - SkateMath.decayRate(30)) < 1e-9, "ground decay")
		assert(math.abs((30 - SkateMath.step(30, dt, false, 0, false)) - SkateMath.decayRate(30) / 2) < 1e-9, "air should halve decay")
		assert(SkateMath.step(30, dt, true, 0, true) < flat, "a wall should drain")
		assert(SkateMath.step(10, dt, true, -0.5, false) > 10, "downhill under the cap should speed up")
		assert(SkateMath.step(30, dt, true, -0.5, false) == flat, "downhill over the cap does nothing")
		assert(SkateMath.step(10, dt, true, 0.5, false) < SkateMath.step(10, dt, true, 0, false), "uphill should slow")
		assert(SkateMath.step(0.01, dt, true, 0, true) == 0 and SkateMath.step(SK.maxSpeed + 50, dt, true, -1, false) <= SK.maxSpeed, "speed clamp")
		assert(math.abs(SkateMath.uphill(Vector3.yAxis, Vector3.zAxis)) < 1e-9, "flat ground isn't uphill")
		assert(SkateMath.uphill(Vector3.new(0, 1, -1).Unit, Vector3.zAxis) > 0, "a slope rising ahead is uphill")

		-- Emote wheel: fill gives every slot a real, distinct emote (removed ids and doubles re-rolled,
		-- valid ones kept), and a slot's pool never holds another slot's emote.
		local Emotes = Paths.data("Emotes")
		assert(#Emotes.items > Emotes.SLOTS, "need more emotes than wheel slots")
		for trial = 1, 100 do
			local ed = { Emotes = if trial % 2 == 0 then {} else { "Wave", "Gone", "Wave", "" } }
			RerollService.fillEmotes(ed, random)
			assert(#ed.Emotes == Emotes.SLOTS, "emote slots " .. #ed.Emotes)
			assert(trial % 2 == 0 or ed.Emotes[1] == "Wave", "a valid emote got re-rolled")
			for n = 1, Emotes.SLOTS do
				assert(ed.Emotes[n] ~= "" and table.find(ed.Emotes, ed.Emotes[n]) == n, "empty or double emote " .. tostring(ed.Emotes[n]))
				for _, item in RerollService.emotePool(ed.Emotes, n) do
					local at = table.find(ed.Emotes, item.id)
					assert(at == nil or at == n, `slot {n} pool has slot {at}'s emote`)
				end
			end
		end

		-- Shirts/pants aren't slots (no rerolls / Catalog): unset = the gender's D.UNIFORM, whatever the
		-- base (their own avatar) says; a dev-set id overrides it (0 = nothing).
		assert(Appearance.slots.Shirt == nil and Appearance.slots.Pants == nil, "shirts/pants came back as appearance slots")
		local base = Instance.new("HumanoidDescription")
		base.Shirt, base.Pants = 111, 222
		local d1 = RerollService.describe(base, {}, "Male")
		assert(d1.Shirt == D.UNIFORM.Male.Shirt and d1.Pants == D.UNIFORM.Male.Pants, `male should wear the uniform, got {d1.Shirt}/{d1.Pants}`)
		local d2 = RerollService.describe(base, {}, "Female")
		assert(d2.Shirt == D.UNIFORM.Female.Shirt and d2.Pants == D.UNIFORM.Female.Pants, `female should wear the uniform, got {d2.Shirt}/{d2.Pants}`)
		local d3 = RerollService.describe(base, { Shirt = 333, Pants = 0 }, "Male")
		assert(d3.Shirt == 333 and d3.Pants == 0, `dev-set clothes should override the uniform, got {d3.Shirt}/{d3.Pants}`)
		-- Accessories go to the field of their real catalog type (UGC is often Neck/Shoulder/Front/Waist),
		-- and every accessory field is rebuilt (no leftovers from the base / own avatar).
		base.NeckAccessory = "999"
		local types = { [111111] = 43, [222222] = 8 } -- a Neck item in the Hat slot, a real hat in Back
		local d4 = RerollService.describe(base, { Hat = 111111, BackAccessory = 222222 }, "Male", function(id)
			return types[id]
		end)
		assert(d4.NeckAccessory == "111111", `neck UGC should load as a neck accessory, got '{d4.NeckAccessory}'`)
		assert(d4.HatAccessory == "222222" and d4.BackAccessory == "", `routing wrong: hat '{d4.HatAccessory}' back '{d4.BackAccessory}'`)
		for _, d in { base, d1, d2, d3, d4 } do
			d:Destroy()
		end

		-- Empty rolls: each slot's `none` chance, never "nothing again" when you already have nothing.
		for _, slot in Appearance.order do
			local none = Appearance.slots[slot].none
			local empties, rolls = 0, 4000
			for _ = 1, rolls do
				if RerollService.rollSlot(slot, "Male", random, -1) == 0 then
					empties += 1
				end
				assert(RerollService.rollSlot(slot, "Male", random, 0) ~= 0, slot .. " rolled nothing onto nothing")
			end
			assert(math.abs(empties / rolls - (none or 0)) < 0.03, `{slot} empty rate {empties / rolls}, want {none or 0}`)
		end
	end)

	test("traits: Close Call, Technical, Brick Wall, Calm The Nerves", function()
		local Fighter = Paths.server("Fighter")
		local PerkService = Paths.server("PerkService")
		local function mods(id: string): any
			return Paths.perk(id).mods
		end
		local noop = function() end

		-- Close Call: dodge adrenaline +40%.
		setup()
		Fighter.addMods(v, mods("CloseCall"), 1)
		CombatService.requestAttack(a, "M1", clock, false)
		run(0.17)
		assert(CombatService.requestDash(v, Vector3.xAxis, "Front", clock, clock, false))
		run(0.12)
		assert(near(v.adrenaline, D.ADR_GAIN_DODGE * (1 + mods("CloseCall").dodgeAdrenaline)), "close call adrenaline " .. v.adrenaline)

		-- Technical: landing an M2 cuts a fraction of the crit's full cooldown off what's left.
		setup()
		Fighter.addMods(a, mods("Technical"), 1)
		local crit = style.moves[style.r]
		a.rCooldownUntil = clock + crit.cooldown
		local before = clock
		CombatService.requestAttack(a, "M2", clock, false)
		run(M2.startup + 0.02)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
		local expected = before + crit.cooldown - crit.cooldown * mods("Technical").m2RCooldownCut
		assert(math.abs(a.rCooldownUntil - expected) < 1e-3, ("technical cooldown ends %.2f, expected %.2f"):format(a.rCooldownUntil - before, expected - before))
		assert(A:GetAttribute("RCooldownUntil") == a.rCooldownUntil, "cooldown attribute not mirrored")

		-- Brick Wall: 2% per hit taken, own timers, capped at 20%.
		setup()
		local BW = Paths.perk("BrickWall")
		PerkService.detach(v)
		v.style = table.clone(style)
		v.style.perks = { "BrickWall" }
		PerkService.attach(v)
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(humB.Health, 100 - M1.damage), "the first hit was reduced")
		assert(near(v.mods.damageReduction, BW.stack), "one stack " .. v.mods.damageReduction)
		humB.Health = 100
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(humB.Health, 100 - M1.damage * (1 - BW.stack)), "second hit not reduced " .. humB.Health)
		run(BW.duration - 0.1)
		humB.Health = 100
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(v.mods.damageReduction, BW.stack * 3), "three stacks " .. v.mods.damageReduction)
		run(0.15) -- the first two stacks expire, the third keeps its own timer
		assert(near(v.mods.damageReduction, BW.stack), "own timers " .. v.mods.damageReduction)
		for _ = 1, 15 do
			HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
			humB.Health = 100
		end
		assert(near(v.mods.damageReduction, BW.stack * BW.maxStacks), "cap " .. v.mods.damageReduction)
		PerkService.detach(v)
		assert(near(v.mods.damageReduction, 0), "detach left " .. v.mods.damageReduction)

		-- Calm The Nerves: heal a flat amount x adrenaline ratio at attack start.
		setup()
		Fighter.addMods(a, mods("CalmTheNerves"), 1)
		humA.Health = 50
		a.healable = 50 -- heals only refill healable HP
		a.lastHitTakenAt = math.huge -- no passive regen in between
		a.attackAdrRatio = 0.5
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(humA.Health, 50 + mods("CalmTheNerves").adrenalineHeal * 0.5), "calm the nerves heal " .. humA.Health)
		a.attackAdrRatio = 0
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(humA.Health, 50 + mods("CalmTheNerves").adrenalineHeal * 0.5), "healed with no adrenaline " .. humA.Health)
	end)

	test("healable HP: keep, regen delay, anti-heal, siphon", function()
		local plain = setmetatable({ antiHeal = 0 }, { __index = M1 })
		local feng = setmetatable({ antiHeal = 0.7 }, { __index = M1 })
		local noop = function() end
		setup()
		v.lastHitTakenAt = clock -- applyHit marks it too; set so the regen delay is measured from here
		HitResolver.applyHit(a, v, plain, 1, clock, Result.Hit, noop)
		assert(near(v.healable, M1.damage * D.HEAL_KEEP), "healable " .. v.healable)
		local hp = humB.Health
		run(D.HEAL_REGEN_DELAY - 0.05)
		assert(near(humB.Health, hp), "regen before the delay " .. humB.Health)
		run(0.5)
		assert(humB.Health > hp and humB.Health <= 100 - M1.damage * (1 - D.HEAL_KEEP) + 1e-3, "regen " .. humB.Health)

		-- Partial anti-heal shrinks the pool and the hit's own part.
		local pool = v.healable
		v.adrenaline = 0 -- no adrenaline anti-heal resist here (tested on its own)
		HitResolver.applyHit(a, v, feng, 1, clock, Result.Hit, noop)
		assert(near(v.healable, (pool + M1.damage * D.HEAL_KEEP) * 0.3), "feng anti-heal " .. v.healable)
		-- Full anti-heal wipes it.
		v.adrenaline = 0
		HitResolver.applyHit(a, v, setmetatable({ antiHeal = 1 }, { __index = M1 }), 1, clock, Result.Hit, noop)
		assert(v.healable == 0, "full anti-heal left " .. v.healable)
		-- Hits cap the pool at D.HEAL_MAX.
		for _ = 1, 10 do
			HitResolver.applyHit(a, v, plain, 1, clock, Result.Hit, noop)
		end
		assert(near(v.healable, math.min(D.HEAL_MAX, 100 - humB.Health)), "cap " .. v.healable)

		-- Siphon: a kill makes all missing HP healable and heals D.SIPHON.heal fast.
		setup()
		humA.Health = 40
		a.lastHitTakenAt = math.huge -- isolate the siphon from passive regen
		humB.Health = 1
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(a.healable, 60) and near(a.siphonLeft, D.SIPHON.heal), "siphon pool " .. a.healable)
		run(D.SIPHON.duration + 0.05)
		assert(near(humA.Health, 40 + D.SIPHON.heal, 0.01) and near(a.healable, 60 - D.SIPHON.heal, 0.01), "siphon heal " .. humA.Health)
		humB.Health = humB.MaxHealth
	end)

	test("cutscene: actors frozen + untouchable for the duration, then Idle", function()
		local CutsceneService = Paths.server("CutsceneService")
		local noop = function() end
		setup()
		local def = Paths.data("Cutscenes").Test
		assert(CutsceneService.play1v1("Test", a, v, clock), "cutscene refused")
		assert(a.state == State.Cutscene and v.state == State.Cutscene, "actors not in the cutscene state")
		assert(not CutsceneService.play1v1("Test", a, v, clock), "a second cutscene started on busy actors")
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(near(humB.Health, humB.MaxHealth), "hit landed during a cutscene")
		assert(HitResolver.resolve(a, v, M1, clock, noop, true) == nil, "resolve should miss a cutscene actor")
		assert(not CombatService.requestAttack(a, "M1", clock, false), "attacked during a cutscene")
		run(def.duration - 0.1)
		assert(a.state == State.Cutscene, "cutscene ended early")
		run(0.2)
		assert(a.state == State.Idle and v.state == State.Idle, "actors should be Idle after it, got " .. a.state .. " / " .. v.state)
		assert(not CutsceneService.play1v1("Nope", a, v, clock), "unknown cutscene id played")
	end)

	test("ProdigyCrit: 30 damage total, keys in order, finisher before the camera heads home", function()
		local def = Paths.data("Cutscenes").ProdigyCrit
		local total = def.finisher.damage
		for _, h in def.hits do
			total += h.damage
		end
		assert(near(total, 30), "total damage " .. total)
		assert(def.antiHeal == 1, "anti-heal should be 100%")
		local prev = -1
		for _, k in def.camera do
			assert(k.t >= prev, "camera keys out of order at " .. k.t)
			prev = k.t
		end
		assert(def.finisher.t < def.duration - def.returnTime, "finisher lands during the return pan")
		assert(def.duration == 14, "the cutscene (and its music) must end at 14s")
		assert(MoveSchema.style("Prodigy").moves.Reentry.cutscene == "ProdigyCrit", "Prodigy's crit doesn't play it")
		local m1s = 0
		for _, cue in def.actors.victim.cues do
			m1s += if cue.m1 then 1 else 0
		end
		assert(m1s == 3, "the victim should throw 3 M1s, got " .. m1s)
	end)

	test("Slugger M2: hold to charge; tap 4 / 10%, 0.6s 8 / 50%, auto release at 1s 8 / 100% + guard break", function()
		local sl = MoveSchema.style("Slugger")
		local SM2 = sl.moves[sl.m2]
		local hit = SM2.charge.swing.hit
		local function asSlugger()
			setup()
			Registry.remove(A)
			a = Registry.add(A, nil, sl, clock)
			only = { [a] = true, [v] = true }
		end
		-- `hold` nil = tap; else release after that long (math.huge = never: auto release).
		local function swing(hold: number?, expectDmg: number, antiHeal: number)
			asSlugger()
			a.chargeHeld = if hold then "M2" else nil
			assert(CombatService.requestAttack(a, "M2", clock, false), "M2 refused")
			local t0 = clock
			if hold and hold ~= math.huge then
				run(hold)
				CombatService.releaseCharge(a, "M2", clock)
			end
			local releaseAt = if hold == nil then SM2.startup elseif hold == math.huge then SM2.startup + SM2.charge.time else math.max(SM2.startup, hold)
			assert(near(a.hitboxAt - t0, releaseAt + hit, 1e-3), `hit at {a.hitboxAt - t0}, expected {releaseAt + hit}`)
			run(a.hitboxAt - clock + 0.01)
			assert(last() and last().r == Result.Hit, `hold {hold}: no hit`)
			assert(near(last().info.damage, expectDmg), `hold {hold}: damage {last().info.damage}`)
			assert(near(v.healable, math.min(D.HEAL_MAX, expectDmg * D.HEAL_KEEP * (1 - antiHeal))), `hold {hold}: healable {v.healable}`)
		end
		-- Numbers from the data's tiers (balance changes don't break this); the timings are the test.
		local T = SM2.charge.tiers
		swing(nil, T[1].damage, T[1].antiHeal)
		swing(0.3, T[1].damage, T[1].antiHeal) -- released early: still the tap
		swing(0.7, T[2].damage, T[2].antiHeal)
		swing(math.huge, T[3].damage, T[3].antiHeal)
		-- Full charge breaks a held block; a 0.6s one is just blocked (or strips the now-weak guard).
		for _, case in { { hold = 0.7, r = { [Result.Blocked] = true, [Result.Strip] = true } }, { hold = math.huge, r = { [Result.GuardBreak] = true } } } do
			asSlugger()
			CombatService.requestBlock(v, true, clock, clock, false)
			run(D.BLOCK_START_DURATION + 0.05)
			a.chargeHeld = "M2"
			assert(CombatService.requestAttack(a, "M2", clock, false), "M2 refused")
			if case.hold ~= math.huge then
				run(case.hold)
				CombatService.releaseCharge(a, "M2", clock)
			end
			run(a.hitboxAt - clock + 0.01)
			assert(last() and case.r[last().r], `hold {case.hold}: got {last() and last().r}`)
		end
	end)

	test("Slugger Critical: 0.4 to hit, 0.7 stun, strips (no GB), unparryable, no counter / cancel, no slow zone", function()
		local sl = MoveSchema.style("Slugger")
		local crit = sl.moves[sl.r]
		assert(crit.hitbox.shape == "Cylinder" and crit.hitbox.radius == 10, "crit hitbox radius changed")
		assert(not crit.slowZone, "crit still drops a slow zone (removed, user 2026-10-31)")
		local function asSlugger()
			setup()
			Registry.remove(A)
			a = Registry.add(A, nil, sl, clock)
			only = { [a] = true, [v] = true }
			A:SetAttribute("SlowZoneAt", nil)
			B:SetAttribute("SlowZoneAt", nil)
		end
		asSlugger()
		assert(CombatService.requestAttack(a, "R", clock, false), "crit refused")
		assert(near(a.hitboxAt - clock, 0.4, 1e-3), "crit hit at " .. (a.hitboxAt - clock))
		run(0.41)
		assert(last() and last().r == Result.Hit, "crit didn't land")
		assert(near(v.stateEndsAt - v.stateStartedAt, 0.7, 1e-3), "stun " .. (v.stateEndsAt - v.stateStartedAt))
		assert(not CombatMath.inSlowZone(A, rootA.Position, clock) and not CombatMath.inSlowZone(B, rootB.Position, clock), "a slow zone dropped")
		-- Blocked: unparryable (user, 2026-10-31), so a fresh press and a held block both get stripped.
		for _, lead in { 0.05, D.BLOCK_START_DURATION + 0.05 } do
			asSlugger()
			assert(CombatService.requestAttack(a, "R", clock, false), "crit refused")
			run(crit.startup - lead)
			CombatService.requestBlock(v, true, clock, clock, false)
			run(lead + 0.01)
			assert(last() and last().r == Result.Strip, `block {lead}s before: got {last() and last().r}`)
		end
		-- Mid-attack victim: no counter, no cancel. They take the damage, keep their M1, and it still lands.
		asSlugger()
		assert(CombatService.requestAttack(a, "R", clock, false), "crit refused")
		run(crit.startup - 0.1)
		assert(CombatService.requestAttack(v, "M1", clock, false), "victim M1 refused")
		local vHitAt = v.hitboxAt
		run(0.11)
		local e = last()
		assert(e and e.a == A and e.r == Result.Hit, `crit on a mid-attack victim: got {e and e.r}`)
		assert(e.info.damage > 0 and near(e.info.damage, crit.damage, 0.5), "crit damage " .. e.info.damage)
		assert(v.state == State.Startup and v.hitboxAt == vHitAt, "the crit cancelled the victim's M1")
		run(vHitAt - clock + 0.01)
		e = last()
		assert(e and e.a == B and e.v == A, "the victim's M1 never landed")
	end)

	-- Focus (user, 2026-10-23): Prodigy's Astronaut / Spacesuit (style perks) + its rollable traits.
	local prodigy = MoveSchema.style("Prodigy")
	local F = D.FOCUS
	local function asProdigy(which: string)
		if which == "a" then
			Registry.remove(A)
			a = Registry.add(A, nil, prodigy, clock)
		else
			Registry.remove(B)
			v = Registry.add(B, nil, prodigy, clock)
		end
		only = { [a] = true, [v] = true }
	end

	test("Focus: dodges give neither Focus nor adrenaline, damage drains it, Spacesuit drains it with adrenaline", function()
		local HealthSystem = Paths.server("HealthSystem")
		setup()
		asProdigy("v")
		assert(v.mods.focus > 0 and B:GetAttribute("FocusOn") == true, "Prodigy should have Focus (Astronaut)")
		assert(CombatService.requestDash(v, Vector3.xAxis, "Side", clock, clock, false), "dash refused")
		assert(CombatService.requestAttack(a, "M1", clock, false))
		run(M1.startup + 0.01)
		assert(near(v.focus, 0), "a dodge gave Focus " .. v.focus)
		assert(near(v.adrenaline, 0), "a Focus dodge gave adrenaline " .. v.adrenaline)
		-- Raw damage no longer costs Focus; being hit by an attack does (flat, by kind).
		v.focus = 50
		HealthSystem.damage(a, v, 5, 0)
		assert(near(v.focus, 50), "raw damage cost Focus " .. v.focus)
		-- Spacesuit: full adrenaline drains adrFocusDrain per second.
		v.focus, v.adrenaline, v.lastHitTakenAt = 50, D.ADR_MAX, clock + 10 -- (no adrenaline drain meanwhile)
		run(1)
		local drain = Paths.perk("Spacesuit").mods.adrFocusDrain
		assert(near(v.focus, 50 - drain, 0.05), "Spacesuit drain: focus " .. v.focus)
	end)

	test("Focus loss: an M1 hit costs 15, M2 / crit 10, a counter x1.5, once per attack; landing a counter gains 5x", function()
		setup()
		asProdigy("v")
		local L = F.hitLoss
		assert(L.M1 == 15 and L.M2 == 10 and L.R == 10 and F.counterGainMult == 5, "hit loss / counter gain numbers changed")
		v.focus = 100
		assert(CombatService.requestAttack(a, "M1", clock, false))
		run(M1.startup + 0.01)
		assert(last() and last().r == Result.Hit, "M1 didn't land")
		assert(near(v.focus, 100 - L.M1), "focus after an M1 " .. v.focus)
		run(M1.endlag + 0.05)
		v.focus, v.adrenaline = 100, 0 -- (the M1 gave adrenaline: Spacesuit would drain through the windup)
		assert(CombatService.requestAttack(a, "M2", clock, false))
		run(M2.startup / a.attackSpeed + 0.01)
		assert(last() and last().r == Result.Hit, "M2 didn't land")
		assert(near(v.focus, 100 - L.M2), "focus after an M2 " .. v.focus)
		-- The same attack connecting again (multi-hit) doesn't charge twice; a counter costs more.
		local noop = function() end
		v.focus = 100
		HitResolver.applyHit(a, v, M2, 1, clock, Result.Hit, noop)
		assert(near(v.focus, 100), "same attack charged twice " .. v.focus)
		a.attackSeq += 1
		HitResolver.applyHit(a, v, M2, 1, clock, Result.Counter, noop)
		assert(near(v.focus, 100 - L.M2 * F.counterLossMult), "focus after being countered " .. v.focus)
		-- Landing a counter as Prodigy gains counterGainMult x hitGain.
		setup()
		asProdigy("a")
		a.focus = 0
		HitResolver.applyHit(a, v, prodigy.moves.M1_1, 1, clock, Result.Counter, noop)
		assert(near(a.focus, F.hitGain * F.counterGainMult), "focus from a landed counter " .. a.focus)
		-- ...but not on an M2: a countering M2 gains the same as any landed M2.
		a.focus = 0
		HitResolver.applyHit(a, v, prodigy.moves[prodigy.m2], 1, clock, Result.Counter, noop)
		assert(near(a.focus, F.m2Gain), "M2 counter got the counter bonus: " .. a.focus)
	end)

	test("Focus: being parried costs 40% of your current Focus", function()
		setup()
		asProdigy("a")
		a.focus, a.adrenaline = 50, 0 -- (no adrenaline: Spacesuit doesn't drain meanwhile)
		CombatService.requestAttack(a, "M2", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03)
		CombatService.requestBlock(v, true, clock, clock, false)
		run(0.07)
		assert(last() and last().r == Result.Parried, "expected Parried, got " .. tostring(last() and last().r))
		assert(near(a.focus, 50 * (1 - F.parriedLoss)) and F.parriedLoss == 0.4, "focus after being parried " .. a.focus)
	end)

	test("Focus: a landed Eject gains 40% of your current Focus, counter or not", function()
		local noop = function() end
		local eject = prodigy.moves.Eject
		for _, r in { Result.Hit, Result.Counter } do
			setup()
			asProdigy("a")
			a.focus = 50
			HitResolver.applyHit(a, v, eject, 1, clock, r, noop)
			assert(near(a.focus, 70), `{r}: focus after Eject {a.focus}`)
		end
	end)

	test("Focus bonuses: full Focus cuts endlag; counters gain Focus damage; Spacesuit takes more", function()
		setup()
		asProdigy("a")
		a.focus = F.max
		local m1 = prodigy.moves.M1_1
		assert(CombatService.requestAttack(a, "M1", clock, false))
		run(m1.startup + 0.001)
		assert(a.state == State.Endlag and near(a.stateEndsAt - a.stateStartedAt, m1.endlag * (1 - F.endlag)), "full-Focus endlag " .. (a.stateEndsAt - a.stateStartedAt))
		assert(near(a.focus, F.max), "hitting at full Focus should stay full") -- (gain clamps)
		-- 60%+ Focus at attack start: M1s deal F.m1Damage.damage (3); below it, their own damage.
		local FocusSystem = Paths.server("FocusSystem")
		a.attackFocus = F.m1Damage.at
		assert(near(FocusSystem.baseDamage(a, m1), 3), "60% Focus M1 damage " .. FocusSystem.baseDamage(a, m1))
		a.attackFocus = F.m1Damage.at - 0.01
		assert(near(FocusSystem.baseDamage(a, m1), m1.damage), "59% Focus M1 damage")
		assert(near(FocusSystem.baseDamage(a, prodigy.moves[prodigy.m2]), prodigy.moves[prodigy.m2].damage), "M2 damage shouldn't drop")
		-- Spacesuit on the victim: a flat +0.35 on the counter multiplier, whatever the adrenaline.
		setup()
		asProdigy("v")
		assert(near(FocusSystem.counterTaken(v), 0.35), "Spacesuit counter taken at 0 adrenaline")
		v.adrenaline = D.ADR_MAX
		assert(near(FocusSystem.counterTaken(v), 0.35), "Spacesuit counter taken at full adrenaline")
	end)

	test("Uppercut to the Moon: full-Focus M2 has a 0.3s windup, 60% less endlag, 50% anti-heal, 15 Focus gain", function()
		local up = Paths.perk("UppercutToTheMoon").mods -- a Prodigy style perk: always on
		setup()
		asProdigy("a")
		a.focus = F.max
		local m2 = prodigy.moves[prodigy.m2]
		assert(CombatService.requestAttack(a, "M2", clock, false))
		assert(near(a.stateEndsAt - clock, up.m2FocusStartup), "M2 windup " .. (a.stateEndsAt - clock))
		run(up.m2FocusStartup + 0.001)
		assert(last() and last().r == Result.Hit, "M2 didn't land")
		assert(near(a.stateEndsAt - a.stateStartedAt, m2.endlag * (1 - F.endlag * 2)), "M2 endlag " .. (a.stateEndsAt - a.stateStartedAt))
		-- 50% anti-heal: the hit keeps only 50% of its healable part.
		assert(near(v.healable, m2.damage * D.HEAL_KEEP * (1 - (m2.antiHeal + F.antiHeal * 2)), 0.01), "M2 anti-heal: healable " .. v.healable)
		-- 3x Focus from a landed M2 (from empty).
		setup()
		asProdigy("a")
		assert(CombatService.requestAttack(a, "M2", clock, false))
		run(m2.startup + 0.01)
		assert(near(a.focus, F.m2Gain) and F.m2Gain == 15, "M2 focus gain " .. a.focus)
	end)

	test("Prodigy: a landed hit no longer slows the victim (Microgravity removed, user 2026-10-31)", function()
		setup()
		asProdigy("a")
		B:SetAttribute("HitSlowUntil", nil)
		B:SetAttribute("HitSlowMult", nil)
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
		run(a.hitboxAt - clock + 0.01)
		assert(last() and last().r == Result.Hit, "M1 didn't land")
		assert(B:GetAttribute("HitSlowUntil") == nil, "Prodigy hit still slows")
	end)

	test("seated: no attacks, blocks or dashes; standing up allows them again", function()
		setup()
		humA.Sit = true
		local okA = CombatService.requestAttack(a, "M1", clock, false)
		local okB = CombatService.requestBlock(a, true, clock, clock, false)
		local okD = CombatService.requestDash(a, Vector3.xAxis, "Side", clock, clock, false)
		humA.Sit = false
		assert(not okA and not okB and not okD, `seated: attack {okA} block {okB} dash {okD}`)
		assert(a.state == State.Idle and not a.queued, "a seated request changed state / was buffered")
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused after standing up")
	end)

	test("hit while seated: knocked out of the seat (and still takes the hit)", function()
		setup()
		humB.Sit = true
		assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
		run(a.hitboxAt - clock + 0.01)
		assert(last() and last().r == Result.Hit, "M1 didn't land on the seated victim")
		assert(not humB.Sit and humB.Health < humB.MaxHealth, `still seated {humB.Sit} / hp {humB.Health}`)
	end)

	test("Taekwondo crit: 7 dmg / 20% anti-heal, a block is a weak guard (stripped, no guard break)", function()
		local tkd = MoveSchema.style("Taekwondo")
		local crit = tkd.moves[tkd.r]
		assert(near(crit.damage, 7) and near(crit.antiHeal, 0.2) and not crit.tags.GuardBreak and crit.tags.Strip and crit.grab == nil, "Taekwondo crit data changed")
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, tkd, clock)
		only = { [a] = true, [v] = true }
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		v.freshPress = false -- a held block, not a parry
		assert(CombatService.requestAttack(a, "R", clock, false), "crit refused")
		run(crit.startup + 0.01)
		assert(last() and last().r == Result.Strip, "fresh block vs the crit: expected Strip, got " .. tostring(last() and last().r))
	end)

	test("Taekwondo crit countered: Clash stun clip, same stun, its own 3-stud push; other moves unchanged", function()
		local tkd = MoveSchema.style("Taekwondo")
		local crit = tkd.moves[tkd.r]
		assert(crit.countered and crit.countered.clip == "Clash" and near(crit.countered.knockback.distance, 3), "Taekwondo crit `countered` changed")
		local Knockback = Paths.server("Knockback")
		local pushes = {}
		local realApply = Knockback.apply
		Knockback.apply = function(att, vic, kb, ...)
			table.insert(pushes, kb)
			return realApply(att, vic, kb, ...)
		end
		local ok, err = pcall(function()
			-- B (Taekwondo) starts its crit; A's M1 lands in that windup = a counter.
			setup()
			Registry.remove(B)
			v = Registry.add(B, nil, tkd, clock)
			only = { [a] = true, [v] = true }
			assert(CombatService.requestAttack(v, "R", clock, false), "crit refused")
			assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
			run(M1.startup + 0.01)
			assert(last() and last().r == Result.Counter, "expected Counter, got " .. tostring(last() and last().r))
			assert(last().info.clip == "Clash", "no Clash clip: " .. tostring(last().info.clip))
			assert(near(last().info.stun, M1.hitstun), "stun changed: " .. tostring(last().info.stun))
			assert(pushes[#pushes] == crit.countered.knockback, "pushed by the M1's knockback, not the crit's countered one")
			-- A plain hit (not out of that crit) keeps the normal clip.
			table.clear(pushes)
			setup()
			assert(CombatService.requestAttack(a, "M1", clock, false), "M1 refused")
			run(M1.startup + 0.01)
			assert(last() and last().r == Result.Hit and last().info.clip == nil, "a plain hit got a clip")
		end)
		Knockback.apply = realApply
		assert(ok, err)
	end)

	test("Taekwondo M2: 4-stud step-in from the click over 0.37s, kick at 0.4 (50% anti-heal), 0.2 endlag", function()
		local tkd = MoveSchema.style("Taekwondo")
		local m2 = tkd.moves[tkd.m2]
		assert(near(m2.startup, 0.4) and near(m2.endlag, 0.2) and near(m2.antiHeal, 0.5) and m2.rush == nil, "Taekwondo M2 numbers changed")
		assert(m2.step and m2.step.at == 0 and near(m2.step.distance, 4) and near(m2.step.duration, 0.37), "Taekwondo M2 step changed")
		setup()
		Registry.remove(A)
		a = Registry.add(A, nil, tkd, clock)
		only = { [a] = true, [v] = true }
		a.adrenaline = 0 -- no startup bonus: the kick is exactly at 0.5
		assert(CombatService.requestAttack(a, "M2", clock, false), "M2 refused")
		run(m2.startup - 0.02)
		assert(#log == 0 and a.state == State.Startup, "kick before 0.5: " .. a.state)
		run(0.05)
		assert(last() and last().r == Result.Hit, "kick didn't land, got " .. tostring(last() and last().r))
		assert(near(v.healable, last().info.damage * D.HEAL_KEEP * (1 - m2.antiHeal), 0.01), "anti-heal: healable " .. v.healable)
		assert(a.state == State.Endlag and near(a.stateEndsAt - a.stateStartedAt, m2.endlag), "endlag " .. (a.stateEndsAt - a.stateStartedAt))
	end)

	test("Reflex Step (Taekwondo): a landed counter cuts 35% of the full dash cooldown; a plain hit doesn't", function()
		local HitResolver = Paths.server("HitResolver")
		local tkd = MoveSchema.style("Taekwondo")
		assert(table.find(tkd.perks, "ReflexStep"), "Taekwondo lost Reflex Step")
		local cut = Paths.perk("ReflexStep").mods.counterDashRefund
		local move = tkd.moves[tkd.m1Chain[1]]
		local noop = function() end
		for _, case in { { r = Result.Hit, want = D.DASH_COOLDOWN }, { r = Result.Counter, want = D.DASH_COOLDOWN * (1 - cut) } } do
			setup()
			Registry.remove(A)
			a = Registry.add(A, nil, tkd, clock)
			only = { [a] = true, [v] = true }
			a.dashCooldownUntil = clock + D.DASH_COOLDOWN
			HitResolver.applyHit(a, v, move, 1, clock, case.r, noop)
			assert(near(a.dashCooldownUntil - clock, case.want, 1e-3), `{case.r}: dash cooldown left {a.dashCooldownUntil - clock}, want {case.want}`)
		end
	end)

	test("Afterburner: a dodge refunds 70% of the dash cooldown", function()
		setup()
		asProdigy("v") -- Afterburner is a Prodigy style perk: always on
		assert(CombatService.requestDash(v, Vector3.xAxis, "Side", clock, clock, false), "dash refused")
		local full = v.dashCooldownUntil
		assert(CombatService.requestAttack(a, "M1", clock, false))
		run(M1.startup + 0.01)
		assert(near(v.dashCooldownUntil, full - D.DASH_COOLDOWN * 0.7, 0.01), "dash cooldown after the dodge " .. (v.dashCooldownUntil - clock))
	end)

	test("Focus 80+: the dash cooldown is 30% shorter; below 80 (or without Focus) it's normal", function()
		for _, case in { { 80, 1 - F.dashCdCut }, { 100, 1 - F.dashCdCut }, { 79, 1 } } do
			setup()
			asProdigy("v")
			v.focus = case[1]
			assert(CombatService.requestDash(v, Vector3.xAxis, "Side", clock, clock, false), "dash refused")
			assert(near(v.dashCooldownUntil - clock, D.DASH_COOLDOWN * case[2]), `focus {case[1]}: cooldown {v.dashCooldownUntil - clock}`)
		end
		setup() -- a style without Focus never gets it
		v.focus = 100
		assert(CombatService.requestDash(v, Vector3.xAxis, "Side", clock, clock, false))
		assert(near(v.dashCooldownUntil - clock, D.DASH_COOLDOWN), "no-Focus style got the cut")
	end)

	test("Gravity Assist: every dash cuts 10% of the crit's full cooldown, a dodge another 20%", function()
		local crit = prodigy.moves[prodigy.r]
		local mods = Paths.perk("GravityAssist").mods
		setup()
		asProdigy("v")
		v.rCooldownUntil = clock + crit.cooldown
		local before = v.rCooldownUntil
		assert(CombatService.requestDash(v, Vector3.xAxis, "Side", clock, clock, false), "dash refused")
		assert(near(v.rCooldownUntil, before - crit.cooldown * mods.dashRCooldownCut), "dash cut " .. (before - v.rCooldownUntil))
		before = v.rCooldownUntil
		assert(CombatService.requestAttack(a, "M1", clock, false))
		run(M1.startup + 0.01)
		assert(near(v.rCooldownUntil, before - crit.cooldown * mods.dodgeRCooldownCut), "dodge cut " .. (before - v.rCooldownUntil))
		-- Never past ready.
		setup()
		asProdigy("v")
		v.rCooldownUntil = clock + 0.1
		assert(CombatService.requestDash(v, Vector3.xAxis, "Side", clock, clock, false))
		assert(near(v.rCooldownUntil, clock), "cut past ready " .. (v.rCooldownUntil - clock))
	end)

	-- Reentry from out of Eject range: B waits 12 studs off, then steps into the rush's hitbox.
	local function reentry(): any
		local crit = prodigy.moves[prodigy.r]
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -12), ORIGIN)
		Paths.server("Fighter").unlockMove(a, "Reentry", clock + 2) -- as if an Eject had just landed
		assert(CombatService.requestAttack(a, "R", clock, false), "Reentry refused")
		assert(a.move.id == "Reentry", "far R threw " .. a.move.id)
		run(crit.startup / a.attackSpeed + 0.001)
		assert(a.state == State.Rush, "expected Rush, got " .. a.state)
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -3), ORIGIN)
		run(STEP)
		return crit
	end

	test("Lightshow: Reentry at full Focus plays the cutscene and spends it; otherwise a normal hit", function()
		-- Lightshow is a Prodigy style perk: on for every Prodigy, no trait slot needed (the live bug:
		-- it was a rollable trait, so a Prodigy without it in a slot never got the cutscene).
		setup()
		asProdigy("a")
		assert(a.mods.focusCutscene > 0, "Lightshow isn't on for Prodigy")
		-- Not full: the normal critical (its damage, no cutscene), and Focus grows.
		a.focus = 50
		local crit = reentry()
		assert(last() and last().r == Result.Hit and not last().info.cutscene, "half-Focus crit should be a normal hit")
		assert(near(humB.Health, humB.MaxHealth - last().info.damage) and last().info.damage >= crit.damage, "normal crit damage " .. humB.Health)
		assert(near(a.focus, 50 + F.hitGain), "focus after the crit " .. a.focus)
		-- Full: the cutscene, no damage from the hit itself, Focus spent.
		setup()
		asProdigy("a")
		-- Live case: Spacesuit has drained a little (the HUD still shows full) and keeps draining
		-- through the windup + rush. Full at the press, within 1 of max, still counts.
		a.focus = F.max - 0.5
		a.adrenaline = 300
		reentry()
		assert(a.mods.adrFocusDrain > 0, "Spacesuit drain not on")
		assert(last() and last().info.cutscene == true, "full-Focus crit didn't start the cutscene")
		assert(near(humB.Health, humB.MaxHealth), "the cutscene hit dealt direct damage " .. humB.Health)
		assert(near(a.focus, 0), "Lightshow didn't spend Focus: " .. a.focus)
	end)

	test("Prodigy R: Eject up close (shove, dash back); Reentry from range ignores the dash, a hit refunds it, neutral", function()
		-- Close (B at 3 studs): Eject, and landing it gives a spent dash back.
		setup()
		asProdigy("a")
		a.dashCooldownUntil = clock + 5
		assert(CombatService.requestAttack(a, "R", clock, false), "Eject refused")
		local eject = a.move
		assert(eject.id == "Eject", "close R threw " .. eject.id)
		run(eject.startup / a.attackSpeed + 0.01)
		assert(last() and last().r == Result.Hit, "Eject didn't land")
		assert(a.dashCooldownUntil <= clock, "Eject didn't refresh the dash")
		-- ...and readies the M2 + crit (its own cooldown skipped), but locks Reentry for 2s.
		local m2cd = prodigy.moves[prodigy.m2].cooldown
		a.m2CooldownUntil = clock + m2cd
		HitResolver.applyHit(a, v, eject, 1, clock, Result.Hit, function() end)
		assert(near(a.m2CooldownUntil - clock, m2cd * 0.2), "Eject should cut 80% of the M2 cooldown, left " .. (a.m2CooldownUntil - clock))
		run(eject.endlag + 0.05)
		assert(a.state == State.Idle and a.rCooldownUntil <= clock, "Eject went on cooldown: " .. (a.rCooldownUntil - clock))
		-- Reentry is open for 2s after the landed Eject: usable right after its endlag, spent on use.
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -12), ORIGIN)
		assert(A:GetAttribute("MoveUnlock_Reentry") ~= nil, "unlock not mirrored to the client")
		assert(CombatService.requestAttack(a, "R", clock, false), "Reentry refused inside the 2s window")
		assert(a.move.id == "Reentry", "far R threw " .. a.move.id)
		assert(A:GetAttribute("MoveUnlock_Reentry") == nil, "throwing Reentry didn't spend the unlock")
		-- ...and closes after 2s unused.
		setup()
		asProdigy("a")
		assert(CombatService.requestAttack(a, "R", clock, false), "Eject refused")
		run(a.move.startup / a.attackSpeed + 0.01)
		assert(last() and last().r == Result.Hit, "2nd Eject didn't land")
		run(2.05)
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -12), ORIGIN)
		assert(CombatService.requestAttack(a, "R", clock, false) and a.move.id == "Eject", "far R after the 2s window didn't throw Eject")
		-- Without a landed Eject, Reentry never comes out: R throws Eject at any range.
		setup()
		asProdigy("a")
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -12), ORIGIN)
		run(5)
		assert(CombatService.requestAttack(a, "R", clock, false) and a.move.id == "Eject", "far R with no landed Eject didn't throw Eject")
		-- Far with the dash ready: Reentry leaves it alone (user, 2026-10-24: no longer tied to the dash).
		setup()
		asProdigy("a")
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -12), ORIGIN)
		Paths.server("Fighter").unlockMove(a, "Reentry", clock + 2)
		assert(CombatService.requestAttack(a, "R", clock, false), "Reentry refused")
		assert(a.dashCooldownUntil <= clock, "Reentry spent the dash")
		-- Far with the dash on cooldown: still goes; the hit refunds the dash; both act again together.
		setup()
		asProdigy("a")
		a.dashCooldownUntil = clock + 5
		local crit = reentry()
		assert(last() and last().r == Result.Hit, "Reentry didn't land")
		assert(a.dashCooldownUntil <= clock, "Reentry hit didn't refresh the dash")
		assert(near(a.stateEndsAt, v.stateEndsAt, 1e-3), `not neutral: attacker {a.stateEndsAt - clock} victim {v.stateEndsAt - clock}`)
		assert(near(crit.damage, 4) and near(crit.antiHeal, 0), "Reentry numbers changed")
	end)

	test("Prodigy: inside the Reentry window R never throws Eject, even up close", function()
		setup()
		asProdigy("a")
		assert(CombatService.requestAttack(a, "R", clock, false), "Eject refused")
		local eject = a.move
		assert(eject.id == "Eject", "close R threw " .. eject.id)
		run(eject.startup / a.attackSpeed + 0.01)
		assert(last() and last().r == Result.Hit, "Eject didn't land")
		run(eject.endlag + 0.05)
		rootB.CFrame = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -3), ORIGIN) -- right up close again
		assert(CombatService.requestAttack(a, "R", clock, false), "R refused inside the window")
		assert(a.move.id == "Reentry", "close R inside the window threw " .. a.move.id)
	end)

	test("Prodigy Eject: no guard break; a fresh block blocks it, a weak guard gets stripped", function()
		setup()
		asProdigy("a")
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		assert(CombatService.requestAttack(a, "R", clock, false), "Eject refused")
		local eject = a.move
		assert(eject.id == "Eject" and eject.tags.GuardBreak ~= true, "Eject still guard breaks")
		run(eject.startup / a.attackSpeed + 0.01)
		assert(last() and last().r == Result.Blocked, "fresh block: expected Blocked, got " .. tostring(last() and last().r))
		setup()
		asProdigy("a")
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.HOLD_STRIP_THRESHOLD)
		assert(CombatService.requestAttack(a, "R", clock, false), "Eject refused")
		run(eject.startup / a.attackSpeed + 0.01)
		assert(last() and last().r == Result.Strip, "weak guard: expected Strip, got " .. tostring(last() and last().r))
	end)

	test("Bloxy Cola: tier thresholds; drunk (tier 2) any hit knocks for hitKnock; tier 1 doesn't", function()
		local Bloxy = Paths.server("BloxyService")
		local X = D.BLOXY
		local S = D.SODA.sips -- thresholds are whole drinks: blurAt drinks = blurAt * S sips
		assert(Bloxy.tier(X.blurAt * S - 1) == 0 and Bloxy.tier(X.blurAt * S) == 1, "blur threshold")
		assert(Bloxy.tier(X.drunkAt * S - 1) == 1 and Bloxy.tier(X.drunkAt * S) == 2, "drunk threshold")
		assert(Bloxy.tier(X.blackoutAt * S - 1) == 2 and Bloxy.tier(X.blackoutAt * S) == 3, "blackout threshold")
		-- Sobering up: nothing lost during soberDelay, then soberRate a second, never below 0.
		assert(Bloxy.level(72, 100, 100 + X.soberDelay) == 72, "lost sips inside the delay")
		assert(math.abs(Bloxy.level(72, 100, 100 + X.soberDelay + 10) - (72 - 10 * X.soberRate)) < 1e-6, "sober rate")
		assert(Bloxy.level(72, 100, 100 + X.soberDelay + 72 / X.soberRate + 5) == 0, "never fully sober")
		assert(Bloxy.tier(Bloxy.level(X.drunkAt * S, 0, X.soberDelay + 1)) < 2, "still one-hit drunk a second after the delay")
		local noop = function() end
		setup()
		B:SetAttribute("Drunk", 1)
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(v.state ~= State.Knocked, "tier 1 should not knock on a normal hit")
		setup()
		B:SetAttribute("Drunk", 2)
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(v.state == State.Knocked, "drunk hit should knock, state " .. v.state)
		assert(near(v.stateEndsAt - clock, X.hitKnock, 1e-3), "drunk knock length " .. (v.stateEndsAt - clock))
		assert(humB.Health > D.KNOCKED.hp, "a drunk knock keeps your HP")
		B:SetAttribute("Drunk", nil)
	end)

	test("knocked: a lethal hit knocks (no death), immune, ragdolled, carried, gets up", function()
		local KnockService = Paths.server("KnockService")
		local noop = function() end
		setup()
		humB.Health = 1
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(v.state == State.Knocked, "lethal hit should knock, state " .. v.state)
		assert(humB.Health > 0 and near(humB.Health, D.KNOCKED.hp), "knocked HP " .. humB.Health)
		assert(B:GetAttribute("Knocked") == true and B:GetAttribute("Ragdolled") ~= nil, "knock attrs / ragdoll")
		assert(near(a.siphonLeft, D.SIPHON.heal), "a knock still counts as a kill for siphon")
		-- immune: further hits do nothing, and a swing at them connects with nobody
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		assert(v.state == State.Knocked and near(humB.Health, D.KNOCKED.hp), "knocked fighter got hit")
		assert(HitResolver.resolve(a, v, M1, clock, noop, true) == nil, "resolve should miss a knocked fighter")
		-- can't act while down
		assert(not CombatService.requestAttack(v, "M1", clock, false), "a knocked fighter attacked")
		-- carry: A picks B up (A must be Idle and in range), can't pick up twice, drop restores
		run(1)
		assert(a.state == State.Idle, "attacker not idle: " .. a.state)
		assert(KnockService.pickUp(a, v, clock), "pick up failed")
		assert(KnockService.isCarrying(a) and KnockService.carrierOf(v) == a, "carry links")
		local link = B:FindFirstChild("MidoriCarrier")
		assert(link and link.Value == rootA and B:GetAttribute("Carried") and A:GetAttribute("Carrying"), "carry: link / attrs")
		assert(A:FindFirstChild("MidoriCarryCollider"), "carried body needs its own collider")
		assert(not KnockService.pickUp(a, v, clock), "picked up twice")
		KnockService.drop(a, clock)
		rootB.Anchored = true
		A:SetAttribute("HoldingSoda", true)
		assert(not KnockService.pickUp(a, v, clock), "carried while holding a soda")
		A:SetAttribute("HoldingSoda", nil)
		assert(KnockService.pickUp(a, v, clock), "pick up after the soda check")
		KnockService.drop(a, clock)
		assert(not KnockService.isCarrying(a) and not B:FindFirstChild("MidoriCarrier") and not A:FindFirstChild("MidoriCarryCollider") and B:GetAttribute("Carried") == nil, "drop")
		assert(not rootB.Anchored and (rootB.Position - (rootA.CFrame * D.CARRY.offset).Position).Magnitude < 1e-3, "dropped at the shoulder, unpinned")
		rootB.Anchored = true -- the test rig stands on nothing
		-- carrier gets stunned: drops automatically
		assert(KnockService.pickUp(a, v, clock), "pick up again")
		local Fighter = Paths.server("Fighter")
		Fighter.setState(a, State.Hitstun, 0.5, clock)
		run(STEP)
		assert(not KnockService.isCarrying(a), "a stunned carrier should drop")
		-- gets up after the knock: Idle, recoverHp, ragdoll + prompt gone
		run(D.KNOCKED.duration)
		assert(v.state == State.Idle, "still down: " .. v.state)
		assert(near(humB.Health, humB.MaxHealth * D.KNOCKED.recoverHp, 0.01), "recover HP " .. humB.Health)
		assert(B:GetAttribute("Knocked") == nil and B:GetAttribute("Ragdolled") == nil, "recover cleanup")
		-- the knocked body was carried when it got up: dropped first
		setup()
		humB.Health = 1
		HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
		run(1)
		-- being held pauses the knock timer; dropping resumes it from where it stopped
		local leftAtPickup = v.stateEndsAt - clock
		assert(KnockService.pickUp(a, v, clock), "pick up for the pause")
		assert(near(B:GetAttribute("KnockedLeft"), leftAtPickup, 1e-3), "KnockedLeft " .. tostring(B:GetAttribute("KnockedLeft")))
		run(D.KNOCKED.duration + 2)
		assert(v.state == State.Knocked and KnockService.isCarrying(a), "carried: the knock should not run out")
		KnockService.drop(a, clock)
		assert(near(v.stateEndsAt - clock, leftAtPickup, 1e-3) and B:GetAttribute("KnockedLeft") == nil, "drop should resume the timer")
		run(leftAtPickup - 0.1)
		assert(v.state == State.Knocked, "got up early after the drop")
		run(0.2)
		assert(v.state == State.Idle, "should be up once the rest of the timer ran")
		humB.Health = humB.MaxHealth
	end)

	test("grip: pins the knocked body in front, kills at GRIP.at, lets go; a hit cancels it", function()
		local KnockService = Paths.server("KnockService")
		local noop = function() end
		local function knockB()
			setup()
			humB.Health = 1
			HitResolver.applyHit(a, v, M1, 1, clock, Result.Hit, noop)
			run(1)
			rootB.Anchored = true -- the test rig stands on nothing
		end
		-- cancelled: A gets hit mid-grip -> B unpinned, still knocked, alive
		knockB()
		assert(KnockService.grip(a, v, clock), "grip refused")
		assert(a.state == State.Gripping and A:GetAttribute("Gripping") and B:GetAttribute("Gripped"), "grip state / attrs")
		local link = B:FindFirstChild("MidoriCarrier")
		assert(link and link.Value == rootA and (rootB.Position - (rootA.CFrame * D.GRIP.offset).Position).Magnitude < 1e-3, "pinned in front")
		assert(not KnockService.pickUp(a, v, clock), "carried someone mid-grip")
		local Fighter = Paths.server("Fighter")
		Fighter.setState(a, State.Hitstun, 0.5, clock)
		run(STEP)
		assert(not B:FindFirstChild("MidoriCarrier") and B:GetAttribute("Gripped") == nil and A:GetAttribute("Gripping") == nil, "cancel cleanup")
		run(D.GRIP.at)
		assert(v.state == State.Knocked and humB.Health > 0, "a cancelled grip killed")
		-- finished: dies at GRIP.at, not before
		knockB()
		assert(KnockService.grip(a, v, clock), "grip refused (2)")
		run(D.GRIP.at - 0.05)
		assert(humB.Health > 0, "died before GRIP.at")
		run(0.1)
		assert(humB.Health <= 0, "grip didn't kill, HP " .. humB.Health)
		assert(a.state == State.Idle and not B:FindFirstChild("MidoriCarrier") and not rootB.Anchored, "after the kill: idle, unpinned")
		Registry.remove(B)
		humB.Health = humB.MaxHealth
	end)

	test("traits: Charged Return, Calm Mind", function()
		local Fighter = Paths.server("Fighter")
		local AdrenalineSystem = Paths.server("AdrenalineSystem")
		local CombatMath = Paths.shared("CombatMath")
		local function mods(id: string): any
			return Paths.perk(id).mods
		end

		-- Charged Return: a landed parry banks the bonus; the parrier's next attack spends it.
		setup()
		Fighter.addMods(v, mods("ChargedReturn"), 1)
		CombatService.requestAttack(a, "M2", clock, false)
		run(a.hitboxAt - clock - LEAD - 0.03)
		CombatService.requestBlock(v, true, clock, clock, false)
		run(0.07)
		assert(last() and last().r == Result.Parried, "expected Parried, got " .. tostring(last() and last().r))
		assert(v.parryBonus == mods("ChargedReturn").parryBonusDamage, "no bonus banked: " .. v.parryBonus)
		run(D.PARRY_RECOVERY + 0.02)
		v.adrenaline = 0 -- no adrenaline bonus, so only the flat +2 shows
		assert(CombatService.requestAttack(v, "M1", clock, false), "follow-up refused")
		assert(v.parryBonus == 0, "bonus not spent at attack start")
		run(M1.startup + 0.01)
		assert(last().r == Result.Hit and last().v == A, "follow-up: " .. tostring(last().r))
		assert(near(humA.Health, 100 - M1.damage - mods("ChargedReturn").parryBonusDamage), "health " .. humA.Health)

		-- Calm Mind (id AggressivePersonality): +100 max (bonus scales past the base max), no gain bonus.
		setup()
		local ap = mods("AggressivePersonality")
		Fighter.addMods(v, ap, 1)
		assert(B:GetAttribute("AdrenalineMax") == D.ADR_MAX + ap.adrenalineMax, "AdrenalineMax attribute")
		AdrenalineSystem.gain(v, 100)
		assert(near(v.adrenaline, 100), "Calm Mind shouldn't boost gains: " .. v.adrenaline)
		AdrenalineSystem.gain(v, 10000)
		assert(near(v.adrenaline, D.ADR_MAX + ap.adrenalineMax), "cap " .. v.adrenaline)
		assert(CombatMath.ratio(v.adrenaline) > 1, "extra max doesn't scale the bonus")
		Fighter.addMods(v, ap, -1)
		assert(near(v.adrenaline, D.ADR_MAX) and B:GetAttribute("AdrenalineMax") == D.ADR_MAX, "detach didn't clamp")
	end)

	-- Drag hitboxes (live DRAG_LEAD before to DRAG_TAIL after the hitbox time, once per victim).
	local FAR = CFrame.lookAt(ORIGIN + Vector3.new(0, 0, -40), ORIGIN)

	test("drag hitbox: lands DRAG_LEAD early on a victim already in range", function()
		if not D.DRAG_HITBOX then
			return -- drag hitboxes are switched off in Defaults
		end
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		run(a.hitboxAt - clock - LEAD + STEP)
		assert(last() and last().r == Result.Hit, "no early drag hit")
		assert(a.state == State.Startup, "attacker left startup early: " .. a.state)
	end)

	test("drag hitbox: catches a victim walking in during the tail, once per swing", function()
		if not D.DRAG_HITBOX then
			return -- drag hitboxes are switched off in Defaults
		end
		setup()
		local inRange = rootB.CFrame
		rootB.CFrame = FAR
		CombatService.requestAttack(a, "M1", clock, false)
		run(a.hitboxAt - clock + TAIL / 2)
		assert(#log == 0, "hit someone 40 studs away")
		rootB.CFrame = inRange
		run(STEP * 2)
		assert(last() and last().r == Result.Hit, "the tail did not catch the victim")
		run(TAIL)
		assert(#log == 1, "hit more than once in one swing: " .. #log)
	end)

	test("drag hitbox: gone after the tail", function()
		if not D.DRAG_HITBOX then
			return -- drag hitboxes are switched off in Defaults
		end
		setup()
		local inRange = rootB.CFrame
		rootB.CFrame = FAR
		CombatService.requestAttack(a, "M1", clock, false)
		run(a.hitboxAt - clock + TAIL + STEP * 2)
		rootB.CFrame = inRange
		run(STEP * 3)
		assert(#log == 0, "hit after the tail")
	end)

	-- Defence grace: B plays a player whose presses are GRACE in flight.
	local LagComp = Paths.server("LagComp")
	local realGrace = LagComp.grace
	local GRACE = 0.08
	local function graceTest(name: string, fn: () -> ())
		test(name, function()
			LagComp.grace = function(f: any): number
				return if f == v then GRACE else 0
			end
			local ok, err = pcall(fn)
			LagComp.grace = realGrace
			assert(ok, err)
		end)
	end
	-- Swing M1 until the drag lands on idle B (held); returns the earliest possible hit time.
	local function swingUntilHeld(): number
		setup()
		CombatService.requestAttack(a, "M1", clock, false)
		local earliest = a.hitboxAt - LEAD
		run(earliest - clock + STEP)
		assert(#log == 0, "resolved before the grace")
		return earliest
	end

	graceTest("grace: a hit on an idle player lands after the grace, stun from the hit time", function()
		swingUntilHeld()
		run(GRACE + STEP)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
		assert(clock - v.stateStartedAt >= GRACE - 1e-3, "stun started at resolution, not the hit")
	end)

	graceTest("grace: a parry pressed before the hit, arriving after it, parries", function()
		local earliest = swingUntilHeld()
		CombatService.requestBlock(v, true, earliest - 0.01, clock, false)
		run(GRACE + STEP)
		assert(last() and last().r == Result.Parried, "expected Parried, got " .. tostring(last() and last().r))
		assert(near(humB.Health, 100), "took damage " .. humB.Health)
	end)

	graceTest("buffer parry: F held through hitstun parries the next chain hit, press arriving late", function()
		swingUntilHeld()
		run(GRACE + STEP)
		assert(last() and last().r == Result.Hit, "first hit: " .. tostring(last() and last().r))
		local stunEnd = v.stateEndsAt
		assert(last().info.ends and near(last().info.ends, stunEnd), "HitResult doesn't carry the stun's end")
		run(a.stateEndsAt - clock + STEP) -- A's endlag ends, A chains M1_2
		assert(CombatService.requestAttack(a, "M1", clock, false), "chain M1 refused")
		run(a.hitboxAt - LEAD - clock + STEP) -- the drag lands on B (now idle): held
		assert(#log == 1, "second hit resolved before the grace")
		-- B's client blocked the instant its (server-aligned) stun ended; the press arrives now.
		CombatService.requestBlock(v, true, stunEnd, clock, false)
		run(GRACE + STEP)
		assert(last().r == Result.Parried, "expected Parried, got " .. tostring(last().r))
	end)

	graceTest("grace: a block pressed after the hit doesn't save you", function()
		swingUntilHeld()
		CombatService.requestBlock(v, true, clock, clock, false)
		run(GRACE + STEP)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
		assert(v.state == State.Hitstun, "victim " .. v.state)
	end)

	graceTest("grace: a dash pressed before the hit dodges it", function()
		local earliest = swingUntilHeld()
		local dodged = false
		local stop = CombatService.dodged:Connect(function()
			dodged = true
		end)
		CombatService.requestDash(v, Vector3.new(0, 0, -1), "Back", earliest - 0.01, clock, false)
		run(GRACE + STEP)
		stop()
		assert(#log == 0, "dash didn't dodge: " .. tostring(last() and last().r))
		assert(dodged and near(humB.Health, 100), "no dodge")
	end)

	-- Ban Hammer crit grab (user, 2026-10-15). Returns the style's crit + follow-up, with A's follow-up
	-- just started (both fighters Ban Hammer, adrenaline 0 so no damage bonus).
	local function banHammerGrab(): (any, any)
		local bh = MoveSchema.style("BanHammer")
		local crit = bh.moves[bh.r]
		local follow = bh.moves[crit.grab.move]
		setup()
		Registry.remove(A)
		Registry.remove(B)
		a = Registry.add(A, nil, bh, clock)
		v = Registry.add(B, nil, bh, clock)
		only = { [a] = true, [v] = true }
		assert(CombatService.requestAttack(a, "R", clock, false), "crit refused")
		run(crit.startup + 0.01)
		assert(last() and last().r == Result.Hit and last().info.grab, "crit didn't grab: " .. tostring(last() and last().r))
		local grabAt = last().info.grab
		assert(a.state == State.Endlag and near(a.stateEndsAt, grabAt, 0.02), "attacker isn't held to the grab")
		assert(v.state == State.Hitstun and near(v.stateEndsAt, grabAt, 0.02), "victim isn't held to the grab")
		run(grabAt - clock + 0.01)
		assert(a.state == State.Startup and a.move.id == follow.id, "follow-up didn't start: " .. a.state)
		return crit, follow
	end

	test("Dema blink: lane 0 -> 40 at startup -> 60 full; i-frames through the windup + 1s after the hit", function()
		local Fighter = Paths.server("Fighter")
		local m2 = MoveSchema.style("Dema").moves.M2
		local s = m2.startup
		assert(CombatMath.blinkRange(m2, 0, s) == 0, "lane isn't 0 at the press")
		assert(math.abs(CombatMath.blinkRange(m2, s, s) - 40) < 1e-6, "lane isn't 40 at startup")
		assert(math.abs(CombatMath.blinkRange(m2, s + m2.charge.time, s) - 60) < 1e-6, "lane isn't 60 at full charge")
		local f = { state = State.Startup, move = m2, dashPressAt = 0, iframesUntil = 0, attackIframesFrom = 0, attackIframesUntil = 0, moveIframesUntil = math.huge }
		assert(Fighter.inIframes(f, 5), "no i-frames in the windup")
		f.state = State.Idle
		assert(not Fighter.inIframes(f, 5), "a cancelled windup kept its i-frames")
		f.moveIframesUntil = 10 + m2.iframes
		assert(Fighter.inIframes(f, 10.9) and not Fighter.inIframes(f, 11.01), "after-hit i-frames aren't 1s")
	end)

	test("Pierce (Dema M2, 100% guard chip): a blocked hit breaks the guard and lands in full", function()
		local m2 = MoveSchema.style("Dema").moves.M2
		local hit = table.clone(m2)
		hit.damage = 4
		setup()
		CombatService.requestBlock(v, true, clock, clock, false)
		run(D.BLOCK_START_DURATION + 0.05)
		v.freshPress = false -- a held block, not a parry press
		local r = HitResolver.resolve(a, v, hit, clock, function() end, false)
		assert(r == Result.Hit, "expected Hit through the guard, got " .. tostring(r))
		assert(v.state == State.Hitstun, "victim not in hitstun: " .. v.state)
		assert(humB.Health < 100, "no damage through the guard")
		assert(v.model:GetAttribute("Ragdolled") ~= nil, "not ragdolled through the guard")
		assert(near(v.guard, style.guardMax * D.GUARD_BREAK_RESTORE), "guard not broken: " .. v.guard)
	end)

	test("Ban Hammer grab: Execute goes through a block for half max HP", function()
		local crit, follow = banHammerGrab()
		assert(CombatService.requestBlock(v, true, clock, clock, false), "victim couldn't block after the hold")
		run(follow.startup)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
		assert(near(humB.Health, humB.MaxHealth * (1 - follow.maxHpDamage) - crit.damage, 0.01), "health " .. humB.Health)
	end)

	test("Ban Hammer grab: a timed parry stops Execute", function()
		local _, follow = banHammerGrab()
		run(follow.startup - D.PARRY_WINDOW / 2)
		assert(CombatService.requestBlock(v, true, clock, clock, false), "victim couldn't block")
		run(D.PARRY_WINDOW)
		assert(last() and last().r == Result.Parried, "expected Parried, got " .. tostring(last() and last().r))
	end)

	-- Lethwei crit (user, 2026-10-16): unparryable, always strips a block, and its style perk
	-- (Mutually Assured Destruction) hurts the attacker when it lands.
	local function lethwei(): any
		local lw = MoveSchema.style("Lethwei")
		setup()
		Registry.remove(A)
		Registry.remove(B)
		a = Registry.add(A, nil, lw, clock)
		v = Registry.add(B, nil, lw, clock)
		only = { [a] = true, [v] = true }
		return lw.moves[lw.r]
	end

	test("Lethwei crit: lands for 16, costs the attacker 4", function()
		local crit = lethwei()
		assert(CombatService.requestAttack(a, "R", clock, false), "crit refused")
		run(crit.startup + 0.01)
		assert(last() and last().r == Result.Hit, "expected Hit, got " .. tostring(last() and last().r))
		assert(near(humB.Health, 100 - crit.damage, 0.01), "victim health " .. humB.Health)
		assert(near(humA.Health, 100 - 4, 0.01), "attacker health " .. humA.Health)
	end)

	test("Lethwei crit: a timed parry only strips", function()
		local crit = lethwei()
		assert(CombatService.requestAttack(a, "R", clock, false), "crit refused")
		run(crit.startup - D.PARRY_WINDOW / 2)
		assert(CombatService.requestBlock(v, true, clock, clock, false), "victim couldn't block")
		run(D.PARRY_WINDOW)
		assert(last() and last().r == Result.Strip, "expected Strip, got " .. tostring(last() and last().r))
	end)

	test("Codes: redeem once, case/space-insensitive; invalid, expired and repeats refused", function()
		local Codes = Paths.server("CodeService")
		local list = { TEST = { spins = 5, bux = 10 }, OLD = { spins = 1, expires = "2020-01-01T00:00:00Z" } }
		local data = { Codes = {}, Spins = 1, Bux = 0 }
		local now = os.time()
		local ok, msg = Codes.redeem(data, "  test ", now, list)
		assert(ok and data.Spins == 6 and data.Bux == 10 and data.Codes.TEST, "first redeem: " .. msg)
		ok, msg = Codes.redeem(data, "TEST", now, list)
		assert(not ok and msg == "ALREADY REDEEMED" and data.Spins == 6, "repeat: " .. msg)
		ok, msg = Codes.redeem(data, "OLD", now, list)
		assert(not ok and msg == "CODE EXPIRED" and data.Spins == 6, "expired: " .. msg)
		for _, bad in { "NOPE", "", 42, string.rep("A", 500) } do
			ok, msg = Codes.redeem(data, bad, now, list)
			assert(not ok and msg == "INVALID CODE", "bad input " .. tostring(bad):sub(1, 10) .. ": " .. msg)
		end
		-- Headless code: worn on the server profile; the old face goes to an empty locker slot.
		local hd = { Codes = {}, Spins = 0, Bux = 0, Loadout = { Appearance = { Face = 123 } }, Locker = { { Kind = "" } } }
		local changed
		ok, msg, changed = Codes.redeem(hd, "ikuandrorydidwhatnow?", now)
		assert(ok and changed and hd.Loadout.Appearance.Face == "Headless", "headless code: " .. msg)
		assert(hd.Locker[1].Kind == "Look" and hd.Locker[1].Slot == "Face" and hd.Locker[1].Id == 123, "old face not stored")
		-- Decor codes add one to the owned count (apartments).
		local dec = { Codes = {}, Spins = 0, Bux = 0, Decor = { FengTrophy = 1 } }
		ok, msg = Codes.redeem(dec, "feng is immortal", now)
		assert(ok and dec.Decor.FengTrophy == 2 and dec.Spins == 50, "trophy code: " .. msg)
		for code, def in Codes.CODES do
			assert(code == string.upper(code), `code {code} must be uppercase`)
			assert(def.expires == nil or pcall(DateTime.fromIsoDate, def.expires), `code {code} has a bad expires date`)
		end
	end)

	test("GridMath: rotation swaps the footprint; bounds, half cells, overlap, surfaces, cframes", function()
		local G = Paths.shared("GridMath")
		local defs: { [string]: any } = {
			T = { size = { 2, 2 }, height = 3, surface = { size = { 2, 2 }, height = 3 } },
			B = { size = { 2, 4 }, height = 2 },
			S = { size = { 1, 1 }, height = 1, tabletop = true },
			Rug = { size = { 4, 4 }, height = 0.1, rug = true },
		}
		local get = function(id: string): any
			return defs[id]
		end
		local rooms = { R = { size = { 10, 8 }, origin = CFrame.new() } }
		local w, d = G.footprint({ 2, 4 }, 1)
		assert(w == 4 and d == 2, "odd quarter turns should swap width / depth")
		local items: { [string]: any } = {}
		assert(G.check(items, rooms, get, { item = "B", room = "R", x = 0, z = 4, rot = 0 }) == nil, "bed should fit on the edge")
		assert(G.check(items, rooms, get, { item = "B", room = "R", x = 0, z = 5, rot = 0 }) == "out of bounds", "bed past the edge")
		assert(G.check(items, rooms, get, { item = "B", room = "R", x = 7, z = 0, rot = 1 }) == "out of bounds", "a turned bed is 4 wide")
		assert(G.check(items, rooms, get, { item = "B", room = "R", x = 0.5, z = 0, rot = 0 }) == "bad cell", "half cells")
		assert(G.check(items, rooms, get, { item = "B", room = "Nope", x = 0, z = 0, rot = 0 }) == "no such room", "unknown room")
		items["1"] = { item = "T", room = "R", x = 2, z = 2, rot = 0 }
		assert(G.check(items, rooms, get, { item = "S", room = "R", x = 3, z = 3, rot = 0 }) == "overlaps", "under the table")
		assert(G.check(items, rooms, get, { item = "S", room = "R", x = 4, z = 3, rot = 0 }) == nil, "right next to the table")
		assert(G.check(items, rooms, get, { item = "T", room = "R", x = 2, z = 2, rot = 0 }, "1") == nil, "a move shouldn't block itself")
		assert(G.check(items, rooms, get, { item = "Rug", room = "R", x = 1, z = 1, rot = 0 }) == nil, "a rug goes under the table")
		items["9"] = { item = "Rug", room = "R", x = 6, z = 0, rot = 0 }
		assert(G.check(items, rooms, get, { item = "Rug", room = "R", x = 5, z = 1, rot = 0 }) == "overlaps", "rugs block rugs")
		assert(G.check(items, rooms, get, { item = "S", room = "R", x = 7, z = 1, rot = 0 }) == nil, "furniture on a rug")
		items["9"] = nil
		assert(G.check(items, rooms, get, { item = "S", parent = "1", x = 1, z = 1, rot = 0 }) == nil, "small thing on the table")
		assert(G.check(items, rooms, get, { item = "B", parent = "1", x = 0, z = 0, rot = 0 }) == "can't go on a surface", "bed on a table")
		assert(G.check(items, rooms, get, { item = "S", parent = "1", x = 2, z = 0, rot = 0 }) == "out of bounds", "off the table top")
		-- The table's pivot is the centre of its cells; things on it sit at the surface height.
		local at = G.cframe(items, rooms, get, "1")
		assert(at and at.Position:FuzzyEq(Vector3.new(6, 0, 6)), "table at " .. tostring(at))
		items["2"] = { item = "S", parent = "1", x = 0, z = 0, rot = 0 }
		local cup = G.cframe(items, rooms, get, "2")
		assert(cup and cup.Position:FuzzyEq(Vector3.new(5, 3, 5)), "cup at " .. tostring(cup))
		-- Every style's rooms are whole cells (the user resizes them in Studio), and each style has a Spawn + Exit.
		for _, style in Paths.Assets.Apartment:GetChildren() do
			if style:IsA("Model") then
				local rooms = style:FindFirstChild("Rooms")
				assert(rooms and #rooms:GetChildren() > 0, `style {style.Name} has no Rooms`)
				for _, p in rooms:GetChildren() do
					if p:IsA("BasePart") then
						local cx, cz = p.Size.X / G.CELL, p.Size.Z / G.CELL
						assert(near(cx, math.round(cx), 1e-3) and near(cz, math.round(cz), 1e-3), `{style.Name}.{p.Name} is {p.Size.X}x{p.Size.Z}: not whole {G.CELL}-stud cells`)
					end
				end
				assert(style:FindFirstChild("Spawn") and style:FindFirstChild("Exit"), `style {style.Name} needs a Spawn and an Exit`)
			end
		end
	end)

	test("GridMath walls: four per room facing in, wall-only items, per-wall overlap, a shelf's surface", function()
		local G = Paths.shared("GridMath")
		local defs: { [string]: any } = {
			P = { size = { 2, 2 }, height = 0.2, wall = true },
			Sh = { size = { 2, 1 }, height = 2, wall = true, surface = { size = { 2, 1 }, height = -0.5, offset = Vector3.new(0, 0, -1) } },
			S = { size = { 1, 1 }, height = 1, tabletop = true },
			T = { size = { 2, 2 }, height = 3 },
		}
		local get = function(id: string): any
			return defs[id]
		end
		local rooms = { R = { size = { 10, 8 }, origin = CFrame.new(), height = 5 } }
		local walls = G.walls(rooms)
		-- wall cells are 1 stud: a 10 x 8 cell (20 x 16 stud) room with 5-cell (10 stud) walls
		assert(walls["R/N"].size[1] == 20 and walls["R/E"].size[1] == 16 and walls["R/N"].size[2] == 10, "wall sizes")
		-- Every wall's front (LookVector) points into the room: from its middle, a step forward is inside.
		for id, wall in walls do
			local mid = wall.origin * CFrame.new(wall.size[1] * G.WALL_CELL / 2, 1, 0)
			local p = (mid * CFrame.new(0, 0, -1)).Position
			assert(p.X > 0 and p.X < 20 and p.Z > 0 and p.Z < 16, `{id} faces out: {p}`)
		end
		local items: { [string]: any } = {}
		assert(G.check(items, rooms, get, { item = "P", wall = "R/N", x = 0, z = 0, rot = 0 }) == nil, "poster on a wall")
		assert(G.check(items, rooms, get, { item = "P", room = "R", x = 0, z = 0, rot = 0 }) == "goes on a wall", "poster on the floor")
		assert(G.check(items, rooms, get, { item = "T", wall = "R/N", x = 0, z = 0, rot = 0 }) == "doesn't hang on walls", "table on a wall")
		-- the poster is 2x2 cells = 4x4 studs = 4x4 wall cells
		assert(G.check(items, rooms, get, { item = "P", wall = "R/N", x = 16, z = 0, rot = 0 }) == nil, "right at the wall's end")
		assert(G.check(items, rooms, get, { item = "P", wall = "R/N", x = 17, z = 0, rot = 0 }) == "out of bounds", "past the wall's end")
		assert(G.check(items, rooms, get, { item = "P", wall = "R/N", x = 0, z = 7, rot = 0 }) == "out of bounds", "past the top")
		assert(G.check(items, rooms, get, { item = "P", wall = "R/N", x = 1, z = 3, rot = 0 }) == nil, "odd (1-stud) spots are fine")
		assert(G.check(items, rooms, get, { item = "P", wall = "R/N", x = 0, z = 0, rot = 1 }) == "bad cell", "turned on a wall")
		assert(G.check(items, rooms, get, { item = "P", wall = "R/Q", x = 0, z = 0, rot = 0 }) == "no such wall", "unknown wall")
		items["1"] = { item = "P", wall = "R/N", x = 4, z = 2, rot = 0 }
		assert(G.check(items, rooms, get, { item = "P", wall = "R/N", x = 7, z = 5, rot = 0 }) == "overlaps", "two posters overlapping by a stud")
		assert(G.check(items, rooms, get, { item = "P", wall = "R/N", x = 8, z = 2, rot = 0 }) == nil, "touching side by side")
		assert(G.check(items, rooms, get, { item = "P", wall = "R/S", x = 4, z = 2, rot = 0 }) == nil, "same cells, other wall")
		assert(G.check(items, rooms, get, { item = "T", room = "R", x = 2, z = 0, rot = 0 }) == nil, "a table under a poster")
		-- The poster's pivot is on the wall face, centred on its cells.
		local at = G.cframe(items, rooms, get, "1")
		local expect = walls["R/N"].origin * CFrame.new(3 * G.CELL, 2 * G.CELL, 0)
		assert(at and at.Position:FuzzyEq(expect.Position), "poster at " .. tostring(at))
		-- A wall shelf's top sticks out into the room; a tabletop thing sits on it.
		items["2"] = { item = "Sh", wall = "R/S", x = 0, z = 2, rot = 0 }
		assert(G.check(items, rooms, get, { item = "S", parent = "2", x = 1, z = 0, rot = 0 }) == nil, "cup on the wall shelf")
		items["3"] = { item = "S", parent = "2", x = 1, z = 0, rot = 0 }
		local cup = G.cframe(items, rooms, get, "3")
		assert(cup and cup.Position.Z < 16 and cup.Position.Z > 13, "cup should sit in front of the S wall (z 16): " .. tostring(cup))
	end)

	test("Apartment edits: only what you own, no overlaps, tabletop only on tables, pick up takes what's on it", function()
		local Apt = Paths.server("ApartmentService")
		local rooms = Paths.shared("GridMath").rooms(Paths.Assets.Apartment[D.APARTMENT.defaultStyle])
		local data = { Decor = { Table = 1, FengTrophy = 1 }, Apartment = { Style = D.APARTMENT.defaultStyle, Layouts = {}, NextUid = 1 } }
		local items = Apt.layout(data)
		local ok, msg = Apt.edit(data, rooms, "Place", { item = "Table", room = "Main", x = 0, z = 0, rot = 0 })
		assert(ok and msg == "1", "table: " .. msg)
		ok, msg = Apt.edit(data, rooms, "Place", { item = "Table", room = "Main", x = 4, z = 0, rot = 0 })
		assert(not ok and msg == "none left", "a second table we don't own: " .. msg)
		ok, msg = Apt.edit(data, rooms, "Place", { item = "Chair", room = "Main", x = 4, z = 0, rot = 0 })
		assert(not ok and msg == "none left", "a chair we don't own: " .. msg)
		ok, msg = Apt.edit(data, rooms, "Place", { item = "FengTrophy", room = "Main", x = 1, z = 1, rot = 0 })
		assert(not ok and msg == "overlaps", "trophy under the table: " .. msg)
		for _, bad in { { item = "FengTrophy", room = "Main", parent = "1", x = 0, z = 0, rot = 0 }, { item = "FengTrophy", room = "Main", wall = "Main/N", x = 0, z = 0, rot = 0 }, { item = "FengTrophy", x = 0, z = 0, rot = 0 }, { item = "FengTrophy", wall = 5, x = 0, z = 0, rot = 0 }, "nope", { item = 5 } } do
			ok, msg = Apt.edit(data, rooms, "Place", bad)
			assert(not ok and msg == "bad request", "malformed place: " .. msg)
		end
		local cup
		ok, cup = Apt.edit(data, rooms, "Place", { item = "FengTrophy", parent = "1", x = 0, z = 1, rot = 0, junk = true })
		assert(ok and items[cup].parent == "1" and items[cup].junk == nil, "trophy on the table: " .. cup)
		-- Moving the table carries the trophy (it's stored relative to the table).
		ok, msg = Apt.edit(data, rooms, "Move", "1", { item = "Table", room = "Main", x = 4, z = 4, rot = 1 })
		assert(ok and items["1"].x == 4 and items["1"].rot == 1 and items[cup].parent == "1", "move the table: " .. msg)
		ok, msg = Apt.edit(data, rooms, "Move", "1", { item = "Chair", room = "Main", x = 0, z = 0, rot = 0 })
		assert(not ok, "a move can't swap the item")
		ok, msg = Apt.edit(data, rooms, "Move", cup, { item = "FengTrophy", parent = cup, x = 0, z = 0, rot = 0 })
		assert(not ok, "the trophy can't sit on itself")
		-- Picking the table up takes the trophy too; both are free to place again, uids never reused.
		local gone
		ok, msg, _, gone = Apt.edit(data, rooms, "PickUp", "1")
		assert(ok and #gone == 2 and next(items) == nil, "pick up: " .. #gone)
		ok, msg = Apt.edit(data, rooms, "Place", { item = "Table", room = "Main", x = 0, z = 0, rot = 0 })
		assert(ok and msg == "3", "table again: " .. msg)
		assert(not Apt.edit(data, rooms, "Explode", "3"), "unknown action")
		-- Styles keep their own layouts: in another style the table is free again; switching back keeps the old one.
		local other = "MidoriTestStyle"
		local stale = Paths.Assets.Apartment:FindFirstChild(other)
		if stale then
			stale:Destroy() -- left by a run that died here
		end
		local model = Paths.Assets.Apartment[D.APARTMENT.defaultStyle]:Clone()
		model.Name = other
		model.Parent = Paths.Assets.Apartment
		data.Apartment.Style = other
		ok, msg = Apt.edit(data, rooms, "Place", { item = "Table", room = "Main", x = 0, z = 0, rot = 0 })
		assert(ok and Apt.layout(data)[msg] and not items[msg], "table in the other style: " .. msg)
		model:Destroy()
		assert(Apt.styleOf(data) == D.APARTMENT.defaultStyle and Apt.layout(data) == items and items["3"], "a removed style falls back to the default's layout")
	end)

	test("Furniture shop: buying costs the price and adds one; not for sale / too poor refused", function()
		local Apt = Paths.server("ApartmentService")
		local chair = Paths.furniture("Chair")
		local data = { Bux = chair.price * 2 + 1, Decor = { Chair = 2 } }
		local ok, msg = Apt.buy(data, "Chair")
		assert(ok and data.Decor.Chair == 3 and data.Bux == chair.price + 1, "buy a chair: " .. msg)
		ok, msg = Apt.buy(data, "FengTrophy")
		assert(not ok and msg == "not for sale" and data.Decor.FengTrophy == nil, "the trophy isn't sold: " .. msg)
		ok, msg = Apt.buy(data, "Nope")
		assert(not ok and msg == "not for sale", "unknown item: " .. msg)
		ok = Apt.buy(data, "Chair")
		assert(ok and data.Bux == 1, "second chair")
		ok, msg = Apt.buy(data, "Chair")
		assert(not ok and msg == "not enough bux" and data.Bux == 1 and data.Decor.Chair == 4, "too poor: " .. msg)
		for _, id in Paths.furnitureIds() do
			local def = Paths.furniture(id)
			assert(Paths.Assets.Furniture:FindFirstChild(id), `furniture {id} has no model`)
			assert(def.price == nil or (typeof(def.price) == "number" and def.price >= 0), `furniture {id} has a bad price`)
		end
	end)

	test("Wall paint: per room + per style, material and colour kept apart, bad values refused", function()
		local Apt = Paths.server("ApartmentService")
		local GridMath = Paths.shared("GridMath")
		local style = Paths.Assets.Apartment[D.APARTMENT.defaultStyle]
		local rooms = GridMath.rooms(style)
		local data = { Apartment = { Style = D.APARTMENT.defaultStyle, Layouts = {}, NextUid = 1 } } -- no Walls: an old profile
		local brick, color = D.APARTMENT.wallMaterials[3], D.APARTMENT.wallColors[2]
		assert(Apt.paint(data, rooms, "Main", "m", brick), "material")
		assert(Apt.paint(data, rooms, "Main", "c", color), "colour")
		local main = Apt.walls(data).Main
		assert(main.m == brick and main.c == color, "both halves kept")
		assert(Apt.walls(data).Bedroom == nil, "the other room untouched")
		assert(not Apt.paint(data, rooms, "Main", "m", "Neon"), "material not on the list")
		assert(not Apt.paint(data, rooms, "Main", "c", "123456"), "colour not on the list")
		assert(not Apt.paint(data, rooms, "Garage", "m", brick), "unknown room")
		assert(not Apt.paint(data, rooms, "Main", "x", brick), "unknown kind")
		assert(main.m == brick and main.c == color, "refusals change nothing")
		assert(Apt.paint(data, rooms, "Main/Ceiling", "c", D.APARTMENT.wallColors[1]), "ceiling")
		assert(Apt.walls(data)["Main/Ceiling"].c == D.APARTMENT.wallColors[1] and main.c == color, "ceiling apart from the walls")
		assert(not Apt.paint(data, rooms, "Main/Floor", "c", color), "unknown surface")
		-- Every room in every style has its own paintable wall layer.
		for _, m in Paths.Assets.Apartment:GetChildren() do
			if m:IsA("Model") then
				for room in GridMath.rooms(m) do
					local w = m:FindFirstChild("Walls") and m.Walls:FindFirstChild(room)
					assert(w and w:IsA("Model") and w:GetAttribute("Paint") == room, `{m.Name} has no Walls/{room} model (Paint = "{room}")`)
				end
			end
		end
	end)

	test("DJ booth sound: rooms through a wall are neighbours, each hop quieter + more muffled, extenders clear", function()
		local RoomSound = Paths.shared("RoomSound")
		local GridMath = Paths.shared("GridMath")
		local cfg = D.DJ
		local starter = GridMath.rooms(Paths.Assets.Apartment[D.APARTMENT.defaultStyle])
		assert(RoomSound.neighbours(starter, cfg.wallGap).Main.Bedroom, "Starter: Main and Bedroom share a wall")
		-- A row of 4 rooms (10 studs wide, 2-stud walls) + one far off.
		local rooms = {}
		for i = 1, 4 do
			rooms["R" .. i] = { size = { 5, 5 }, origin = CFrame.new((i - 1) * 12, 0, 0) }
		end
		rooms.Far = { size = { 5, 5 }, origin = CFrame.new(0, 0, 100) }
		local h = RoomSound.hops(rooms, { R1 = 0 }, cfg.wallGap)
		assert(h.R1 == 0 and h.R2 == 1 and h.R3 == 2 and h.R4 == 3 and h.Far == math.huge, "hops along the row")
		local v0, hi0 = RoomSound.mix(0, cfg)
		local v1, hi1, mid1 = RoomSound.mix(1, cfg)
		local v2, hi2 = RoomSound.mix(2, cfg)
		assert(v0 == 1 and hi0 == 0, "booth room is clear")
		assert(v1 < v0 and v2 < v1 and hi1 < 0 and hi2 < hi1 and mid1 < 0, "each hop quieter and more muffled")
		assert(RoomSound.mix(math.huge, cfg) == 0, "unreachable is silent")
		h = RoomSound.hops(rooms, { R1 = 0, R3 = cfg.extenderHops }, cfg.wallGap)
		assert(h.R3 == cfg.extenderHops and h.R4 == cfg.extenderHops + 1, "an extender room is clear and carries on")
		for _, id in { "DJBooth", "SoundExtender" } do
			assert(Paths.furniture(id) and Paths.Assets.Furniture:FindFirstChild(id), id .. " data + model")
		end
		assert(Paths.furniture("DJBooth").dj and Paths.furniture("SoundExtender").speaker, "flags")
	end)

	test("DJ booth pick: any song under Assets.Music by path, or shuffle; anything else refused", function()
		local Apt = Paths.server("ApartmentService")
		local data = { Apartment = {} }
		local song: Sound? = nil
		for _, s in Paths.Assets.Music:GetDescendants() do
			if s:IsA("Sound") then
				song = s
				break
			end
		end
		assert(Apt.setDJ(data, "", 5) and data.Apartment.DJ.song == "" and data.Apartment.DJ.at == 5, "shuffle")
		if song then
			local path = (song.Parent :: Instance).Name .. "/" .. song.Name
			if song.Parent == Paths.Assets.Music then
				path = song.Name
			end
			assert(Apt.song(path) == song, "path finds the song")
			assert(Apt.setDJ(data, path, 9) and data.Apartment.DJ.song == path and data.Apartment.DJ.at == 9, "pick")
		end
		for _, bad in { "Nope/Nothing", 5, "../x", string.rep("a", 300) } do
			assert(not Apt.setDJ(data, bad, 1), "refused: " .. tostring(bad))
		end
		assert(data.Apartment.DJ.at ~= 1, "a refusal changes nothing")
	end)

	test("Apartment access: unlocked = anyone; locked = owner + list (+ friends if on); list add / remove / cap", function()
		local Apt = Paths.server("ApartmentService")
		local data = { Apartment = {} } -- an old save: no Access yet
		local access = Apt.access(data)
		assert(access.Locked == false and access.Friends == true, "defaults: unlocked, friends on")
		assert(Apt.allowed(access, 1, 2, false), "unlocked: anyone")
		assert(Apt.setAccess(data, "Lock", true) and access.Locked, "lock")
		assert(Apt.allowed(access, 1, 1, false), "the owner always")
		assert(not Apt.allowed(access, 1, 2, false), "locked: a stranger is out")
		assert(Apt.allowed(access, 1, 2, true), "locked: friends in while Friends is on")
		assert(Apt.setAccess(data, "Friends", false) and not Apt.allowed(access, 1, 2, true), "friends off: out")
		assert(Apt.setAccess(data, "Allow", 2, "Two") and Apt.allowed(access, 1, 2, false), "listed: in")
		assert(not Apt.setAccess(data, "Allow", 2, "Two"), "already listed")
		assert(Apt.setAccess(data, "Allow", 2, false) and not Apt.allowed(access, 1, 2, false), "removed: out")
		assert(not Apt.setAccess(data, "Allow", 2, false), "removing someone not listed")
		assert(not Apt.setAccess(data, "Allow", 3, nil), "adding needs a name (server-side: only players in the server)")
		assert(not Apt.setAccess(data, "Allow", 1.5, "x") and not Apt.setAccess(data, "Lock", "yes"), "bad values")
		for i = 1, D.APARTMENT.listMax do
			assert(Apt.setAccess(data, "Allow", 100 + i, "p"), "fill " .. i)
		end
		assert(not Apt.setAccess(data, "Allow", 9999, "p"), "list cap")
	end)

	test("Locker slots: Bux buys the 6 tiers in order; Robux slots add on top and never use up a Bux tier", function()
		local PlayerData = Paths.server("PlayerData")
		local RerollService = Paths.server("RerollService")
		local prices = D.LOCKER_BUX_PRICES
		assert(#prices == 6 and prices[1] == 50 and prices[6] == 1000, "the user's tiers")
		local total = 0
		for _, p in prices do
			total += p
		end
		local data = { SchemaVersion = 99, Bux = total + 5, ExtraSlots = 0, Loadout = {}, Locker = {} } -- an old save: no BuxSlots
		PlayerData.fitLocker(data)
		assert(#data.Locker == D.LOCKER_SLOTS, "free slots")
		-- A Robux slot first (what the product handler does): Bux tier 1 is still 50.
		data.ExtraSlots += 1
		PlayerData.fitLocker(data)
		assert(#data.Locker == D.LOCKER_SLOTS + 1, "robux slot added")
		for i, price in prices do
			local before = data.Bux
			assert(RerollService.buySlot(data), "tier " .. i)
			assert(before - data.Bux == price and data.BuxSlots == i, "tier " .. i .. " costs " .. price)
		end
		assert(#data.Locker == D.LOCKER_SLOTS + 1 + #prices, "every slot there")
		local ok, msg = RerollService.buySlot(data)
		assert(not ok and msg == "all bux slots bought" and data.Bux == 5, "no 7th bux slot: " .. msg)
		data.ExtraSlots += 1
		PlayerData.fitLocker(data)
		assert(#data.Locker == D.LOCKER_SLOTS + 2 + #prices, "robux still adds after the bux ones")
		local poor = { Bux = 49, BuxSlots = 0, ExtraSlots = 0, Loadout = {}, Locker = {} }
		ok, msg = RerollService.buySlot(poor)
		assert(not ok and msg == "not enough bux" and poor.Bux == 49 and poor.BuxSlots == 0, "too poor: " .. msg)
	end)

	test("Panel furniture give: adds to the bag; unknown ids and bad amounts refused", function()
		local Apt = Paths.server("ApartmentService")
		local data = { Decor = { Chair = 2 } }
		assert(Apt.give(data, "Chair", 3) == 5 and data.Decor.Chair == 5, "adds to what they own")
		assert(Apt.give(data, "DJBooth", 1) == 1, "new id starts at 0")
		for _, bad in { { "Nope", 1 }, { "Chair", 0 }, { "Chair", 1.5 }, { "Chair", 1000 }, { 5, 1 } } do
			assert(Apt.give(data, bad[1], bad[2]) == nil, `refused {tostring(bad[1])} x{bad[2]}`)
		end
		assert(data.Decor.Chair == 5, "refusals change nothing")
	end)

	test("Locker trash: empties that slot only (slot kept), empty / bad slots refused", function()
		local RerollService = Paths.server("RerollService")
		local data = { Locker = { { Kind = "Look", Slot = "Hat", Id = 5 }, { Kind = "" }, { Kind = "Style", Style = "Feng", Traits = {}, Locks = {} } } }
		assert(RerollService.trash(data, 1) and data.Locker[1].Kind == "", "trashed slot 1")
		assert(#data.Locker == 3 and data.Locker[3].Kind == "Style", "other slots untouched, slot count kept")
		assert(not RerollService.trash(data, 2), "empty slot")
		assert(not RerollService.trash(data, 9) and not RerollService.trash(data, "1"), "bad slot")
	end)

	test("Roles: several at once, old single saves still read, chips add / remove, Player clears, owner keeps Owner", function()
		local RS = Paths.server("RoleService")
		local Roles = Paths.data("Roles")
		local id = 999000111 -- nobody (no defaults entry)
		assert(RS.rolesOf(id, nil)[1] == "Player" and #RS.rolesOf(id, nil) == 1, "nothing saved = Player")
		assert(RS.rolesOf(id, "Tester")[1] == "Tester", "old single-name save")
		local both = RS.rolesOf(id, { "content creator", "Staff", "Nope" })
		assert(#both == 2 and both[1] == "Staff" and both[2] == "Content Creator", "list: unknown dropped, highest first")
		assert(RS.rolesOf(id, {})[1] == "Player", "empty list = Player (strip)")
		local list = RS.toggle({ "Staff" }, id, "Content Creator")
		assert(#list == 2 and table.find(list, "Staff") and table.find(list, "Content Creator"), "chip adds")
		list = RS.toggle(list, id, "Staff")
		assert(#list == 1 and list[1] == "Content Creator", "chip on a held role removes it")
		assert(#RS.toggle(list, id, "Player") == 0, "Player clears")
		local ownerRoles = RS.rolesOf(D.OWNER_USER_ID, { "Content Creator" })
		assert(ownerRoles[1] == "Owner" and table.find(ownerRoles, "Content Creator"), "owner keeps Owner plus extras")
		local saved = RS.toggle({ "Content Creator" }, D.OWNER_USER_ID, "Tester")
		assert(not table.find(saved, "Owner"), "Owner is never saved")
		assert(Roles.roles["Content Creator"].freeSpins == false and Roles.roles["Content Creator"].title == "Content Creator", "content creator: title, no free rerolls")
		assert(Paths.data("Titles")["Content Creator"], "content creator title exists")
		for d, uid in Roles.defaults do
			assert(RS.rolesOf(d, nil)[1] == uid, "defaults still apply")
		end
	end)

	test("DJ booth OFF: 'off' is a valid pick", function()
		local Apt = Paths.server("ApartmentService")
		local data = { Apartment = {} }
		assert(Apt.setDJ(data, "off", 3) and data.Apartment.DJ.song == "off", "off")
		assert(Apt.setDJ(data, "", 4) and data.Apartment.DJ.song == "", "back to shuffle")
	end)

	test("PlayerData v8: Decor true -> 1 and everyone gets the starter furniture", function()
		local PlayerData = Paths.server("PlayerData")
		local data = { SchemaVersion = 7, Decor = { FengTrophy = true, Chair = 5 }, Loadout = {}, Locker = {}, ExtraSlots = 0 }
		PlayerData.migrate(data)
		assert(data.Decor.FengTrophy == 1 and data.Decor.Chair == 5 and data.Decor.Table == D.APARTMENT.starter.Table, "decor after v8")
		-- v9: the single layout becomes the default style's.
		local v8 = { SchemaVersion = 8, Decor = {}, Apartment = { Items = { ["1"] = { item = "Bed", room = "Main", x = 0, z = 0, rot = 0 } }, NextUid = 2 }, Loadout = {}, Locker = {}, ExtraSlots = 0 }
		PlayerData.migrate(v8)
		local apt = v8.Apartment
		assert(apt.Items == nil and apt.Layouts[D.APARTMENT.defaultStyle]["1"].item == "Bed" and apt.Style == D.APARTMENT.defaultStyle and apt.NextUid == 2, "apartment after v9")
		-- v10: the old "TV" is the Monitor now (owned + placed, every style); the new "TV" id is the 2x one.
		local v9 = { SchemaVersion = 9, Decor = { TV = 2, Monitor = 1 }, Apartment = { Style = "Starter", NextUid = 3, Layouts = { Starter = { ["1"] = { item = "TV", room = "Main", x = 0, z = 0, rot = 0 } }, Other = { ["2"] = { item = "TV", room = "Main", x = 0, z = 0, rot = 0 } } } }, Loadout = {}, Locker = {}, ExtraSlots = 0 }
		PlayerData.migrate(v9)
		assert(v9.Decor.TV == nil and v9.Decor.Monitor == 3, "decor after v10")
		assert(v9.Apartment.Layouts.Starter["1"].item == "Monitor" and v9.Apartment.Layouts.Other["2"].item == "Monitor", "placed TVs after v10")
	end)

	test("Apartment posters: decal id on posters only, kept when moved", function()
		local Apt = Paths.server("ApartmentService")
		local data = { Decor = { Poster = 1, Table = 1 }, Apartment = { Style = D.APARTMENT.defaultStyle, NextUid = 3, Layouts = { [D.APARTMENT.defaultStyle] = {
			["1"] = { item = "Poster", wall = "Main/N", x = 0, z = 2, rot = 0 },
			["2"] = { item = "Table", room = "Main", x = 0, z = 0, rot = 0 },
		} } } }
		local items = Apt.layout(data)
		assert(Apt.setImage(data, "1", 12179880823) and (items["1"] :: any).img == 12179880823, "poster id")
		assert(not Apt.setImage(data, "2", 5), "a table took a picture")
		for _, bad in { 0, -4, 1.5, "123", 2 ^ 60 } do
			assert(not Apt.setImage(data, "1", bad), "bad id taken: " .. tostring(bad))
		end
		assert(not Apt.setImage(data, "9", 5), "missing uid")
		assert((items["1"] :: any).img == 12179880823, "refusals changed it")
		local rooms = { Main = { origin = CFrame.new(), size = { 20, 20 }, height = 10 } }
		local ok = Apt.edit(data, rooms, "Move", "1", { item = "Poster", wall = "Main/N", x = 2, z = 2, rot = 0 })
		assert(ok and (items["1"] :: any).img == 12179880823, "move lost the picture")
	end)
	test("Apartment styles: paid styles bought once with Bux, free ones always owned; Flat costs 800", function()
		local Apt = Paths.server("ApartmentService")
		assert(Apt.stylePrice("Flat") == 800, "Flat price " .. Apt.stylePrice("Flat"))
		assert(Apt.stylePrice(D.APARTMENT.defaultStyle) == 0, "the default style costs something")
		local data = { Bux = 799, Apartment = {} }
		assert(Apt.ownsStyle(data, D.APARTMENT.defaultStyle, 0), "default not owned")
		local ok, msg = Apt.buyStyle(data, "Flat", 800)
		assert(not ok and msg == "not enough bux" and data.Bux == 799, "bought without the Bux")
		data.Bux = 1000
		ok, msg = Apt.buyStyle(data, "Flat", 800)
		assert(ok and msg == "bought" and data.Bux == 200 and data.Apartment.Styles.Flat, "buy")
		ok, msg = Apt.buyStyle(data, "Flat", 800)
		assert(ok and msg == "owned" and data.Bux == 200, "charged twice")
	end)
	test("PlayerData v11: wall items' spots double onto the 1-stud wall grid, same place", function()
		local PlayerData = Paths.server("PlayerData")
		local G = Paths.shared("GridMath")
		local v10 = { SchemaVersion = 10, Decor = {}, Apartment = { Style = "Starter", NextUid = 3, Layouts = { Starter = {
			["1"] = { item = "Poster", wall = "Main/N", x = 3, z = 1, rot = 0 },
			["2"] = { item = "Table", room = "Main", x = 3, z = 1, rot = 0 },
		} } }, Loadout = {}, Locker = {}, ExtraSlots = 0 }
		local rooms = { Main = { size = { 10, 14 }, origin = CFrame.new(), height = 5 } }
		local get = function(id: string): any
			return Paths.furniture(id)
		end
		-- where it was on the old 2-stud wall grid
		local def = get("Poster")
		local old = G.walls(rooms)["Main/N"].origin * CFrame.new((3 + def.size[1] / 2) * 2, (1 + def.size[2] / 2) * 2, 0)
		PlayerData.migrate(v10)
		local items = v10.Apartment.Layouts.Starter
		assert(items["1"].x == 6 and items["1"].z == 2, "wall spot not doubled")
		assert(items["2"].x == 3 and items["2"].z == 1, "a floor item moved")
		local now = G.cframe(items, rooms, get, "1")
		assert(now and now.Position:FuzzyEq(old.Position), `poster moved: {now} vs {old.Position}`)
	end)
	disconnect()
	Registry.remove(A)
	Registry.remove(B)
	A:Destroy()
	B:Destroy()

	table.insert(lines, string.format("%d passed, %d failed", passed, failed))
	return table.concat(lines, string.char(10))
end

return Tests
