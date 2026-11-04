--!strict
-- Weapon holster pose (style.holster, Dema; user, 2026-10-28). Out of combat mode the weapon joint's C0
-- is `holster`; in combat mode it's the asset's own C0, so the idle's Handle keys line up. (A "holster
-- while walking" rule was tried and removed by the user.) Set locally for every fighter; C0 is visual
-- only (hitboxes never use the weapon), and the server leaves the asset's C0.
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local MoveSchema = Paths.shared("MoveSchema")

local FIGHTER_TAG = "MidoriFighter"
local SLOT = "StyleWeapon" -- WeaponService's weapon model name

local HolsterController = {}

-- The weapon's joint (in the limb, Part1 inside the weapon) and the asset's own C0.
local function joint(model: Model, weapon: Instance): (Motor6D?, CFrame?)
	local limb = model:FindFirstChild(weapon:GetAttribute("Limb") or "Torso")
	if not limb then
		return nil, nil
	end
	for _, j in limb:GetChildren() do
		if j:IsA("Motor6D") and j.Part1 and j.Part1:IsDescendantOf(weapon) then
			local asset = Paths.Assets.Weapons:FindFirstChild(weapon:GetAttribute("Weapon"))
			local own = asset and asset.PrimaryPart and asset.PrimaryPart:FindFirstChildOfClass("Motor6D")
			return j, if own then own.C0 else j.C0
		end
	end
	return nil, nil
end

function HolsterController.init()
	RunService.PreRender:Connect(function()
		for _, model in CollectionService:GetTagged(FIGHTER_TAG) do
			local weapon = model:FindFirstChild(SLOT)
			if not weapon then
				continue
			end
			local style = MoveSchema.ofModel(model)
			if not style.holster then
				continue
			end
			local j, own = joint(model, weapon)
			if not j or not own then
				continue
			end
			local c0 = if model:GetAttribute("CombatMode") ~= true then style.holster else own
			if j.C0 ~= c0 then
				j.C0 = c0
			end
		end
	end)
end

return HolsterController
