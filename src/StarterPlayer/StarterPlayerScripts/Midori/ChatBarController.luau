--!strict
-- Chat in the topbar (user, 2026-11-01): the chat window is off (no history on screen), so the only chat box
-- is this TopbarPlus one. Roblox won't let scripts focus a box it drives (ChatInputBarConfiguration.TextBox)
-- and its own "/" never reached it, so this box is ours and sends through RBXGeneral:SendAsync (filtered
-- by Roblox, bubbles over heads, Player.Chatted still fires for admin commands). Roblox's input bar stays
-- enabled, pointed at a hidden stand-in box, so the topbar chat icon is still there; that icon shows /
-- hides our bar.
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")

local Paths = require(game:GetService("ReplicatedStorage"):WaitForChild("Midori"):WaitForChild("Paths"))
local Icon = Paths.lib("Icon")

local ChatBarController = {}

local WIDTH = 400 -- px: TopbarPlus lays the topbar out in offsets

function ChatBarController.init()
	local config = TextChatService:WaitForChild("ChatInputBarConfiguration") :: ChatInputBarConfiguration
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	-- The stand-in Roblox draws its input into instead of its own top-left bar (never shown).
	local holder = Instance.new("ScreenGui")
	holder.Name = "MidoriChatStandIn"
	holder.ResetOnSpawn = false
	holder.Enabled = false
	local standIn = Instance.new("TextBox")
	standIn.Name = "StandIn"
	standIn.Visible = false
	standIn.Parent = holder
	holder.Parent = playerGui
	config.TextBox = standIn

	local icon = Icon.new():setName("Chat"):setWidth(WIDTH):modifyTheme({
		{ "IconButton", "BackgroundTransparency", 1 },
		{ "Widget", "MinimumWidth", WIDTH },
	})
	icon:getInstance("ClickRegion").Visible = false -- clicks go straight to the box

	-- Drawn with Roblox's own chat bar look (ChatInputBarConfiguration's values).
	local bar = Instance.new("Frame")
	bar.Name = "ChatBar"
	bar.Size = UDim2.fromScale(1, 1)
	bar.BackgroundColor3 = config.BackgroundColor3
	bar.BackgroundTransparency = config.BackgroundTransparency
	bar.ZIndex = 20
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = bar

	local box = Instance.new("TextBox")
	box.Name = "ChatBox"
	box.Size = UDim2.fromScale(1, 1)
	box.BackgroundTransparency = 1
	box.ClearTextOnFocus = false
	box.Text = ""
	box.PlaceholderText = "To chat click here or press / key"
	box.PlaceholderColor3 = config.PlaceholderColor3
	box.TextColor3 = config.TextColor3
	box.TextStrokeColor3 = config.TextStrokeColor3
	box.TextStrokeTransparency = config.TextStrokeTransparency
	box.FontFace = config.FontFace
	box.TextSize = config.TextSize
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.TextYAlignment = Enum.TextYAlignment.Center
	box.TextTruncate = Enum.TextTruncate.AtEnd
	box.ClipsDescendants = true
	box.ZIndex = 21
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = box
	box.Parent = bar
	bar.Parent = icon:getInstance("Widget")
	-- Roblox's own "/" handling focuses the stand-in (a moment after we take focus), which swallowed
	-- typing: whenever it gets focus, hand it straight to our box.
	standIn.Focused:Connect(function()
		task.defer(function()
			box:CaptureFocus()
		end)
	end)

	local slashAt = -math.huge -- os.clock() of the last "/" press
	-- The "/" that opened the bar still lands in it when focus wins the race with the keystroke (bug,
	-- 2026-11-02: "it types / in your message"). Eat exactly one "/" typed right after a "/" press.
	local slashText: string? = nil -- the box's text when "/" was pressed, until that "/" is eaten
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local before = slashText
		if not before or os.clock() - slashAt > 0.25 then
			slashText = nil
			return
		end
		local text = box.Text
		if #text ~= #before + 1 then
			return
		end
		-- Where the one new character went (not CursorPosition: it isn't reliable mid-focus).
		local i = 1
		while i <= #before and string.sub(text, i, i) == string.sub(before, i, i) do
			i += 1
		end
		if string.sub(text, i, i) == "/" and string.sub(text, 1, i - 1) .. string.sub(text, i + 1) == before then
			slashText = nil
			box.Text = before
			box.CursorPosition = i
		end
	end)
	box.FocusLost:Connect(function(enter)
		-- Roblox's own "/" handling drops focus a frame after we take it (it reaches for its reserved
		-- stand-in, which can't be focused): take it back, keep what's typed.
		if not enter and os.clock() - slashAt < 0.25 then
			task.defer(function()
				box:CaptureFocus()
			end)
			return
		end
		local message = box.Text
		box.Text = ""
		if not enter or string.match(message, "^%s*$") then
			return
		end
		local channels = TextChatService:FindFirstChild("TextChannels")
		local general = channels and channels:FindFirstChild("RBXGeneral")
		if general and general:IsA("TextChannel") then
			general:SendAsync(message)
		end
	end)

	-- Roblox's chat icon (topbar) shows / hides the bar: it flips the "ChatActive" core value, which has
	-- no changed event, so it's polled.
	local function chatActive(): boolean
		local ok, on = pcall(StarterGui.GetCore, StarterGui, "ChatActive")
		return not ok or on ~= false
	end
	task.spawn(function()
		local shown = true
		while true do
			local on = chatActive()
			if on ~= shown then
				shown = on
				icon:setEnabled(on)
				if not on and box:IsFocused() then
					box:ReleaseFocus()
				end
			end
			task.wait(0.1)
		end
	end)

	-- "/" focuses the bar, opening it first if the chat icon hid it. `processed` isn't checked (Roblox's
	-- chat sinks the key); typing in another box is the real "busy" test (the stand-in doesn't count).
	UserInputService.InputBegan:Connect(function(input)
		local focused = UserInputService:GetFocusedTextBox()
		if input.KeyCode ~= config.KeyboardKeyCode or (focused and focused ~= standIn) then
			return
		end
		slashAt = os.clock()
		slashText = box.Text
		pcall(StarterGui.SetCore, StarterGui, "ChatActive", true)
		icon:setEnabled(true)
		task.defer(function() -- after this frame, so the "/" itself isn't typed in
			box:CaptureFocus()
		end)
	end)
end

return ChatBarController
