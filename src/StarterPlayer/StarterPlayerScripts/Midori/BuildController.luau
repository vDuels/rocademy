--!strict
-- Apartment build mode (user, 2026-10-31). Only inside your own apartment (ApartmentController.state).
-- BUILD (bottom right) turns it on; the server then puts every visitor out and keeps them out until DONE.
-- Screen, Hi-Fi Rush / Persona like the HUD + P menu (red / black stickers, hard drop shadows, LuckiestGuy,
-- motion on everything), SCALE ONLY (no offsets, no pixel strokes: outlines are black frames behind, text
-- readability is a black drop-shadow copy):
--   top left   BUILD MODE banner (slams in, bops on D.HUD_BPM)
--   right      the panel, two modes (top right): BAG = what you own (PlayerData.Decor), free count badge,
--              ALL PLACED when none are free; SHOP = everything with a Data/Furniture `price`, bought with Bux
--              (Furnish "Buy"; it lands in the bag). Category tabs (Data/Furniture `category`); every card has a
--              3D ViewportFrame preview that spins on hover. Holding a placed item, click the panel to store it.
--              WALLS = paint: COLOR / MATERIAL swatches (D.APARTMENT.wallColors / wallMaterials); pick one, then
--              click a wall or ceiling and that room's walls / ceiling take it (Models under the style's Walls with a Paint
--              attribute: "<room>" or "<room>/Ceiling"; Apartment "Paint").
--   bottom     STYLE strip (Models in Assets.Apartment; each keeps its own layout) + the controls bar
-- Pick a card and a ghost follows the mouse, snapped to 2-stud cells (Shared/GridMath) on a room floor, a
-- table / shelf top, or (wall items) the wall you point at. Green = the server will take it (same
-- GridMath.check). Click = place. Touch: tap the world to aim, tap a placed item to pick it up, and the
-- PLACE / ROTATE / STORE / CANCEL buttons (left) do the rest; dragging still turns the camera. With nothing held,
-- placed items outline on hover; click one to move it. X stores the held item, or the hovered one (back to
-- the bag, a "+1" flies to the panel). R rotates, right click / Backspace cancels.
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local GridMath = Paths.shared("GridMath")
local Apartment = require(script.Parent:WaitForChild("ApartmentController"))
local Hud = require(script.Parent:WaitForChild("HudController"))

local player = Players.LocalPlayer
local state = Apartment.state

local CELL = GridMath.CELL
local GOOD = Color3.fromRGB(90, 230, 120)
local BAD = Color3.fromRGB(240, 70, 70)
local RED = Color3.fromRGB(225, 18, 40) -- the HUD / menu red
local BLACK = Color3.new(0, 0, 0)
local WHITE = Color3.new(1, 1, 1)
local CARD = Color3.fromRGB(36, 33, 46)
local WELL = Color3.fromRGB(16, 14, 22)
local DIM = Color3.fromRGB(120, 115, 135)
local YELLOW = Color3.fromRGB(255, 220, 40)
local FONT = Enum.Font.LuckiestGuy
local REACH = 200 -- studs the aim ray goes
local SHADOW = Vector2.new(0.025, 0.06) -- hard drop shadow, as a share of the sticker's size
local SFX = { -- Assets.Sfx.Generic (swap these freely)
	click = "UIClick",
	hover = "UIHover",
	place = "Blocked",
	store = "WeakBlock",
	error = "WeakBlock",
	buy = "buy",
}

local BuildController = {}

local function getDef(id: string): any?
	return Paths.furniture(id)
end

-- Copies of `id` we own that aren't placed (in this style's layout).
local function free(id: string): number
	local n = state.decor[id] or 0
	for _, it in state.items do
		n -= if it.item == id then 1 else 0
	end
	return n
end

local function play(key: string)
	local generic = Paths.Assets:FindFirstChild("Sfx") and Paths.Assets.Sfx:FindFirstChild("Generic")
	local s = generic and generic:FindFirstChild(SFX[key])
	if s and s:IsA("Sound") then
		SoundService:PlayLocalSound(s)
	end
end

local function tween(o: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?)
	TweenService:Create(o, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props):Play()
end

-- UI pieces (scale only) ----------------------------------------------------------------------------

local function new(class: string, props: { [string]: any }, parent: Instance?): any
	local o = Instance.new(class)
	if o:IsA("GuiObject") then
		o.BorderSizePixel = 0
		o.BackgroundTransparency = 1
	end
	for k, v in props do
		(o :: any)[k] = v
	end
	o.Parent = parent
	return o
end

-- A sticker: hard black drop shadow + black outline + `color` fill (inset by `border`, a share of each side).
-- Returns the outer frame (position / size / rotate / scale it) and the fill (put content in it).
local function sticker(parent: Instance, color: Color3, props: { [string]: any }, border: Vector2?): (Frame, Frame)
	local b = border or Vector2.new(0.03, 0.08)
	local outer = new("Frame", props, parent)
	new("Frame", { Name = "Shadow", BackgroundTransparency = 0, BackgroundColor3 = BLACK, Size = UDim2.fromScale(1, 1), Position = UDim2.fromScale(SHADOW.X, SHADOW.Y), ZIndex = 0 }, outer)
	new("Frame", { Name = "Outline", BackgroundTransparency = 0, BackgroundColor3 = BLACK, Size = UDim2.fromScale(1, 1), ZIndex = 1 }, outer)
	local fill = new("Frame", {
		Name = "Fill", BackgroundTransparency = 0, BackgroundColor3 = color, ZIndex = 2,
		AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(1 - b.X * 2, 1 - b.Y * 2),
	}, outer)
	return outer, fill
end

-- LuckiestGuy text with a black drop-shadow copy. Returns a setter (text, colour?).
local function text(parent: Instance, str: string, props: { [string]: any }): ((string, Color3?) -> (), TextLabel)
	-- TextColor3 / TextXAlignment are for the labels; everything else sizes / places the holder.
	local frameProps = table.clone(props)
	frameProps.TextColor3, frameProps.TextXAlignment = nil, nil
	local holder = new("Frame", frameProps, parent)
	local z = (props.ZIndex or 3) :: number
	local function label(color: Color3, pos: UDim2, zi: number): TextLabel
		return new("TextLabel", {
			Font = FONT, TextScaled = true, TextColor3 = color, Text = str, Size = UDim2.fromScale(1, 1), Position = pos, ZIndex = zi,
			TextXAlignment = props.TextXAlignment or Enum.TextXAlignment.Center,
		}, holder)
	end
	local shadow = label(BLACK, UDim2.fromScale(0.012, 0.09), z)
	local main = label(props.TextColor3 or WHITE, UDim2.new(), z + 1)
	return function(s: string, c: Color3?)
		main.Text, shadow.Text = s, s
		if c then
			main.TextColor3 = c
		end
	end, main
end

local function aspect(o: Instance, ratio: number)
	new("UIAspectRatioConstraint", { AspectRatio = ratio }, o)
end

-- A 3D preview of furniture `id` in `parent` (fills it). Returns the model (spin it by pivoting).
local function preview(parent: Instance, id: string): Model?
	local template = Paths.Assets:WaitForChild("Furniture"):FindFirstChild(id)
	if not (template and template:IsA("Model")) then
		return nil
	end
	local vp = new("ViewportFrame", { Size = UDim2.fromScale(1, 1), Ambient = Color3.fromRGB(170, 165, 180), LightColor = WHITE, LightDirection = Vector3.new(-1, -2, -1), ZIndex = 3 }, parent)
	local m = template:Clone()
	m:PivotTo(CFrame.new())
	m.Parent = vp
	local cf, size = m:GetBoundingBox()
	local cam = new("Camera", { FieldOfView = 40 }, vp)
	local r = size.Magnitude / 2
	-- From the front (models face -Z; wall items would otherwise show their back), a bit above and to the side.
	cam.CFrame = CFrame.lookAt(cf.Position + Vector3.new(0.8, 0.7, -1).Unit * (r / math.sin(math.rad(20)) * 1.05), cf.Position)
	vp.CurrentCamera = cam
	return m
end

function BuildController.init()
	local furnish = Net.get(Net.Names.Furnish)
	local apartment = Net.get(Net.Names.Apartment)

	-- Sibling: ZIndex only orders siblings (like the HUD). Global let a card's preview well (3) cover its badge's fill (2).
	local gui = new("ScreenGui", { Name = "MidoriBuild", ResetOnSpawn = false, Enabled = false, IgnoreGuiInset = true, DisplayOrder = 3, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))

	-- BUILD / DONE toggle ---------------------------------------------------------------------------
	local toggle, toggleFill = sticker(gui, RED, { Name = "Toggle", AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(0.98, 0.96), Size = UDim2.fromScale(0.13, 0.08), Rotation = -3 })
	aspect(toggle, 2.8)
	local toggleScale = new("UIScale", {}, toggle)
	local setToggle = text(toggleFill, "BUILD", { Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1) })
	local toggleButton = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, toggle)
	-- DOOR (above BUILD): the door panel from inside (lock / whitelist; DoorController).
	local doorChip, doorFill = sticker(gui, BLACK, { Name = "Door", AnchorPoint = Vector2.new(1, 1), Position = UDim2.fromScale(0.975, 0.865), Size = UDim2.fromScale(0.09, 0.055), Rotation = 3 })
	aspect(doorChip, 2.8)
	text(doorFill, "DOOR", { Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1), TextColor3 = YELLOW })
	new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, doorChip).Activated:Connect(function()
		require(script.Parent:WaitForChild("DoorController")).open(nil)
	end)

	-- Banner ------------------------------------------------------------------------------------------
	local banner = new("Frame", { Name = "Banner", Position = UDim2.fromScale(0.02, 0.05), Size = UDim2.fromScale(0.3, 0.12), Rotation = -4, Visible = false }, gui)
	aspect(banner, 3.6)
	local bannerScale = new("UIScale", {}, banner)
	local _, slashFill = sticker(banner, RED, { Position = UDim2.fromScale(0, 0.3), Size = UDim2.fromScale(1, 0.62) })
	text(slashFill, "BUILD MODE", { Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1) })
	local _, tagFill = sticker(banner, BLACK, { Position = UDim2.fromScale(0.06, 0), Size = UDim2.fromScale(0.62, 0.3), Rotation = 3 }, Vector2.new(0, 0))
	text(tagFill, "DOOR LOCKED  ·  VISITORS OUT", { Size = UDim2.fromScale(0.9, 0.7), Position = UDim2.fromScale(0.05, 0.15), TextColor3 = YELLOW })

	-- Inventory panel ---------------------------------------------------------------------------------
	local panel, panelFill = sticker(gui, WELL, { Name = "Inventory", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.fromScale(0.98, 0.45), Size = UDim2.fromScale(0.3, 0.68), Visible = false }, Vector2.new(0.025, 0.012))
	aspect(panel, 0.66)
	local panelShadow = panel:FindFirstChild("Shadow") :: Frame -- the shared SHADOW share is too tall on a panel this high
	panelShadow.Position = UDim2.fromScale(0.025, 0.016)
	-- Ends before the BAG / SHOP chips (top right) so it never sits on them.
	local _, headerFill = sticker(panel, RED, { Position = UDim2.fromScale(-0.04, -0.04), Size = UDim2.fromScale(0.48, 0.1), Rotation = -3, ZIndex = 5 })
	local setHeader = text(headerFill, "BAG", { Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1), TextXAlignment = Enum.TextXAlignment.Left })
	-- BAG (what you own) / SHOP (buy with Bux) / WALLS (paint), top right.
	local modes = new("Frame", { Name = "Modes", Position = UDim2.fromScale(0.5, 0.01), Size = UDim2.fromScale(0.48, 0.062), ZIndex = 6 }, panelFill)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, HorizontalAlignment = Enum.HorizontalAlignment.Right, Padding = UDim.new(0.05, 0), VerticalAlignment = Enum.VerticalAlignment.Center }, modes)
	-- Bottom line: "3/5 PLACED" in the bag, your Bux in the shop.
	local setCount = text(panelFill, "", { Position = UDim2.fromScale(0.04, 0.935), Size = UDim2.fromScale(0.92, 0.045), TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left })
	local tabs = new("Frame", { Name = "Tabs", Position = UDim2.fromScale(0.04, 0.085), Size = UDim2.fromScale(0.92, 0.06), ZIndex = 3 }, panelFill) -- over the drop zone
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0.025, 0), VerticalAlignment = Enum.VerticalAlignment.Center }, tabs)
	-- Holding a placed item: clicking anywhere on the panel (cards included) puts it back in the bag.
	local dropZone = new("TextButton", { Name = "DropZone", Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 2, AutoButtonColor = false }, panelFill)
	local grid = new("ScrollingFrame", {
		Name = "Grid", Position = UDim2.fromScale(0.04, 0.17), Size = UDim2.fromScale(0.92, 0.755), CanvasSize = UDim2.new(), ZIndex = 3, -- over the drop zone

		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.Y,
	}, panelFill)
	-- Cell height comes from the aspect constraint, width-dominant. (A 0 scale height made every card
	-- 1x1 px: "nothing in my bag", user 2026-10-31. Measured in edit mode: this gives ~190x223 cells.)
	local layout = new("UIGridLayout", { CellSize = UDim2.fromScale(0.47, 1), CellPadding = UDim2.fromScale(0.06, 0.02), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
	new("UIAspectRatioConstraint", { AspectRatio = 0.85, DominantAxis = Enum.DominantAxis.Width }, layout)
	-- On the panel, not in the grid (the grid layout would make it a cell).
	local setEmpty, emptyLabel = text(panelFill, "", { Position = UDim2.fromScale(0.06, 0.4), Size = UDim2.fromScale(0.88, 0.06), TextColor3 = DIM })

	-- Style strip ---------------------------------------------------------------------------------
	-- Bottom centre: the HUD's controls list owns the bottom left.
	local styleStrip = new("Frame", { Name = "Styles", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.96), Size = UDim2.fromScale(0.42, 0.065), Visible = false }, gui)
	aspect(styleStrip, 9)
	local _, styleTagFill = sticker(styleStrip, BLACK, { Size = UDim2.fromScale(0.16, 1), Rotation = -4 }, Vector2.new(0, 0))
	text(styleTagFill, "STYLE", { Size = UDim2.fromScale(0.85, 0.7), Position = UDim2.fromScale(0.075, 0.15), TextColor3 = YELLOW })
	local styleList = new("Frame", { Position = UDim2.fromScale(0.19, 0), Size = UDim2.fromScale(0.81, 1) }, styleStrip)
	new("UIListLayout", { FillDirection = Enum.FillDirection.Horizontal, Padding = UDim.new(0.02, 0), VerticalAlignment = Enum.VerticalAlignment.Center }, styleList)

	-- Status line (above the style strip). The keys go in the HUD's own bottom-left controls list.
	local setStatus, statusLabel = text(gui, "", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.88), Size = UDim2.fromScale(0.4, 0.045) })
	local statusHolder = statusLabel.Parent :: Frame
	statusHolder.Visible = false

	local function setControls(list: { { string } }?)
		Hud.setControls(list)
	end

	-- State --------------------------------------------------------------------------------------------
	local building = false
	local held: { item: string, uid: string? }? = nil
	local rot = 0
	local ghost: Model? = nil
	local highlight: Highlight? = nil
	local target: GridMath.Item? = nil -- where the ghost is now (nil = pointing at nothing usable)
	local valid = false
	local category = "ALL"
	local mode = "BAG" -- or "SHOP" / "WALLS"
	local brush: { kind: string, value: string }? = nil -- WALLS: the finish we're painting with (kind "c" colour / "m" material)
	local tapAt: Vector2? = nil -- touch: the last tap in the world (the ghost aims there); nil = screen centre
	local cards: { [string]: { refresh: () -> (), spin: Model?, holder: Frame } } = {}
	local hovered: string? = nil

	local hoverOutline = new("Highlight", { FillTransparency = 1, OutlineColor = WHITE, OutlineTransparency = 0, DepthMode = Enum.HighlightDepthMode.Occluded, Enabled = false }, nil)

	local function refreshCards()
		for _, c in cards do
			c.refresh()
		end
		if mode == "SHOP" then
			setCount(`YOUR BUX: {player:GetAttribute("Bux") or 0}`, YELLOW)
		elseif mode == "WALLS" then
			setCount(if brush then "CLICK A WALL OR CEILING" else "PICK A COLOR OR MATERIAL", if brush then YELLOW else DIM)
		else
			local owned, placed = 0, 0
			for id, n in state.decor do
				owned += n
				placed += n - math.max(free(id), 0)
			end
			setCount(`{placed}/{owned} PLACED`, DIM)
		end
		-- Holding a placed item: the panel is where it goes back.
		setHeader(if held and held.uid then "CLICK TO STORE" else mode)
	end

	local function updateControls()
		if not building then
			setControls(nil)
		elseif held and held.uid then
			setControls({ { "M1", "Place" }, { "R", "Rotate" }, { "X", "Store in bag" }, { "M2", "Cancel" } })
		elseif held then
			setControls({ { "M1", "Place" }, { "R", "Rotate" }, { "M2", "Cancel" } })
		elseif brush then
			setControls({ { "M1", "Paint a wall / ceiling" }, { "M2", "Cancel" } })
		else
			setControls({ { "M1", "Move an item" }, { "X", "Store hovered item" }, { "BAG", "Pick one to place" }, { "SHOP", "Buy furniture" }, { "WALLS", "Paint a room" } })
		end
	end

	local statusGen = 0
	local function status(msg: string, bad: boolean)
		statusGen += 1
		local my = statusGen
		setStatus(string.upper(msg), if bad then BAD else YELLOW)
		statusHolder.Visible = true
		statusHolder.Rotation = if bad then 4 else -2
		tween(statusHolder, 0.35, { Rotation = 0 }, Enum.EasingStyle.Elastic)
		task.delay(1.8, function()
			if statusGen == my then
				statusHolder.Visible = false
			end
		end)
	end

	-- The placed model being moved goes invisible (and unhittable) while its ghost is out.
	local function showPlaced(uid: string?, on: boolean)
		local m = uid and state.models[uid]
		if m then
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") then
					d.LocalTransparencyModifier = if on then 0 else 1
					d.CanQuery = on
				end
			end
		end
	end

	local function drop()
		if ghost then
			ghost:Destroy()
		end
		showPlaced(held and held.uid, true)
		ghost, highlight, held, target, brush = nil, nil, nil, nil, nil
		refreshCards()
		updateControls()
	end

	local function hold(item: string, uid: string?)
		drop()
		local template = Paths.Assets:WaitForChild("Furniture"):FindFirstChild(item)
		if not template or not state.folder then
			return
		end
		held = { item = item, uid = uid }
		if not uid then
			tapAt = nil -- touch: a fresh pick from the bag starts at the screen centre, not the last tap
		end
		rot = if uid and state.items[uid] then state.items[uid].rot else 0
		local g = template:Clone() :: Model
		for _, d in g:GetDescendants() do
			if d:IsA("BasePart") then
				d.CanCollide, d.CanQuery, d.CanTouch = false, false, false
				d.Transparency = math.max(d.Transparency, 0.35)
			end
		end
		local h = Instance.new("Highlight")
		h.FillTransparency = 0.55
		h.Parent = g
		ghost, highlight = g, h
		showPlaced(uid, false)
		hoverOutline.Enabled = false
		play("click")
		refreshCards()
		updateControls()
	end

	-- Puts placed item `uid` (and whatever is on it) back in the bag; a "+1 NAME" flies from the cursor to the panel.
	local function store(uid: string)
		local it = state.items[uid]
		local def = it and getDef(it.item)
		local cam = workspace.CurrentCamera
		if not it or not def or not cam then
			return
		end
		furnish:FireServer("PickUp", uid)
		play("store")
		local at = UserInputService:GetMouseLocation()
		local vp = cam.ViewportSize
		local _, flyLabel = text(gui, `+1 {string.upper(def.name)}`, {
			AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(at.X / vp.X, at.Y / vp.Y),
			Size = UDim2.fromScale(0.18, 0.045), TextColor3 = YELLOW, ZIndex = 20,
		})
		local fly = flyLabel.Parent :: Frame
		tween(fly, 0.5, { Position = UDim2.fromScale(0.83, 0.2) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		task.delay(0.5, function()
			fly:Destroy()
		end)
		if held and held.uid == uid then
			drop()
		end
	end

	dropZone.Activated:Connect(function()
		if held and held.uid then
			store(held.uid)
		end
	end)

	-- Where we aim: the mouse, or on touch the last tap in the world (dragging still turns the camera).
	local function touching(): boolean
		return UserInputService:GetLastInputType() == Enum.UserInputType.Touch
	end
	local function pointer(): Vector2
		if touching() then
			local cam = workspace.CurrentCamera
			return tapAt or (if cam then cam.ViewportSize / 2 else Vector2.zero)
		end
		return UserInputService:GetMouseLocation()
	end

	local function aimRay(): RaycastResult?
		local camera = workspace.CurrentCamera
		if not camera or not state.folder then
			return nil
		end
		local m = pointer()
		local ray = camera:ViewportPointToRay(m.X, m.Y)
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { state.folder }
		return workspace:Raycast(ray.Origin, ray.Direction * REACH, params)
	end

	-- The placed item (uid, model) under the mouse.
	local function placedUnderMouse(): (string?, Model?)
		local hit = aimRay()
		local model = hit and hit.Instance:FindFirstAncestorOfClass("Model")
		local uid = model and model:GetAttribute("Uid")
		if typeof(uid) == "string" and state.items[uid] then
			return uid, model
		end
		return nil, nil
	end

	-- The paint target under the mouse: a Model with a Paint attribute ("<room>" walls / "<room>/Ceiling").
	local function roomUnderMouse(): (string?, Model?)
		local hit = aimRay()
		local m = hit and hit.Instance.Parent
		local room = m and m:GetAttribute("Paint")
		if m and m:IsA("Model") and typeof(room) == "string" then
			return room, m
		end
		return nil, nil
	end

	-- Moves the ghost to the cell under the mouse and colours it.
	local function aim()
		local g, item = ghost, held and held.item
		local def = item and getDef(item)
		if not g or not held or not item or not def then
			return
		end
		local hit = aimRay()
		local w, d -- wall items: wall cells (1 stud, GridMath.WALL_CELL); everything else: 2-stud cells
		if def.wall then
			w, d = GridMath.wallSize(def)
		else
			w, d = GridMath.footprint(def.size, rot)
		end
		local place: GridMath.Item = { item = item, x = 0, z = 0, rot = if def.wall then 0 else rot }
		local area: CFrame? = nil
		if hit and def.wall then
			-- Wall items: the wall whose face the ray hit (on its plane, inside its bounds).
			for id, wall in GridMath.walls(state.rooms) do
				local cf = state.plot * wall.origin
				local p = cf:PointToObjectSpace(hit.Position)
				if math.abs(p.Z) < 0.75 and p.X >= 0 and p.Y >= 0 and p.X <= wall.size[1] * GridMath.WALL_CELL and p.Y <= wall.size[2] * GridMath.WALL_CELL then
					area = cf
					place.wall = id
					break
				end
			end
		elseif hit then
			-- A table top (a placed item with a surface) takes tabletop items; anything else = the room under it.
			local model = hit.Instance:FindFirstAncestorOfClass("Model")
			local uid = model and model:GetAttribute("Uid")
			local under = if typeof(uid) == "string" then state.items[uid] else nil
			local pdef = under and getDef(under.item)
			if typeof(uid) == "string" and pdef and pdef.surface and def.tabletop and not def.surface then
				local at = GridMath.cframe(state.items, state.rooms, getDef, uid)
				area = if at then state.plot * at * GridMath.surfaceOrigin(pdef.surface) else nil
				place.parent = uid
			else
				for name, room in state.rooms do
					local cf = state.plot * room.origin
					local p = cf:PointToObjectSpace(hit.Position)
					if p.X >= 0 and p.Z >= 0 and p.X <= room.size[1] * CELL and p.Z <= room.size[2] * CELL and math.abs(p.Y) < 4 then
						area = cf
						place.room = name
						break
					end
				end
			end
		end
		if not hit or not area then
			g.Parent = nil
			target = nil
			return
		end
		local goal: CFrame
		if place.wall then
			place.x, place.z = GridMath.snapWall(area:PointToObjectSpace(hit.Position), w, d)
			goal = area * GridMath.toWall(place.x, place.z, w, d)
		else
			place.x, place.z = GridMath.snap(area:PointToObjectSpace(hit.Position), w, d)
			goal = area * GridMath.toLocal(place.x, place.z, w, d, rot)
		end
		valid = GridMath.check(state.items, state.rooms, getDef, place, held.uid) == nil and (held.uid ~= nil or free(item) > 0)
		target = place
		-- Glide to the new cell instead of teleporting (snappy, but you see it move).
		if g.Parent then
			g:PivotTo(g:GetPivot():Lerp(goal, 0.45))
		else
			g:PivotTo(goal)
		end
		g.Parent = state.folder
		if highlight then
			highlight.FillColor = if valid then GOOD else BAD
			highlight.OutlineColor = highlight.FillColor
		end
	end

	-- Cards -------------------------------------------------------------------------------------------
	local function card(id: string, order: number)
		local def = getDef(id) :: any
		local holder = new("Frame", { Name = id, LayoutOrder = order }, grid)
		local scale = new("UIScale", { Scale = 0 }, holder)
		local outer, fill = sticker(holder, CARD, { Size = UDim2.fromScale(1, 1) }, Vector2.new(0.04, 0.035))
		local well = new("Frame", { BackgroundTransparency = 0, BackgroundColor3 = WELL, Position = UDim2.fromScale(0.05, 0.05), Size = UDim2.fromScale(0.9, 0.66), ZIndex = 3 }, fill)
		local model = preview(well, id)
		text(fill, string.upper(def.name), { Position = UDim2.fromScale(0.05, 0.74), Size = UDim2.fromScale(0.9, 0.12) })
		local setInfo = text(fill, "", { Position = UDim2.fromScale(0.05, 0.86), Size = UDim2.fromScale(0.9, 0.09), TextColor3 = DIM })
		local badge, badgeFill = sticker(holder, YELLOW, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.88, 0.08), Size = UDim2.fromScale(0.3, 0.2), Rotation = 8, ZIndex = 6 }, Vector2.new(0.08, 0.08))
		local badgeScale = new("UIScale", {}, badge)
		local setBadge = text(badgeFill, "", { Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1), TextColor3 = BLACK })
		local allPlaced = new("TextLabel", {
			Font = FONT, TextScaled = true, Text = "ALL PLACED", TextColor3 = WHITE, BackgroundTransparency = 0.35, BackgroundColor3 = BLACK,
			Size = UDim2.fromScale(0.9, 0.2), Position = UDim2.fromScale(0.05, 0.28), Rotation = -6, ZIndex = 7, Visible = false,
		}, fill)
		local button = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, holder)
		local shop = mode == "SHOP"
		local last = -1
		local function refresh()
			local owned = state.decor[id] or 0
			local left = math.max(free(id), 0)
			local count -- what the badge shows; it pops when this changes
			if shop then
				local afford = ((player:GetAttribute("Bux") or 0) :: number) >= (def.price or math.huge)
				fill.BackgroundColor3 = CARD
				setBadge(`{def.price}`)
				badgeFill.BackgroundColor3 = if afford then GOOD else DIM
				setInfo(if owned > 0 then `OWN {owned}` else "BUX", if owned > 0 then YELLOW else DIM)
				allPlaced.Text = "NEED BUX"
				allPlaced.Visible = not afford
				count = owned
			else
				local selected = held ~= nil and held.item == id and held.uid == nil
				fill.BackgroundColor3 = if selected then RED else CARD
				setBadge(`x{left}`)
				badgeFill.BackgroundColor3 = if left > 0 then YELLOW else DIM
				setInfo(`{owned - left}/{owned} PLACED`, DIM)
				allPlaced.Text = "ALL PLACED"
				allPlaced.Visible = left == 0
				count = left
			end
			if last ~= -1 and count ~= last then
				badgeScale.Scale = 1.5
				tween(badgeScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			end
			last = count
		end
		local function shake()
			play("error")
			tween(outer, 0.05, { Rotation = 5 })
			task.delay(0.05, function()
				tween(outer, 0.3, { Rotation = 0 }, Enum.EasingStyle.Elastic)
			end)
		end
		button.MouseEnter:Connect(function()
			hovered = id
			tween(scale, 0.15, { Scale = 1.06 }, Enum.EasingStyle.Back)
			tween(outer, 0.15, { Rotation = -2 })
			play("hover")
		end)
		button.MouseLeave:Connect(function()
			if hovered == id then
				hovered = nil
			end
			tween(scale, 0.15, { Scale = 1 })
			tween(outer, 0.15, { Rotation = 0 })
		end)
		button.Activated:Connect(function()
			if held and held.uid then
				store(held.uid) -- the whole panel takes a held placed item back
			elseif shop then
				if ((player:GetAttribute("Bux") or 0) :: number) >= (def.price or math.huge) then
					furnish:FireServer("Buy", id)
					scale.Scale = 0.9
					tween(scale, 0.3, { Scale = 1.06 }, Enum.EasingStyle.Back)
				else
					status(`NEED {def.price} BUX`, true)
					shake()
				end
			elseif free(id) > 0 then
				hold(id, nil)
				scale.Scale = 0.9
				tween(scale, 0.3, { Scale = 1.06 }, Enum.EasingStyle.Back)
			else
				status("ALL PLACED: X ONE IN THE ROOM TO STORE IT", true)
				shake()
			end
		end)
		cards[id] = { refresh = refresh, spin = model, holder = holder }
		refresh()
		-- Stagger in.
		task.delay(order * 0.035, function()
			tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
	end

	-- A WALLS swatch: kind "c" = colour (hex), "m" = material (Enum.Material name).
	local function paintCard(kind: string, value: string, order: number)
		local key = `{kind}:{value}`
		local holder = new("Frame", { Name = key, LayoutOrder = order }, grid)
		local scale = new("UIScale", { Scale = 0 }, holder)
		local outer, fill = sticker(holder, CARD, { Size = UDim2.fromScale(1, 1) }, Vector2.new(0.04, 0.035))
		local well = new("Frame", { BackgroundTransparency = 0, BackgroundColor3 = WELL, Position = UDim2.fromScale(0.05, 0.05), Size = UDim2.fromScale(0.9, 0.66), ZIndex = 3 }, fill)
		local name
		if kind == "c" then
			well.BackgroundColor3 = Color3.fromHex(value)
			name = `#{value}`
		else
			local vp = new("ViewportFrame", { Size = UDim2.fromScale(1, 1), Ambient = Color3.fromRGB(170, 165, 180), LightColor = WHITE, LightDirection = Vector3.new(-1, -2, -1), ZIndex = 3 }, well)
			new("Part", { Anchored = true, Size = Vector3.new(4, 4, 4), Material = (Enum.Material :: any)[value], Color = Color3.fromHex(D.APARTMENT.wallColors[1]) }, vp)
			local cam = new("Camera", { FieldOfView = 40, CFrame = CFrame.lookAt(Vector3.new(0, 0, -7.5), Vector3.zero) }, vp)
			vp.CurrentCamera = cam
			name = string.upper((string.gsub(value, "(%l)(%u)", "%1 %2")))
		end
		text(fill, name, { Position = UDim2.fromScale(0.05, 0.76), Size = UDim2.fromScale(0.9, 0.14), TextColor3 = if kind == "c" then DIM else WHITE })
		local button = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, holder)
		local function refresh()
			fill.BackgroundColor3 = if brush and brush.kind == kind and brush.value == value then RED else CARD
		end
		button.MouseEnter:Connect(function()
			tween(scale, 0.15, { Scale = 1.06 }, Enum.EasingStyle.Back)
			tween(outer, 0.15, { Rotation = -2 })
			play("hover")
		end)
		button.MouseLeave:Connect(function()
			tween(scale, 0.15, { Scale = 1 })
			tween(outer, 0.15, { Rotation = 0 })
		end)
		button.Activated:Connect(function()
			if held and held.uid then
				store(held.uid)
				return
			end
			drop()
			brush = { kind = kind, value = value }
			play("click")
			scale.Scale = 0.9
			tween(scale, 0.3, { Scale = 1.06 }, Enum.EasingStyle.Back)
			refreshCards()
			updateControls()
		end)
		cards[key] = { refresh = refresh, spin = nil, holder = holder }
		refresh()
		task.delay(order * 0.035, function()
			tween(scale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
	end

	-- Is `id` in the current tab? Bag: things you own. Shop: things with a price.
	local function listed(id: string): boolean
		local def = getDef(id)
		if not def then
			return false
		end
		return if mode == "SHOP" then typeof(def.price) == "number" else (state.decor[id] or 0) > 0
	end

	local function rebuildGrid()
		for _, c in cards do
			c.holder:Destroy()
		end
		cards = {}
		if mode == "WALLS" then
			local paints = if category == "MATERIAL" then D.APARTMENT.wallMaterials else D.APARTMENT.wallColors
			for i, v in paints do
				paintCard(if category == "MATERIAL" then "m" else "c", v, i)
			end
			local emptyHolder = emptyLabel.Parent :: Frame
			emptyHolder.Visible = false
			refreshCards()
			return
		end
		local ids = {}
		for _, id in Paths.furnitureIds() do
			local def = getDef(id)
			if def and listed(id) and (category == "ALL" or string.upper(def.category or "Furniture") == category) then
				table.insert(ids, id)
			end
		end
		table.sort(ids, function(a, b)
			return (getDef(a) :: any).name < (getDef(b) :: any).name
		end)
		for i, id in ids do
			card(id, i)
		end
		setEmpty(if mode == "SHOP" then "NOTHING FOR SALE HERE" else "YOUR BAG IS EMPTY. HIT THE SHOP!")
		local emptyHolder = emptyLabel.Parent :: Frame
		emptyHolder.Visible = #ids == 0
		refreshCards()
	end

	local rebuildTabs: () -> ()
	local function rebuildModes()
		for _, c in modes:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		for i, name in { "BAG", "SHOP", "WALLS" } do
			local on = name == mode
			local chip, chipFill = sticker(modes, if on then YELLOW else BLACK, { LayoutOrder = i, Size = UDim2.fromScale(0.3, 1), Rotation = if on then 3 else 0, ZIndex = 6 }, Vector2.new(0, 0))
			new("TextLabel", { Font = FONT, TextScaled = true, Text = name, TextColor3 = if on then BLACK else WHITE, Size = UDim2.fromScale(0.86, 0.72), Position = UDim2.fromScale(0.07, 0.14), ZIndex = 7 }, chipFill)
			local chipScale = new("UIScale", {}, chip)
			local b = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, chip)
			b.MouseEnter:Connect(function()
				tween(chipScale, 0.12, { Scale = 1.1 }, Enum.EasingStyle.Back)
			end)
			b.MouseLeave:Connect(function()
				tween(chipScale, 0.12, { Scale = 1 })
			end)
			b.Activated:Connect(function()
				if held and held.uid then
					store(held.uid) -- still the drop zone while holding a placed item
				elseif mode ~= name then
					mode, category = name, if name == "WALLS" then "COLOR" else "ALL"
					drop()
					play("click")
					rebuildModes()
					rebuildTabs()
					rebuildGrid()
				end
			end)
		end
	end

	function rebuildTabs()
		for _, c in tabs:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		local names, seen = { "ALL" }, { ALL = true }
		if mode == "WALLS" then
			names = { "COLOR", "MATERIAL" }
		end
		for _, id in if mode == "WALLS" then {} else Paths.furnitureIds() do
			local def = getDef(id)
			local cat = def and string.upper(def.category or "Furniture")
			if cat and listed(id) and not seen[cat] then
				seen[cat] = true
				table.insert(names, cat)
			end
		end
		table.sort(names, function(a, b)
			return a == "ALL" or (b ~= "ALL" and a < b)
		end)
		-- Tabs share the row evenly (a fixed 0.3 each ran the 4th off the panel).
		local pad = 0.025
		local w = (1 - pad * (#names - 1)) / #names
		for i, name in names do
			local on = name == category
			local tab, tabFill = sticker(tabs, if on then WHITE else BLACK, { LayoutOrder = i, Size = UDim2.fromScale(w, 1), Rotation = if on then -3 else 0 }, Vector2.new(0, 0))
			new("TextLabel", { Font = FONT, TextScaled = true, Text = name, TextColor3 = if on then BLACK else WHITE, Size = UDim2.fromScale(0.86, 0.7), Position = UDim2.fromScale(0.07, 0.15), ZIndex = 3 }, tabFill)
			local b = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, tab)
			b.Activated:Connect(function()
				if category ~= name then
					category = name
					play("click")
					rebuildTabs()
					rebuildGrid()
				end
			end)
		end
	end

	local rebuildStyles: () -> ()
	player:GetAttributeChangedSignal("AptStyles"):Connect(function()
		if rebuildStyles and styleStrip.Visible then
			rebuildStyles()
		end
	end)
	function rebuildStyles()
		for _, c in styleList:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		local i = 0
		for _, m in Paths.Assets:WaitForChild("Apartment"):GetChildren() do
			if m:IsA("Model") then
				i += 1
				local current = m.Name == state.style
				-- Paid styles (attribute Price, Bux) you don't own show their price; the first click asks, the
				-- second buys + moves you in (ApartmentService "Style"; user, 2026-11-01).
				local price = m:GetAttribute("Price")
				local ownedList = string.split(tostring(player:GetAttribute("AptStyles") or ""), ",")
				local forSale = typeof(price) == "number" and price > 0 and m.Name ~= D.APARTMENT.defaultStyle and not table.find(ownedList, m.Name)
				local chip, chipFill = sticker(styleList, if current then RED else CARD, { LayoutOrder = i, Size = UDim2.fromScale(0.23, 0.85), Rotation = if current then -3 else 0 })
				text(chipFill, string.upper(m.Name), { Size = UDim2.fromScale(0.9, if forSale then 0.5 else 0.75), Position = UDim2.fromScale(0.05, if forSale then 0.06 else 0.12) })
				local setPrice: ((string, Color3?) -> ())? = nil
				if forSale then
					setPrice = text(chipFill, `{price} BUX`, { Size = UDim2.fromScale(0.9, 0.36), Position = UDim2.fromScale(0.05, 0.58), TextColor3 = YELLOW })
				end
				local armed = 0
				local chipScale = new("UIScale", {}, chip)
				local b = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, chip)
				b.MouseEnter:Connect(function()
					tween(chipScale, 0.12, { Scale = 1.08 }, Enum.EasingStyle.Back)
				end)
				b.MouseLeave:Connect(function()
					tween(chipScale, 0.12, { Scale = 1 })
				end)
				b.Activated:Connect(function()
					if m.Name == state.style then
						return
					end
					if forSale and os.clock() - armed > 3 then
						armed = os.clock()
						play("click")
						if setPrice then
							setPrice("SURE? CLICK AGAIN")
						end
						task.delay(3, function()
							if setPrice and chip.Parent and os.clock() - armed >= 3 then
								setPrice(`{price} BUX`)
							end
						end)
						return
					end
					drop()
					play("click")
					apartment:FireServer("Style", m.Name)
				end)
			end
		end
	end

	-- Open / close ----------------------------------------------------------------------------------
	local openGen = 0
	local bopFrom = math.huge -- the banner bops on the beat from this os.clock() (not over its slam / exit tweens)
	-- `tell` = let the server know (build mode kicks visitors out and keeps them out until it's off).
	local function setBuilding(on: boolean, tell: boolean)
		if tell and on ~= building then
			apartment:FireServer("Build", on)
		end
		building = on
		openGen += 1
		local my = openGen
		setToggle(if on then "DONE" else "BUILD", if on then BLACK else WHITE)
		toggleFill.BackgroundColor3 = if on then WHITE else RED
		toggleScale.Scale = 1.2
		tween(toggleScale, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		if on then
			play("click")
			rebuildModes()
			rebuildTabs()
			rebuildGrid()
			rebuildStyles()
			updateControls()
			banner.Visible, panel.Visible, styleStrip.Visible = true, true, true
			-- Slam the banner, slide the panel + strip in.
			bannerScale.Scale = 1.6
			tween(bannerScale, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
			panel.Position = UDim2.fromScale(1.4, 0.45)
			tween(panel, 0.4, { Position = UDim2.fromScale(0.98, 0.45) }, Enum.EasingStyle.Back)
			styleStrip.Position = UDim2.fromScale(0.5, 1.2)
			tween(styleStrip, 0.4, { Position = UDim2.fromScale(0.5, 0.96) }, Enum.EasingStyle.Back)
			bopFrom = os.clock() + 0.36 -- after the slam
			Hud.setOut(true, "build") -- the HP / guard bars slide away like they do for the menu (the banner takes their spot)
		else
			bopFrom = math.huge
			drop()
			Hud.setOut(false, "build")
			hoverOutline.Enabled = false
			statusHolder.Visible = false
			tween(panel, 0.25, { Position = UDim2.fromScale(1.4, 0.45) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			tween(styleStrip, 0.25, { Position = UDim2.fromScale(0.5, 1.2) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			tween(bannerScale, 0.2, { Scale = 0 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(0.26, function()
				if openGen == my then
					banner.Visible, panel.Visible, styleStrip.Visible = false, false, false
				end
			end)
		end
	end

	toggleButton.Activated:Connect(function()
		setBuilding(not building, true)
	end)
	toggleButton.MouseEnter:Connect(function()
		tween(toggleScale, 0.12, { Scale = 1.08 }, Enum.EasingStyle.Back)
	end)
	toggleButton.MouseLeave:Connect(function()
		tween(toggleScale, 0.12, { Scale = 1 })
	end)

	Apartment.changed:Connect(function(uid: string?)
		local mine = state.owner == player.UserId
		gui.Enabled = mine
		if not mine then
			setBuilding(false, false) -- we left: the server already ended build mode
			return
		end
		if uid == nil then
			drop() -- a fresh load (or a style swap): the old ghost belonged to the old models
			if building then
				rebuildModes()
				rebuildTabs()
				rebuildGrid()
				rebuildStyles()
			end
		else
			refreshCards()
		end
	end)

	furnish.OnClientEvent:Connect(function(ok: boolean, message: string, action: string?)
		if not ok then
			status(message, true)
			play("error")
		elseif action == "Buy" then
			status(`BOUGHT {message}! IT'S IN YOUR BAG`, false)
			play("buy")
		elseif action == "BuyStyle" then
			status(`BOUGHT THE {message}! MOVING IN`, false)
			play("buy")
		end
	end)

	-- Bought something / redeemed a code: new cards in the bag, new counts in the shop.
	Apartment.ownedChanged:Connect(function()
		if not building then
			return
		end
		if mode == "SHOP" then
			refreshCards()
		else
			rebuildTabs()
			rebuildGrid()
		end
	end)
	player:GetAttributeChangedSignal("Bux"):Connect(function()
		if building and mode == "SHOP" then
			refreshCards()
		end
	end)

	-- Actions (keyboard / mouse and the touch buttons share these) --------------------------------------
	-- Place what's held where the ghost is; with nothing held, pick up the placed item we're pointing at.
	local function confirm()
		if brush then
			local room = roomUnderMouse()
			if room then
				apartment:FireServer("Paint", room, brush.kind, brush.value)
				play("place")
				status(`PAINTED {string.upper((string.gsub(room, "/", " ")))}`, false)
			else
				status(if touching() then "TAP A WALL OR CEILING FIRST" else "POINT AT A WALL OR CEILING", true)
				play("error")
			end
			return
		end
		if held and target and valid then
			local g = ghost
			if held.uid then
				furnish:FireServer("Move", held.uid, target)
				play("place")
				drop()
			else
				local item = held.item
				furnish:FireServer("Place", target)
				play("place")
				if free(item) <= 1 then -- that was the last free one (the Set hasn't arrived yet)
					drop()
				elseif g then
					-- A little squash on the ghost so the click lands.
					g:PivotTo(g:GetPivot() * CFrame.new(0, 0.6, 0))
				end
			end
		elseif held and target and not valid then
			status(if held.uid or free(held.item) > 0 then "CAN'T GO THERE" else "NONE LEFT", true)
			play("error")
		elseif held then
			status(if touching() then "TAP WHERE IT GOES FIRST" else "POINT AT A FLOOR, TABLE OR WALL", true)
			play("error")
		else
			local uid = placedUnderMouse()
			if uid then
				hold(state.items[uid].item, uid)
			end
		end
	end
	local function rotate()
		if held then
			rot = (rot + 1) % 4
			play("hover")
		end
	end
	-- Store the held placed item, or (nothing held) the one we're pointing at.
	local function storeAimed()
		local uid = if held then held.uid else placedUnderMouse()
		if uid then
			store(uid)
		end
	end
	local function cancel()
		if held or brush then
			drop()
		end
	end

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if not building or processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			confirm()
		elseif input.KeyCode == Enum.KeyCode.R then
			rotate()
		elseif input.KeyCode == Enum.KeyCode.X then
			storeAimed()
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 or input.KeyCode == Enum.KeyCode.Backspace then
			cancel()
		end
	end)

	-- Touch (user, 2026-10-31): tap the world to aim there (or, holding nothing, tap a placed item to pick it
	-- up); dragging still turns the camera. Big buttons on the left do the rest (the HUD bars are out anyway).
	UserInputService.TouchTapInWorld:Connect(function(at: Vector2, processedByUI: boolean)
		if not building or processedByUI then
			return
		end
		tapAt = at
		if not held and not brush then
			local uid = placedUnderMouse()
			if uid then
				hold(state.items[uid].item, uid)
			end
		end
	end)
	local touchPad = new("Frame", { Name = "TouchPad", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.02, 0.5), Size = UDim2.fromScale(0.14, 0.42), Visible = false }, gui)
	aspect(touchPad, 0.62)
	new("UIListLayout", { Padding = UDim.new(0.04, 0), VerticalAlignment = Enum.VerticalAlignment.Center, SortOrder = Enum.SortOrder.LayoutOrder }, touchPad)
	local touchButtons: { [string]: Frame } = {}
	for i, b in { { "PLACE", GOOD, confirm }, { "ROTATE", WHITE, rotate }, { "STORE", YELLOW, storeAimed }, { "CANCEL", BAD, cancel } } do
		local outer, fill = sticker(touchPad, b[2], { LayoutOrder = i, Size = UDim2.fromScale(1, 0.22), Rotation = if i % 2 == 0 then 2 else -2 })
		new("TextLabel", { Font = FONT, TextScaled = true, Text = b[1], TextColor3 = BLACK, Size = UDim2.fromScale(0.86, 0.7), Position = UDim2.fromScale(0.07, 0.15), ZIndex = 3 }, fill)
		local scale = new("UIScale", {}, outer)
		local button = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, outer)
		button.Activated:Connect(function()
			scale.Scale = 0.85
			tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
			b[3]()
		end)
		touchButtons[b[1]] = outer
	end
	-- Which buttons make sense right now (set every frame below).
	local function refreshTouch()
		local on = building and touching()
		touchPad.Visible = on
		if on then
			touchButtons.PLACE.Visible = held ~= nil or brush ~= nil
			touchButtons.ROTATE.Visible = held ~= nil and not (getDef(held.item) or {} :: any).wall
			touchButtons.STORE.Visible = held ~= nil and held.uid ~= nil
			touchButtons.CANCEL.Visible = held ~= nil or brush ~= nil
		end
	end

	RunService.RenderStepped:Connect(function(dt: number)
		refreshTouch()
		if not building then
			return
		end
		aim()
		-- Hovered placed item (nothing held): white outline. Not on touch: nothing hovers there.
		if not held and not touching() then
			-- With a brush, the room's whole wall layer lights up.
			local model: Model? = if brush then select(2, roomUnderMouse()) else select(2, placedUnderMouse())
			hoverOutline.Adornee = model
			hoverOutline.Parent = if model then workspace.CurrentCamera else nil
			hoverOutline.Enabled = model ~= nil
		end
		-- The hovered card's preview spins.
		local c = hovered and cards[hovered]
		if c and c.spin then
			c.spin:PivotTo(c.spin:GetPivot() * CFrame.Angles(0, dt * 1.8, 0))
		end
		-- The banner bops on the HUD beat.
		if os.clock() >= bopFrom then
			local beat = (os.clock() * D.HUD_BPM / 60) % 1
			bannerScale.Scale = 1 + 0.03 * (1 - beat) ^ 3
		end
	end)
end

return BuildController
