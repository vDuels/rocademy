--!strict
-- Running. Hold Left Shift while moving forward to run. You run whenever Shift is held,
-- you are moving forward, and the combat gate allows it (idle or dashing). So the run pauses
-- for attacks, blocks, stuns and dash endlag, and picks back up by itself if Shift is still held.
-- The character's "Running" attribute tells the Animate script to play the run animation.
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local CombatMath = Paths.shared("CombatMath")
local Height = Paths.shared("Height")

local ContextActionService = game:GetService("ContextActionService")

local KEY_RUN = Enum.KeyCode.LeftShift
local FOCUS_WALK = { min = 0.85, max = 1.2, full = 50 } -- user, 2026-10-24: 15% slower at 0 Focus, 20% faster at 50+ (was 35%)
local RUN_ACTION = "MidoriRun"
local State = Paths.shared("Enums").State
local SLOWED = {
	[State.Startup] = true,
	[State.Endlag] = true,
	[State.Barrage] = true,
	[State.BlockStart] = true,
	[State.Blocking] = true,
	[State.BlockRecovery] = true,
}

export type Run = {
	stop: () -> (), -- drop out of the run right now (it resumes once allowed and Shift is held)
	setGate: (gate: () -> boolean) -> (), -- extra condition for running, e.g. "not in combat"
	setRooted: (on: boolean) -> (), -- no walking at all while on (e.g. a whiffed rush's endlag)
	isRunning: () -> boolean,
	toggle: () -> (), -- flip run on/off (touch / gamepad toggle-run)
	isHeld: () -> boolean, -- run wanted (Shift held or toggled on), even while the gate pauses it
	destroy: () -> (),
}

local RunController = {}

function RunController.start(character: Model): Run
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local walkSpeed = humanoid.WalkSpeed
	local running = false
	local held = false
	local rooted = false -- RunController owns WalkSpeed, so the root lock lives here too
	local parriedEndlag = false -- in the half endlag that follows a ParryStun
	local swingSlowUntil = 0 -- os.clock(); the attack slow carries on until then
	local gate: () -> boolean = function()
		return true
	end
	local conns: { RBXScriptConnection } = {}

	-- Focus (Prodigy) paces movement (user, 2026-10-24): FOCUS_WALK.min x at 0 Focus up to FOCUS_WALK.max x
	-- at FOCUS_WALK.full Focus, linear, held past it. No Focus meter = 1.
	local function focusMult(): number
		local focus = character:GetAttribute("Focus")
		-- Only with the style out (combat mode, T; user, 2026-11-01): holstered Prodigy walks / runs normally.
		if character:GetAttribute("FocusOn") ~= true or typeof(focus) ~= "number" or character:GetAttribute("CombatMode") ~= true then
			return 1
		end
		local F = FOCUS_WALK
		return F.min + (F.max - F.min) * math.clamp(focus / F.full, 0, 1)
	end

	-- Perks scale the run speed through the character's "RunSpeedMult" attribute (server-set). Focus
	-- only speeds the run up, never slows it (user).
	-- Inside a slow zone (Slugger Critical): walking and running both slowed (D.SLOW_ZONE).
	local function zoneMult(): number
		return if CombatMath.inSlowZone(character, root.Position, workspace:GetServerTimeNow()) then D.SLOW_ZONE.walkMult else 1
	end

	-- The flee meter (server FleeSystem's "Flee", 0-1), or CombatController's predicted dash-away chunk
	-- ("FleePredict") while it's waiting on the server, whichever is higher.
	local function flee(): number
		local v = character:GetAttribute("Flee")
		local value = if typeof(v) == "number" then v else 0
		local p, pUntil = character:GetAttribute("FleePredict"), character:GetAttribute("FleePredictUntil")
		if typeof(p) == "number" and typeof(pUntil) == "number" and workspace:GetServerTimeNow() < pUntil then
			value = math.max(value, p)
		end
		return value
	end
	-- A full meter: no running until it drains to D.FLEE.unlockAt (server-set "FleeLocked").
	local function fleeLocked(): boolean
		return character:GetAttribute("FleeLocked") == true or flee() >= D.FLEE.lockAt
	end

	-- Fleeing (D.FLEE), any adrenaline (D.ADRENALINE_MOVE_MULT): walking and running both slowed.
	-- Also: hit by a hitSlow fighter (Microgravity, Prodigy): "HitSlowMult" until "HitSlowUntil" (server-set).
	local function slowMult(): number
		local t = workspace:GetServerTimeNow()
		local adr = character:GetAttribute("Adrenaline")
		local mult = CombatMath.fleeMult(flee()) * (if typeof(adr) == "number" and adr > 0 then D.ADRENALINE_MOVE_MULT else 1)
		local hitUntil, hitMult = character:GetAttribute("HitSlowUntil"), character:GetAttribute("HitSlowMult")
		if typeof(hitUntil) == "number" and typeof(hitMult) == "number" and t < hitUntil then
			mult *= hitMult
		end
		return mult
	end

	local function runSpeed(): number
		local mult = character:GetAttribute("RunSpeedMult")
		return D.RUN_SPEED * (if typeof(mult) == "number" then mult else 1) * math.max(1, focusMult()) * zoneMult() * slowMult() * Height.ofModel(character).moveSpeed
	end

	-- Short characters (D.HEIGHT) walk and run faster.
	local function baseWalk(): number
		return walkSpeed * focusMult() * zoneMult() * slowMult() * Height.ofModel(character).moveSpeed
	end

	local function setRunning(on: boolean)
		if running == on then
			if on then
				humanoid.WalkSpeed = runSpeed() -- picks up a perk change mid-run
			end
			return
		end
		running = on
		humanoid.WalkSpeed = if on then runSpeed() else baseWalk()
		character:SetAttribute("Running", on)
	end

	-- Moving, and not mostly backward relative to where the character faces.
	local function movingForward(): boolean
		local move = CombatMath.flat(humanoid.MoveDirection)
		if move == Vector3.zero then
			return false
		end
		return move:Dot(CombatMath.flat(root.CFrame.LookVector)) > D.RUN_BACKWARD_DOT
	end

	local function update()
		if rooted then
			setRunning(false)
			humanoid.WalkSpeed = 0
			return
		end
		-- Drunk on Bloxy Cola (tier 2+): no running (BloxyService; user, 2026-10-27).
		local drunk = character:GetAttribute("Drunk")
		local tooDrunk = typeof(drunk) == "number" and drunk >= 2
		setRunning(held and not tooDrunk and not fleeLocked() and humanoid.Health > 0 and movingForward() and gate() and os.clock() >= swingSlowUntil)
		if not running then
			-- Attacking or blocking walks slower (CombatController's predicted state); the endlag
			-- after getting parried slower still.
			local state = character:GetAttribute("LocalMState") :: any
			local mult = if state == State.Hitstun then D.HITSTUN_WALK_MULT
				elseif parriedEndlag then D.PARRIED_WALK_MULT
				elseif SLOWED[state] or os.clock() < swingSlowUntil then D.ACTION_WALK_MULT
				else 1
			humanoid.WalkSpeed = baseWalk() * mult
		end
	end
	local lastState: any = nil
	table.insert(conns, character:GetAttributeChangedSignal("LocalMState"):Connect(function()
		local state = character:GetAttribute("LocalMState")
		parriedEndlag = state == State.Endlag and (lastState == State.ParryStun or parriedEndlag)
		-- The swing slow lingers past the attack, so it doesn't flicker off between M1s.
		if (lastState == State.Startup or lastState == State.Endlag) and state ~= State.Startup and state ~= State.Endlag then
			swingSlowUntil = os.clock() + D.SWING_SLOW_LINGER
		end
		lastState = state
	end))

	-- Settings "TOGGLE RUN" (Player attribute SetToggleRun, SettingsService): Shift flips running on/off
	-- instead of holding it.
	local localPlayer = game:GetService("Players").LocalPlayer
	local function toggleRun(): boolean
		return localPlayer:GetAttribute("SetToggleRun") == true
	end
	table.insert(conns, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == KEY_RUN then
			held = if toggleRun() then not held else true
			update()
		end
	end))
	table.insert(conns, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.KeyCode == KEY_RUN and not toggleRun() then
			held = false
			update()
		end
	end))
	-- Switching the setting off while toggled on: stop, so you're not stuck running.
	table.insert(conns, localPlayer:GetAttributeChangedSignal("SetToggleRun"):Connect(function()
		if not toggleRun() then
			held = false
			update()
		end
	end))
	table.insert(conns, RunService.Heartbeat:Connect(update))
	-- Gamepad (stick click) and touch (MobileButtons' RUN): a TOGGLE, since a thumb can't hold run
	-- while steering and attacking. Keyboard Shift stays hold-to-run.
	local function toggle()
		held = not held
		update()
	end
	ContextActionService:BindAction(RUN_ACTION, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin then
			toggle()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.ButtonL3)

	local destroyed = false
	local run: Run = {
		stop = function()
			setRunning(false)
		end,
		setGate = function(newGate: () -> boolean)
			gate = newGate
		end,
		setRooted = function(on: boolean)
			if rooted == on then
				return
			end
			rooted = on
			if not on then
				humanoid.WalkSpeed = baseWalk() -- update() brings the run back if Shift is still held
			end
			update()
		end,
		isRunning = function()
			return running
		end,
		toggle = toggle,
		isHeld = function()
			return held
		end,
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			for _, c in conns do
				c:Disconnect()
			end
			ContextActionService:UnbindAction(RUN_ACTION)
			setRunning(false)
		end,
	}
	table.insert(conns, humanoid.Died:Connect(run.destroy))
	character:SetAttribute("Running", false)
	return run
end

return RunController
