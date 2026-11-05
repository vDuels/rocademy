--!strict
-- Screen colour shifts (local to this screen, in Lighting): a ColorCorrection preset from
-- D.COLOR_SHIFT, plus an optional depth of field locked on a model (the rest of the world blurs).
-- Roblox's post effects have no hue rotation, so "red becomes blue" is faked: drain the colour and
-- tint blue, so the whole frame reads blue (reds included).
--   pulse(look)          a pseudo impact frame: on for look.hold, then eased out over look.fade
--   hold(look, focus?)   on until the returned release() is called, then eased out the same way
-- A newer shift takes over from an older one.
-- The depth of field can only be on while the hold that turned it on is the current shift (user,
-- 2026-11-01: someone was left with a blurred screen after Prodigy): a watchdog switches it off otherwise,
-- e.g. if Roblox's Freecam re-enables it (its own DoF mode turns existing ones off, then back on), and a
-- hold lets go by itself after MAX_HOLD s if its release never comes.
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

export type Look = {
	tint: Color3,
	saturation: number,
	contrast: number?,
	brightness: number?,
	hold: number?,
	fadeIn: number?, -- seconds to shift in (eased); nil / 0 = straight on
	fade: number,
	dof: { far: number, near: number, radius: number }?,
}

local ColorShift = {}

local cc: ColorCorrectionEffect? = nil
local dof: DepthOfFieldEffect? = nil
local token = 0
local dofOwner = 0 -- the token whose hold turned the depth of field on (0 = none)
local MAX_HOLD = 5 -- longest a hold can last (Reentry: windup + endlag, ~1-2 s)

local function effects(): (ColorCorrectionEffect, DepthOfFieldEffect)
	if not cc or not cc.Parent then
		local c = Instance.new("ColorCorrectionEffect")
		c.Name = "MidoriShift"
		c.Enabled = false
		c.Parent = Lighting
		cc = c
	end
	if not dof or not dof.Parent then
		local d = Instance.new("DepthOfFieldEffect")
		d.Name = "MidoriFocus"
		d.Enabled = false
		d.Parent = Lighting
		dof = d
		-- One watchdog per effect: once this effect is replaced it stops (was a new Heartbeat connection per
		-- recreation that never disconnected).
		local watchdog: RBXScriptConnection
		watchdog = RunService.Heartbeat:Connect(function()
			if dof ~= d then
				watchdog:Disconnect()
			elseif d.Enabled and dofOwner ~= token then
				d.Enabled = false
			end
		end)
	end
	return cc :: ColorCorrectionEffect, dof :: DepthOfFieldEffect
end

local function apply(look: Look): number
	token += 1
	local c, d = effects()
	local target = { TintColor = look.tint, Saturation = look.saturation, Contrast = look.contrast or 0, Brightness = look.brightness or 0 }
	if look.fadeIn and look.fadeIn > 0 then
		-- Shift in slowly from wherever the screen is now (neutral, or a shift that was fading out).
		if not c.Enabled then
			c.TintColor, c.Saturation, c.Contrast, c.Brightness = Color3.new(1, 1, 1), 0, 0, 0
		end
		TweenService:Create(c, TweenInfo.new(look.fadeIn, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), target):Play()
	else
		for k, v in target do
			(c :: any)[k] = v
		end
	end
	c.Enabled = true
	d.Enabled = false
	dofOwner = 0
	return token
end

local function fadeOut(look: Look, mine: number)
	if token ~= mine then
		return -- a newer shift owns the effects now
	end
	local c, d = effects()
	local info = TweenInfo.new(look.fade, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(c, info, { TintColor = Color3.new(1, 1, 1), Saturation = 0, Contrast = 0, Brightness = 0 }):Play()
	if d.Enabled then
		TweenService:Create(d, info, { FarIntensity = 0, NearIntensity = 0 }):Play()
	end
	task.delay(look.fade, function()
		if token == mine then
			c.Enabled = false
			d.Enabled = false
			dofOwner = 0
		end
	end)
end

function ColorShift.pulse(look: Look)
	local mine = apply(look)
	task.delay(look.hold or 0, fadeOut, look, mine)
end

-- `focus`: keep this model sharp (depth of field on its root) while the rest blurs.
function ColorShift.hold(look: Look, focus: Model?): () -> ()
	local mine = apply(look)
	local conn: RBXScriptConnection? = nil
	local root = focus and focus:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root and look.dof then
		local _, d = effects()
		d.InFocusRadius = look.dof.radius
		if look.fadeIn and look.fadeIn > 0 then
			d.FarIntensity, d.NearIntensity = 0, 0 -- the blur comes in with the colour
			TweenService:Create(d, TweenInfo.new(look.fadeIn, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), { FarIntensity = look.dof.far, NearIntensity = look.dof.near }):Play()
		else
			d.FarIntensity, d.NearIntensity = look.dof.far, look.dof.near
		end
		d.Enabled = true
		dofOwner = mine
		conn = RunService.RenderStepped:Connect(function()
			local cam = workspace.CurrentCamera
			if token ~= mine or not root.Parent or not cam then
				return
			end
			d.FocusDistance = math.clamp((root.Position - cam.CFrame.Position).Magnitude, 0, 200)
		end)
	end
	local released = false
	local function release()
		if released then
			return
		end
		released = true
		if conn then
			conn:Disconnect()
		end
		fadeOut(look, mine)
	end
	task.delay(MAX_HOLD, release)
	return release
end

return ColorShift
