--!strict
-- Runs one cutscene actor's cues (Data/Cutscenes actors[role].cues).
--   Movement (cf / dash / orbit) runs on the machine that owns the body: a player's client for its
--   own character, the server for dummies. It replicates like any movement.
--   Clips run locally on EVERY client, for every actor (CutsceneController), like RemoteAnimator does
--   for combat: replicated combat clips are stopped on other screens, so a replicated copy would never
--   show. RemoteAnimator leaves tracks this module made alone (CutsceneTimeline.owns).
--   cue = { t, cf?, dash?, orbit?, anim?, m1?, crit?, speed?, idle? }
--   cf     teleport to anchor * cf
--   dash   { distance, duration, dir? }: DashMotor push along the facing ("Front" default, "Back",
--          "Left", "Right")
--   orbit  { center, radius, from, to, duration }: dash round `center` (anchor space) along the circle
--          from angle `from` to `to` (radians; 0 = +Z, as Data/Cutscenes' around()), facing the center
--   anim   path under Assets.Animations; `m1` = i plays the actor's own style's i-th M1 clip instead,
--          started early so its punch (the move's animHit at `speed`) lands at t, whatever the style;
--          `crit` = true does the same with the actor's own critical.
--          Either plays at `speed`, cutting off the actor's previous cue clip.
--   idle   fades the cue clip out: back to whatever the actor was playing underneath (its idle).
local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")
local DashMotor = Paths.shared("DashMotor")
local CombatMath = Paths.shared("CombatMath")
local MoveSchema = Paths.shared("MoveSchema")

local CutsceneTimeline = {}

-- Client hook: what a dash looks/sounds like (CutsceneController: the normal dash's sound + flash and
-- the afterimage trail). Called with the dash's duration for every dash / orbit cue where clips run.
CutsceneTimeline.onDash = nil :: ((root: BasePart, duration: number) -> ())?

local mine: { [AnimationTrack]: boolean } = setmetatable({}, { __mode = "k" }) :: any

-- True for a clip a cutscene is playing locally (RemoteAnimator must not stop it).
function CutsceneTimeline.owns(track: AnimationTrack): boolean
	return mine[track] == true
end

local function animation(path: string): Animation?
	local node: Instance? = Paths.Assets:FindFirstChild("Animations")
	for part in string.gmatch(path, "[^/]+") do
		node = node and node:FindFirstChild(part)
	end
	return if node and node:IsA("Animation") then node else nil
end

-- The actor's own style's move for a cue (`m1` = i: the i-th M1, `crit`: the critical): its clip,
-- and how far into the clip (at 1x) the hit lands.
local function moveOf(model: Model, cue: any): (string?, number)
	local style = MoveSchema.ofModel(model)
	local id = if cue.crit then style.r else style.m1Chain[(cue.m1 - 1) % #style.m1Chain + 1]
	local move = id and style.moves[id]
	if not move then
		return nil, 0
	end
	return move.anim, move.animHit or move.startup
end

-- Holds `root`'s facing (set each frame by the orbit's steer) for `duration`.
local function holdFacing(root: BasePart, duration: number): AlignOrientation
	local align = Instance.new("AlignOrientation")
	align.Name = "MidoriCutsceneFace"
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = root:FindFirstChild("RootAttachment") :: Attachment?
	align.RigidityEnabled = true
	align.CFrame = root.CFrame.Rotation
	align.Parent = root
	task.delay(duration, align.Destroy, align)
	return align
end

local DIRS: { [string]: (CFrame) -> Vector3 } = {
	Front = function(cf) return cf.LookVector end,
	Back = function(cf) return -cf.LookVector end,
	Left = function(cf) return -cf.RightVector end,
	Right = function(cf) return cf.RightVector end,
}

-- The cues' movement, in time order (data builds them roughly in order; this makes it exact).
function CutsceneTimeline.sorted(cues: { any }): { any }
	local list = table.clone(cues)
	table.sort(list, function(a, b)
		return a.t < b.t
	end)
	return list
end

-- Where the cues put the body at `t` (seconds in), starting from `start`: the same teleports, orbits
-- and dashes `run` makes the owner perform, replayed exactly (DashMotor's own curve), so a local
-- puppet (CutscenePuppet) can stand in for a body whose replicated movement arrives late.
-- `cues` must be time-sorted (CutsceneTimeline.sorted).
function CutsceneTimeline.pose(cues: { any }, anchor: CFrame, t: number, start: CFrame): CFrame
	local cf = start
	for _, cue in cues do
		if cue.t > t then
			break
		end
		if cue.cf then
			cf = anchor * cue.cf
		elseif cue.orbit then
			local o = cue.orbit
			local e = DashMotor.ease(math.clamp((t - cue.t) / o.duration, 0, 1))
			local a = o.from + (o.to - o.from) * e
			local center = anchor:PointToWorldSpace(o.center)
			local pos = anchor:PointToWorldSpace(o.center + Vector3.new(math.sin(a) * o.radius, 0, math.cos(a) * o.radius))
			cf = CFrame.lookAt(pos, Vector3.new(center.X, pos.Y, center.Z))
		elseif cue.dash then
			local d = cue.dash
			local e = DashMotor.ease(math.clamp((t - cue.t) / d.duration, 0, 1))
			cf = cf + CombatMath.flat(DIRS[d.dir or "Front"](cf)) * d.distance * e
		end
	end
	return cf
end

-- Schedules `cues` from server time `startAt`: movement if `move`, clips if `animate`.
-- Returns a stop function (cancels what's left).
function CutsceneTimeline.run(model: Model, cues: { any }, anchor: CFrame, startAt: number, move: boolean, animate: boolean): () -> ()
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not animator or not root then
		return function() end
	end
	local tracks: { [string]: AnimationTrack } = {}
	local current: AnimationTrack? = nil
	local playSeq = 0 -- bumps per cue clip: a newer clip cancels the older one's timed stop
	local done = false -- the cutscene's cleanup ran: its tracks are freed
	local cancelDash: (() -> ())? = nil
	local threads: { thread } = {}
	local cleared = false
	-- The facing the cues mean (upright, yaw only), as `pose` replays it: set by cf cues and orbits. A dash
	-- goes along THIS and holds it, never the live body's facing (user, 2026-10-29: the attacker sometimes
	-- faced the wrong way; shift lock / AutoRotate could turn the body between cues).
	local function upright(cf: CFrame): CFrame
		local look = CombatMath.flat(cf.LookVector)
		return CFrame.lookAlong(Vector3.zero, if look ~= Vector3.zero then look else Vector3.new(0, 0, -1))
	end
	local facing = upright(root.CFrame)

	local function play(path: string, speed: number)
		if not cleared then
			-- The first cue clip: whatever the actor was swinging (the move that started the cutscene,
			-- held through its impact frame) gives way now, not at t = 0.
			cleared = true
			for _, track in animator:GetPlayingAnimationTracks() do
				if track.Priority.Value >= Enum.AnimationPriority.Action.Value and not mine[track] then
					track:Stop(0.1)
				end
			end
		end
		local track = tracks[path]
		if not track then
			local anim = animation(path)
			if not anim then
				return
			end
			track = animator:LoadAnimation(anim)
			track.Priority = Enum.AnimationPriority.Action4
			track.Looped = false -- nothing hangs or loops once the cues are done
			mine[track] = true
			tracks[path] = track
		end
		if current and current ~= track then
			current:Stop(0.05)
		end
		if track.IsPlaying then
			track:Stop(0) -- the same clip again (victim flinches): restart it
		end
		track:Play(0.05, 1, speed)
		current = track
		-- End every cue clip with an explicit Stop when it's done here. Looped = false and the play speed
		-- never replicate, so without it the server's (and others') copy of a clip on our own body runs
		-- on at 1x / loops / holds a pose until the cutscene's cleanup: the post-cutscene freeze (user,
		-- 2026-10-28). Same rule as AnimationHandler's timed one-shot stops.
		playSeq += 1
		local seq = playSeq
		task.spawn(function()
			local waited = 0
			while track.Length <= 0 and waited < 1 do -- not loaded yet
				waited += task.wait()
			end
			if track.Length <= 0 then
				return
			end
			task.wait(math.max(0, track.Length / math.max(speed, 0.01) - waited))
			if not done and playSeq == seq and track.IsPlaying then
				track:Stop(0.1)
				if current == track then
					current = nil
				end
			end
		end)
	end

	local function orbit(o: any)
		local center = anchor:PointToWorldSpace(o.center)
		local sign = if o.to >= o.from then 1 else -1
		local align = holdFacing(root, o.duration)
		-- Along the circle's tangent, nudged back onto the radius, turning to face the center as it goes.
		local function steer(): Vector3
			local rel = anchor:VectorToObjectSpace((root.Position - center) * Vector3.new(1, 0, 1))
			local phi = math.atan2(rel.X, rel.Z)
			local out = Vector3.new(math.sin(phi), 0, math.cos(phi))
			local tangent = Vector3.new(math.cos(phi), 0, -math.sin(phi)) * sign
			local dir = anchor:VectorToWorldSpace(tangent + out * (o.radius - rel.Magnitude) * 2)
			if align.Parent then
				align.CFrame = CFrame.lookAt(Vector3.zero, -anchor:VectorToWorldSpace(out))
			end
			return CombatMath.flat(dir)
		end
		cancelDash = DashMotor.apply(root, steer(), o.radius * math.abs(o.to - o.from), o.duration, D.DASH_MAX_FORCE, steer, false, nil, true)
	end

	for _, cue in cues do
		local moves = move and (cue.cf or cue.dash or cue.orbit)
		-- An `m1` / `crit` cue's t is when its hit lands: the clip starts that much earlier for this style.
		local m1Path, m1Hit = nil, 0
		if cue.m1 or cue.crit then
			m1Path, m1Hit = moveOf(model, cue)
		end
		local path = if animate then cue.anim or m1Path else nil
		local idle = animate and cue.idle
		if not (moves or path or idle) then
			continue
		end
		local at = cue.t - (if path == m1Path then m1Hit / (cue.speed or 1) else 0)
		table.insert(threads, task.delay(math.max(0, startAt + at - workspace:GetServerTimeNow()), function()
			if not model.Parent then
				return
			end
			if moves then
				if cue.cf then
					root.AssemblyLinearVelocity = Vector3.zero
					root.CFrame = anchor * cue.cf
					facing = upright(anchor * cue.cf)
				end
				if cue.dash or cue.orbit then
					if cancelDash then
						cancelDash()
					end
					if cue.orbit then
						orbit(cue.orbit)
						-- Ends facing the centre from angle `to` (as pose does).
						local o = cue.orbit
						local center = anchor:PointToWorldSpace(o.center)
						local pos = anchor:PointToWorldSpace(o.center + Vector3.new(math.sin(o.to) * o.radius, 0, math.cos(o.to) * o.radius))
						facing = upright(CFrame.lookAt(pos, Vector3.new(center.X, pos.Y, center.Z)))
					else
						root.CFrame = CFrame.new(root.Position) * facing
						holdFacing(root, cue.dash.duration).CFrame = facing
						local dir = DIRS[cue.dash.dir or "Front"](facing)
						cancelDash = DashMotor.apply(root, CombatMath.flat(dir), cue.dash.distance, cue.dash.duration, D.DASH_MAX_FORCE, nil, false, nil, true)
					end
				end
			end
			if path then
				play(path, cue.speed or 1)
			end
			if animate and (cue.dash or cue.orbit) and CutsceneTimeline.onDash then
				CutsceneTimeline.onDash(root, (cue.dash or cue.orbit).duration)
			end
			if idle and current then
				current:Stop(0.3)
				current = nil
			end
		end))
	end
	return function()
		for _, thread in threads do
			pcall(task.cancel, thread)
		end
		if cancelDash then
			cancelDash()
		end
		-- Stop AND free: every cutscene loads its own tracks, and stopped-but-alive tracks count toward
		-- the Animator's 256-track cap; past it animations stop playing (user, 2026-10-28: stuck anims).
		done = true
		for _, track in tracks do
			track:Stop(0.2)
			task.delay(0.3, track.Destroy, track)
		end
		table.clear(tracks)
	end
end

return CutsceneTimeline