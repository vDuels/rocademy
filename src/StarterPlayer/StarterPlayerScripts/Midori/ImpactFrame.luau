--!strict
-- Impact frames: a few frames of stark black/white "manga panel" flash with the fighters as
-- solid silhouettes, a hitstop (both fighters' animations freeze briefly) and a camera kick.
-- Shown only on the attacker's and victim's screens. Visual only: server timing never changes.
-- What triggers one is decided by data (see D.IMPACT_RESULTS and moves' `impact` flag);
-- FeedbackController calls ImpactFrame.play on a matching HitResult.
local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local LOOKS = {
	-- washed-out world, black silhouettes (softened: user found the first version too flashy)
	light = { brightness = 0.15, contrast = 0.6, silhouette = Color3.new(0, 0, 0) },
	-- dark world, white silhouettes
	dark = { brightness = -0.2, contrast = 0.8, silhouette = Color3.new(1, 1, 1) },
}
local SHAKE_STEP = "MidoriImpactShake"

local ImpactFrame = {}

local cc: ColorCorrectionEffect? = nil
local token = 0 -- a newer impact cancels the rest of an older one

local function correction(): ColorCorrectionEffect
	if not cc or not cc.Parent then
		local c = Instance.new("ColorCorrectionEffect")
		c.Name = "MidoriImpact"
		c.Saturation = -1
		c.Enabled = false
		c.Parent = Lighting
		cc = c
	end
	return cc :: ColorCorrectionEffect
end

local function silhouette(model: Model): Highlight
	local h = Instance.new("Highlight")
	h.Name = "MidoriImpact"
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.FillTransparency = 0
	h.OutlineTransparency = 1
	h.Adornee = model
	h.Parent = model
	return h
end

-- Freezes every playing track on these models for `time`, then gives each its speed back.
local function hitstop(models: { Model }, time: number)
	local frozen: { [AnimationTrack]: number } = {}
	for _, model in models do
		local hum = model:FindFirstChildOfClass("Humanoid")
		local animator = hum and hum:FindFirstChildOfClass("Animator")
		if animator then
			for _, track in animator:GetPlayingAnimationTracks() do
				if track.Speed ~= 0 then
					frozen[track] = track.Speed
					track:AdjustSpeed(0)
				end
			end
		end
	end
	task.delay(time, function()
		for track, speed in frozen do
			if track.IsPlaying and track.Speed == 0 then
				track:AdjustSpeed(speed)
			end
		end
	end)
end

local function shake(strength: number, time: number)
	local started = os.clock()
	pcall(RunService.UnbindFromRenderStep, RunService, SHAKE_STEP)
	RunService:BindToRenderStep(SHAKE_STEP, Enum.RenderPriority.Camera.Value + 1, function()
		local t = os.clock() - started
		local cam = workspace.CurrentCamera
		if t >= time or not cam then
			RunService:UnbindFromRenderStep(SHAKE_STEP)
			return
		end
		local k = strength * (1 - t / time) -- decays to nothing
		cam.CFrame *= CFrame.new((math.random() * 2 - 1) * k, (math.random() * 2 - 1) * k, 0)
	end)
end

-- Plays an impact frame if we are the attacker or the victim.
function ImpactFrame.play(attacker: Instance?, victim: Instance?)
	local me = Players.LocalPlayer.Character
	if not me or (attacker ~= me and victim ~= me) then
		return
	end
	local models: { Model } = {}
	for _, m in { attacker, victim } do
		if typeof(m) == "Instance" and m:IsA("Model") and m.Parent then
			table.insert(models, m)
		end
	end
	local cfg = D.IMPACT
	token += 1
	local mine = token
	local c = correction()
	local lights: { Highlight } = {}
	for _, m in models do
		table.insert(lights, silhouette(m))
	end
	hitstop(models, cfg.hitstop)
	shake(cfg.shake, cfg.shakeTime)
	task.spawn(function()
		for _, frame in cfg.frames do
			if token ~= mine then
				break
			end
			local look = LOOKS[frame.look] or LOOKS.light
			c.Brightness = look.brightness
			c.Contrast = look.contrast
			c.Saturation = -1
			c.Enabled = true
			for _, h in lights do
				h.FillColor = look.silhouette
			end
			task.wait(frame.time)
		end
		-- Ease back instead of cutting (no hard flash on the way out either).
		local info = TweenInfo.new(cfg.fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		for _, h in lights do
			TweenService:Create(h, info, { FillTransparency = 1 }):Play()
		end
		if token == mine then
			TweenService:Create(c, info, { Brightness = 0, Contrast = 0, Saturation = 0 }):Play()
		end
		task.wait(cfg.fade)
		for _, h in lights do
			h:Destroy()
		end
		if token == mine then
			c.Enabled = false
		end
	end)
end

return ImpactFrame
