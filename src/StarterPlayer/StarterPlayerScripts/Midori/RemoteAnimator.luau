--!strict
-- Plays OTHER fighters' combat animations locally (players and dummies), driven by the
-- events the server already broadcasts: AttackStarted, DashStarted, HitResult, plus the
-- replicated MState / BlockPressAt attributes.
--
-- Why: animations replicate owner -> server -> other clients. The server copy is clean, but
-- the second hop drops or reorders short tracks (parry, parried, hitstun, quick restarts),
-- so other people's animations bugged out while your own never did. Here every client runs
-- the same AnimationHandler for everyone it sees, and the replicated copies of combat tracks
-- are stopped so they can't fight the local ones. Locomotion (walk/run/idle) still replicates.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Enums = Paths.shared("Enums")
local Net = Paths.shared("Net")
local MoveSchema = Paths.shared("MoveSchema")
local AnimationHandler = Paths.shared("AnimationHandler")
local Reactions = Paths.shared("Reactions")
local CutsceneTimeline = Paths.shared("CutsceneTimeline")

local State = Enums.State
local FIGHTER_TAG = "MidoriFighter"

type Remote = {
	model: Model,
	animator: Animator,
	fa: any,
	style: any,
	ids: { [string]: boolean },
	prevState: string?,
	move: any, -- the last attack it started (AttackStarted), for rush moves
	conns: { RBXScriptConnection },
}

local RemoteAnimator = {}

local player = Players.LocalPlayer
local remotes: { [Model]: Remote } = {}

-- A replicated copy of a combat track: stop it, the local handler plays the real one. Cutscene clips
-- are played locally too (Shared/CutsceneTimeline), so those stay.
local function suppress(r: Remote, track: AnimationTrack)
	local anim = track.Animation
	if anim and r.ids[anim.AnimationId] and not r.fa:owns(track) and not CutsceneTimeline.owns(track) then
		track:Stop(0)
	end
end

local function remove(model: Model)
	local r = remotes[model]
	if not r then
		return
	end
	remotes[model] = nil
	for _, c in r.conns do
		c:Disconnect()
	end
	r.fa:destroy()
end

local function add(inst: Instance)
	if not inst:IsA("Model") or remotes[inst] then
		return
	end
	local model = inst :: Model
	if model == player.Character then
		return -- our own character is animated by CombatController
	end
	local humanoid = model:WaitForChild("Humanoid", 10) :: Humanoid?
	local animator = humanoid and humanoid:WaitForChild("Animator", 10) :: Animator?
	if not animator or not model.Parent or remotes[model] or model == player.Character then
		return
	end

	local style = MoveSchema.ofModel(model)

	local r: Remote = {
		model = model,
		animator = animator,
		fa = AnimationHandler.new(animator, style),
		style = style,
		ids = AnimationHandler.combatIds(style),
		prevState = model:GetAttribute("MState") :: string?,
		move = nil,
		conns = {},
	}
	remotes[model] = r

	-- Style swaps (",e <Style>") happen while the fighter is Idle, so just rebuild.
	table.insert(r.conns, model:GetAttributeChangedSignal("Style"):Connect(function()
		local new = MoveSchema.ofModel(model)
		if new ~= r.style then
			r.fa:destroy()
			r.style = new
			r.fa = AnimationHandler.new(r.animator, new)
			r.ids = AnimationHandler.combatIds(new)
		end
	end))

	-- Every fresh block press sets BlockPressAt (also when Idle -> BlockStart happen in one
	-- server step and the client never sees the Idle).
	table.insert(r.conns, model:GetAttributeChangedSignal("BlockPressAt"):Connect(function()
		r.fa:setBlock(true)
	end))
	-- Leaving guard for anything but a stun releases the block (stuns are handled by the
	-- HitResult reaction, which already replaces the block).
	table.insert(r.conns, model:GetAttributeChangedSignal("MState"):Connect(function()
		local s = model:GetAttribute("MState") :: string?
		local prev = r.prevState
		r.prevState = s
		if prev and Enums.GUARDING[prev] and not (s and (Enums.GUARDING[s] or Enums.STUNS[s])) then
			r.fa:setBlock(false)
		end
		-- Rush moves (Feng Critical, Firecracker M2): loop while charging, miss clip on a whiff,
		-- and a connected rush (Rush -> Endlag) just ends the loop.
		local rushMove = r.move
		if rushMove and rushMove.rush then
			if s == State.Rush then
				r.fa:playRushLoop(rushMove)
			elseif s == State.RushMiss then
				r.fa:playRushMiss(rushMove)
			elseif prev == State.Rush and s == State.Endlag then
				-- Connected: its contact clip (Prodigy Reentry swings on reaching them), like the owner's
				-- screen does (bug, 2026-10-25: viewers saw the windup cut off and no swing).
				if rushMove.rush.contactAnim then
					r.fa:playRushContact(rushMove)
				else
					r.fa:stopAttacks()
				end
			end
		end
		-- Barrage moves (Firecracker Critical): the punch chain runs while the state lasts.
		local crit = r.style.r and r.style.moves[r.style.r]
		if s == State.Barrage and crit and crit.barrage then
			r.fa:playBarrage(crit)
		end
	end))
	table.insert(r.conns, animator.AnimationPlayed:Connect(function(track)
		suppress(r, track)
	end))
	for _, track in animator:GetPlayingAnimationTracks() do
		suppress(r, track)
	end

	table.insert(r.conns, model.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			remove(model)
		end
	end))
end

function RemoteAnimator.init()
	Net.get("AttackStarted").OnClientEvent:Connect(function(model: Model, moveId: string, speed: number)
		local r = remotes[model]
		local move = r and r.style.moves[moveId]
		if r and move and typeof(speed) == "number" then
			r.move = move -- rush moves are followed through MState (above)
			local swing = move.charge and move.charge.swing
			-- Swing charge (Slugger M2): hold the windup and swing at the server's release (releaseCharge
			-- moves MStateEnds), not at the tap time (bug, 2026-10-25: viewers saw a tap swing, then a still
			-- body, then the real charged hit).
			r.fa:playAttack(move, speed, swing ~= nil)
			if swing then
				-- MState may replicate a beat after this event: only a state other than Startup seen AFTER
				-- Startup ends the watch (Endlag = it already swung, so swing now; anything else = cut off).
				task.spawn(function()
					local t0, seen = os.clock(), false
					while remotes[model] == r and r.move == move and os.clock() - t0 < 3 do
						local s = model:GetAttribute("MState")
						if s == State.Startup then
							seen = true
							local ends = model:GetAttribute("MStateEnds")
							if typeof(ends) == "number" and ends > 0 and workspace:GetServerTimeNow() >= ends - swing.hit then
								r.fa:playSwing(move)
								return
							end
						elseif seen or os.clock() - t0 > 0.5 then
							if s == State.Endlag then
								r.fa:playSwing(move)
							end
							return
						end
						RunService.Heartbeat:Wait()
					end
				end)
			end
		end
	end)
	Net.get("DashStarted").OnClientEvent:Connect(function(model: Model, dir: Vector3)
		local r = remotes[model]
		local root = r and model:FindFirstChild("HumanoidRootPart") :: BasePart?
		if r and root and typeof(dir) == "Vector3" then
			r.fa:playDash(root.CFrame.LookVector, dir)
		elseif r then
			r.fa:stopAttacks()
		end
	end)
	Net.get("HitResult").OnClientEvent:Connect(function(attacker: Model, victim: Model, result: string, _pos: Vector3, info: any)
		for _, model in { attacker, victim } do
			local r = remotes[model]
			if r then
				Reactions.apply(r.fa, model, attacker, victim, result, info)
			end
		end
	end)

	CollectionService:GetInstanceAddedSignal(FIGHTER_TAG):Connect(function(model)
		task.spawn(add, model)
	end)
	CollectionService:GetInstanceRemovedSignal(FIGHTER_TAG):Connect(function(model)
		if model:IsA("Model") then
			remove(model)
		end
	end)
	for _, model in CollectionService:GetTagged(FIGHTER_TAG) do
		task.spawn(add, model)
	end

	-- Safety sweep: a replicated track can be restarted or resumed by a later update from
	-- the server without firing AnimationPlayed again.
	RunService.Heartbeat:Connect(function()
		for _, r in remotes do
			for _, track in r.animator:GetPlayingAnimationTracks() do
				suppress(r, track)
			end
		end
	end)
end

return RemoteAnimator
