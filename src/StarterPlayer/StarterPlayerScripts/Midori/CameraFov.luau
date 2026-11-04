--!strict
-- The one owner of the local camera's FieldOfView. FOV = base x every active multiplier.
-- base is the player's own FOV: the planned FOV slider calls CameraFov.setBase(fov).
-- Effects never write FieldOfView themselves; they set / clear a named multiplier:
--   CameraFov.set("barrage", 1.2, 0.1)  -- 20% wider, eased in over 0.1s
--   CameraFov.set("barrage", nil, 0.25) -- back to normal over 0.25s
local TweenService = game:GetService("TweenService")

local CameraFov = {}

local base: number? = nil -- nil until first used: then the camera's current FOV
local mults: { [string]: number } = {}
local tween: Tween? = nil

local function apply(time: number, style: Enum.EasingStyle?, direction: Enum.EasingDirection?)
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	base = base or cam.FieldOfView
	local fov = base :: number
	for _, k in mults do
		fov *= k
	end
	fov = math.clamp(fov, 1, 120) -- Roblox's FieldOfView range
	if tween then
		tween:Cancel()
		tween = nil
	end
	if time <= 0 then
		cam.FieldOfView = fov
		return
	end
	local t = TweenService:Create(cam, TweenInfo.new(time, style or Enum.EasingStyle.Quad, direction or Enum.EasingDirection.Out), { FieldOfView = fov })
	tween = t
	t:Play()
end

-- The player's own FOV (the future FOV slider). Active effects stay applied on top of it.
function CameraFov.setBase(fov: number, time: number?)
	base = fov
	apply(time or 0)
end

function CameraFov.getBase(): number
	local cam = workspace.CurrentCamera
	return base or (if cam then cam.FieldOfView else 70)
end

-- Sets (or with nil clears) one effect's multiplier, easing to the result over `time`
-- (Quad Out unless a style / direction is given).
function CameraFov.set(key: string, mult: number?, time: number?, style: Enum.EasingStyle?, direction: Enum.EasingDirection?)
	mults[key] = mult
	apply(time or 0, style, direction)
end

return CameraFov
