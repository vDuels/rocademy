--!strict
-- Client side of too much Bloxy Cola (server: BloxyService; user, 2026-10-27). Reads our character's
-- attributes every frame, so it carries across respawns. Everything here is made by this client: only we
-- see / hear it.
--   Vision ("BloxySips" -> drinks = sips / D.SODA.sips): a BlurEffect that fades in from D.BLOXY.blurAt
--     drinks and grows with every sip up to D.BLOXY.blurMax; at "Drunk" 2 (the fighting style slows) it jumps
--     to D.BLOXY.blurFull. (Was depth of field until 2026-11-01: it kept everything near the camera sharp
--     and doesn't render on low graphics settings, user: "bluring vision doesnt really work".)
--   Sound ("BloxySips"): from D.BLOXY.muffleAt sips every sound goes through a master SoundGroup that muffles
--     (EQ cut) more each sip, fully garbled at D.BLOXY.garbleAt (+ distortion + wobbling pitch).
--   "BlackedOut" (while knocked): the screen fades to black, UNDER the rest of the UI (the KNOCKED
--     countdown still shows).
-- Can't run / slower attacks live in RunController / CombatController.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

-- How fast blur / muffle follow a change (per second, exponential): 0.4 = ~2.5 s to get most of the way,
-- ~6 s to settle, so each sip (and the jump to full blur) creeps in instead of snapping (user, 2026-10-27).
local EASE = 0.4
local BLACK_RATE = 1.5

local BloxyController = {}

local function ease(current: number, target: number, rate: number, dt: number): number
	return current + (target - current) * (1 - math.exp(-rate * dt))
end

-- Every sound in the game plays through `master` (on this client), so its effects reach them all.
-- Sounds that already have a group keep it; groups made in SoundService nest under master instead.
local function routeAll(master: SoundGroup)
	local function route(inst: Instance)
		if inst:IsA("Sound") and inst.SoundGroup == nil then
			inst.SoundGroup = master
		end
	end
	-- Where sounds live (characters and the map are in workspace); not `game`, whose core parts are locked.
	local roots: { Instance } = { workspace, SoundService, ReplicatedStorage, Players.LocalPlayer:WaitForChild("PlayerGui") }
	for _, root in roots do
		for _, d in root:GetDescendants() do
			route(d)
		end
		root.DescendantAdded:Connect(route)
	end
	local function nest(child: Instance)
		if child:IsA("SoundGroup") and child ~= master then
			child.Parent = master
		end
	end
	for _, c in SoundService:GetChildren() do
		nest(c)
	end
	SoundService.ChildAdded:Connect(nest)
end

function BloxyController.init()
	local player = Players.LocalPlayer
	local B = D.BLOXY

	local blur = Instance.new("BlurEffect")
	blur.Name = "MidoriBloxyBlur"
	blur.Size = 0
	blur.Enabled = false
	blur.Parent = Lighting

	local master = Instance.new("SoundGroup")
	master.Name = "MidoriMaster"
	master.Parent = SoundService
	local eq = Instance.new("EqualizerSoundEffect")
	eq.Priority = 3
	eq.Enabled = false
	eq.Parent = master
	local dist = Instance.new("DistortionSoundEffect")
	dist.Priority = 2
	dist.Enabled = false
	dist.Parent = master
	local pitch = Instance.new("PitchShiftSoundEffect")
	pitch.Priority = 1
	pitch.Enabled = false
	pitch.Parent = master
	routeAll(master)

	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriBlackout"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = -1
	local black = Instance.new("Frame")
	black.Size = UDim2.fromScale(1, 1)
	black.BackgroundColor3 = Color3.new(0, 0, 0)
	black.BackgroundTransparency = 1
	black.BorderSizePixel = 0
	black.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")

	local muffle = 0 -- eased 0..1
	RunService.RenderStepped:Connect(function(dt)
		local character = player.Character
		local sipsAttr = character and character:GetAttribute("BloxySips")
		local sips = if typeof(sipsAttr) == "number" then sipsAttr else 0
		local drinks = sips / D.SODA.sips
		local full = character ~= nil and character:GetAttribute("Drunk") == 2

		-- Vision: gradual from blurAt drinks, full the moment the fighting style slows.
		local size = 0
		if full then
			size = B.blurFull
		elseif drinks >= B.blurAt then
			-- a little at blurAt (the first blurry sip shows), up to blurMax just before drunkAt
			size = B.blurMax * math.clamp((drinks - B.blurAt) / (B.drunkAt - B.blurAt), 0.15, 1)
		end
		blur.Size = ease(blur.Size, size, EASE, dt)
		blur.Enabled = blur.Size > 0.05

		-- Sound: a tiny bit muffled at muffleAt sips, fully garbled at garbleAt.
		local m = if sips >= B.muffleAt then math.clamp((sips - B.muffleAt) / (B.garbleAt - B.muffleAt), 0.05, 1) else 0
		muffle = ease(muffle, m, EASE, dt)
		local on = muffle > 0.005
		eq.Enabled, dist.Enabled, pitch.Enabled = on, on and muffle > 0.3, on and muffle > 0.15
		if on then
			eq.HighGain = -45 * muffle
			eq.MidGain = -14 * muffle
			eq.LowGain = 3 * muffle
			dist.Level = 0.8 * muffle * muffle
			local t = os.clock()
			pitch.Octave = math.clamp(1 + (math.sin(t * 2.3) * 0.1 + math.sin(t * 5.7) * 0.05) * muffle, 0.5, 2)
		end

		-- Blackout screen.
		local out = character ~= nil and character:GetAttribute("BlackedOut") == true and character:GetAttribute("Knocked") == true
		black.BackgroundTransparency = ease(black.BackgroundTransparency, if out then 0 else 1, BLACK_RATE, dt)
	end)
end

return BloxyController
