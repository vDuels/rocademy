--!strict
-- Discord log of every admin give (user, 2026-11-01: "whenever someone gets something make sure I see it,
-- who gave, who received, what item. security reasons"). Server only: the webhook URL must never replicate.
-- Called from AdminService.give (rerolls / Bux), RerollService DevSet (furniture, Bux, styles, traits,
-- looks...; not when the setter is a Developer) and RoleService.set (roles). Needs Game Settings > Security > Allow HTTP Requests.
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local URL = "https://discord.com/api/webhooks/1566541030596022334/11HTJV4mTP_WukfbLsWwbaeGPcuBAVPISjFiBr_ZOgiyTHJdGwm_SDRO5Y59IT1BbqaH"

local GiveLog = {}

local function who(p: Player | number | string): string
	if typeof(p) == "Instance" and p:IsA("Player") then
		return `{p.DisplayName} (@{p.Name}, {p.UserId})`
	end
	return tostring(p)
end

-- `to` = a Player, or a UserId / text when they're offline (roles).
function GiveLog.log(from: Player, to: Player | number | string, what: string)
	local line = `**{who(from)}** gave **{who(to)}**: {what}`
		.. (if RunService:IsStudio() then " *(Studio)*" else ` *(server {string.sub(game.JobId, 1, 8)})*`)
	task.spawn(function()
		-- ponytail: one POST per give, no queue; Discord allows ~30/min per webhook, add a queue if gives burst past that.
		local ok, err = pcall(HttpService.PostAsync, HttpService, URL, HttpService:JSONEncode({
			content = string.sub(line, 1, 2000),
			allowed_mentions = { parse = {} },
		}), Enum.HttpContentType.ApplicationJson)
		if not ok then
			warn("[GiveLog] webhook failed:", err)
		end
	end)
end

return GiveLog
