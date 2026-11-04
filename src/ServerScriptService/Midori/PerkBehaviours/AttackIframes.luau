--!strict
-- Startup i-frames for one move kind (data: e.g. Data/Perks/AerialAce { kind, at, duration? }).
-- Opens the fighter's generic attack i-frame window from `at` into startup for `duration`
-- (or until the hitbox) (Fighter.inIframes). Both scale with attack speed like startup does.
type State = { startedAt: number }

local AttackIframes = {}

function AttackIframes.attach(_f: any, _data: any): State
	return { startedAt = -1 }
end

function AttackIframes.detach(f: any, _data: any, _s: State)
	f.attackIframesFrom = 0
	f.attackIframesUntil = 0
end

function AttackIframes.tick(f: any, data: any, s: State, _now: number, _dt: number)
	local move = f.move
	if f.state ~= "Startup" or not move or move.kind ~= data.kind or s.startedAt == f.stateStartedAt then
		return
	end
	s.startedAt = f.stateStartedAt
	local scale = (f.stateEndsAt - f.stateStartedAt) / move.startup
	f.attackIframesFrom = f.stateStartedAt + data.at * scale
	f.attackIframesUntil = if data.duration then f.attackIframesFrom + data.duration * scale else f.hitboxAt
end

return AttackIframes
