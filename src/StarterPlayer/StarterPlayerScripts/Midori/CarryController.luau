--!strict
-- Client side of knocked + carrying (server: KnockService; user, 2026-10-18), per character.
--   Knocked (us): a "KNOCKED" countdown ("HELD" while carried: the timer is paused).
--   Carrying: E (or gamepad X) drops them (the "Carry" remote);
--   we play Assets.Animations.Knocked.Pickup once, then HoldIdle looped (slots: they need ids).
--   Gripping: plays Knocked.Grip (stopped early if the grip gets cancelled; the kill's sound is the server's).
-- Picking up / gripping is InteractController's hover + E / V; the ragdoll is Shared/Ragdoll's.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Net = Paths.shared("Net")
local D = Paths.data("Defaults")

local DROP_ACTION = "MidoriCarryDrop"
local FONT = Font.fromEnum(Enum.Font.LuckiestGuy)
local RED = Color3.fromRGB(225, 18, 40)

local player = Players.LocalPlayer

local CarryController = {}

local function anim(name: string): Animation?
	local folder = Paths.Assets:FindFirstChild("Animations")
	local knocked = folder and folder:FindFirstChild("Knocked")
	local a = knocked and knocked:FindFirstChild(name)
	return if a and a:IsA("Animation") and a.AnimationId ~= "" then a else nil
end

function CarryController.start(character: Model): { destroy: () -> () }
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	local root = character:WaitForChild("HumanoidRootPart") :: BasePart
	local animator = humanoid:WaitForChild("Animator") :: Animator
	local conns: { RBXScriptConnection } = {}
	local tracks: { AnimationTrack } = {}

	-- "KNOCKED" + seconds left (MStateEnds is the server clock).
	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriKnocked"
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui.DisplayOrder = 6
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.7)
	label.Size = UDim2.fromOffset(420, 70)
	label.BackgroundTransparency = 1
	label.FontFace = FONT
	label.TextSize = 54
	label.TextColor3 = RED
	label.Rotation = -4
	label.Text = "KNOCKED"
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 4
	stroke.Parent = label
	local pop = Instance.new("UIScale")
	pop.Parent = label
	gui.Parent = player:WaitForChild("PlayerGui")
	local function refreshKnocked()
		local on = character:GetAttribute("Knocked") == true
		if on and not gui.Enabled then
			pop.Scale = 1.4
			TweenService:Create(pop, TweenInfo.new(0.35, Enum.EasingStyle.Back), { Scale = 1 }):Play()
		end
		gui.Enabled = on
	end
	table.insert(conns, character:GetAttributeChangedSignal("Knocked"):Connect(refreshKnocked))
	refreshKnocked()
	table.insert(conns, RunService.RenderStepped:Connect(function()
		if gui.Enabled then
			local held = character:GetAttribute("KnockedLeft") -- being carried: the timer is paused
			local ends = character:GetAttribute("MStateEnds")
			local left = if typeof(held) == "number" then held
				elseif typeof(ends) == "number" and ends > 0 then math.max(0, ends - workspace:GetServerTimeNow())
				else 0
			label.Text = if typeof(held) == "number" then `HELD  {math.ceil(left)}` else `KNOCKED  {math.ceil(left)}`
		end
	end))

	-- Carrying: drop key, pickup -> hold animations.
	-- Stop AND destroy: a track that's only stopped still counts toward the Animator's 256-track cap
	-- (a fresh one is loaded every carry), and past it animations stop playing (user, 2026-10-28: stuck anims).
	local function stopTracks()
		for _, t in tracks do
			t:Stop(0.2)
			task.delay(0.3, t.Destroy, t)
		end
		table.clear(tracks)
	end
	local function refreshCarrying()
		local on = character:GetAttribute("Carrying") == true
		stopTracks()
		if on then
			ContextActionService:BindAction(DROP_ACTION, function(_, state)
				if state == Enum.UserInputState.Begin then
					-- Hovering a door / pad: go through it carrying them (InteractController); else drop.
					local Interact = require(script.Parent:WaitForChild("InteractController")) :: any
					if not Interact.useHovered() then
						Net.get(Net.Names.Carry):FireServer("Drop")
					end
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.KeyCode.E, Enum.KeyCode.DPadRight) -- same key as interact (user, 2026-10-30; was ButtonX)
			local pickup, hold = anim("Pickup"), anim("HoldIdle")
			local holdTrack = if hold then animator:LoadAnimation(hold) else nil
			if holdTrack then
				holdTrack.Looped = true
				-- Over walk / run / idle (Movement and Core), under combat (Action2+), whatever the asset
				-- was published with. The arms keep holding while you walk.
				holdTrack.Priority = Enum.AnimationPriority.Action
				table.insert(tracks, holdTrack)
			end
			if pickup then
				local t = animator:LoadAnimation(pickup)
				t.Priority = Enum.AnimationPriority.Action2 -- the scoop plays over everything, hold included
				table.insert(tracks, t)
				t:Play(0.1)
				t.Stopped:Once(function()
					if holdTrack and character:GetAttribute("Carrying") then
						holdTrack:Play(0.15)
					end
				end)
			elseif holdTrack then
				holdTrack:Play(0.15)
			end
		else
			ContextActionService:UnbindAction(DROP_ACTION)
		end
	end
	table.insert(conns, character:GetAttributeChangedSignal("Carrying"):Connect(refreshCarrying))
	refreshCarrying()

	-- Gripping: the grip animation. Cancelled before D.GRIP.at (we got hit): cut it off.
	local gripTrack: AnimationTrack? = nil
	local gripStart = 0
	local function refreshGripping()
		if character:GetAttribute("Gripping") then
			local a = anim("Grip")
			if gripTrack then
				gripTrack:Stop(0)
				gripTrack:Destroy()
			end
			if a then
				gripTrack = animator:LoadAnimation(a)
				local t = gripTrack :: AnimationTrack
				t.Priority = Enum.AnimationPriority.Action4
				t:Play(0.1)
			end
			gripStart = os.clock()
		elseif gripTrack then
			local t = gripTrack :: AnimationTrack
			if os.clock() - gripStart < D.GRIP.at - 0.1 then
				t:Stop(0.15)
			end
			-- Let it finish (or fade), then free it (a new one is loaded every grip).
			task.delay(math.max(0, t.Length - t.TimePosition) + 0.3, function()
				t:Stop(0)
				t:Destroy()
			end)
			gripTrack = nil
		end
	end
	table.insert(conns, character:GetAttributeChangedSignal("Gripping"):Connect(refreshGripping))

	local destroyed = false
	local function destroy()
		if destroyed then
			return
		end
		destroyed = true
		for _, c in conns do
			c:Disconnect()
		end
		stopTracks()
		ContextActionService:UnbindAction(DROP_ACTION)
		gui:Destroy()
	end
	table.insert(conns, humanoid.Died:Connect(destroy))
	return { destroy = destroy }
end

return CarryController
