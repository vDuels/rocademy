--!strict
-- Ban Hammer critical's cage (user, 2026-10-15), played for every fighter's crit by FeedbackController.swing
-- (move.vfx). Drops onto the fighter's feet while fading in, flashes at the hit, then fades out. Local only,
-- anchored, driven per frame from the start time. Numbers in D.BANCAGE.
-- ponytail: timings ignore adrenaline's startup speed-up (hit up to 15% earlier); pass the speed if it shows.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local Template = Paths.Assets:WaitForChild("Vfx"):WaitForChild("Bancage") :: Model

local Bancage = {}

function Bancage.play(root: BasePart)
	local C = D.BANCAGE
	local cage = Template:Clone()
	local parts: { BasePart } = {}
	for _, d in cage:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanTouch = false
			d.CanQuery = false
			if d == cage.PrimaryPart then
				d.Transparency = 1 -- the pivot block, not part of the look
			else
				table.insert(parts, d)
			end
		end
	end
	local pivot = cage:GetPivot()
	local box, size = cage:GetBoundingBox()
	local lift = pivot.Position.Y - (box.Position.Y - size.Y / 2) -- pivot height above the cage's bottom
	local feet = root.Position.Y - root.Size.Y / 2 - 2 -- R6: the legs hang 2 studs under the root
	local final = CFrame.new(root.Position.X, feet + lift, root.Position.Z) * pivot.Rotation

	local function set(t: number)
		for _, p in parts do
			p.Transparency = t
		end
	end
	set(C.startT)
	cage:PivotTo(final + Vector3.yAxis * C.drop)
	cage.Parent = workspace

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = os.clock() - t0
		if t < C.fall then
			local a = t / C.fall
			cage:PivotTo(final + Vector3.yAxis * C.drop * (1 - a * a)) -- falls, speeding up
			set(C.startT + (C.landT - C.startT) * a)
		elseif t < C.fall + C.flash then
			cage:PivotTo(final)
			set(C.flashT + (C.holdT - C.flashT) * (t - C.fall) / C.flash)
		elseif t < C.fall + C.flash + C.linger then
			cage:PivotTo(final)
			set(C.holdT + (1 - C.holdT) * (t - C.fall - C.flash) / C.linger)
		else
			conn:Disconnect()
			cage:Destroy()
		end
	end)
end

return Bancage
