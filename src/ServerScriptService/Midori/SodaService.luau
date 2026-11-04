--!strict
-- Bloxy Cola (user, 2026-10-17). Any part tagged D.SODA.tag in the world is a can (e.g. a copy of
-- Assets.Models.BloxyCola); pick it up by hovering it and pressing E (client InteractController ->
-- the Soda remote's "Pickup"; no ProximityPrompts, user 2026-10-18). A held can hangs on a Motor6D named "Soda" from
-- the Right Arm with C0/C1 left at identity: the Soda animations (client, SodaController) place it.
-- The first click opens it ("Opened" attribute, OpenSoda + fizz, no heal); every drink after heals
-- D.SODA.heal of healable HP (regen heals it back), D.SODA.sips drinks per can ("Sips" attribute = left). Backspace drops it
-- back into the world as a pickup; taking HP damage drops it too. While held, the character's
-- "HoldingSoda" attribute is on (CombatService refuses M1: click drinks instead). Where cans come from
-- is still TBD: devs type ",e Soda" for one (and tagged copies placed in the map work).
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local State = Paths.shared("Enums").State
local Registry = Paths.server("FighterRegistry")
local Fighter = Paths.server("Fighter")
local HealthSystem = Paths.server("HealthSystem")
local Reach = Paths.shared("Reach")

local SODA = D.SODA
local MOTOR = "Soda"

type Held = { can: BasePart, drinkAt: number?, sipped: boolean, hurt: RBXScriptConnection? }
local held: { [Player]: Held } = {}

local SodaService = {}

local function fighterOf(player: Player): any
	local character = player.Character
	return character and Registry.get(character)
end

-- Picking up / drinking / dropping only between actions (not attacking, blocking or stunned).
local function free(f: any): boolean
	return f ~= nil and Fighter.alive(f) and f.state == State.Idle
end

local function play(name: string, part: BasePart)
	local template = Paths.Assets:WaitForChild("Sfx"):WaitForChild("Generic"):FindFirstChild(name)
	if template and template:IsA("Sound") then
		local s = template:Clone()
		s.Parent = part
		s:Play()
		s.Ended:Once(function()
			s:Destroy()
		end)
	end
end

local function fizz(can: BasePart, on: boolean)
	local emitter = can:FindFirstChildWhichIsA("ParticleEmitter", true)
	if emitter then
		emitter.Enabled = on
	end
end

local drop: (Player, Held) -> ()

-- A can lying in the world despawns unless someone picks it up first (user, 2026-11-01): empty after
-- SODA.emptyDespawn s, with sips left (or never opened) after SODA.fullDespawn s. Picking it up and putting
-- it down again starts it over.
local function expire(can: BasePart)
	local droppedAt = os.clock()
	can:SetAttribute("DroppedAt", droppedAt)
	local sips = can:GetAttribute("Sips")
	local empty = typeof(sips) == "number" and sips <= 0
	task.delay(if empty then SODA.emptyDespawn else SODA.fullDespawn, function()
		if can.Parent == workspace and can:GetAttribute("DroppedAt") == droppedAt then
			can:Destroy()
		end
	end)
end

-- Puts `can` in `player`'s right hand. Returns false (and leaves the can alone) if they can't hold it now.
local function attach(player: Player, can: BasePart): boolean
	local f = fighterOf(player)
	local character = player.Character
	local arm = character and character:FindFirstChild("Right Arm")
	if held[player] or not free(f) or not arm or not arm:IsA("BasePart") then
		return false
	end
	CollectionService:RemoveTag(can, SODA.tag)
	can:SetAttribute("InApartment", nil) -- in a hand now: it's wherever its holder is
	if can:GetAttribute("Sips") == nil then
		can:SetAttribute("Sips", SODA.sips) -- a fresh can (dropped cans keep what's left)
	end
	can.Anchored = false
	can.CanCollide = false
	can.CanQuery = false
	can.CanTouch = false
	can.Massless = true
	can.Parent = player.Character
	local motor = Instance.new("Motor6D")
	motor.Name = MOTOR
	motor.Part0 = arm
	motor.Part1 = can
	motor.Parent = arm
	local h: Held = { can = can, drinkAt = nil, sipped = false, hurt = nil }
	held[player] = h
	character:SetAttribute("HoldingSoda", true)
	-- Any HP damage knocks it out of your hand (and cancels a drink in progress).
	local hp = f.humanoid.Health
	h.hurt = f.humanoid.HealthChanged:Connect(function(new)
		if new < hp - 1e-3 and held[player] == h then
			drop(player, h)
		end
		hp = new
	end)
	Net.get(Net.Names.Soda):FireClient(player, "Pickup")
	return true
end

-- A tagged can in the world, within reach (the client's hover pick; never trusted blindly).
local function pickup(player: Player, can: BasePart)
	local f = fighterOf(player)
	if not f or not can.Parent or not CollectionService:HasTag(can, SODA.tag) or (can.Position - f.root.Position).Magnitude > SODA.reach + 2 then
		return
	end
	if f.model:GetAttribute("Building") then
		return -- apartment build mode: clicks are for furniture (user, 2026-11-01)
	end
	attach(player, can)
end

-- ",e Soda" (devs) and the vending machine: a fresh can straight into your hand. False if you can't hold one now.
local function give(player: Player): boolean
	local f = fighterOf(player)
	if not f then
		return false
	end
	local can = (Paths.Assets:WaitForChild("Models"):WaitForChild("BloxyCola") :: BasePart):Clone()
	can.Name = "Soda" -- the model is BloxyCola; the instance in game is just "Soda" (user)
	can.CFrame = f.root.CFrame
	if not attach(player, can) then
		can:Destroy()
		return false
	end
	return true
end

-- Vending machine (user, 2026-10-27): anything tagged SODA.vendorTag (the machine model) sells a fresh can
-- for SODA.price Bux. The can DROPS out of the machine's side that faces you; pick it up with E like any
-- can. 1 in 1000 (SODA.fatalChance) it fires out like a bullet instead (Sfx.Generic.VendingBlast): you're
-- ragdolled and launched with Vfx.WindTrail on your Torso, taking SODA.blast.damage (999: knocked). The owner can rig the
-- next buy (anyone's) to do it: the Panel's RIG NEXT CAN (RigVending remote).
local lastBuy: { [Player]: number } = {}
local riggedNext = false

-- The can hit you: ragdolled, launched along `dir` (your client runs it, like any knockback), trail on,
-- and SODA.blast.damage through the normal damage path (user, 2026-10-27: damage, not a kill), so a
-- lethal amount knocks you like any finishing hit.
local function blast(f: any, dir: Vector3)
	local X = SODA.blast
	local flat = Vector3.new(dir.X, 0, dir.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else f.root.CFrame.LookVector
	Paths.server("Knockback").push(f, flat, X.distance, X.duration, nil, X.up)
	Paths.shared("Ragdoll").apply(f, X.ragdoll, X.spin)
	Paths.shared("WindTrail").whileRagdolled(f.model, X.trailScale)
	if HealthSystem.damage(nil, f, X.damage, 0) then
		Paths.server("KnockService").knock(f, workspace:GetServerTimeNow())
	end
end
local function buy(player: Player, vendor: Instance)
	local f = fighterOf(player)
	if not f or not Fighter.alive(f) or not CollectionService:HasTag(vendor, SODA.vendorTag) or not vendor:IsDescendantOf(workspace) then
		return
	end
	local gap = Reach.gap(vendor, f.root.Position) -- from the machine's bounding box, any side
	if not gap or gap > SODA.vendReach + 2 or os.clock() - (lastBuy[player] or -math.huge) < SODA.buyCooldown then
		return
	end
	local data = Paths.server("PlayerData").get(player)
	if not data or data.Bux < SODA.price then
		return
	end
	lastBuy[player] = os.clock()
	data.Bux -= SODA.price
	player:SetAttribute("Bux", data.Bux)

	-- The slot: the bounding box's side facing the buyer, near the bottom.
	local cf: CFrame, size: Vector3
	if vendor:IsA("Model") then
		cf, size = vendor:GetBoundingBox()
	else
		cf, size = (vendor :: BasePart).CFrame, (vendor :: BasePart).Size
	end
	local rel = cf:PointToObjectSpace(f.root.Position)
	local alongX = math.abs(rel.X) / size.X > math.abs(rel.Z) / size.Z
	local axis = if alongX then Vector3.new(if rel.X >= 0 then 1 else -1, 0, 0) else Vector3.new(0, 0, if rel.Z >= 0 then 1 else -1)
	local out = cf:VectorToWorldSpace(axis)
	local half = if alongX then size.X / 2 else size.Z / 2
	local slot = cf.Position + out * (half + 0.6) - cf.UpVector * (size.Y / 2 - 1.5)

	-- Sfx.Generic.buy (the purchase) + Vending (the dispense), from the machine part nearest the slot.
	local nearest: BasePart? = if vendor:IsA("BasePart") then vendor else nil
	if not nearest then
		local best = math.huge
		for _, p in vendor:GetDescendants() do
			if p:IsA("BasePart") and (p.Position - slot).Magnitude < best then
				best = (p.Position - slot).Magnitude
				nearest = p
			end
		end
	end
	if nearest then
		play("buy", nearest)
		play("Vending", nearest)
	end

	local can = (Paths.Assets:WaitForChild("Models"):WaitForChild("BloxyCola") :: BasePart):Clone()
	can.Name = "Soda"
	can.CFrame = CFrame.lookAlong(slot, out)
	can.Anchored = false
	can.CanCollide = true
	can.CanQuery = true
	can.CanTouch = true
	can.Massless = false
	can.Parent = workspace
	can:SetNetworkOwner(nil)
	expire(can)
	local function pickupable()
		if can.Parent == workspace then
			CollectionService:AddTag(can, SODA.tag)
		end
	end
	local fatal = riggedNext or math.random() < SODA.fatalChance
	if fatal then
		-- The 1 in 1000 (or rigged): it comes out like a bullet, straight at you.
		riggedNext = false
		can.CanCollide = false
		local toYou = f.root.Position - slot
		can.AssemblyLinearVelocity = toYou.Unit * SODA.fatalSpeed
		if nearest then
			play("VendingBlast", nearest)
		end
		task.delay(math.min(0.2, toYou.Magnitude / SODA.fatalSpeed), function()
			play("SodaHit", can)
			if Fighter.alive(f) then
				blast(f, toYou)
			end
			can.CanCollide = true
			task.delay(0.5, pickupable)
		end)
	else
		can.AssemblyLinearVelocity = out * SODA.dispenseSpeed + Vector3.yAxis * 2
		task.delay(0.5, pickupable)
	end
end

local function sip(player: Player, h: Held, at: number)
	if held[player] ~= h or h.drinkAt ~= at or h.sipped then
		return
	end
	h.sipped = true
	h.drinkAt = nil
	local f = fighterOf(player)
	-- Stunned or hit since the drink started: no heal, and the sip isn't used up.
	if not free(f) or f.lastHitTakenAt >= at then
		fizz(h.can, false)
		h.sipped = false
		return
	end
	HealthSystem.addHealable(f, SODA.heal) -- tops up the healable pool; regen heals it back
	h.can:SetAttribute("Sips", math.max(0, (h.can:GetAttribute("Sips") :: number? or 1) - 1))
	play("Drink", h.can)
	task.delay(0.6, fizz, h.can, false)
	-- Every can is Bloxy Cola: too many sips and it hits you (BloxyService). A blackout drops the can.
	if Paths.server("BloxyService").onSip(player, f) then
		drop(player, h)
	end
end

drop = function(player: Player, h: Held)
	held[player] = nil
	if h.hurt then
		h.hurt:Disconnect()
	end
	local can = h.can
	local character = player.Character
	if character then
		character:SetAttribute("HoldingSoda", nil)
	end
	local arm = character and character:FindFirstChild("Right Arm")
	local motor = arm and arm:FindFirstChild(MOTOR)
	if motor then
		motor:Destroy()
	end
	fizz(can, false)
	can.Parent = workspace
	can.Massless = false
	can.CanCollide = true
	can.CanQuery = true
	can.CanTouch = true
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	-- Whose apartment it was dropped in, if any (clients elsewhere don't draw it; ApartmentService clears
	-- them when the apartment comes down). Apartments are real server parts, so it falls like anywhere else.
	can:SetAttribute("InApartment", character and character:GetAttribute("InApartment"))
	if root then
		can.AssemblyLinearVelocity = root.AssemblyLinearVelocity + root.CFrame.LookVector * SODA.dropSpeed
	end
	can:SetNetworkOwner(nil)
	-- clink when it lands on something that isn't a character
	local landed: RBXScriptConnection
	landed = can.Touched:Connect(function(other)
		if other.Parent and other.Parent:FindFirstChildOfClass("Humanoid") then
			return
		end
		landed:Disconnect()
		play("DropSoda", can) -- user, 2026-11-03: was SodaHit (now KickCan's hit sound)
	end)
	task.delay(0.5, function()
		if can.Parent == workspace then
			CollectionService:AddTag(can, SODA.tag) -- a pickup again
		end
	end)
	expire(can)
end

-- ,soda flood (AdminService; user, 2026-11-01): SODA.floodCount fresh cans tumble out in front of `player`,
-- pickups like any dropped can (and despawn like them). Returns false if there's nowhere to put them.
local lastFlood: { [Player]: number } = {}
function SodaService.flood(player: Player): boolean
	local f = fighterOf(player)
	if not f or os.clock() - (lastFlood[player] or -math.huge) < SODA.floodCooldown then
		return false
	end
	lastFlood[player] = os.clock()
	local template = Paths.Assets:WaitForChild("Models"):WaitForChild("BloxyCola") :: BasePart
	local front = f.root.CFrame * CFrame.new(0, 0, -6) -- 6 studs ahead, at root height
	local apartment = f.model:GetAttribute("InApartment")
	for i = 1, SODA.floodCount do
		local can = template:Clone()
		can.Name = "Soda"
		-- a heap: spread over ~5 x 5 studs, stacked up to ~8 studs high so they spill down
		can.CFrame = front * CFrame.new((math.random() - 0.5) * 5, 1 + (i / SODA.floodCount) * 8, (math.random() - 0.5) * 5)
			* CFrame.Angles(math.random() * math.pi * 2, math.random() * math.pi * 2, 0)
		can.Anchored = false
		can.CanCollide, can.CanQuery, can.CanTouch, can.Massless = true, true, true, false
		can:SetAttribute("InApartment", apartment) -- an apartment flood stays (and goes) with the apartment
		can.Parent = workspace
		can:SetNetworkOwner(nil)
		expire(can)
		task.delay(0.5, function()
			if can.Parent == workspace then
				CollectionService:AddTag(can, SODA.tag)
			end
		end)
	end
	return true
end

function SodaService.init()
	-- Panel: RIG NEXT CAN. Only the owners, D.OWNER_IDS (UserIds, not a role; everyone in Studio). Answers
	-- on the same remote: (ok, message).
	local rigRemote = Net.get(Net.Names.RigVending)
	rigRemote.OnServerEvent:Connect(function(player)
		local ok = game:GetService("RunService"):IsStudio() or table.find(D.OWNER_IDS, player.UserId) ~= nil
		if ok then
			riggedNext = true
		end
		rigRemote:FireClient(player, ok, if ok then "NEXT BUYER GETS BLASTED" else "NOT ALLOWED")
	end)
	Net.get(Net.Names.Soda).OnServerEvent:Connect(function(player, action, target)
		if action == "Pickup" then
			-- pickup checks the tag, reach and that you're free; it only ever takes one can
			if typeof(target) == "Instance" and target:IsA("BasePart") then
				pickup(player, target)
			end
			return
		elseif action == "Buy" then
			if typeof(target) == "Instance" then
				buy(player, target)
			end
			return
		end
		local h = held[player]
		if not h or typeof(action) ~= "string" then
			return
		end
		local now = workspace:GetServerTimeNow()
		if action == "Open" then
			if h.drinkAt or h.can:GetAttribute("Opened") or not free(fighterOf(player)) then
				return
			end
			h.can:SetAttribute("Opened", true)
			play("OpenSoda", h.can)
			fizz(h.can, true)
			task.delay(1, function()
				if not h.drinkAt then
					fizz(h.can, false)
				end
			end)
		elseif action == "Drink" then
			local sips = h.can:GetAttribute("Sips")
			if h.drinkAt or not h.can:GetAttribute("Opened") or typeof(sips) ~= "number" or sips <= 0 or not free(fighterOf(player)) then
				return
			end
			h.drinkAt = now
			h.sipped = false
			fizz(h.can, true)
			local at = now
			task.delay(SODA.sipTimeout, function()
				sip(player, h, at) -- no "Sip" marker came (or no animation yet)
			end)
		elseif action == "Sip" then
			local at = h.drinkAt
			if at and now - at >= SODA.minSip then
				sip(player, h, at)
			end
		elseif action == "Drop" then
			if not h.drinkAt then
				drop(player, h)
			end
		end
	end)

	local function forget(player: Player)
		local h = held[player]
		if h and h.hurt then
			h.hurt:Disconnect()
		end
		held[player] = nil -- the can goes with the old character
		lastBuy[player] = nil
		lastFlood[player] = nil
	end
	Players.PlayerRemoving:Connect(forget)
	local function watch(player: Player)
		player.CharacterRemoving:Connect(function()
			forget(player)
		end)
		player.Chatted:Connect(function(message: string)
			if string.lower(message):match("^,e%s+soda%s*$") and Paths.server("RoleService").isDev(player) then
				give(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
end

return SodaService
