--!strict
-- Maps a confirmed HitResult to animations on the fighter that owns `fa`.
-- Same rules on the client (own character) and server (dummies).
local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local Enums = Paths.shared("Enums")
local D = Paths.data("Defaults")

local Result = Enums.Result

local Reactions = {}

-- The attacker of this HitResult got parry-stunned: a real parry, or a clumsy one (Two Left Feet:
-- the victim's Strip / GuardBreak carries info.parried).
function Reactions.attackerParried(result: string, info: any): boolean
	return result == Result.Parried or (type(info) == "table" and info.parried == true)
end

function Reactions.apply(fa: any, self: Model, attacker: Model, victim: Model, result: string, info: any)
	local stun = if type(info) == "table" and type(info.stun) == "number" then info.stun else 0
	if victim == self then
		if type(info) == "table" and info.held then
			return -- hit landed during a guard-break / perfect-blocked stun: keep that reaction playing
		end
		if result == Result.Hit or result == Result.Counter or result == Result.Clash or result == Result.GuardBreak then
			-- info.clip: countered out of a move with its own stun clip (MoveSchema `countered`).
			local clip = if type(info) == "table" and type(info.clip) == "string" then info.clip else nil
			fa:stun(stun, if result == Result.Clash then "Clash" else clip)
		elseif result == Result.Blocked then
			fa:pose("Blocked", math.max(stun, 0.15))
		elseif result == Result.Strip then
			fa:pose("WeakBlock", math.max(stun, 0.15))
		elseif result == Result.Parried then
			-- Plays the clip once and holds its last frame for the rest of the parry recovery.
			fa:parried(stun)
		end
	elseif attacker == self and Reactions.attackerParried(result, info) then
		local attackerStun = if type(info) == "table" and type(info.attackerStun) == "number"
			then info.attackerStun
			else D.PARRY_STUN
		fa:stopAttacks(0.05)
		fa:pose("Perfect Blocked", attackerStun)
	end
end

return Reactions
