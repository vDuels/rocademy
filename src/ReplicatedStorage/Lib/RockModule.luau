local RockModule = {}
local TweenSerivce = game:GetService("TweenService")
local Players= game:GetService("Players")
local DebrisFolder


local function CheckDebrisFolder()
	if not workspace:FindFirstChild("Debris") then
		DebrisFolder = Instance.new("Folder")
		DebrisFolder.Name = "Debris"
		DebrisFolder.Parent = workspace
	else
		DebrisFolder = workspace:FindFirstChild("Debris")
	end
end


-- Ground raycasts skip the debris itself, player characters and anything tagged RockModuleIgnore.
local function GroundParams(): RaycastParams
	local ignore = {DebrisFolder}
	for _, v in Players:GetPlayers() do
		if v.Character then
			table.insert(ignore, v.Character)
		end
	end
	for _, v in game:GetService("CollectionService"):GetTagged("RockModuleIgnore") do
		table.insert(ignore, v)
	end
	local params = RaycastParams.new()
	params.FilterDescendantsInstances = ignore
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	return params
end

-- Lifetime (optional, Midori): seconds the rocks stay up before sinking (default 6.5-9.5, random).
function RockModule.Crater(Center : CFrame, Radius : number, MinRocks : number, MaxRocks : number, PlayerCollision : boolean, Lifetime : number?)
	Radius = Radius or 7
	MinRocks = MinRocks or 7
	MaxRocks = MaxRocks or 10
	if PlayerCollision == nil then
		PlayerCollision = true
	end
	
	
	CheckDebrisFolder()
	
	local raycastParams = GroundParams()
	local ray = workspace:Raycast(Center.Position, Center.UpVector * -1000, raycastParams)
	
	if ray then
	local numRocks = math.round(math.random(MinRocks, MaxRocks))
		local distance = Radius
		local newCframe = CFrame.new(ray.Position)
		local angle = 0
		
		for i = 1, numRocks do
			local Rock = Instance.new("Part")
			Rock.Parent = DebrisFolder
			Rock.Name = "GroundSlam"
			Rock.Size = Vector3.new(math.random(3,5), math.random(2, 3), math.random(2,4))
			Rock.CFrame = newCframe * CFrame.Angles(0, math.rad(angle), 0) * CFrame.new(0,0, -distance) + Vector3.new(0, -5, 0)
			Rock.CFrame = CFrame.lookAt(Rock.Position, ray.Position)
			local ray2 = workspace:Raycast(Rock.CFrame.Position + Vector3.new(0,7,0), Vector3.new(0,1,0) * -1000, raycastParams)
			if ray2 then
				Rock.Color = ray2.Instance.Color
				Rock.Material = ray2.Instance.Material
				Rock.Transparency = ray2.Instance.Transparency
				
			else
				Rock.Color = ray.Instance.Color
				Rock.Material = ray.Instance.Material
				Rock.Transparency = ray.Instance.Transparency
			end
			if PlayerCollision == false then
				Rock.CollisionGroup = "RockDebris"
			end
			
			Rock.Anchored = true
			
			Rock.CanCollide = PlayerCollision
			Rock.CanQuery = PlayerCollision -- (Midori) camera / hitboxes skip decorative rocks
			Rock.CanTouch = false
			game:GetService("Debris"):AddItem(Rock, 30)
			local Tween = TweenSerivce:Create(Rock, TweenInfo.new(0.2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Position = Rock.Position + Vector3.new(0, 4.5, 0)})
			Tween:Play()
			task.spawn(function()
				task.wait(Lifetime or math.random(650, 950) / 100)
				local Tween = TweenSerivce:Create(Rock, TweenInfo.new(4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {Position = Rock.Position + Vector3.new(0, -5, 0), Size = Vector3.new(1,1,1)})
				Tween:Play()
			end)
			angle += 360/numRocks
		end
	end
	
end

function RockModule.Explosion(Center : CFrame, TotalRocks : number, MinSize : number, MaxSize : number, PlayerCollision : boolean)
	TotalRocks = TotalRocks or 7
	MinSize = MinSize or 0.5
	MaxSize = MaxSize or 2.5
	PlayerCollision = PlayerCollision or false
	
	local numOfRocks = TotalRocks
	CheckDebrisFolder()
	
	local raycastParams = GroundParams()

	local ray = workspace:Raycast(Center.Position, Center.UpVector * -100, raycastParams)
	
	if ray then
		for i = 1, numOfRocks do
			local Rock = Instance.new("Part")
			Rock.Name = "ExplosionPart"
			Rock.Parent = DebrisFolder
			
			local RandomSize = (math.random(MinSize * 100, MaxSize * 100)) / 100.0
			if math.random(1, 5) == 3 then
				Rock.Size = Vector3.new(RandomSize * 2, 0.15, RandomSize * 2)
			else
				Rock.Size = Vector3.new(RandomSize, RandomSize, RandomSize)
			end
			
			Rock.CFrame = Center
			Rock.Color = ray.Instance.Color
			Rock.Material = ray.Instance.Material
			Rock.Anchored = false
			Rock.Orientation = Vector3.new(math.random(-359, 359),math.random(-359, 359),math.random(-359, 359))
			Rock.Transparency = ray.Instance.Transparency
			Rock.CanCollide = true -- needed to land on the ground
			Rock.CanQuery = false -- (Midori) the camera's occlusion raycasts skip it in flight (physics still lands it)
			Rock.CanTouch = false
			if PlayerCollision == false then
				Rock.CollisionGroup = "RockDebris"
			end
			
			
			game:GetService("Debris"):AddItem(Rock, 4.5)
			
			local velocitySpread = 32 
			local upwardForce = 22
			local velocity = Vector3.new(math.random(-velocitySpread, velocitySpread),upwardForce,math.random(-velocitySpread, velocitySpread))
			local bodyVelocity = Instance.new("BodyVelocity")
		
			bodyVelocity.Velocity = velocity
			bodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
			bodyVelocity.P = 5000
			bodyVelocity.Parent = Rock
			
			game:GetService("Debris"):AddItem(bodyVelocity, 0.25)
			task.spawn(function()
				task.wait(4)
				local Tween = TweenSerivce:Create(Rock, TweenInfo.new(0.75, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut), {Size = Vector3.new(0.1,0.1,0.1), Transparency = 1}):Play()	
			end)
		end
	end
end

-- (Midori) Pops `Rock` out of the ground at `ray` to `base * up(outY)` and sinks it after Lifetime.
-- Takes the ground's colour + material. Decorative: anchored, no collision, no queries (camera,
-- hitboxes), no touches.
local function Jut(Rock : BasePart, ray : RaycastResult, base : CFrame, outY : number, Lifetime : number)
	Rock.Material = ray.Material
	Rock.Color = if ray.Instance:IsA("Terrain") then (ray.Instance :: Terrain):GetMaterialColor(ray.Material) else ray.Instance.Color
	Rock.Anchored, Rock.CanCollide, Rock.CanQuery, Rock.CanTouch = true, false, false, false
	local hidden = base * CFrame.new(0, -Rock.Size.Y, 0)
	Rock.CFrame = hidden
	Rock.Parent = DebrisFolder
	TweenSerivce:Create(Rock, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {CFrame = base * CFrame.new(0, outY, 0)}):Play()
	task.delay(Lifetime, function()
		if Rock.Parent then
			TweenSerivce:Create(Rock, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.In), {CFrame = hidden}):Play()
		end
	end)
	game:GetService("Debris"):AddItem(Rock, Lifetime + 1.1)
end

-- Rubble (Midori): Count chunky rocks jutting out of the ground at random spots inside Radius, tilted.
function RockModule.Rubble(Center : CFrame, Radius : number, Count : number, Lifetime : number)
	CheckDebrisFolder()
	local raycastParams = GroundParams()
	for i = 1, Count do
		local r = Radius * math.sqrt(math.random()) -- even spread over the disc
		local a = math.random() * math.pi * 2
		local ray = workspace:Raycast(Center.Position + Vector3.new(math.cos(a) * r, 7, math.sin(a) * r), Vector3.new(0, -1000, 0), raycastParams)
		if ray then
			local s = math.random(100, 220) / 100
			local Rock = Instance.new("Part")
			Rock.Name = "Rubble"
			Rock.Size = Vector3.new(s, s * math.random(80, 140) / 100, s * math.random(80, 120) / 100)
			local base = CFrame.new(ray.Position) * CFrame.Angles(math.rad(math.random(-40, 40)), math.rad(math.random(0, 359)), math.rad(math.random(-40, 40)))
			Jut(Rock, ray, base, Rock.Size.Y * 0.2, Lifetime) -- about 70% above ground
		end
	end
end

-- Spikes (Midori): Count sharp rocks (corner wedges) jutting out along the circle of Radius, leaning
-- outward, so the edge of an area reads at a glance.
function RockModule.Spikes(Center : CFrame, Radius : number, Count : number, Lifetime : number)
	CheckDebrisFolder()
	local raycastParams = GroundParams()
	for i = 1, Count do
		local a = (i + math.random() * 0.6 - 0.3) / Count * math.pi * 2
		local r = Radius + math.random(-60, 60) / 100
		local out = Vector3.new(math.cos(a), 0, math.sin(a))
		local ray = workspace:Raycast(Center.Position + out * r + Vector3.new(0, 7, 0), Vector3.new(0, -1000, 0), raycastParams)
		if ray then
			local w = math.random(90, 150) / 100
			local h = math.random(250, 450) / 100
			local Rock = Instance.new("CornerWedgePart")
			Rock.Name = "Spike"
			Rock.Size = Vector3.new(w, h, w)
			-- Facing out (-Z = outward), random spin, then leaning 15-35 degrees away from the centre.
			local base = CFrame.lookAt(ray.Position, ray.Position + out)
				* CFrame.Angles(-math.rad(math.random(15, 35)), 0, 0)
				* CFrame.Angles(0, math.rad(math.random(0, 359)), 0)
			Jut(Rock, ray, base, h * 0.35, Lifetime) -- base buried, ~85% above ground
		end
	end
end

function RockModule.CraterRows(Center : CFrame, Radius : number, Rows: number, NextRowRadius : number, MinRocks : number, MaxRocks : number, PlayerCollision : boolean)
	if PlayerCollision == nil then
		PlayerCollision = true
	end
	Radius = Radius or 7
	MinRocks = MinRocks or 7
	MaxRocks = MaxRocks or 10
	Rows = Rows or 3
	NextRowRadius = NextRowRadius or 4
	local currentRadius = Radius
	for i = 1, Rows do
		RockModule.Crater(Center, currentRadius, MinRocks * i, MaxRocks * i, PlayerCollision)
		currentRadius += NextRowRadius
	end
end

function RockModule.ClearDebris(Fade : boolean)
	CheckDebrisFolder()
	
	if Fade then
		for i, v in pairs(DebrisFolder:GetChildren()) do
			if v:IsA("BasePart") then
				local Tween = TweenSerivce:Create(v, TweenInfo.new(0.75, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut), {Size = Vector3.new(0.1,0.1,0.1), Transparency = 1}):Play()	
				game:GetService("Debris"):AddItem(v, 1)
				
			end
		end
	else
		for i, v in pairs(DebrisFolder:GetChildren()) do
			v:Destroy()
		end
	end
end



return RockModule
-- Written by @LxckyDev