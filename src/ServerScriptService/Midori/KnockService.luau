--!strict
-- Knocked + carrying (user, 2026-10-18).
-- Knocked: a hit that would kill (HealthSystem.damage) knocks you down instead: State.Knocked for
-- D.KNOCKED.duration, HP at D.KNOCKED.hp, ragdolled (Shared/Ragdoll; each client also plays the
-- down body's bobbing locally), can't act (not Idle) and can't be hit (Fighter.hittable). When it
-- runs out (CombatService onExpire) you get up with D.KNOCKED.recoverHp x max HP.
-- Grip: hover a knocked fighter and press V (InteractController -> the Carry remote's "Grip"):
-- State.Gripping for D.GRIP.at, then they die. Getting hit (or anything else ending the state) cancels it.
-- Carry: hover a knocked fighter and press E (client InteractController -> the Carry remote's
-- "PickUp"; no ProximityPrompts, user 2026-10-18; in range, Idle, hands free,
-- not already carrying) puts them on your shoulder: your client gets their limp body's physics and holds
-- it at D.CARRY.offset from you (Shared/Ragdoll; no weld), with a shoulder collider on you. Drop = the "Carry" remote ("Drop", CarryController's E), or automatically when you get
-- stunned / knocked / die, they get up, or either of you leaves.
-- Replicates as character attributes "Knocked", "Carried", "Carrying", "Gripping" and "Gripped" (true).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Enums = Paths.shared("Enums")
local Net = Paths.shared("Net")
local Ragdoll = Paths.shared("Ragdoll")
local Reach = Paths.shared("Reach")
local Fighter = Paths.server("Fighter")
local Registry = Paths.server("FighterRegistry")
local RateLimit = Paths.server("RateLimit")

local State = Enums.State
local LINK = "MidoriCarrier" -- ObjectValue in the carried model -> the carrier's root (Shared/Ragdoll holds it there)

type Carry = { k: any, link: ObjectValue, collider: BasePart, left: number }
local carrying: { [any]: Carry } = {} -- carrier fighter -> what it carries
local carriedBy: { [any]: any } = {} -- knocked fighter -> its carrier
local gripping: { [any]: any } = {} -- gripper -> knocked fighter
local grippedBy: { [any]: any } = {} -- knocked fighter -> its gripper

local KnockService = {}

-- Tells a player's client its state (the client otherwise only predicts its own actions).
-- endsAt -1: a knock's end comes from the server (recover), never from the client's own clock.
local function stateSync(f: any, endsAt: number, reason: string)
	-- Only to the body it's about: a dead body's state must never reach the player's next character.
	if typeof(f.player) == "Instance" and (f.player :: Player).Character == f.model then
		Net.get(Net.Names.StateSync):FireClient(f.player :: Player, f.state, endsAt, reason)
	end
end

local function owner(part: BasePart, player: Player?)
	pcall(function() -- fails for anchored / not-in-workspace parts (and in edit-mode tests)
		part:SetNetworkOwner(player)
	end)
end

-- The whole (limp) body goes to `player`'s physics, or the server's (nil): limp limbs are their own assemblies.
local function bodyOwner(k: any, player: Player?)
	owner(k.root, player)
	for _, name in { "Head", "Torso", "Left Arm", "Right Arm", "Left Leg", "Right Leg" } do
		local p = k.model:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			owner(p, player)
		end
	end
end

function KnockService.isKnocked(f: any): boolean
	return f.state == State.Knocked
end

function KnockService.isCarrying(f: any): boolean
	return carrying[f] ~= nil
end

function KnockService.carrierOf(k: any): any?
	return carriedBy[k]
end

-- What `c` carries (the knocked fighter), or nil.
function KnockService.carrying(c: any): any?
	local carry = carrying[c]
	return carry and carry.k
end

-- Puts down whatever `c` carries (no-op if nothing). Safe with destroyed models. `now` = the combat
-- clock (CombatService / tests); the paused knock timer resumes from it.
function KnockService.drop(c: any, now: number?)
	local carry = carrying[c]
	if not carry then
		return
	end
	local t = now or workspace:GetServerTimeNow()
	local k = carry.k
	carrying[c] = nil
	carriedBy[k] = nil
	carry.link:Destroy()
	carry.collider:Destroy()
	-- Put the body down at the shoulder, colliding again, and hand its physics back to its owner.
	if k.root.Parent then
		if c.root.Parent then
			k.root.CFrame = c.root.CFrame * D.CARRY.offset
		end
		k.root.AssemblyLinearVelocity = Vector3.zero
		k.root.Anchored = false
		Ragdoll.setGroup(k.model, Ragdoll.GROUP.ragdoll)
		bodyOwner(k, if typeof(k.player) == "Instance" then k.player else nil)
	end
	-- The knock timer was paused while carried: it picks up where it stopped.
	if KnockService.isKnocked(k) then
		k.stateEndsAt = t + carry.left
		k.model:SetAttribute("MStateEnds", k.stateEndsAt)
		k.model:SetAttribute("KnockedLeft", nil)
		stateSync(k, -1, "dropped")
	end
	k.model:SetAttribute("Carried", nil)
	c.model:SetAttribute("Carrying", nil)
end

-- Hands `k`'s body to `c` for a carry / grip (rebuilt 2026-10-24): `c`'s client owns its physics and
-- holds it at the LINK's offset from its own root (Shared/Ragdoll; the shoulder unless `offset`). The
-- body hits nothing meanwhile (ghost group).
local function pin(c: any, k: any, offset: CFrame?): ObjectValue
	Ragdoll.setGroup(k.model, Ragdoll.GROUP.ghost)
	k.root.Anchored = false
	bodyOwner(k, if typeof(c.player) == "Instance" then c.player else nil)
	local link = Instance.new("ObjectValue")
	link.Name = LINK
	link.Value = c.root
	if offset then
		link:SetAttribute("Offset", offset)
		k.root.CFrame = c.root.CFrame * offset
	end
	link.Parent = k.model
	return link
end

local function unpin(k: any, link: ObjectValue, networkOwner: Player?)
	link:Destroy()
	if k.root.Parent then
		k.root.AssemblyLinearVelocity = Vector3.zero
		k.root.Anchored = false
		Ragdoll.setGroup(k.model, Ragdoll.GROUP.ragdoll) -- still down: hits the world again, never characters
		bodyOwner(k, networkOwner)
	end
end

type Grip = { k: any, link: ObjectValue }
local function endGrip(c: any): any?
	local g: Grip? = gripping[c]
	if not g then
		return nil
	end
	gripping[c] = nil
	grippedBy[g.k] = nil
	unpin(g.k, g.link, if typeof(g.k.player) == "Instance" then g.k.player else nil)
	c.model:SetAttribute("Gripping", nil)
	g.k.model:SetAttribute("Gripped", nil)
	return g.k
end

-- `c` starts gripping knocked `k` (same rules as picking up): `k` is pinned D.GRIP.offset in front
-- of `c` (user). Returns whether it worked.
function KnockService.grip(c: any, k: any, now: number?): boolean
	if c == k or not Fighter.hittable(c) or c.state ~= State.Idle or carrying[c] or carriedBy[c] or gripping[c]
		or c.model:GetAttribute("HoldingSoda") or not KnockService.isKnocked(k) or carriedBy[k] or grippedBy[k]
		or Reach.body(c.root.Position, k.root.Position) > D.GRIP.range + 2 -- along the ground: height doesn't eat reach
	then
		return false
	end
	Fighter.setState(c, State.Gripping, D.GRIP.at, now or workspace:GetServerTimeNow())
	gripping[c] = { k = k, link = pin(c, k, D.GRIP.offset) }
	grippedBy[k] = c
	c.model:SetAttribute("Gripping", true)
	k.model:SetAttribute("Gripped", true)
	stateSync(c, -1, "grip") -- rooted until the server ends it
	return true
end

-- The grip ran its D.GRIP.at (CombatService onExpire): they die, are let go and knocked back away
-- from you (user). The server takes the body's physics so the launch isn't overwritten.
function KnockService.finishGrip(c: any, now: number)
	local g: Grip? = gripping[c]
	local k = g and g.k
	local kill = k and KnockService.isKnocked(k) and Fighter.alive(k)
	if g and kill then
		gripping[c] = nil
		grippedBy[k] = nil
		unpin(k, g.link, nil)
		c.model:SetAttribute("Gripping", nil)
		k.model:SetAttribute("Gripped", nil)
		Ragdoll.corpse(k) -- dies limp, not stiff (bug, 2026-11-02)
		k.humanoid.Health = 0
		-- TEMP [GRIPDEBUG]: the corpse's joints half a second later (stiff = motors back on / sockets off / no colliders).
		task.delay(0.5, function()
			local torso = k.model:FindFirstChild("Torso")
			local motors, on, sockets, son = 0, 0, 0, 0
			for _, d in if torso then torso:GetChildren() else {} do
				if d:IsA("Motor6D") then motors += 1; on += if d.Enabled then 1 else 0 end
				if d:IsA("BallSocketConstraint") then sockets += 1; son += if d.Enabled then 1 else 0 end
			end
			local arm = k.model:FindFirstChild("Right Arm")
			local col = arm and arm:FindFirstChild("MidoriRagdollCollider")
			warn("[GRIPDEBUG]", k.model.Name, "motors", motors, "enabled", on, "| sockets", sockets, "enabled", son,
				"| arm collider", col ~= nil and (col :: BasePart).CanCollide, "welded", col ~= nil and col:FindFirstChildOfClass("Weld") ~= nil,
				"| state", k.humanoid:GetState().Name, "| owner", arm and (arm :: BasePart):GetNetworkOwner(), "| height", k.model:GetAttribute("Height"))
		end)
		local sfx = Paths.Assets:FindFirstChild("Sfx")
		local sound = sfx and sfx:FindFirstChild("Generic") and sfx.Generic:FindFirstChild("Grip")
		if sound and sound:IsA("Sound") then
			local clip = sound:Clone() -- on the body: everyone near hears it
			clip.Parent = k.root
			clip:Play()
			game:GetService("Debris"):AddItem(clip, math.max(clip.TimeLength, 1) + 0.5)
		end
		local away = c.root.CFrame.LookVector * Vector3.new(1, 0, 1)
		away = if away.Magnitude > 1e-3 then away.Unit else Vector3.zAxis
		-- The whole corpse is thrown (not just the root): the server simulates it now (Ragdoll.corpse).
		Ragdoll.push(k.model, away * D.GRIP.knockback.speed + Vector3.yAxis * D.GRIP.knockback.up)
	else
		endGrip(c)
	end
	Fighter.setState(c, State.Idle, nil, now)
	stateSync(c, -1, "gripped")
end

-- `c` picks up knocked `k`. Returns whether it worked. `now` = the combat clock (see drop).
-- No weld (user, 2026-10-18: welding the two bodies gave collision + movement problems): `pin` hands
-- the body's physics to the carrier, whose client holds it on its shoulder with one-attachment aligns
-- (only the body is pushed), so the carrier moves exactly as normal. The body hits nothing meanwhile;
-- the shoulder collider below does the walls, and it's part of the carrier.
function KnockService.pickUp(c: any, k: any, now: number?): boolean
	if c == k or not Fighter.hittable(c) or c.state ~= State.Idle or carrying[c] or carriedBy[c]
		or c.model:GetAttribute("HoldingSoda") or not KnockService.isKnocked(k) or carriedBy[k] or carrying[k] or grippedBy[k]
		or Reach.body(c.root.Position, k.root.Position) > D.CARRY.range + 2 -- a little slack for lag; along the ground
	then
		return false
	end
	local link = pin(c, k, nil)
	-- (user) The carried body's own collision: an invisible box over the shoulder, welded to the
	-- carrier (part of their body), so walls stop you instead of the body sliding into them. Its
	-- group never hits characters or ragdolls, and it weighs nothing.
	local collider = Instance.new("Part")
	collider.Name = "MidoriCarryCollider"
	collider.Size = D.CARRY.colliderSize
	collider.Transparency = 1
	collider.CanCollide, collider.CanQuery, collider.CanTouch, collider.Massless = true, false, false, true
	collider.CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.3, 0, 1, 100)
	collider.CFrame = c.root.CFrame * D.CARRY.colliderOffset
	pcall(function()
		collider.CollisionGroup = Ragdoll.GROUP.carry
	end)
	local cw = Instance.new("Weld")
	cw.Part0, cw.Part1 = c.root, collider
	cw.C0 = D.CARRY.colliderOffset
	cw.Parent = collider
	collider.Parent = c.model
	-- (user) Being held pauses the knock timer; drop resumes it.
	local t = now or workspace:GetServerTimeNow()
	local left = math.max(0, k.stateEndsAt - t)
	k.stateEndsAt = math.huge
	k.model:SetAttribute("MStateEnds", -1)
	k.model:SetAttribute("KnockedLeft", left)
	carrying[c] = { k = k, link = link, collider = collider, left = left }
	carriedBy[k] = c
	k.model:SetAttribute("Carried", true)
	c.model:SetAttribute("Carrying", true)
	return true
end

-- Knocks `f` down (HitResolver, after the finishing hit's knockback / ragdoll). `duration` overrides
-- D.KNOCKED.duration (Bloxy Cola: BloxyService).
-- `launch` (Knockback.launch): the finishing hit's throw, carried into the ragdoll.
function KnockService.knock(f: any, now: number, duration: number?, launch: Vector3?)
	if KnockService.isKnocked(f) or not Fighter.alive(f) then
		return
	end
	KnockService.drop(f) -- a carrier who gets knocked drops what it carried
	f.move, f.queued, f.grab, f.grabTarget = nil, nil, nil, nil
	f.fuseMove = nil -- a lit fuse dies with the knock (its cooldown was already set when lit)
	f.blockHeld, f.freshPress, f.stripPending, f.parryUnguard = false, false, false, false
	f.chainIndex = 1
	Fighter.setState(f, State.Knocked, duration or D.KNOCKED.duration, now)
	f.model:SetAttribute("Knocked", true)
	Ragdoll.setGroup(f.model, Ragdoll.GROUP.ragdoll) -- the down body never hits characters (user)
	-- Ragdolled until recover ends it (the knock can be paused by a carry, so no timer of its own).
	-- An already-limp body (a ragdoll hit) keeps its flight: no relaunch unless this hit threw it.
	if launch then
		Ragdoll.apply(f, 1e6, 0, launch)
	else
		Ragdoll.hold(f, 1e6)
	end
	stateSync(f, -1, "knocked")
end

-- Gets `f` back up (CombatService onExpire when the knock runs out).
function KnockService.recover(f: any, now: number)
	local c = carriedBy[f]
	if c then
		KnockService.drop(c, now)
	end
	f.model:SetAttribute("KnockedLeft", nil)
	f.model:SetAttribute("BlackedOut", nil) -- Bloxy Cola blackout over
	f.humanoid.Health = math.max(f.humanoid.Health, f.humanoid.MaxHealth * D.KNOCKED.recoverHp)
	Fighter.setState(f, State.Idle, nil, now)
	f.model:SetAttribute("Knocked", nil)
	Ragdoll.setGroup(f.model, Ragdoll.GROUP.character)
	Ragdoll.stop(f)
	Fighter.syncMeters(f, true)
	stateSync(f, -1, "recovered")
end

-- Every CombatService step: drop carries that can't go on.
function KnockService.step(now: number)
	for c, g in gripping do
		if c.state ~= State.Gripping or not KnockService.isKnocked(g.k) or not g.k.model.Parent then
			endGrip(c) -- hit (or otherwise moved on) mid-grip, or they got up / left: cancelled
		end
	end
	for c, carry in carrying do
		local k = carry.k
		local busy = Enums.STUNS[c.state] or c.state == State.Knocked or c.state == State.Dead
		if busy or not Fighter.alive(c) or not KnockService.isKnocked(k) or not k.model.Parent or not carry.link.Parent or not c.root.Parent then
			KnockService.drop(c, now)
		end
	end
end

function KnockService.init()
	-- ("PickUp", knocked model): the client's hover pick; pickUp re-checks everything (range, states).
	-- ("Grip", knocked model): finish them. ("Drop"): put down what you carry. Players and dummies can be picked up alike.
	Net.get(Net.Names.Carry).OnServerEvent:Connect(function(player: Player, action: any, target: any)
		if not RateLimit.take(player, "Carry") then
			return
		end
		local c = Registry.getByPlayer(player)
		if not c then
			return
		end
		if action == "PickUp" and typeof(target) == "Instance" and target:IsA("Model") then
			local k = Registry.get(target)
			if k then
				KnockService.pickUp(c, k)
			end
		elseif action == "Grip" and typeof(target) == "Instance" and target:IsA("Model") then
			local k = Registry.get(target)
			if k then
				KnockService.grip(c, k)
			end
		elseif action == "Drop" then
			KnockService.drop(c)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		for c, carry in carrying do
			if c.player == player or carry.k.player == player then
				KnockService.drop(c)
			end
		end
		for c, g in gripping do
			if c.player == player or g.k.player == player then
				endGrip(c)
			end
		end
	end)
end

return KnockService
