--!strict
-- One combat animation slot per fighter. Every combat animation in this game is authored at
-- Action priority, so letting two play at once blends them into each other. Here exactly one
-- combat track plays at a time: starting one stops whatever was playing.
--
-- A "base" animation (the block hold loop) is what the slot falls back to when a timed or
-- one-shot animation finishes, e.g. Block -> BlockLoop, or Blocked reaction -> BlockLoop.
--
-- Used by the client for its own character and by the server for dummies; animations played
-- by the owner replicate to everyone.
--
-- Replication rules (what the server and other players see):
--   * Only Play, Stop and AdjustSpeed replicate. TimePosition and Looped set from the client
--     do NOT, so a restart via TimePosition = 0 never reached the server, and a clip whose
--     asset loops kept looping there even though we set Looped = false locally.
--   * So every play is a fresh :Play() on one of two alternating tracks per animation
--     (back-to-back hits of the same clip restart properly), and one-shot clips always end
--     with an explicit :Stop() on a timer instead of relying on the clip ending by itself.
local RunService = game:GetService("RunService")
local ContentProvider = game:GetService("ContentProvider")

local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")

local Animations = Paths.Assets:WaitForChild("Animations")
local Generic = Animations:WaitForChild("Generic")
local Dash = Animations:WaitForChild("Dash")

-- Dash slots, relative to the body's facing. A slot with an empty AnimationId is skipped,
-- so dashes simply play nothing until the animation is filled in.
local DASH_SLOTS = { "Front", "Back", "Left", "Right" }

local FADE = 0.08

-- Groups decide what stopAttacks / setBlock(false) are allowed to interrupt.
-- `oneShot` clips always end on an explicit Stop after one pass (see header). Looped ones
-- (the block hold) run until replaced. Reactions that must last longer than their clip hold
-- the last frame instead of looping (see `freeze`).
local GENERIC: { { name: string, group: string, oneShot: boolean } } = {
	{ name = "Block", group = "block", oneShot = true },
	{ name = "BlockLoop", group = "block", oneShot = false },
	{ name = "Blocked", group = "react", oneShot = true },
	{ name = "WeakBlock", group = "react", oneShot = true },
	{ name = "Perfect Block", group = "react", oneShot = true },
	{ name = "Perfect Blocked", group = "react", oneShot = true },
	{ name = "Hitstun", group = "stun", oneShot = true },
	{ name = "Clash", group = "stun", oneShot = true }, -- both sides of a clash (user, 2026-10-14)
}

export type PlayOptions = {
	speed: number?,
	duration: number?, -- end (or return to base) after this long
	freeze: boolean?, -- hold the last frame if the clip is shorter than duration
	fallback: number?, -- one-shot end time to use while the clip's Length is still unknown
}

type Entry = {
	pair: { AnimationTrack },
	active: AnimationTrack?,
	group: string,
	oneShot: boolean,
}

local AnimationHandler = {}
AnimationHandler.__index = AnimationHandler

local function findAnim(path: string): Animation
	local node: Instance = Animations
	for part in string.gmatch(path, "[^/]+") do
		node = node:WaitForChild(part)
	end
	return node :: Animation
end

function AnimationHandler.new(animator: Animator, style: any)
	local self = setmetatable({}, AnimationHandler)
	self.entries = {} :: { [string]: Entry }
	self.current = nil :: string?
	self.base = nil :: string?
	self.gen = 0
	self.endConn = nil :: RBXScriptConnection?

	local assets: { Animation } = {}
	local function register(key: string, anim: Animation, group: string, oneShot: boolean)
		if anim.AnimationId == "" then
			return -- not uploaded yet: plays of this key are silently skipped
		end
		local pair = {}
		for i = 1, 2 do
			local track = animator:LoadAnimation(anim)
			track.Priority = Enum.AnimationPriority.Action
			if oneShot then
				track.Looped = false -- local only; the explicit Stop is what the server sees
			end
			pair[i] = track
		end
		self.entries[key] = { pair = pair, active = nil, group = group, oneShot = oneShot }
		table.insert(assets, anim)
	end

	for _, move in pairs(style.moves) do
		if not self.entries[move.anim] then
			register(move.anim, findAnim(move.anim), "attack", true)
		end
		if move.lead and not self.entries[move.lead.anim] then
			register(move.lead.anim, findAnim(move.lead.anim), "attack", true)
		end
		if move.rush and move.rush.loopAnim then
			register(move.rush.loopAnim, findAnim(move.rush.loopAnim), "attack", false)
		end
		if move.rush and move.rush.missAnim then
			register(move.rush.missAnim, findAnim(move.rush.missAnim), "attack", true)
		end
		if move.rush and move.rush.contactAnim and not self.entries[move.rush.contactAnim] then
			register(move.rush.contactAnim, findAnim(move.rush.contactAnim), "attack", true)
		end
		if move.charge and move.charge.loopAnim then
			register(move.charge.loopAnim, findAnim(move.charge.loopAnim), "attack", false)
		end
		if move.charge and move.charge.swing then
			register(move.charge.swing.anim, findAnim(move.charge.swing.anim), "attack", true)
		end
		if move.barrage then
			for _, path in move.barrage.anims do
				if not self.entries[path] then
					register(path, findAnim(path), "attack", true)
				end
			end
		end
	end
	for _, g in GENERIC do
		register(g.name, Generic:WaitForChild(g.name) :: Animation, g.group, g.oneShot)
	end
	for _, slot in DASH_SLOTS do
		local anim = Dash:WaitForChild(slot) :: Animation
		if anim.AnimationId ~= "" then
			register("Dash" .. slot, anim, "dash", true)
		end
	end
	-- Load the clips up front so the first hit already knows its Length and isn't skipped
	-- while the asset downloads.
	if RunService:IsClient() then
		task.spawn(ContentProvider.PreloadAsync, ContentProvider, assets)
	end
	return self
end

-- True if `track` is one of this handler's own tracks (not a replicated copy).
function AnimationHandler.owns(self: any, track: AnimationTrack): boolean
	for _, e: Entry in self.entries do
		if e.pair[1] == track or e.pair[2] == track then
			return true
		end
	end
	return false
end

-- Every AnimationId the combat slot can play for `style` (attacks + generic reactions).
function AnimationHandler.combatIds(style: any): { [string]: boolean }
	local ids = {}
	for _, move in pairs(style.moves) do
		ids[findAnim(move.anim).AnimationId] = true
		if move.lead then
			ids[findAnim(move.lead.anim).AnimationId] = true
		end
		if move.rush and move.rush.loopAnim then
			ids[findAnim(move.rush.loopAnim).AnimationId] = true
		end
		if move.rush and move.rush.missAnim then
			ids[findAnim(move.rush.missAnim).AnimationId] = true
		end
		if move.rush and move.rush.contactAnim then
			ids[findAnim(move.rush.contactAnim).AnimationId] = true
		end
		if move.charge and move.charge.loopAnim then
			ids[findAnim(move.charge.loopAnim).AnimationId] = true
		end
		if move.charge and move.charge.swing then
			ids[findAnim(move.charge.swing.anim).AnimationId] = true
		end
		if move.barrage then
			for _, path in move.barrage.anims do
				ids[findAnim(path).AnimationId] = true
			end
		end
	end
	for _, g in GENERIC do
		ids[(Generic:WaitForChild(g.name) :: Animation).AnimationId] = true
	end
	for _, slot in DASH_SLOTS do
		local id = (Dash:WaitForChild(slot) :: Animation).AnimationId
		if id ~= "" then
			ids[id] = true
		end
	end
	return ids
end

function AnimationHandler._track(self: any, key: string): AnimationTrack?
	local e: Entry? = self.entries[key]
	return if e then e.active or e.pair[1] else nil
end

function AnimationHandler._stopAll(self: any, except: AnimationTrack?, fade: number)
	for _, e: Entry in self.entries do
		for _, t in e.pair do
			if t ~= except and t.IsPlaying then
				t:Stop(fade)
			end
		end
	end
end

-- Starts `key` in the slot, stopping everything else. A newer play always wins: `gen`
-- makes any pending timer or Stopped handler from an older play do nothing.
function AnimationHandler.play(self: any, key: string, opts: PlayOptions?)
	local o: PlayOptions = opts or {}
	local e: Entry? = self.entries[key]
	if not e then
		return
	end
	self.gen += 1
	local gen = self.gen
	if self.endConn then
		self.endConn:Disconnect()
		self.endConn = nil
	end

	-- Alternate tracks so a repeat of the same clip is a fresh Play (replicates), not a
	-- TimePosition rewind (doesn't). A looped base that is already running is left alone.
	local speed = o.speed or 1
	local track: AnimationTrack
	if not e.oneShot and e.active and e.active.IsPlaying and o.duration == nil then
		track = e.active
		self:_stopAll(track, FADE)
		track:AdjustSpeed(speed)
	else
		track = if e.active == e.pair[1] then e.pair[2] else e.pair[1]
		self:_stopAll(track, FADE)
		if track.IsPlaying then
			track:Stop(0) -- still fading out from two plays ago
		end
		track:Play(FADE, 1, speed)
	end
	e.active = track
	self.current = key

	local length = track.Length
	local duration = o.duration
	if duration == nil and e.oneShot then
		duration = if length > 0 then length / speed else o.fallback
	end

	if duration then
		if o.freeze and length > 0 and duration > length / speed then
			task.delay(length * 0.95 / speed, function()
				if self.gen == gen then
					track:AdjustSpeed(0)
				end
			end)
		end
		task.delay(duration, function()
			if self.gen == gen then
				self:_finish()
			end
		end)
	end
	if e.oneShot and o.duration == nil then
		-- Length unknown and no fallback: end when the local clip ends (still with an
		-- explicit Stop in _finish).
		self.endConn = track.Stopped:Connect(function()
			if self.gen == gen then
				self:_finish()
			end
		end)
	end
end

-- The current animation is done: fall back to the base loop, or go quiet. Always stops the
-- track explicitly so the end replicates even if the clip already ended locally.
function AnimationHandler._finish(self: any)
	local key = self.current
	self.current = nil
	if self.endConn then
		self.endConn:Disconnect()
		self.endConn = nil
	end
	if self.base and self.base ~= key then
		self:play(self.base)
	elseif key then
		self.gen += 1
		local track = self:_track(key)
		if track then
			track:Stop(FADE)
		end
	end
end

-- Interrupts the current animation only if it belongs to `group`.
function AnimationHandler.stopGroup(self: any, group: string)
	local key = self.current
	if key and self.entries[key].group == group then
		self:_finish()
	end
end

---- Combat vocabulary used by CombatController, DummyService and Reactions ----

-- `held`: a swing charge move's button is still down (the owner calls playSwing on release);
-- otherwise (taps, dummies) its swing plays at the minimum windup by itself.
function AnimationHandler.playAttack(self: any, move: any, speed: number, held: boolean?)
	if move.fuse then
		return -- lighting a fuse has no animation; the fighter keeps doing whatever it was doing
	end
	-- Scale playback so the animation's hitbox marker lines up with the data startup.
	local align = if move.animHit then move.animHit / move.startup else 1
	if move.rush and not move.animHit then
		-- A rush windup has no hit moment: the whole clip is stretched over the startup.
		local track = self:_track(move.anim)
		local length = if track then track.Length else 0
		if length > 0 then
			align = length / move.startup
		end
	end
	if move.charge then
		-- Charge move: the windup clip over the minimum windup (holding its last frame), then the
		-- charge loop (charge.loopAnim) until the rush's clip, a hit or a stun replaces it. Viewers
		-- who can't know whether it's still held just see the loop start at the minimum.
		self:play(move.anim, { speed = align * speed, duration = 1e6, freeze = true })
		if move.charge.swing then
			if not held then
				local gen = self.gen
				task.delay(move.startup / speed, function()
					if self.gen == gen then
						self:playSwing(move)
					end
				end)
			end
			return
		end
		local loop = move.charge.loopAnim
		if loop and self.entries[loop] then
			local gen = self.gen
			task.delay(move.startup / speed, function()
				if self.gen == gen then
					self.base = nil
					self:play(loop)
				end
			end)
		end
		return
	end
	if move.lead then
		-- Two clips (Furious Feng dash kick): the lead clip holds through lead.time, then the main clip
		-- plays so its animHit lands at startup. An empty (not uploaded) lead just leaves the gap.
		local lead = move.lead
		self.base = nil
		if self.entries[lead.anim] then
			self:play(lead.anim, { speed = speed, duration = 1e6, freeze = true }) -- the main clip replaces it
		else
			-- Not uploaded: end whatever was playing (the dash clip), or its own end timer would bump
			-- `gen` mid-lead and the main clip would never start.
			self.gen += 1
			if self.endConn then
				self.endConn:Disconnect()
				self.endConn = nil
			end
			self:_stopAll(nil, FADE)
			self.current = nil
		end
		local gen = self.gen
		local rest = move.startup - lead.time
		local mainSpeed = (if move.animHit then move.animHit / rest else 1) * speed
		task.delay(lead.time / speed, function()
			if self.gen == gen then
				self:play(move.anim, { speed = mainSpeed, fallback = (rest + move.endlag) / speed })
			end
		end)
		return
	end
	if move.rush and not move.rush.loopAnim then
		-- No dash clip: the windup's last frame holds through the dash until the contact / miss clip,
		-- a hit or a stun replaces it (playRushLoop ends it at the latest).
		self:play(move.anim, { speed = align * speed, duration = 1e6, freeze = true })
		return
	end
	self:play(move.anim, {
		speed = align * speed,
		fallback = (move.startup + (if move.rush then 0 else move.endlag)) / speed,
	})
end

-- Rush reached someone: its contactAnim once (nothing if it has none, or it isn't uploaded).
function AnimationHandler.playRushContact(self: any, move: any)
	local anim = move.rush and move.rush.contactAnim
	if anim and self.entries[anim] then
		self.base = nil
		self:play(anim)
	end
end

-- Swing charge release: the swing clip once at its own speed (its hit is charge.swing.hit in).
function AnimationHandler.playSwing(self: any, move: any)
	self.base = nil
	self:play(move.charge.swing.anim, { fallback = move.charge.swing.hit + move.endlag })
end

-- Rush: the loop runs until something replaces it (contact, miss, stun).
function AnimationHandler.playRushLoop(self: any, move: any)
	if not (move.rush.loopAnim and self.entries[move.rush.loopAnim]) then
		-- No (uploaded) loop clip: whatever is playing keeps going, until the longest the rush, its
		-- carry and the whiff endlag could take (a hit or a stun ends it sooner).
		local r = move.rush
		local studs = r.freeStuds + (if move.charge then move.charge.studs else 0)
		local gen = self.gen
		local travel = if r.duration > 0 then r.duration else studs / r.speed
		task.delay(travel + r.carry + r.missEndlag, function()
			if self.gen == gen then
				self:_finish()
			end
		end)
		return
	end
	self.base = nil
	self:play(move.rush.loopAnim)
end

-- Miss: one pass of the miss clip over the carry + endlag, holding its last frame.
function AnimationHandler.playRushMiss(self: any, move: any)
	if not (move.rush.missAnim and self.entries[move.rush.missAnim]) then
		-- No miss clip: end whatever is playing (e.g. the dash clip) once the whiff endlag is over.
		local gen = self.gen
		task.delay(move.rush.carry + move.rush.missEndlag, function()
			if self.gen == gen then
				self:_finish()
			end
		end)
		return
	end
	self.base = nil
	self:play(move.rush.missAnim, { duration = move.rush.carry + move.rush.missEndlag, freeze = true })
end

-- Barrage: one clip per hit, cycling through barrage.anims. Any other play (stun, dash,
-- stopAttacks) bumps `gen` and ends the chain.
function AnimationHandler.playBarrage(self: any, move: any)
	local b = move.barrage
	local interval = b.duration / b.hits
	self.base = nil
	local function punch(i: number)
		-- Lasts a bit past the interval so the next punch (not _finish) replaces it.
		self:play(b.anims[(i - 1) % #b.anims + 1], { speed = b.animSpeed, duration = interval + 0.05 })
		if i < b.hits then
			local gen = self.gen
			task.delay(interval, function()
				if self.gen == gen then
					punch(i + 1)
				end
			end)
		end
	end
	punch(1)
end

-- Which dash slot a world direction is, relative to where the body faces (`look`):
-- the animation plays on the body, so it follows the body, not the camera.
function AnimationHandler.dashSlot(look: Vector3, dir: Vector3): string
	local facing = Vector3.new(look.X, 0, look.Z)
	local flat = Vector3.new(dir.X, 0, dir.Z)
	if facing.Magnitude < 1e-3 or flat.Magnitude < 1e-3 then
		return "Front"
	end
	facing, flat = facing.Unit, flat.Unit
	local right = facing:Cross(Vector3.yAxis)
	local f, r = flat:Dot(facing), flat:Dot(right)
	if math.abs(f) >= math.abs(r) then
		return if f >= 0 then "Front" else "Back"
	end
	return if r >= 0 then "Right" else "Left"
end

-- Dash: replaces whatever was playing (attack startup, block) and plays its full clip.
function AnimationHandler.playDash(self: any, look: Vector3, dir: Vector3)
	self.base = nil
	local key = "Dash" .. AnimationHandler.dashSlot(look, dir)
	if self.entries[key] then
		-- Plays the whole clip even past the dash's end (user, 2026-10-13); any new action replaces it.
		self:play(key, { fallback = D.DASH_DURATION + D.DASH_ENDLAG })
	else
		-- No animation in this slot yet: still end the attack / block it cancelled.
		self:stopGroup("attack")
	end
end

function AnimationHandler.stopAttacks(self: any)
	self:stopGroup("attack")
end

function AnimationHandler.setBlock(self: any, on: boolean)
	if on then
		self.base = "BlockLoop"
		-- Stretch the Block clip to exactly the block-start time the server uses, then hand
		-- off to the loop on that same timer.
		local block = self:_track("Block") :: AnimationTrack
		local length = block.Length
		local speed = if length > 0 then length / D.BLOCK_START_DURATION else 1
		self:play("Block", { duration = D.BLOCK_START_DURATION, speed = speed, freeze = true })
	else
		self.base = nil
		local group = self.current and self.entries[self.current].group
		if group == "block" or group == "react" then
			self:_finish()
		end
	end
end

-- Timed one-shot reaction (Blocked / Parryed): plays once, holds its last frame for the rest
-- of `duration`, then returns to the block loop if still blocking.
function AnimationHandler.pose(self: any, name: string, duration: number)
	self:play(name, { duration = duration, freeze = true })
end

-- Landed parry: guard is dropped, so the pose plays alone and never falls back to the block
-- loop. Holding F re-blocks through setBlock(true), which replaces the pose.
function AnimationHandler.parried(self: any, duration: number)
	self.base = nil
	self:play("Perfect Block", { duration = duration, freeze = true })
end

-- Hitstun ends any block and holds the recoil's last frame until the stun is over.
-- `clip` swaps the recoil for another stun clip (e.g. "Clash").
function AnimationHandler.stun(self: any, duration: number, clip: string?)
	self.base = nil
	self:play(clip or "Hitstun", { duration = duration, freeze = true })
end

function AnimationHandler.destroy(self: any)
	self.gen += 1
	self.base = nil
	self.current = nil
	if self.endConn then
		self.endConn:Disconnect()
		self.endConn = nil
	end
	self:_stopAll(nil, 0)
	-- Free the tracks: a style swap builds a new handler on the same Animator.
	for _, entry in self.entries do
		for _, track in entry.pair do
			track:Destroy()
		end
	end
	table.clear(self.entries)
end

return AnimationHandler
