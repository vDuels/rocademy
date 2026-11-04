--!strict
-- Ghost: universal afterimage VFX. Takes a snapshot of a character and leaves an anchored
-- copy of every limb (head included) at the limb's exact CFrame, then fades it out.
-- Local only; each client spawns its own ghosts from confirmed events.
--
--   Ghost.snapshot(character)                         -- whole body, default look
--   Ghost.snapshot(character, { fade = 0.5, color = Color3.new(1, 1, 1) })
--   Ghost.snapshot(character, { limbs = { "Right Arm" } }) -- only some limbs
local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local MESH_HEAD = Paths.Assets:WaitForChild("Vfx"):WaitForChild("MeshHead") :: MeshPart

export type Options = {
	fade: number?, -- seconds to fade out (default GHOST_FADE)
	transparency: number?, -- starting transparency (default GHOST_START_TRANSPARENCY)
	color: Color3?, -- default GHOST_COLOR (white)
	material: Enum.Material?,
	limbs: { string }?, -- only these limb names (default: every limb)
}

local Ghost = {}

local folder: Folder? = nil

local function container(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "MidoriGhosts"
		f.Parent = workspace
		folder = f
	end
	return folder :: Folder
end

local function inert(part: BasePart)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
end

-- The head's visible size: a classic head is a 2x1x1 part shrunk by its SpecialMesh, so
-- MeshHead is scaled to the mesh, not the part.
local function headCopy(head: BasePart): BasePart
	local copy = MESH_HEAD:Clone()
	local mesh = head:FindFirstChildOfClass("SpecialMesh")
	local size: Vector3
	if head:IsA("MeshPart") then
		size = head.Size
	elseif mesh then
		local visible = head.Size.Y * mesh.Scale.Y
		size = MESH_HEAD.Size * (visible / MESH_HEAD.Size.Y)
	else
		size = MESH_HEAD.Size * (head.Size.Y / MESH_HEAD.Size.Y)
	end
	copy.Size = size
	copy:ClearAllChildren()
	return copy
end

local function limbCopy(limb: BasePart): BasePart
	local copy = Instance.new("Part")
	copy.Size = limb.Size
	copy.Shape = Enum.PartType.Block
	copy.TopSurface = Enum.SurfaceType.Smooth
	copy.BottomSurface = Enum.SurfaceType.Smooth
	return copy
end

Ghost.headCopy = headCopy -- LimbFx ghosts heads the same way

function Ghost.snapshot(character: Model, opts: Options?)
	local o: Options = opts or {}
	local fade = o.fade or D.GHOST_FADE
	local start = o.transparency or D.GHOST_START_TRANSPARENCY
	local only: { [string]: boolean }? = nil
	if o.limbs then
		only = {}
		for _, name in o.limbs do
			(only :: any)[name] = true
		end
	end

	local parent = container()
	local info = TweenInfo.new(fade, Enum.EasingStyle.Linear)
	for _, limb in character:GetChildren() do
		if not limb:IsA("BasePart") or limb.Name == "HumanoidRootPart" or limb.Transparency >= 1 then
			continue
		end
		if only and not only[limb.Name] then
			continue
		end
		local copy = if limb.Name == "Head" then headCopy(limb) else limbCopy(limb)
		copy.Name = "Ghost_" .. limb.Name
		copy.CFrame = limb.CFrame
		copy.Color = o.color or D.GHOST_COLOR
		copy.Material = o.material or D.GHOST_MATERIAL
		copy.Transparency = start
		inert(copy)
		copy.Parent = parent
		TweenService:Create(copy, info, { Transparency = 1 }):Play()
		Debris:AddItem(copy, fade + 0.1)
	end
end

return Ghost
