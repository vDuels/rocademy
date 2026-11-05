--!strict
-- Teleport pads / doors (user, 2026-10-27). A part tagged D.TRAVEL.tag with a string attribute "To" naming
-- another tagged part is a pad: hover + E (client InteractController -> the Travel remote) puts you in front
-- of "To" (its LookVector side, standing level with its bottom face). Two doors pointing at each other pair up.
-- Walk = true on a pad: walking into it teleports you (no E). "To" can be any tagged part, e.g. a plain arrival marker.
-- The area name popup is client-side (LocationController, Zone+), so arriving shows it like walking in does.
-- Carrying someone (user, 2026-11-01): they come with you, on your shoulder (TravelService.bring), with the
-- same fade and streaming as you. Being carried / knocked / gripping still refuses.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local State = Paths.shared("Enums").State
local Registry = Paths.server("FighterRegistry")
local Fighter = Paths.server("Fighter")
local Reach = Paths.shared("Reach")

local TRAVEL = D.TRAVEL
local BUSY = { "Knocked", "Carried", "Gripping", "Gripped" }

local lastUse: { [Player]: number } = {}

local TravelService = {}

-- Who `f` carries: the knocked fighter, and its player if it's one.
function TravelService.rider(f: any): (any?, Player?)
	local k = Paths.server("KnockService").carrying(f)
	return k, if k then Players:GetPlayerFromCharacter(k.model) else nil
end

-- Puts whatever `f` carries on its shoulder at `cf` (call right after moving `f` there). The carrier's client
-- holds the body at D.CARRY.offset (Shared/Ragdoll), so it just has to start there.
function TravelService.bring(f: any, cf: CFrame)
	local k = TravelService.rider(f)
	if k and k.root.Parent then
		k.root.AssemblyLinearVelocity = Vector3.zero
		k.model:PivotTo(cf * D.CARRY.offset * k.root.CFrame:ToObjectSpace(k.model:GetPivot()))
	end
end

local function find(name: string): BasePart?
	for _, part in CollectionService:GetTagged(TRAVEL.tag) do
		if part.Name == name and part:IsA("BasePart") then
			return part
		end
	end
	return nil
end

-- Where you land: just in front of `dest`, facing the way it faces, root 3 studs above its bottom (R6 hip).
function TravelService.arrival(dest: BasePart): CFrame
	local look = dest.CFrame.LookVector * Vector3.new(1, 0, 1)
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
	local pos = Vector3.new(dest.Position.X, dest.Position.Y - dest.Size.Y / 2 + 3, dest.Position.Z) + look * (dest.Size.Z / 2 + 3)
	return CFrame.lookAt(pos, pos + look)
end

-- Why `player` can't use `pad` right now (nil = they can). Checked on the press AND again right before the
-- move: the fade is a 0.3s window where you could start carrying / gripping / fighting / sitting, and the
-- teleport would leave the carried body behind (user, 2026-10-29: "you can delete someone with it").
local function refusal(player: Player, character: Model?, f: any, pad: BasePart): string?
	if not f or not character or player.Character ~= character or Registry.get(character) ~= f then
		return "no fighter for this character"
	end
	if not Fighter.alive(f) or f.state ~= State.Idle then
		return `not idle ({f.state})`
	end
	-- Distance from the pad's surface, not its centre (walk-in triggers can be big).
	if not pad.Parent or not CollectionService:HasTag(pad, TRAVEL.tag) or Reach.gapToBox(pad.CFrame, pad.Size, f.root.Position) > TRAVEL.reach + 2 then
		return "out of reach"
	end
	for _, attr in BUSY do
		if character:GetAttribute(attr) then
			return attr
		end
	end
	if f.humanoid.Sit then
		return "seated"
	end
	return nil
end

-- For other services' doors (apartment doors: ApartmentService): can `player` use `pad` now? Takes the
-- travel cooldown and returns a `still()` to re-check right before the move, or nil = refused.
function TravelService.check(player: Player, pad: BasePart): (() -> boolean)?
	local character = player.Character
	local f = character and Registry.get(character)
	if refusal(player, character, f, pad) then
		return nil
	end
	local now = os.clock()
	if now - (lastUse[player] or -math.huge) < TRAVEL.cooldown then
		return nil
	end
	lastUse[player] = now
	return function()
		return refusal(player, character, f, pad) == nil
	end
end

local function travel(player: Player, pad: BasePart)
	local character = player.Character
	local f = character and Registry.get(character)
	local to = pad:GetAttribute("To")
	-- Apartment = true pads are apartment doors: claim / visit go through ApartmentService (Apartment remote).
	if typeof(to) ~= "string" or pad:GetAttribute("Apartment") == true then
		return
	end
	if refusal(player, character, f, pad) then
		return
	end
	local now = os.clock()
	if now - (lastUse[player] or -math.huge) < TRAVEL.cooldown then
		return
	end
	local dest = find(to :: string)
	if not dest then
		warn(`[Travel] pad {pad:GetFullName()} points at "{to}", which isn't a tagged part`)
		return
	end
	lastUse[player] = now
	-- Screen fade (LocationController): out, move while black, back in. "In" always follows, even if we bail.
	local remote = Net.get(Net.Names.Travel)
	remote:FireClient(player, "Out")
	local cf = TravelService.arrival(dest)
	pcall(player.RequestStreamAroundAsync, player, cf.Position, 3) -- load the floor before we land on it
	local _, rider = TravelService.rider(f)
	if rider then
		remote:FireClient(rider, "Out")
		pcall(rider.RequestStreamAroundAsync, rider, cf.Position, 3)
	end
	task.wait(math.max(0, TRAVEL.fadeOut - (os.clock() - now)))
	if not refusal(player, character, f, pad) then
		f.root.AssemblyLinearVelocity = Vector3.zero
		character:PivotTo(cf)
		TravelService.bring(f, cf)
	end
	remote:FireClient(player, "In")
	if rider then
		remote:FireClient(rider, "In")
	end
end

function TravelService.init()
	Net.get(Net.Names.Travel).OnServerEvent:Connect(function(player, pad)
		if typeof(pad) == "Instance" and pad:IsA("BasePart") then
			travel(player, pad) -- yields for the fade (OnServerEvent handlers each get their own thread)
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastUse[player] = nil
	end)
	-- Walk-in pads (attribute Walk = true, e.g. the bottom of a staircase): touching it is the same as pressing E.
	local function watch(pad: Instance)
		if pad:IsA("BasePart") and pad:GetAttribute("Walk") then
			pad.Touched:Connect(function(hit)
				local player = Players:GetPlayerFromCharacter(hit.Parent)
				-- Skip touches inside the cooldown (every limb fires one).
				if player and os.clock() - (lastUse[player] or -math.huge) >= TRAVEL.cooldown then
					task.spawn(travel, player, pad) -- yields for the fade
				end
			end)
		end
	end
	CollectionService:GetInstanceAddedSignal(TRAVEL.tag):Connect(watch)
	for _, pad in CollectionService:GetTagged(TRAVEL.tag) do
		watch(pad)
	end
end

return TravelService
