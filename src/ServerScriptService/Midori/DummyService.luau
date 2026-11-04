--!strict
-- Studio-only test dummies. Each runs one scripted behaviour through the same CombatService
-- calls a player would make:
--   Idle   - stands still
--   Block  - holds block whenever it can
--   Parry  - presses block just before any nearby hit lands
--   SpamM1 - M1s whenever a player is in range
--   Clash  - answers a nearby player's attack with its own, timed so both hitboxes land together (dual exchange)
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local Enums = Paths.shared("Enums")
local CombatMath = Paths.shared("CombatMath")
local AnimationHandler = Paths.shared("AnimationHandler")
local Reactions = Paths.shared("Reactions")
local Registry = Paths.server("FighterRegistry")
local CombatService = Paths.server("CombatService")

local State = Enums.State

local MODES = { "Idle", "Block", "Parry", "SpamM1", "Clash" }
local CLASH_KINDS = { "R", "M2", "M1" } -- the slowest move that still fits the time left wins
local RESPAWN_DELAY = 3
local SPAM_RANGE = 7
local PARRY_REACT_RANGE = 10
-- Press this long before the hitbox time (drag hitboxes can land DRAG_LEAD early).
local PARRY_LEAD = 0.02 + (if Paths.data("Defaults").DRAG_HITBOX then Paths.data("Defaults").DRAG_LEAD else 0)
local PARRY_HOLD = 0.3

type Dummy = { mode: string, align: AlignOrientation, animator: any }

local dummies: { [Model]: Dummy } = {}

local DummyService = {}

local function nearestPlayerRoot(from: Vector3): BasePart?
	local best, bestDist = nil, math.huge
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 then
			local d = (root.Position - from).Magnitude
			if d < bestDist then
				best, bestDist = root, d
			end
		end
	end
	return best
end

local function label(model: Model, mode: string)
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "DummyLabel"
	gui.Size = UDim2.fromOffset(160, 20)
	gui.StudsOffset = Vector3.new(0, 2.2, 0)
	gui.AlwaysOnTop = true
	gui.Parent = head
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.GothamMedium
	text.TextSize = 13
	text.TextColor3 = Color3.fromRGB(230, 230, 230)
	text.TextStrokeTransparency = 0.6
	text.Parent = gui
	local function refresh()
		text.Text = `{mode} | {model:GetAttribute("MState") or "?"} | guard {model:GetAttribute("Guard") or "?"}`
	end
	model:GetAttributeChangedSignal("MState"):Connect(refresh)
	model:GetAttributeChangedSignal("Guard"):Connect(refresh)
	refresh()
end

-- `respawn`: the Studio row comes back where it stood; command dummies (",e dummy") just go away.
local function spawnDummy(mode: string, cf: CFrame, folder: Folder, style: any, respawn: boolean)
	local model = Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R6)
	model.Name = "Dummy"
	model:SetAttribute("DummyMode", mode)
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.AutoRotate = false
	humanoid.DisplayName = mode
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local animatorInst = humanoid:FindFirstChildOfClass("Animator") or Instance.new("Animator")
	animatorInst.Parent = humanoid

	local att = root:FindFirstChild("RootAttachment") :: Attachment
	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = att
	align.RigidityEnabled = true
	align.CFrame = cf.Rotation
	align.Parent = root

	model:PivotTo(cf)
	model.Parent = folder
	root:SetNetworkOwner(nil)
	label(model, mode)

	Registry.add(model, nil, style, workspace:GetServerTimeNow())
	dummies[model] = {
		mode = mode,
		align = align,
		animator = AnimationHandler.new(animatorInst :: Animator, style),
	}

	humanoid.Died:Connect(function()
		task.delay(RESPAWN_DELAY, function()
			dummies[model] = nil
			model:Destroy()
			if respawn then
				spawnDummy(mode, cf, folder, style, true)
			end
		end)
	end)
end

local function animatorFor(f: any): any?
	local d = dummies[f.model]
	return d and d.animator
end

function DummyService.init(style: any)
	local folder = Instance.new("Folder")
	folder.Name = "MidoriDummies"
	folder.Parent = workspace

	-- The row of one dummy per mode: Studio only.
	if RunService:IsStudio() then
		local spawnLoc = workspace:FindFirstChildOfClass("SpawnLocation")
		local base = if spawnLoc then spawnLoc.Position else Vector3.zero
		for i, mode in MODES do
			local pos = base + Vector3.new((i - (#MODES + 1) / 2) * 10, 3, -22)
			local face = Vector3.new(base.X, pos.Y, base.Z)
			spawnDummy(mode, CFrame.lookAt(pos, face), folder, style, true)
		end
	end

	-- Dev chat ",e dummy": an Idle dummy 6 studs in front of you, facing you (any server, devs only).
	local function watch(player: Player)
		player.Chatted:Connect(function(message: string)
			if not string.lower(message):match("^,e%s+dummy%s*$") or not Paths.server("RoleService").isDev(player) then
				return
			end
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not root then
				return
			end
			local look = CombatMath.flat(root.CFrame.LookVector)
			if look == Vector3.zero then
				look = Vector3.new(0, 0, -1)
			end
			local pos = root.Position + look * 6
			spawnDummy("Idle", CFrame.lookAt(pos, pos - look), folder, style, false)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
	end

	-- Visuals for server-owned fighters (player characters animate themselves).
	CombatService.attackStarted:Connect(function(f, move, speed)
		local fa = animatorFor(f)
		if fa then
			fa:playAttack(move, speed)
		end
	end)
	CombatService.dashStarted:Connect(function(f, dir)
		local fa = animatorFor(f)
		if fa then
			fa:playDash(f.root.CFrame.LookVector, dir)
		end
	end)
	CombatService.blockChanged:Connect(function(f, held)
		local fa = animatorFor(f)
		if fa then
			fa:setBlock(held)
		end
	end)
	CombatService.hitResult:Connect(function(a, v, result, _pos, info)
		for _, f in { a, v } do
			local fa = animatorFor(f)
			if fa then
				Reactions.apply(fa, f.model, a.model, v.model, result, info)
			end
		end
	end)

	-- Parry dummies time a fresh press against the server's own hitbox schedule.
	CombatService.attackStarted:Connect(function(attacker, move)
		-- A lit fuse isn't a swing, and a held charge has no hit time yet (hitboxAt = inf).
		if (move and move.fuse) or attacker.hitboxAt == math.huge then
			return
		end
		for model, d in dummies do
			if d.mode ~= "Parry" then
				continue
			end
			local f = Registry.get(model)
			if not f or f == attacker or (f.root.Position - attacker.root.Position).Magnitude > PARRY_REACT_RANGE then
				continue
			end
			local wait = math.max(0, attacker.hitboxAt - workspace:GetServerTimeNow() - PARRY_LEAD)
			task.delay(wait, function()
				local now = workspace:GetServerTimeNow()
				if CombatService.requestBlock(f, true, now, now, false) then
					task.delay(PARRY_HOLD, function()
						local later = workspace:GetServerTimeNow()
						CombatService.requestBlock(f, false, later, later, false)
					end)
				end
			end)
		end
	end)

	-- Clash dummies start their own attack so its hitbox is due when the player's is.
	CombatService.attackStarted:Connect(function(attacker, move)
		if not attacker.player or (move and move.fuse) or attacker.hitboxAt == math.huge then
			return
		end
		for model, d in dummies do
			if d.mode ~= "Clash" then
				continue
			end
			local f = Registry.get(model)
			if not f or (f.root.Position - attacker.root.Position).Magnitude > PARRY_REACT_RANGE then
				continue
			end
			local left = attacker.hitboxAt - workspace:GetServerTimeNow()
			local speed = CombatMath.speed(f.adrenaline)
			for _, kind in CLASH_KINDS do
				local id = if kind == "M1" then f.style.m1Chain[1] elseif kind == "M2" then f.style.m2 else f.style.r
				local own = id and f.style.moves[id]
				local startup = own and (if own.fixedStartup then own.startup else own.startup / speed)
				local cooldown = if kind == "M2" then f.m2CooldownUntil elseif kind == "R" then f.rCooldownUntil else 0
				if startup and startup <= left and cooldown <= attacker.hitboxAt - startup then
					-- ponytail: aims with the first chain hit's startup and today's adrenaline; good to ~a tick.
					task.delay(left - startup, function()
						local now = workspace:GetServerTimeNow()
						CombatService.requestAttack(f, kind, now, false)
					end)
					break
				end
			end
		end
	end)

	RunService.Heartbeat:Connect(function()
		local now = workspace:GetServerTimeNow()
		for model, d in dummies do
			local f = Registry.get(model)
			if not f then
				continue
			end
			local target = nearestPlayerRoot(f.root.Position)
			if target then
				local look = CombatMath.flat(target.Position - f.root.Position)
				if look ~= Vector3.zero then
					d.align.CFrame = CFrame.lookAlong(Vector3.zero, look)
				end
			end
			if d.mode == "Block" and f.state == State.Idle and not f.blockHeld then
				CombatService.requestBlock(f, true, now, now, false)
			elseif d.mode == "SpamM1" and target and (target.Position - f.root.Position).Magnitude <= SPAM_RANGE then
				CombatService.requestAttack(f, "M1", now, false)
			end
		end
	end)
end

return DummyService
