--!strict
-- Location name popup (user, 2026-10-27). Every part in workspace[D.TRAVEL.folder] (a Persistent Model, so
-- streaming never drops it) is an area named by the part's Name. Walking or teleporting (TravelService) into
-- one slams the name in at the top of the screen for D.TRAVEL.popupHold s. Areas use Zone+ (Lib.Zone),
-- relocated out of workspace on this client so they never block hover picks, clicks or the camera.
-- Also the teleport screen fade (TravelService fires "Out" / "In" on the Travel remote).
-- LocationController.track(zone, name, pool?) adds a zone made elsewhere (the apartment we're in:
-- ApartmentController) as an area; it returns a function that takes it away again.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Zone = Paths.lib("Zone")
local Net = Paths.shared("Net")

local Sticker = require(script.Parent:WaitForChild("Sticker"))
local Music = require(script.Parent:WaitForChild("MusicController"))

local LocationController = {}

-- Areas with attribute Enclosed = true (Club Kuro) are their own place: things inside aren't drawn for
-- anyone outside it and the other way round (ApartmentController's prop hiding). Kept here because the area
-- parts get relocated out of workspace by Zone+.
local enclosed: { { part: BasePart, name: string } } = {}

-- The enclosed area `pos` is in (its name), or nil = the open map.
function LocationController.enclosedAt(pos: Vector3): string?
	for _, e in enclosed do
		local p = e.part.CFrame:PointToObjectSpace(pos)
		local h = e.part.Size / 2
		if math.abs(p.X) <= h.X and math.abs(p.Y) <= h.Y and math.abs(p.Z) <= h.Z then
			return e.name
		end
	end
	return nil
end
LocationController.track = nil :: ((zone: any, name: string, pool: string?, clock: number?) -> () -> ())?

function LocationController.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriLocation"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 3
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	-- Hi-Fi Rush / Persona card, top centre (Sticker), like the HUD.
	local card = Sticker.new({
		parent = gui,
		tag = "NOW ENTERING",
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, 12),
		size = 56,
		away = Vector2.new(0, -200), -- drops in from the top, leaves back up
	})

	local shown: string? = nil
	local gen = 0
	local function show(name: string)
		if name == shown then
			return -- still up (overlapping areas / edge jitter)
		end
		shown = name
		gen += 1
		local my = gen
		card:show(name)
		task.delay(D.TRAVEL.popupHold, function()
			if gen ~= my then
				return
			end
			shown = nil
			card:hide()
		end)
	end

	-- Teleport fade (TravelService): "Out" = to black, "In" = back. Under the name popup, over everything else.
	local fadeGui = Instance.new("ScreenGui")
	fadeGui.Name = "MidoriTravelFade"
	fadeGui.ResetOnSpawn = false
	fadeGui.IgnoreGuiInset = true
	fadeGui.DisplayOrder = 2
	local black = Instance.new("Frame")
	black.Size = UDim2.fromScale(1, 1)
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	black.BackgroundTransparency = 1
	black.BorderSizePixel = 0
	black.Parent = fadeGui
	fadeGui.Parent = gui.Parent
	local fadeGen = 0
	local function fade(to: number, time: number)
		TweenService:Create(black, TweenInfo.new(time, Enum.EasingStyle.Quad), { BackgroundTransparency = to }):Play()
	end
	Net.get(Net.Names.Travel).OnClientEvent:Connect(function(step: string)
		fadeGen += 1
		local my = fadeGen
		if step == "Out" then
			fade(0, D.TRAVEL.fadeOut)
			task.delay(3, function() -- never stay black if "In" got lost
				if fadeGen == my then
					fade(1, D.TRAVEL.fadeIn)
				end
			end)
		else
			fade(1, D.TRAVEL.fadeIn)
		end
	end)

	-- Areas with a number attribute "ClockTime" set this client's time of day while you're inside
	-- (e.g. Club Kuro = 0, midnight); leaving the last one puts the map's own time back.
	local outsideClock = Lighting.ClockTime
	local clocks: { [any]: number } = {} -- zone -> its ClockTime, for the zones we're in
	local function applyClock()
		local _, t = next(clocks)
		Lighting.ClockTime = if t then t else outsideClock
	end

	-- Which area we're in, for the OST pool (MusicController: pool = area name, none = Default).
	local inside: { [any]: string } = {}
	local function applyMusic()
		local _, name = next(inside)
		Music.setPool(name)
	end

	-- `pool` = the OST pool while inside (default: the area's name); `clock` = ClockTime while inside.
	local function track(zone: any, name: string, pool: string?, clock: number?): () -> ()
		local function leave()
			inside[zone] = nil
			applyMusic()
			if clocks[zone] then
				clocks[zone] = nil
				applyClock()
			end
		end
		local entered = zone.localPlayerEntered:Connect(function()
			show(name)
			inside[zone] = pool or name
			applyMusic()
			if typeof(clock) == "number" then
				if next(clocks) == nil then
					outsideClock = Lighting.ClockTime
				end
				clocks[zone] = clock
				applyClock()
			end
		end)
		local exited = zone.localPlayerExited:Connect(leave)
		return function()
			entered:Disconnect()
			exited:Disconnect()
			leave()
		end
	end
	LocationController.track = track

	local folder = workspace:WaitForChild(D.TRAVEL.folder)
	-- ponytail: areas added at runtime aren't picked up; watch ChildAdded if locations ever spawn in.
	for _, part in folder:GetChildren() do
		if part:IsA("BasePart") then
			if part:GetAttribute("Enclosed") == true then
				table.insert(enclosed, { part = part, name = part.Name })
			end
			local zone = Zone.new(part)
			zone:relocate()
			local clock = part:GetAttribute("ClockTime")
			track(zone, part.Name, nil, if typeof(clock) == "number" then clock else nil)
		end
	end
end

return LocationController
