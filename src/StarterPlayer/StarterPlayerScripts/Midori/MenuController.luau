--!strict
-- The P menu, Hi-Fi Rush / Persona like the HUD and side bar (user, 2026-10-17): a drawn jagged panel
-- (D.MENU_WINDOW), LuckiestGuy, red/dark sticker buttons with fat black outlines, world blurred behind.
-- Codes: type a code, REDEEM (server: CodeService).
-- Tabs: Appearance (your look: reroll ONE slot + free gender switch, which only swaps hair; server:
-- RerollService), Locker (slots that each keep one item you own: STORE / SWAP IN; RerollService), Styles
-- (your style + traits, trait locks), Servers (create / join private servers; PrivateServerService) and
-- Panel (Dev roles: set yourself; Managers / owner: anyone + roles + titles). A reroll cycles the pool slot-machine style until the server answers,
-- slows down and lands: the row flashes its rarity colour, Epic+ shakes the window, Legendary/Mythic
-- push a callout and Mythic flashes the screen red.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Appearance = Paths.data("Appearance")
local Net = Paths.shared("Net")
local Rarity = Paths.shared("Rarity")
local RarityText = Paths.client("RarityText")

local HEAD_FONT = Font.fromEnum(Enum.Font.LuckiestGuy)
local BOLD_FONT = Font.fromEnum(Enum.Font.GothamBold)
local BODY_FONT = Font.fromEnum(Enum.Font.GothamBold)
-- The page panel in design units (= midori_menu_window.png pixels). It's scaled to fit the screen
-- (up to MAX_FIT), centred, and only nudged right when the side bar would cover it.
local WINDOW = Vector2.new(860, 540)
local HEADER_H = 92 -- the red slash + page title; pages live below it
local EDGE = 22 -- content inset from the panel's jagged edge
local MAX_FIT = 1.35
local BLUR = 18 -- Lighting blur size while a page is open
-- Side menu (user, 2026-10-17): an arrow at the middle left slides in a full-height bar of menus
-- (~20% of a 16:9 screen) and slides the combat HUD out. Pages sit stacked in list order
-- on a reel; opening one rolls up from below the last page, switching rolls past the pages between.
-- Side bar art: menu_art.py rects (keep in sync), design size, list layout. The bar is scaled so
-- BAR_DESIGN.Y = the screen height (~20% of a 16:9 screen wide).
local MENU_ART = {
	bar = { x = 0, y = 0, w = 360, h = 1000 },
	selector = { x = 380, y = 0, w = 330, h = 92 },
	arrow = { x = 380, y = 110, w = 110, h = 150 },
	wallet = { x = 380, y = 280, w = 320, h = 120 },
}
local MENU_FONT = Font.fromEnum(Enum.Font.LuckiestGuy)
local BAR_DESIGN = Vector2.new(360, 1000)
local ITEMS_Y, ITEM_GAP = 280, 62 -- 9 items (owner) must end above the wallet at y 846
local ITEM_POSE = { { x = 40, rot = -4 }, { x = 62, rot = 3 }, { x = 32, rot = -2 }, { x = 56, rot = 4 }, { x = 44, rot = -3 } }
local ROLL_BASE, ROLL_PER_PAGE = 0.25, 0.12 -- reel roll time: base + per page passed
local ROW_H = 58
local ROW_GAP = 5
local TIMEOUT = 5 -- give up waiting for the server
local SPIN_MIN = 0.8 -- the strip cycles at least this long
local TICK_START, TICK_GROW, TICK_STOP = 0.05, 1.18, 0.22 -- strip interval, its growth per tick once answered, landing interval
local PREVIEW_SPIN = 0.6 -- rad/s
local SCREEN_MARGIN = 12 -- px the menu keeps clear of the screen (safe area) edges
local SHAKE_PX: { [string]: number } = { Epic = 3, Legendary = 5, Mythic = 10 }
local CALLOUT: { [string]: boolean } = { Legendary = true, Mythic = true }

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)
local DIM = Color3.fromRGB(165, 160, 180)
local BAR = Color3.fromRGB(10, 9, 14) -- wells: preview, thumbnails, inputs
local ROW = Color3.fromRGB(36, 33, 46)
local BUTTON = Color3.fromRGB(48, 44, 60)
local HOVER = Color3.fromRGB(72, 66, 88)
local ACCENT = Color3.fromRGB(225, 18, 40) -- the HUD / side bar red
local YELLOW = Color3.fromRGB(255, 220, 40)
local NAME_W = 290 -- Appearance row name width (list 540 - thumb/labels 70 - undo + reroll buttons 180)

local TABS = { "Appearance", "Locker", "Styles", "Emotes", "Servers", "Codes", "Catalog", "Settings", "Panel" }
-- Panel (user, 2026-10-22: Dev + Owner tabs merged): only for roles with "Dev" or "Manage" (RoleService).
local DEV_TABS = { Panel = true }

local player = Players.LocalPlayer
-- The owners (D.OWNER_IDS: UserIds, not a role; the server checks again): RIG NEXT CAN + GIVE rows, and
-- they always see the Panel tab.
local isOwner = table.find(D.OWNER_IDS, player.UserId) ~= nil or game:GetService("RunService"):IsStudio()
local OWNER_ROWS_H = 46 -- the owner row on top (VENDING); GIVE moved into the setter, on the target (2026-11-01)
local ownerRowsIn: (Instance, number) -> ()

local MenuController = {}

-- Rerolls cost nothing for everyone (D.FREE_SPINS) or for your role (Testers: server-set "FreeSpins").
local function freeSpins(): boolean
	return D.FREE_SPINS or player:GetAttribute("FreeSpins") == true
end

local function new(class: string, props: { [string]: any }, parent: Instance?): any
	local inst = Instance.new(class)
	for k, v in props do
		(inst :: any)[k] = v
	end
	inst.Parent = parent
	return inst
end

local function box(props: { [string]: any }, parent: Instance?): Frame
	props.BorderSizePixel = 0
	return new("Frame", props, parent)
end

local function text(props: { [string]: any }, parent: Instance?): TextLabel
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		TextColor3 = WHITE,
		FontFace = BODY_FONT,
		TextStrokeTransparency = 0.7,
	}, parent)
	for k, v in props do
		(l :: any)[k] = v
	end
	return l
end

local function stroke(parent: Instance, transparency: number, thickness: number?)
	new("UIStroke", { Color = WHITE, Transparency = transparency, Thickness = thickness or 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, parent)
end

local function tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

-- Hover lightens, press dips the scale, release bounces back.
local function pressable(b: GuiButton, base: Color3, hover: Color3)
	local scale = new("UIScale", {}, b)
	b.MouseEnter:Connect(function()
		tween(b, 0.1, { BackgroundColor3 = hover })
	end)
	b.MouseLeave:Connect(function()
		tween(b, 0.1, { BackgroundColor3 = base })
		tween(scale, 0.15, { Scale = 1 })
	end)
	b.MouseButton1Down:Connect(function()
		tween(scale, 0.06, { Scale = 0.92 })
	end)
	b.MouseButton1Up:Connect(function()
		tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
end

-- Sticker buttons: `primary` = red (REROLL), everything else dark; both with a fat black outline
-- (the gender switch turns it white for the selected one). Text shrinks to fit (TextSize = max).
local function button(label: string, size: UDim2, pos: UDim2, parent: Instance, primary: boolean?): TextButton
	local face = if primary then ACCENT else BUTTON
	local hover = if primary then ACCENT:Lerp(WHITE, 0.2) else HOVER
	local b = new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = face,
		BorderSizePixel = 0,
		Size = size,
		Position = pos,
		FontFace = HEAD_FONT,
		TextScaled = true,
		TextColor3 = WHITE,
		TextStrokeTransparency = 0,
		Text = label,
	}, parent)
	new("UITextSizeConstraint", { MaxTextSize = 22 }, b)
	new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingRight = UDim.new(0, 6), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 4) }, b)
	new("UIStroke", { Color = BLACK, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
	pressable(b, face, hover)
	return b
end

local function lookItem(slot: string, id: any): any?
	for _, item in Appearance.slots[slot].items do
		if item.id == id then
			return item
		end
	end
	return nil
end

-- What a style is called on screen: its `display` if it has one (e.g. "Ban Hammer"), else its id. Uppercase.
local function styleLabel(name: string): string
	local display = if Paths.findStyle(name) == name then Paths.style(name).display else nil
	return string.upper(if typeof(display) == "string" then display else name)
end

local function styleRarity(name: string): string
	return if Paths.findStyle(name) == name then Paths.style(name).rarity or "Common" else "Common"
end

local function stylePool(): { any }
	local pool = {}
	for _, name in Paths.styleIds() do
		if Paths.style(name).rollable == false then
			continue -- not in the reroll pool (mirrors RerollService.stylePool)
		end
		table.insert(pool, { id = name, rarity = styleRarity(name) })
	end
	return pool
end

function MenuController.init()
	local gui = new("ScreenGui", {
		Name = "MidoriMenu",
		ResetOnSpawn = false,
		Enabled = false,
		DisplayOrder = 20,
		ScreenInsets = Enum.ScreenInsets.DeviceSafeInsets, -- keeps the window off notches / rounded corners
	})

	-- Mythic screen flash, under the window (oversized so it also covers the safe-area insets).
	local screenFlash = box({ Position = UDim2.fromOffset(-200, -200), Size = UDim2.new(1, 400, 1, 400), BackgroundColor3 = Rarity.COLORS.Mythic, BackgroundTransparency = 1 }, gui)

	-- Two layers so they never fight: `fit` = where and how big the window is on this screen (fitScreen,
	-- any time), `holder` inside it = the open/close/shake motion (its UIScale is 1 at rest).
	local fit = box({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(WINDOW.X, WINDOW.Y), BackgroundTransparency = 1 }, gui)
	local fitScale = new("UIScale", {}, fit)
	local HOME = UDim2.fromScale(0.5, 0.5)
	local holder = box({ AnchorPoint = Vector2.new(0.5, 0.5), Position = HOME, Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, fit)
	local holderScale = new("UIScale", {}, holder)
	-- The drawn panel (jagged slab, white rim, red slash under the title, its own drop shadow).
	local window = new("ImageLabel", { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Image = D.MENU_WINDOW }, holder)

	-- Header: the page title on the red slash; who you are (headshot, display name, title) top right.
	local function outline(l: Instance, px: number)
		new("UIStroke", { Color = BLACK, Thickness = px, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, l)
	end
	local pageTitle = text({ Text = "", FontFace = HEAD_FONT, TextSize = 50, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(32, 6), Size = UDim2.fromOffset(420, 64), Rotation = -3 }, window)
	outline(pageTitle, 4)
	local titlePop = new("UIScale", {}, pageTitle)
	local headshot = new("ImageLabel", {
		Position = UDim2.fromOffset(WINDOW.X - 316, 20),
		Size = UDim2.fromOffset(52, 52),
		BackgroundColor3 = BAR,
		BorderSizePixel = 0,
		Rotation = 4,
		Image = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`,
	}, window)
	new("UIStroke", { Color = WHITE, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, headshot)
	local nameLabel = text({ Text = string.upper(player.DisplayName), FontFace = HEAD_FONT, TextSize = 26, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(WINDOW.X - 252, 20), Size = UDim2.fromOffset(186, 30) }, window)
	outline(nameLabel, 2)
	local titleLabel = text({ Text = "", FontFace = BOLD_FONT, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(WINDOW.X - 252, 50), Size = UDim2.fromOffset(186, 18) }, window)
	local Titles = Paths.data("Titles")
	local function refreshTitle()
		local t = Titles[player:GetAttribute("Title") :: any]
		titleLabel.Text = if t then string.upper(t.text) else `@{player.Name}`
		titleLabel.TextColor3 = if t then t.from else DIM
	end
	player:GetAttributeChangedSignal("Title"):Connect(refreshTitle)
	refreshTitle()
	-- Close: a red sticker on the top-right corner (big enough for a thumb).
	local close = button("X", UDim2.fromOffset(58, 58), UDim2.fromOffset(WINDOW.X - 58, -6), window, true)
	close.Rotation = 6
	close.Modal = true -- frees the mouse while the menu is up
	-- Status toast: yellow, sitting on the panel's bottom edge.
	local status = text({ Text = "", FontFace = HEAD_FONT, TextSize = 26, TextColor3 = YELLOW, TextStrokeTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(WINDOW.X / 2, WINDOW.Y - 4), Size = UDim2.fromOffset(WINDOW.X - 80, 32), ZIndex = 6 }, window)
	outline(status, 3)

	local statusToken = 0
	local function setStatus(msg: string)
		statusToken += 1
		local token = statusToken
		status.Text = msg
		task.delay(2.5, function()
			if statusToken == token then
				status.Text = ""
			end
		end)
	end

	-- Side bar (its own ScreenGui, always on), Hi-Fi Rush / Persona like the combat HUD (user, 2026-10-17):
	-- drawn sticker art (menu_art.py -> D.MENU_ART), LuckiestGuy, tilted items, a red slab that slides
	-- behind the picked one and bops on the HUD beat. Laid out in design units (BAR_DESIGN) and scaled
	-- to the screen height. Closed = AnchorPoint X 1 (parked off the left edge, only the arrow pokes out).
	local side = new("ScreenGui", { Name = "MidoriSide", ResetOnSpawn = false, DisplayOrder = 21, IgnoreGuiInset = true })
	local sideBar = box({ AnchorPoint = Vector2.new(1, 0), Size = UDim2.fromOffset(BAR_DESIGN.X, BAR_DESIGN.Y), BackgroundTransparency = 1 }, side)
	local barScale = new("UIScale", {}, sideBar)
	local function art(name: string, props: { [string]: any }, parent: Instance, class: string?): any
		local r = MENU_ART[name]
		props.Image = D.MENU_ART
		props.ImageRectOffset = Vector2.new(r.x, r.y)
		props.ImageRectSize = Vector2.new(r.w, r.h)
		props.BackgroundTransparency = 1
		props.BorderSizePixel = 0
		return new(class or "ImageLabel", props, parent)
	end
	local function loud(class: string, props: { [string]: any }, parent: Instance, strokePx: number?): (any, UIStroke)
		props.FontFace = MENU_FONT
		props.BackgroundTransparency = 1
		props.TextStrokeTransparency = 1
		local l = new(class, props, parent)
		local s = new("UIStroke", { Color = BLACK, Thickness = strokePx or 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, l)
		return l, s
	end
	art("bar", { Size = UDim2.fromScale(1, 1) }, sideBar)
	loud("TextLabel", { Text = "MENU", TextSize = 88, TextColor3 = WHITE, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(26, 112), Size = UDim2.fromOffset(260, 96), Rotation = -9 }, sideBar, 5)
	-- Chevron on the jagged edge: points right while closed, flips when open.
	local arrow = art("arrow", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromOffset(BAR_DESIGN.X + 22, BAR_DESIGN.Y / 2), Size = UDim2.fromOffset(MENU_ART.arrow.w * 0.6, MENU_ART.arrow.h * 0.6), AutoButtonColor = false }, sideBar, "ImageButton") :: ImageButton
	local arrowScale = new("UIScale", {}, arrow)
	arrow.MouseEnter:Connect(function()
		tween(arrowScale, 0.12, { Scale = 1.15 }, Enum.EasingStyle.Back)
	end)
	arrow.MouseLeave:Connect(function()
		tween(arrowScale, 0.12, { Scale = 1 })
	end)

	-- Tabs: the menu list. Each item has its own stagger + tilt (ITEM_POSE); hidden ones close the gap.
	local tabCol = box({ Position = UDim2.fromOffset(0, ITEMS_Y), Size = UDim2.fromOffset(BAR_DESIGN.X, #TABS * ITEM_GAP), BackgroundTransparency = 1 }, sideBar)
	local selector = art("selector", { AnchorPoint = Vector2.new(0, 0.5), Size = UDim2.fromOffset(MENU_ART.selector.w, MENU_ART.selector.h), Position = UDim2.fromOffset(-20, ITEM_GAP / 2) }, tabCol)
	local selectorScale = new("UIScale", {}, selector)
	local content = box({ Position = UDim2.fromOffset(EDGE, HEADER_H), Size = UDim2.new(1, -2 * EDGE, 1, -HEADER_H - EDGE), BackgroundTransparency = 1, ClipsDescendants = true }, window)
	-- The reel: visible pages stacked top to bottom in list order, one page-height apart.
	local reel = box({ Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, content)
	local pages: { [string]: Frame } = {}
	local tabButtons: { [string]: TextButton } = {}
	local tabStrokes: { [string]: UIStroke } = {}
	local tabScales: { [string]: UIScale } = {}
	local current = TABS[1]

	local function listed(): { string }
		local list = {}
		for _, tab in TABS do
			if tabButtons[tab].Visible then
				table.insert(list, tab)
			end
		end
		return list
	end

	local function pose(i: number): (number, number, number)
		local p = ITEM_POSE[(i - 1) % #ITEM_POSE + 1]
		return p.x, (i - 0.5) * ITEM_GAP, p.rot
	end

	-- Shows `name`, rolling the reel from page `from` (an index into listed(); defaults to the current
	-- page, #list + 1 = the empty slot under the last page) past every page in between.
	local rollToken = 0
	local function select(name: string, from: number?)
		local list = listed()
		local to = table.find(list, name) or 1
		local start = from or table.find(list, current) or to
		current = name
		if pageTitle.Text ~= string.upper(name) then
			pageTitle.Text = string.upper(name)
			titlePop.Scale = 1.2
			tween(titlePop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end
		for _, tab in TABS do
			local on = tab == name
			local at = table.find(list, tab)
			local x, y, rot = pose(at or 1)
			local b = tabButtons[tab]
			b.Position = UDim2.fromOffset(x, y)
			b.Rotation = rot
			-- picked = black text with a white outline on the red slab (Persona inverted)
			tween(b, 0.12, { TextColor3 = if on then BLACK else WHITE })
			tabStrokes[tab].Color = if on then WHITE else BLACK
			tween(tabScales[tab], 0.25, { Scale = if on then 1.12 else 1 }, Enum.EasingStyle.Back)
			if on then
				tween(selector, 0.28, { Position = UDim2.fromOffset(x - 46, y), Rotation = rot }, Enum.EasingStyle.Back)
			end
			pages[tab].Visible = at ~= nil
			pages[tab].Position = UDim2.fromScale(0, (at or 1) - 1)
		end
		rollToken += 1
		local token = rollToken
		reel.Position = UDim2.fromScale(0, -(start - 1))
		local passed = math.abs(to - start)
		tween(reel, if passed == 0 then 0.01 else ROLL_BASE + ROLL_PER_PAGE * passed, { Position = UDim2.fromScale(0, -(to - 1)) }, Enum.EasingStyle.Back).Completed:Connect(function()
			if token == rollToken then
				for _, tab in TABS do
					pages[tab].Visible = tab == current -- only the landed page stays live
				end
			end
		end)
	end

	local openTab: (string) -> () -- set with the open/close logic below
	for i, tab in TABS do
		local x, y, rot = pose(i)
		local b, s = loud("TextButton", {
			AutoButtonColor = false,
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromOffset(x, y),
			Size = UDim2.fromOffset(270, ITEM_GAP - 10),
			Rotation = rot,
			TextSize = 40,
			TextColor3 = WHITE,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = string.upper(tab),
			ZIndex = 2,
		}, tabCol)
		local scale = new("UIScale", {}, b)
		b.MouseEnter:Connect(function()
			if current ~= tab then
				tween(scale, 0.12, { Scale = 1.06 }, Enum.EasingStyle.Back)
			end
		end)
		b.MouseLeave:Connect(function()
			if current ~= tab then
				tween(scale, 0.12, { Scale = 1 })
			end
		end)
		b.Activated:Connect(function()
			openTab(tab)
		end)
		tabButtons[tab] = b :: any
		tabStrokes[tab] = s
		tabScales[tab] = scale
		pages[tab] = box({ Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, reel)
	end
	local function refreshDev()
		local dev = player:GetAttribute("Dev") == true or player:GetAttribute("Manage") == true or isOwner
		for tab in DEV_TABS do
			tabButtons[tab].Visible = dev
		end
		-- re-select so the list closes up around hidden items
		select(if DEV_TABS[current] and not dev then TABS[1] else current)
	end
	player:GetAttributeChangedSignal("Dev"):Connect(refreshDev)
	player:GetAttributeChangedSignal("Manage"):Connect(refreshDev)

	-- Landing effects
	local function shake(px: number)
		local t0 = os.clock()
		local conn: RBXScriptConnection
		conn = RunService.RenderStepped:Connect(function()
			local k = 1 - (os.clock() - t0) / 0.35
			if k <= 0 then
				conn:Disconnect()
				holder.Position = HOME
				return
			end
			holder.Position = HOME + UDim2.fromOffset((math.random() * 2 - 1) * px * k, (math.random() * 2 - 1) * px * k)
		end)
	end

	-- `quiet` = only the row's own flash + pop (a multi roll shakes / calls out once, for its best row).
	local function land(rarity: string, flash: Frame, pop: UIScale, quiet: boolean?)
		local color = Rarity.color(rarity)
		flash.BackgroundColor3 = color
		flash.BackgroundTransparency = 0.35
		tween(flash, 0.5, { BackgroundTransparency = 1 })
		pop.Scale = 1.35
		tween(pop, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		if quiet then
			return
		end
		if SHAKE_PX[rarity] then
			shake(SHAKE_PX[rarity])
		end
		if CALLOUT[rarity] then
			Paths.client("CalloutController").push("Roll" .. rarity, string.upper(rarity), color)
		end
		if rarity == "Mythic" then
			screenFlash.BackgroundTransparency = 0.45
			tween(screenFlash, 0.9, { BackgroundTransparency = 1 })
		end
	end

	-- Reroll: ask the server and cycle `show` through `pool` until it answers, then slow down.
	-- Returns started (false = refused locally) and the result id (nil = server said no / timeout).
	-- Several rolls can spin at once (user, 2026-10-17: press REROLL on one row, then another):
	-- each is keyed "tab|key" and waits for its own answer.
	local rolling: { [string]: true } = {}
	local function busy(): boolean
		return next(rolling) ~= nil
	end
	local autoTarget: string? = nil -- AUTO selector: nil = normal single rerolls
	local answers: { [string]: (any, any) -> () } = {}
	local devAnswer: ((string, any) -> ())? = nil -- set by the Dev page
	local undone: { [string]: () -> () } = {} -- key -> feedback when an undo/redo lands
	local refreshPreview: () -> () = function() end -- the Appearance page's rebuildPreview, set once it exists
	Net.get(Net.Names.RerollResult).OnClientEvent:Connect(function(tab, slot, id, rolls)
		if tab == "Undo" then
			if id == nil then
				setStatus("CAN'T UNDO RIGHT NOW")
			elseif typeof(slot) == "string" and undone[slot] then
				undone[slot]()
			end
		elseif tab == "Gender" or tab == "Lock" or tab == "Locker" then
			if id == nil then
				setStatus(if tab == "Locker" and slot == "Store" then "NOTHING TO STORE, OR NO EMPTY SLOT"
					elseif tab == "Locker" and slot == "BuySlot" then "NOT ENOUGH BUX"
					else "CAN'T CHANGE RIGHT NOW")
			elseif tab == "Locker" and slot == "BuySlot" then
				setStatus("+1 LOCKER SLOT")
			elseif tab == "Locker" and slot == "Trash" then
				setStatus("TRASHED")
			elseif tab == "Locker" then
				task.delay(0.4, function()
					if gui.Enabled then
						refreshPreview()
					end
				end)
			end
		elseif tab == "Dev" then
			if devAnswer then
				devAnswer(slot, id)
			end
		else
			local reply = answers[`{tab}|{slot}`]
			if reply then
				reply(id, rolls)
			end
		end
	end)

	local function roll(tab: string, slot: string?, pool: { any }, show: (any) -> ()): (boolean, any)
		local key = `{tab}|{slot}`
		if rolling[key] then
			return false, nil
		end
		local spins = player:GetAttribute("Spins")
		local character = player.Character
		if not freeSpins() and (typeof(spins) ~= "number" or spins < 1) then
			setStatus("NO REROLLS LEFT")
			return false, nil
		elseif character and character:GetAttribute("CombatMode") then
			setStatus("LEAVE COMBAT MODE FIRST")
			return false, nil
		end
		rolling[key] = true
		local done, result, rolls = false, nil, nil
		answers[key] = function(id, n)
			done, result, rolls = true, id, n
		end
		local target = autoTarget
		Net.get(Net.Names.Reroll):FireServer(tab, slot, target)
		local started = os.clock()
		local tick = TICK_START
		local last = nil
		while true do
			if done and os.clock() - started >= SPIN_MIN then
				if result == nil then
					break
				end
				tick *= TICK_GROW
				if tick >= TICK_STOP then
					break
				end
			elseif not done and os.clock() - started > TIMEOUT then
				break
			end
			local item = pool[math.random(#pool)]
			if item == last and #pool > 1 then
				item = pool[math.random(#pool)]
			end
			last = item
			show(item.id)
			task.wait(tick)
		end
		answers[key] = nil
		rolling[key] = nil
		if result == nil then
			setStatus(if target then `CAN'T AUTO ROLL FOR {string.upper(target)} HERE` else "CAN'T REROLL RIGHT NOW")
		elseif target and typeof(rolls) == "number" then
			setStatus(`AUTO ROLLED {rolls}x`)
		end
		return true, result
	end

	-- AUTO selector (one shared target for every reroll button): click cycles OFF -> Rare -> ... -> Mythic.
	local AUTO_TARGETS = { "Rare", "Epic", "Legendary", "Mythic" }
	local autoButtons: { TextButton } = {}
	local function refreshAuto()
		for _, b in autoButtons do
			b.Text = if autoTarget then `AUTO: {string.upper(autoTarget)}+` else "AUTO: OFF"
			b.TextColor3 = if autoTarget then Rarity.color(autoTarget) else DIM
		end
	end
	local function autoButton(size: UDim2, pos: UDim2, parent: Instance): TextButton
		local b = button("", size, pos, parent)
		table.insert(autoButtons, b)
		b.Activated:Connect(function()
			if busy() then
				return
			end
			local i = if autoTarget then table.find(AUTO_TARGETS, autoTarget) else 0
			autoTarget = AUTO_TARGETS[(i :: number) + 1] -- past Mythic wraps to nil (OFF)
			refreshAuto()
		end)
		refreshAuto()
		return b
	end

	-- UNDO/REDO for one reroll key (an appearance slot or "Style"). Only shown while the server says
	-- there's something to swap back ("Undo_<key>" = "UNDO"/"REDO"). `onDone` = feedback when it lands.
	local function undoButton(key: string, size: UDim2, pos: UDim2, parent: Instance, onDone: () -> ()): TextButton
		local b = button("UNDO", size, pos, parent)
		b.TextSize = 12
		local attr = "Undo_" .. key
		local function refresh()
			local v = player:GetAttribute(attr)
			b.Visible = typeof(v) == "string"
			if typeof(v) == "string" then
				b.Text = v
			end
		end
		player:GetAttributeChangedSignal(attr):Connect(refresh)
		refresh()
		b.Activated:Connect(function()
			local character = player.Character
			if busy() then
				return
			elseif character and character:GetAttribute("CombatMode") then
				setStatus("LEAVE COMBAT MODE FIRST")
				return
			end
			Net.get(Net.Names.Undo):FireServer(key)
		end)
		undone[key] = onDone
		return b
	end

	-- Appearance page
	local appearance = pages.Appearance
	local preview = new("ViewportFrame", {
		Size = UDim2.new(0, 240, 1, -56), -- the gender switch sits under it
		BackgroundColor3 = BAR,
		BorderSizePixel = 0,
		Ambient = Color3.fromRGB(170, 170, 170),
		LightDirection = Vector3.new(-1, -1, 1),
	}, appearance)
	stroke(preview, 0.85)
	local world = new("WorldModel", {}, preview)
	local cam = new("Camera", { FieldOfView = 40, CFrame = CFrame.lookAt(Vector3.new(0, 0.3, -12), Vector3.new(0, -0.3, 0)) }, preview)
	preview.CurrentCamera = cam

	local previewModel: Model? = nil
	local angle = math.pi
	local function rebuildPreview()
		if previewModel then
			previewModel:Destroy()
			previewModel = nil
		end
		local character = player.Character
		if not character then
			return
		end
		local was = character.Archivable
		character.Archivable = true
		local clone = character:Clone()
		character.Archivable = was
		if not clone then
			return
		end
		for _, d in clone:GetDescendants() do
			if d:IsA("BaseScript") or d:IsA("BillboardGui") or d:IsA("Sound") or d:IsA("ParticleEmitter") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.Anchored = true
			end
		end
		local hum = clone:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
		clone:PivotTo(CFrame.Angles(0, angle, 0))
		clone.Parent = world
		previewModel = clone
	end

	refreshPreview = rebuildPreview

	type Row = { row: Frame, name: TextLabel, fancy: Frame, thumb: ImageLabel, flash: Frame, pop: UIScale }
	local rows: { [string]: Row } = {}
	local spinning: { [string]: boolean } = {}

	-- Gender switch (free). Selected = bright stroke + white text.
	local genderButtons: { [string]: TextButton } = {}
	local function gender(): string?
		local g = player:GetAttribute("Gender")
		return if typeof(g) == "string" then g else nil
	end
	local function refreshGender()
		for g, b in genderButtons do
			local on = g == gender()
			tween(b, 0.15, { TextColor3 = if on then WHITE else DIM })
			tween(b:FindFirstChildOfClass("UIStroke") :: UIStroke, 0.15, { Color = if on then WHITE else BLACK })
		end
		task.delay(0.5, function()
			if gui.Enabled then
				rebuildPreview()
			end
		end)
	end
	for i, g in D.GENDERS do
		local b = button(string.upper(g), UDim2.fromOffset(116, 46), UDim2.new(0, (i - 1) * 124, 1, -46), appearance)
		genderButtons[g] = b
		b.Activated:Connect(function()
			local character = player.Character
			if g == gender() or busy() then
				return
			elseif character and character:GetAttribute("CombatMode") then
				setStatus("LEAVE COMBAT MODE FIRST")
				return
			end
			Net.get(Net.Names.SetGender):FireServer(g)
		end)
	end
	player:GetAttributeChangedSignal("Gender"):Connect(refreshGender)
	refreshGender()

	-- `fancy` = draw the name with its rarity's Text+ effect; the slot-machine strip uses the plain
	-- label instead (re-rendering Text+ every tick would be wasteful).
	local function showItem(slot: string, id: any, fancy: boolean)
		local r = rows[slot]
		local item = lookItem(slot, id)
		local rarity = item and item.rarity
		local label = if item then item.name
			elseif id == nil then "..."
			elseif id == 0 then Appearance.slots[slot].noneName or "None"
			else `Custom #{id}`
		r.row.BackgroundColor3 = Rarity.tint(rarity, ROW)
		r.name.Visible = not fancy
		if fancy then
			RarityText.render(r.fancy, label, rarity, 22, NAME_W)
		else
			RarityText.clear(r.fancy)
			r.name.Text = label
			r.name.TextColor3 = Rarity.color(rarity)
		end
		if slot == "SkinTone" then
			r.thumb.Image = ""
			r.thumb.BackgroundColor3 = if typeof(id) == "string" then BrickColor.new(id).Color else BAR
		else
			r.thumb.BackgroundColor3 = BAR
			local thumbId = if item and item.thumb then item.thumb else id
			r.thumb.Image = if typeof(thumbId) == "number" and thumbId ~= 0 then `rbxthumb://type=Asset&id={thumbId}&w=150&h=150` else ""
		end
	end

	local list = box({ Position = UDim2.fromOffset(256, 0), Size = UDim2.new(1, -256, 1, 0), BackgroundTransparency = 1 }, appearance)
	-- Only rerollable slots get a row.
	local rowSlots = {}
	for _, slot in Appearance.order do
		if Appearance.slots[slot].rerollable ~= false then
			table.insert(rowSlots, slot)
		end
	end
	-- What a slot's strip cycles through while it rolls ("nothing" spins past too).
	local function stripFor(slot: string): { any }
		local strip = Appearance.eligible(slot, gender())
		if Appearance.slots[slot].none then
			table.insert(strip, { id = 0 })
		end
		return strip
	end
	local picked: { [string]: true? } = {} -- rows selected for ROLL SELECTED
	local rollPicked: TextButton -- made under the rows
	local function refreshPicked()
		local n = 0
		for _ in picked do
			n += 1
		end
		rollPicked.Text = if n > 0 then `ROLL SELECTED ({n})` else "ROLL SELECTED"
	end
	for i, slot in rowSlots do
		local row = box({ Position = UDim2.fromOffset(0, (i - 1) * (ROW_H + ROW_GAP)), Size = UDim2.new(1, 0, 0, ROW_H), BackgroundColor3 = ROW }, list)
		stroke(row, 0.9)
		local thumb = new("ImageLabel", { Position = UDim2.fromOffset(10, 5), Size = UDim2.fromOffset(48, 48), BackgroundColor3 = BAR, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Fit }, row)
		stroke(thumb, 0.85)
		local pop = new("UIScale", {}, thumb)
		text({ Text = string.upper(Appearance.slots[slot].label), TextSize = 17, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(70, 4), Size = UDim2.new(1, -190, 0, 18) }, row)
		local name = text({ Text = "", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(70, 24), Size = UDim2.new(0, NAME_W, 0, 26) }, row)
		local fancy = box({ Position = UDim2.fromOffset(70, 24), Size = UDim2.new(0, NAME_W, 0, 26), BackgroundTransparency = 1 }, row)
		local flash = box({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 3 }, row)
		local reroll = button("REROLL", UDim2.fromOffset(100, 42), UDim2.new(1, -108, 0.5, -21), row, true)
		undoButton(slot, UDim2.fromOffset(66, 42), UDim2.new(1, -182, 0.5, -21), row, function()
			pop.Scale = 1.25
			tween(pop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			task.delay(0.4, function()
				if gui.Enabled then
					rebuildPreview()
				end
			end)
		end)
		rows[slot] = { row = row, name = name, fancy = fancy, thumb = thumb, flash = flash, pop = pop }

		local attr = "Look_" .. slot
		player:GetAttributeChangedSignal(attr):Connect(function()
			if not spinning[slot] then
				showItem(slot, player:GetAttribute(attr), true)
			end
		end)
		showItem(slot, player:GetAttribute(attr), true)

		-- Multi roll pick: click the picture / slot name to (un)select the row for ROLL SELECTED.
		local pickButton = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundTransparency = 1, Size = UDim2.new(0, 70, 1, 0), ZIndex = 4 }, row)
		local check = text({ Text = "✓", FontFace = HEAD_FONT, TextSize = 16, BackgroundTransparency = 0, BackgroundColor3 = ACCENT, Position = UDim2.fromOffset(2, 2), Size = UDim2.fromOffset(20, 20), Visible = false, ZIndex = 5 }, row)
		local rowStroke = row:FindFirstChildOfClass("UIStroke") :: UIStroke
		pickButton.Activated:Connect(function()
			if busy() then
				return
			end
			picked[slot] = not picked[slot] or nil
			check.Visible = picked[slot] == true
			rowStroke.Color = if picked[slot] then ACCENT else WHITE
			rowStroke.Transparency = if picked[slot] then 0 else 0.9
			refreshPicked()
		end)

		reroll.Activated:Connect(function()
			spinning[slot] = true
			local strip = stripFor(slot)
			local started, result = roll("Appearance", slot, strip, function(id)
				showItem(slot, id, false)
			end)
			spinning[slot] = nil
			if not started then
				return
			end
			showItem(slot, if result ~= nil then result else player:GetAttribute(attr), true)
			if result ~= nil then
				local item = lookItem(slot, result)
				land(item and item.rarity or "Common", flash, pop)
				task.delay(0.4, function()
					if gui.Enabled then
						rebuildPreview()
					end
				end)
			end
		end)
	end

	local bottomY = #rowSlots * (ROW_H + ROW_GAP) + 4
	autoButton(UDim2.new(0.5, -4, 0, 42), UDim2.fromOffset(0, bottomY), list)
	rollPicked = button("ROLL SELECTED", UDim2.new(0.5, -4, 0, 42), UDim2.new(0.5, 4, 0, bottomY), list, true)
	refreshPicked()

	-- Multi roll (user, 2026-10-17): every picked row in ONE server request (RerollMany, all-or-nothing,
	-- costs a reroll per row, or per roll with AUTO). All strips spin together and land together; the
	-- best rarity gets the shake / callout once.
	rollPicked.Activated:Connect(function()
		if busy() then
			return
		end
		local slots = {}
		for _, slot in rowSlots do
			if picked[slot] then
				table.insert(slots, slot)
			end
		end
		local spins = player:GetAttribute("Spins")
		local character = player.Character
		if #slots == 0 then
			setStatus("CLICK A PICTURE TO PICK ROWS")
			return
		elseif not freeSpins() and (typeof(spins) ~= "number" or spins < #slots) then
			setStatus(`NEED {#slots} REROLLS`)
			return
		elseif character and character:GetAttribute("CombatMode") then
			setStatus("LEAVE COMBAT MODE FIRST")
			return
		end
		for _, slot in slots do
			if rolling[`Appearance|{slot}`] then
				setStatus("WAIT FOR THAT ROLL TO LAND")
				return
			end
		end
		rolling["Many|nil"] = true
		local strips = {}
		for _, slot in slots do
			rolling[`Appearance|{slot}`] = true -- no single reroll on these rows meanwhile
			spinning[slot] = true
			strips[slot] = stripFor(slot)
		end
		local done, results, rolls = false, nil, nil
		answers["Many|nil"] = function(r, n)
			done, results, rolls = true, r, n
		end
		local target = autoTarget
		Net.get(Net.Names.RerollMany):FireServer(slots, target)
		local started, tick = os.clock(), TICK_START
		while true do
			if done and os.clock() - started >= SPIN_MIN then
				if typeof(results) ~= "table" then
					break
				end
				tick *= TICK_GROW
				if tick >= TICK_STOP then
					break
				end
			elseif not done and os.clock() - started > TIMEOUT then
				break
			end
			for _, slot in slots do
				local strip = strips[slot]
				showItem(slot, strip[math.random(#strip)].id, false)
			end
			task.wait(tick)
		end
		answers["Many|nil"] = nil
		rolling["Many|nil"] = nil
		for _, slot in slots do
			rolling[`Appearance|{slot}`] = nil
		end
		local best, bestSlot = 0, nil
		for _, slot in slots do
			spinning[slot] = nil
			local id = if typeof(results) == "table" then results[slot] else nil
			showItem(slot, if id ~= nil then id else player:GetAttribute("Look_" .. slot), true)
			if id ~= nil then
				local item = lookItem(slot, id)
				local rarity = item and item.rarity or "Common"
				local r = rows[slot]
				land(rarity, r.flash, r.pop, true)
				local rank = table.find(Rarity.ORDER, rarity) or 0
				if rank > best then
					best, bestSlot = rank, slot
				end
			end
		end
		if typeof(results) ~= "table" then
			setStatus(if target then `CAN'T AUTO ROLL FOR {string.upper(target)} HERE` else "CAN'T REROLL RIGHT NOW")
			return
		end
		if bestSlot then
			local r = rows[bestSlot]
			land(Rarity.ORDER[best], r.flash, r.pop)
		end
		if target and typeof(rolls) == "number" then
			setStatus(`AUTO ROLLED {rolls}x`)
		end
		task.delay(0.4, function()
			if gui.Enabled then
				rebuildPreview()
			end
		end)
	end)

	-- Emotes page (user, 2026-10-18): one row per G wheel slot, REROLL (1 reroll, never a double) + UNDO.
	local Emotes = Paths.data("Emotes")
	local emotesPage = pages.Emotes
	autoButton(UDim2.fromOffset(220, 40), UDim2.fromOffset(0, 4), emotesPage)
	text({ Text = "Press G to open your emote wheel.", TextSize = 17, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(234, 4), Size = UDim2.new(1, -234, 0, 40) }, emotesPage)
	local function emoteItem(id: any): any?
		for _, item in Emotes.items do
			if item.id == id then
				return item
			end
		end
		return nil
	end
	for n = 1, Emotes.SLOTS do
		local key = "Emote" .. n
		local row = box({ Position = UDim2.fromOffset(0, 52 + (n - 1) * (ROW_H + ROW_GAP)), Size = UDim2.new(1, 0, 0, ROW_H), BackgroundColor3 = ROW }, emotesPage)
		stroke(row, 0.9)
		local badge = text({ Text = tostring(n), FontFace = HEAD_FONT, TextSize = 30, Position = UDim2.fromOffset(10, 5), Size = UDim2.fromOffset(48, 48), BackgroundTransparency = 0, BackgroundColor3 = BAR }, row)
		stroke(badge, 0.85)
		local pop = new("UIScale", {}, badge)
		text({ Text = `SLOT {n}`, TextSize = 17, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(70, 4), Size = UDim2.new(1, -190, 0, 18) }, row)
		local name = text({ Text = "", TextSize = 22, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(70, 24), Size = UDim2.new(0, NAME_W, 0, 26) }, row)
		local fancy = box({ Position = UDim2.fromOffset(70, 24), Size = UDim2.new(0, NAME_W, 0, 26), BackgroundTransparency = 1 }, row)
		local flash = box({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 3 }, row)
		local reroll = button("REROLL", UDim2.fromOffset(100, 42), UDim2.new(1, -108, 0.5, -21), row, true)
		local spinningEmote = false
		local function show(id: any, isFancy: boolean)
			local item = emoteItem(id)
			local rarity = item and item.rarity
			local label = if item then item.name else "..."
			row.BackgroundColor3 = Rarity.tint(rarity, ROW)
			name.Visible = not isFancy
			if isFancy then
				RarityText.render(fancy, label, rarity, 22, NAME_W)
			else
				RarityText.clear(fancy)
				name.Text = label
				name.TextColor3 = Rarity.color(rarity)
			end
		end
		undoButton(key, UDim2.fromOffset(66, 42), UDim2.new(1, -182, 0.5, -21), row, function()
			pop.Scale = 1.25
			tween(pop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
		end)
		player:GetAttributeChangedSignal(key):Connect(function()
			if not spinningEmote then
				show(player:GetAttribute(key), true)
			end
		end)
		show(player:GetAttribute(key), true)
		reroll.Activated:Connect(function()
			spinningEmote = true
			local started, result = roll("Emotes", key, Emotes.items, function(id)
				show(id, false)
			end)
			spinningEmote = false
			if not started then
				return
			end
			show(if result ~= nil then result else player:GetAttribute(key), true)
			if result ~= nil then
				local item = emoteItem(result)
				land(item and item.rarity or "Common", flash, pop)
			end
		end)
	end

	-- Shared by the Styles and Lockers pages.
	local HttpService = game:GetService("HttpService")
	-- What you fight with, from the attributes: "Style" (StyleService), "PerkSlots", "TraitLocks".
	local function wornStyle(): any
		local style = player:GetAttribute("Style")
		local traits = string.split(tostring(player:GetAttribute("PerkSlots") or ""), ",")
		local locks = {}
		for t, v in string.split(tostring(player:GetAttribute("TraitLocks") or ""), ",") do
			locks[t] = v == "1"
		end
		return { Style = if typeof(style) == "string" then style else "", Traits = traits, Locks = locks }
	end
	-- Stored items ("Locker" attribute, PerkRollService): { Kind = "" | "Look" | "Style", ... }.
	local function lockerItems(): { any }
		local raw = player:GetAttribute("Locker")
		if typeof(raw) ~= "string" then
			return {}
		end
		local ok, v = pcall(HttpService.JSONDecode, HttpService, raw)
		return if ok and typeof(v) == "table" then v else {}
	end
	local function styleOf(slot: any): string
		return if slot.Style ~= "" then slot.Style else D.DEFAULT_STYLE
	end
	-- What a trait roll for `style` can show on the strip (mirrors PerkRollService.pool), plus nothing.
	local function traitPool(style: string): { any }
		local items = { { id = "" } }
		for _, id in Paths.perkIds() do
			local data = Paths.perk(id)
			if data.rollable == true and (data.style == nil or data.style == style) then
				table.insert(items, { id = id, rarity = data.rarity })
			end
		end
		return items
	end
	local function traitRarity(id: string): string?
		return if id ~= "" and Paths.findPerk(id) then Paths.perk(id).rarity else nil
	end
	-- Rerolls one traits roll costs (mirrors PerkRollService.lockCost): D.TRAIT_LOCK_MULT per lock; nil = all locked.
	local function lockCost(slot: any): number?
		local locked = 0
		for t = 1, D.PERK_SLOTS do
			if slot.Locks and slot.Locks[t] then
				locked += 1
			end
		end
		return if locked >= D.PERK_SLOTS then nil else D.TRAIT_LOCK_MULT ^ locked
	end
	-- Trait art lives in the HUD atlas (4 cells a row, 256 px; the card back is cell 12).
	local ATLAS_CELL, CARD_CELL = 256, 12
	local EMPTY_TRAIT = Color3.fromRGB(70, 70, 78)
	local function atlas(cell: number, props: { [string]: any }, parent: Instance): ImageLabel
		props.Image = D.HUD_ATLAS
		props.ImageRectOffset = Vector2.new((cell % 4) * ATLAS_CELL, (cell // 4) * ATLAS_CELL)
		props.ImageRectSize = Vector2.new(ATLAS_CELL, ATLAS_CELL)
		props.BackgroundTransparency = 1
		return new("ImageLabel", props, parent)
	end
	-- A trait's card art (+ icon) tinted in its colour; nil id / "" = the grey empty card.
	local function paintTrait(art: ImageLabel, icon: ImageLabel, id: string?)
		local data = if id and id ~= "" and Paths.findPerk(id) then Paths.perk(id) else nil
		art.ImageColor3 = if data then data.color or Rarity.color(data.rarity) else EMPTY_TRAIT
		icon.Visible = data ~= nil and data.icon ~= nil
		if data and data.icon then
			icon.ImageRectOffset = Vector2.new((data.icon % 4) * ATLAS_CELL, (data.icon // 4) * ATLAS_CELL)
		end
	end
	local function combatBlocked(): boolean
		local character = player.Character
		if character and character:GetAttribute("CombatMode") then
			setStatus("LEAVE COMBAT MODE FIRST")
			return true
		end
		return false
	end

	-- Styles page (user, 2026-10-22): your style and traits as one Persona spread. Left: the style plate
	-- (REROLL STYLE + UNDO). Right: three tilted trait cards, each with a LOCK (a locked trait stays
	-- through rerolls; every lock multiplies the price by D.TRAIT_LOCK_MULT, all locked = no reroll).
	-- REROLL TRAITS spins the unlocked cards and lands them one after another. Keys: "Style", "Traits".
	local stylesPage = pages.Styles
	local plate = box({ Position = UDim2.fromOffset(8, 14), Size = UDim2.fromOffset(272, 300), BackgroundColor3 = BAR, Rotation = -3 }, stylesPage)
	new("UIStroke", { Color = WHITE, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, plate)
	box({ Position = UDim2.fromOffset(-16, 40), Size = UDim2.new(1, 32, 0, 58), BackgroundColor3 = ACCENT, Rotation = -4 }, plate) -- the red slash under the name
	local styleTag = text({ Text = "STYLE", FontFace = HEAD_FONT, TextSize = 24, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(14, 6), Size = UDim2.fromOffset(160, 28), Rotation = -2 }, plate)
	outline(styleTag, 2)
	local styleHolder = box({ Position = UDim2.fromOffset(12, 46), Size = UDim2.fromOffset(248, 44), BackgroundTransparency = 1 }, plate)
	local stylePop = new("UIScale", {}, styleHolder)
	local styleName = text({ Text = "", FontFace = HEAD_FONT, TextSize = 34, TextStrokeTransparency = 0, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.fromScale(1, 1) }, styleHolder)
	local styleFancy = box({ Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, styleHolder)
	local styleTier = text({ Text = "", FontFace = HEAD_FONT, TextSize = 22, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(14, 108), Size = UDim2.fromOffset(244, 26) }, plate)
	outline(styleTier, 2)
	text({ Text = "Changes kick in once you're idle and out of combat mode. Keep a style for later in the Locker.", TextSize = 15, TextColor3 = DIM, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(14, 142), Size = UDim2.fromOffset(244, 60) }, plate)
	local styleFlash = box({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 4 }, plate)
	local rerollStyle = button("REROLL STYLE", UDim2.fromOffset(170, 50), UDim2.fromOffset(12, 236), plate, true)
	undoButton("Style", UDim2.fromOffset(76, 50), UDim2.fromOffset(188, 236), plate, function()
		stylePop.Scale = 1.2
		tween(stylePop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
	autoButton(UDim2.fromOffset(272, 46), UDim2.new(0, 8, 1, -50), stylesPage)

	local function showStyle(id: string, fancy: boolean)
		local name = if id == "" then D.DEFAULT_STYLE else id
		local label = styleLabel(name)
		local rarity = styleRarity(name)
		styleTier.Text = string.upper(rarity) .. " STYLE"
		styleTier.TextColor3 = Rarity.color(rarity)
		styleName.Visible = not fancy
		if fancy then
			RarityText.render(styleFancy, label, rarity, 34, 248)
		else
			RarityText.clear(styleFancy)
			styleName.Text = label
			styleName.TextColor3 = Rarity.color(rarity)
		end
	end

	local CARD_W, CARD_H, CARD_GAP, CARDS_X = 158, 296, 14, 300
	local CARD_TILT = { -4, 2, -2 }
	type TraitCard = { root: Frame, scale: UIScale, band: Frame, art: ImageLabel, icon: ImageLabel, name: TextLabel, fancy: Frame, desc: TextLabel, flash: Frame, chains: Frame, lock: TextButton }
	local traitCards: { TraitCard } = {}
	for t = 1, D.PERK_SLOTS do
		local root = box({
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromOffset(CARDS_X + (t - 1) * (CARD_W + CARD_GAP) + CARD_W / 2, 12 + CARD_H / 2),
			Size = UDim2.fromOffset(CARD_W, CARD_H),
			Rotation = CARD_TILT[t],
			BackgroundColor3 = BAR,
		}, stylesPage)
		new("UIStroke", { Color = WHITE, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, root)
		local scale = new("UIScale", {}, root)
		local band = box({ Size = UDim2.new(1, 0, 0, 12), BackgroundColor3 = EMPTY_TRAIT }, root)
		local tag = text({ Text = `TRAIT {t}`, FontFace = HEAD_FONT, TextSize = 18, TextColor3 = DIM, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(10, 16), Size = UDim2.fromOffset(120, 22) }, root)
		outline(tag, 2)
		local art = atlas(CARD_CELL, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 40), Size = UDim2.fromOffset(110, 110), Rotation = -CARD_TILT[t] * 2 }, root)
		local icon = atlas(0, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.52, 0.5), Size = UDim2.fromScale(0.68, 0.68) }, art)
		local nameHolder = box({ Position = UDim2.fromOffset(8, 158), Size = UDim2.new(1, -16, 0, 26), BackgroundTransparency = 1 }, root)
		local name = text({ Text = "", FontFace = HEAD_FONT, TextSize = 20, TextStrokeTransparency = 0, TextTruncate = Enum.TextTruncate.AtEnd, Size = UDim2.fromScale(1, 1) }, nameHolder)
		local fancy = box({ Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, nameHolder)
		local desc = text({ Text = "", TextSize = 13, TextColor3 = DIM, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(8, 188), Size = UDim2.new(1, -16, 0, 58) }, root)
		local flash = box({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 6 }, root)
		-- Locked: the card goes dark under a tilted LOCKED stamp.
		local chains = box({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = BLACK, BackgroundTransparency = 0.45, ZIndex = 3, Visible = false }, root)
		for i = 1, 2 do
			box({ AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.38), Size = UDim2.new(1.15, 0, 0, 10), BackgroundColor3 = YELLOW, BackgroundTransparency = 0.25, Rotation = if i == 1 then 32 else -32, ZIndex = 3 }, chains)
		end
		local stamp = text({ Text = "LOCKED", FontFace = HEAD_FONT, TextSize = 34, TextColor3 = YELLOW, TextStrokeTransparency = 1, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.38), Size = UDim2.fromOffset(150, 42), Rotation = -12, ZIndex = 4 }, chains)
		outline(stamp, 3)
		local lock = button("LOCK", UDim2.new(1, -16, 0, 36), UDim2.new(0, 8, 1, -44), root)
		lock.ZIndex = 5
		traitCards[t] = { root = root, scale = scale, band = band, art = art, icon = icon, name = name, fancy = fancy, desc = desc, flash = flash, chains = chains, lock = lock }
		lock.Activated:Connect(function()
			local slot = wornStyle()
			if busy() or combatBlocked() then
				return
			elseif not slot.Locks[t] and (slot.Traits[t] or "") == "" then
				setStatus("NOTHING TO LOCK")
				return
			end
			Net.get(Net.Names.TraitLock):FireServer(t)
		end)
	end
	-- One flash over all the cards for the loud landing (shake / callout once, for the best trait).
	local traitsFlash = box({ Position = UDim2.fromOffset(CARDS_X - 8, 0), Size = UDim2.fromOffset(3 * CARD_W + 2 * CARD_GAP + 16, CARD_H + 24), BackgroundColor3 = WHITE, BackgroundTransparency = 1, ZIndex = 7 }, stylesPage)
	local traitsPop = new("UIScale", {}, traitsFlash)
	local rerollTraits = button("REROLL TRAITS", UDim2.fromOffset(300, 54), UDim2.new(0, CARDS_X, 1, -58), stylesPage, true)
	local costLabel = text({ Text = "", FontFace = HEAD_FONT, TextSize = 26, TextStrokeTransparency = 1, Position = UDim2.new(0, CARDS_X + 306, 1, -58), Size = UDim2.fromOffset(120, 54), Rotation = -4 }, stylesPage)
	outline(costLabel, 3)
	undoButton("Traits", UDim2.fromOffset(76, 54), UDim2.new(1, -78, 1, -58), stylesPage, function()
		traitsPop.Scale = 1.05
		tween(traitsPop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
	end)

	local function showTrait(t: number, id: string, fancy: boolean)
		local c = traitCards[t]
		local data = if id ~= "" and Paths.findPerk(id) then Paths.perk(id) else nil
		local rarity = data and data.rarity
		paintTrait(c.art, c.icon, id)
		c.band.BackgroundColor3 = c.art.ImageColor3
		local label = if data then string.upper(data.name or id) else "NO TRAIT"
		c.desc.Text = if data then data.desc or "" else "Reroll for a chance at one."
		c.name.Visible = not fancy
		if fancy then
			RarityText.render(c.fancy, label, rarity, 20, CARD_W - 16)
		else
			RarityText.clear(c.fancy)
			c.name.Text = label
			c.name.TextColor3 = if rarity then Rarity.color(rarity) else DIM
		end
	end

	local spinningStyle, spinningTraits = false, false
	local function refreshStyles()
		local slot = wornStyle()
		if not spinningStyle then
			showStyle(slot.Style, true)
		end
		local cost = lockCost(slot)
		costLabel.Text = if cost then `COST {cost}` else "ALL LOCKED"
		costLabel.TextColor3 = if cost == nil then DIM elseif cost > 1 then YELLOW else WHITE
		for t, c in traitCards do
			local locked = slot.Locks[t] == true
			c.chains.Visible = locked
			c.lock.Text = if locked then "UNLOCK" else "LOCK"
			if not spinningTraits then
				showTrait(t, slot.Traits[t] or "", true)
			end
		end
	end

	rerollStyle.Activated:Connect(function()
		if spinningStyle then
			return
		end
		spinningStyle = true
		local started, result = roll("Loadout", "Style", stylePool(), function(id)
			showStyle(id, false)
			plate.Rotation = -3 + (math.random() * 2 - 1) * 1.5
		end)
		spinningStyle = false
		plate.Rotation = -3
		if not started then
			return
		end
		refreshStyles()
		if result ~= nil then
			showStyle(result, true)
			land(styleRarity(result), styleFlash, stylePop)
		end
	end)

	rerollTraits.Activated:Connect(function()
		local slot = wornStyle()
		if spinningTraits then
			return
		end
		local cost = lockCost(slot)
		local spins = player:GetAttribute("Spins")
		if not cost then
			setStatus("UNLOCK A TRAIT TO REROLL")
			return
		elseif not freeSpins() and (typeof(spins) ~= "number" or spins < cost) then
			setStatus(`NEED {cost} REROLLS`)
			return
		end
		local locks = slot.Locks
		local pool = traitPool(styleOf(slot))
		spinningTraits = true
		local started, result = roll("Loadout", "Traits", pool, function()
			for t, c in traitCards do
				if not locks[t] then
					showTrait(t, pool[math.random(#pool)].id, false)
					c.root.Rotation = CARD_TILT[t] + (math.random() * 2 - 1) * 3
				end
			end
		end)
		for t, c in traitCards do
			c.root.Rotation = CARD_TILT[t]
		end
		if not started or typeof(result) ~= "table" then
			spinningTraits = false
			refreshStyles()
			return
		end
		-- Unlocked cards land one by one; locked ones rattle in their chains; the best rarity lands loud.
		local landing, best = {}, nil
		for t = 1, D.PERK_SLOTS do
			if locks[t] then
				local c = traitCards[t]
				c.root.Rotation = CARD_TILT[t] + 7
				tween(c.root, 0.6, { Rotation = CARD_TILT[t] }, Enum.EasingStyle.Elastic)
			else
				table.insert(landing, t)
				local r = traitRarity(result[t] or "")
				if r and (not best or table.find(Rarity.ORDER, r) > table.find(Rarity.ORDER, best)) then
					best = r
				end
			end
		end
		for i, t in landing do
			task.delay((i - 1) * 0.16, function()
				local c = traitCards[t]
				showTrait(t, result[t] or "", true)
				land(traitRarity(result[t] or "") or "Common", c.flash, c.scale, true)
			end)
		end
		task.delay(#landing * 0.16, function()
			spinningTraits = false
			land(best or "Common", traitsFlash, traitsPop)
			refreshStyles()
		end)
	end)
	for _, attr in { "Style", "PerkSlots", "TraitLocks" } do
		player:GetAttributeChangedSignal(attr):Connect(refreshStyles)
	end
	refreshStyles()

	-- Locker page (user, 2026-10-22: "lockers are supposed to store individual items, so if someone wants
	-- to own 2 mythic hats and swap between them they can"). Each slot keeps ONE item: a hat, hair, face,
	-- accessory or a style with its traits. A full slot: SWAP IN (you wear it, what you wore takes its
	-- place). An empty slot: STORE what you're wearing in one of the categories. Server: RerollService.
	local lockersPage = pages.Locker
	text({ Text = "Each slot keeps one thing you own. STORE what you wear into an empty slot, then reroll for a new one; SWAP IN to wear it again.", TextSize = 15, TextColor3 = DIM, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, -10, 0, 40) }, lockersPage)
	local lockerList = new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 48),
		Size = UDim2.new(1, 0, 1, -48),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = DIM,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, lockersPage)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(258, 132), CellPadding = UDim2.fromOffset(14, 14), SortOrder = Enum.SortOrder.LayoutOrder }, lockerList)
	new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 10) }, lockerList)
	-- What an empty slot can store (skin tone isn't an item; mirrors RerollService.store).
	local STORE_KINDS = { { "Hair", "HAIR" }, { "Hat", "HAT" }, { "FaceAccessory", "FACE ACC" }, { "BackAccessory", "BACK ACC" }, { "Face", "FACE" }, { "Style", "STYLE" } }

	local function lockerSend(action: string, arg: any)
		if busy() or combatBlocked() then
			return
		end
		Net.get(Net.Names.Locker):FireServer(action, arg)
	end

	local function lockerCard(n: number, item: any)
		local root = box({ LayoutOrder = n, BackgroundColor3 = BAR, BackgroundTransparency = 0.1, Rotation = if n % 2 == 0 then 1 else -1 }, lockerList)
		local ring = new("UIStroke", { Color = WHITE, Transparency = 0.75, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, root)
		if item.Kind == "" then
			ring.Transparency = 0.9
			text({ Text = "STORE WHAT YOU WEAR:", FontFace = HEAD_FONT, TextSize = 16, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(10, 10), Size = UDim2.new(1, -20, 0, 20) }, root)
			for i, kind in STORE_KINDS do
				local col, rowN = (i - 1) % 3, (i - 1) // 3
				local b = button(kind[2], UDim2.fromOffset(76, 34), UDim2.fromOffset(10 + col * 80, 38 + rowN * 42), root)
				b.Activated:Connect(function()
					lockerSend("Store", kind[1])
				end)
			end
			return
		end
		local rarity: string? = nil
		if item.Kind == "Look" then
			local def = Appearance.slots[item.Slot]
			local found = lookItem(item.Slot, item.Id)
			rarity = found and found.rarity
			local thumb = new("ImageLabel", { Position = UDim2.fromOffset(10, 12), Size = UDim2.fromOffset(72, 72), BackgroundColor3 = ROW, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Fit }, root)
			stroke(thumb, 0.85)
			local thumbId = if found and found.thumb then found.thumb else item.Id
			thumb.Image = if typeof(thumbId) == "number" and thumbId ~= 0 then `rbxthumb://type=Asset&id={thumbId}&w=150&h=150` else ""
			text({ Text = string.upper(def and def.label or tostring(item.Slot)), TextSize = 14, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(92, 12), Size = UDim2.fromOffset(156, 18) }, root)
			local fancy = box({ Position = UDim2.fromOffset(92, 32), Size = UDim2.fromOffset(156, 26), BackgroundTransparency = 1 }, root)
			RarityText.render(fancy, if found then found.name else `Custom #{item.Id}`, rarity, 19, 156)
		else
			local style = styleOf(item)
			rarity = styleRarity(style)
			text({ Text = "STYLE", TextSize = 14, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(10, 10), Size = UDim2.fromOffset(120, 18) }, root)
			local fancy = box({ Position = UDim2.fromOffset(10, 28), Size = UDim2.fromOffset(150, 26), BackgroundTransparency = 1 }, root)
			RarityText.render(fancy, styleLabel(style), rarity, 22, 150)
			for t = 1, D.PERK_SLOTS do
				local art = atlas(CARD_CELL, { Position = UDim2.fromOffset(166 + (t - 1) * 30, 14), Size = UDim2.fromOffset(28, 28), Rotation = CARD_TILT[t] * 2 }, root)
				local icon = atlas(0, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.52, 0.5), Size = UDim2.fromScale(0.68, 0.68) }, art)
				paintTrait(art, icon, item.Traits[t])
				if item.Locks and item.Locks[t] then
					new("UIStroke", { Color = YELLOW, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, art)
				end
			end
		end
		ring.Color = Rarity.color(rarity)
		ring.Transparency = if rarity and rarity ~= "Common" then 0.1 else 0.6
		local swap = button("SWAP IN", UDim2.new(1, -112, 0, 36), UDim2.new(0, 10, 1, -44), root, true)
		swap.Activated:Connect(function()
			lockerSend("Swap", n)
		end)
		-- TRASH (user, 2026-11-01): gone for good, so the first press only arms it ("SURE?" for 3 s).
		local trash = button("TRASH", UDim2.fromOffset(90, 36), UDim2.new(1, -100, 1, -44), root)
		local armedAt = -math.huge
		trash.Activated:Connect(function()
			if os.clock() - armedAt > 3 then
				armedAt = os.clock()
				trash.Text = "SURE?"
				trash.BackgroundColor3 = ACCENT
				task.delay(3, function()
					if trash.Parent and os.clock() - armedAt >= 3 then
						trash.Text = "TRASH"
						trash.BackgroundColor3 = BUTTON
					end
				end)
				return
			end
			armedAt = -math.huge
			lockerSend("Trash", n)
		end)
	end

	-- The last cell (user, 2026-11-01): buy one more slot. Bux = the next of D.LOCKER_BUX_PRICES (that half
	-- goes away once all are bought); Robux = a LOCKER_PRODUCTS product, every time, never uses up a Bux slot.
	local lockerProduct = next(D.LOCKER_PRODUCTS)
	local function buyCard(n: number)
		local bought = player:GetAttribute("LockerBuxSlots")
		local price = D.LOCKER_BUX_PRICES[(if typeof(bought) == "number" then bought else 0) + 1]
		if not price and not lockerProduct then
			return
		end
		local root = box({ LayoutOrder = n, BackgroundColor3 = BAR, BackgroundTransparency = 0.4, Rotation = if n % 2 == 0 then 1 else -1 }, lockerList)
		new("UIStroke", { Color = YELLOW, Transparency = 0.3, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, root)
		local plus = text({ Text = "+1 SLOT", FontFace = HEAD_FONT, TextSize = 30, TextStrokeTransparency = 1, TextColor3 = YELLOW, Position = UDim2.fromOffset(10, 10), Size = UDim2.new(1, -20, 0, 36) }, root)
		outline(plus, 2)
		local buttons = {}
		if price then
			local buxButton = button(`{price} BUX`, UDim2.new(), UDim2.new(), root, true)
			buxButton.Activated:Connect(function()
				lockerSend("BuySlot")
			end)
			table.insert(buttons, buxButton)
		end
		if lockerProduct then
			local robuxButton = button("50 ROBUX", UDim2.new(), UDim2.new(), root, true)
			robuxButton.Activated:Connect(function()
				game:GetService("MarketplaceService"):PromptProductPurchase(player, lockerProduct)
			end)
			table.insert(buttons, robuxButton)
		end
		-- One button = full width; two = side by side.
		local w = (238 - 8 * (#buttons - 1)) / #buttons
		for i, bt in buttons do
			bt.Size = UDim2.fromOffset(w, 40)
			bt.Position = UDim2.fromOffset(10 + (i - 1) * (w + 8), 132 - 52)
		end
	end

	local function refreshLocker()
		for _, c in lockerList:GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		local items = lockerItems()
		for n, item in items do
			lockerCard(n, item)
		end
		buyCard(#items + 1)
	end
	player:GetAttributeChangedSignal("Locker"):Connect(refreshLocker)
	player:GetAttributeChangedSignal("LockerBuxSlots"):Connect(refreshLocker) -- the next Bux price
	refreshLocker()

	-- Servers page (user, 2026-10-22): free private servers (PrivateServerService). CREATE SERVER sends you
	-- to a new one with a share code; JOIN SERVER takes a code. Inside a code server its code shows on top.
	local serversPage = pages.Servers
	local sw = WINDOW.X - 2 * EDGE
	local serversTitle = text({ Text = "PRIVATE SERVERS", FontFace = HEAD_FONT, TextSize = 46, TextStrokeTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 6), Size = UDim2.fromOffset(sw, 54), Rotation = -2 }, serversPage)
	outline(serversTitle, 4)
	local serverInfo = text({ Text = "", TextSize = 17, TextColor3 = DIM, TextWrapped = true, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 64), Size = UDim2.fromOffset(sw - 80, 24) }, serversPage)
	local COL_W = 360
	local leftX, rightX = sw / 2 - COL_W - 20, sw / 2 + 20
	local function heading(label: string, x: number)
		local l = text({ Text = label, FontFace = HEAD_FONT, TextSize = 26, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(x, 112), Size = UDim2.fromOffset(COL_W, 30), Rotation = -2 }, serversPage)
		outline(l, 2)
	end
	heading("CREATE SERVER", leftX)
	text({ Text = "Free. You get a code to share with friends.", TextSize = 16, TextColor3 = DIM, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(leftX, 150), Size = UDim2.fromOffset(COL_W, 48) }, serversPage)
	local create = button("CREATE SERVER", UDim2.fromOffset(COL_W, 64), UDim2.fromOffset(leftX, 210), serversPage, true)
	heading("JOIN SERVER", rightX)
	local joinField: TextBox = new("TextBox", {
		Position = UDim2.fromOffset(rightX, 146),
		Size = UDim2.fromOffset(COL_W, 56),
		BackgroundColor3 = BAR,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		FontFace = HEAD_FONT,
		TextSize = 32,
		TextColor3 = WHITE,
		PlaceholderText = "ENTER CODE",
		PlaceholderColor3 = Color3.fromRGB(90, 86, 104),
		Text = "",
	}, serversPage)
	new("UIStroke", { Color = WHITE, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, joinField)
	local join = button("JOIN SERVER", UDim2.fromOffset(COL_W, 64), UDim2.fromOffset(rightX, 210), serversPage, true)
	for _, b in { create, join } do
		(b:FindFirstChildOfClass("UITextSizeConstraint") :: UITextSizeConstraint).MaxTextSize = 30
	end
	local serverResult = text({ Text = "", FontFace = HEAD_FONT, TextSize = 28, TextStrokeTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 300), Size = UDim2.fromOffset(sw, 40) }, serversPage)
	outline(serverResult, 3)
	local resultPop = new("UIScale", {}, serverResult)
	local function refreshHere()
		local code = workspace:GetAttribute("ServerCode")
		serverInfo.Text = if typeof(code) == "string" then `THIS SERVER'S CODE: {code}` else "Make your own server for free, or join a friend's with their code."
		serverInfo.TextColor3 = if typeof(code) == "string" then YELLOW else DIM
	end
	workspace:GetAttributeChangedSignal("ServerCode"):Connect(refreshHere)
	refreshHere()
	local serverToken = 0
	local function ask(remote: string, arg: any?)
		if serverToken ~= 0 or combatBlocked() then
			return
		end
		serverToken = os.clock()
		local token = serverToken
		serverResult.Text = "..."
		serverResult.TextColor3 = DIM
		Net.get(remote):FireServer(arg)
		task.delay(TIMEOUT * 2, function() -- reserving + saving a code can take a few seconds
			if serverToken == token then
				serverToken = 0
				serverResult.Text = "NO ANSWER, TRY AGAIN"
				serverResult.TextColor3 = Color3.fromRGB(255, 110, 110)
			end
		end)
	end
	Net.get(Net.Names.ServerResult).OnClientEvent:Connect(function(ok: boolean, message: string)
		serverToken = 0
		serverResult.Text = tostring(message)
		serverResult.TextColor3 = if ok then Color3.fromRGB(110, 255, 140) else Color3.fromRGB(255, 110, 110)
		resultPop.Scale = 1.3
		tween(resultPop, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
	create.Activated:Connect(function()
		ask(Net.Names.ServerCreate)
	end)
	local function joinCode()
		local code = string.gsub(joinField.Text, "%s", "")
		if code ~= "" then
			ask(Net.Names.ServerJoin, code)
		end
	end
	join.Activated:Connect(joinCode)
	joinField.FocusLost:Connect(function(enter)
		if enter then
			joinCode()
		end
	end)

	-- Codes page (user, 2026-10-17): one big box + REDEEM; the server checks it (CodeService) and
	-- answers with CodeResult(ok, message).
	local codesPage = pages.Codes
	local cw = WINDOW.X - 2 * EDGE
	local codeTitle = text({ Text = "GOT A CODE?", FontFace = HEAD_FONT, TextSize = 48, TextStrokeTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 24), Size = UDim2.fromOffset(cw, 56), Rotation = -2 }, codesPage)
	new("UIStroke", { Color = BLACK, Thickness = 4, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, codeTitle)
	text({ Text = "Codes drop with updates and on our socials. Each one works once.", TextSize = 18, TextColor3 = DIM, TextWrapped = true, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 88), Size = UDim2.fromOffset(cw - 80, 24) }, codesPage)
	local codeBox: TextBox = new("TextBox", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 136),
		Size = UDim2.fromOffset(480, 72),
		BackgroundColor3 = BAR,
		BorderSizePixel = 0,
		ClearTextOnFocus = false,
		FontFace = HEAD_FONT,
		TextSize = 34,
		TextColor3 = WHITE,
		PlaceholderText = "ENTER CODE",
		PlaceholderColor3 = Color3.fromRGB(90, 86, 104),
		Text = "",
	}, codesPage)
	new("UIStroke", { Color = WHITE, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, codeBox)
	local redeem = button("REDEEM", UDim2.fromOffset(220, 60), UDim2.new(0.5, -110, 0, 230), codesPage, true)
	local redeemSize = redeem:FindFirstChildOfClass("UITextSizeConstraint") :: UITextSizeConstraint
	redeemSize.MaxTextSize = 32
	local codeResult = text({ Text = "", FontFace = HEAD_FONT, TextSize = 30, TextStrokeTransparency = 1, AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 316), Size = UDim2.fromOffset(cw, 40) }, codesPage)
	new("UIStroke", { Color = BLACK, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, codeResult)
	local codePop = new("UIScale", {}, codeResult)
	local codeToken = 0 -- the request in flight (0 = none)
	local function redeemCode()
		local code = string.gsub(codeBox.Text, "^%s*(.-)%s*$", "%1")
		if code == "" or codeToken ~= 0 then
			return
		end
		codeToken = os.clock()
		local token = codeToken
		codeResult.Text = "..."
		codeResult.TextColor3 = DIM
		Net.get(Net.Names.RedeemCode):FireServer(code)
		task.delay(TIMEOUT, function()
			if codeToken == token then
				codeToken = 0
				codeResult.Text = "NO ANSWER, TRY AGAIN"
				codeResult.TextColor3 = Color3.fromRGB(255, 110, 110)
			end
		end)
	end
	Net.get(Net.Names.CodeResult).OnClientEvent:Connect(function(ok: boolean, message: string)
		codeToken = 0
		codeResult.Text = tostring(message)
		codeResult.TextColor3 = if ok then Color3.fromRGB(110, 255, 140) else Color3.fromRGB(255, 110, 110)
		codePop.Scale = 1.3
		tween(codePop, 0.35, { Scale = 1 }, Enum.EasingStyle.Back)
		if ok then
			codeBox.Text = ""
			Paths.client("CalloutController").push("Code", "REDEEMED!", YELLOW)
		end
	end)
	redeem.Activated:Connect(redeemCode)
	codeBox.FocusLost:Connect(function(enter)
		if enter then
			redeemCode()
		end
	end)

	-- Settings page (user, 2026-10-29): FOV slider + TOGGLE RUN + MUSIC VOLUME (2026-11-01). Saved by the server (SettingsService); what
	-- gets applied is the Player attributes it echoes (SetFov -> CameraFov.setBase, SetToggleRun -> RunController).
	-- Scrolls: four rows (FOV, run, music, title) are taller than the page.
	local settingsPage = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = DIM,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, pages.Settings)
	new("UIPadding", { PaddingBottom = UDim.new(0, 16) }, settingsPage)
	local SET = D.SETTINGS
	local CameraFov = Paths.client("CameraFov")
	local SettingsRemote = Net.get(Net.Names.Settings)
	local rowW = WINDOW.X - 2 * EDGE - 40
	local function settingRow(y: number, label: string, hint: string): Frame
		local row = box({ Position = UDim2.fromOffset(EDGE + 20, y), Size = UDim2.fromOffset(rowW, 100), BackgroundColor3 = ROW }, settingsPage)
		local l = text({ Text = label, FontFace = HEAD_FONT, TextSize = 30, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(18, 12), Size = UDim2.fromOffset(320, 36) }, row)
		new("UIStroke", { Color = BLACK, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, l)
		text({ Text = hint, TextSize = 15, TextColor3 = DIM, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(18, 54), Size = UDim2.fromOffset(340, 40) }, row)
		return row
	end

	-- A slider row: drag the bar (mouse / touch) or step with - / + (gamepad too). `apply` runs live; the value
	-- is saved (SettingsRemote `key`) on release; the server's echo (Player attribute `attr`) loads it.
	local function slider(row: Frame, key: string, attr: string, min: number, max: number, step: number, start: number, apply: (number) -> (), show: (number) -> string)
		local valueLabel = text({ Text = "", FontFace = HEAD_FONT, TextSize = 34, TextStrokeTransparency = 1, Position = UDim2.fromOffset(372, 28), Size = UDim2.fromOffset(70, 44) }, row)
		new("UIStroke", { Color = BLACK, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, valueLabel)
		local minus = button("-", UDim2.fromOffset(48, 48), UDim2.fromOffset(452, 26), row)
		local track = new("TextButton", { Text = "", AutoButtonColor = false, BackgroundColor3 = BAR, BorderSizePixel = 0, Position = UDim2.fromOffset(512, 40), Size = UDim2.fromOffset(196, 20) }, row) :: TextButton
		new("UIStroke", { Color = WHITE, Thickness = 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, track)
		local fill = box({ BackgroundColor3 = ACCENT, Size = UDim2.fromScale(0, 1) }, track)
		local knob = box({ AnchorPoint = Vector2.new(0.5, 0.5), BackgroundColor3 = WHITE, Size = UDim2.fromOffset(14, 34), Position = UDim2.fromScale(0, 0.5) }, track)
		new("UIStroke", { Color = BLACK, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, knob)
		local plus = button("+", UDim2.fromOffset(48, 48), UDim2.fromOffset(720, 26), row)
		local value = start
		local dragging = false
		local function set(v: number)
			value = math.clamp(math.round(v), min, max)
			local k = (value - min) / (max - min)
			fill.Size = UDim2.fromScale(k, 1)
			knob.Position = UDim2.fromScale(k, 0.5)
			valueLabel.Text = show(value)
			apply(value)
		end
		local function save()
			if player:GetAttribute(attr) ~= value then
				SettingsRemote:FireServer(key, value)
			end
		end
		local function dragTo(x: number)
			local k = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
			set(min + k * (max - min))
		end
		track.InputBegan:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragTo(input.Position.X)
			end
		end)
		UserInputService.InputChanged:Connect(function(input: InputObject)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				dragTo(input.Position.X)
			end
		end)
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
				dragging = false
				save()
			end
		end)
		minus.Activated:Connect(function()
			set(value - step)
			save()
		end)
		plus.Activated:Connect(function()
			set(value + step)
			save()
		end)
		local function load()
			local v = player:GetAttribute(attr)
			if typeof(v) == "number" and not dragging then
				set(v)
			end
		end
		player:GetAttributeChangedSignal(attr):Connect(load)
		load()
		valueLabel.Text = show(value) -- before the saved value arrives
	end

	-- FOV (the camera keeps its own FOV until the saved value arrives).
	local fovRow = settingRow(24, "FIELD OF VIEW", `How much of the world your camera shows. Default {SET.fovDefault}.`)
	slider(fovRow, "Fov", "SetFov", SET.fovMin, SET.fovMax, SET.fovStep, SET.fovDefault, CameraFov.setBase, tostring)

	-- Music volume (OST + DJ booths): live while dragging; MusicController also follows SetMusic on its own.
	local musicRow = settingRow(256, "MUSIC VOLUME", "The OST and DJ booths. 0 = off.")
	slider(musicRow, "Music", "SetMusic", 0, 100, SET.musicStep, 100, Paths.client("MusicController").setVolume, function(v)
		return `{v}%`
	end)

	-- Toggle run: Shift flips running on / off instead of holding it.
	local runRow = settingRow(140, "TOGGLE RUN", "Press Shift to start or stop running instead of holding it.")
	local runButton = button("OFF", UDim2.fromOffset(150, 56), UDim2.fromOffset(rowW - 168, 22), runRow, true)
	local function loadRun()
		runButton.Text = if player:GetAttribute("SetToggleRun") == true then "ON" else "OFF"
	end
	runButton.Activated:Connect(function()
		SettingsRemote:FireServer("ToggleRun", player:GetAttribute("SetToggleRun") ~= true)
	end)
	player:GetAttributeChangedSignal("SetToggleRun"):Connect(loadRun)
	loadRun()

	-- TITLE (user, 2026-11-01: "select which role you want to have above your head"): one chip per title
	-- your roles give ("OwnedTitles", RoleService) + OFF (hides it for everyone; you keep it, and what it
	-- gives, like freecam: SetHideTitle). Only shown when you have a title. The pick is saved
	-- (SettingsService "Title") and RoleService puts it on your nametag.
	local titleRow = box({ Position = UDim2.fromOffset(EDGE + 20, 372), Size = UDim2.fromOffset(rowW, 100), BackgroundColor3 = ROW }, settingsPage)
	do
		local l = text({ Text = "TITLE", FontFace = HEAD_FONT, TextSize = 30, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(18, 12), Size = UDim2.fromOffset(320, 36) }, titleRow)
		new("UIStroke", { Color = BLACK, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual }, l)
		text({ Text = "Which of your roles shows above your name. OFF hides it for everyone; you keep it.", TextSize = 15, TextColor3 = DIM, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Position = UDim2.fromOffset(18, 54), Size = UDim2.fromOffset(340, 40) }, titleRow)
	end
	local titleChips = box({ Position = UDim2.fromOffset(372, 14), Size = UDim2.new(1, -390, 1, -28), BackgroundTransparency = 1 }, titleRow)
	new("UIGridLayout", { CellSize = UDim2.fromOffset(160, 34), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder }, titleChips)
	local function loadTitle()
		for _, c in titleChips:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		local raw = player:GetAttribute("OwnedTitles")
		local owned = if typeof(raw) == "string" and raw ~= "" then string.split(raw, ",") else {}
		titleRow.Visible = #owned > 0
		local hidden = player:GetAttribute("SetHideTitle") == true
		local current = player:GetAttribute("Title")
		local rows = math.ceil((#owned + 1) / 2)
		titleRow.Size = UDim2.fromOffset(rowW, math.max(100, 28 + rows * 42))
		for i, id in owned do
			local b = button(string.upper(id), UDim2.new(), UDim2.new(), titleChips, not hidden and id == current) -- red = showing (hover keeps it)
			b.LayoutOrder = i
			b.Activated:Connect(function()
				SettingsRemote:FireServer("Title", id)
				if player:GetAttribute("SetHideTitle") == true then
					SettingsRemote:FireServer("HideTitle", false)
				end
			end)
		end
		local off = button("OFF", UDim2.new(), UDim2.new(), titleChips, hidden)
		off.LayoutOrder = #owned + 1
		off.Activated:Connect(function()
			if player:GetAttribute("SetHideTitle") ~= true then
				SettingsRemote:FireServer("HideTitle", true)
			end
		end)
	end
	for _, attr in { "OwnedTitles", "SetHideTitle", "Title" } do
		player:GetAttributeChangedSignal(attr):Connect(loadTitle)
	end
	loadTitle()

	-- Panel (user, 2026-10-22; was the Dev + Owner tabs): a value per row, SET (the server checks it).
	-- Dev roles change YOU only. Managers and the owner also give roles, pick a target (anyone in this
	-- server, you included) and have the Title row.
	local function trim(s: string): string
		return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
	end
	local function devInput(parent: Instance, x: number, width: number): TextBox
		local input: TextBox = new("TextBox", {
			Position = UDim2.fromOffset(x, 6),
			Size = UDim2.new(0, width, 0, 28),
			BackgroundColor3 = BAR,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			FontFace = BODY_FONT,
			TextSize = 17,
			TextColor3 = WHITE,
			PlaceholderColor3 = DIM,
			TextXAlignment = Enum.TextXAlignment.Left,
			Text = "",
		}, parent)
		new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, input)
		stroke(input, 0.8)
		return input
	end
	local RED_TEXT, GREEN_TEXT = Color3.fromRGB(255, 110, 110), Color3.fromRGB(110, 255, 140)
	local answerTo: { [string]: TextLabel } = {} -- key -> result label of the panel that sent it last
	local giveResults: { TextLabel } = {} -- the setter's GIVE result labels (OwnerGive answers fill them)

	-- `targets` = pick other players too; `titles` = Managers / owner (the ROLE rows). `flat` = no scroll of
	-- its own, just grows to fit (the owner page scrolls as a whole; nested scrolls fight over input).
	local function buildSetter(page: Instance, top: number, targets: boolean, titles: boolean, flat: boolean?)
		local scroll = if flat
			then new("Frame", {
				Position = UDim2.fromOffset(0, top),
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			}, page)
			else new("ScrollingFrame", {
				Position = UDim2.fromOffset(0, top),
				Size = UDim2.new(1, 0, 1, -top),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
				ScrollBarThickness = 6,
				ScrollBarImageColor3 = DIM,
				CanvasSize = UDim2.new(),
				AutomaticCanvasSize = Enum.AutomaticSize.Y,
			}, page)
		local y = 10
		-- Whose values the rows show and change: you (Dev page), or the picked player (Owner page;
		-- attributes on Player objects replicate to everyone, so their values show as placeholders).
		local target: Player? = player
		local targetId: number? = nil -- nil = yourself
		local placeholders: { () -> () } = {}
		local function refreshPlaceholders()
			for _, f in placeholders do
				f()
			end
		end
		local function header(msg: string)
			text({
				Text = msg,
				TextSize = 16,
				TextColor3 = DIM,
				TextXAlignment = Enum.TextXAlignment.Left,
				TextWrapped = true,
				TextYAlignment = Enum.TextYAlignment.Bottom,
				Position = UDim2.fromOffset(16, y),
				Size = UDim2.new(1, -38, 0, 40),
			}, scroll)
			y += 48
		end
		local results: { [string]: TextLabel } = {}
		local function send(key: string, value: string)
			local label = results[key]
			if not target then
				label.Text, label.TextColor3 = "NO TARGET", RED_TEXT
				return
			end
			label.Text, label.TextColor3 = "...", DIM
			answerTo[key] = label
			Net.get(Net.Names.DevSet):FireServer(key, value, targetId)
		end
		-- One input row: `key` goes to the server, `current(target)` fills the grey placeholder.
		local function row(key: string, label: string, current: (Player) -> string)
			local r = box({ Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -38, 0, 40), BackgroundColor3 = ROW }, scroll)
			y += 46
			stroke(r, 0.9)
			text({ Text = string.upper(label), TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0, 130, 1, 0) }, r)
			local input = devInput(r, 146, 220)
			local function placeholder()
				input.PlaceholderText = if target then current(target) else ""
			end
			table.insert(placeholders, placeholder)
			placeholder()
			local set = button("SET", UDim2.fromOffset(64, 28), UDim2.fromOffset(374, 6), r)
			results[key] = text({ Text = "", TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(448, 0), Size = UDim2.new(1, -456, 1, 0) }, r)
			local function submit()
				local value = trim(input.Text)
				if value ~= "" then
					send(key, value)
				end
			end
			set.Activated:Connect(submit)
			input.FocusLost:Connect(function(enter)
				if enter then
					submit()
				end
			end)
		end
		local targetConn = player.AttributeChanged:Connect(refreshPlaceholders)

		if targets then
			-- ONE target (user, 2026-11-01: "too many places to select name, just look at everyone in the server
			-- and only one target"): every player here is a card; click one and every row below is for them,
			-- the role chips too. No typing names.
			header(if titles then "Click a player: everything below changes them, roles included."
				else "Click a player. On other players you can set cosmetics only (look, clothes, gender, reset).")
			local gridTop = y
			local grid = new("Frame", { Position = UDim2.fromOffset(16, gridTop), Size = UDim2.new(1, -38, 0, 58), BackgroundTransparency = 1 }, scroll)
			local layout = new("UIGridLayout", { CellSize = UDim2.fromOffset(176, 58), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
			-- Everything after the cards hangs off `below`, which moves down as the grid grows (players join).
			local below = new("Frame", { Position = UDim2.fromOffset(0, gridTop + 70), Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, scroll)
			local function fit()
				local h = math.max(58, layout.AbsoluteContentSize.Y)
				grid.Size = UDim2.new(1, -38, 0, h)
				below.Position = UDim2.fromOffset(0, gridTop + h + 12)
			end
			layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fit)
			scroll = below
			y = 0

			local rebuildPlayers: () -> ()
			local function setTarget(p: Player)
				target = p
				targetId = if p ~= player then p.UserId else nil
				targetConn:Disconnect()
				targetConn = p.AttributeChanged:Connect(refreshPlaceholders)
				rebuildPlayers()
				refreshPlaceholders()
			end
			function rebuildPlayers()
				for _, c in grid:GetChildren() do
					if c:IsA("GuiObject") then
						c:Destroy()
					end
				end
				local list = Players:GetPlayers()
				table.sort(list, function(x, z)
					return if x == player then true elseif z == player then false else string.lower(x.DisplayName) < string.lower(z.DisplayName)
				end)
				for i, p in list do
					if p.Parent == Players then
						local on = p == target
						local card = box({ LayoutOrder = i, BackgroundColor3 = if on then ACCENT else ROW }, grid)
						stroke(card, if on then 0.2 else 0.85)
						text({ Text = if p == player then `{p.DisplayName} (YOU)` else p.DisplayName, TextSize = 17, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 24) }, card)
						local role = p:GetAttribute("Roles") -- every role they hold, highest first
						role = if typeof(role) == "string" then string.gsub(role, ",", ", ") else nil
						text({ Text = `@{p.Name}` .. (if typeof(role) == "string" and role ~= "Player" then `  ·  {string.upper(role)}` else ""), TextSize = 13, TextColor3 = if on then WHITE else DIM, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(10, 31), Size = UDim2.new(1, -20, 0, 20) }, card)
						local hit = new("TextButton", { Text = "", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, card)
						hit.Activated:Connect(function()
							setTarget(p)
						end)
					end
				end
			end
			Players.PlayerAdded:Connect(function()
				rebuildPlayers()
			end)
			Players.PlayerRemoving:Connect(function(p)
				if p == target then
					task.defer(setTarget, player) -- they left: back to you
				else
					task.defer(rebuildPlayers)
				end
			end)
			rebuildPlayers()
			fit()

			if titles then
				-- Roles (Managers / owner): chips for the picked player; their current role is red.
				local roleRow = box({ Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -38, 0, 40), BackgroundColor3 = ROW }, scroll)
				y += 46
				stroke(roleRow, 0.9)
				text({ Text = "ROLE", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0, 130, 1, 0) }, roleRow)
				local roleResult = text({ Text = "", TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(146, 0), Size = UDim2.new(1, -154, 1, 0) }, roleRow)
				local order = Paths.data("Roles").order
				local chipRows = math.ceil(#order / 6)
				local chips = box({ Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -38, 0, chipRows * 40), BackgroundTransparency = 1 }, scroll)
				y += chipRows * 40 + 10
				new("UIGridLayout", { CellSize = UDim2.fromOffset(110, 32), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder }, chips)
				-- One chip per role; the ones the target holds are red (several at once). Click = add / take away
				-- that role (PLAYER = take them all). Rebuilt on every change so hover can't repaint them.
				local function rebuildChips()
					for _, c in chips:GetChildren() do
						if c:IsA("GuiButton") then
							c:Destroy()
						end
					end
					local raw = target and target:GetAttribute("Roles")
					local held = if typeof(raw) == "string" then string.split(raw, ",") else {}
					for i, role in order do
						local b = button(string.upper(role), UDim2.new(), UDim2.new(), chips, table.find(held, role) ~= nil)
						b.LayoutOrder = i
						b.Activated:Connect(function()
							if target then
								roleResult.Text, roleResult.TextColor3 = "...", DIM
								Net.get(Net.Names.SetRole):FireServer(tostring(target.UserId), role)
							end
						end)
					end
				end
				table.insert(placeholders, rebuildChips)
				Net.get(Net.Names.RoleResult).OnClientEvent:Connect(function(ok: boolean, message: string)
					roleResult.Text = string.upper(tostring(message))
					roleResult.TextColor3 = if ok then GREEN_TEXT else RED_TEXT
					rebuildPlayers() -- the role on their card
				end)
				refreshPlaceholders()
			end
		else
			header("Changes apply to you only. Managers set other players and roles.")
		end

		-- Reset: rerolls the whole look for free and clears undo. Tap twice to confirm.
		local resetRow = box({ Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -38, 0, 40), BackgroundColor3 = ROW }, scroll)
		y += 54
		stroke(resetRow, 0.9)
		text({ Text = "RESET LOOK", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0, 130, 1, 0) }, resetRow)
		local resetButton = button("REROLL ALL", UDim2.fromOffset(292, 28), UDim2.fromOffset(146, 6), resetRow, true)
		results.Reset = text({ Text = "", TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(448, 0), Size = UDim2.new(1, -456, 1, 0) }, resetRow)
		local armedAt = -math.huge
		resetButton.Activated:Connect(function()
			if os.clock() - armedAt > 3 then
				armedAt = os.clock()
				resetButton.Text = "CONFIRM? (NO UNDO)"
				task.delay(3, function()
					if os.clock() - armedAt >= 3 then
						resetButton.Text = "REROLL ALL"
					end
				end)
				return
			end
			armedAt = -math.huge
			resetButton.Text = "REROLL ALL"
			send("Reset", "look")
		end)

		-- (The Title row was removed, user 2026-10-28: titles come from roles only.)
		header("Appearance: any catalog id, or nil to wear nothing. Skin Tone = BrickColor name. Face can be Headless. Shirt/Pants: default = their gender's uniform.")
		for _, slot in Appearance.order do
			row(slot, Appearance.slots[slot].label, function(p)
				return tostring(p:GetAttribute("Look_" .. slot) or "")
			end)
		end
		-- Clothes aren't appearance slots (no rerolls / Catalog): unset = their gender's uniform.
		for _, field in { "Shirt", "Pants" } do
			row(field, field, function(p)
				local v = p:GetAttribute("Look_" .. field)
				return if v == nil then "default" else tostring(v)
			end)
		end
		y += 8
		header(if isOwner
			then "Bux: a whole number. Gender, style and traits: a name (any case); style + traits change what they wear, not the locker. Traits take 'none' to empty the slot."
			else "Gender, style and traits: a name (any case); style + traits change what they wear, not the locker. Traits take 'none' to empty the slot.")
		-- Currencies are owner only (user, 2026-11-03: not Managers or Developers); the server gates it too.
		if isOwner then
			row("Bux", "Bux", function(p)
				return tostring(p:GetAttribute("Bux") or 0)
			end)
		end
		row("Gender", "Gender", function(p)
			return tostring(p:GetAttribute("Gender") or "")
		end)
		row("Style", "Style", function(p)
			local s = p:GetAttribute("Style")
			return if typeof(s) == "string" then s else D.DEFAULT_STYLE
		end)
		for i = 1, D.PERK_SLOTS do
			row("Trait" .. i, "Trait " .. i, function(p)
				local raw = p:GetAttribute("PerkSlots")
				local id = if typeof(raw) == "string" then string.split(raw, ",")[i] else nil
				return if id and id ~= "" then id else "none"
			end)
		end
		-- Height (owner only, user 2026-11-02; D.HEIGHT): a body scale, 1 = normal. The server clamps and gates it.
		if isOwner then
			row("Height", `Height {D.HEIGHT.min}-{D.HEIGHT.max}`, function(p)
				return tostring(p:GetAttribute("Height") or 1)
			end)
		end

		-- Furniture (user, 2026-11-01): type to search by name, set how many, click one to give it to the
		-- target's apartment bag (devSet "Furniture" = "<id>:<amount>"). Last section: the grid can grow.
		y += 8
		-- GIVE (owner only, user 2026-11-01: "down to the same level"): REROLLS / BUX for the target, sent by
		-- UserId ("#<id>", AdminService.give) so it can't land on someone with a similar name.
		if isOwner then
			header("Give the target rerolls or Bux (adds to what they have).")
			local give = box({ Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -38, 0, 40), BackgroundColor3 = ROW }, scroll)
			y += 46
			stroke(give, 0.9)
			text({ Text = "GIVE", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0, 130, 1, 0) }, give)
			local amount = devInput(give, 146, 80)
			amount.PlaceholderText = "amount"
			local rerolls = button("REROLLS", UDim2.fromOffset(96, 28), UDim2.fromOffset(234, 6), give, true)
			local bux = button("BUX", UDim2.fromOffset(64, 28), UDim2.fromOffset(336, 6), give, true)
			local giveResult = text({ Text = "", TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(410, 0), Size = UDim2.new(1, -418, 1, 0) }, give)
			table.insert(giveResults, giveResult)
			local function giveTo(kind: string)
				if not target then
					giveResult.Text, giveResult.TextColor3 = "NO TARGET", RED_TEXT
					return
				end
				giveResult.Text, giveResult.TextColor3 = "...", DIM
				Net.get(Net.Names.OwnerGive):FireServer(`#{target.UserId}`, kind, trim(amount.Text))
			end
			rerolls.Activated:Connect(function()
				giveTo("Spins")
			end)
			bux.Activated:Connect(function()
				giveTo("Bux")
			end)
		end
		header("Furniture: search by name, set how many, then click one to give it.")
		local furnRow = box({ Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -38, 0, 40), BackgroundColor3 = ROW }, scroll)
		y += 46
		stroke(furnRow, 0.9)
		text({ Text = "FURNITURE", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0, 130, 1, 0) }, furnRow)
		local furnSearch = devInput(furnRow, 146, 220)
		furnSearch.PlaceholderText = "search, e.g. dj"
		local furnAmount = devInput(furnRow, 374, 64)
		furnAmount.PlaceholderText = "1"
		results.Furniture = text({ Text = "", TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(448, 0), Size = UDim2.new(1, -456, 1, 0) }, furnRow)
		local furnGrid = new("Frame", { Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -38, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, scroll)
		new("UIGridLayout", { CellSize = UDim2.fromOffset(170, 34), CellPadding = UDim2.fromOffset(8, 8), SortOrder = Enum.SortOrder.LayoutOrder }, furnGrid)
		local function rebuildFurniture()
			for _, c in furnGrid:GetChildren() do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
			local q = string.lower(trim(furnSearch.Text))
			local ids = {}
			for _, id in Paths.furnitureIds() do
				local def = Paths.furniture(id)
				if def and (q == "" or string.find(string.lower(def.name), q, 1, true) or string.find(string.lower(id), q, 1, true)) then
					table.insert(ids, id)
				end
			end
			table.sort(ids, function(x, z)
				return (Paths.furniture(x) :: any).name < (Paths.furniture(z) :: any).name
			end)
			for i, id in ids do
				local b = button(string.upper((Paths.furniture(id) :: any).name), UDim2.new(), UDim2.new(), furnGrid)
				b.LayoutOrder = i
				b.TextTruncate = Enum.TextTruncate.AtEnd
				b.Activated:Connect(function()
					local n = tonumber(trim(furnAmount.Text)) or 1
					n = math.clamp(math.floor(n), 1, 999)
					send("Furniture", `{id}:{n}`)
				end)
			end
		end
		furnSearch:GetPropertyChangedSignal("Text"):Connect(rebuildFurniture)
		rebuildFurniture()
		new("UIPadding", { PaddingBottom = UDim.new(0, 12) }, scroll)
	end
	-- Dev roles see the self-only setter; Staff ("SetCosmetics") also others' cosmetics; Managers / the
	-- owner the roles + full setter ("Manage").
	local selfPanel = box({ Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, pages.Panel)
	local cosmeticPanel = box({ Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, pages.Panel)
	local managePanel = box({ Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, pages.Panel)
	local function refreshPanel()
		local manage = player:GetAttribute("Manage") == true
		local cosmetics = not manage and player:GetAttribute("SetCosmetics") == true
		selfPanel.Visible = not manage and not cosmetics
		cosmeticPanel.Visible = cosmetics
		managePanel.Visible = manage
	end
	player:GetAttributeChangedSignal("Manage"):Connect(refreshPanel)
	player:GetAttributeChangedSignal("SetCosmetics"):Connect(refreshPanel)
	refreshPanel()
	-- Owner row (user, 2026-10-27), only for D.OWNER_IDS (not a role), on top of whichever Panel page they get:
	--   VENDING  RIG NEXT CAN: the next vending buy, anyone's, fires the can at the buyer (SodaService)
	-- (GIVE REROLLS / BUX is in the setter now, on the clicked target, next to FURNITURE.)
	local rigResults: { TextLabel } = {}
	local function resultLabel(row: Instance, x: number): TextLabel
		return text({ Text = "", TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(x, 0), Size = UDim2.new(1, -(x + 8), 1, 0) }, row)
	end
	local function pending(label: TextLabel)
		label.Text = "..."
		label.TextColor3 = DIM
	end
	ownerRowsIn = function(parent: Instance, y: number)
		local row = box({ Position = UDim2.fromOffset(16, y), Size = UDim2.new(1, -38, 0, 40), BackgroundColor3 = ROW }, parent)
		stroke(row, 0.9)
		text({ Text = "VENDING", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0, 130, 1, 0) }, row)
		local rig = button("RIG NEXT CAN", UDim2.fromOffset(220, 28), UDim2.fromOffset(146, 6), row, true)
		local rigResult = resultLabel(row, 378)
		table.insert(rigResults, rigResult)
		rig.Activated:Connect(function()
			pending(rigResult)
			Net.get(Net.Names.RigVending):FireServer()
		end)
	end
	local function answer(labels: { TextLabel }, ok: boolean, message: string)
		for _, r in labels do
			r.Text = string.upper(tostring(message))
			r.TextColor3 = if ok then GREEN_TEXT else RED_TEXT
		end
	end
	Net.get(Net.Names.RigVending).OnClientEvent:Connect(function(ok: boolean, message: string)
		answer(rigResults, ok, message)
	end)
	Net.get(Net.Names.OwnerGive).OnClientEvent:Connect(function(ok: boolean, message: string)
		answer(giveResults, ok, message)
	end)
	local selfTop = 0
	if isOwner then
		ownerRowsIn(selfPanel, 10)
		ownerRowsIn(cosmeticPanel, 10)
		selfTop = 10 + OWNER_ROWS_H
	end
	buildSetter(selfPanel, selfTop, false, false)
	buildSetter(cosmeticPanel, selfTop, true, false)
	devAnswer = function(slot, id)
		local label = typeof(slot) == "string" and answerTo[slot]
		if label then
			label.Text = if slot == "Furniture" and id ~= nil then `GAVE (THEY OWN {id})` elseif id ~= nil then "SET" else "INVALID"
			label.TextColor3 = if id ~= nil then GREEN_TEXT else RED_TEXT
			if id ~= nil then
				task.delay(0.4, function()
					if gui.Enabled then
						rebuildPreview()
					end
				end)
			end
		end
	end

	-- Roles: set anyone's role (RoleService) by UserId or username, online or not. The server checks
	-- you can (owner: any role; Manager: roles below Manager); LOOKUP shows their current role.
	-- The whole manage / owner page scrolls as one (user, 2026-10-27): roles, owner rows and the setter.
	local ownerPage = new("ScrollingFrame", {
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = DIM,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, managePanel)
	local ownerY = 10
	text({
		Text = "Every role but Player rerolls free; Staff / Developer get this Panel for themselves; Managers for anyone. Pick a player below to change them or give a role.",
		TextSize = 16,
		TextColor3 = DIM,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Bottom,
		Position = UDim2.fromOffset(16, ownerY),
		Size = UDim2.new(1, -38, 0, 40),
	}, ownerPage)
	ownerY += 48
	-- Under the roles (and the owner rows, for owners): change any player in this server, titles included
	-- (Managers / owner; the server checks).
	if isOwner then
		ownerRowsIn(ownerPage, ownerY)

		-- Everyone with a role, online or not, STRIP = back to Player right away (user, 2026-10-27;
		-- RoleService.list / RoleList remote). Opens over this page.
		local rolesRow = box({ Position = UDim2.fromOffset(16, ownerY + OWNER_ROWS_H), Size = UDim2.new(1, -38, 0, 40), BackgroundColor3 = ROW }, ownerPage)
		stroke(rolesRow, 0.9)
		text({ Text = "ROLES", TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(0, 130, 1, 0) }, rolesRow)
		local showAll = button("SHOW EVERYONE", UDim2.fromOffset(220, 28), UDim2.fromOffset(146, 6), rolesRow, true)

		local sheet = box({ Size = UDim2.fromScale(1, 1), BackgroundColor3 = BAR, ZIndex = 20, Visible = false }, managePanel) -- covers the panel, doesn't scroll with it
		-- The menu is Global ZIndex: everything on the sheet must sit above it (and the page under it).
		local function raise()
			for _, d in sheet:GetDescendants() do
				if d:IsA("GuiObject") then
					d.ZIndex = 21
				end
			end
		end
		stroke(sheet, 0.6)
		text({ Text = "EVERYONE WITH A ROLE", TextSize = 20, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(16, 8), Size = UDim2.new(1, -260, 0, 32) }, sheet)
		local status = text({ Text = "", TextSize = 15, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(16, 40), Size = UDim2.new(1, -32, 0, 22) }, sheet)
		local refresh = button("REFRESH", UDim2.fromOffset(100, 28), UDim2.new(1, -228, 0, 10), sheet)
		local close = button("CLOSE", UDim2.fromOffset(90, 28), UDim2.new(1, -118, 0, 10), sheet, true)
		local list = new("ScrollingFrame", {
			Position = UDim2.fromOffset(0, 68),
			Size = UDim2.new(1, 0, 1, -68),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			ScrollBarThickness = 6,
			ScrollBarImageColor3 = DIM,
			CanvasSize = UDim2.new(),
			AutomaticCanvasSize = Enum.AutomaticSize.Y,
		}, sheet)
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, list)
		new("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 22), PaddingBottom = UDim.new(0, 12) }, list)
		raise()

		local function ask(action: string, userId: number?)
			status.Text = "LOADING..."
			status.TextColor3 = DIM
			Net.get(Net.Names.RoleList):FireServer(action, userId)
		end
		showAll.Activated:Connect(function()
			sheet.Visible = true
			ask("List")
		end)
		refresh.Activated:Connect(function()
			ask("List")
		end)
		close.Activated:Connect(function()
			sheet.Visible = false
		end)
		Net.get(Net.Names.RoleList).OnClientEvent:Connect(function(ok: boolean, message: string, entries: { any }?)
			status.Text = string.upper(tostring(message))
			status.TextColor3 = if ok then GREEN_TEXT else RED_TEXT
			if not entries then
				return -- a failed strip keeps the list as it was
			end
			for _, c in list:GetChildren() do
				if c:IsA("GuiObject") then
					c:Destroy()
				end
			end
			for i, e in entries do
				local row = box({ Size = UDim2.new(1, 0, 0, 40), BackgroundColor3 = ROW, LayoutOrder = i }, list)
				stroke(row, 0.9)
				text({ Text = `{e.name}  ({e.id})`, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, TextTruncate = Enum.TextTruncate.AtEnd, Position = UDim2.fromOffset(12, 0), Size = UDim2.new(1, -260, 1, 0) }, row)
				text({ Text = string.upper(e.role), TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.new(1, -240, 0, 0), Size = UDim2.new(0, 130, 1, 0) }, row)
				local strip = button("STRIP", UDim2.fromOffset(90, 28), UDim2.new(1, -100, 0, 6), row, true)
				strip.Activated:Connect(function()
					ask("Strip", e.id)
				end)
			end
			raise()
		end)
	end
	buildSetter(ownerPage, ownerY + (if isOwner then OWNER_ROWS_H + 46 else 0), true, true, true)

	-- Catalog page (devs): every item each gender can roll, per slot, with rarity and real roll odds.
	local catalog = pages.Catalog
	local catGender = D.GENDERS[1]
	local catButtons: { [string]: TextButton } = {}
	local catScroll = new("ScrollingFrame", {
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 1, -52),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = DIM,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
	}, catalog)
	new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, catScroll)
	new("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 22), PaddingBottom = UDim.new(0, 12) }, catScroll)

	local rarityRank: { [string]: number } = {}
	for i, r in Rarity.ORDER do
		rarityRank[r] = i
	end
	local function pct(p: number): string
		return if p >= 0.1 then string.format("%.1f%%", p * 100) elseif p >= 0.001 then string.format("%.2f%%", p * 100) else string.format("%.3f%%", p * 100)
	end

	local function buildCatalog()
		for _, c in catScroll:GetChildren() do
			if c:IsA("GuiObject") then
				c:Destroy()
			end
		end
		for order, slot in Appearance.order do
			local def = Appearance.slots[slot]
			local items = Appearance.eligible(slot, catGender)
			local odds, none = Rarity.odds(items, def.none) -- per-reroll chances, nothing included
			local entries = {}
			for i, item in items do
				table.insert(entries, { item = item, chance = odds[i] })
			end
			table.sort(entries, function(a, b)
				local ra, rb = rarityRank[a.item.rarity or "Common"] or 0, rarityRank[b.item.rarity or "Common"] or 0
				return if ra ~= rb then ra > rb else a.item.name < b.item.name
			end)

			local section = box({ LayoutOrder = order, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, catScroll)
			new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, section)
			local headerText = `{string.upper(def.label)}  ({#items})`
			if none > 0 then
				headerText ..= `   {def.noneName or "None"}: {pct(none)}`
			end
			text({ LayoutOrder = 1, Text = headerText, FontFace = BOLD_FONT, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 20) }, section)
			local grid = box({ LayoutOrder = 2, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, section)
			new("UIGridLayout", { CellSize = UDim2.fromOffset(106, 138), CellPadding = UDim2.fromOffset(6, 6), SortOrder = Enum.SortOrder.LayoutOrder }, grid)
			for i, e in entries do
				local item = e.item
				local color = Rarity.color(item.rarity)
				local card = box({ LayoutOrder = i, BackgroundColor3 = Rarity.tint(item.rarity, ROW) }, grid)
				stroke(card, 0.9)
				local thumb = new("ImageLabel", { Position = UDim2.new(0.5, -32, 0, 8), Size = UDim2.fromOffset(64, 64), BackgroundColor3 = BAR, BorderSizePixel = 0, ScaleType = Enum.ScaleType.Fit }, card)
				if slot == "SkinTone" then
					thumb.BackgroundColor3 = BrickColor.new(item.id).Color
				else
					local thumbId = item.thumb or item.id
					thumb.Image = if typeof(thumbId) == "number" then `rbxthumb://type=Asset&id={thumbId}&w=150&h=150` else ""
				end
				local nameLabel = text({ Text = item.name, TextScaled = true, TextWrapped = true, Position = UDim2.fromOffset(4, 74), Size = UDim2.new(1, -8, 0, 28) }, card)
				new("UITextSizeConstraint", { MaxTextSize = 14 }, nameLabel)
				local tier = string.upper(item.rarity or "Common") .. (if item.gender then " · " .. string.upper(string.sub(item.gender, 1, 1)) else "")
				text({ Text = tier, TextSize = 13, TextColor3 = color, Position = UDim2.fromOffset(0, 102), Size = UDim2.new(1, 0, 0, 14) }, card)
				text({ Text = pct(e.chance), TextSize = 13, TextColor3 = DIM, Position = UDim2.fromOffset(0, 117), Size = UDim2.new(1, 0, 0, 14) }, card)
			end
		end

		-- Styles (user, 2026-10-25): every obtainable style with its style perks (always on while you use it).
		-- `rollable = false` styles (BanHammer, dev-only) are left out, like the reroll pool (stylePool).
		local styles = {}
		for _, id in Paths.styleIds() do
			local style = Paths.style(id)
			if style.rollable ~= false then
				table.insert(styles, style)
			end
		end
		table.sort(styles, function(a, b)
			local ra, rb = rarityRank[a.rarity or "Common"] or 0, rarityRank[b.rarity or "Common"] or 0
			return if ra ~= rb then ra > rb else a.name < b.name
		end)
		local section = box({ LayoutOrder = #Appearance.order + 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = 1 }, catScroll)
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }, section)
		text({ LayoutOrder = 0, Text = `STYLES  ({#styles})   perks are always on while you fight with the style`, FontFace = BOLD_FONT, TextSize = 15, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 20) }, section)
		for i, style in styles do
			local card = box({ LayoutOrder = i, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundColor3 = Rarity.tint(style.rarity, ROW) }, section)
			stroke(card, 0.9)
			new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10), PaddingTop = UDim.new(0, 8), PaddingBottom = UDim.new(0, 8) }, card)
			new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }, card)
			text({ LayoutOrder = 0, Text = `{styleLabel(style.name)}   <font color="#{Rarity.color(style.rarity):ToHex()}">{string.upper(style.rarity or "Common")}</font>`, RichText = true, FontFace = BOLD_FONT, TextSize = 16, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 20) }, card)
			local perks = style.perks or {}
			if #perks == 0 then
				text({ LayoutOrder = 1, Text = "No style perks.", TextSize = 14, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, Size = UDim2.new(1, 0, 0, 18) }, card)
			end
			for j, id in perks do
				local perk = if Paths.findPerk(id) then Paths.perk(id) else nil
				local function esc(s: string): string -- RichText
					return (string.gsub(string.gsub(string.gsub(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
				end
				local name = esc(if perk then perk.name else id)
				local desc = esc(if perk and perk.desc then perk.desc else "")
				text({
					LayoutOrder = j, RichText = true, TextWrapped = true, TextSize = 14, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top,
					Text = `<b>{name}</b>  <font color="#{DIM:ToHex()}">{desc}</font>`, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y,
				}, card)
			end
		end
	end

	text({ Text = "Rolls for", TextSize = 15, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(16, 12), Size = UDim2.fromOffset(70, 30) }, catalog)
	for i, g in D.GENDERS do
		local b = button(string.upper(g), UDim2.fromOffset(100, 30), UDim2.fromOffset(86 + (i - 1) * 108, 12), catalog)
		catButtons[g] = b
		b.Activated:Connect(function()
			if catGender ~= g then
				catGender = g
				for other, ob in catButtons do
					ob.TextColor3 = if other == g then WHITE else DIM
				end
				buildCatalog()
			end
		end)
		b.TextColor3 = if g == catGender then WHITE else DIM
	end
	text({ Text = "% = chance per roll (ignores 'never the same item twice'). M/F = gender-locked.", TextSize = 14, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Left, Position = UDim2.fromOffset(310, 12), Size = UDim2.new(1, -326, 0, 30), TextWrapped = true }, catalog)
	local catalogBuilt = false
	tabButtons.Catalog.Activated:Connect(function()
		if not catalogBuilt then -- thumbnails only load once a dev opens it
			catalogBuilt = true
			buildCatalog()
		end
	end)

	gui.Parent = player:WaitForChild("PlayerGui")
	select(current)
	refreshDev()

	-- Open / close. Two layers: the side bar (arrow; slides the combat HUD out) and the page window
	-- (picking a menu). The window needs the bar, and closing the bar closes the window.
	local Hud = Paths.client("HudController")
	local shiftLockWasOn = false
	local function setShiftLock(on: boolean)
		local scripts = player:FindFirstChild("PlayerScripts")
		local module = scripts and scripts:FindFirstChild("CustomShiftLock")
		local ev = module and module:FindFirstChild("ToggleShiftLock", true)
		if ev and ev:IsA("BindableEvent") then
			ev:Fire(on)
		end
	end

	local spinConn: RBXScriptConnection? = nil
	local isOpen = false
	local barOpen = false
	local beatConn: RBXScriptConnection? = nil
	local setOpen: (boolean) -> ()
	local fitScreen: () -> () -- set at the bottom
	-- Blurs the world (not the UI) behind an open page. Client-made, so it never replicates.
	local blur = new("BlurEffect", { Name = "MidoriMenuBlur", Size = 0 }, game:GetService("Lighting"))

	local function setBar(open: boolean)
		if open == barOpen then
			return
		end
		barOpen = open
		player:SetAttribute("MenuOpen", open or nil) -- SkateController frees the mouse while it's up
		Hud.setOut(open)
		tween(sideBar, 0.35, { AnchorPoint = Vector2.new(if open then 0 else 1, 0) }, if open then Enum.EasingStyle.Back else Enum.EasingStyle.Quad)
		tween(arrow, 0.3, { Rotation = if open then 180 else 0 }, Enum.EasingStyle.Back)
		arrow.Modal = open -- frees the mouse while the bar is out
		if beatConn then
			beatConn:Disconnect()
			beatConn = nil
		end
		if open then
			-- the red slab bops on the HUD's beat while the bar is out
			beatConn = RunService.RenderStepped:Connect(function()
				local phase = (os.clock() * D.HUD_BPM / 60) % 1
				selectorScale.Scale = 1 + 0.05 * math.exp(-phase * 6)
			end)
			shiftLockWasOn = UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
			if shiftLockWasOn then
				setShiftLock(false)
			end
		else
			setOpen(false)
			if shiftLockWasOn then
				shiftLockWasOn = false
				setShiftLock(true)
			end
		end
	end

	setOpen = function(open: boolean)
		if open == isOpen then
			return
		end
		isOpen = open
		if open then
			setBar(true)
			gui.Enabled = true
			fitScreen()
			task.defer(fitScreen) -- once the just-enabled gui has its real (safe-area) size
			status.Text = ""
			holderScale.Scale = 0.85
			holder.Position = HOME + UDim2.fromOffset(-30, 0)
			tween(holderScale, 0.28, { Scale = 1 }, Enum.EasingStyle.Back)
			tween(holder, 0.28, { Position = HOME }, Enum.EasingStyle.Back)
			tween(blur, 0.25, { Size = BLUR })
			rebuildPreview()
			spinConn = RunService.RenderStepped:Connect(function(dt)
				angle += dt * PREVIEW_SPIN
				if previewModel then
					previewModel:PivotTo(CFrame.Angles(0, angle, 0))
				end
			end)
		else
			if spinConn then
				spinConn:Disconnect()
				spinConn = nil
			end
			tween(blur, 0.2, { Size = 0 })
			tween(holder, 0.12, { Position = HOME + UDim2.fromOffset(-20, 0) }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			tween(holderScale, 0.12, { Scale = 0.9 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In).Completed:Connect(function(state)
				if state == Enum.PlaybackState.Completed and not isOpen then
					gui.Enabled = false
					holderScale.Scale = 1
					holder.Position = HOME
				end
			end)
		end
	end

	-- A menu in the list: opening rolls up from under the last page; the open one again closes it;
	-- another one rolls past the pages between.
	openTab = function(tab: string)
		if isOpen and tab == current then
			setOpen(false)
		elseif isOpen then
			select(tab)
		else
			setOpen(true)
			select(tab, #listed() + 1)
		end
	end

	close.Activated:Connect(function()
		setOpen(false)
	end)
	arrow.Activated:Connect(function()
		setBar(not barOpen)
	end)
	local function inside(g: GuiObject, p: Vector3): boolean
		local pos, size = g.AbsolutePosition, g.AbsoluteSize
		return p.X >= pos.X and p.Y >= pos.Y and p.X <= pos.X + size.X and p.Y <= pos.Y + size.Y
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		-- tap / click outside the window and the side bar closes the page (no key opens the menu: user, 2026-11-01)
		local t = input.UserInputType
		if isOpen and (t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch) then
			local p = input.Position
			if not processed and not inside(window, p) and not inside(sideBar, p) and not inside(arrow, p) then
				setOpen(false)
			end
		end
	end)
	player.CharacterAdded:Connect(function()
		if isOpen then
			task.delay(1, rebuildPreview)
		end
	end)

	-- Wallet (bottom of the side bar only, not the page window): your Bux and Rerolls. The icons are
	-- cloned from Assets.2d templates (never copied by id).
	local wallet = art("wallet", { Position = UDim2.fromOffset(14, 846), Size = UDim2.fromOffset(MENU_ART.wallet.w, MENU_ART.wallet.h), Rotation = -4 }, sideBar)

	local function commas(n: number): string
		local s = tostring(math.floor(n)):reverse():gsub("(%d%d%d)", "%1,"):reverse()
		return (s:gsub("^,", ""))
	end
	-- One icon + amount row. The amount counts up/down to a new value and the icon pops.
	local function counter(y: number, iconName: string, label: string, attr: string, infinite: () -> boolean, alsoWatch: string?)
		local icon = (Paths.Assets:WaitForChild("2d"):WaitForChild(iconName) :: ImageLabel):Clone()
		-- rows follow the slab's lean: the lower row sits further left
		local x0 = 60 - (y - 40) * 0.45
		icon.AnchorPoint = Vector2.new(0, 0.5)
		icon.Position = UDim2.fromOffset(x0, y)
		icon.Size = UDim2.fromOffset(34, 34)
		icon.Parent = wallet
		local pop = new("UIScale", {}, icon)
		text({ Text = label, FontFace = MENU_FONT, TextSize = 24, TextColor3 = BLACK, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Left, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(x0 + 42, y + 2), Size = UDim2.fromOffset(110, 34) }, wallet)
		local amount = text({ Text = "0", FontFace = MENU_FONT, TextSize = 30, TextColor3 = ACCENT, TextStrokeTransparency = 1, TextXAlignment = Enum.TextXAlignment.Right, AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromOffset(x0 + 120, y + 2), Size = UDim2.fromOffset(100, 34) }, wallet)
		local shown: number? = nil
		local counting: RBXScriptConnection? = nil
		local function refresh()
			if infinite() then
				shown = nil -- leaving ∞ shows the real count straight away
				amount.Text = "∞"
				amount.FontFace = Font.fromEnum(Enum.Font.GothamBlack) -- LuckiestGuy draws ∞ tiny
				return
			end
			amount.FontFace = MENU_FONT
			local v = player:GetAttribute(attr)
			local target = if typeof(v) == "number" then v else 0
			if shown == nil or shown == target then
				shown = target
				amount.Text = commas(target)
				return
			end
			local from, t0 = shown, os.clock()
			shown = target
			pop.Scale = 1.3
			tween(pop, 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
			if counting then
				counting:Disconnect()
			end
			counting = RunService.RenderStepped:Connect(function()
				local k = math.min(1, (os.clock() - t0) / 0.4)
				amount.Text = commas(from + (target - from) * (1 - (1 - k) ^ 3))
				if k >= 1 and counting then
					counting:Disconnect()
					counting = nil
				end
			end)
		end
		player:GetAttributeChangedSignal(attr):Connect(refresh)
		if alsoWatch then
			player:GetAttributeChangedSignal(alsoWatch):Connect(refresh)
		end
		refresh()
	end
	counter(40, "Bux", "BUX", "Bux", function()
		return false
	end)
	counter(80, "Rerolls", "REROLLS", "Spins", freeSpins, "FreeSpins") -- rerolls are saved as Spins; ∞ while free
	side.Parent = player:WaitForChild("PlayerGui")
	local UiSounds = Paths.client("UiSounds")
	UiSounds.watch(gui) -- page window (incl. buttons built later: catalog, player list)
	UiSounds.watch(side) -- side bar items + arrow

	-- Any screen: the side bar is scaled to the screen height; the window is scaled to fit inside the
	-- safe area (phones / small windows shrink it, big screens grow it up to MAX_FIT), centred, and only
	-- pushed right as far as it takes to clear the bar. Applied straight to `fit`, open or not.
	fitScreen = function()
		local vp = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
		barScale.Scale = vp.Y / BAR_DESIGN.Y
		local area = if gui.AbsoluteSize.X > 0 then gui.AbsoluteSize else vp -- the safe area
		local barW = (BAR_DESIGN.X + 60) * barScale.Scale - gui.AbsolutePosition.X -- bar + arrow, in the gui's own space
		local menuFit = math.min(MAX_FIT, (area.Y - 2 * SCREEN_MARGIN) / WINDOW.Y, (area.X - barW - 2 * SCREEN_MARGIN) / WINDOW.X)
		local x = math.max(area.X / 2, barW + SCREEN_MARGIN + WINDOW.X * menuFit / 2)
		fitScale.Scale = menuFit
		fit.Position = UDim2.new(0, x, 0.5, 0)
	end
	local function watchCamera()
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(fitScreen)
		end
		fitScreen()
	end
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	gui:GetPropertyChangedSignal("AbsoluteSize"):Connect(fitScreen)
	watchCamera()
end

return MenuController
