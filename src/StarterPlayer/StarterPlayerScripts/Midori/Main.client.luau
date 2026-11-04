--!strict
-- Midori client boot: global controllers once, per-character controllers on every spawn.
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local CombatController = Paths.client("CombatController")
local RunController = Paths.client("RunController")
local CombatModeController = Paths.client("CombatModeController")
local FeedbackController = Paths.client("FeedbackController")

local player = Players.LocalPlayer

task.spawn(Paths.client("CameraDebug").init) -- TEMP: mobile black-screen camera readout (devs on touch only)

task.spawn(function()
	local anims = {}
	for _, inst in Paths.Assets:WaitForChild("Animations"):GetDescendants() do
		if inst:IsA("Animation") and inst.AnimationId ~= "" then
			table.insert(anims, inst)
		end
	end
	ContentProvider:PreloadAsync(anims)
end)

Paths.client("ChronoClient").init() -- character replication for fighters in combat
FeedbackController.init()
Paths.client("NametagController").init()
Paths.client("ShieldController").init()
task.spawn(Paths.client("ChatBarController").init) -- topbar chat box (no chat window / history); waits for PlayerGui
Paths.client("HudController").init() -- top-left HUD: guard / HP / adrenaline + trait cards
Paths.client("RemoteAnimator").init()
Paths.shared("AnimDebug").start() -- TEMP: stuck-animation diagnostic (D.ANIM_DEBUG)
Paths.client("Afterimage").init() -- ghost trail on afterimage rushes (Prodigy Reentry), everyone's
Paths.client("BlinkLane").init() -- others' blink lanes (Dema M2); ours comes from CombatController
Paths.client("HolsterController").init() -- style.holster weapon pose (Dema): put away / walking
Paths.shared("Ragdoll").initClient() -- our own ragdoll + holding bodies we carry
Paths.client("CalloutController").init()
Paths.client("AnnounceController").init() -- owner ,m banners
Paths.client("StatusController").init()
Paths.client("MenuController").init() -- P menu; builds the traits panel too
Paths.client("EmoteController").init() -- G emote wheel
Paths.client("InteractController").init() -- hover + E: carry knocked players, pick up soda
Paths.client("BloxyController").init() -- too much Bloxy Cola: blur + blackout screen
task.spawn(function()
	Paths.client("MusicController").init() -- OST pools + NOW PLAYING card; before areas (they pick the pool)
	Paths.client("LocationController").init() -- area name card, teleport fade, area time of day (waits for workspace.Locations)
end)
Paths.client("CutsceneController").init() -- cutscene camera / letterbox (CutsceneService)
Paths.client("ApartmentController").init() -- builds the apartment we're in (only here) + hides who isn't with us
Paths.client("BuildController").init() -- BUILD button / furniture bar in your own apartment
Paths.client("DJController").init() -- DJ booth music through the apartment, muffled room by room
Paths.client("DoorController").init() -- apartment door signs + your door panel (claim / lock / whitelist)
local MobileButtons = Paths.client("MobileButtons")
MobileButtons.init() -- touch only: LOCK (shift lock) + RUN (sprint toggle) + EMOTE (wheel), bottom left

local cleanup: (() -> ())? = nil

local function onCharacter(character: Model)
	if cleanup then
		cleanup()
	end
	local run = RunController.start(character)
	MobileButtons.setRun(run)
	local mode = CombatModeController.start(character)
	Paths.client("HudController").setMode(mode) -- bottom-left controls list follows combat mode
	local soda = Paths.client("SodaController").start(character)
	local skate = Paths.client("SkateController").start(character, run) -- B: skateboard
	local stopCombat = CombatController.start(character, run, mode, soda, skate)
	local carry = Paths.client("CarryController").start(character) -- knocked countdown, carry drop key + anims
	-- Each step on its own: one failing on the old body (e.g. reset while carried) must not stop the
	-- rest, or the new character's controllers never start (bug, 2026-10-24: no sprint, no style).
	cleanup = function()
		local steps = { { "carry", carry.destroy }, { "skate", skate.destroy }, { "soda", soda.destroy }, { "combat", stopCombat }, { "mode", mode.destroy }, { "run", run.destroy } }
		for _, s in steps do
			local ok, err = pcall(s[2])
			if not ok then
				warn(`[Cleanup] {s[1]}: {err}`)
			end
		end
	end
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	onCharacter(player.Character)
end
