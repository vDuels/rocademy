--!strict
-- Skateboard speed rules (D.SKATE), pure so Tests can check them. SkateController runs them every
-- frame. Per 60fps frame, scaled by dt, in the reference game's order.
local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")

local SkateMath = {}

-- Speed lost per 60fps frame at `speed` (D.SKATE.decay tiers).
function SkateMath.decayRate(speed: number): number
	for _, tier in D.SKATE.decay do
		if speed >= tier.at then
			return tier.rate
		end
	end
	return 0
end

-- How steeply the ground under you rises along `heading` (flat unit): + uphill, - downhill,
-- 0 on flat ground (it's the sine of the incline).
function SkateMath.uphill(normal: Vector3, heading: Vector3): number
	return -normal:Dot(heading)
end

-- One frame: decay at the rate for the speed you STARTED the frame with (halved in the air), then
-- a wall in front drains (only while moving), then slopes push you (downhill speeds you up, uphill
-- slows you) while you're under slopeCap. Clamped to 0..maxSpeed.
function SkateMath.step(speed: number, dt: number, grounded: boolean, uphill: number, wall: boolean): number
	local S = D.SKATE
	local f = dt * 60
	speed = math.clamp(speed - SkateMath.decayRate(speed) * (if grounded then 1 else 0.5) * f, 0, S.maxSpeed)
	if wall and speed > 0 then
		speed -= S.wallDrain * f
	end
	if grounded and speed < S.slopeCap then
		speed -= uphill * S.slopeGain * f
	end
	return math.clamp(speed, 0, S.maxSpeed)
end

return SkateMath
