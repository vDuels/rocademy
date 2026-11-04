--!strict
-- UI sounds (user, 2026-10-17): every button under a watched ScreenGui plays Sfx.Generic.UIHover on
-- hover and Sfx.Generic.UIClick on click, including buttons created after the watch starts.
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))

local UiSounds = {}

local function play(name: string)
	local sound = Paths.Assets:WaitForChild("Sfx"):WaitForChild("Generic"):FindFirstChild(name)
	if sound and sound:IsA("Sound") then
		SoundService:PlayLocalSound(sound)
	end
end

local function hook(inst: Instance)
	if inst:IsA("GuiButton") then
		inst.MouseEnter:Connect(function()
			play("UIHover")
		end)
		inst.Activated:Connect(function()
			play("UIClick")
		end)
	end
end

function UiSounds.watch(root: Instance)
	for _, d in root:GetDescendants() do
		hook(d)
	end
	root.DescendantAdded:Connect(hook)
end

return UiSounds
