--!strict
-- Hover interactions (user, 2026-10-18; replaces ProximityPrompts): point at something you can use and
-- it highlights, with a small "E  ACTION" hint by the cursor; E (gamepad D-pad right) uses it.
--   Mouse: what's under the cursor (with shift lock, that's the screen centre). Gamepad: the screen
--   centre. Touch: tap the thing itself (uses it straight away).
-- Targets, only within reach of YOU (the server checks again):
--   a knocked fighter (not being carried, not you) -> CARRY   (D.CARRY.range; KnockService)
--     ...and V (gamepad D-pad up) -> GRIP: finish them (D.GRIP.range; KnockService). Touch: MobileButtons'
--     GRIP button (shows while one is in range), gripTarget / grip below.
--   a soda can lying in the world (D.SODA.tag)       -> PICK UP (D.SODA.reach; SodaService)
--   a teleport pad / door (D.TRAVEL.tag)             -> TRAVEL  (D.TRAVEL.reach; TravelService)
--   a free Seat                                      -> SIT     (D.SEAT.reach; SeatService)
--   a vending machine (D.SODA.vendorTag)             -> BUY     (D.SODA.price Bux; SodaService "Buy")
--   an apartment's Exit (attribute ApartmentExit)     -> LEAVE   (D.TRAVEL.reach; ApartmentService)
--   your DJ booth (model attribute DJBooth)           -> MUSIC   (D.TRAVEL.reach; DJController's song picker)
--   your poster (model attribute PosterEdit)          -> POSTER  (D.TRAVEL.reach; ApartmentController.openPoster)
--   an apartment door (travel pad, Apartment = true): free -> CLAIM, someone's -> VISIT, yours -> MY DOOR
--     (DoorController's panel: enter / lock / whitelist). ApartmentService "Claim" / "Visit".
-- Nothing while you're knocked, carrying, or the side menu / emote wheel is up; nothing while your
-- hand holds a can (it's full).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local Reach = Paths.shared("Reach")

local FIGHTER_TAG = "MidoriFighter"
local KEYS = { [Enum.KeyCode.E] = true, [Enum.KeyCode.DPadRight] = true } -- was ButtonX: clashed with the style toggle (user, 2026-10-30)
local GRIP_KEYS = { [Enum.KeyCode.V] = true, [Enum.KeyCode.DPadUp] = true }
local RAY_LENGTH = 80 -- from the camera
local PICK_RADIUS = 0.6 -- a sphere cast, so small things (a can) are easy to point at
local COOLDOWN = 0.3 -- between uses (the server answers by changing state)
local FONT = Font.fromEnum(Enum.Font.LuckiestGuy)

local ACTIONS = {
	carry = { text = "CARRY", reach = function() return D.CARRY.range end },
	soda = { text = "PICK UP", reach = function() return D.SODA.reach end },
	travel = { text = "TRAVEL", reach = function() return D.TRAVEL.reach end },
	seat = { text = "SIT", reach = function() return D.SEAT.reach end },
	buy = { text = "BUY", reach = function() return D.SODA.vendReach end }, -- from the machine's bounding box (server allows +2)
	claim = { text = "CLAIM", reach = function() return D.TRAVEL.reach end },
	visit = { text = "VISIT", reach = function() return D.TRAVEL.reach end },
	door = { text = "MY DOOR", reach = function() return D.TRAVEL.reach end },
	dj = { text = "MUSIC", reach = function() return D.TRAVEL.reach end }, -- your own DJ booth (ApartmentController marks it)
	poster = { text = "POSTER", reach = function() return D.TRAVEL.reach end }, -- your own poster: its decal id
	leave = { text = "LEAVE", reach = function() return D.TRAVEL.reach end }, -- an apartment's Exit (ApartmentService "Leave")
}

local player = Players.LocalPlayer

local InteractController = {}

-- What `part` belongs to, if it's something we can use: (kind, the instance to send).
local function resolve(part: Instance): (string?, Instance?)
	if CollectionService:HasTag(part, D.SODA.tag) then
		return "soda", part
	end
	if part:GetAttribute("ApartmentExit") == true then -- set by ApartmentController on the style's Exit part
		return "leave", part
	end
	local booth = part:FindFirstAncestorOfClass("Model")
	if booth and booth:GetAttribute("DJBooth") == true then
		return "dj", booth
	end
	if booth and booth:GetAttribute("PosterEdit") == true then
		return "poster", booth
	end
	if CollectionService:HasTag(part, D.TRAVEL.tag) and part:GetAttribute("Apartment") == true then
		local owner = part:GetAttribute("Owner")
		if owner == player.UserId then
			return "door", part
		elseif owner ~= nil then
			return "visit", part
		end
		-- free: only if we don't have one already (the server refuses a second anyway)
		if player:GetAttribute("AptDoor") then
			return nil, nil
		end
		return "claim", part
	end
	if CollectionService:HasTag(part, D.TRAVEL.tag) then
		-- walk-in pads and arrival markers (no "To") aren't hover targets
		-- (Apartment = true doors have no "To": ApartmentService picks where you go)
		if (typeof(part:GetAttribute("To")) == "string" or part:GetAttribute("Apartment") == true) and not part:GetAttribute("Walk") then
			return "travel", part
		end
		return nil, nil
	end
	-- a vending machine: the tagged part, or any part of a tagged model
	if CollectionService:HasTag(part, D.SODA.vendorTag) then
		return "buy", part
	end
	local vendor = part:FindFirstAncestorOfClass("Model")
	while vendor do
		if CollectionService:HasTag(vendor, D.SODA.vendorTag) then
			return "buy", vendor
		end
		vendor = vendor:FindFirstAncestorOfClass("Model")
	end
	-- a free Seat (the seat part itself: the map's seats all share one 3k-part model, so no sibling lookup)
	if part:IsA("Seat") then
		if not part.Disabled and not part.Occupant then
			return "seat", part
		end
		return nil, nil
	end
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if CollectionService:HasTag(model, FIGHTER_TAG) then
			if model ~= player.Character and model:GetAttribute("Knocked") and not model:GetAttribute("Carried") and not model:GetAttribute("Gripped") then
				return "carry", model
			end
			return nil, nil
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil, nil
end

local function position(kind: string, inst: Instance): Vector3?
	if (kind == "soda" or kind == "travel" or kind == "seat" or kind == "buy" or kind == "leave" or kind == "claim" or kind == "visit" or kind == "door") and inst:IsA("BasePart") then
		return inst.Position
	end
	if (kind == "buy" or kind == "dj" or kind == "poster") and inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	local root = inst:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

-- Can we use anything right now (and soda specifically)?
local function blocked(kind: string?): boolean
	local character = player.Character
	if not character or player:GetAttribute("MenuOpen") or player:GetAttribute("EmoteWheelOpen") then
		return true
	end
	if character:GetAttribute("Knocked") or character:GetAttribute("Gripping") then
		return true -- down
	end
	-- Carrying someone: only doors / pads / the apartment exit, and they come with you (user, 2026-11-01;
	-- TravelService / ApartmentService). E on anything else drops them (CarryController).
	local withRider = { travel = true, claim = true, visit = true, door = true, leave = true }
	if character:GetAttribute("Carrying") and not withRider[kind :: any] then
		return true
	end
	-- Hand full (a can): you can still sit down with it, buy one (it drops out) (user, 2026-10-27), and use
	-- apartment doors / the apartment exit and teleport pads (user, 2026-11-01).
	local handsFree = { seat = true, buy = true, claim = true, visit = true, door = true, leave = true, travel = true }
	if character:GetAttribute("HoldingSoda") and not handsFree[kind :: any] then
		return true
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Sit and kind ~= "soda" then
		return true -- seated: only grabbing a drink, jump to stand up for anything else (user, 2026-10-27)
	end
	if character:GetAttribute("Building") then
		return true -- apartment build mode: clicks / taps are for furniture (a tap on the Exit mustn't leave)
	end
	if kind == "seat" and character:GetAttribute("CombatMode") then
		return true -- no sitting in combat mode (user, 2026-10-31; SeatService refuses too)
	end
	return kind == nil
end

-- The usable thing at screen point `at` (viewport pixels), within reach.
local function pick(at: Vector2): (string?, Instance?)
	local cam = workspace.CurrentCamera
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not cam or not character or not root or not root:IsA("BasePart") then
		return nil, nil
	end
	local ray = cam:ViewportPointToRay(at.X, at.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local hit = workspace:Spherecast(ray.Origin, PICK_RADIUS, ray.Direction * RAY_LENGTH, params)
	if not hit then
		return nil, nil
	end
	local kind, inst = resolve(hit.Instance)
	if not kind or not inst or blocked(kind) then
		return nil, nil
	end
	-- vending machines: from their bounding box, any side (same as the server); everything else: centre distance
	local dist = if kind == "buy" then Reach.gap(inst, root.Position) else (function()
		local pos = position(kind, inst)
		return if not pos then nil
			elseif kind == "carry" then Reach.body(root.Position, pos) -- along the ground, like the server
			else (pos - root.Position).Magnitude
	end)()
	if not dist or dist > ACTIONS[kind].reach() then
		return nil, nil
	end
	return kind, inst
end

local current: { kind: string, inst: Instance }? = nil -- what's under the cursor now (RenderStepped)

local lastUse = 0
local function use(kind: string, inst: Instance)
	if os.clock() - lastUse < COOLDOWN then
		return
	end
	lastUse = os.clock()
	if kind == "grip" then
		Net.get(Net.Names.Carry):FireServer("Grip", inst)
	elseif kind == "carry" then
		Net.get(Net.Names.Carry):FireServer("PickUp", inst)
	elseif kind == "soda" then
		Net.get(Net.Names.Soda):FireServer("Pickup", inst)
	elseif kind == "travel" then
		Net.get(Net.Names.Travel):FireServer(inst)
	elseif kind == "claim" then
		Net.get(Net.Names.Apartment):FireServer("Claim", inst)
	elseif kind == "visit" then
		Net.get(Net.Names.Apartment):FireServer("Visit", inst)
	elseif kind == "door" then
		require(script.Parent:WaitForChild("DoorController")).open(inst :: BasePart)
	elseif kind == "dj" then
		require(script.Parent:WaitForChild("DJController")).openPicker()
	elseif kind == "poster" then
		require(script.Parent:WaitForChild("ApartmentController")).openPoster(inst :: Model)
	elseif kind == "leave" then
		Net.get(Net.Names.Apartment):FireServer("Leave") -- the Exit only exists here, so it isn't sent
	elseif kind == "seat" then
		Net.get(Net.Names.Sit):FireServer(inst)
	elseif kind == "buy" then
		if (player:GetAttribute("Bux") or 0) >= D.SODA.price then
			Net.get(Net.Names.Soda):FireServer("Buy", inst)
		end
	end
end

-- Touch GRIP (user, 2026-11-02: "add gripping to mobile"): the nearest knocked fighter within D.GRIP.range
-- that could be carried (not you, not carried / gripped already), if we can act at all. MobileButtons shows its
-- GRIP button while this isn't nil.
function InteractController.gripTarget(): Model?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or blocked("carry") then
		return nil
	end
	local best, bestDist = nil, D.GRIP.range
	for _, model in CollectionService:GetTagged(FIGHTER_TAG) do
		if model:IsA("Model") and model ~= character and model:GetAttribute("Knocked") and not model:GetAttribute("Carried") and not model:GetAttribute("Gripped") then
			local pos = position("carry", model)
			local d = if pos then Reach.body(root.Position, pos) else math.huge
			if d <= bestDist then
				best, bestDist = model, d
			end
		end
	end
	return best
end

function InteractController.grip()
	local target = InteractController.gripTarget()
	if target then
		use("grip", target)
	end
end

-- CarryController's E while carrying: a door / pad under the cursor wins over dropping. True = used it.
function InteractController.useHovered(): boolean
	local c = current
	if c and not blocked(c.kind) then
		use(c.kind, c.inst)
		return true
	end
	return false
end

function InteractController.init()
	local highlight = Instance.new("Highlight")
	highlight.Name = "MidoriInteractHighlight"
	highlight.FillColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = 0.8
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Enabled = false

	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriInteract"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- positions below are raw viewport pixels (GetMouseLocation)
	gui.DisplayOrder = 4
	local hint = Instance.new("TextLabel")
	hint.AnchorPoint = Vector2.new(0, 0)
	hint.Size = UDim2.fromOffset(200, 56)
	hint.TextYAlignment = Enum.TextYAlignment.Top
	hint.BackgroundTransparency = 1
	hint.FontFace = FONT
	hint.TextSize = 24
	hint.TextColor3 = Color3.new(1, 1, 1)
	hint.TextXAlignment = Enum.TextXAlignment.Left
	hint.Rotation = -4
	hint.Visible = false
	hint.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Parent = hint
	gui.Parent = player:WaitForChild("PlayerGui")

	local function pointer(): Vector2
		local cam = workspace.CurrentCamera
		local gamepad = UserInputService:GetLastInputType().Name:match("^Gamepad") ~= nil
		if gamepad and cam then
			return cam.ViewportSize / 2
		end
		return UserInputService:GetMouseLocation()
	end

	RunService.RenderStepped:Connect(function()
		local touch = UserInputService.TouchEnabled and not UserInputService.MouseEnabled
		local kind, inst = nil, nil
		if not touch then
			kind, inst = pick(pointer())
		end
		current = if kind and inst then { kind = kind, inst = inst } else nil
		if current then
			highlight.Adornee = current.inst
			highlight.Parent = workspace.CurrentCamera
			highlight.Enabled = true
			local at = pointer()
			local pad = UserInputService:GetLastInputType().Name:match("^Gamepad") ~= nil
			hint.Text = `{if pad then "RIGHT" else "E"}  {ACTIONS[current.kind].text}`
			if current.kind == "buy" then
				hint.Text = if (player:GetAttribute("Bux") or 0) >= D.SODA.price
					then `{hint.Text}  {D.SODA.price} BUX`
					else `NOT ENOUGH BUX ({D.SODA.price})`
			end
			if current.kind == "carry" and Reach.body((player.Character :: any).HumanoidRootPart.Position, position("carry", current.inst) :: Vector3) <= D.GRIP.range then
				hint.Text ..= `\n{if pad then "UP" else "V"}  GRIP`
			end
			hint.Position = UDim2.fromOffset(at.X + 18, at.Y + 14)
			hint.Visible = true
		else
			highlight.Enabled = false
			highlight.Adornee = nil
			hint.Visible = false
		end
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		local c = current
		if not c or blocked(c.kind) then
			return
		end
		if KEYS[input.KeyCode] then
			use(c.kind, c.inst)
		elseif GRIP_KEYS[input.KeyCode] and c.kind == "carry" then
			local root = (player.Character :: any).HumanoidRootPart :: BasePart
			local pos = position("carry", c.inst)
			if pos and Reach.body(root.Position, pos) <= D.GRIP.range then
				use("grip", c.inst)
			end
		end
	end)
	-- Touch: tap the thing itself.
	UserInputService.TouchTapInWorld:Connect(function(at: Vector2, processedByUI: boolean)
		if processedByUI then
			return
		end
		local kind, inst = pick(at)
		if kind and inst then
			use(kind, inst)
		end
	end)
end

return InteractController
