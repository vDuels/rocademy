--!strict
-- TEMP (2026-10-27): hunting the mobile black screen (3D goes black facing orientation 0,-90,0 = +X; UI and
-- Highlights still draw). Devs on touch devices get a live camera readout on the right: the UI survives the
-- black, so read it off the phone while facing +X. Delete this module + its line in Main once found.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CameraDebug = {}

local function v(x: Vector3): string
	return string.format("%.1f, %.1f, %.1f", x.X, x.Y, x.Z)
end

function CameraDebug.init()
	local player = Players.LocalPlayer
	if not UserInputService.TouchEnabled then
		return
	end
	local t = os.clock()
	while player:GetAttribute("Dev") == nil and os.clock() - t < 15 do
		task.wait(0.5)
	end
	if not player:GetAttribute("Dev") then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriCameraDebug"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	local label = Instance.new("TextLabel")
	label.AnchorPoint = Vector2.new(1, 0.5)
	label.Position = UDim2.new(1, -8, 0.5, 0)
	label.Size = UDim2.fromOffset(300, 220)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.4
	label.TextColor3 = Color3.new(0, 1, 0)
	label.Font = Enum.Font.Code
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextWrapped = true
	label.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")

	RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		if not cam then
			label.Text = "no CurrentCamera"
			return
		end
		local cf = cam.CFrame
		local rx, ry, rz = cf:ToOrientation()
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { player.Character :: any }
		local hit = workspace:Raycast(cf.Position, cf.LookVector * 50, params)
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local lines = {
			"pos " .. v(cf.Position),
			string.format("rot %.0f, %.0f, %.0f", math.deg(rx), math.deg(ry), math.deg(rz)),
			"look " .. v(cf.LookVector),
			"focus " .. v(cam.Focus.Position),
			"type " .. cam.CameraType.Name .. "  fov " .. string.format("%.1f", cam.FieldOfView),
			"subject " .. (if cam.CameraSubject then cam.CameraSubject:GetFullName() else "nil"),
			"camChildren " .. #cam:GetChildren(),
			"hit " .. (if hit then hit.Instance:GetFullName() .. string.format(" @%.1f", hit.Distance) else "none"),
			"root " .. (if root then v(root.Position) else "nil"),
			"camOffset " .. (if hum then v(hum.CameraOffset) else "nil"),
			"zoom " .. string.format("%.1f", (cf.Position - cam.Focus.Position).Magnitude),
		}
		label.Text = table.concat(lines, string.char(10))
	end)
end

return CameraDebug
