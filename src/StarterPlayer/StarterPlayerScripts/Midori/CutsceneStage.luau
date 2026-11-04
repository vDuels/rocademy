--!strict
-- The cutscene "stage" (user, 2026-10-23: the fighters as the stars of a boxing match). Local to the
-- screens running the cutscene camera (CutsceneController), nothing replicates:
--   * a box of black Neon walls + ceiling round the pair (Neon black is pure black under any lighting),
--     and Lighting's sun / ambient / environment turned to black, so the world is gone;
--   * a dark floor just above the real ground with a glowing pool of light under them (stacked soft
--     circles, or `floorImage` if given) and real spotlights from above lighting the fighters;
--   * everything else inside the box hidden locally (parts, decals, other players; glows off).
-- fadeOut(time) brings the world back (the camera easing home = the scene fading out); destroy()
-- removes it all and puts Lighting back exactly.
-- Every part: CanQuery off (the camera's occlusion and every raycast ignore it), no collision.
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local NO_CHARACTERS = Paths.shared("Ragdoll").GROUP.ragdoll -- the floor sits right under their feet

local CutsceneStage = {}

export type Spec = {
	center: Vector3, -- anchor space (the victim's spot)
	radius: number, -- half-width of the black box
	height: number,
	floorImage: string?,
	light: { color: Color3, brightness: number },
	uplights: boolean?, -- floor searchlights aimed up the middle (Prodigy, user 2026-10-24)
}

-- Lighting properties that would light (or haze) the void, and what they become.
local DARK: { [string]: any } = {
	Brightness = 0,
	Ambient = Color3.new(0, 0, 0),
	OutdoorAmbient = Color3.new(0, 0, 0),
	EnvironmentDiffuseScale = 0,
	EnvironmentSpecularScale = 0,
}

local function part(props: { [string]: any }, parent: Instance): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.CollisionGroup = NO_CHARACTERS
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = parent
	return p
end

-- The light pool: concentric soft circles, each adding a little light toward the middle.
local function pool(floor: Part, spec: Spec): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.LightInfluence = 0
	gui.Brightness = 1 -- user: dimmer (was 2)
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	gui.Adornee = floor
	gui.Parent = floor
	local share = 9 / (spec.radius * 2) -- the pool is 18 studs across
	if spec.floorImage then
		local img = Instance.new("ImageLabel")
		img.BackgroundTransparency = 1
		img.Image = spec.floorImage
		img.AnchorPoint = Vector2.new(0.5, 0.5)
		img.Position = UDim2.fromScale(0.5, 0.5)
		img.Size = UDim2.fromScale(share * 2, share * 2)
		img.Parent = gui
		return gui
	end
	local RINGS = 14
	for i = 1, RINGS do
		local k = i / RINGS -- 1/14 (smallest, brightest stack) .. 1 (outer edge)
		local c = Instance.new("Frame")
		c.AnchorPoint = Vector2.new(0.5, 0.5)
		c.Position = UDim2.fromScale(0.5, 0.5)
		c.Size = UDim2.fromScale(share * 2 * k, share * 2 * k)
		c.BackgroundColor3 = spec.light.color
		c.BackgroundTransparency = 0.93 -- user: dimmer (was 0.88)
		c.BorderSizePixel = 0
		c.ZIndex = RINGS - i + 1
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = c
		c.Parent = gui
	end
	return gui
end

-- Things that shine or draw on their own: switched off while hidden (a hidden torch still lights the void).
local GLOWS = { "Light", "ParticleEmitter", "Beam", "Trail", "Fire", "Smoke", "Sparkles", "LayerCollector" }

-- Hides (locally, render only: LocalTransparencyModifier never replicates or touches physics) every
-- world part, decal and texture inside the box, and switches its glows off. Skips `keep` (the
-- fighters) and anything under the camera (the stage itself). Returns what it changed, to undo.
type Hidden = { fades: { [Instance]: number }, toggles: { [Instance]: boolean } }
local function hideRealm(base: CFrame, r: number, h: number, keep: { Instance }): Hidden
	local hidden: Hidden = { fades = {}, toggles = {} }
	local camera = workspace.CurrentCamera
	local function kept(inst: Instance): boolean
		if inst:IsDescendantOf(camera) then
			return true
		end
		for _, k in keep do
			if inst:IsDescendantOf(k) then
				return true
			end
		end
		return false
	end
	local function inside(p: BasePart): boolean
		local lp = base:PointToObjectSpace(p.Position)
		local reach = p.Size.Magnitude / 2 -- any part that could poke into the box
		return math.abs(lp.X) - reach < r and math.abs(lp.Z) - reach < r and lp.Y + reach > -2 and lp.Y - reach < h
	end
	-- ponytail: one pass over every workspace descendant per cutscene (~ms on a big map); a spatial
	-- query would miss CanQuery-off decor.
	for _, inst in workspace:GetDescendants() do
		if inst:IsA("BasePart") then
			if inst.LocalTransparencyModifier < 1 and inside(inst) and not kept(inst) then
				hidden.fades[inst] = inst.LocalTransparencyModifier
				inst.LocalTransparencyModifier = 1
			end
		elseif inst:IsA("Decal") then -- (Texture is a Decal)
			local p = inst.Parent
			if p and p:IsA("BasePart") and hidden.fades[p] ~= nil then
				hidden.fades[inst] = inst.LocalTransparencyModifier
				inst.LocalTransparencyModifier = 1
			end
		else
			for _, class in GLOWS do
				if inst:IsA(class) then
					local p = inst:FindFirstAncestorWhichIsA("BasePart")
					if p and (inst :: any).Enabled and inside(p) and not kept(inst) then
						hidden.toggles[inst] = true;
						(inst :: any).Enabled = false
					end
					break
				end
			end
		end
	end
	-- Decals can come before their part in GetDescendants order: catch the ones the pass skipped.
	for inst in hidden.fades do
		if inst:IsA("BasePart") then
			for _, d in inst:GetChildren() do
				if d:IsA("Decal") and hidden.fades[d] == nil then
					hidden.fades[d] = d.LocalTransparencyModifier
					d.LocalTransparencyModifier = 1
				end
			end
		end
	end
	return hidden
end

local function restore(hidden: Hidden, share: number)
	-- share 0 = still hidden .. 1 = back to how it was
	for inst, was in hidden.fades do
		(inst :: any).LocalTransparencyModifier = 1 - (1 - was) * share
	end
end

-- Builds it round `origin` (the anchor CFrame); `exclude` = the fighters (the ground probe skips them).
function CutsceneStage.build(origin: CFrame, spec: Spec, exclude: { Instance })
	local center = origin:PointToWorldSpace(spec.center)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	local hit = workspace:Raycast(center + Vector3.yAxis * 2, Vector3.yAxis * -12, params)
	local groundY = if hit then hit.Position.Y else center.Y - 3
	local base = CFrame.new(center.X, groundY, center.Z) * origin.Rotation

	local folder = Instance.new("Folder")
	folder.Name = "MidoriCutsceneStage"
	local r, h = spec.radius, spec.height
	local black = { Material = Enum.Material.Neon, Color = Color3.new(0, 0, 0) }
	local walls: { Part } = {}
	for _, w in {
		{ CFrame.new(0, h / 2, -r), Vector3.new(r * 2, h, 1) },
		{ CFrame.new(0, h / 2, r), Vector3.new(r * 2, h, 1) },
		{ CFrame.new(-r, h / 2, 0), Vector3.new(1, h, r * 2) },
		{ CFrame.new(r, h / 2, 0), Vector3.new(1, h, r * 2) },
		{ CFrame.new(0, h, 0), Vector3.new(r * 2, 1, r * 2) },
	} do
		local p = part(black, folder)
		p.CFrame = base * w[1]
		p.Size = w[2]
		table.insert(walls, p)
	end
	-- Floor: just above the ground so it covers it (top 0.04 up), dark but able to take the spotlights.
	local floor = part({ Material = Enum.Material.SmoothPlastic, Color = Color3.fromRGB(14, 14, 16), Reflectance = 0.08, Size = Vector3.new(r * 2, 0.1, r * 2) }, folder)
	floor.CFrame = base * CFrame.new(0, -0.01, 0)
	local glow = pool(floor, spec)
	-- Lights: one overhead pool, two angled key lights for faces.
	local lights: { SpotLight } = {}
	for _, l in {
		{ Vector3.new(0, 20, 0), 55, 32 },
		{ Vector3.new(9, 14, 9), 40, 30 },
		{ Vector3.new(-9, 14, -9), 40, 30 },
	} do
		local holder = part({ Transparency = 1, Size = Vector3.one * 0.2 }, folder)
		holder.CFrame = CFrame.lookAt(base:PointToWorldSpace(l[1]), base:PointToWorldSpace(Vector3.new(0, 1.5, 0)))
		local s = Instance.new("SpotLight")
		s.Face = Enum.NormalId.Front
		s.Angle = l[2]
		s.Range = l[3]
		s.Color = spec.light.color
		s.Brightness = spec.light.brightness
		s.Shadows = true
		s.Parent = holder
		table.insert(lights, s)
	end
	if spec.uplights then
		-- Searchlights in the floor either side, aimed up the middle: whoever's in the air stays lit.
		for _, x in { -6, 6 } do
			local holder = part({ Transparency = 1, Size = Vector3.one * 0.2 }, folder)
			holder.CFrame = CFrame.lookAt(base:PointToWorldSpace(Vector3.new(x, 0.2, 0)), base:PointToWorldSpace(Vector3.new(0, h * 0.5, 0)))
			local s = Instance.new("SpotLight")
			s.Face = Enum.NormalId.Front
			s.Angle = 35
			s.Range = 60
			s.Color = spec.light.color
			s.Brightness = spec.light.brightness
			s.Parent = holder
			table.insert(lights, s)
		end
	end
	folder.Parent = workspace.CurrentCamera
	local hidden = hideRealm(base, r, h, exclude) -- the world inside the box, gone (locally)

	-- Lighting to black (saved to put back exactly).
	local saved: { [Instance]: { [string]: any } } = { [Lighting] = {} }
	for k, v in DARK do
		saved[Lighting][k] = (Lighting :: any)[k];
		(Lighting :: any)[k] = v
	end
	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if atmosphere then
		saved[atmosphere] = { Density = atmosphere.Density, Haze = atmosphere.Haze, Glare = atmosphere.Glare }
		atmosphere.Density, atmosphere.Haze, atmosphere.Glare = 0, 0, 0
	end
	local rays = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if rays then
		saved[rays] = { Enabled = rays.Enabled }
		rays.Enabled = false
	end

	local done = false
	local toggledBack = false
	local function glowsBack()
		if not toggledBack then
			toggledBack = true
			for inst in hidden.toggles do
				(inst :: any).Enabled = true
			end
		end
	end
	local stage = {}
	-- The world comes back over `time`: walls, floor, pool and lights fade, Lighting eases home, the
	-- hidden world fades back in (its glows switch back on halfway).
	function stage.fadeOut(time: number)
		local started = os.clock()
		local conn: RBXScriptConnection
		conn = RunService.RenderStepped:Connect(function()
			local u = math.clamp((os.clock() - started) / time, 0, 1)
			if done then
				conn:Disconnect()
				return
			end
			restore(hidden, 0.5 - 0.5 * math.cos(math.pi * u)) -- sine in-out, like the rest
			if u >= 0.5 then
				glowsBack()
			end
			if u >= 1 then
				conn:Disconnect()
			end
		end)
		local info = TweenInfo.new(time, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		for _, p in walls do
			TweenService:Create(p, info, { Transparency = 1 }):Play()
		end
		TweenService:Create(floor, info, { Transparency = 1 }):Play()
		for _, c in glow:GetChildren() do
			if c:IsA("GuiObject") then
				TweenService:Create(c, info, if c:IsA("ImageLabel") then { ImageTransparency = 1 } else { BackgroundTransparency = 1 }):Play()
			end
		end
		for _, s in lights do
			TweenService:Create(s, info, { Brightness = 0 }):Play()
		end
		for inst, props in saved do
			local tweenable = {}
			for k, v in props do
				if typeof(v) == "boolean" then
					(inst :: any)[k] = v
				else
					tweenable[k] = v
				end
			end
			TweenService:Create(inst, info, tweenable):Play()
		end
	end
	function stage.destroy()
		if done then
			return
		end
		done = true
		folder:Destroy()
		restore(hidden, 1)
		glowsBack()
		for inst, props in saved do
			for k, v in props do
				(inst :: any)[k] = v
			end
		end
	end
	return stage
end

return CutsceneStage