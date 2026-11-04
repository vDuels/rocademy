--!strict
-- Volume hitboxes: a target counts if any of its body parts (not accessories) overlaps the volume.
-- Box: the box itself. Cylinder (upright, see MoveSchema): its bounding box narrows the
-- search, then a part must reach within `radius` of the axis (horizontally).
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")

local Hitbox = {}

function Hitbox.query(root: CFrame, box: any, candidates: { Model }): { Model }
	if #candidates == 0 then
		return {}
	end
	local set: { [Instance]: boolean } = {}
	for _, m in candidates do
		set[m] = true
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = candidates

	local center = root * box.offset
	local radius: number? = if box.shape == "Cylinder" then box.radius else nil
	local hits: { Model } = {}
	local seen: { [Instance]: boolean } = {}
	for _, part in workspace:GetPartBoundsInBox(center, box.size, params) do
		-- Only the body counts: hats, hair and wings are random rolls and must not grow the hurtbox.
		if part:FindFirstAncestorOfClass("Accessory") then
			continue
		end
		if radius then
			local p = center:PointToObjectSpace(part.Position)
			local reach = math.min(part.Size.X, part.Size.Z) / 2
			if Vector2.new(p.X, p.Z).Magnitude > radius + reach then
				continue
			end
		end
		local node: Instance? = part.Parent
		while node and not set[node] do
			node = node.Parent
		end
		if node and not seen[node] then
			seen[node] = true
			table.insert(hits, node :: Model)
		end
	end
	return hits
end

function Hitbox.contains(root: CFrame, box: any, target: Model): boolean
	return #Hitbox.query(root, box, { target }) > 0
end

-- True if `box` placed at `root` touches an upright cylinder (`radius`, `height`) centred at `center`.
-- Pure geometry, no parts. Exact while the volume only turns around Y (hitboxes follow a flat root).
function Hitbox.touchesCylinder(root: CFrame, box: any, center: Vector3, radius: number, height: number): boolean
	local p = (root * box.offset):PointToObjectSpace(center)
	if math.abs(p.Y) > (box.size.Y + height) / 2 then
		return false
	end
	if box.shape == "Cylinder" then
		return Vector2.new(p.X, p.Z).Magnitude <= box.radius + radius
	end
	local hx, hz = box.size.X / 2, box.size.Z / 2
	local dx, dz = p.X - math.clamp(p.X, -hx, hx), p.Z - math.clamp(p.Z, -hz, hz)
	return dx * dx + dz * dz <= radius * radius
end

function Hitbox.draw(cf: CFrame, box: any)
	if not (D.DEBUG_HITBOXES and RunService:IsStudio() and RunService:IsRunning()) then
		return
	end
	local vis = Instance.new("Part")
	vis.Name = "MidoriHitboxDebug"
	if box.shape == "Cylinder" then
		-- Part cylinders run along X; turn it upright.
		vis.Shape = Enum.PartType.Cylinder
		vis.Size = Vector3.new(box.size.Y, box.size.X, box.size.Z)
		vis.CFrame = cf * CFrame.Angles(0, 0, math.pi / 2)
	else
		vis.Size = box.size
		vis.CFrame = cf
	end
	vis.Anchored = true
	vis.CanCollide = false
	vis.CanQuery = false
	vis.CanTouch = false
	vis.CastShadow = false
	vis.Material = Enum.Material.ForceField
	vis.Color = Color3.fromRGB(255, 80, 80)
	vis.Transparency = 0.5
	vis.Parent = workspace
	Debris:AddItem(vis, 0.15)
end

return Hitbox
