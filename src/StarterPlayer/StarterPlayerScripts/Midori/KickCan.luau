--!strict
-- Furious Feng's KickCan (user, 2026-11-03), played for every fighter's dash M2 by FeedbackController.swing
-- (move.vfx). The can (move.projectile.model) appears welded in front of the root, gets a Highlight +
-- Vfx.FuriousFengFire at fxAt, and at the hit time (startup) is kicked off, tumbling.
-- The flight is the SERVER's shot (CombatService; "Shot" remote): until its Fire arrives the can flies on our
-- own guess (root facing), then eases onto the real path over BLEND, and it stops exactly where the server's
-- End says (a hit, a wall, its range). So every screen draws the same flight and the can never stops on
-- someone the server missed. Cut off before the kick (stunned, dashed out) = it vanishes.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local MoveSchema = Paths.shared("MoveSchema")
local CombatMath = Paths.shared("CombatMath")
local Net = Paths.shared("Net")
local State = Paths.shared("Enums").State

local BLEND = 0.15 -- s to ease from our guess onto the server's path
local NO_SHOT = 1 -- s after our launch with no Fire from the server: it never threw (refused / cut off)

local KickCan = {}

type Can = {
	model: Model,
	part: BasePart,
	p: any, -- move.projectile
	weld: WeldConstraint?,
	launchedAt: number?, -- os.clock() of our own launch (nil while welded)
	guessFrom: Vector3,
	guessDir: Vector3,
	id: number?, -- the server shot it follows, once Fire arrives
	from: Vector3,
	dir: Vector3,
	at: number, -- server time of the server's launch
	offset: Vector3, -- our guess minus the server path at adoption, eased out over BLEND
	adoptedAt: number,
	endPos: Vector3?,
	conn: RBXScriptConnection?,
}

local live: { Can } = {}

-- Still in the swing: our own body by its predicted state, others by the server's.
local function swinging(model: Model): boolean
	local st = model:GetAttribute(if model == Players.LocalPlayer.Character then "LocalMState" else "MState")
	return model.Parent ~= nil and (st == State.Startup or st == State.Endlag)
end

local function inert(p: BasePart)
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
end

local function projectileOf(model: Model): (any?, any?)
	local style = MoveSchema.ofModel(model)
	local move = style.dashM2 and style.moves[style.dashM2]
	return move, move and move.projectile
end

local function newCan(p: any, cf: CFrame): BasePart?
	local template = Paths.Assets:WaitForChild("Models"):FindFirstChild(p.model)
	if not (template and template:IsA("BasePart")) then
		return nil
	end
	local can = template:Clone()
	inert(can)
	can.Anchored = false
	can.CFrame = cf
	can.Parent = workspace
	return can
end

-- The purple Highlight + Vfx.FuriousFengFire's emitters (locked to the can).
local function ignite(can: BasePart, p: any)
	if can:FindFirstChildOfClass("Highlight") then
		return
	end
	local h = Instance.new("Highlight")
	h.FillColor = p.color
	h.OutlineColor = p.color
	h.Adornee = can
	h.Parent = can
	local fire = Paths.Assets:WaitForChild("Vfx"):FindFirstChild("FuriousFengFire")
	for _, e in if fire then fire:GetDescendants() else {} do
		if e:IsA("ParticleEmitter") then
			local c = e:Clone()
			c.LockedToPart = true
			c.Parent = can
		end
	end
end

-- Stops the fire emitting, lets its particles finish, then removes the can.
local function finish(c: Can)
	local i = table.find(live, c)
	if i then
		table.remove(live, i)
	end
	if c.conn then
		c.conn:Disconnect()
	end
	local can = c.part
	if not can.Parent then
		return
	end
	local fade = 0
	for _, e in can:GetDescendants() do
		if e:IsA("ParticleEmitter") then
			e.Enabled = false
			fade = math.max(fade, e.Lifetime.Max)
		elseif e:IsA("Highlight") then
			e:Destroy()
		end
	end
	can.Transparency = 1
	task.delay(fade, can.Destroy, can)
end

-- Where the server's shot is now (capped at its range).
local function serverPos(c: Can): Vector3
	local d = math.clamp((workspace:GetServerTimeNow() - c.at) * c.p.speed, 0, c.p.range)
	return c.from + c.dir * d
end

-- Kicks it off (our launch, or the server's Fire if that came first): unwelded, anchored, driven per frame.
local function launch(c: Can)
	if c.launchedAt then
		return
	end
	c.launchedAt = os.clock()
	if c.weld then
		c.weld:Destroy()
		c.weld = nil
	end
	local can = c.part
	can.Anchored = true
	c.guessFrom = can.Position
	local rot = can.CFrame.Rotation
	local spinAxis = c.guessDir:Cross(Vector3.yAxis)
	c.conn = RunService.RenderStepped:Connect(function()
		if not can.Parent then
			finish(c)
			return
		end
		local elapsed = os.clock() - (c.launchedAt :: number)
		local pos
		if c.endPos then
			pos = c.endPos
		elseif c.id then
			local blend = math.max(0, 1 - (os.clock() - c.adoptedAt) / BLEND)
			pos = serverPos(c) + c.offset * blend
		else
			if elapsed > NO_SHOT then
				finish(c) -- the server never threw it
				return
			end
			pos = c.guessFrom + c.guessDir * math.min(c.p.range, elapsed * c.p.speed)
		end
		can.CFrame = CFrame.new(pos) * CFrame.fromAxisAngle(spinAxis, -c.p.spin * elapsed) * rot
		if c.endPos then
			finish(c)
		end
	end)
end

-- Follow server shot `id` from now on.
local function adopt(c: Can, id: number, from: Vector3, dir: Vector3, at: number)
	c.id, c.from, c.dir, c.at = id, from, dir, at
	c.adoptedAt = os.clock()
	if not c.launchedAt then
		c.guessDir = dir
		launch(c)
	end
	c.offset = c.part.Position - serverPos(c)
end

function KickCan.play(root: BasePart)
	local model = root.Parent
	if not model or not model:IsA("Model") then
		return
	end
	local move, p = projectileOf(model)
	if not (move and p) then
		return
	end
	local part = newCan(p, root.CFrame * p.offset)
	if not part then
		return
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = part
	weld.Parent = part
	local c: Can = {
		model = model, part = part, p = p, weld = weld, launchedAt = nil,
		guessFrom = part.Position, guessDir = Vector3.zero,
		id = nil, from = Vector3.zero, dir = Vector3.zero, at = 0, offset = Vector3.zero, adoptedAt = 0,
		endPos = nil, conn = nil,
	}
	table.insert(live, c)

	task.delay(p.fxAt, function()
		if not part.Parent then
			return
		end
		if not c.id and not swinging(model) then
			finish(c)
			return
		end
		ignite(part, p)
	end)
	task.delay(move.startup, function()
		if c.launchedAt or not part.Parent then
			return
		end
		if not swinging(model) then
			finish(c)
			return
		end
		local dir = CombatMath.flat(root.CFrame.LookVector)
		c.guessDir = if dir == Vector3.zero then Vector3.new(0, 0, -1) else dir.Unit
		ignite(part, p)
		launch(c)
	end)
end

Net.get("Shot").OnClientEvent:Connect(function(kind: string, id: number, a: any, b: any, c2: any, d: any)
	if kind == "Fire" then
		local model, from, dir, at = a, b, c2, d
		if typeof(model) ~= "Instance" or not model:IsA("Model") then
			return
		end
		-- Our oldest unbound can for that thrower; none (missed its swing, joined late) = a fresh one.
		for _, c in live do
			if c.model == model and not c.id then
				adopt(c, id, from, dir, at)
				return
			end
		end
		local _, p = projectileOf(model)
		local part = p and newCan(p, CFrame.lookAlong(from, dir))
		if not part then
			return
		end
		ignite(part, p)
		local c: Can = {
			model = model, part = part, p = p, weld = nil, launchedAt = nil,
			guessFrom = from, guessDir = dir,
			id = nil, from = from, dir = dir, at = at, offset = Vector3.zero, adoptedAt = 0,
			endPos = nil, conn = nil,
		}
		table.insert(live, c)
		adopt(c, id, from, dir, at)
	elseif kind == "End" then
		for _, c in live do
			if c.id == id then
				c.endPos = a :: Vector3
				return
			end
		end
	end
end)

return KickCan
