--!strict
-- Chrono for every living fighter. Every player character is a Chrono entity (Shared/ChronoSetup);
-- this only pauses it on death. While active, lag comp reads Chrono's snapshot history
-- and each attacker's measured render delay instead of guessing (see LagComp).
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local ChronoSetup = Paths.shared("ChronoSetup")
local Registry = Paths.server("FighterRegistry")
local Fighter = Paths.server("Fighter")
local RateLimit = Paths.server("RateLimit")

local CHECK_EVERY = 0.25 -- seconds between combat checks

local ChronoService = {}

local Chrono: any = nil -- set by init; nil in tests, so everything falls back to LagComp's own data
-- When each entity last went active (a respawn is a new entity, which starts unpaused).
local activeSince: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any
-- delays[attacker][victim] = how far behind the attacker draws the victim (client-reported).
local delays: { [Player]: { [Player]: number } } = {}

local function entityOf(f: any): any?
	if not Chrono or not f.player then
		return nil
	end
	local entity = Chrono.Holder.GetEntityFromPlayer(f.player)
	if entity and entity.model == f.model and not entity.destroyed then
		return entity
	end
	return nil
end

-- Always on while alive (user, 2026-10-14): toggling it with combat mode made characters teleport on
-- other screens. On resume Chrono bridges from the stale pre-pause snapshot; on pause Roblox's own
-- replication takes over at a different delay. Never pause/resume a moving character.
local function wantsChrono(f: any, _now: number): boolean
	return Fighter.alive(f)
end

-- Active and with enough history behind it for any rewind (LAGCOMP_MAX).
local function settled(f: any, entity: any): boolean
	local since = activeSince[entity]
	return not entity.paused and since ~= nil and os.clock() - since >= D.LAGCOMP_MAX
end

-- Where Chrono's server history says `f`'s root was at server time `t`, or nil when `f` isn't
-- (settled) on Chrono. Chrono's history runs on os.clock, ours on GetServerTimeNow.
function ChronoService.cframeAt(f: any, t: number): CFrame?
	local entity = entityOf(f)
	if not entity or not settled(f, entity) then
		return nil
	end
	local offset = workspace:GetServerTimeNow() - os.clock()
	return Chrono.Entity.GetAt(entity, t - offset)
end

-- How far behind `a`'s screen draws `v` (Chrono's buffer, measured on a's client), or nil when
-- v isn't on Chrono or a hasn't reported it yet.
function ChronoService.renderDelay(a: any, v: any): number?
	local entity = entityOf(v)
	if not entity or not settled(v, entity) or not a.player then
		return nil
	end
	local mine = delays[a.player]
	return mine and mine[v.player]
end

local function check()
	local now = workspace:GetServerTimeNow()
	for _, f in Registry.all() do
		local entity = entityOf(f)
		if not entity then
			continue
		end
		if wantsChrono(f, now) then
			if entity.paused then
				Chrono.Entity.ResumeReplication(entity)
			end
			activeSince[entity] = activeSince[entity] or os.clock()
		else
			if not entity.paused then
				Chrono.Entity.PauseReplication(entity)
			end
			activeSince[entity] = nil
		end
	end
end

function ChronoService.init()
	if not D.CHRONO_ENABLED then
		return -- Chrono stays nil: cframeAt/renderDelay return nil and LagComp uses its own data
	end
	ChronoSetup.start()
	Chrono = ChronoSetup.chrono()
	-- Chrono's client always reports its character's death, but we run REPLICATE_DEATHS = NONE, so
	-- Chrono never listens and Roblox warns "invocation discarded". Drain it.
	local deathRemote = ReplicatedStorage.Lib.Chrono.Shared.Remotes:FindFirstChild("Death")
	if deathRemote and deathRemote:IsA("RemoteEvent") then
		deathRemote.OnServerEvent:Connect(function() end)
	end

	Net.get(Net.Names.ChronoDelay).OnServerEvent:Connect(function(player: Player, report: any)
		if typeof(report) ~= "table" or not RateLimit.take(player, "ChronoDelay") then
			return
		end
		local clean: { [Player]: number } = {}
		local n = 0
		for key, delay in report do
			n += 1
			if n > 50 then
				break
			end
			-- Keys are UserId strings (Instance keys don't survive a remote).
			local id = if type(key) == "string" then tonumber(key) else nil
			local victim = if id then Players:GetPlayerByUserId(id) else nil
			if victim and type(delay) == "number" and delay == delay then
				clean[victim] = math.clamp(delay, 0, D.CHRONO_DELAY_MAX)
			end
		end
		delays[player] = clean
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		delays[player] = nil
	end)

	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc >= CHECK_EVERY then
			acc = 0
			check()
		end
	end)
end

return ChronoService
