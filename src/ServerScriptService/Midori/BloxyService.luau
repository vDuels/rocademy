--!strict
-- Too much Bloxy Cola (user, 2026-10-27). SodaService calls onSip for every Bloxy Cola sip that lands.
-- Sips add up; D.BLOXY.soberDelay s after the last one the count starts dropping by D.BLOXY.soberRate a
-- second (user, 2026-11-01: effects wore off far too late, all at once). The tiers go by whole drinks (cans):
-- sips / D.SODA.sips. The tier replicates as the character
-- attribute "Drunk" (1 blurry, 2 drunk, nil sober):
--   blurAt+  : blurry vision (client BloxyController)
--   drunkAt+ : can't run (RunController), attacks slower (CombatService + CombatController mirror),
--              any hit knocks you out for D.BLOXY.hitKnock s (HitResolver -> knockDuration)
--   blackoutAt: knocked out for D.BLOXY.blackout s with a black screen ("BlackedOut"); the count resets.
-- Dying / respawning sobers you up.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Fighter = Paths.server("Fighter")

local B = D.BLOXY

type Drinking = { count: number, last: number } -- sips at the last sip, and when it was (os.clock)
local drinking: { [Player]: Drinking } = {}

local BloxyService = {}

-- Pure: the tier for `count` sips (0 sober, 1 blurry, 2 drunk, 3 blackout). Thresholds are in WHOLE
-- DRINKS (user, 2026-10-27): a full can is D.SODA.sips sips, so half a can counts as half a drink.
function BloxyService.tier(count: number): number
	local drinks = count / D.SODA.sips
	return if drinks >= B.blackoutAt then 3 elseif drinks >= B.drunkAt then 2 elseif drinks >= B.blurAt then 1 else 0
end

-- Pure: sips left `now`, from `count` sips as of the last sip at `last`.
function BloxyService.level(count: number, last: number, now: number): number
	local idle = now - last - B.soberDelay
	return if idle > 0 then math.max(0, count - idle * B.soberRate) else count
end

-- "Drunk" = the tier (gameplay); "BloxySips" = the raw sip count (the client's gradual blur and muffling).
local function setTier(player: Player, tier: number, sips: number?)
	local character = player.Character
	if character then
		character:SetAttribute("Drunk", if tier > 0 and tier < 3 then tier else nil)
		character:SetAttribute("BloxySips", sips)
	end
end

local function sober(player: Player)
	drinking[player] = nil
	setTier(player, 0, nil)
end

-- How long a hit knocks `f` out for because of Bloxy Cola (nil = not drunk enough: normal rules).
function BloxyService.hitKnock(f: any): number?
	local tier = f.model:GetAttribute("Drunk")
	return if typeof(tier) == "number" and tier >= 2 then B.hitKnock else nil
end

-- Returns true if this sip blacked them out (SodaService then drops the can).
function BloxyService.onSip(player: Player, f: any): boolean
	local now = os.clock()
	local d = drinking[player]
	if not d then
		d = { count = 0, last = now }
		drinking[player] = d
	end
	d.count = BloxyService.level(d.count, d.last, now) + 1
	d.last = now
	local tier = BloxyService.tier(d.count)
	if tier >= 3 then
		sober(player) -- the blackout is the end of the session
		if Fighter.alive(f) then
			f.model:SetAttribute("BlackedOut", true) -- cleared by KnockService.recover
			Paths.server("KnockService").knock(f, workspace:GetServerTimeNow(), B.blackout)
		end
		return true
	end
	setTier(player, tier, d.count)
	return false
end

function BloxyService.init()
	Players.PlayerRemoving:Connect(function(player)
		drinking[player] = nil
	end)
	-- Sobering up: once a second, everyone drinking gets their count (and tier / blur / muffle) lowered.
	task.spawn(function()
		while true do
			task.wait(1)
			local now = os.clock()
			for player, d in drinking do
				local left = BloxyService.level(d.count, d.last, now)
				if left <= 0 then
					sober(player)
				else
					setTier(player, BloxyService.tier(left), math.round(left * 10) / 10)
				end
			end
		end
	end)
	local function watch(player: Player)
		player.CharacterRemoving:Connect(function()
			drinking[player] = nil -- died / reset: sober (the new character has no attribute)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
end

return BloxyService
