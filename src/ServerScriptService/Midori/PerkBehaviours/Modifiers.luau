--!strict
-- Stat perks: the perk data's `mods` table (keys = Fighter.Mods fields) is added to the
-- fighter's mods on attach and taken back off on detach, so these stack and swap cleanly.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Fighter = Paths.server("Fighter")

local Modifiers = {}

function Modifiers.attach(f: any, data: any)
	Fighter.addMods(f, data.mods, 1)
	return nil
end

function Modifiers.detach(f: any, data: any, _state: any)
	Fighter.addMods(f, data.mods, -1)
end

return Modifiers
