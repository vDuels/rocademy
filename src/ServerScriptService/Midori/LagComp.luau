--!strict
-- Lag compensation. A player swings at what their screen shows, which is everyone else
-- about their ping + an interpolation delay in the past (Chrono's measured buffer for
-- fighters on Chrono, Roblox's assumed one otherwise). The server keeps a short
-- history of every fighter's root so a player's hitbox can be checked against where the
-- victims were on the attacker's screen. Only positions are rewound: blocks, parries and
-- i-frames are still judged at server time, so lag never beats a defence that already happened.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Hitbox = Paths.shared("Hitbox")
local ChronoService = Paths.server("ChronoService")

type Sample = { t: number, cf: CFrame }

local KEEP = 1 -- seconds of history per fighter (well past LAGCOMP_MAX)

local history: { [any]: { Sample } } = setmetatable({}, { __mode = "k" }) :: any

local LagComp = {}

-- Called every server step, before hitboxes resolve.
function LagComp.record(f: any, now: number)
	local h = history[f]
	if not h then
		h = {}
		history[f] = h
	end
	table.insert(h, { t = now, cf = f.root.CFrame })
	while #h > 2 and now - h[1].t > KEEP do
		table.remove(h, 1)
	end
end

-- Where `f`'s root was at time `t` (interpolated between samples, clamped to the history).
function LagComp.cframeAt(f: any, t: number): CFrame
	local h = history[f]
	if not h or #h == 0 then
		return f.root.CFrame
	end
	if t <= h[1].t then
		return h[1].cf
	end
	for i = #h, 1, -1 do
		local s = h[i]
		if s.t <= t then
			local nxt = h[i + 1]
			if not nxt then
				return s.cf
			end
			return s.cf:Lerp(nxt.cf, (t - s.t) / (nxt.t - s.t))
		end
	end
	return h[1].cf
end

-- Prefers Chrono's own history while `f` is on Chrono (exact arrival times), else ours.
local function pastCFrame(f: any, t: number): CFrame
	return ChronoService.cframeAt(f, t) or LagComp.cframeAt(f, t)
end

-- How far back `a`'s screen shows `v`: a's round trip, plus how far behind a draws v (measured
-- by Chrono when v is on it, else Roblox's assumed delay). Server-run fighters see the present.
function LagComp.rewind(a: any, v: any): number
	if not a.player then
		return 0
	end
	local interp = ChronoService.renderDelay(a, v) or D.LAGCOMP_INTERP
	return math.clamp(a.player:GetNetworkPing() + interp, 0, D.LAGCOMP_MAX)
end

-- Where `v`'s root was on `a`'s screen at `now` (the present for server-run attackers).
function LagComp.seenAt(a: any, v: any, now: number): CFrame
	if not a.player then
		return v.root.CFrame
	end
	return pastCFrame(v, now - LagComp.rewind(a, v))
end

-- How long a hit on `v` waits for their defence presses still in flight: their one-way ping
-- plus a server tick, capped. Server-run fighters have nothing in flight.
function LagComp.grace(v: any): number
	if not v.player then
		return 0
	end
	return math.clamp(v.player:GetNetworkPing() / 2 + 1 / 60, 0, D.DEFENSE_GRACE_MAX)
end

-- Hitbox.query for attacker `a`, but each candidate is tested where it was on a's screen
-- (now - LagComp.rewind(a, victim)). Rather than moving anyone, the hitbox is moved by the
-- victim's offset since then: overlapping the victim's past pose P is the same as the box
-- shifted by (current * P^-1) overlapping its current pose.
function LagComp.query(a: any, cf: CFrame, box: any, candidates: { Model }, fighterOf: (Model) -> any?, now: number): { Model }
	local hits: { Model } = {}
	local center = (cf * box.offset).Position
	local reach = box.size.Magnitude / 2 + 6 -- box half-diagonal + a character's size
	for _, model in candidates do
		local f = fighterOf(model)
		local past = if f then pastCFrame(f, now - LagComp.rewind(a, f)) else nil
		if past and (past.Position - center).Magnitude > reach then
			continue -- nowhere near: skip the overlap query
		end
		local shift = if f and past then f.root.CFrame * past:Inverse() else CFrame.identity
		if Hitbox.contains(shift * cf, box, model) then
			table.insert(hits, model)
		end
	end
	return hits
end

return LagComp
