--!strict
-- TEMP diagnostic (2026-10-28, user: "animations can get stuck on server side, never been an issue before").
-- Runs on the server (every fighter) and on each client (its own character), so the two views can be
-- compared. Every SCAN seconds it looks at each Animator's playing tracks and warns once per track when:
--   HELD    a non-looped track sits at its end (TimePosition ~ Length) for HOLD s: its Stop never came
--   FROZEN  a track with Speed > 0 hasn't moved for HOLD s mid-clip
--   PAUSED  a track at Speed 0 (AdjustSpeed(0) hold) for PAUSE_HOLD s
--   LEAK    an Animator has more than LEAK tracks loaded/playing
-- Plus, on the server only, a once-a-second "summary" of what's playing on each player while anything is stuck.
-- Remove with D.ANIM_DEBUG = false (or delete this module + its two init lines).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")

local Paths = require(script.Parent.Parent:WaitForChild("Paths"))

local SCAN = 0.25
local HOLD = 0.75
local LEAK = 60
local PAUSE_HOLD = 3

local AnimDebug = {}

-- AnimationId -> "Folder/Name" under Assets.Animations, for readable output.
local names: { [string]: string } = {}
local function indexNames()
	local root = Paths.Assets:FindFirstChild("Animations")
	if not root then
		return
	end
	for _, a in root:GetDescendants() do
		if a:IsA("Animation") and a.AnimationId ~= "" then
			local path = a:GetFullName():match("Animations%.(.+)$") or a.Name
			names[a.AnimationId] = string.gsub(path, "%.", "/")
		end
	end
end

local function label(track: AnimationTrack): string
	local id = track.Animation and track.Animation.AnimationId or "?"
	return `{names[id] or track.Name} ({id})`
end

local function describe(track: AnimationTrack): string
	return string.format("%s prio=%s looped=%s speed=%.2f t=%.2f/%.2f weight=%.2f",
		label(track), track.Priority.Name, tostring(track.Looped), track.Speed, track.TimePosition, track.Length, track.WeightCurrent)
end

type Seen = { t: number, since: number, warned: boolean }

local function watch(getModels: () -> { Model }, side: string)
	local seen: { [AnimationTrack]: Seen } = {} -- rebuilt every scan: only tracks still playing (no weak keys)
	local lastSummary = 0
	task.spawn(function()
		while true do
			task.wait(SCAN)
			local now = os.clock()
			local anyStuck = false
			local nextSeen: { [AnimationTrack]: Seen } = {}
			for _, model in getModels() do
				local humanoid = model:FindFirstChildOfClass("Humanoid")
				local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
				if not animator then
					continue
				end
				local playing = animator:GetPlayingAnimationTracks()
				if #playing > LEAK then
					warn(`[ANIMDEBUG {side}] LEAK {model.Name}: {#playing} playing tracks`)
				end
				for _, track in playing do
					local s = seen[track]
					if not s or math.abs(track.TimePosition - s.t) > 1e-3 then
						nextSeen[track] = { t = track.TimePosition, since = now, warned = s ~= nil and s.warned }
						continue
					end
					nextSeen[track] = s
					if now - s.since < HOLD then
						continue
					end
					local atEnd = track.Length > 0 and track.TimePosition >= track.Length - 0.05
					-- PAUSED (2026-11-02, Reentry "stuck in pose, only server sided"): AnimationHandler holds clips with
					-- AdjustSpeed(0) (freeze / rush windups); legit holds end within a stun or rush, so > PAUSE_HOLD is stuck.
					local kind = if atEnd and not track.Looped then "HELD"
						elseif track.Speed > 0 and not atEnd then "FROZEN"
						elseif track.Speed == 0 and now - s.since >= PAUSE_HOLD then "PAUSED"
						else nil
					if kind then
						anyStuck = true
						if not s.warned then
							s.warned = true
							warn(`[ANIMDEBUG {side}] {kind} {model.Name} for {string.format("%.1f", now - s.since)}s: {describe(track)} | state={tostring(model:GetAttribute("MState"))} style={tostring(model:GetAttribute("Style"))}`)
						end
					end
				end
			end
			seen = nextSeen
			if anyStuck and side == "server" and now - lastSummary > 1 then
				lastSummary = now
				for _, model in getModels() do
					local humanoid = model:FindFirstChildOfClass("Humanoid")
					local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
					if animator then
						local list = {}
						for _, track in animator:GetPlayingAnimationTracks() do
							table.insert(list, describe(track))
						end
						warn(`[ANIMDEBUG server] playing on {model.Name}: {#list} -> {table.concat(list, "  ||  ")}`)
					end
				end
			end
		end
	end)
end

-- Server: every fighter (players + dummies). Client: our own character only.
function AnimDebug.start()
	if not Paths.data("Defaults").ANIM_DEBUG then
		return
	end
	indexNames()
	if RunService:IsServer() then
		watch(function(): { Model }
			local list = {}
			for _, m in CollectionService:GetTagged("MidoriFighter") do
				if m:IsA("Model") then
					table.insert(list, m)
				end
			end
			return list
		end, "server")
	else
		watch(function(): { Model }
			local c = Players.LocalPlayer.Character
			return if c then { c } else {}
		end, "client")
	end
end

return AnimDebug
