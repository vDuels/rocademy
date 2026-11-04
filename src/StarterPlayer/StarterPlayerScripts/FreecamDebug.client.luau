-- TEMP [FREECAMDEBUG] (2026-11-02, "freecam doesnt work at all"): on Shift+P, report what freecam the
-- client has and whether it turned on. Delete once fixed.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local player = Players.LocalPlayer
UserInputService.InputBegan:Connect(function(input, processed)
	if input.KeyCode ~= Enum.KeyCode.P then
		return
	end
	local shift = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift)
	local focused = UserInputService:GetFocusedTextBox()
	warn("[FREECAMDEBUG] P pressed: shift =", shift, "processed =", processed, "textbox =", focused and focused:GetFullName())
	task.wait(0.3)
	local found = 0
	for _, d in player:WaitForChild("PlayerGui"):GetDescendants() do
		if d:IsA("LocalScript") and string.find(string.lower(d.Name), "freecam") then
			found += 1
			warn("[FREECAMDEBUG] script", d:GetFullName(), "enabled =", d.Enabled, "FreecamEnabled =", d:GetAttribute("FreecamEnabled"))
		end
	end
	local cam = workspace.CurrentCamera
	warn("[FREECAMDEBUG] freecam scripts in PlayerGui:", found, "| camera type", cam and cam.CameraType, "fov", cam and cam.FieldOfView)
end)
