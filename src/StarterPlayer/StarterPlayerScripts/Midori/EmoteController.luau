--!strict
-- G = emote wheel (user, 2026-10-18): your 4 emotes (player attributes "Emote<n>", rolled on the P
-- menu's Emotes page) around the screen centre, Hi-Fi Rush / Persona like the HUD. Click one to play
-- it; G again or a click elsewhere closes it. Not in combat mode. Emotes are cosmetic, so the client
-- plays them on its own character (Animator tracks replicate); moving stops it. An emote with no
-- `anim` just pops its name in the middle. `loop` emotes (dances) keep going until you move.
-- Gamepad (user, 2026-10-30): hold D-pad down for the wheel, Y/B/A/X plays top/right/bottom/left;
-- letting go closes it. While held, the face buttons only pick emotes (no jump / style toggle).
local Players = game:GetService("Players")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Emotes = Paths.data("Emotes")
local Rarity = Paths.shared("Rarity")

local KEY = Enum.KeyCode.G
local PAD_HOLD = "MidoriEmoteHold"
local PAD_PICK = "MidoriEmotePick"
-- face button -> slot, matching SPOTS (top, right, bottom, left)
local PAD_SLOTS = { [Enum.KeyCode.ButtonY] = 1, [Enum.KeyCode.ButtonB] = 2, [Enum.KeyCode.ButtonA] = 3, [Enum.KeyCode.ButtonX] = 4 }
local FONT = Font.fromEnum(Enum.Font.LuckiestGuy)
local RADIUS = 150
local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local ACCENT = Color3.fromRGB(225, 18, 40)
local CARD = Color3.fromRGB(16, 14, 22)
-- slot n's spot: top, right, bottom, left
local SPOTS = { Vector2.new(0, -1), Vector2.new(1, 0), Vector2.new(0, 1), Vector2.new(-1, 0) }
local TILT = { -4, 3, -3, 4 }

local player = Players.LocalPlayer

local EmoteController = {}

local function new(class: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(class)
	for k, v in props do
		(inst :: any)[k] = v
	end
	inst.Parent = parent
	return inst
end

local function tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function item(id: any): any?
	for _, it in Emotes.items do
		if it.id == id then
			return it
		end
	end
	return nil
end

-- Same hook the P menu uses (CustomShiftLock's ToggleShiftLock bindable).
local function setShiftLock(on: boolean)
	local scripts = player:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("CustomShiftLock")
	local ev = module and module:FindFirstChild("ToggleShiftLock", true)
	if ev and ev:IsA("BindableEvent") then
		ev:Fire(on)
	end
end

function EmoteController.init()
	-- Our wheel is the only way to emote (user, 2026-11-01): Roblox's emote menu off, and the chat's /e
	-- command off once TextChatService makes it (Animate's PlayEmote refuses both anyway).
	pcall(function()
		game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.EmotesMenu, false)
	end)
	-- Emote sounds (`sound`): every client watches every character's Animator and, when an emote with a
	-- sound starts, plays it from that character's root (so everyone near hears it, no remote needed).
	local soundFor: { [string]: Sound } = {}
	local loopFor: { [string]: boolean } = {}
	local sfx = Paths.Assets:WaitForChild("Sfx"):FindFirstChild("Emotes")
	for _, it in Emotes.items do
		local s = it.sound and sfx and sfx:FindFirstChild(it.sound)
		if s and s:IsA("Sound") and it.anim ~= "" then
			soundFor[it.anim] = s
			loopFor[it.anim] = it.loop == true
		end
	end
	local function watchCharacter(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		local animator = humanoid and humanoid:WaitForChild("Animator", 10)
		if not animator or not animator:IsA("Animator") then
			return
		end
		local playingSound: { [AnimationTrack]: Sound } = {}
		animator.AnimationPlayed:Connect(function(t: AnimationTrack)
			local id = t.Animation and t.Animation.AnimationId or ""
			local template = soundFor[id]
			local root = character:FindFirstChild("HumanoidRootPart")
			if not template or not root or playingSound[t] then
				return -- a looping emote replaying itself: its sound is still going
			end
			local s = template:Clone()
			s.Looped = loopFor[id] == true -- looping emotes keep their sound going too
			s.SoundGroup = require(script.Parent:WaitForChild("MusicController")).emoteGroup() -- the MUSIC VOLUME slider
			s.Parent = root
			s:Play()
			playingSound[t] = s
			local function done()
				playingSound[t] = nil
				if s.Parent then
					s:Destroy()
				end
			end
			s.Ended:Once(done)
			t.Stopped:Connect(function()
				-- A looping emote restarts right away; only a stop that sticks ends the sound (moved / cut short).
				task.delay(0.15, function()
					if playingSound[t] == s and not t.IsPlaying then
						done()
					end
				end)
			end)
		end)
	end
	if next(soundFor) then
		local function onPlayer(p: Player)
			p.CharacterAdded:Connect(watchCharacter)
			if p.Character then
				task.spawn(watchCharacter, p.Character)
			end
		end
		Players.PlayerAdded:Connect(onPlayer)
		for _, p in Players:GetPlayers() do
			onPlayer(p)
		end
	end

	task.spawn(function()
		local commands = game:GetService("TextChatService"):WaitForChild("TextChatCommands", 30)
		local emoteCommand = commands and commands:WaitForChild("RBXEmoteCommand", 30)
		if emoteCommand and emoteCommand:IsA("TextChatCommand") then
			emoteCommand.Enabled = false
		end
	end)
	local gui = new("ScreenGui", { Name = "MidoriEmotes", ResetOnSpawn = false, Enabled = false, DisplayOrder = 19, IgnoreGuiInset = true })
	local wheel = new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(0, 0), BackgroundTransparency = 1 }, gui)
	local wheelScale = new("UIScale", {}, wheel)
	local hub = new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(150, 70),
		BackgroundColor3 = ACCENT,
		BorderSizePixel = 0,
		Rotation = -6,
		FontFace = FONT,
		TextSize = 34,
		TextColor3 = WHITE,
		Text = "EMOTE",
	}, wheel)
	new("UIStroke", { Color = BLACK, Thickness = 4, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, hub)
	local hubPop = new("UIScale", {}, hub)

	local buttons: { TextButton } = {}
	local play: (number) -> ()
	for n = 1, Emotes.SLOTS do
		local spot = SPOTS[(n - 1) % #SPOTS + 1]
		local b = new("TextButton", {
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(spot.X * RADIUS * 1.25, spot.Y * RADIUS),
			Size = UDim2.fromOffset(170, 64),
			Rotation = TILT[(n - 1) % #TILT + 1],
			BackgroundColor3 = CARD,
			BorderSizePixel = 0,
			FontFace = FONT,
			TextScaled = true,
			Text = "",
			Modal = true, -- frees the mouse while the wheel is up
		}, wheel)
		new("UITextSizeConstraint", { MaxTextSize = 30 }, b)
		new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 6) }, b)
		local s = new("UIStroke", { Color = WHITE, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
		local scale = new("UIScale", {}, b)
		new("TextLabel", { Text = tostring(n), FontFace = FONT, TextSize = 20, TextColor3 = BLACK, BackgroundColor3 = WHITE, BorderSizePixel = 0, Position = UDim2.fromOffset(-18, -16), Size = UDim2.fromOffset(24, 24), ZIndex = 2 }, b)
		b.MouseEnter:Connect(function()
			tween(scale, 0.12, { Scale = 1.12 }, Enum.EasingStyle.Back)
			tween(b, 0.1, { BackgroundColor3 = ACCENT })
			s.Color = BLACK
		end)
		b.MouseLeave:Connect(function()
			tween(scale, 0.12, { Scale = 1 })
			tween(b, 0.1, { BackgroundColor3 = CARD })
			s.Color = WHITE
		end)
		b.Activated:Connect(function()
			play(n)
		end)
		buttons[n] = b
	end

	local function refresh()
		for n, b in buttons do
			local it = item(player:GetAttribute("Emote" .. n))
			b.Text = if it then string.upper(it.name) else "..."
			b.TextColor3 = Rarity.color(it and it.rarity)
		end
	end
	for n = 1, Emotes.SLOTS do
		player:GetAttributeChangedSignal("Emote" .. n):Connect(refresh)
	end
	refresh()

	local isOpen = false
	local shiftLockWasOn = false
	local function setOpen(open: boolean)
		if open == isOpen then
			return
		end
		isOpen = open
		player:SetAttribute("EmoteWheelOpen", open or nil) -- SkateController frees the mouse while it's up
		if open then
			hub.Text = "EMOTE"
			gui.Enabled = true
			wheelScale.Scale = 0.6
			tween(wheelScale, 0.22, { Scale = 1 }, Enum.EasingStyle.Back)
			shiftLockWasOn = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
			if shiftLockWasOn then
				setShiftLock(false)
			end
		else
			ContextActionService:UnbindAction(PAD_PICK)
			tween(wheelScale, 0.1, { Scale = 0.7 }).Completed:Connect(function()
				if not isOpen then
					gui.Enabled = false
				end
			end)
			if shiftLockWasOn then
				shiftLockWasOn = false
				setShiftLock(true)
			end
		end
	end

	local track: AnimationTrack? = nil
	local conns: { RBXScriptConnection } = {} -- what ends the current emote
	local function stop()
		for _, c in conns do
			c:Disconnect()
		end
		conns = {}
		if track then
			local t = track :: AnimationTrack
			t:Stop(0.2)
			task.delay(0.3, t.Destroy, t) -- a new track per emote: free it (Animator 256-track cap)
			track = nil
		end
	end

	play = function(n: number)
		local it = item(player:GetAttribute("Emote" .. n))
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
		if not it or not humanoid or not animator then
			return
		end
		stop()
		-- Not while you're being moved (a dash, knockback, a fall): the emote would sit on top of it
		-- (user, 2026-11-01: "emoting and dashing is buggy").
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local v = if root and root:IsA("BasePart") then root.AssemblyLinearVelocity else Vector3.zero
		if Vector3.new(v.X, 0, v.Z).Magnitude > 4 or math.abs(v.Y) > 8 then
			return
		end
		if it.anim == "" then
			-- no animation yet: say so in the hub and keep the wheel open
			hub.Text = string.upper(it.name)
			hubPop.Scale = 1.3
			tween(hubPop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			return
		end
		setOpen(false)
		local anim = new("Animation", { AnimationId = it.anim })
		local t = animator:LoadAnimation(anim)
		anim:Destroy()
		-- Top priority (user, 2026-11-01: "emote strength is weak, stop idle playing over them"): the stock
		-- emotes are authored low, so they blended 50/50 with the idle. Action4 owns every joint it keys.
		-- Set before Play so it goes out with the track.
		t.Priority = Enum.AnimationPriority.Action4
		track = t
		t:Play(0.2, 1)
		if it.speed then
			t:AdjustSpeed(it.speed)
		end
		if it.loop then
			-- Looping emotes (dances): play again each time it ends, until stop() swaps the track out. A fresh
			-- Play replicates; a client-set Looped doesn't (others would see it stop after one go).
			t.Stopped:Connect(function()
				if track == t then
					t:Play(0)
					if it.speed then
						t:AdjustSpeed(it.speed)
					end
				end
			end)
		end
		-- What ends it: walking, any other action-level clip starting (a dash, attack, block, the soda ones:
		-- the emote is Action4, so it would sit on top of them), jumping / falling / sitting / ragdolling,
		-- or going into combat mode.
		table.insert(conns, humanoid:GetPropertyChangedSignal("MoveDirection"):Connect(function()
			if humanoid.MoveDirection.Magnitude > 0 then
				stop()
			end
		end))
		table.insert(conns, animator.AnimationPlayed:Connect(function(other: AnimationTrack)
			local p = other.Priority
			if other ~= t and (p == Enum.AnimationPriority.Action or p == Enum.AnimationPriority.Action2 or p == Enum.AnimationPriority.Action3 or p == Enum.AnimationPriority.Action4) then
				stop()
			end
		end))
		table.insert(conns, humanoid.StateChanged:Connect(function(_, new)
			if new == Enum.HumanoidStateType.Jumping or new == Enum.HumanoidStateType.Freefall or new == Enum.HumanoidStateType.Seated
				or new == Enum.HumanoidStateType.FallingDown or new == Enum.HumanoidStateType.Ragdoll or new == Enum.HumanoidStateType.Physics then
				stop()
			end
		end))
		table.insert(conns, (character :: Model):GetAttributeChangedSignal("CombatMode"):Connect(function()
			if (character :: Model):GetAttribute("CombatMode") == true then
				stop()
			end
		end))
	end

	-- No wheel in combat mode, knocked down, or carrying someone.
	local function inCombat(): boolean
		local character = player.Character
		return character ~= nil and (character:GetAttribute("CombatMode") == true or character:GetAttribute("Knocked") == true or character:GetAttribute("Carrying") == true)
	end
	-- Touch (user, 2026-11-02: "how do mobile players dance?"): MobileButtons' EMOTE button, same as G.
	function EmoteController.toggle()
		if not isOpen and inCombat() then
			return
		end
		setOpen(not isOpen)
	end

	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == KEY then
			if not isOpen and inCombat() then
				return
			end
			setOpen(not isOpen)
		elseif isOpen and not processed and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
			setOpen(false) -- clicked off the wheel (a wheel button marks the input processed)
		end
	end)
	-- Gamepad: Low priority so SodaController's D-pad-down DROP (Default) wins while you hold a can.
	ContextActionService:BindActionAtPriority(PAD_HOLD, function(_, state)
		if state == Enum.UserInputState.Begin then
			if inCombat() then
				return Enum.ContextActionResult.Pass
			end
			setOpen(true)
			-- High: above the jump (A) and the style toggle (X) while the wheel is up
			ContextActionService:BindActionAtPriority(PAD_PICK, function(_, s, input)
				if s == Enum.UserInputState.Begin then
					play(PAD_SLOTS[input.KeyCode])
				end
				return Enum.ContextActionResult.Sink
			end, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.ButtonY, Enum.KeyCode.ButtonB, Enum.KeyCode.ButtonA, Enum.KeyCode.ButtonX)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			setOpen(false)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.Low.Value, Enum.KeyCode.DPadDown)
	-- combat mode on mid-emote / with the wheel up: put it all away
	local function watchCharacter(character: Model)
		stop()
		setOpen(false)
		character:GetAttributeChangedSignal("CombatMode"):Connect(function()
			if character:GetAttribute("CombatMode") then
				stop()
				setOpen(false)
			end
		end)
	end
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end
	gui.Parent = player:WaitForChild("PlayerGui")
	Paths.client("UiSounds").watch(gui)
end

return EmoteController
