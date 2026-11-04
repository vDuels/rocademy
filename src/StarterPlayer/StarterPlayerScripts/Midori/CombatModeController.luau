--!strict
-- Combat mode. Press T to enter or leave it. M1, M2, R and block only work in combat mode
-- (the server enforces it too); walking, running and dashing work either way, but you
-- cannot jump in combat mode. Every life starts out of combat mode.
-- While in combat mode and standing still on the ground, the style's idle animation
-- (style.idle) plays at Idle priority: above the Animate script's idle, below everything
-- combat plays. An empty AnimationId keeps the normal idle.
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Net = Paths.shared("Net")
local MoveSchema = Paths.shared("MoveSchema")

local ContextActionService = game:GetService("ContextActionService")

local KEY_TOGGLE = Enum.KeyCode.T
local ACTION = "MidoriCombatMode"
local IDLE_FADE = 0.2
local IDLE_SPEED_MIN, IDLE_SPEED_MAX = 0.7, 1.1 -- idle speed at 0 Focus .. at IDLE_FOCUS_FULL (user, 2026-10-24)
local IDLE_FOCUS_FULL = 80

export type Mode = {
	isOn: () -> boolean,
	destroy: () -> (),
}

local CombatModeController = {}

local function findAnim(path: string): Animation?
	local node: Instance? = Paths.Assets:WaitForChild("Animations")
	for part in string.gmatch(path, "[^/]+") do
		node = node and node:FindFirstChild(part)
	end
	return if node and node:IsA("Animation") then node else nil
end

function CombatModeController.start(character: Model): Mode
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:WaitForChild("Animator") :: Animator
	local remote = Net.get("CombatMode")

	local on = false
	local conns: { RBXScriptConnection } = {}

	-- Reloaded when the server changes our style (",e <Style>").
	local idleTrack: AnimationTrack? = nil
	local idleAlways = false -- style.idleWhileMoving: a hold pose (e.g. BanHammer) layered over walk/run
	local holstered = false -- style.holster: out of combat mode the weapon is put away, so no idle (Dema)
	-- style.equip: played once on entering combat mode (Furious Feng). Movement priority: over the idle and
	-- walk, under every combat clip, so attacking out of it just takes over.
	local equipTrack: AnimationTrack? = nil
	local equipGen = 0 -- a newer play / stop / reload makes an older one's timed Stop do nothing
	local function loadIdle()
		if idleTrack then
			idleTrack:Stop(0)
			idleTrack:Destroy()
			idleTrack = nil
		end
		equipGen += 1
		if equipTrack then
			equipTrack:Stop(0)
			equipTrack:Destroy()
			equipTrack = nil
		end
		local style = MoveSchema.ofModel(character)
		local equipAnim = if style.equip then findAnim(style.equip) else nil
		if equipAnim and equipAnim.AnimationId ~= "" then
			local track = animator:LoadAnimation(equipAnim) -- loaded up front, played from the cache
			track.Priority = Enum.AnimationPriority.Movement
			track.Looped = false
			equipTrack = track
		end
		idleAlways = style.idleWhileMoving
		holstered = style.holster ~= nil
		local idleAnim = if style.idle then findAnim(style.idle) else nil
		if idleAnim and idleAnim.AnimationId ~= "" then
			local track = animator:LoadAnimation(idleAnim)
			track.Priority = Enum.AnimationPriority.Idle
			track.Looped = true
			idleTrack = track
		end
	end
	loadIdle()
	table.insert(conns, character:GetAttributeChangedSignal("Style"):Connect(loadIdle))

	-- Focus (Prodigy) paces the idle (user, 2026-10-24): IDLE_SPEED_MIN at 0 Focus up to IDLE_SPEED_MAX
	-- at IDLE_FOCUS_FULL, linear, held past it. No Focus meter = normal speed.
	local function idleSpeed(): number
		local focus = character:GetAttribute("Focus")
		if character:GetAttribute("FocusOn") ~= true or typeof(focus) ~= "number" then
			return 1
		end
		local u = math.clamp(focus / IDLE_FOCUS_FULL, 0, 1)
		return IDLE_SPEED_MIN + (IDLE_SPEED_MAX - IDLE_SPEED_MIN) * u
	end

	local function stopEquip(fade: number)
		equipGen += 1
		if equipTrack and equipTrack.IsPlaying then
			equipTrack:Stop(fade)
		end
	end
	-- One pass, ended by an explicit Stop: Looped = false doesn't replicate, so without it the server's copy
	-- could hang on the last frame (AnimationHandler's rule).
	local function playEquip()
		local track = equipTrack
		if not track then
			return
		end
		stopEquip(0)
		local gen = equipGen
		track:Play(0.1)
		task.spawn(function()
			local started = os.clock()
			while track.Length <= 0 and os.clock() - started < 1 do
				task.wait()
			end
			local length = if track.Length > 0 then track.Length else 1
			task.wait(math.max(length - (os.clock() - started), 0))
			if equipGen == gen then
				track:Stop(0.15)
			end
		end)
	end

	local function setOn(value: boolean)
		if value and character:GetAttribute("InApartment") then
			return -- apartments are no-combat (ApartmentService; the server refuses attacks there too)
		end
		on = value
		-- No jumping in combat mode. The client simulates its own character, so disabling
		-- the state here is what actually stops the jump.
		humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, not value)
		remote:FireServer(value)
		if value then
			playEquip()
		else
			stopEquip(0.15)
		end
	end
	-- Going into an apartment drops combat mode.
	table.insert(conns, character:GetAttributeChangedSignal("InApartment"):Connect(function()
		if on and character:GetAttribute("InApartment") then
			setOn(false)
		end
	end))

	table.insert(conns, UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not processed and input.KeyCode == KEY_TOGGLE and humanoid.Health > 0 then
			setOn(not on)
		end
	end))
	-- Gamepad X / on-screen touch button (touch devices only). ponytail: position picked blind.
	ContextActionService:BindAction(ACTION, function(_, inputState: Enum.UserInputState)
		if inputState == Enum.UserInputState.Begin and humanoid.Health > 0 then
			setOn(not on)
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.ButtonX)
	ContextActionService:SetTitle(ACTION, "FIGHT")
	ContextActionService:SetPosition(ACTION, UDim2.new(0.75, 0, 0.75, 0))

	table.insert(conns, RunService.Heartbeat:Connect(function()
		local track = idleTrack
		if not track then
			return
		end
		-- Never over the sit pose (user, 2026-10-29: no fighting styles while sitting).
		local standing = humanoid.MoveDirection.Magnitude < 0.05
			and humanoid.FloorMaterial ~= Enum.Material.Air
			and humanoid.Health > 0
			and not humanoid.Sit
		local want = if holstered and not on then false
			elseif idleAlways then humanoid.Health > 0 and not humanoid.Sit
			else on and standing
		if want and not track.IsPlaying then
			track:Play(IDLE_FADE)
		elseif not want and track.IsPlaying then
			track:Stop(IDLE_FADE)
		end
		if track.IsPlaying then
			local speed = idleSpeed()
			if math.abs(track.Speed - speed) > 0.005 then
				track:AdjustSpeed(speed)
			end
		end
	end))

	local destroyed = false
	local mode: Mode = {
		isOn = function()
			return on
		end,
		destroy = function()
			if destroyed then
				return
			end
			destroyed = true
			for _, c in conns do
				c:Disconnect()
			end
			ContextActionService:UnbindAction(ACTION)
			if idleTrack then
				idleTrack:Stop(0)
			end
			equipGen += 1
			if equipTrack then
				equipTrack:Stop(0)
				equipTrack:Destroy()
				equipTrack = nil
			end
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end,
	}
	table.insert(conns, humanoid.Died:Connect(mode.destroy))
	return mode
end

return CombatModeController
