--!strict
-- Height (D.HEIGHT; owner-set, HeightService): one body scale -> stat multipliers. Server and client
-- both read the character's replicated "Height" attribute, so prediction matches.
local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")

local Height = {}

export type Stats = {
	damage: number,
	hp: number,
	dashDistance: number,
	dashCooldown: number,
	m2Cooldown: number,
	range: number,
	swingSpeed: number,
	moveSpeed: number,
	antiHeal: number, -- x on this fighter's anti-heal
	stunTaken: number, -- x on hitstun this fighter takes
}

function Height.clamp(h: number): number
	return math.clamp(h, D.HEIGHT.min, D.HEIGHT.max)
end

function Height.of(model: Instance?): number
	local h = model and model:GetAttribute("Height")
	return if typeof(h) == "number" then Height.clamp(h) else 1
end

function Height.stats(h: number): Stats
	local H = D.HEIGHT
	local up = math.clamp((h - 1) / (H.max - 1), 0, 1)
	local down = math.clamp((1 - h) / (1 - H.min), 0, 1)
	local T, S = H.tall, H.short
	return {
		damage = 1 + T.damage * up,
		hp = 1 + T.hp * up - S.hp * down,
		dashDistance = 1 + T.dashDistance * up,
		dashCooldown = 1 - S.dashCooldownCut * down,
		m2Cooldown = 1 - S.m2CooldownCut * down,
		range = h, -- hitbox scales with the body
		swingSpeed = 1 - T.swingSlow * up + S.swingFast * down,
		moveSpeed = 1 + S.moveSpeed * down,
		antiHeal = 1 + T.antiHeal * up - S.antiHeal * down,
		stunTaken = 1 - T.stunResist * up + S.stunWeak * down,
	}
end

function Height.ofModel(model: Instance?): Stats
	return Height.stats(Height.of(model))
end

local function scaleBox(box: any, r: number): any
	local b = table.clone(box)
	b.size = box.size * r
	b.offset = CFrame.new(box.offset.Position * r) * box.offset.Rotation
	if box.radius then
		b.radius = box.radius * r
	end
	return table.freeze(b)
end

-- The move as this height throws it: hitbox scaled by range, M2 cooldown cut. Normal height = the same move.
function Height.move(move: any, h: number): any
	if h == 1 then
		return move
	end
	local s = Height.stats(h)
	local m = table.clone(move)
	if move.hitbox then
		m.hitbox = scaleBox(move.hitbox, s.range)
	end
	if move.kind == "M2" then
		m.cooldown = move.cooldown * s.m2Cooldown
	end
	return table.freeze(m)
end

return Height
