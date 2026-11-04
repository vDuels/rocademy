--!strict
-- Redeemable codes (user, 2026-10-17). The list lives here, server-only, so clients can't read it.
-- Each player can redeem a code once (saved in PlayerData.Codes). Rewards: spins (rerolls), Bux, and/or
-- a worn Face (`face`, e.g. "Headless": saved to the server profile and applied by RerollService).
-- Add a code: an UPPERCASE key below; `expires` (optional) = UTC ISO date after which it stops working.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Net = Paths.shared("Net")

type Code = { spins: number?, bux: number?, face: string?, decor: string?, expires: string? }

local CODES: { [string]: Code } = {
	MIDORI = { spins = 67 },
	RELEASE = { spins = 250, bux = 50 },
	FENG = { spins = 30},
	GIONERF = { spins = 30},
	THEMAPISNEVERCOMING = { spins = 30},
	ZOMBIE = { spins = 30},	
	IKUNEM = { spins = 1},
	["BAR MONEY"] = { bux = 100 }, -- user, 2026-10-28 (the space is part of the code)
	TEST1 = { spins = 250 }, -- user, 2026-10-28
	DORMSORSOMETHING = { spins = 30 }, -- user, 2026-10-31
	["MOVING IN"] = { bux = 45 }, -- user, 2026-10-31
	["LARP FOOD"] = { bux = 25 }, -- user, 2026-10-31
	["IKUANDRORYDIDWHATNOW?"] = { face = "Headless" }, -- user, 2026-10-31
	["FENG WINNER"] = { spins = 30 }, -- user, 2026-10-31
	["FENG NERF"] = { spins = 30 }, -- user, 2026-10-31
	["FENG IS IMMORTAL"] = { spins = 50, decor = "FengTrophy" }, -- user, 2026-10-31 (special trophy, apartment decoration)
}

local MAX_LEN = 32

local CodeService = {}
CodeService.CODES = CODES -- tests

-- Pure: checks `raw` against `codes` and, if it's good, grants it into `data` (a PlayerData profile).
-- `now` = unix seconds. Returns ok + the message the player sees + whether the worn look changed.
function CodeService.redeem(data: any, raw: unknown, now: number, codes: { [string]: Code }?): (boolean, string, boolean)
	local list = codes or CODES
	if typeof(raw) ~= "string" or #raw > MAX_LEN * 4 then
		return false, "INVALID CODE", false
	end
	local code = string.upper((string.gsub(raw, "^%s*(.-)%s*$", "%1")))
	local def = list[code]
	if code == "" or #code > MAX_LEN or not def then
		return false, "INVALID CODE", false
	elseif def.expires and now >= DateTime.fromIsoDate(def.expires).UnixTimestamp then
		return false, "CODE EXPIRED", false
	elseif data.Codes[code] then
		return false, "ALREADY REDEEMED", false
	end
	data.Codes[code] = true
	local got = {}
	if def.spins then
		data.Spins += def.spins
		table.insert(got, `+{def.spins} REROLLS`)
	end
	if def.bux then
		data.Bux += def.bux
		table.insert(got, `+{def.bux} BUX`)
	end
	if def.face then
		-- The face you wore goes to the locker if there's room (store), so the code doesn't eat it.
		Paths.server("RerollService").store(data, "Face")
		Paths.server("PlayerData").worn(data).Appearance.Face = def.face
		table.insert(got, string.upper(def.face))
	end
	if def.decor then
		-- Owned in the server profile (PlayerData.Decor); the apartment reads it once that exists.
		data.Decor[def.decor] = (data.Decor[def.decor] or 0) + 1
		table.insert(got, "+SPECIAL TROPHY")
	end
	return true, table.concat(got, "  "), def.face ~= nil
end

function CodeService.init()
	local PlayerData = Paths.server("PlayerData")
	local RateLimit = Paths.server("RateLimit")
	local RerollService = Paths.server("RerollService")
	local result = Net.get(Net.Names.CodeResult)
	Net.get(Net.Names.RedeemCode).OnServerEvent:Connect(function(player: Player, raw: unknown)
		if not RateLimit.take(player, "Code") then
			result:FireClient(player, false, "SLOW DOWN")
			return
		end
		local data = PlayerData.get(player)
		if not data then
			result:FireClient(player, false, "STILL LOADING, TRY AGAIN")
			return
		end
		local ok, message, lookChanged = CodeService.redeem(data, raw, os.time())
		if ok then
			player:SetAttribute("Spins", data.Spins)
			player:SetAttribute("Bux", data.Bux)
			if lookChanged then
				RerollService.commit(player, data) -- saves + wears it
			end
			Paths.server("ApartmentService").ownedChanged(player) -- a furniture code while in your apartment shows up now
		end
		result:FireClient(player, ok, message)
	end)
end

return CodeService
