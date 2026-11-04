--!strict
-- Chambered Dash logic (data: Data/Perks/ChamberedDash). It only ever touches the fighter's
-- generic bonus-dash charges; CombatService spends those when the normal dash is on cooldown.
-- The fill progress is mirrored to the "Chamber" attribute (0-1) for the HUD.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Fighter = Paths.server("Fighter")

type State = { progress: number, loaded: boolean, mirrored: number }

local ChamberedDash = {}

local function mirror(f: any, s: State, force: boolean?)
	if force or math.abs(s.progress - s.mirrored) >= 0.02 or (s.progress >= 1) ~= (s.mirrored >= 1) then
		s.mirrored = s.progress
		f.model:SetAttribute("Chamber", math.round(s.progress * 100) / 100)
	end
end

function ChamberedDash.attach(f: any, _data: any): State
	local s: State = { progress = 0, loaded = false, mirrored = -1 }
	mirror(f, s, true)
	return s
end

function ChamberedDash.detach(f: any, data: any, s: State)
	if s.loaded then
		Fighter.addBonusDashes(f, -data.charges)
	end
	f.model:SetAttribute("Chamber", nil)
end

function ChamberedDash.tick(f: any, data: any, s: State, now: number, dt: number)
	if s.loaded then
		if f.bonusDashes > 0 then
			return -- still chambered
		end
		-- The chambered dash was burned: start filling again from empty.
		s.loaded = false
		s.progress = 0
		mirror(f, s, true)
	end
	-- Only fills while the normal dash is ready; on cooldown it holds its progress.
	if now < f.dashCooldownUntil then
		return
	end
	s.progress = math.min(1, s.progress + dt / data.fillTime)
	if s.progress >= 1 then
		s.loaded = true
		Fighter.addBonusDashes(f, data.charges)
	end
	mirror(f, s)
end

-- A landed move with `chamberRefund` (none use it now; the dash kick's 0.3 was removed 2026-11-03) refills that share of the chamber,
-- dash cooldown or not. mods.hitDashRefund (Fury) adds that many seconds of fill on every landed hit.
function ChamberedDash.onLanded(f: any, data: any, s: State, move: any, _now: number)
	local refund = (move.chamberRefund or 0) + f.mods.hitDashRefund / data.fillTime
	if refund <= 0 or (s.loaded and f.bonusDashes > 0) then
		return -- nothing to refund, or still chambered
	end
	if s.loaded then
		s.loaded, s.progress = false, 0 -- burned this frame, before tick noticed
	end
	s.progress = math.min(1, s.progress + refund)
	if s.progress >= 1 then
		s.loaded = true
		Fighter.addBonusDashes(f, data.charges)
	end
	mirror(f, s, true)
end

return ChamberedDash
