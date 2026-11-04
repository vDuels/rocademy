--!strict
-- Starts Chrono on this client (same config as the server, Shared/ChronoSetup) and reports how
-- far behind we draw each active Chrono fighter, so the server's lag comp can rewind exactly
-- that far (ServerScriptService.Midori.ChronoService / LagComp).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local ChronoSetup = Paths.shared("ChronoSetup")

local REPORT_EVERY = 0.5

local ChronoClient = {}

function ChronoClient.init()
	if not D.CHRONO_ENABLED then
		return
	end
	ChronoSetup.start()
	local Chrono = ChronoSetup.chrono()
	local remote = Net.get(Net.Names.ChronoDelay)
	local localPlayer = Players.LocalPlayer
	task.spawn(function()
		while true do
			task.wait(REPORT_EVERY)
			-- Keyed by UserId string: remotes turn Instance keys into strings, which the server can't map back.
			local report: { [string]: number } = {}
			for _, entity in Chrono.Holder.idMap do
				local owner = entity._player
				local clock = entity._clientClock
				if owner and owner ~= localPlayer and clock and not entity.paused and not entity.destroyed then
					-- Each owner has its own clock: render time trails its latest (extrapolated) send time.
					local delay = clock:GetEstimatedServerTime() - clock:GetTargetRenderTime()
					if delay == delay and delay >= 0 then
						report[tostring(owner.UserId)] = delay
					end
				end
			end
			if next(report) then
				remote:FireServer(report)
			end
		end
	end)
end

return ChronoClient
