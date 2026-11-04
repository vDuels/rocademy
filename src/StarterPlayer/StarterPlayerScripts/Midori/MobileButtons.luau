--!strict
-- Touch-only buttons, bottom left (inside the left third of the screen), in the HUD / side menu
-- sticker style (D.MENU_ART wallet slab, LuckiestGuy): LOCK = shift lock toggle (CustomShiftLock),
-- RUN = sprint toggle (RunController), EMOTE = the emote wheel (EmoteController, G on keyboard; 2026-11-02).
-- GRIP (2026-11-02) = V on keyboard: only shown while a knocked fighter is in grip range (InteractController),
-- sits above the row.
-- Lit = red slab, white text (user, 2026-10-17).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local SLAB = { x = 380, y = 280, w = 320, h = 120 } -- menu_art.py "wallet"
local SIZE = Vector2.new(128, 48) -- px at REF_HEIGHT
local GAP = 10
local REF_HEIGHT = 400 -- phone landscape height the sizes are tuned for
local LIT = Color3.fromRGB(225, 18, 40)
local FONT = Font.fromEnum(Enum.Font.LuckiestGuy)

local player = Players.LocalPlayer
local MobileButtons = {}
local run: any = nil

-- Main hands over each character's RunController run.
function MobileButtons.setRun(r: any)
	run = r
end

local function shiftLock(): (any, BindableEvent?)
	local scripts = player:FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("SmoothShiftLock", true)
	local ev = module and module:FindFirstChild("ToggleShiftLock")
	if module and module:IsA("ModuleScript") and ev and ev:IsA("BindableEvent") then
		return require(module) :: any, ev
	end
	return nil, nil
end

function MobileButtons.init()
	if not UserInputService.TouchEnabled then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriMobile"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	gui.IgnoreGuiInset = true
	-- Holder sits in the bottom-left corner; its UIScale sizes everything for the screen.
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0, 1)
	holder.Position = UDim2.new(0, 16, 1, -14)
	holder.Size = UDim2.fromOffset(SIZE.X * 3 + GAP * 2, SIZE.Y)
	holder.Parent = gui
	local fit = Instance.new("UIScale")
	fit.Parent = holder

	local function button(text: string, x: number, onTap: () -> ()): (ImageButton, TextLabel)
		local b = Instance.new("ImageButton")
		b.BackgroundTransparency = 1
		b.AutoButtonColor = false
		b.Image = D.MENU_ART
		b.ImageRectOffset = Vector2.new(SLAB.x, SLAB.y)
		b.ImageRectSize = Vector2.new(SLAB.w, SLAB.h)
		b.Position = UDim2.fromOffset(x, 0)
		b.Size = UDim2.fromOffset(SIZE.X, SIZE.Y)
		b.Rotation = -4
		b.Parent = holder
		local pop = Instance.new("UIScale")
		pop.Parent = b
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = 1
		label.Size = UDim2.fromScale(1, 1)
		label.FontFace = FONT
		label.TextSize = 24
		label.TextColor3 = Color3.new(0, 0, 0)
		label.Text = text
		label.Parent = b
		b.Activated:Connect(function()
			onTap()
			pop.Scale = 0.85
			TweenService:Create(pop, TweenInfo.new(0.25, Enum.EasingStyle.Back), { Scale = 1 }):Play()
		end)
		return b, label
	end

	local lockButton, lockLabel = button("LOCK", 0, function()
		local module, ev = shiftLock()
		if module and ev then
			ev:Fire(not module:IsEnabled())
		end
	end)
	local runButton, runLabel = button("RUN", SIZE.X + GAP, function()
		if run then
			run.toggle()
		end
	end)

	local emoteButton, emoteLabel = button("EMOTE", (SIZE.X + GAP) * 2, function()
		Paths.client("EmoteController").toggle()
	end)

	local Interact = Paths.client("InteractController")
	local gripButton, gripLabel = button("GRIP", 0, function()
		Interact.grip()
	end)
	gripButton.Position = UDim2.fromOffset(0, -(SIZE.Y + GAP))
	gripButton.Visible = false

	local function paint(b: ImageButton, label: TextLabel, on: boolean)
		b.ImageColor3 = if on then LIT else Color3.new(1, 1, 1)
		label.TextColor3 = if on then Color3.new(1, 1, 1) else Color3.new(0, 0, 0)
	end
	RunService.RenderStepped:Connect(function()
		local module = shiftLock()
		paint(lockButton, lockLabel, module ~= nil and module:IsEnabled())
		paint(runButton, runLabel, run ~= nil and run.isHeld())
		paint(emoteButton, emoteLabel, player:GetAttribute("EmoteWheelOpen") == true)
		gripButton.Visible = Interact.gripTarget() ~= nil
		paint(gripButton, gripLabel, true) -- always lit: it only shows when it can be used
		local cam = workspace.CurrentCamera
		local vp = if cam then cam.ViewportSize else Vector2.new(800, REF_HEIGHT)
		-- never wider than the left third of the screen
		fit.Scale = math.min(math.clamp(vp.Y / REF_HEIGHT, 0.8, 1.6), (vp.X / 3 - 16) / holder.Size.X.Offset)
	end)
	Paths.client("UiSounds").watch(gui)
	gui.Parent = player:WaitForChild("PlayerGui")
end

return MobileButtons
