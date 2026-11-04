--!strict
-- Blink lane (Dema M2, move.blink; user, 2026-10-28): the hitbox drawn on the ground while the M2 charges.
-- A glowing yellow outline (neon parts) around a pale see-through fill (a SurfaceGui on the floor), as
-- wide as the lane, growing out ahead with the range (CombatMath.blinkRange: 0 -> blink.min at startup ->
-- blink.max at full charge). It follows the user until release, holds there, and fades once the windup
-- is over. Everyone sees everyone's: the local player's from CombatController (predicted), others' from
-- the AttackStarted broadcast + their replicated MState / MStateEnds. Also draws others' wind trails.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local MoveSchema = Paths.shared("MoveSchema")
local CombatMath = Paths.shared("CombatMath")
local WindTrail = Paths.shared("WindTrail")

local L = D.BLINK_LANE
local GROUND_REACH = 12 -- studs below the root to look for the floor
local LIFT = 0.06 -- above the floor, so it never z-fights
local STATE_GRACE = 0.5 -- AttackStarted can beat the MState attribute here: count as started until then
local JUMP_STUDS = 10 -- a torso moving this far in one frame = their blink teleport arrived
-- The lane fill's length fade: true = the GUI's left edge (X = 0) is the user's end. false: seen live
-- (user, 2026-10-29: the far end / top of the lane was the faint one with true).
local NEAR_AT_GUI_LEFT = false

local BlinkLane = {}

local function folder(): Instance
	local f = workspace:FindFirstChild("MidoriBlinkLanes")
	if not f then
		f = Instance.new("Folder")
		f.Name = "MidoriBlinkLanes"
		f.Parent = workspace
	end
	return f
end

local function part(parent: Instance, neon: boolean): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = if neon then Enum.Material.Neon else Enum.Material.SmoothPlastic
	p.Color = L.edge
	p.Transparency = if neon then 0 else 1
	p.Size = Vector3.new(0.05, 0.05, 0.05)
	p.Parent = parent
	return p
end

-- The floor under `root` (characters ignored), else a guess at the feet.
local function groundY(root: BasePart, model: Model): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model, folder() }
	params.RespectCanCollide = true
	local hit = workspace:Raycast(root.Position, Vector3.new(0, -GROUND_REACH, 0), params)
	return (if hit then hit.Position.Y else root.Position.Y - 3) + LIFT
end

-- A loose, anchored, non-colliding copy of an Assets/Vfx model (in our folder).
local function vfx(name: string): Model?
	local template = Paths.Assets:WaitForChild("Vfx"):FindFirstChild(name)
	if not template or not template:IsA("Model") then
		return nil
	end
	local m = template:Clone()
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.CastShadow = false
		end
	end
	m.Parent = folder()
	return m
end

-- Runs step(a) every frame with a = 0 -> 1 over `time`, then destroys `m`.
local function animate(m: Model, time: number, step: (number) -> ())
	local start = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local a = math.clamp((os.clock() - start) / time, 0, 1)
		if not m.Parent then
			conn:Disconnect()
			return
		end
		step(a)
		if a >= 1 then
			conn:Disconnect()
			m:Destroy()
		end
	end)
end

-- One Vfx.GlassSlash at `at` (its long axis is X), `size` x its size, growing out to `slashGrow` x
-- that while fading to invisible over `slashTime`.
local function glassSlash(at: CFrame, size: number)
	local G = D.BLINK_GLASS
	local m = vfx("GlassSlash")
	if not m then
		return
	end
	m:PivotTo(at)
	m:ScaleTo(size)
	local from: { [BasePart]: number } = {}
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			from[p] = p.Transparency
		end
	end
	animate(m, G.slashTime, function(a: number)
		m:ScaleTo(size * (1 + (G.slashGrow - 1) * a))
		for p, t0 in from do
			p.Transparency = t0 + (1 - t0) * a
		end
	end)
end

-- Release (user, 2026-10-28: spread out like a domain full of cuts; repeats every 0.1): a wave of
-- slashes every `waveEvery` s for `storm` s, `perStud` x the distance travelled (the lane's range) per wave
-- (user: more distance = more slashes), at least 1, each at a random spot in the lane (`base` = its
-- near edge on the floor, `width` x `range`), a random height up to `slashHeight`, a random angle, and a
-- random size in `slashSize`.
local function slashStorm(base: CFrame, width: number, range: number)
	local G = D.BLINK_GLASS
	local waves = math.max(1, math.floor(G.storm / G.waveEvery + 0.5))
	for w = 0, waves - 1 do
		task.delay(w * G.waveEvery, function()
			for _ = 1, math.max(1, math.floor(range * G.perStud + 0.5)) do
				local at = base * CFrame.new((math.random() - 0.5) * width, 0.5 + math.random() * G.slashHeight, -math.random() * range)
				local angle = CFrame.Angles(0, math.random() * math.pi * 2, (math.random() - 0.5) * math.pi * 0.9)
				glassSlash(at * angle, G.slashSize[1] + math.random() * (G.slashSize[2] - G.slashSize[1]))
			end
		end)
	end
end

-- Draws `move`'s lane for `model`. `startedAt` = the press (server clock), `startup` = this attack's
-- real minimum windup. `released()` = the release time once known (nil while still held);
-- `active()` = still winding up. Cleans itself up.
function BlinkLane.show(model: Model, move: any, startedAt: number, startup: number, released: () -> number?, active: () -> boolean)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or not move.blink then
		return
	end
	local width = move.blink.width
	local lane = Instance.new("Model")
	lane.Name = model.Name
	local fill = part(lane, false)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 0
	gui.Brightness = 2
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 8
	gui.Parent = fill
	-- The fill glows off the neon lines (user, 2026-10-29): strongest along the two side lines, fading to
	-- nearly clear down the middle, and fading out toward the user's end, which has no line any more.
	-- Two fades multiply: the CanvasGroup's along the length, the frame's across the width.
	local group = Instance.new("CanvasGroup")
	group.Size = UDim2.fromScale(1, 1)
	group.BackgroundTransparency = 1
	group.BorderSizePixel = 0
	group.Parent = gui
	-- Measured (2026-10-29): on this Top-face SurfaceGui the GUI's X runs ALONG the lane (part Z) and Y ACROSS
	-- it (part X). Which end of X is the user's isn't measurable here: NEAR_AT_GUI_LEFT (top of the file) says.
	local along = Instance.new("UIGradient")
	along.Rotation = 0 -- GUI X = the lane's length
	along.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, if NEAR_AT_GUI_LEFT then L.nearFade else 0),
		NumberSequenceKeypoint.new(1, if NEAR_AT_GUI_LEFT then 0 else L.nearFade),
	})
	along.Parent = group
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BorderSizePixel = 0
	frame.BackgroundColor3 = L.color
	frame.BackgroundTransparency = L.fill
	frame.Parent = group
	local across = Instance.new("UIGradient")
	across.Rotation = 90 -- GUI Y = across the lane (symmetric, so its sign doesn't matter)
	across.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, L.centerFade),
		NumberSequenceKeypoint.new(1, 0),
	})
	across.Parent = frame
	-- The far line's own glow (user, 2026-10-29: "the far end has no change"): a second layer over the first,
	-- solid at the far line and gone half a lane-width in, like the side lines' glow. Kept in studs as the
	-- lane grows (its gradient is re-laid every frame below).
	local farGlow = Instance.new("Frame")
	farGlow.Size = UDim2.fromScale(1, 1)
	farGlow.BorderSizePixel = 0
	farGlow.BackgroundColor3 = L.color
	farGlow.BackgroundTransparency = L.fill
	farGlow.Parent = gui
	local farGrad = Instance.new("UIGradient")
	farGrad.Rotation = 0 -- GUI X = the lane's length
	farGrad.Parent = farGlow
	local function layFarGlow(range: number)
		local g = math.clamp(width / 2 / range, 0.001, 0.999) -- the glow's reach, as a share of the length
		-- `at` = distance from the far line (0) to the user's end (1), as a GUI X position. Seen live
		-- (user, 2026-10-29): the first sign put this glow at the user's end, so it's the other way round.
		local function x(at: number): number
			return if NEAR_AT_GUI_LEFT then at else 1 - at
		end
		local points = { { x(0), 0 }, { x(g), 1 }, { x(1), 1 } }
		table.sort(points, function(p, q)
			return p[1] < q[1]
		end)
		local keys = {}
		for _, p in points do
			table.insert(keys, NumberSequenceKeypoint.new(p[1], p[2]))
		end
		keys[1] = NumberSequenceKeypoint.new(0, keys[1].Value)
		keys[#keys] = NumberSequenceKeypoint.new(1, keys[#keys].Value)
		farGrad.Transparency = NumberSequence.new(keys)
	end
	-- Side lines + the far line (the line at the user's end was removed, user 2026-10-29).
	local edges = { part(lane, true), part(lane, true), part(lane, true) }
	lane.Parent = folder()

	local frozen: CFrame? = nil
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		if not lane.Parent or not root.Parent then
			conn:Disconnect()
			lane:Destroy()
			return
		end
		local t = workspace:GetServerTimeNow()
		local rel = released()
		local held = math.min(t, rel or math.huge) - startedAt
		local range = math.max(CombatMath.blinkRange(move, held, startup), 0.05)
		-- Follows the user until release, then stays where the lane was thrown from.
		local base = frozen
		if not base then
			local look = CombatMath.flat(root.CFrame.LookVector)
			local pos = root.Position
			local dir = if look == Vector3.zero then Vector3.new(0, 0, -1) else look
			base = CFrame.lookAlong(Vector3.new(pos.X, groundY(root, model), pos.Z), dir)
			if rel and t >= rel then
				frozen = base
				slashStorm(base, width, range) -- released
			end
		end
		local b = base :: CFrame
		local e = L.edgeWidth
		fill.Size = Vector3.new(width, 0.05, range)
		fill.CFrame = b * CFrame.new(0, 0, -range / 2)
		layFarGlow(range)
		edges[1].Size = Vector3.new(e, 0.1, range)
		edges[1].CFrame = b * CFrame.new(-width / 2, 0, -range / 2)
		edges[2].Size = Vector3.new(e, 0.1, range)
		edges[2].CFrame = b * CFrame.new(width / 2, 0, -range / 2)
		edges[3].Size = Vector3.new(width + e, 0.1, e)
		edges[3].CFrame = b * CFrame.new(0, 0, -range)
		if not active() then
			conn:Disconnect()
			local info = TweenInfo.new(L.fade, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			for _, p in edges do
				TweenService:Create(p, info, { Transparency = 1 }):Play()
			end
			TweenService:Create(frame, info, { BackgroundTransparency = 1 }):Play()
			TweenService:Create(farGlow, info, { BackgroundTransparency = 1 }):Play()
			task.delay(L.fade, function()
				lane:Destroy()
			end)
		end
	end)
end

-- Other fighters' lanes (players + dummies), from the AttackStarted broadcast.
function BlinkLane.init()
	Net.get("AttackStarted").OnClientEvent:Connect(function(model: Model, moveId: string, speed: number)
		if typeof(model) ~= "Instance" or model == Players.LocalPlayer.Character then
			return -- our own is drawn by CombatController
		end
		local move = MoveSchema.ofModel(model).moves[moveId]
		if not move or not move.blink then
			return
		end
		local startedAt = workspace:GetServerTimeNow()
		local hit = move.charge.swing.hit
		BlinkLane.show(model, move, startedAt, move.startup / (if typeof(speed) == "number" and speed > 0 then speed else 1), function(): number?
			-- The server's planned release (an auto release, or the real one once it's let go).
			local ends = model:GetAttribute("MStateEnds")
			return if typeof(ends) == "number" and ends > 0 then ends - hit else nil
		end, function(): boolean
			return model.Parent ~= nil and (model:GetAttribute("MState") == "Startup" or workspace:GetServerTimeNow() - startedAt < STATE_GRACE and model:GetAttribute("MState") ~= "Endlag")
		end)
		-- Their wind trail, drawn here from the start of the move to its end (startup + endlag).
		local seen = false
		local function going(): boolean
			local st = model:GetAttribute("MState")
			if st == "Startup" or st == "Endlag" then
				seen = true
				return model.Parent ~= nil
			end
			return not seen and workspace:GetServerTimeNow() - startedAt < STATE_GRACE and model.Parent ~= nil
		end
		WindTrail.during(model, going)
		-- Their teleport arrives as a one-frame jump: draw it as a streak (WindTrail.streak), once.
		local torso = model:FindFirstChild("Torso") or model:FindFirstChild("HumanoidRootPart")
		if not torso or not torso:IsA("BasePart") then
			return
		end
		local last = torso.CFrame
		local conn: RBXScriptConnection
		conn = RunService.Heartbeat:Connect(function()
			if not going() or not torso.Parent then
				conn:Disconnect()
				return
			end
			local now = torso.CFrame
			if (now.Position - last.Position).Magnitude >= JUMP_STUDS then
				WindTrail.streak(last, now)
				conn:Disconnect()
				return
			end
			last = now
		end)
	end)
end

return BlinkLane
