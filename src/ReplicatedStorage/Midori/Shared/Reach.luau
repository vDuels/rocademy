--!strict
-- How far `pos` is from the SURFACE of a thing (0 = inside / touching), not its centre: big things (a vending
-- machine, a walk-in teleport trigger) are reachable from any side. A part uses its own box; a model uses its
-- bounding box (Model:GetBoundingBox, oriented like the model's pivot). Client hover and server checks share it.
local Reach = {}

function Reach.gapToBox(cf: CFrame, size: Vector3, pos: Vector3): number
	local l = cf:PointToObjectSpace(pos)
	local h = size / 2
	return Vector3.new(math.max(math.abs(l.X) - h.X, 0), math.max(math.abs(l.Y) - h.Y, 0), math.max(math.abs(l.Z) - h.Z, 0)).Magnitude
end

-- Body to body (carry / grip; bug 2026-11-02: tall players couldn't grip): distance along the ground
-- between two roots, so a tall body's higher root (owner-set height) or a downed one's low root doesn't eat
-- the reach. Too far apart vertically (another floor) = out of reach.
local BODY_VERTICAL = 12 -- studs: a 2x-height root over a body lying on the floor is ~6

function Reach.body(from: Vector3, to: Vector3): number
	local d = to - from
	if math.abs(d.Y) > BODY_VERTICAL then
		return math.huge
	end
	return Vector2.new(d.X, d.Z).Magnitude
end

-- nil if `inst` is neither a part nor a model.
function Reach.gap(inst: Instance, pos: Vector3): number?
	if inst:IsA("BasePart") then
		return Reach.gapToBox(inst.CFrame, inst.Size, pos)
	elseif inst:IsA("Model") then
		local cf, size = inst:GetBoundingBox()
		return Reach.gapToBox(cf, size, pos)
	end
	return nil
end

return Reach
