--!strict
-- Cosmic Ray (user, 2026-10-23): a dash throws a mirage of the dasher dashing the opposite way, on the
-- dash's own curve, with the matching dash clip; the more Focus they hold, the more real it looks. Visual
-- only, local on every screen (FeedbackController.dash, for your own dash and everyone else's).
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local CombatMath = Paths.shared("CombatMath")
local DashMotor = Paths.shared("DashMotor")
local CutscenePuppet = Paths.client("CutscenePuppet")

-- Focus shapes it (user, 2026-10-24): no mirage under MIN_FOCUS; at MIN_FOCUS it's blue-tinted and
-- see-through (an obvious fake), and by CLEAN_FOCUS the tint is gone with only a slight transparency
-- left (passes for the real thing). Linear in between, held past CLEAN_FOCUS. Same on every screen.
local MIN_FOCUS, CLEAN_FOCUS = 10, 80
local TINT = Color3.fromRGB(70, 150, 255)
local TINT_FILL = 0.45 -- Highlight fill transparency at full tint (1 = no tint)
local SEE_THROUGH, SLIGHT = 0.4, 0.1 -- body transparency at MIN_FOCUS .. at CLEAN_FOCUS
local FADE = 0.25 -- after the dash, it fades out over this
local CLIP_SPEED = 2.6 -- dash clips (~0.95s) squeezed toward the 0.2s dash

local Mirage = {}

local function focusOf(character: Model): number
	local f = character:GetAttribute("Focus")
	return if character:GetAttribute("FocusOn") == true and typeof(f) == "number" then f else 0
end

-- `dir` = the real dash's direction; the mirage goes `distance` studs the other way.
function Mirage.spawn(character: Model, dir: Vector3, distance: number)
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local away = -CombatMath.flat(dir)
	local focus = focusOf(character)
	if not root or away == Vector3.zero or focus < MIN_FOCUS then
		return
	end
	local ok, p = pcall(CutscenePuppet.new, character)
	if not ok then
		return
	end
	local u = math.clamp((focus - MIN_FOCUS) / (CLEAN_FOCUS - MIN_FOCUS), 0, 1) -- 0 = obvious fake, 1 = clean
	local base = SEE_THROUGH + (SLIGHT - SEE_THROUGH) * u
	local fading: { Instance } = {}
	for _, d in p.model:GetDescendants() do
		if (d:IsA("BasePart") and d.Name ~= "HumanoidRootPart") or d:IsA("Decal") then
			(d :: any).Transparency = math.max((d :: any).Transparency, base)
			table.insert(fading, d)
		end
	end
	-- The blue tint: a Highlight fill, so it covers clothing too (a part Color wouldn't).
	local tint: Highlight? = nil
	if u < 1 then
		tint = Instance.new("Highlight")
		tint.FillColor = TINT
		tint.FillTransparency = TINT_FILL + (1 - TINT_FILL) * u
		tint.OutlineTransparency = 1
		tint.DepthMode = Enum.HighlightDepthMode.Occluded
		tint.Parent = p.model
	end
	local start = root.CFrame
	p.show(true) -- alongside the real body
	p.setCFrame(start)

	-- The dash clip for the way the mirage goes, relative to where it faces.
	local look = CombatMath.flat(start.LookVector)
	local f, r = away:Dot(look), away:Dot(look:Cross(Vector3.yAxis))
	local slot = if math.abs(f) >= math.abs(r) then (if f >= 0 then "Front" else "Back") else (if r >= 0 then "Right" else "Left")
	local clip = Paths.Assets:FindFirstChild("Animations")
	clip = clip and clip:FindFirstChild("Dash")
	clip = clip and clip:FindFirstChild(slot)
	local humanoid = p.model:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if clip and clip:IsA("Animation") and animator then
		local track = animator:LoadAnimation(clip)
		track.Priority = Enum.AnimationPriority.Action4
		track:Play(0.05, 1, CLIP_SPEED)
	end

	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local s = math.min(1, (os.clock() - t0) / D.DASH_DURATION)
		p.setCFrame(start + away * distance * DashMotor.ease(s))
		if s >= 1 then
			conn:Disconnect()
			local info = TweenInfo.new(FADE, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			for _, d in fading do
				TweenService:Create(d, info, { Transparency = 1 }):Play()
			end
			if tint then
				TweenService:Create(tint, info, { FillTransparency = 1 }):Play()
			end
			task.delay(FADE, p.destroy)
		end
	end)
end

return Mirage