--!strict
-- ArmClone: a look-alike copy of a character's arm, with its colour, package mesh
-- (CharacterMesh) and shirt. The copy lives in its own model with an inert Humanoid, which is
-- what makes the shirt render on it (R6 clothing is drawn on limbs by name under a Humanoid).
-- Build one template per use site and :Clone() it per copy (cloning is cheap; building isn't).
--
--   local tpl = ArmClone.template(character, "Right Arm") -- Model? (PrimaryPart = the arm)
--   local copy = tpl:Clone(); copy.PrimaryPart.CFrame = ...; copy.Parent = workspace
local ArmClone = {}

local MESH_PART: { [string]: Enum.BodyPart } = {
	["Left Arm"] = Enum.BodyPart.LeftArm,
	["Right Arm"] = Enum.BodyPart.RightArm,
}

function ArmClone.template(character: Model, limb: string): Model?
	local arm = character:FindFirstChild(limb)
	if not arm or not arm:IsA("BasePart") then
		return nil
	end
	local copy = arm:Clone()
	-- Drop joints, attachments, tool grips etc.; keep only a mesh if the arm has one.
	for _, child in copy:GetChildren() do
		if not child:IsA("DataModelMesh") then
			child:Destroy()
		end
	end
	copy.Name = limb -- clothing is applied by limb name
	copy.Anchored = true
	copy.CanCollide = false
	copy.CanQuery = false
	copy.CanTouch = false
	copy.CastShadow = false
	copy.Massless = true
	copy.Transparency = 0

	local model = Instance.new("Model")
	model.Name = "ArmClone"
	copy.Parent = model
	model.PrimaryPart = copy

	local hum = Instance.new("Humanoid")
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	hum.EvaluateStateMachine = false
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	hum.Parent = model

	local shirt = character:FindFirstChildOfClass("Shirt")
	if shirt then
		shirt:Clone().Parent = model
	end
	local bodyPart = MESH_PART[limb]
	for _, child in character:GetChildren() do
		if child:IsA("CharacterMesh") and child.BodyPart == bodyPart then
			child:Clone().Parent = model
		end
	end
	return model
end

return ArmClone
