--!strict
-- Single source of truth for Midori require paths. Business modules never hardcode
-- instance paths; they go through these helpers.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Midori = ReplicatedStorage:WaitForChild("Midori")
local Shared = Midori:WaitForChild("Shared")
local Data = Midori:WaitForChild("Data")

local Paths = {}

Paths.Assets = ReplicatedStorage:WaitForChild("Assets")

-- Third-party libraries (ReplicatedStorage/Lib/<name>).
function Paths.lib(name: string): any
	return require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild(name) :: ModuleScript)
end

function Paths.shared(name: string): any
	return require(Shared:WaitForChild(name) :: ModuleScript)
end

function Paths.data(name: string): any
	return require(Data:WaitForChild(name) :: ModuleScript)
end

function Paths.style(name: string): any
	return require(Data:WaitForChild("Styles"):WaitForChild(name) :: ModuleScript)
end

-- The real name of the style called `name` (any letter case), or nil if there is no such style.
-- Check this before Paths.style, which waits forever for a missing module.
function Paths.findStyle(name: string): string?
	local lower = string.lower(name)
	for _, m in Data:WaitForChild("Styles"):GetChildren() do
		if m:IsA("ModuleScript") and string.lower(m.Name) == lower then
			return m.Name
		end
	end
	return nil
end

-- Every style name in Data/Styles.
function Paths.styleIds(): { string }
	local ids = {}
	for _, m in Data:WaitForChild("Styles"):GetChildren() do
		if m:IsA("ModuleScript") then
			table.insert(ids, m.Name)
		end
	end
	return ids
end

-- Perk data (Data/Perks/<name>). Use Paths.findPerk first if the name may not exist.
function Paths.perk(name: string): any
	return require(Data:WaitForChild("Perks"):WaitForChild(name) :: ModuleScript)
end

function Paths.findPerk(name: string): boolean
	local perks = Data:FindFirstChild("Perks")
	local m = perks and perks:FindFirstChild(name)
	return m ~= nil and m:IsA("ModuleScript")
end

-- Every perk id in Data/Perks.
function Paths.perkIds(): { string }
	local ids = {}
	for _, m in Data:WaitForChild("Perks"):GetChildren() do
		if m:IsA("ModuleScript") then
			table.insert(ids, m.Name)
		end
	end
	return ids
end

-- Furniture data (Data/Furniture/<id>; Shared/GridMath). Nil for an unknown id (never waits).
function Paths.furniture(id: string): any?
	local m = Data:WaitForChild("Furniture"):FindFirstChild(id)
	return if m and m:IsA("ModuleScript") then require(m) :: any else nil
end

-- Every furniture id in Data/Furniture.
function Paths.furnitureIds(): { string }
	local ids = {}
	for _, m in Data:WaitForChild("Furniture"):GetChildren() do
		if m:IsA("ModuleScript") then
			table.insert(ids, m.Name)
		end
	end
	return ids
end

-- Server-side perk logic (ServerScriptService/Midori/PerkBehaviours/<name>).
function Paths.perkBehaviour(name: string): any
	local folder = game:GetService("ServerScriptService"):WaitForChild("Midori"):WaitForChild("PerkBehaviours")
	return require(folder:WaitForChild(name) :: ModuleScript)
end

function Paths.server(name: string): any
	local folder = game:GetService("ServerScriptService"):WaitForChild("Midori")
	return require(folder:WaitForChild(name) :: ModuleScript)
end

function Paths.client(name: string): any
	local playerScripts = game:GetService("Players").LocalPlayer:WaitForChild("PlayerScripts")
	return require(playerScripts:WaitForChild("Midori"):WaitForChild(name) :: ModuleScript)
end

return Paths
