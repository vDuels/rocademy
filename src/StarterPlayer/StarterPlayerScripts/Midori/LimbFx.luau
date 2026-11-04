--!strict
-- Limb flash for M2s / crits (move.limbFx, user 2026-10-16): each named limb ghosts (a plain copy
-- cfg.ghostScale bigger, riding the limb), and HallowSquares spin like buzz saws at random tilts
-- around the limb's end (hand / foot; the head's centre), shrinking In and fading out.
-- Look per move kind: D.LIMB_FX (M2), with D.LIMB_FX_CRIT's fields on top for crits.
-- Local visual only; every client plays it from the swing.
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Ghost = Paths.client("Ghost")

local SQUARE = Paths.Assets:WaitForChild("Vfx"):WaitForChild("HallowSquare") :: MeshPart

local LimbFx = {}

local folder: Folder? = nil
local function container(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "MidoriLimbFx"
		f.Parent = workspace
		folder = f
	end
	return folder :: Folder
end

local function inert(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

-- D.LIMB_FX, plus D.LIMB_FX_CRIT's fields for crits (R).
function LimbFx.config(kind: string): any
	if kind ~= "R" then
		return D.LIMB_FX
	end
	local cfg = table.clone(D.LIMB_FX)
	for k, v in D.LIMB_FX_CRIT do
		cfg[k] = v
	end
	return cfg
end

local function limbOf(model: Model, name: string): BasePart?
	local limb = model:FindFirstChild(name)
	return if limb and limb:IsA("BasePart") then limb else nil
end

-- Runs `step(t, elapsed)` every frame for `time` (t = 0..1), then `done()`; stops early if the limb goes.
local function animate(limb: BasePart, time: number, step: (number, number) -> (), done: () -> ())
	local start = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - start
		local t = elapsed / time
		if t >= 1 or not limb.Parent then
			conn:Disconnect()
			done()
			return
		end
		step(t, elapsed)
	end)
end

-- Just the spinning squares at `limb`'s end, gone after `time`. `spinMult` scales the spin (Firecracker's slower idle squares).
local function squares(limb: BasePart, cfg: any, spinMult: number, time: number)
	local parent = container()
	-- End of the limb: the bottom face in its rest pose (R6 hands / feet); the head's centre.
	local tip = if limb.Name == "Head" then CFrame.identity else CFrame.new(0, -limb.Size.Y / 2, 0)
	local list: { { part: BasePart, tilt: CFrame, spin: number } } = {}
	for _ = 1, cfg.squares do
		local sq = SQUARE:Clone()
		sq:ClearAllChildren()
		sq.TextureID = ""
		sq.Color = cfg.color -- material stays the asset's own (HallowSquare is Neon)
		sq.Transparency = cfg.startTransparency
		inert(sq)
		sq.Parent = parent
		local tilt = CFrame.Angles(math.random() * 2 * math.pi, math.random() * 2 * math.pi, math.random() * 2 * math.pi)
		table.insert(list, { part = sq, tilt = tilt, spin = cfg.spin * spinMult * (if math.random() < 0.5 then -1 else 1) })
	end
	local base = SQUARE.Size
	local thick = base.Y * cfg.size / base.X
	animate(limb, time, function(t, elapsed)
		local e = TweenService:GetValue(t, cfg.shrinkStyle, Enum.EasingDirection.In)
		local w = cfg.size + (cfg.endSize - cfg.size) * e -- size -> endSize
		local at = (limb.CFrame * tip).Position
		for _, s in list do
			s.part.Size = Vector3.new(w, thick, w)
			-- Spin around the square's own normal (Y): a buzz saw on a random tilt.
			s.part.CFrame = CFrame.new(at) * s.tilt * CFrame.Angles(0, s.spin * elapsed, 0)
			s.part.Transparency = cfg.startTransparency + (1 - cfg.startTransparency) * t
		end
	end, function()
		for _, s in list do
			s.part:Destroy()
		end
	end)
end

local function ghost(limb: BasePart, cfg: any)
	local copy: BasePart
	if limb.Name == "Head" then
		copy = Ghost.headCopy(limb) -- a classic head is a mesh-shrunk 2x1x1 part; copy its visible shape
		copy.Size *= cfg.ghostScale
	else
		local p = Instance.new("Part")
		p.Size = limb.Size * cfg.ghostScale
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		copy = p
	end
	copy.Name = "LimbGhost"
	copy.Color = cfg.color
	copy.Material = Enum.Material.SmoothPlastic
	copy.Transparency = cfg.ghostTransparency
	inert(copy)
	copy.Parent = container()
	animate(limb, cfg.time, function(t)
		copy.CFrame = limb.CFrame
		copy.Transparency = cfg.ghostTransparency + (1 - cfg.ghostTransparency) * t
	end, function()
		copy:Destroy()
	end)
end

-- The full flash (ghost + squares) on each named limb. The squares shrink in over `squareTime`
-- (the swing's time to its hitbox, so they close as it lands); the ghost fades over cfg.time.
function LimbFx.play(model: Model, limbs: { string }, cfg: any, squareTime: number)
	for _, name in limbs do
		local limb = limbOf(model, name)
		if limb then
			ghost(limb, cfg)
			squares(limb, cfg, 1, squareTime)
		end
	end
end

-- Squares only, on each named limb (no ghost), at `spinMult` spin.
function LimbFx.squares(model: Model, limbs: { string }, cfg: any, spinMult: number)
	for _, name in limbs do
		local limb = limbOf(model, name)
		if limb then
			squares(limb, cfg, spinMult, cfg.time)
		end
	end
end

return LimbFx
