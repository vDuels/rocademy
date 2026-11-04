--!strict
-- E to sit (user, 2026-10-27): hover a Seat + E (client InteractController -> the Sit remote). Walking into a
-- seat no longer sits you: every Seat gets CanTouch = false at runtime (Seat:Sit doesn't need touch). Jump to
-- stand up, as usual. Not in combat mode or apartment build mode (2026-10-31). Apartment furniture is built
-- on the server (ApartmentService), so its seats work the same way.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local State = Paths.shared("Enums").State
local Registry = Paths.server("FighterRegistry")
local Fighter = Paths.server("Fighter")

local BUSY = { "Knocked", "Carrying", "Carried", "Gripping", "Gripped", "Skating" }

local SeatService = {}

local function sit(player: Player, seat: Seat)
	local character = player.Character
	local f = character and Registry.get(character)
	if not f or not character or not Fighter.alive(f) or f.state ~= State.Idle or f.humanoid.Sit then
		return
	end
	-- Not in combat mode, not in apartment build mode (user, 2026-10-31).
	if f.combatMode or character:GetAttribute("Building") then
		return
	end
	if seat.Disabled or seat.Occupant or not seat:IsDescendantOf(workspace) or (seat.Position - f.root.Position).Magnitude > D.SEAT.reach + 2 then
		return
	end
	for _, attr in BUSY do
		if character:GetAttribute(attr) then
			return
		end
	end
	seat:Sit(f.humanoid)
end

function SeatService.init()
	Net.get(Net.Names.Sit).OnServerEvent:Connect(function(player, seat)
		if typeof(seat) == "Instance" and seat:IsA("Seat") then
			sit(player, seat)
		end
	end)
	local function noTouch(inst: Instance)
		if inst:IsA("Seat") then
			inst.CanTouch = false
		end
	end
	workspace.DescendantAdded:Connect(noTouch)
	for _, d in workspace:GetDescendants() do
		noTouch(d)
	end
end

return SeatService
