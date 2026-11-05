--!strict
-- Plays cutscenes the server starts (ServerScriptService.Midori.CutsceneService; data in
-- Data/Cutscenes): a Scriptable camera through the keyframes (relative to the anchor CFrame), timed from
-- the server's start time, FOV through CameraFov ("cutscene" multiplier), letterbox bars, the HUD slid
-- out and local SFX. Ends (camera + HUD back) at the duration, or early if an actor dies or goes away.
-- Also: our own character's cues (Shared/CutsceneTimeline), the music (silent by the duration), hit
-- kicks, and the `returnTime` blend into the normal camera.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Cutscenes = Paths.data("Cutscenes")
local Net = Paths.shared("Net")
local CombatMath = Paths.shared("CombatMath")
local CutsceneTimeline = Paths.shared("CutsceneTimeline")
local Enums = Paths.shared("Enums")
local CameraFov = Paths.client("CameraFov")
local HudController = Paths.client("HudController")
local FeedbackController = Paths.client("FeedbackController")
local ImpactFrame = Paths.client("ImpactFrame")
local CutsceneStage = Paths.client("CutsceneStage")
local Afterimage = Paths.client("Afterimage")
local CutscenePuppet = Paths.client("CutscenePuppet")

local RESTORE_STEP, BLEND_STEP = "MidoriCutsceneRestore", "MidoriCutsceneBlend"

local BAR = 0.12 -- letterbox bar height (share of the screen)
local BAR_TIME = 0.35

local CutsceneController = {}

local bars: { Frame } = {}
local fade: Frame -- full-screen black for the intro's fade (built in init)
local stopCurrent: (() -> ())? = nil

local function letterbox(on: boolean)
	for i, bar in bars do
		local y = if i == 1 then (if on then 0 else -BAR) else (if on then 1 - BAR else 1)
		TweenService:Create(bar, TweenInfo.new(BAR_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0, y) }):Play()
	end
end

local function sound(path: string): Sound?
	local node: Instance? = Paths.Assets:FindFirstChild("Sfx")
	for part in string.gmatch(path, "[^/]+") do
		node = node and node:FindFirstChild(part)
	end
	return if node and node:IsA("Sound") then node else nil
end

-- One Sound per music track, kept in SoundService and reused every cutscene (preloaded at init), so a
-- replay never waits on a fresh clone loading. `gen` stops an old fade-out from stopping a newer play.
local musicCache: { [string]: { sound: Sound, volume: number, start: number, gen: number } } = {}
local function cachedMusic(path: string)
	local entry = musicCache[path]
	if not entry then
		local template = sound(path)
		if not template then
			return nil
		end
		local m = template:Clone()
		m.Parent = SoundService
		-- start: the template's TimePosition is where the track begins (set in Studio).
		entry = { sound = m, volume = template.Volume, start = template.TimePosition, gen = 0 }
		musicCache[path] = entry
	end
	return entry
end

-- The camera CFrame + FOV multiplier at `t` seconds in.
local function sample(keys: { any }, t: number): (CFrame, number)
	local prev = keys[1]
	for i = 2, #keys do
		local key = keys[i]
		if t < key.t then
			local span = key.t - prev.t
			local a = if span > 0 then math.clamp((t - prev.t) / span, 0, 1) else 1
			a = TweenService:GetValue(a, key.style or Enum.EasingStyle.Quad, key.dir or Enum.EasingDirection.InOut)
			local fov = (prev.fov or 1) + ((key.fov or 1) - (prev.fov or 1)) * a
			return prev.cf:Lerp(key.cf, a), fov
		end
		prev = key
	end
	return prev.cf, prev.fov or 1
end

-- `everyone`: 3P (every screen runs the camera); else only the actors' screens do. Every screen plays
-- every actor's clips locally, and moves its own character (Shared/CutsceneTimeline).
function CutsceneController.play(id: string, anchor: CFrame, actors: { [string]: Model }, startAt: number, everyone: boolean?)
	local def = Cutscenes[id]
	if not def then
		return
	end
	local me = Players.LocalPlayer.Character
	local stops: { () -> () } = {}
	local watching = everyone == true
	local intro = def.intro or 0
	-- Our own body plays its cues for real (moves + clips). Every other actor gets a local puppet that
	-- replays its cues exactly (CutscenePuppet): replicated movement arrives late and smoothed. It
	-- swaps in at `intro` (under the black on the fighters' screens) and hands back to the real body at
	-- its `handback`: the victim at the finisher (the launch + ragdoll are real physics), else the end.
	type Stand = { p: any, cues: { any }, start: CFrame, handback: number, shown: boolean }
	local puppets: { [string]: Stand } = {}
	for role, model in actors do
		local spec = def.actors[role]
		watching = watching or model == me
		if not (spec and spec.cues and model) then
			continue
		end
		if model == me then
			table.insert(stops, CutsceneTimeline.run(model, spec.cues, anchor, startAt, true, true))
		else
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			local ok, p = pcall(CutscenePuppet.new, model)
			if ok and root then
				puppets[role] = {
					p = p,
					cues = CutsceneTimeline.sorted(spec.cues),
					start = if role == "attacker" then anchor else root.CFrame,
					handback = if role == "victim" and def.finisher then def.finisher.t else def.duration,
					shown = false,
				}
				table.insert(stops, CutsceneTimeline.run(p.model, spec.cues, anchor, startAt, false, true))
			else
				table.insert(stops, CutsceneTimeline.run(model, spec.cues, anchor, startAt, false, true)) -- no copy: clips on the real body
			end
		end
	end
	if next(puppets) then
		local drive: RBXScriptConnection
		drive = RunService.RenderStepped:Connect(function()
			local t = workspace:GetServerTimeNow() - startAt
			for role, s in puppets do
				local real = actors[role]
				local humanoid = real and real.Parent and real:FindFirstChildOfClass("Humanoid")
				if t >= s.handback or not humanoid or humanoid.Health <= 0 then
					s.p.destroy()
					puppets[role] = nil
				elseif t >= intro then
					if not s.shown then
						s.shown = true
						s.p.show()
					end
					s.p.setCFrame(CutsceneTimeline.pose(s.cues, anchor, t, s.start))
				end
			end
			if next(puppets) == nil then
				drive:Disconnect()
			end
		end)
	end
	-- What a screen sees for an actor right now: its puppet while one stands in, else the real body.
	local function seen(role: string): Model?
		local s = puppets[role]
		return if s and s.shown then s.p.model else actors[role]
	end
	-- Hit particles on every hit (every screen), the finisher bigger and with an impact frame (the
	-- impact frame only shows for the two fighters, as in combat).
	if actors.attacker and actors.victim then
		local function burst(result: string?)
			local a, v = seen("attacker"), seen("victim")
			local ar = a and a:FindFirstChild("HumanoidRootPart") :: BasePart?
			local vr = v and v:FindFirstChild("HumanoidRootPart") :: BasePart?
			if ar and vr then
				local toward = (ar.Position - vr.Position) * Vector3.new(1, 0, 1)
				local side = if toward.Magnitude > 0.01 then toward.Unit else Vector3.zero
				FeedbackController.hitEffect(vr.Position + side + Vector3.yAxis * 0.5, result)
			end
		end
		for _, h in def.hits or {} do
			task.delay(math.max(0, startAt + h.t - workspace:GetServerTimeNow()), burst)
		end
		-- Barrages: arm clones, see-through copies and the faded arm, on every screen.
		for _, b in def.barrages or {} do
			Paths.client("CutsceneBarrage").play(b, startAt, function()
				return seen("attacker")
			end)
		end
		if def.finisher then
			task.delay(math.max(0, startAt + def.finisher.t - workspace:GetServerTimeNow()), function()
				burst(Enums.Result.Counter)
				-- The victim's puppet hands back on this same beat: impact the real victim.
				ImpactFrame.play(seen("attacker"), actors.victim)
			end)
		end
	end
	if not watching then
		return -- someone else's 1v1: just their clips and hit effects
	end
	if stopCurrent then
		stopCurrent()
	end
	local camera = workspace.CurrentCamera
	local oldType, oldSubject = camera.CameraType, camera.CameraSubject
	-- `intro`: the gameplay camera stays for the opening impact frame while the screen fades to black;
	-- the cutscene camera, bars and HUD swap in under the black, which then lifts.
	local taken = false
	local stage: any = nil
	local function takeCamera()
		taken = true
		oldType, oldSubject = camera.CameraType, camera.CameraSubject
		camera.CameraType = Enum.CameraType.Scriptable
		if def.letterbox then
			letterbox(true)
		end
		if def.stage then
			local exclude = {}
			for _, model in actors do
				table.insert(exclude, model)
			end
			for _, s in puppets do
				table.insert(exclude, s.p.model)
			end
			stage = CutsceneStage.build(anchor, def.stage, exclude)
		end
	end
	if def.hideHud then
		HudController.setOut(true) -- straight away: the HUD may draw above the fade
	end
	local timers: { thread } = {}
	if intro > 0 then
		local black = def.black or { fadeIn = 0.3, fadeOut = 0.4 }
		local wait = math.max(0, startAt + intro - black.fadeIn - workspace:GetServerTimeNow())
		table.insert(timers, task.delay(wait, function()
			TweenService:Create(fade, TweenInfo.new(black.fadeIn, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { BackgroundTransparency = 0 }):Play()
		end))
		table.insert(timers, task.delay(wait + black.fadeIn, function()
			TweenService:Create(fade, TweenInfo.new(black.fadeOut, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
		end))
	else
		takeCamera()
	end
	-- (def.startSound plays on the hit that started it: FeedbackController, from the HitResult.)
	for _, cue in def.sfx do
		table.insert(timers, task.delay(math.max(0, startAt + cue.t - workspace:GetServerTimeNow()), function()
			local s = sound(cue.sound)
			if s then
				SoundService:PlayLocalSound(s)
			end
		end))
	end
	-- Music from `music.at` (default the start), fading so it's silent exactly at the duration.
	local music: Sound? = nil
	local track = def.music and cachedMusic(def.music.sound)
	if track then
		track.gen += 1
		local m = track.sound
		m:Stop()
		m.Volume = track.volume
		local musicAt = startAt + (def.music.at or 0)
		table.insert(timers, task.delay(math.max(0, musicAt - workspace:GetServerTimeNow()), function()
			m.TimePosition = track.start + math.max(0, workspace:GetServerTimeNow() - musicAt)
			m:Play()
		end))
		music = m
		local fadeAt = startAt + def.duration - def.music.fade
		table.insert(timers, task.delay(math.max(0, fadeAt - workspace:GetServerTimeNow()), function()
			TweenService:Create(m, TweenInfo.new(math.max(0, startAt + def.duration - workspace:GetServerTimeNow()), Enum.EasingStyle.Linear), { Volume = 0 }):Play()
		end))
	end

	-- Hand back: the normal camera runs again (seeded behind our character, looking where it faces) and
	-- its result is blended in from where the keyframes left off. RESTORE puts the camera module's own
	-- CFrame back before it runs, so it never builds on the blended one.
	local returnAt = def.duration - (def.returnTime or 0)
	local returning = false
	local function startReturn(from: CFrame)
		returning = true
		-- Shift lock gets the body back now, while the view eases home (not with a snap at the end).
		-- Local only; the server clears the attribute itself when the cutscene state ends.
		if me then
			me:SetAttribute("Cutscene", nil)
		end
		local root = me and me:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			local look = CombatMath.flat(root.CFrame.LookVector)
			camera.CFrame = CFrame.lookAt(root.Position - look * 12 + Vector3.yAxis * 4, root.Position + look * 4)
		end
		camera.CameraType = oldType
		camera.CameraSubject = oldSubject
		local own = camera.CFrame
		-- Camera - 2: strictly before HeadRotation (Camera - 1), which reads the camera to aim the shoulder
		-- offset; at the same priority it sometimes read the blended view, fed it back into the blend,
		-- then snapped when the cutscene ended (the jitter).
		RunService:BindToRenderStep(RESTORE_STEP, Enum.RenderPriority.Camera.Value - 2, function()
			camera.CFrame = own
		end)
		RunService:BindToRenderStep(BLEND_STEP, Enum.RenderPriority.Last.Value, function()
			own = camera.CFrame
			local a = math.clamp((workspace:GetServerTimeNow() - startAt - returnAt) / def.returnTime, 0, 1)
			camera.CFrame = from:Lerp(own, TweenService:GetValue(a, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut))
		end)
		CameraFov.set("cutscene", nil, def.returnTime)
		if stage then
			stage.fadeOut(def.returnTime) -- the scene fades out as the camera comes home
		end
		if def.letterbox then
			letterbox(false)
		end
		if def.hideHud then
			HudController.setOut(false)
		end
		-- This frame's render steps have already run, so the blend starts next frame: without this the
		-- seed (behind the character) showed for one frame (the end-of-cutscene flash). RESTORE hands the
		-- camera module the seed again before it runs next frame.
		camera.CFrame = from
	end

	local conn: RBXScriptConnection
	local function stop()
		if stopCurrent ~= stop then
			return
		end
		stopCurrent = nil
		conn:Disconnect()
		for _, thread in timers do
			pcall(task.cancel, thread)
		end
		if music and track then
			local m, gen = music, track.gen
			TweenService:Create(m, TweenInfo.new(0.3), { Volume = 0 }):Play() -- already silent at the duration
			task.delay(0.3, function()
				if track.gen == gen then
					m:Stop()
				end
			end)
		end
		for _, stopCues in stops do
			stopCues()
		end
		RunService:UnbindFromRenderStep(RESTORE_STEP)
		RunService:UnbindFromRenderStep(BLEND_STEP)
		if stage then
			stage.destroy()
		end
		if fade.BackgroundTransparency < 1 then
			TweenService:Create(fade, TweenInfo.new(0.2), { BackgroundTransparency = 1 }):Play() -- cut short mid-fade: never stuck black
		end
		if not returning then
			if taken then
				CameraFov.set("cutscene", nil, 0.2)
				camera.CameraType = oldType
				camera.CameraSubject = oldSubject
				if def.letterbox then
					letterbox(false)
				end
			end
			if def.hideHud then
				HudController.setOut(false)
			end
		end
	end
	stopCurrent = stop
	conn = RunService.RenderStepped:Connect(function()
		local t = workspace:GetServerTimeNow() - startAt
		for _, model in actors do
			local humanoid = model and model.Parent and model:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				stop()
				return
			end
		end
		if t >= def.duration then
			stop()
			return
		end
		if returning or t < intro then
			return -- (the gameplay camera runs through the intro)
		end
		if not taken then
			takeCamera()
		end
		local cf, fov = sample(def.camera, math.max(t, 0))
		-- Hit kicks: the latest one's punch, decaying fast. ponytail: scans every kick each frame (~30).
		local kick = 0
		for _, k in def.kicks or {} do
			if t >= k.t then
				kick = math.max(kick, k.s * math.exp(-(t - k.t) * 14))
			end
		end
		if kick > 0.01 then
			cf *= CFrame.Angles(math.noise(t * 30, 1) * 0.08 * kick, math.noise(t * 30, 2) * 0.08 * kick, math.noise(t * 30, 3) * 0.12 * kick)
			fov *= 1 - 0.07 * kick
		end
		if def.returnTime and t >= returnAt then
			startReturn(anchor * cf)
			return
		end
		camera.CFrame = anchor * cf
		CameraFov.set("cutscene", if fov ~= 1 then fov else nil)
	end)
end

function CutsceneController.init()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriCutscene"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 50
	for i = 1, 2 do
		local bar = Instance.new("Frame")
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.Size = UDim2.fromScale(1, BAR)
		bar.Position = UDim2.fromScale(0, if i == 1 then -BAR else 1)
		bar.Parent = gui
		bars[i] = bar
	end
	fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.Size = UDim2.fromScale(1, 1)
	fade.ZIndex = 10
	fade.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	Net.get(Net.Names.Cutscene).OnClientEvent:Connect(CutsceneController.play)
	-- Cutscene dashes: the real dash's sound + flash, and an afterimage trail (user).
	CutsceneTimeline.onDash = function(root: BasePart, duration: number)
		FeedbackController.dash(root)
		local character = root.Parent
		if character and character:IsA("Model") then
			Afterimage.trail(character, duration)
		end
	end
	-- Preload every cutscene's punch sound + music, so the first hit isn't silent while it downloads.
	local preload: { Instance } = {}
	for _, def in Cutscenes do
		if def.hitSound then
			local s = Instance.new("Sound")
			s.SoundId = def.hitSound.id
			table.insert(preload, s)
		end
		local start = def.startSound and sound("Cutscenes/" .. def.startSound.sound)
		if start then
			table.insert(preload, start)
		end
		local track = def.music and cachedMusic(def.music.sound)
		if track then
			table.insert(preload, track.sound)
		end
	end
	task.spawn(ContentProvider.PreloadAsync, ContentProvider, preload)
end

return CutsceneController
