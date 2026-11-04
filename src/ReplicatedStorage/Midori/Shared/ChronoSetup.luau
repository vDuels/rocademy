--!strict
-- Chrono (Lib/Chrono, Parihsz's custom character replication) setup. Server and client must
-- configure it identically, so both call ChronoSetup.start() and nothing else touches Config.
-- Every player character becomes a Chrono entity (AUTOMATIC), but ServerScriptService.Midori.
-- ChronoService keeps it PAUSED (plain Roblox replication) unless that fighter is in combat.
local Paths = require(game:GetService("ReplicatedStorage"):WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")

local ChronoSetup = {}

local started = false

-- Requires Chrono lazily: requiring it starts listeners, which tests must not do.
function ChronoSetup.chrono(): any
	return Paths.lib("Chrono")
end

function ChronoSetup.start()
	if started then
		return
	end
	started = true
	local Chrono = ChronoSetup.chrono()
	local Config = Chrono.Config
	Config.SetConfig("CHECK_NEW_VERSION", false) -- an HTTP call on every server start
	Config.SetConfig("REPLICATE_DEATHS", "NONE") -- Roblox already replicates deaths
	Config.RegisterEntityType("PLAYER", {
		MODEL_REPLICATION_MODE = "NATIVE", -- the server keeps real physics; Chrono only drives what viewers draw
		BUFFER = 0, -- 0 = Chrono sizes each owner's buffer from their jitter
		TICK_RATE = D.CHRONO_TICK_RATE,
		NORMAL_TICK_DISTANCE = D.CHRONO_FULL_RATE_DISTANCE,
		-- Never stop sending: a client that loses an entity moves the character to y = 1,000,000.
		HALF_TICK_DISTANCE = math.huge,
		ASSEMBLY_ROOT_PART_CHECK = true,
	})
	Chrono.Start()
end

function ChronoSetup.started(): boolean
	return started
end

return ChronoSetup
