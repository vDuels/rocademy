--!strict
-- Client side of Midori combat for the local character: reads input, predicts the local
-- fighter's state so actions feel instant, and plays its animations. It mirrors the
-- server's rules; the server stays authoritative and corrects us via HitResult and StateSync.
--   M1 = left mouse (hold to chain), M2 = right mouse, R = crit, F = block, Q = dash
-- Holding F is a block buffer: you block the instant blocking becomes legal (after an
-- attack, the block cooldown or a stun), and every buffered block is a fresh press, so it
-- can parry. A landed parry cancels the hold: you must press F again to block.
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Enums = Paths.shared("Enums")
local Net = Paths.shared("Net")
local MoveSchema = Paths.shared("MoveSchema")
local CombatMath = Paths.shared("CombatMath")
local AnimationHandler = Paths.shared("AnimationHandler")
local Reactions = Paths.shared("Reactions")
local DashMotor = Paths.shared("DashMotor")
local RushMotor = Paths.shared("RushMotor")
local Hitbox = Paths.shared("Hitbox")
local Height = Paths.shared("Height")
local Feedback = Paths.client("FeedbackController")
local Status = Paths.client("StatusController")
local ColorShift = Paths.client("ColorShift")
local Hud = Paths.client("HudController")
local BlinkLane = Paths.client("BlinkLane")
local WindTrail = Paths.shared("WindTrail")

local State, Result = Enums.State, Enums.Result

local KEY_ACTIONS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.R] = "R",
	[Enum.KeyCode.F] = "Block",
	[Enum.KeyCode.Q] = "Dash",
}
-- Gamepad buttons + on-screen touch buttons (ContextActionService). Touch positions are relative to
-- Roblox's button area by the jump button. ponytail: picked blind; tune them on a real phone.
local PAD_TOUCH = {
	{ name = "MidoriM1", action = "M1", title = "M1", pad = Enum.KeyCode.ButtonR2, pos = UDim2.new(0.55, 0, 0.2, 0) },
	{ name = "MidoriM2", action = "M2", title = "M2", pad = Enum.KeyCode.ButtonR1, pos = UDim2.new(0.15, 0, 0.45, 0) },
	{ name = "MidoriCrit", action = "R", title = "CRIT", pad = Enum.KeyCode.ButtonY, pos = UDim2.new(0.35, 0, -0.1, 0) },
	{ name = "MidoriBlock", action = "Block", title = "BLOCK", pad = Enum.KeyCode.ButtonL2, pos = UDim2.new(-0.05, 0, 0.75, 0) },
	{ name = "MidoriDash", action = "Dash", title = "DASH", pad = Enum.KeyCode.ButtonB, pos = UDim2.new(0.75, 0, -0.15, 0) },
}

local QUEUE_TTL: { [string]: number } = {
	attack = D.INPUT_BUFFER,
	dash = D.DASH_BUFFER,
}
local BLOCK_RETRY = 0.1 -- if the server rejected a buffered block, wait this long before retrying
local ACK_TIMEOUT = 0.6 -- stop waiting for the server to confirm an attack after this long
local MAX_BACKDATE = 0.05 -- most a buffered action may be started in the past (a few frames)
local FUSE_CONFIRM_SLACK = 0.6 -- round trip on top of the server's queue time before an unlit fuse unlocks
local FLEE_PREDICT = 0.5 -- a predicted dash-away flee chunk holds this long, waiting for the server's "Flee"

local CombatController = {}

-- `run` (from RunController) is stopped by attacks, blocks and getting hit.
-- `mode` (from CombatModeController): attacks and blocks only work while it is on.
-- `soda` (from SodaController): while it's holding a can, M1 drinks instead.
-- `skate` (from SkateController): while riding it takes M1 / M2 / Dash for its board moves.
function CombatController.start(character: Model, run: any?, mode: any?, soda: any?, skate: any?): () -> ()
	local function interruptRun()
		if run then
			run.stop()
		end
	end
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	-- Seated counts as out of combat mode (user, 2026-10-29: no fighting styles while sitting; the server
	-- refuses attacks / blocks / dashes too).
	local function inCombatMode(): boolean
		return (mode == nil or mode.isOn()) and not humanoid.Sit
	end
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local animator = humanoid:WaitForChild("Animator") :: Animator
	-- Both are swapped when the server changes our style (",e <Style>", see StyleService).
	local style = MoveSchema.ofModel(character)
	local fa = AnimationHandler.new(animator, style)

	local AttackRemote = Net.get("Attack")
	local BlockRemote = Net.get("Block")
	local DashRemote = Net.get("Dash")

	local S = {
		state = State.Idle,
		endsAt = math.huge,
		move = nil :: any,
		chainIndex = 1,
		chainResetAt = 0,
		blockKey = false,
		stripPending = false,
		blockedHit = false, -- this block took a hit (not a strip): releasing it has no cooldown (mirrors the server)
		parryUnguard = false,
		nextBlockTry = 0,
		blockCooldownUntil = 0,
		actLockUntil = 0,
		noBlockUntil = 0,
		dashCooldownUntil = 0,
		dashLockUntil = 0,
		m1LockUntil = 0,
		m2CooldownUntil = 0,
		rCooldownUntil = 0,
		m1Held = false,
		stateStartedAt = 0,
		-- Sent an attack the server hasn't confirmed yet. Never predict a second one on top,
		-- so the client can't run ahead of the server.
		awaitingAck = false,
		ackDeadline = 0,
		queued = nil :: { kind: string, arg: any, at: number }?,
		cancelDash = nil :: (() -> ())?, -- stops the dash or rush motor
		dashDir = Vector3.zero, -- the last dash's direction, steering and speed (a dash M1 carries it on)
		dashSteer = nil :: (() -> Vector3)?,
		dashSpeed = nil :: number?,
		rushMotor = nil :: any,
		rushBudget = 0, -- studs, from the adrenaline at attack start (mirrors the server)
		rushContact = false, -- our rush touched someone locally; waiting on the server's verdict
		bonusSpent = 0, -- bonus dashes we used that the server's BonusDashes doesn't show yet
		endlagEndedAt = -math.huge, -- running waits D.RUN_AFTER_ENDLAG after this
		startupLanded = false, -- our swing connected while still in Startup (early drag hit): no dash-cancel
		refreshedMove = nil :: any, -- our landed cooldownRefresh move (Eject): its endlag cuts its cooldown
		unlockTarget = nil :: Model?, -- who our last unlocking hit (Eject) landed on: Reentry aims at them
		held = {} :: { [string]: boolean }, -- attack buttons held down (charge moves read M2 / R)
		chargeMinEnd = 0, -- a charge move's windup can't end before this (its base startup)
		swung = false, -- a swing charge move (Slugger M2) has been released this attack
		releasedAt = nil :: number?, -- when it was released (a blink lane stops growing there)
		shiftMove = nil :: any, -- the move our useShift colour shift belongs to
		shiftRelease = nil :: (() -> ())?, -- ends it
		grabAt = nil :: number?, -- our landed grab's follow-up time (server clock, HitResult info.grab)
		rootUntil = nil :: number?, -- grabbed: no walking until the follow-up's hit (server clock, info.rootUntil)
		fuseKind = nil :: string?, -- "R" / "M2": a fuse we asked to light, not confirmed by its cooldown attribute yet
		fusePendingUntil = 0, -- give up on it then: the server never lit it, so drop the provisional lock
		fuseSentAt = 0,
	}
	local conns: { RBXScriptConnection } = {}

	-- The server only swaps styles while we're Idle out of combat mode, so nothing is mid-move.
	table.insert(conns, character:GetAttributeChangedSignal("Style"):Connect(function()
		local new = MoveSchema.ofModel(character)
		if new == style then
			return
		end
		style = new
		fa:destroy()
		fa = AnimationHandler.new(animator, style)
		S.chainIndex = 1
		S.move = nil
		S.queued = nil
	end))

	-- Running is only allowed while idle or dashing, not in dash endlag, and not for
	-- D.RUN_AFTER_ENDLAG after an attack's endlag (a held Shift resumes it afterward).
	if run then
		run.setGate(function()
			if S.state == State.Idle then
				return workspace:GetServerTimeNow() - S.endlagEndedAt >= D.RUN_AFTER_ENDLAG
			end
			return S.state == State.Dash
		end)
	end

	local function now(): number
		return workspace:GetServerTimeNow()
	end

	local function adrenaline(): number
		local v = character:GetAttribute("Adrenaline")
		return if typeof(v) == "number" then v else 0
	end

	-- Bonus dashes the server says we hold, minus ones we've already spent locally.
	local function bonusDashes(): number
		local v = character:GetAttribute("BonusDashes")
		return (if typeof(v) == "number" then v else 0) - S.bonusSpent
	end
	-- Any server update to the count already includes our spends.
	table.insert(conns, character:GetAttributeChangedSignal("BonusDashes"):Connect(function()
		S.bonusSpent = 0
	end))

	-- `at` lets transitions use their scheduled time instead of this frame's, so frame
	-- timing never stretches a state (mirrors the server; see CombatService.onExpire).
	local function setState(state: string, duration: number?, at: number?)
		local start = at or now()
		-- Rooted in place: a whiffed rush's endlag (straight after the miss carry), the parried
		-- stun and the guard-break stun (user, 2026-10-10), and a `rooted` move's startup + endlag.
		if run then
			local rootedMove = ((state == State.Startup or state == State.Endlag) and S.move ~= nil and S.move.rooted)
				or (state == State.Startup and S.move ~= nil and S.move.charge ~= nil and S.move.charge.swing ~= nil) -- swing charge windup (released in releaseSwing)
			run.setRooted(rootedMove or (state == State.Endlag and S.state == State.RushMiss) or state == State.ParryStun or state == State.GuardBreakStun
				or (S.rootUntil ~= nil and start < S.rootUntil))
		end
		if state ~= State.Endlag then
			S.grabAt = nil -- our landed grab's follow-up only comes out of that move's endlag
		end
		if S.state == State.Endlag and state ~= State.Endlag then
			S.endlagEndedAt = start
		end
		if state == State.Startup then
			S.startupLanded = false
		end
		S.state = state
		S.stateStartedAt = start
		S.endsAt = if duration then start + duration else math.huge
		-- Local-only (client attributes don't replicate): ShieldController shows our own shield
		-- from the predicted state instead of waiting a round trip for MState.
		character:SetAttribute("LocalMState", state)
	end

	local function stopDash()
		if S.cancelDash then
			S.cancelDash()
			S.cancelDash = nil
		end
	end

	local function canAct(): boolean
		return S.state == State.Idle and now() >= S.actLockUntil
	end

	-- When an attack of this kind is next allowed: M1 combo-end lock, move cooldowns.
	local function kindLock(kind: string): number
		if kind == "M1" then
			return S.m1LockUntil
		elseif kind == "M2" then
			return S.m2CooldownUntil
		elseif kind == "R" then
			return S.rCooldownUntil
		end
		return 0
	end

	local function canBlock(t: number): boolean
		return canAct() and t >= S.blockCooldownUntil and t >= S.noBlockUntil
	end

	local function release(t: number)
		S.stripPending = false
		S.parryUnguard = false
		setState(State.Idle, nil, t)
		S.blockCooldownUntil = t + (if S.blockedHit then D.BLOCK_COOLDOWN_AFTER_BLOCK else D.BLOCK_COOLDOWN)
		S.actLockUntil = t + D.RELEASE_ACT_DELAY
		fa:setBlock(false)
	end

	local function attrNum(name: string, default: number): number
		local v = character:GetAttribute(name)
		return if typeof(v) == "number" then v else default
	end
	-- Our Focus as 0-1 (0 without the meter), as the server reads it when an attack starts.
	local function focusRatio(): number
		if character:GetAttribute("FocusOn") ~= true then
			return 0
		end
		return math.clamp(attrNum("Focus", 0) / math.max(attrNum("FocusMax", 100), 1), 0, 1)
	end

	local function chainMove(move: any): any
		local perStep = character:GetAttribute("M1ChainEndlag")
		return CombatMath.chainMove(style, move, if type(perStep) == "number" then perStep else 0)
	end

	-- Same chain rules as the server; AttackStarted corrects us if we guessed wrong.
	local function predictMove(kind: string): any?
		if kind == "M1" then
			if now() >= S.chainResetAt then
				S.chainIndex = 1
			end
			local id = style.m1Chain[S.chainIndex]
			S.chainIndex = S.chainIndex % #style.m1Chain + 1
			S.chainResetAt = math.huge
			return style.moves[id]
		elseif kind == "M2" then
			S.chainIndex = 1
			return if style.m2 then style.moves[style.m2] else nil
		elseif kind == "R" then
			-- Mirrors the server: a `locked` move (Reentry) needs a landed unlock (Eject) first, and
			-- while it's unlocked R always throws it (no Eject up close).
			local function unlocked(m: any): boolean
				local untilT = character:GetAttribute("MoveUnlock_" .. m.id)
				return typeof(untilT) == "number" and now() <= untilT
			end
			local main = style.r and style.moves[style.r]
			if main and main.locked and unlocked(main) then
				return main
			end
			local m = CombatMath.rMove(style, root)
			if m and m.locked and not unlocked(m) then
				return nil
			end
			return m
		end
		return nil
	end

	local function tryAttack(kind: string, fromQueue: boolean?): boolean
		if not inCombatMode() then
			return true -- out of combat mode: swallow the input
		end
		local t = now()
		if S.awaitingAck and t >= S.ackDeadline then
			S.awaitingAck = false -- server never answered (dropped); stop waiting
		end
		-- Dash M1 (Furious Feng's dash kick), mirrors the server: a click DURING our dash throws style.dashM1
		-- now, cutting the dash (no queue, no chain, no combo-end lock).
		-- Dash M2 (KickCan) the same (no M2 cooldown gate; the chamber limits it).
		local dashId = if kind == "M1" then style.dashM1 elseif kind == "M2" then style.dashM2 else nil
		local dashMove = if dashId and S.state == State.Dash and not S.awaitingAck
			then style.moves[dashId]
			else nil
		-- Chambered Kick (mirrors the server): every dash attack needs a chambered dash, spends it, refunds the dash.
		local chamberKick = false
		for _, id in style.perks do
			local mods = Paths.perk(id).mods
			chamberKick = chamberKick or (mods ~= nil and (mods.dashM1Chamber or 0) > 0)
		end
		if dashMove and chamberKick and bonusDashes() <= 0 then
			dashMove = nil
		end
		if not dashMove and (not canAct() or S.awaitingAck or t < kindLock(kind)) then
			if not fromQueue then
				S.queued = { kind = "attack", arg = kind, at = t }
			end
			return false
		end
		local move = dashMove or predictMove(kind)
		if move then
			move = chainMove(move) -- mirrors the server's chain endlag (Measured Strikes)
		end
		if not move or move.cost > adrenaline() then
			return true -- nothing to do; consume the input
		end
		if move.fuse then
			-- Only lights the fuse: we stay free to act. Lock the move for the longest it could take;
			-- the server's real cooldown (RCooldownUntil) lowers it, and its StateSync starts the barrage.
			-- The lock is provisional (bug, 2026-10-25): if the server never lights it (queued then
			-- dropped, refused), the cooldown attribute never moves and the lock is lifted at fusePendingUntil.
			local lock = t + move.fuse.max + move.barrage.duration + move.endlag + move.cooldown
			if move.kind == "M2" then
				S.m2CooldownUntil = lock
			else
				S.rCooldownUntil = lock
			end
			S.fuseKind = move.kind
			S.fuseSentAt = t
			S.fusePendingUntil = t + D.INPUT_BUFFER + D.MAX_COMP + FUSE_CONFIRM_SLACK
			AttackRemote:FireServer(kind, t)
			return true
		end
		-- Mirrors the server: some perks (Firecracker) make M1s ignore adrenaline, speed bonus included.
		local ignoresAdr = move.kind == "M1" and character:GetAttribute("M1NoAdrenaline") == true
		local speed = if move.fixedStartup then 1 else CombatMath.speed(if ignoresAdr then 0 else adrenaline())
		-- Mirrors the server: chain mods (Measured Strikes) slow later chain M1s.
		local chainSlow = character:GetAttribute("M1ChainSlow")
		local chainDiv = 1 + (if type(chainSlow) == "number" then chainSlow else 0) * CombatMath.chainStep(style, move)
		speed /= chainDiv
		-- Mirrors the server: Focus cuts endlag and (Uppercut to the Moon) quickens the M2 windup.
		local focusSpeed
		move, focusSpeed = CombatMath.focusMove(move, focusRatio(), attrNum("M2FocusPower", 1), attrNum("M2FocusStartup", 0))
		speed *= focusSpeed
		-- Mirrors the server: height (D.HEIGHT) scales the hitbox and M2 cooldown.
		move = Height.move(move, Height.of(character))
		-- Mirrors the server: Slugger drops speed bonuses (they become damage there); slows still apply.
		if character:GetAttribute("SpeedToDamage") == true then
			speed = math.min(speed * chainDiv, 1) / chainDiv
		end
		-- Mirrors the server: drunk on Bloxy Cola (tier 2+) slows every attack.
		local drunk = character:GetAttribute("Drunk")
		if typeof(drunk) == "number" and drunk >= 2 then
			speed *= D.BLOXY.attackSpeed
		end
		speed *= Height.ofModel(character).swingSpeed -- mirrors the server: tall swings slower, short slightly faster
		interruptRun()
		if dashMove and chamberKick then
			S.bonusSpent += 1
			Status.chamberSpent()
			S.dashCooldownUntil = math.min(S.dashCooldownUntil, t)
			Status.dashUsed(S.dashCooldownUntil)
		end
		-- Buffered/held inputs start when the attack became legal (Idle start or M1 lock end),
		-- not on whichever frame noticed it, so chains keep exact data timing. Back-dating is
		-- capped at a couple of frames; a fresh click always starts now.
		local start = t
		if fromQueue then
			local legal = math.max(S.stateStartedAt, S.actLockUntil, kindLock(kind))
			start = math.clamp(legal, t - MAX_BACKDATE, t)
		end
		S.move = move
		if move.rush then
			S.rushBudget = move.rush.freeStuds + (if move.rush.adrPerStud > 0 then adrenaline() / move.rush.adrPerStud else 0)
		end
		-- Charge move still held: the windup runs on until we let go (no cap; the bonus caps at charge.time).
		-- A swing charge (Slugger M2) auto-releases at startup + charge.time; the hit is swing.hit after release.
		local charging = move.charge ~= nil and S.held[kind] == true
		local swing = move.charge and move.charge.swing
		local startup = move.startup / speed
		setState(State.Startup, if swing then (if charging then startup + move.charge.time else startup) + swing.hit
			elseif charging then nil
			else startup, start)
		S.chargeMinEnd = start + startup
		S.swung = false
		S.releasedAt = nil
		if move.blink then
			BlinkLane.show(character, move, start, startup, function(): number?
				return S.releasedAt
			end, function(): boolean
				return S.move == move and S.state == State.Startup
			end)
			-- Wind trail on our Torso from the press to the end of the move (local: no wait on the server).
			WindTrail.during(character, function(): boolean
				return S.move == move and (S.state == State.Startup or S.state == State.Endlag)
			end)
		end
		fa:playAttack(move, speed, true) -- a swing charge's swing comes from releaseSwing
		if move.step then
			-- Step-in: our own body moves forward partway through startup (players own their movement).
			local step, startedAt = move.step, S.stateStartedAt
			task.delay(math.max(0, start + step.at / speed - now()), function()
				if S.move == move and S.state == State.Startup and S.stateStartedAt == startedAt then
					stopDash()
					if step.dash and S.dashSpeed then
						-- Carries the dash on (style.dashM1): its direction (still steering with the camera) and speed.
						local dashSteer = S.dashSteer
						local dir = if dashSteer then dashSteer() else S.dashDir
						-- burst (the dash's own constant-speed motor), not apply (which eases out): the same dash, longer.
						S.cancelDash = DashMotor.burst(root, dir, S.dashSpeed * step.duration, step.duration, D.DASH_MAX_FORCE, dashSteer)
						return
					end
					local facing = CombatMath.flat(root.CFrame.LookVector)
					-- A steered step follows the camera every frame, no turn cap (Gio Critical).
					local steer = if step.steer
						then function(): Vector3
							local cam = workspace.CurrentCamera
							local look = if cam then CombatMath.flat(cam.CFrame.LookVector) else Vector3.zero
							return if look == Vector3.zero then facing else look
						end
						else nil
					S.cancelDash = DashMotor.apply(root, if steer then steer() else facing, step.distance, step.duration, D.DASH_MAX_FORCE, steer, step.steer)
				end
			end)
		end
		Feedback.swing(root, move.id, nil, speed)
		S.awaitingAck = true
		S.ackDeadline = t + ACK_TIMEOUT
		AttackRemote:FireServer(kind, t)
		return true
	end

	-- No queue: holding F is the buffer (see Heartbeat).
	local function tryBlock(): boolean
		local t = now()
		-- Out of combat mode a held F just waits (buffered) until T is pressed.
		if not inCombatMode() or not canBlock(t) or t < S.nextBlockTry then
			return false
		end
		S.stripPending = false
		S.blockedHit = false
		S.parryUnguard = false
		S.nextBlockTry = t + BLOCK_RETRY
		interruptRun()
		character:SetAttribute("LocalBlockPressAt", t)
		setState(State.BlockStart, D.BLOCK_START_DURATION)
		fa:setBlock(true)
		BlockRemote:FireServer(true, t)
		return true
	end

	local function tryDash(fromQueue: boolean?): boolean
		if humanoid.Sit then
			return true -- seated: swallowed, not buffered (the server refuses it too)
		end
		local t = now()
		-- Mirrors the server: a swing that already connected (early drag hit) can't be dash-cancelled.
		local fromStartup = S.state == State.Startup and not S.startupLanded
		local fromBlock = S.state == State.Blocking
		local legal = fromStartup or fromBlock or canAct()
		-- Normal dash first; a bonus dash (perks, e.g. Chambered Dash) only while it's on cooldown.
		local onCooldown = t < S.dashCooldownUntil
		local useBonus = onCooldown and bonusDashes() > 0
		if not legal or (onCooldown and not useBonus) or t < S.dashLockUntil then
			if not fromQueue then
				S.queued = { kind = "dash", arg = nil, at = t }
			end
			return false
		end
		-- Exactly where the movement input points (diagonals too), locked for the whole dash;
		-- no input = backdash (user, 2026-10-11, Gakuran-style). Kind (distance) is relative to the body.
		local facing = CombatMath.flat(root.CFrame.LookVector)
		local input = CombatMath.flat(humanoid.MoveDirection)
		local dir = if input ~= Vector3.zero then input.Unit else -facing
		local kind = DashMotor.classify(facing, dir)
		-- Mirrors the server: in a slow zone (Slugger Critical) no back dash, and dashes are shorter.
		local slowed = CombatMath.inSlowZone(character, root.Position, t)
		if slowed and kind == "Back" then
			return true -- swallowed, not buffered
		end
		if fromStartup then
			-- A cancelled M2/crit windup still goes on cooldown (mirrors the server).
			local m = S.move
			if m and m.cooldown > 0 then
				if m.kind == "M2" then
					S.m2CooldownUntil = t + m.cooldown
				elseif m.kind == "R" then
					S.rCooldownUntil = t + m.cooldown
				end
			end
			fa:stopAttacks()
			S.move = nil
		end
		if fromBlock then
			S.blockKey = false -- dashing out of block needs a fresh press to block again
			S.blockCooldownUntil = t + (if S.blockedHit then D.BLOCK_COOLDOWN_AFTER_BLOCK else D.BLOCK_COOLDOWN)
			fa:setBlock(false)
		end
		fa:playDash(root.CFrame.LookVector, dir)
		local heightStats = Height.ofModel(character) -- mirrors the server (D.HEIGHT)
		local distance = DashMotor.distance(kind, fromStartup, slowed) * heightStats.dashDistance
		stopDash()
		-- Gakuran burst (constant speed, slides out into a walk) + steering (user, 2026-10-13): the
		-- dash keeps its angle relative to the live camera.
		local cam = workspace.CurrentCamera
		local look0 = if cam then CombatMath.flat(cam.CFrame.LookVector) else Vector3.zero
		local steer: (() -> Vector3)? = nil
		if cam and look0 ~= Vector3.zero then
			local offset = CFrame.lookAlong(Vector3.zero, look0):VectorToObjectSpace(dir)
			steer = function(): Vector3
				local look = CombatMath.flat(cam.CFrame.LookVector)
				if look == Vector3.zero then
					return dir
				end
				return CFrame.lookAlong(Vector3.zero, look):VectorToWorldSpace(offset)
			end
		end
		S.cancelDash = DashMotor.burst(root, dir, distance, D.DASH_DURATION, D.DASH_MAX_FORCE, steer)
		-- A dash M1 (style.dashM1, step.dash) carries this dash on: same direction, steering and speed.
		S.dashDir, S.dashSteer, S.dashSpeed = dir, steer, distance / D.DASH_DURATION
		setState(State.Dash, D.DASH_DURATION)
		-- Mirrors the server: dashing away from / toward the nearest fighter we're in combat with
		-- (D.DASH_INTENT; the server's CombatTag lists them in our character's CombatWith folder).
		local enemies = {}
		local foes = character:FindFirstChild("CombatWith")
		for _, value in if foes then foes:GetChildren() else {} do
			local model = (value :: ObjectValue).Value
			local hum = model and model:FindFirstChildOfClass("Humanoid")
			local hrp = model and model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hum and hum.Health > 0 and hrp then
				table.insert(enemies, hrp.Position)
			end
		end
		local intent = CombatMath.dashIntent(root.Position, dir, enemies)
		if intent == "Away" then
			-- Predict the server's flee chunk (FleeSystem.dashAway) until its "Flee" can arrive; RunController
			-- uses the higher of the two meanwhile, so a server that disagrees wins within FLEE_PREDICT.
			character:SetAttribute("FleePredict", math.min(1, attrNum("Flee", 0) + D.FLEE.dash))
			character:SetAttribute("FleePredictUntil", t + FLEE_PREDICT)
		end
		if useBonus then
			S.bonusSpent += 1
			Status.chamberSpent()
		else
			-- Mirrors the server: shorter at high Focus (CombatMath.dashCooldown).
			local focus = if character:GetAttribute("FocusOn") == true then attrNum("Focus", 0) else 0
			S.dashCooldownUntil = t + CombatMath.dashCooldown(focus) * CombatMath.dashIntentMult(intent) * heightStats.dashCooldown
			Status.dashUsed(S.dashCooldownUntil)
		end
		Feedback.dash(root, dir, distance)
		DashRemote:FireServer(dir, kind, t)
		return true
	end

	local function cameraLook(): Vector3
		local cam = workspace.CurrentCamera
		return if cam then CombatMath.flat(cam.CFrame.LookVector) else Vector3.zero
	end

	-- Rush windup done: charge toward the camera, steering toward it at the move's turn rate.
	local function startRush(t: number)
		local move = S.move
		local rush = move.rush
		if move.charge then
			-- Mirrors the server: the held part of the windup buys extra distance.
			S.rushBudget += move.charge.studs * math.clamp((t - S.chargeMinEnd) / move.charge.time, 0, 1)
		end
		local dir = cameraLook()
		if dir == Vector3.zero then
			dir = CombatMath.flat(root.CFrame.LookVector)
		end
		stopDash()
		if rush.aim == "Facing" then
			dir = CombatMath.flat(root.CFrame.LookVector) -- no turn: straight where the body faces
		end
		-- "Target" (Reentry): launches at, and steers toward (still capped by turnRate, so it can be
		-- dodged), the fighter our unlocking hit (Eject) landed on. Camera if they're gone.
		local steer = cameraLook
		local target = S.unlockTarget
		local targetRoot = if rush.aim == "Target" and target and target.Parent then target:FindFirstChild("HumanoidRootPart") :: BasePart? else nil
		if targetRoot then
			steer = function(): Vector3
				return CombatMath.flat(targetRoot.Position - root.Position)
			end
			local toward = steer()
			if toward.Magnitude > 1e-3 then
				dir = toward.Unit
			end
		end
		local speed = MoveSchema.rushSpeed(rush, S.rushBudget)
		local motor = RushMotor.start(root, dir, speed, rush.turnRate, steer, true)
		S.rushMotor = motor
		S.rushContact = false
		S.cancelDash = function()
			motor:stop()
		end
		setState(State.Rush, S.rushBudget / speed, t)
		fa:playRushLoop(move)
	end

	-- The server confirmed our rush connected: the rush ends, the momentum carries on (same
	-- carry as a miss) into endlag. A stun or parry still stops the motor dead (stopDash).
	local function endRush()
		if S.rushMotor and S.move then
			S.rushMotor:easeOut(S.move.rush.carry)
		end
		S.rushMotor = nil
		if S.move and S.move.rush.contactAnim then
			-- The contact swing (Reentry) plays out through the endlag; start it if our own contact
			-- check hadn't caught the touch yet. Not if the miss swing is already running and it's the
			-- same clip (bug, 2026-11-02: "reentry swing buggy": we missed locally, the server's lag-
			-- compensated hit landed during RushMiss, and the swing restarted from frame one).
			local r = S.move.rush
			local swinging = S.rushContact or (S.state == State.RushMiss and r.missAnim == r.contactAnim)
			if not swinging then
				fa:playRushContact(S.move)
			end
		else
			fa:stopAttacks()
		end
		setState(State.Endlag, if S.move then S.move.endlag else 0)
	end

	-- Barrage: the punch chain, and (advance > 0) a constant-speed step-in that follows the camera
	-- with no turn cap, the body turning with it. Stopped by stopDash (barrage end, stun, parry).
	local function startBarrage(move: any)
		fa:playBarrage(move)
		stopDash()
		local b = move.barrage
		if b.advance > 0 then
			local dir = cameraLook()
			if dir == Vector3.zero then
				dir = CombatMath.flat(root.CFrame.LookVector)
			end
			local motor = RushMotor.start(root, dir, b.advance / b.duration, math.huge, cameraLook, true)
			S.cancelDash = function()
				motor:stop()
			end
		end
	end

	-- Local contact check so the rush stops on the target instead of overshooting by a
	-- ping's worth of travel. Fighters mid-dash are skipped (i-frames: the rush goes through).
	local function rushTouching(): boolean
		local motor = S.rushMotor
		if not motor or not S.move then
			return false
		end
		local candidates = {}
		for _, m in CollectionService:GetTagged("MidoriFighter") do
			local hum = m:FindFirstChildOfClass("Humanoid")
			if m ~= character and m:IsA("Model") and hum and hum.Health > 0 and m:GetAttribute("MState") ~= State.Dash then
				table.insert(candidates, m)
			end
		end
		local cf = CFrame.lookAlong(root.Position, motor.dir)
		return #Hitbox.query(cf, S.move.hitbox, candidates) > 0
	end

	-- While attacking, stream our root to the server: it places our hitboxes at our real pose
	-- instead of its own lagging copy of us (see D.POSE_*). `force` skips the rate cap (hit moments).
	local PoseRemote = Net.get("AttackPose")
	local lastPoseSent = 0
	local ATTACKING = { [State.Startup] = true, [State.Rush] = true, [State.Barrage] = true }
	local function sendPose(force: boolean?)
		local c = os.clock()
		if force or c - lastPoseSent >= D.POSE_SEND_INTERVAL then
			lastPoseSent = c
			PoseRemote:FireServer(root.CFrame)
		end
	end

	-- Transitions use the state's scheduled end (`t`), never this frame's time, so the
	-- prediction keeps exact data timing and stays in step with the server.
	local function onExpire()
		local s = S.state
		local t = S.endsAt
		if s == State.Startup then
			sendPose(true) -- our hit moment: the pose the server should use for it
		end
		if s == State.Startup and S.move and S.move.rush then
			startRush(t)
		elseif s == State.Rush then
			-- Out of distance: keep the momentum for the carry, easing out, then endlag.
			local move = S.move
			local carry = if move then move.rush.carry else 0
			if S.rushMotor then
				S.rushMotor:easeOut(carry) -- no-op if a local contact already started the carry
			end
			setState(State.RushMiss, carry, t)
			-- Already swinging on a local contact, the server's verdict still in flight (ping longer than the
			-- rest of the rush): keep that swing, don't restart it with the miss clip (same bug as endRush).
			if move and not (S.rushContact and move.rush.contactAnim) then
				fa:playRushMiss(move)
			end
		elseif s == State.RushMiss then
			stopDash()
			S.rushMotor = nil
			setState(State.Endlag, if S.move and S.move.rush then S.move.rush.missEndlag else 0, t)
		elseif s == State.Startup and S.move and S.move.barrage then
			setState(State.Barrage, S.move.barrage.duration, t)
			startBarrage(S.move)
		elseif s == State.Startup or s == State.Barrage then
			if s == State.Barrage then
				stopDash() -- the step-in ends with the barrage
			end
			setState(State.Endlag, if S.move then S.move.endlag else 0, t)
		elseif s == State.Endlag and S.grabAt and S.move and S.move.grab and style.moves[S.move.grab.move] then
			if t < S.grabAt then
				S.endsAt = S.grabAt -- the grab landed while we were still in startup: hold until it's time
				return
			end
			-- Our grab's hold is over: the follow-up starts now (mirrors CombatService.grabTick).
			local follow = style.moves[S.move.grab.move]
			S.grabAt = nil
			S.move = follow
			setState(State.Startup, follow.startup, t)
			fa:playAttack(follow, 1)
			Feedback.swing(root, follow.id)
		elseif s == State.Endlag then
			if S.move and S.move.id == style.m1Chain[#style.m1Chain] then
				-- Combo finished: chain restarts and M1 is locked briefly (mirrors the server).
				S.chainIndex = 1
				S.m1LockUntil = t + style.comboEndDelay
			end
			-- Move cooldowns start when endlag ends (mirrors the server); a landed Eject cuts its own
			-- by its cooldownRefresh share.
			if S.move and S.move.cooldown > 0 then
				local refresh = if S.refreshedMove == S.move then S.move.cooldownRefresh else nil
				local cooldown = S.move.cooldown * (1 - (if refresh then refresh[S.move.kind] or 0 else 0))
				if S.move.kind == "M2" then
					S.m2CooldownUntil = t + cooldown
				elseif S.move.kind == "R" then
					S.rCooldownUntil = t + cooldown
				end
			end
			S.refreshedMove = nil
			S.move = nil
			S.chainResetAt = t + D.CHAIN_RESET
			setState(State.Idle, nil, t)
		elseif s == State.BlockStart or s == State.BlockRecovery then
			if S.parryUnguard then
				-- Landed parry drops guard with no cooldown. Only a new F press re-blocks.
				S.parryUnguard = false
				setState(State.Idle, nil, t)
			elseif S.stripPending or not S.blockKey then
				release(t)
			else
				setState(State.Blocking, nil, t)
			end
		elseif s == State.ParryStun and S.move then
			-- Parried: the stun, then half the parried move's endlag (mirrors the server).
			setState(State.Endlag, S.move.endlag / 2, t)
		elseif Enums.STUNS[s] then
			S.move = nil
			S.chainIndex = 1
			setState(State.Idle, nil, t)
			S.dashLockUntil = t + D.POST_STUN_DASH_DELAY
			if s == State.GuardBreakStun then
				S.noBlockUntil = t + D.GUARD_BREAK_NO_BLOCK
			end
		elseif s == State.Dash then
			-- Natural end: keep the leftover speed (stopDash would zero it if this ran a frame
			-- before the burst's own timer, a dead stop).
			if S.cancelDash then
				S.cancelDash(true)
				S.cancelDash = nil
			end
			setState(State.DashEndlag, D.DASH_ENDLAG, t)
		elseif s == State.DashEndlag then
			setState(State.Idle, nil, t)
		end
	end

	-- A swing charge move's release (let go, tap minimum or auto release): free to walk again, the
	-- swing clip + release sound, and the charge tier's step-in over the swing (mirrors chargedMove).
	local function releaseSwing(move: any, at: number)
		S.swung = true
		if run then
			run.setRooted(false)
		end
		local swing = move.charge.swing
		fa:playSwing(move)
		Feedback.release(root, move.id)
		local tier = CombatMath.chargeTier(move, at - S.stateStartedAt)
		S.releasedAt = at
		if move.blink then
			-- Blink (Dema M2): at the hit we teleport to the lane's end (short of walls). The server
			-- strikes from where we released, so the jump can't move its hitbox.
			local range = CombatMath.blinkRange(move, at - S.stateStartedAt, S.chargeMinEnd - S.stateStartedAt)
			task.delay(math.max(0, at + swing.hit - now()), function()
				if S.move == move and humanoid.Health > 0 and root.Parent then
					stopDash()
					local torso = character:FindFirstChild("Torso")
					local off = if torso and torso:IsA("BasePart") then root.CFrame:ToObjectSpace(torso.CFrame) else CFrame.new()
					local from = root.CFrame
					root.CFrame = CombatMath.blinkTarget(root, range, { character })
					root.AssemblyLinearVelocity = Vector3.zero
					WindTrail.streak(from * off, root.CFrame * off) -- the trail can't draw a 1-frame jump
					if move.blink.stand > 0 then
						-- Stand still after the jump (user: 0.3s); the Heartbeat lifts it at rootUntil.
						S.rootUntil = math.max(S.rootUntil or 0, now() + move.blink.stand)
						if run then
							run.setRooted(true)
						end
					end
				end
			end)
		end
		if tier.step > 0 then
			stopDash()
			S.cancelDash = DashMotor.apply(root, CombatMath.flat(root.CFrame.LookVector), tier.step, swing.hit, D.DASH_MAX_FORCE)
		end
	end

	table.insert(conns, RunService.Heartbeat:Connect(function(dt: number)
		local t = now()
		-- A move's useShift (Prodigy Reentry) lasts exactly as long as we're in that move: windup to the
		-- end of its endlag, or until a stun / dash / another move takes over. Its dof keeps the
		-- unlock target (who the Eject landed on) in focus.
		if S.shiftMove ~= S.move then
			if S.shiftRelease then
				S.shiftRelease()
				S.shiftRelease = nil
			end
			S.shiftMove = S.move
			local key = S.move and S.move.useShift
			if key then
				S.shiftRelease = ColorShift.hold(D.COLOR_SHIFT[key], S.unlockTarget)
			end
		end
		-- Mirrors the server: the dash cooldown regens slower in a slow zone.
		if S.dashCooldownUntil > t and CombatMath.inSlowZone(character, root.Position, t) then
			S.dashCooldownUntil += dt * (1 - D.SLOW_ZONE.dashRegenMult)
			Status.dashUsed(S.dashCooldownUntil, true)
		end
		-- A fuse we asked for: lit once its cooldown attribute moves past the moment we sent it (the
		-- server sets it on lighting); still unmoved at the deadline = never lit, so lift our lock.
		if S.fuseKind then
			local attr = character:GetAttribute(if S.fuseKind == "M2" then "M2CooldownUntil" else "RCooldownUntil")
			local serverUntil = if typeof(attr) == "number" then attr else 0
			if serverUntil > S.fuseSentAt then
				S.fuseKind = nil
			elseif t >= S.fusePendingUntil then
				if S.fuseKind == "M2" then
					S.m2CooldownUntil = serverUntil
				else
					S.rCooldownUntil = serverUntil
				end
				S.fuseKind = nil
			end
		end
		local m = S.move
		local swing = S.state == State.Startup and m and m.charge and m.charge.swing
		if swing and not S.swung and t >= S.endsAt - swing.hit then
			releaseSwing(m, S.endsAt - swing.hit)
		end
		-- M2 charge bar under the crosshair: only while a swing charge winds up
		if swing and not S.swung then
			Hud.setCharge(t - S.stateStartedAt, m.charge.tiers)
		else
			Hud.setCharge(nil)
		end
		if t >= S.endsAt then
			onExpire()
		end
		if S.rootUntil and t >= S.rootUntil then
			S.rootUntil = nil
			if run then
				run.setRooted(S.state == State.ParryStun or S.state == State.GuardBreakStun)
			end
		end
		if ATTACKING[S.state] then
			sendPose()
		end
		if S.state == State.Rush and not S.rushContact and rushTouching() then
			-- Start the carry on contact so it lines up with the target; HitResult (or the
			-- rush timer) decides what state follows.
			S.rushContact = true
			if S.rushMotor and S.move then
				S.rushMotor:easeOut(S.move.rush.carry)
				fa:playRushContact(S.move) -- reached them: swing (Reentry)
			end
		end
		local q = S.queued
		if q then
			if t - q.at > QUEUE_TTL[q.kind] then
				S.queued = nil
			else
				local ok = if q.kind == "attack" then tryAttack(q.arg, true) else tryDash(true)
				if ok then
					S.queued = nil
				end
			end
		end
		-- Held F wins over held M1: block the moment it is legal.
		if S.blockKey then
			if S.state == State.Idle then
				tryBlock()
			end
		elseif S.m1Held and S.queued == nil and canAct() then
			tryAttack("M1", true)
		end
	end))

	-- Every input method (mouse/keyboard, gamepad, touch buttons) ends up in press / unpress.
	local function press(action: string)
		if character:GetAttribute("Knocked") or character:GetAttribute("Carrying") then
			return -- down, or hands full carrying someone (KnockService; the server refuses these too)
		end
		if action == "M1" and soda and soda.holding() then
			soda.drink() -- holding a Bloxy Cola: M1 drinks instead of swinging (user, 2026-10-17)
			return
		end
		if skate and skate.press(action) then
			return -- on the board: M1 push, M2 ollie, Dash = charge lunge (movement only, user 2026-10-18)
		end
		if action == "M1" then
			S.m1Held = true
			tryAttack("M1")
		elseif action == "M2" or action == "R" then
			S.held[action] = true
			tryAttack(action)
		elseif action == "Block" then
			S.blockKey = true
			S.nextBlockTry = 0
			tryBlock()
		elseif action == "Dash" then
			tryDash()
		end
	end
	local function unpress(action: string)
		if skate then
			skate.unpress(action) -- lets go of a charging lunge; harmless otherwise
		end
		if action == "M1" then
			S.m1Held = false
		elseif action == "M2" or action == "R" then
			S.held[action] = false
			-- Letting go ends a charging windup now (never before its base startup); the server does the same.
			local t = now()
			local m = S.move
			if S.state == State.Startup and m and m.charge and m.kind == action then
				S.endsAt = math.min(S.endsAt, math.max(S.chargeMinEnd, t) + (if m.charge.swing then m.charge.swing.hit else 0))
			end
			Net.get("AttackRelease"):FireServer(action, t)
		elseif action == "Block" then
			S.blockKey = false
			BlockRemote:FireServer(false, now())
			if S.state == State.Blocking then
				release(now())
			end
		end
	end
	local function keyboardAction(input: InputObject): string?
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			return "M1"
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			return "M2"
		end
		return KEY_ACTIONS[input.KeyCode]
	end

	table.insert(conns, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local action = keyboardAction(input)
		if action and not processed then
			press(action)
		end
	end))

	table.insert(conns, UserInputService.InputEnded:Connect(function(input: InputObject)
		local action = keyboardAction(input)
		if action then
			unpress(action)
		end
	end))

	-- Gamepad buttons and on-screen touch buttons (touch buttons only appear on touch devices).
	-- ponytail: stock ContextActionService buttons; swap for custom-drawn ones if the look matters.
	for _, b in PAD_TOUCH do
		ContextActionService:BindAction(b.name, function(_, inputState: Enum.UserInputState)
			if inputState == Enum.UserInputState.Begin then
				press(b.action)
			elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
				unpress(b.action)
			end
			return Enum.ContextActionResult.Sink
		end, true, b.pad)
		ContextActionService:SetTitle(b.name, b.title)
		ContextActionService:SetPosition(b.name, b.pos)
	end

	-- Confirmed results about us move our predicted state to match the server.
	table.insert(conns, Net.get("HitResult").OnClientEvent:Connect(function(attacker: Model, victim: Model, result: string, _pos: Vector3, info: any)
		Reactions.apply(fa, character, attacker, victim, result, info)
		local stun = if type(info) == "table" and type(info.stun) == "number" then info.stun else 0
		-- Start the state when the server did (info.ends), not when this packet arrived: a late
		-- start made a block held through hitstun go out too late to parry the next hit.
		local from = if type(info) == "table" and type(info.ends) == "number" then info.ends - stun else nil
		local parriedUs = attacker == character and Reactions.attackerParried(result, info)
		if victim == character or parriedUs then
			interruptRun()
		end
		if attacker == character and S.state == State.Startup then
			S.startupLanded = true
		end
		local landed = result == Result.Hit or result == Result.Counter or result == Result.Clash
		if attacker == character and landed and S.move then
			-- Our cooldownRefresh move (Eject) landed: cut those shares of the M2 / R full cooldowns
			-- (mirrors HitResolver); its own cooldown is cut at endlag end.
			local refresh = S.move.cooldownRefresh
			if refresh then
				local t = now()
				local m2 = style.m2 and style.moves[style.m2]
				local r = style.r and style.moves[style.r]
				if m2 and refresh.M2 > 0 then
					S.m2CooldownUntil = math.max(t, S.m2CooldownUntil - m2.cooldown * refresh.M2)
				end
				if r and refresh.R > 0 then
					S.rCooldownUntil = math.max(t, S.rCooldownUntil - r.cooldown * refresh.R)
				end
				S.refreshedMove = S.move
			end
			if S.move.unlocks then
				S.unlockTarget = victim -- Reentry aims at them
			end
		end
		if attacker == character and type(info) == "table" and type(info.grab) == "number" then
			-- Our grab landed: wait in endlag until the server's grab time, then the follow-up (onExpire).
			S.grabAt = info.grab
			if S.state == State.Endlag then
				S.endsAt = info.grab
			end
		end
		if victim == character then
			if type(info) == "table" and info.held then
				-- Hit during our guard-break / perfect-blocked stun: the server kept that stun as is.
			elseif result == Result.Hit or result == Result.Counter or result == Result.Clash or result == Result.GuardBreak then
				-- Our countered M2/crit still goes on cooldown (mirrors HitResolver.applyHit).
				local m = S.move
				if (result == Result.Counter or result == Result.Clash) and m and m.cooldown > 0 then
					local t = now()
					if m.kind == "M2" then
						S.m2CooldownUntil = t + m.cooldown
					elseif m.kind == "R" then
						S.rCooldownUntil = t + m.cooldown
					end
				end
				S.queued = nil
				S.move = nil
				S.stripPending = false
				if result == Result.Counter then
					S.m1Held = false -- counter-punched: a held M1 doesn't swing again until re-pressed (user)
				end
				S.parryUnguard = false
				stopDash()
				-- Grabbed: held in place through the pull and the follow-up's windup (we can still parry).
				S.rootUntil = if type(info) == "table" and type(info.rootUntil) == "number" then info.rootUntil else nil
				-- info.gbs: hit at max adrenaline, guard-break-stunned instead of hitstun (HitResolver.applyHit)
				local gbs = result == Result.GuardBreak or (type(info) == "table" and info.gbs == true)
				setState(if gbs then State.GuardBreakStun else State.Hitstun, stun, from)
			elseif result == Result.Parried then
				setState(State.BlockRecovery, stun, from)
				S.parryUnguard = true
				-- A held F does not carry over: you must press F again for a fresh block.
				-- A press during the recovery is buffered and blocks as soon as it ends.
				S.blockKey = false
			elseif result == Result.Blocked then
				setState(State.BlockRecovery, stun, from)
				S.blockedHit = true
			elseif result == Result.Strip then
				setState(State.BlockRecovery, stun, from)
				S.stripPending = true
				S.blockedHit = false
			end
		elseif attacker == character and (S.state == State.Rush or S.state == State.RushMiss) and not parriedUs then
			-- Our rush connected (hit, counter, block, strip, guard break): it stops here.
			-- A clash also stuns us, which the victim branch above already handled.
			endRush()
		elseif parriedUs then
			stopDash() -- a parried rush stops dead
			S.rushMotor = nil
			S.queued = nil
			-- S.move stays: its endlag follows the parry stun (see onExpire)
			local attackerStun = if type(info) == "table" and type(info.attackerStun) == "number" then info.attackerStun else D.PARRY_STUN
			local attackerEnds = if type(info) == "table" and type(info.attackerEnds) == "number" then info.attackerEnds else nil
			setState(State.ParryStun, attackerStun, if attackerEnds then attackerEnds - attackerStun else nil)
		end
	end))

	-- The server confirmed one of our attacks: stop waiting, resync the chain from the
	-- server's pick, and swap the animation if we predicted the wrong hit.
	table.insert(conns, Net.get("AttackStarted").OnClientEvent:Connect(function(model: Model, moveId: string, speed: number)
		if model ~= character then
			return
		end
		local move = style.moves[moveId]
		if move and move.fuse then
			return -- a lit fuse isn't an attack we wait on; nothing changes until it goes off (StateSync)
		end
		S.awaitingAck = false
		if not move then
			return
		end
		local index = table.find(style.m1Chain, moveId)
		if index then
			S.chainIndex = index % #style.m1Chain + 1
		elseif move.kind == "M2" then
			S.chainIndex = 1
		end
		if S.state == State.Startup and S.move and S.move.id ~= moveId then
			S.move = chainMove(move)
			if move.rush then
				S.rushBudget = move.rush.freeStuds -- we guessed Eject, the server threw Reentry
			end
			fa:playAttack(move, speed)
		end
	end))

	-- We own our character's physics, so the server's knockback runs here. It is kept apart
	-- from S.cancelDash so the Hitstun HitResult and StateSync don't cut it short.
	local cancelKnockback: (() -> ())? = nil
	local function stopKnockback()
		if cancelKnockback then
			cancelKnockback()
			cancelKnockback = nil
		end
	end
	table.insert(conns, Net.get("Knockback").OnClientEvent:Connect(function(dir: Vector3, distance: number, duration: number, target: Vector3?, up: number?, arc: number?)
		stopKnockback()
		if distance <= 0 or duration <= 0 then
			return
		end
		if typeof(target) == "Vector3" then
			-- A pull (grab): aim at the spot from where we really are, not the server's stale copy.
			local delta = (target - root.Position) * Vector3.new(1, 0, 1)
			if delta.Magnitude < 0.05 then
				return
			end
			dir, distance = delta.Unit, delta.Magnitude
		end
		stopDash()
		if character:GetAttribute("Ragdolled") ~= nil then
			-- Limp: a launch, never a motor (D.RAGDOLL: one ragdoll physics model everywhere).
			local Ragdoll = Paths.shared("Ragdoll")
			Ragdoll.push(character, Ragdoll.launchVelocity(dir, distance, duration, if typeof(up) == "number" then up else nil))
			return
		end
		local cancel = DashMotor.apply(root, dir, distance, duration, D.KNOCKBACK_MAX_FORCE, nil, nil, nil, nil, if typeof(arc) == "number" then arc else nil)
		cancelKnockback = cancel
		if typeof(up) == "number" and up > 0 then
			root.AssemblyLinearVelocity += Vector3.yAxis * up -- launch; the motor only drives the flat plane
		end
	end))


	-- The server can cut the R cooldown short (traits, e.g. Technical); never lengthen our prediction.
	table.insert(conns, character:GetAttributeChangedSignal("RCooldownUntil"):Connect(function()
		local v = character:GetAttribute("RCooldownUntil")
		if typeof(v) == "number" and v < S.rCooldownUntil then
			S.rCooldownUntil = v
		end
	end))

	-- The server rejected or dropped one of our actions: adopt its state.
	table.insert(conns, Net.get("StateSync").OnClientEvent:Connect(function(state: string, endsAt: number, reason: string?)
		S.queued = nil
		S.awaitingAck = false
		S.bonusSpent = 0 -- a rejected bonus dash was never spent; trust the server's count
		if reason == "grabFollow" then
			-- The server started our grab's follow-up: adopt it if we didn't predict it.
			local crit = style.r and style.moves[style.r]
			local follow = crit and crit.grab and style.moves[crit.grab.move]
			if follow and not (S.move and S.move.id == follow.id) then
				S.move = follow
				S.grabAt = nil
				fa:playAttack(follow, 1)
				Feedback.swing(root, follow.id)
			end
		end
		if run and state ~= State.Endlag then
			-- The server moved us out of the whiff endlag; parried / guard-break stuns stay rooted.
			run.setRooted(state == State.ParryStun or state == State.GuardBreakStun or state == State.Gripping or state == State.Cutscene
				or (state == State.Startup and S.move ~= nil and S.move.rooted))
		end
		if S.state == State.Endlag and state ~= State.Endlag then
			S.endlagEndedAt = now()
		end
		S.state = state
		S.stateStartedAt = now()
		S.endsAt = if endsAt < 0 then math.huge else endsAt
		character:SetAttribute("LocalMState", state)
		local inMove = state == State.Startup or state == State.Endlag or state == State.Rush or state == State.RushMiss or state == State.Barrage
		if not inMove then
			fa:stopAttacks()
			S.move = nil
		end
		-- Our lit fuse went off (only the server knows when): the barrage cuts off whatever we were doing.
		local fuseMove = style.r and style.moves[style.r]
		local fuseWentOff = state == State.Barrage and fuseMove and fuseMove.fuse and S.move ~= fuseMove
		if fuseWentOff then
			S.move = fuseMove
			startBarrage(fuseMove)
		end
		if not Enums.GUARDING[state] then
			S.stripPending = false
			S.parryUnguard = false
			-- In a stun the HitResult reaction (Hitstun / Parryed) owns the slot and already
			-- dropped the block; setBlock(false) would cut that reaction short.
			if not Enums.STUNS[state] then
				fa:setBlock(false)
			end
		end
		if state ~= State.Dash and state ~= State.Rush and state ~= State.RushMiss and state ~= State.Barrage then
			stopDash()
			S.rushMotor = nil
		end
		local function attr(name: string): number
			local v = character:GetAttribute(name)
			return if typeof(v) == "number" then v else 0
		end
		S.blockCooldownUntil = attr("BlockCooldownUntil")
		S.actLockUntil = attr("ActLockUntil")
		S.noBlockUntil = attr("NoBlockUntil")
		S.dashCooldownUntil = attr("DashCooldownUntil")
		S.dashLockUntil = attr("DashLockUntil")
		S.m1LockUntil = attr("M1LockUntil")
		S.m2CooldownUntil = attr("M2CooldownUntil")
		S.rCooldownUntil = attr("RCooldownUntil")
	end))
	-- A dash cooldown the server cut short (Afterburner refund on a dodge): take it right away. Only
	-- ever lowers it; our own prediction of a fresh dash is never undone by the late echo. The one raise
	-- taken: the server judged our dash "Away" (D.DASH_INTENT) and we didn't. The echo is only late by
	-- ping, so anything past half that penalty is the penalty.
	local awayGap = D.DASH_COOLDOWN * (D.DASH_INTENT.awayCooldownMult - 1) / 2
	table.insert(conns, character:GetAttributeChangedSignal("DashCooldownUntil"):Connect(function()
		local v = character:GetAttribute("DashCooldownUntil")
		if typeof(v) == "number" and (v < S.dashCooldownUntil or v > S.dashCooldownUntil + awayGap) then
			S.dashCooldownUntil = v
			Status.dashUsed(v)
		end
	end))

	local stopped = false
	local function stop()
		if stopped then
			return
		end
		stopped = true
		for _, c in conns do
			c:Disconnect()
		end
		for _, b in PAD_TOUCH do
			ContextActionService:UnbindAction(b.name)
		end
		stopDash()
		stopKnockback()
		if S.shiftRelease then
			S.shiftRelease() -- died / respawned mid-Reentry: don't leave the screen blue
			S.shiftRelease = nil
		end
		fa:destroy()
	end
	humanoid.Died:Connect(stop)
	return stop
end

return CombatController
