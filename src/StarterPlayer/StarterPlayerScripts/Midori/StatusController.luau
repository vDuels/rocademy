--!strict
-- Dash meters floating just left of your character (user, 2026-10-29: a dash cooldown bar again, both bars
-- longer, sized in STUDS so they scale with the world like the character instead of staying a fixed pixel
-- size; Chambered Dash sits to the LEFT of the dash bar). One BillboardGui, two slim upright bars:
--   right: DASH COOLDOWN, only while the dash recharges; fills bottom-up, pops when it's back, fades out.
--   left:  CHAMBERED DASH (perk only), fills in sync with the server's chamber, rainbow + pop when full,
--          fades out while empty or out of combat mode.
-- CombatController reports our own dashes instantly (dashUsed / chamberSpent); the server's replicated
-- attributes correct anything the prediction got wrong.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))

local CHAMBER_BLUE = Color3.fromRGB(120, 170, 220)
local DASH_WHITE = Color3.fromRGB(245, 245, 245)
local RAINBOW_SPEED = 0.6 -- hue cycles per second once the chamber is full
local CHAMBER_SNAP = 0.1 -- re-sync to the server's chamber if we drift further than this
local CHAMBER_PERK = "ChamberedDash"
-- Studs (BillboardGui scale size): each bar BAR_W x BAR_H, the board leaves room for the tilt + pop.
local BAR_W, BAR_H = 0.3, 3.4 -- user, 2026-10-29: longer (was 12 x 84 px, ~0.3 x 2.1 studs up close)
local BOARD_W, BOARD_H = 1.5, 4.4
local GAP = 0.6 -- studs between the two bars' centres
local OFFSET = Vector3.new(-2.8, 0.4, 0) -- studs, camera space: left of the character on screen
local READY_HOLD = 2 -- the dash bar stays up (full) this long after the dash is back (user, 2026-10-29; was 0.3)

local StatusController = {}

type Bar = { box: Frame, fill: Frame, scale: UIScale, vis: number, pop: number }

-- Live numbers for the local character.
local dashCooldownUntil = 0
local dashTotal = 1 -- length of the current cooldown (for the fill)
local chamber = 0 -- 0-1, predicted between server updates
local chamberFillTime = 1
local hasChamber = false
local wasFull = false
local wasReady = true
local charConns: { RBXScriptConnection } = {}

local board: BillboardGui
local chamberBar: Bar
local dashBar: Bar

local function now(): number
	return workspace:GetServerTimeNow()
end

-- One black slab with a Persona tilt; the fill grows from the bottom. `x` = its centre across the board (0-1).
local function makeBar(x: number): Bar
	local box = Instance.new("Frame")
	box.AnchorPoint = Vector2.new(0.5, 0.5)
	box.Position = UDim2.fromScale(x, 0.5)
	box.Size = UDim2.fromScale(BAR_W / BOARD_W, BAR_H / BOARD_H)
	box.Rotation = 8
	box.BackgroundColor3 = Color3.new(0, 0, 0)
	box.BorderSizePixel = 0
	box.BackgroundTransparency = 1
	box.Parent = board
	local scale = Instance.new("UIScale")
	scale.Parent = box
	local inner = Instance.new("Frame")
	inner.Position = UDim2.fromScale(0.15, 0.02)
	inner.Size = UDim2.fromScale(0.7, 0.96)
	inner.BackgroundTransparency = 1
	inner.Parent = box
	local fill = Instance.new("Frame")
	fill.AnchorPoint = Vector2.new(0, 1)
	fill.Position = UDim2.fromScale(0, 1)
	fill.Size = UDim2.fromScale(1, 0)
	fill.BorderSizePixel = 0
	fill.BackgroundTransparency = 1
	fill.Parent = inner
	return { box = box, fill = fill, scale = scale, vis = 0, pop = 0 }
end

-- Eases the bar's visibility toward `want` (0/1), lays out `level` (0-1) in `color`, decays its pop.
local function drawBar(bar: Bar, dt: number, want: number, level: number, color: Color3)
	bar.vis += (want - bar.vis) * (1 - math.exp(-dt * (if want > bar.vis then 20 else 8)))
	bar.pop *= math.exp(-dt * 8)
	bar.fill.Size = UDim2.fromScale(1, level)
	bar.fill.BackgroundColor3 = color
	bar.fill.BackgroundTransparency = 1 - bar.vis
	bar.box.BackgroundTransparency = 1 - bar.vis * 0.8
	bar.scale.Scale = 1 + 0.5 * bar.pop
end

local function step(dt: number)
	local t = now()
	-- predicted chamber fill (only while the dash is off cooldown, like the server)
	if hasChamber and chamber < 1 and t >= dashCooldownUntil then
		chamber = math.min(1, chamber + dt / chamberFillTime)
	end
	local full = chamber >= 1
	if full and not wasFull and hasChamber then
		chamberBar.pop = 1 -- loaded
	end
	wasFull = full
	-- Only in combat mode (user, 2026-10-31); it still fills while hidden, so it comes back where it really is.
	local character = Players.LocalPlayer.Character
	local fighting = character ~= nil and character:GetAttribute("CombatMode") == true
	drawBar(chamberBar, dt, if hasChamber and chamber > 0 and fighting then 1 else 0, chamber,
		if full then Color3.fromHSV((os.clock() * RAINBOW_SPEED) % 1, 0.55, 1) else CHAMBER_BLUE)

	local left = dashCooldownUntil - t
	local ready = left <= 0
	if ready and not wasReady then
		dashBar.pop = 1 -- dash is back
	end
	wasReady = ready
	drawBar(dashBar, dt, if left > -READY_HOLD then 1 else 0, 1 - math.clamp(left / dashTotal, 0, 1), DASH_WHITE)

	board.Enabled = chamberBar.vis > 0.01 or dashBar.vis > 0.01
end

-- Our own normal dash, predicted (the DashCooldownUntil attribute confirms it later). A cooldown that starts
-- while the dash was ready is a fresh one (we note when); any later change (the server's echo, a dash-away
-- penalty, a refund, a slow zone stretching it) moves the end, and the fill is measured from that start.
-- `stretched` (slow zone) is accepted for CombatController's call; only the end time matters here.
local dashStart = 0
function StatusController.dashUsed(cooldownUntil: number, _stretched: boolean?)
	local t = now()
	if cooldownUntil > t and dashCooldownUntil <= t then
		dashStart = t
	end
	dashCooldownUntil = cooldownUntil
	dashTotal = math.max(0.1, cooldownUntil - dashStart)
end

-- We burned the chambered dash (predicted; the Chamber attribute confirms it).
function StatusController.chamberSpent()
	chamber = 0
end

local function bind(character: Model)
	for _, c in charConns do
		c:Disconnect()
	end
	table.clear(charConns)
	dashCooldownUntil = 0
	chamber = 0
	hasChamber = false
	board.Adornee = character:WaitForChild("HumanoidRootPart", 10) :: BasePart?

	local function readCooldown()
		local v = character:GetAttribute("DashCooldownUntil")
		if typeof(v) == "number" then
			StatusController.dashUsed(v)
		end
	end
	local function readChamber()
		local v = character:GetAttribute("Chamber")
		hasChamber = typeof(v) == "number"
		if typeof(v) == "number" then
			-- Server updates lag a little behind our prediction; only snap on real drift
			-- (or the exact empty / full moments).
			if v <= 0 or v >= 1 or math.abs(v - chamber) > CHAMBER_SNAP then
				chamber = v
			end
		end
		if hasChamber and Paths.findPerk(CHAMBER_PERK) then
			chamberFillTime = Paths.perk(CHAMBER_PERK).fillTime
		end
	end
	table.insert(charConns, character:GetAttributeChangedSignal("DashCooldownUntil"):Connect(readCooldown))
	table.insert(charConns, character:GetAttributeChangedSignal("Chamber"):Connect(readChamber))
	readCooldown()
	readChamber()
end

function StatusController.init()
	board = Instance.new("BillboardGui")
	board.Name = "MidoriDashMeters"
	board.ResetOnSpawn = false
	board.AlwaysOnTop = true
	board.LightInfluence = 0
	board.Size = UDim2.fromScale(BOARD_W, BOARD_H) -- scale = studs: sized with the world, not the screen
	board.StudsOffset = OFFSET
	board.Enabled = false
	board.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	chamberBar = makeBar(0.5 - GAP / 2 / BOARD_W) -- left
	dashBar = makeBar(0.5 + GAP / 2 / BOARD_W) -- right, nearer the character

	local player = Players.LocalPlayer
	player.CharacterAdded:Connect(bind)
	if player.Character then
		task.spawn(bind, player.Character)
	end
	RunService.RenderStepped:Connect(step)
end

return StatusController