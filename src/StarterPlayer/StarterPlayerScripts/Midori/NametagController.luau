--!strict
-- Nametags for every player, drawn with Text+ (ReplicatedStorage.Lib["Text+"]).
--   Bottom row: the display name, white with a black outline and a soft drop shadow.
--   Top row (only with a title): the title with a per-letter gradient, icon on its left.
-- Titles come from the server through each player's "Title" attribute
-- (ServerScriptService.NametagService); looks come from Midori/Data/Titles.
--
-- Sizing: the nametag has a fixed size in the WORLD (like a sign above the head), so it
-- shrinks with distance together with the character instead of staying screen-sized.
-- Text+ lays text out from on-screen sizes, so the text is rendered once at a fixed
-- reference size (Left/Top aligned in an oversized frame, then fitted and centred by us)
-- and a UIScale shrinks/grows the finished nametag with distance. Text+ never re-renders.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Titles = Paths.data("Titles")
local TextPlus = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Text+") :: ModuleScript)

-- Reference layout, in pixels at UIScale 1.
local WIDTH = 280
local TITLE_ROW = 24
local ROW_GAP = 4
local NAME_ROW = 28
local HEIGHT = TITLE_ROW + ROW_GAP + NAME_ROW
local FONT = Font.fromEnum(Enum.Font.FredokaOne)
local NAME_SIZE = 22
local TITLE_SIZE = 18
-- Text+ outlines each letter separately, so a letter's outline paints over the one before it.
-- At the title's smaller size the full 2px stroke crushes the letters together; titles get a
-- thinner stroke and a little extra gap.
local TITLE_STROKE = 1.5 -- px (names use STYLE.StrokeSize)
local TITLE_SPACING = 1.12 -- Text+ CharacterSpacing: widens the gaps, not the letters
local ICON_SIZE = 18
local ICON_GAP = 5

-- World size of the whole nametag (keeps the reference aspect ratio).
local WORLD_WIDTH = 6 -- studs
local WORLD_HEIGHT = WORLD_WIDTH * HEIGHT / WIDTH
local HEIGHT_ABOVE_HEAD = 2.2 -- studs
local MAX_DISTANCE = 100 -- studs

local LAYOUT_WIDTH = 100000 -- render frame width: never wraps, whatever the scale
local RERENDER_PX = 3 -- re-render letters once the name's on-screen size changes this many px
local RERENDER_DELAY = 0.3 -- ...and has had this long to settle (one re-render per window)

-- Shared Text+ look for both rows.
local STYLE = {
	Font = FONT,
	StrokeSize = 2, -- px
	StrokeColor = Color3.new(0, 0, 0),
	ShadowOffset = Vector2.new(0, 2), -- px
	ShadowColor = Color3.new(0, 0, 0),
	ShadowTransparency = 0.6,
	XAlignment = "Left", -- positions never depend on the frame's on-screen size
	YAlignment = "Top",
	WordSorting = true, -- keeps Text+'s GetCharacters working for Roblox fonts
}

local NametagController = {}

local function withStyle(extra: { [string]: any }): { [string]: any }
	local options = table.clone(STYLE)
	for key, value in extra do
		options[key] = value
	end
	return options
end

-- Text+ needs the GUI laid out (on-screen size > 0); a far-away tag may wait a while.
local function waitForLayout(frame: GuiObject)
	while frame.Parent and frame.AbsoluteSize.X <= 0 do
		RunService.RenderStepped:Wait()
	end
end

local function render(frame: GuiObject, text: string, size: number, extra: { [string]: any }): Vector2
	local options = withStyle(extra)
	options.Size = size
	TextPlus.Create(frame, text, options)
	return TextPlus.GetBounds(frame)
end

-- Renders `text` into `frame`, then shrinks the frame to the text and centres it in its
-- row, nudged right by `shiftX`. Returns the text bounds.
local function renderCentred(frame: Frame, text: string, size: number, extra: { [string]: any }, shiftX: number): Vector2
	frame.AnchorPoint = Vector2.zero
	frame.Position = UDim2.new()
	frame.Size = UDim2.fromOffset(LAYOUT_WIDTH, 1000)
	waitForLayout(frame)
	local bounds = render(frame, text, size, extra)
	frame.Size = UDim2.fromOffset(bounds.X, bounds.Y)
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.new(0.5, shiftX, 0.5, 0)
	return bounds
end

-- Chat bubbles sit just above each player's own nametag (user, 2026-10-28: above the title, "make it
-- dynamic"): every character gets a tiny invisible BUBBLE_ANCHOR welded to its head at the top edge of what
-- its nametag shows (the title row, or the name row with no title), and bubble chat is adorned to it.
-- The default HumanoidRootPart adornee used the whole character's bounding box: tall hats / Dema's sword
-- threw bubbles way too high.
local BUBBLE_ANCHOR = "MidoriBubbleAnchor"
local BUBBLE_GAP = 0.3 -- studs between the nametag's top edge and the bubble

local function makeFrame(parent: Instance, name: string, size: UDim2, position: UDim2): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundTransparency = 1
	frame.Size = size
	frame.Position = position
	frame.Parent = parent
	return frame
end

-- The visible glyph of every letter, left to right. With a shadow, Text+'s
-- GetCharacters returns the shadow label and the real glyph is its child "Main";
-- colouring the shadow is why the gradient used to be invisible.
local function glyphsOf(frame: GuiObject): { GuiObject }
	local glyphs = {}
	for _, letter in TextPlus.GetCharacters(frame) do
		table.insert(glyphs, (letter:FindFirstChild("Main") or letter) :: GuiObject)
	end
	return glyphs
end

-- Gradient across the letters. `phase` (0..1) slides it for the colour shift: each letter
-- ping-pongs between `from` and `to`, offset along the word so the colours sweep across.
local function paintGradient(glyphs: { GuiObject }, from: Color3, to: Color3, phase: number)
	local count = #glyphs
	for i, glyph in glyphs do
		local along = if count > 1 then (i - 1) / (count - 1) else 0
		local t = (along - phase * 2) % 2 -- 0..2
		local color = from:Lerp(to, if t > 1 then 2 - t else t)
		if glyph:IsA("TextLabel") then
			glyph.TextColor3 = color
		elseif glyph:IsA("ImageLabel") then
			glyph.ImageColor3 = color
		end
	end
end

local function hasIcon(icon: string): boolean
	return icon ~= "" and icon ~= "rbxassetid://0"
end

local function build(player: Player, character: Model): () -> ()
	local head = character:WaitForChild("Head", 10)
	if not (head and head:IsA("BasePart")) then
		return function() end
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "MidoriNametag"
	gui.Size = UDim2.fromScale(WORLD_WIDTH, WORLD_HEIGHT) -- studs: scales with distance
	gui.StudsOffsetWorldSpace = Vector3.new(0, HEIGHT_ABOVE_HEAD, 0)
	gui.LightInfluence = 0
	gui.MaxDistance = MAX_DISTANCE
	gui.Adornee = head
	gui.Parent = head

	-- Everything is laid out at the reference size inside `content`; UIScale fits it to
	-- the billboard's current on-screen size.
	local content = makeFrame(gui, "Content", UDim2.fromOffset(WIDTH, HEIGHT), UDim2.fromScale(0.5, 0.5))
	content.AnchorPoint = Vector2.new(0.5, 0.5)
	local uiScale = Instance.new("UIScale")
	uiScale.Parent = content
	-- Text+ spaces letters for the on-screen pixel size it was drawn at (small glyphs are relatively
	-- wider), so re-render once the name's pixel size has moved by RERENDER_PX and stayed there briefly.
	local renderedPx = -1
	local rerenderQueued = false
	local renderName, renderTitle
	local function rescale()
		local width = gui.AbsoluteSize.X
		uiScale.Scale = if width > 0 then width / WIDTH else 1
		if renderedPx < 0 or rerenderQueued or math.abs(NAME_SIZE * uiScale.Scale - renderedPx) < RERENDER_PX then
			return
		end
		rerenderQueued = true
		task.delay(RERENDER_DELAY, function()
			rerenderQueued = false
			if gui.Parent then
				renderedPx = NAME_SIZE * uiScale.Scale
				task.spawn(renderName)
				task.spawn(renderTitle)
			end
		end)
	end

	local titleRow = makeFrame(content, "TitleRow", UDim2.new(1, 0, 0, TITLE_ROW), UDim2.new())
	local titleText = makeFrame(titleRow, "Text", UDim2.new(), UDim2.new())
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
	icon.AnchorPoint = Vector2.new(0, 0.5)
	icon.Parent = titleRow
	-- Placeholder drawn while a title has no real icon id: a small diamond in its colours.
	local diamond = Instance.new("Frame")
	diamond.Name = "PlaceholderIcon"
	diamond.Size = UDim2.fromOffset(ICON_SIZE * 0.62, ICON_SIZE * 0.62)
	diamond.AnchorPoint = Vector2.new(0.5, 0.5)
	diamond.Position = UDim2.fromScale(0.5, 0.5)
	diamond.Rotation = 45
	diamond.BorderSizePixel = 0
	diamond.BackgroundColor3 = Color3.new(1, 1, 1)
	diamond.Parent = icon
	local diamondGradient = Instance.new("UIGradient")
	diamondGradient.Parent = diamond
	local diamondStroke = Instance.new("UIStroke")
	diamondStroke.Thickness = 2
	diamondStroke.Color = Color3.new(0, 0, 0)
	diamondStroke.Parent = diamond

	-- Bubble anchor: local only, massless, never collides; moved by renderTitle.
	local anchor = Instance.new("Part")
	anchor.Name = BUBBLE_ANCHOR
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Transparency = 1
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Massless = true
	anchor.CFrame = head.CFrame
	local anchorWeld = Instance.new("Weld")
	anchorWeld.Part0 = head
	anchorWeld.Part1 = anchor
	anchorWeld.Parent = anchor
	anchor.Parent = character
	-- Top edge of the nametag's visible rows, above the head's centre (studs): the billboard is centred
	-- at HEIGHT_ABOVE_HEAD and WORLD_HEIGHT tall; without a title only the name row (its bottom part) shows.
	local function placeAnchor(hasTitle: boolean)
		local top = if hasTitle then WORLD_HEIGHT / 2 else WORLD_HEIGHT / 2 - (TITLE_ROW + ROW_GAP) / HEIGHT * WORLD_HEIGHT
		anchorWeld.C0 = CFrame.new(0, HEIGHT_ABOVE_HEAD + top, 0)
	end
	placeAnchor(false)

	local titleGlyphs: { GuiObject } = {}
	local currentTitle: any = nil
	local nameRow = makeFrame(content, "NameRow", UDim2.new(1, 0, 0, NAME_ROW), UDim2.fromOffset(0, TITLE_ROW + ROW_GAP))
	local nameText = makeFrame(nameRow, "Text", UDim2.new(), UDim2.new())

	function renderName()
		local nick = player:GetAttribute("Nick") -- ,nick (AdminService)
		renderCentred(nameText, if type(nick) == "string" and nick ~= "" then nick else player.DisplayName, NAME_SIZE, { Color = Color3.new(1, 1, 1) }, 0)
		renderedPx = NAME_SIZE * uiScale.Scale
	end

	function renderTitle()
		local id = player:GetAttribute("Title")
		-- Settings SHOW TITLE off (SetHideTitle): they keep the title (and its perks, e.g. freecam), it just isn't drawn.
		local title = if type(id) == "string" and player:GetAttribute("SetHideTitle") ~= true then Titles[id] else nil
		titleRow.Visible = title ~= nil
		placeAnchor(title ~= nil)
		currentTitle = title
		titleGlyphs = {}
		if not title then
			return
		end
		-- Icon goes to the RIGHT: nudge the text left by half the icon's footprint so
		-- text + icon centre together.
		local shift = -(ICON_SIZE + ICON_GAP) / 2
		local bounds = renderCentred(titleText, title.text, TITLE_SIZE, { Color = title.from, StrokeSize = TITLE_STROKE, CharacterSpacing = TITLE_SPACING }, shift)
		titleGlyphs = glyphsOf(titleText)
		paintGradient(titleGlyphs, title.from, title.to, 0)
		icon.Position = UDim2.new(0.5, shift + bounds.X / 2 + ICON_GAP, 0.5, 0)
		if hasIcon(title.icon) then
			icon.Image = title.icon
			diamond.Visible = false
		else
			icon.Image = ""
			diamond.Visible = true
			diamondGradient.Color = ColorSequence.new(title.from, title.to)
		end
	end

	-- Colour shift: slide the gradient across the letters every frame.
	local function animate()
		local title = currentTitle
		if not (title and title.shift and #titleGlyphs > 0) then
			return
		end
		local phase = (os.clock() * title.shiftSpeed) % 1
		paintGradient(titleGlyphs, title.from, title.to, phase)
		diamondGradient.Offset = Vector2.new(math.sin(phase * math.pi * 2) * 0.5, 0)
	end

	local conns = {
		gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale),
		RunService.RenderStepped:Connect(animate),
		player:GetAttributeChangedSignal("Title"):Connect(function()
			task.spawn(renderTitle)
		end),
		player:GetAttributeChangedSignal("SetHideTitle"):Connect(function()
			task.spawn(renderTitle)
		end),
		player:GetPropertyChangedSignal("DisplayName"):Connect(function()
			task.spawn(renderName)
		end),
		player:GetAttributeChangedSignal("Nick"):Connect(function()
			task.spawn(renderName)
		end),
	}
	rescale()
	task.spawn(renderName)
	task.spawn(renderTitle)

	return function()
		for _, c in conns do
			c:Disconnect()
		end
		gui:Destroy()
		anchor:Destroy()
	end
end

function NametagController.init()
	local cleanups: { [Player]: () -> () } = {}
	local bubbles = TextChatService:FindFirstChildOfClass("BubbleChatConfiguration")
	if bubbles then
		bubbles.AdorneeName = BUBBLE_ANCHOR
		bubbles.VerticalStudsOffset = BUBBLE_GAP
	end

	local function clear(player: Player)
		local cleanup = cleanups[player]
		cleanups[player] = nil
		if cleanup then
			cleanup()
		end
	end

	-- A fresh tag every time the head shows up (user, 2026-11-01: "names can get bugged and be invisible"):
	-- with StreamingEnabled someone far away (us in an apartment) can spawn without their head loaded here
	-- (build used to give up after 10 s), or their head streams out and back in, taking the tag with it or
	-- bringing it back blank. The head (re)entering the character rebuilds it.
	local function onCharacter(player: Player, character: Model)
		clear(player)
		local current: (() -> ())? = nil
		local function rebuild()
			if current then
				current()
				current = nil
			end
			if player.Character == character and character:FindFirstChild("Head") then
				current = build(player, character)
			end
		end
		local headConn = character.ChildAdded:Connect(function(child)
			if child.Name == "Head" then
				rebuild()
			end
		end)
		cleanups[player] = function()
			headConn:Disconnect()
			if current then
				current()
				current = nil
			end
		end
		rebuild()
	end

	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
		if player.Character then
			task.spawn(onCharacter, player, player.Character)
		end
	end

	Players.PlayerAdded:Connect(onPlayer)
	Players.PlayerRemoving:Connect(clear)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return NametagController
