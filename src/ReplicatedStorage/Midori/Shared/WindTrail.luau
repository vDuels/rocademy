--!strict
-- Vfx.WindTrail (a model: a part with a Trail between two attachments) welded to a fighter's Torso.
-- Used by strong ragdolls (move.strongRagdoll; Dema M2) and the vending blast (SodaService), and on a
-- Dema M2 user for the whole move. Shared: the server uses it for victims (everyone sees those); each
-- client draws blink users' trails locally the instant the move starts (CombatController / BlinkLane).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local WindTrail = {}

-- Puts a trail `scale` x the template's size on `model`'s Torso (or on `at`, offset by `offset`, e.g. a
-- foot). Returns it (nil without a template).
function WindTrail.attach(model: Model, scale: number?, at: BasePart?, offset: CFrame?): Instance?
	local torso = at or model:FindFirstChild("Torso") or model.PrimaryPart
	local template = Paths.Assets:WaitForChild("Vfx"):FindFirstChild("WindTrail")
	if not template or not torso or not torso:IsA("BasePart") then
		return nil
	end
	local s = scale or D.WIND_TRAIL_SCALE
	local trail = template:Clone()
	if trail:IsA("Model") then
		trail:ScaleTo(s)
		trail:PivotTo(torso.CFrame * (offset or CFrame.identity))
	elseif trail:IsA("BasePart") then
		trail.Size *= s
		trail.CFrame = torso.CFrame * (offset or CFrame.identity)
	end
	local parts = trail:GetDescendants()
	table.insert(parts, trail)
	for _, p in parts do
		if p:IsA("BasePart") then
			p.Anchored = false
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
			p.Massless = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = torso
			weld.Part1 = p
			weld.Parent = p
		end
	end
	trail.Parent = model
	return trail
end

-- Stops emitting, lets the streak fade over its Lifetime, then removes it.
function WindTrail.fade(trail: Instance)
	local fade = 0
	for _, t in trail:GetDescendants() do
		if t:IsA("Trail") then
			t.Enabled = false
			fade = math.max(fade, t.Lifetime)
		end
	end
	task.delay(fade, function()
		trail:Destroy()
	end)
end

-- A trail that lasts while `model` is ragdolled ("Ragdolled" cleared: got up, or the ragdoll ended).
-- Call after Ragdoll.apply (bug, 2026-10-27: trails stayed on after).
function WindTrail.whileRagdolled(model: Model, scale: number?)
	local trail = WindTrail.attach(model, scale)
	if not trail then
		return
	end
	local conn: RBXScriptConnection
	conn = model:GetAttributeChangedSignal("Ragdolled"):Connect(function()
		if model:GetAttribute("Ragdolled") ~= nil then
			return
		end
		conn:Disconnect()
		WindTrail.fade(trail)
	end)
end

-- A trail on `model` while `active()` stays true (checked every frame), then it fades. Client-side use:
-- a local trail shows the moment the move starts, with no wait on the server.
function WindTrail.during(model: Model, active: () -> boolean, scale: number?)
	local trail = WindTrail.attach(model, scale)
	if not trail then
		return
	end
	local conn: RBXScriptConnection
	conn = game:GetService("RunService").Heartbeat:Connect(function()
		if not trail.Parent or not active() then
			conn:Disconnect()
			if trail.Parent then
				WindTrail.fade(trail)
			end
		end
	end)
end


-- A Trail only draws while it moves, so a one-frame teleport shows nothing. This draws the jump: a loose
-- trail flies `from` -> `to` over `time` seconds (client-side, local only), the whole line stays up for
-- D.BLINK_TRAIL_STAY after it lands (user: 0.3), then fades. Blink moves.
function WindTrail.streak(from: CFrame, to: CFrame, time: number?, scale: number?)
	local template = Paths.Assets:WaitForChild("Vfx"):FindFirstChild("WindTrail")
	if not template then
		return
	end
	local trail = template:Clone()
	local s = scale or D.WIND_TRAIL_SCALE
	if trail:IsA("Model") then
		trail:ScaleTo(s)
	elseif trail:IsA("BasePart") then
		trail.Size *= s
	end
	local parts = trail:GetDescendants()
	table.insert(parts, trail)
	for _, p in parts do
		if p:IsA("BasePart") then
			p.Anchored = true
			p.CanCollide = false
			p.CanQuery = false
			p.CanTouch = false
		end
	end
	local function place(cf: CFrame)
		if trail:IsA("Model") then
			trail:PivotTo(cf)
		else
			(trail :: BasePart).CFrame = cf
		end
	end
	place(from)
	local dur = time or D.BLINK_STREAK_TIME
	for _, t in trail:GetDescendants() do
		if t:IsA("Trail") then
			-- Each piece of the line lives Lifetime from when it's drawn: stretch it so the first piece
			-- (drawn at the start of the flight) is still up when the stay ends, then fades as before.
			t.Lifetime += dur + D.BLINK_TRAIL_STAY
		end
	end
	trail.Parent = workspace
	local start = os.clock()
	local conn: RBXScriptConnection
	conn = game:GetService("RunService").RenderStepped:Connect(function()
		local a = math.clamp((os.clock() - start) / dur, 0, 1)
		place(from:Lerp(to, a))
		if a >= 1 then
			conn:Disconnect()
			task.delay(D.BLINK_TRAIL_STAY, WindTrail.fade, trail)
		end
	end)
end

return WindTrail
