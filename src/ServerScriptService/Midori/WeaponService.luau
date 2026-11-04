--!strict
-- Style weapons. A style with `weapon = "<name>"` gets a clone of Assets/Weapons/<name> on every fighter
-- using it. The asset's PrimaryPart carries its own Motor6D (named like the part, C0/C1 as on the user's
-- animation rig); here Part0 is set to the limb named by the asset's "Limb" attribute (default Torso).
-- Animations key that joint by name, so the asset's part name and C0/C1 must match the animation rig
-- (BanHammer: Torso "handle", identity C0/C1; Dema: Right Arm "Handle", C0 = (0, -1, 0) rotated (0, -90, 0), C1 identity (user, 2026-10-28)).
-- Follows the fighter's "Style" attribute: spawns, style swaps and dummies all go through it.
-- A style's `holster` pose (Dema) is applied on clients (HolsterController); here the joint keeps the asset's C0.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local MoveSchema = Paths.shared("MoveSchema")

local FIGHTER_TAG = "MidoriFighter"
local SLOT = "StyleWeapon" -- name of the weapon model inside the character

local WeaponService = {}

local function limbOf(model: Model, weapon: Instance): BasePart?
	local limb = model:FindFirstChild(weapon:GetAttribute("Limb") or "Torso")
	return if limb and limb:IsA("BasePart") then limb else nil
end

-- Gives `model` the weapon its style asks for (or none), replacing a different one.
function WeaponService.refresh(model: Model)
	local want = MoveSchema.ofModel(model).weapon
	local current = model:FindFirstChild(SLOT)
	if current and current:GetAttribute("Weapon") == want then
		return
	end
	if current then
		-- The joint lives in the limb (like the anim rig), so it doesn't go with the model.
		local limb = limbOf(model, current)
		for _, j in (if limb then limb:GetChildren() else {}) do
			if j:IsA("Motor6D") and j.Part1 and j.Part1:IsDescendantOf(current) then
				j:Destroy()
			end
		end
		current:Destroy()
	end
	if not want then
		return
	end
	local asset = Paths.Assets.Weapons[want]
	local limb = limbOf(model, asset)
	if not limb then
		return
	end
	local weapon = asset:Clone()
	weapon.Name = SLOT
	weapon:SetAttribute("Weapon", want)
	local joint = (weapon.PrimaryPart :: BasePart):FindFirstChildOfClass("Motor6D") :: Motor6D
	joint.Part0 = limb
	weapon.Parent = model
	joint.Parent = limb -- e.g. Torso.handle / Right Arm.Handle, same place as on the anim rig
end

function WeaponService.init()
	local function track(model: Instance)
		if not model:IsA("Model") then
			return
		end
		model:GetAttributeChangedSignal("Style"):Connect(function()
			WeaponService.refresh(model)
		end)

		WeaponService.refresh(model)
	end
	CollectionService:GetInstanceAddedSignal(FIGHTER_TAG):Connect(track)
	for _, model in CollectionService:GetTagged(FIGHTER_TAG) do
		track(model)
	end
end

return WeaponService
