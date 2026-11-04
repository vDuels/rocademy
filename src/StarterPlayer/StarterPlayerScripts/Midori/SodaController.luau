--!strict
-- Bloxy Cola, client side (user, 2026-10-17; server: SodaService). Plays the Soda animations
-- (Assets.Animations.Soda: Pickup, Open, Drink, Drop, Idle) and sends their markers to the server.
-- The first M1 on a fresh can plays Open (the server opens it); later M1s drink while "Sips" > 0:
--   Drink: "Sip" marker = the heal lands (server falls back after D.SODA.sipTimeout without it)
--   Drop:  "Release" marker = the can leaves the hand (falls back to the clip's end, or right away
--          with no clip)
-- Idle loops while you carry a can (set it Looped in the editor: Looped set from code doesn't replicate).
-- While holding: M1 drinks (CombatController routes every M1 input here: click, R2, the touch M1
-- button), Backspace / D-pad down / the touch DROP button drops. Taking HP damage drops it (server).
local ContextActionService = game:GetService("ContextActionService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")

local DROP_ACTION = "MidoriSodaDrop"

export type Soda = {
	holding: () -> boolean,
	drink: () -> (),
	destroy: () -> (),
}

local SodaController = {}

function SodaController.start(character: Model): Soda
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local animator = humanoid:WaitForChild("Animator") :: Animator
	local arm = character:WaitForChild("Right Arm") :: BasePart
	local remote = Net.get(Net.Names.Soda)
	local folder = Paths.Assets:WaitForChild("Animations"):WaitForChild("Soda")
	local conns: { RBXScriptConnection } = {}

	-- Empty AnimationId = no clip yet; everything still works, just without the motion.
	local function load(name: string): AnimationTrack?
		local a = folder:FindFirstChild(name)
		if a and a:IsA("Animation") and a.AnimationId ~= "" then
			return animator:LoadAnimation(a)
		end
		return nil
	end
	local tracks = { Pickup = load("Pickup"), Open = load("Open"), Drink = load("Drink"), Drop = load("Drop"), Idle = load("Idle") }
	if tracks.Idle then
		tracks.Idle.Priority = Enum.AnimationPriority.Idle -- under the combat clips (Action)
		tracks.Idle.Looped = true
	end

	local holding, busy = false, false

	local function can(): BasePart?
		local motor = arm:FindFirstChild("Soda")
		return if motor and motor:IsA("Motor6D") then motor.Part1 :: BasePart? else nil
	end

	local function open()
		busy = true
		remote:FireServer("Open")
		local track = tracks.Open
		if track then
			track.Stopped:Once(function()
				busy = false
			end)
			track:Play()
		else
			busy = false
		end
	end

	local function drink()
		local c = can()
		if not holding or busy or not c then
			return
		end
		if not c:GetAttribute("Opened") then
			open()
			return
		end
		local sips = c:GetAttribute("Sips")
		if typeof(sips) == "number" and sips <= 0 then
			return -- empty
		end
		busy = true
		remote:FireServer("Drink")
		local track = tracks.Drink
		if track then
			local sipConn = track:GetMarkerReachedSignal("Sip"):Connect(function()
				remote:FireServer("Sip")
			end)
			track.Stopped:Once(function()
				sipConn:Disconnect()
				busy = false
			end)
			track:Play()
		else
			task.delay(D.SODA.sipTimeout, function()
				busy = false
			end)
		end
	end

	local function drop()
		if not holding or busy then
			return
		end
		busy = true
		local track = tracks.Drop
		if not track then
			remote:FireServer("Drop")
			busy = false
			return
		end
		local sent = false
		local function release()
			if not sent then
				sent = true
				remote:FireServer("Drop")
			end
		end
		local relConn = track:GetMarkerReachedSignal("Release"):Connect(release)
		track.Stopped:Once(function()
			relConn:Disconnect()
			release() -- no "Release" marker: let go at the end of the clip
			busy = false
		end)
		track:Play()
	end

	local function bind(on: boolean)
		if on then
			ContextActionService:BindAction(DROP_ACTION, function(_, state)
				if state == Enum.UserInputState.Begin then
					drop()
				end
				return Enum.ContextActionResult.Sink
			end, true, Enum.KeyCode.Backspace, Enum.KeyCode.DPadDown)
			ContextActionService:SetTitle(DROP_ACTION, "DROP")
			ContextActionService:SetPosition(DROP_ACTION, UDim2.new(-0.25, 0, 0.05, 0))
		else
			ContextActionService:UnbindAction(DROP_ACTION)
		end
	end

	local function setHolding(on: boolean)
		if holding == on then
			return
		end
		holding = on
		busy = false
		bind(on)
		if tracks.Idle then
			if on then
				tracks.Idle:Play()
			else
				tracks.Idle:Stop()
			end
		end
	end

	table.insert(conns, arm.ChildAdded:Connect(function(child)
		if child.Name == "Soda" then
			setHolding(true)
		end
	end))
	table.insert(conns, arm.ChildRemoved:Connect(function(child)
		if child.Name == "Soda" then
			setHolding(false)
		end
	end))
	table.insert(conns, remote.OnClientEvent:Connect(function(action)
		if action == "Pickup" and tracks.Pickup then
			tracks.Pickup:Play()
		end
	end))
	setHolding(arm:FindFirstChild("Soda") ~= nil)

	return {
		holding = function()
			return holding
		end,
		drink = drink,
		destroy = function()
			for _, c in conns do
				c:Disconnect()
			end
			holding = true
			setHolding(false)
		end,
	}
end

return SodaController
