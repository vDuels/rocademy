--!strict
-- Owner ,m messages (AdminService): a top-centre banner for a few seconds; a newer one replaces it.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Net = Paths.shared("Net")

local SHOW_TIME = 6
local FADE = 0.3

local AnnounceController = {}

function AnnounceController.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriAnnounce"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local plate = Instance.new("Frame")
	plate.AnchorPoint = Vector2.new(0.5, 0)
	plate.Position = UDim2.new(0.5, 0, 0, 60)
	plate.Size = UDim2.fromOffset(0, 0)
	plate.AutomaticSize = Enum.AutomaticSize.XY
	plate.BackgroundColor3 = Color3.new(0, 0, 0)
	plate.BackgroundTransparency = 1
	plate.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 16), UDim.new(0, 16)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
	pad.Parent = plate

	local label = Instance.new("TextLabel")
	label.AutomaticSize = Enum.AutomaticSize.XY
	label.Size = UDim2.fromOffset(0, 0)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextSize = 22
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextTransparency = 1
	label.TextWrapped = true
	label.Parent = plate
	local cap = Instance.new("UISizeConstraint")
	cap.MaxSize = Vector2.new(700, math.huge)
	cap.Parent = label

	local shown = 0
	local function fade(to: number)
		local info = TweenInfo.new(FADE)
		TweenService:Create(plate, info, { BackgroundTransparency = if to == 0 then 0.35 else 1 }):Play()
		TweenService:Create(label, info, { TextTransparency = to }):Play()
	end

	Net.get(Net.Names.Announce).OnClientEvent:Connect(function(from: string, text: string)
		label.Text = `{from}: {text}`
		fade(0)
		shown += 1
		local mine = shown
		task.delay(SHOW_TIME, function()
			if shown == mine then
				fade(1)
			end
		end)
	end)
end

return AnnounceController