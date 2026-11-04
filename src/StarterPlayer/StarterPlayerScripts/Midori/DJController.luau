--!strict
-- DJ Booth (user, 2026-11-01). While the apartment we're in has a placed `dj` furniture, its music plays for
-- everyone inside and the area OST steps aside (MusicController.hold). The library is EVERY Sound under
-- Assets.Music (all the OST folders), by path "<folder>/<Sound name>". The owner hovers the booth + E
-- (InteractController "dj") and picks one song (it loops) or SHUFFLE ALL (the whole library in path order);
-- the server keeps the pick { song, at } (ApartmentService.setDJ, saved) and everyone inside plays it from
-- server time `at`, so they hear the same moment. How it sounds depends on the room we're in
-- (ApartmentController.state.room, a Zone+ zone): Shared/RoomSound counts the rooms between us and the booth
-- (a `speaker` furniture's room counts as close as D.DJ.extenderHops) and each hop is quieter and more muffled.
local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Net = Paths.shared("Net")
local RoomSound = Paths.shared("RoomSound")
local Apartment = require(script.Parent:WaitForChild("ApartmentController"))
local Music = require(script.Parent:WaitForChild("MusicController"))

local player = Players.LocalPlayer
local state = Apartment.state

local DJController = {}

type Track = { sound: Sound, eq: EqualizerSoundEffect, volume: number, length: number, title: string }

local tracks: { Track } = {} -- loaded, in play order
local folder: Folder? = nil -- our copies of the songs (SoundService)
local playing: Track? = nil
local on = false
local gen = 0
local hops: { [string]: number } = {}

local function getDef(id: string): any?
	return Paths.furniture(id)
end

-- Every song: { path, sound } sorted by path. The same SoundId in two folders counts once.
local function library(): { { path: string, sound: Sound } }
	local music = Paths.Assets:WaitForChild("Music")
	local out, seen = {}, {}
	for _, s in music:GetDescendants() do
		if s:IsA("Sound") and not seen[s.SoundId] then
			seen[s.SoundId] = true
			local parts, at = {}, s :: Instance
			while at ~= music do
				table.insert(parts, 1, at.Name)
				at = at.Parent :: Instance
			end
			table.insert(out, { path = table.concat(parts, "/"), sound = s })
		end
	end
	table.sort(out, function(a, b)
		return a.path < b.path
	end)
	return out
end

-- The room an item stands in: its own, its table's, or its wall's.
local function roomOf(uid: string): string?
	local it = state.items[uid]
	if not it then
		return nil
	end
	if it.parent then
		return roomOf(it.parent)
	end
	return it.room or (it.wall and string.match(it.wall, "^(.-)/"))
end

-- Booth rooms start at 0 hops, speaker rooms at D.DJ.extenderHops; none = no booth.
local function sources(): { [string]: number }?
	local booth, out = false, {}
	for uid, it in state.items do
		local def = getDef(it.item)
		local room = roomOf(uid)
		if def and room then
			if def.dj then
				booth = true
				out[room] = 0
			elseif def.speaker then
				out[room] = math.min(out[room] or math.huge, D.DJ.extenderHops)
			end
		end
	end
	return if booth then out else nil
end

-- Level for the room we're in (tweened when it changes).
local function applyMix(instant: boolean?)
	local h = if state.room then hops[state.room] or math.huge else 0 -- not in a room yet (just arrived): full
	local vol, high, mid = RoomSound.mix(h, D.DJ)
	local info = TweenInfo.new(if instant then 0 else D.DJ.fade)
	for _, t in tracks do
		TweenService:Create(t.sound, info, { Volume = t.volume * vol }):Play()
		TweenService:Create(t.eq, info, { HighGain = high, MidGain = mid }):Play()
	end
end

-- Play whatever the server clock says is on now (counted from the pick's `at`), then the next one.
local function playNow()
	gen += 1
	local my = gen
	local total = 0
	for _, t in tracks do
		total += t.length
	end
	if total <= 0 then
		return
	end
	local at = (workspace:GetServerTimeNow() - (if state.dj then state.dj.at else 0)) % total
	local pick, offset = tracks[1], 0
	for _, t in tracks do
		if at < t.length then
			pick, offset = t, at
			break
		end
		at -= t.length
	end
	if playing and playing ~= pick then
		playing.sound:Stop()
	end
	if playing ~= pick or not pick.sound.IsPlaying then
		pick.sound.TimePosition = offset
		pick.sound:Play()
		Music.announce(pick.title)
	end
	playing = pick
	task.delay(pick.length - offset + 0.05, function()
		if gen == my and on then
			playNow()
		end
	end)
end

-- Drops our song copies (the OST hold stays as it is).
local function teardown()
	gen += 1
	if folder then
		folder:Destroy()
	end
	folder, tracks, playing = nil, {}, nil
end

local function stop()
	if not on then
		return
	end
	on = false
	teardown()
	Music.hold(false)
end

-- Loads the songs the pick asks for (one, or the whole library) and starts.
local function start()
	teardown()
	on = true
	local my = gen
	Music.hold(true)
	local f = Instance.new("Folder")
	f.Name = "MidoriDJ"
	f.Parent = SoundService -- client-made: only we hear it
	folder = f
	local want = state.dj and state.dj.song or ""
	local copies = {}
	for _, song in library() do
		if want == "" or song.path == want then
			local c = song.sound:Clone()
			c.Looped = false
			c.Volume = 0
			c.SoundGroup = Music.group() -- the Settings page's MUSIC VOLUME applies to the booth too
			local eq = Instance.new("EqualizerSoundEffect")
			eq.LowGain, eq.MidGain, eq.HighGain = 0, 0, 0
			eq.Parent = c
			c.Parent = f
			table.insert(copies, { sound = c, eq = eq, volume = song.sound.Volume, length = 0, title = song.sound.Name })
		end
	end
	task.spawn(function()
		local list = {}
		for _, t in copies do
			table.insert(list, t.sound)
		end
		pcall(ContentProvider.PreloadAsync, ContentProvider, list)
		if gen ~= my or not on then
			return
		end
		local ready = {}
		for _, t in copies do
			if t.sound.IsLoaded and t.sound.TimeLength > 0 then
				t.length = t.sound.TimeLength
				table.insert(ready, t)
			end
		end
		tracks = ready
		applyMix(true)
		playNow()
	end)
end

-- The owner turned the booth OFF (picker): no booth music, the area OST plays as if there were no booth.
local function isOff(): boolean
	return state.dj ~= nil and state.dj.song == "off"
end

local function refresh()
	local src = if state.folder then sources() else nil
	if not src or isOff() then
		stop()
		return
	end
	hops = RoomSound.hops(state.rooms, src, D.DJ.wallGap)
	if not on then
		start()
	else
		applyMix()
	end
end

-- Song picker (owner, hover + E on the booth). Hi-Fi Rush / Persona stickers like the build UI, SCALE ONLY.
local Ui = require(script.Parent:WaitForChild("StickerUi"))
local RED, BLACK, WHITE, CARD, WELL, DIM, YELLOW = Ui.RED, Ui.BLACK, Ui.WHITE, Ui.CARD, Ui.WELL, Ui.DIM, Ui.YELLOW
local new, sticker, label = Ui.new, Ui.sticker, Ui.label

local picker: { gui: ScreenGui, list: ScrollingFrame, close: TextButton }? = nil

local function closePicker()
	if picker then
		picker.gui.Enabled = false
		picker.close.Modal = false
	end
end

local function buildPicker()
	local gui = new("ScreenGui", { Name = "MidoriDJ", ResetOnSpawn = false, Enabled = false, DisplayOrder = 4, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling }, player:WaitForChild("PlayerGui"))
	local panel, fill = sticker(gui, WELL, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.36, 0.7), Rotation = -1 }, Vector2.new(0.02, 0.012), Vector2.new(0.025, 0.018))
	new("UIAspectRatioConstraint", { AspectRatio = 0.75 }, panel)
	local _, headFill = sticker(panel, RED, { Position = UDim2.fromScale(-0.04, -0.045), Size = UDim2.fromScale(0.7, 0.1), Rotation = -3, ZIndex = 5 }, Vector2.new(0.02, 0.08))
	label(headFill, "PICK THE MUSIC", WHITE, { Size = UDim2.fromScale(0.9, 0.8), Position = UDim2.fromScale(0.05, 0.1), TextXAlignment = Enum.TextXAlignment.Left })
	local closeOuter, closeFill = sticker(panel, YELLOW, { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.97, 0.02), Size = UDim2.fromScale(0.12, 0.09), Rotation = 6, ZIndex = 6 }, Vector2.new(0.08, 0.08))
	label(closeFill, "X", BLACK, { Size = UDim2.fromScale(0.8, 0.8), Position = UDim2.fromScale(0.1, 0.1) })
	local close = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10, Modal = false }, closeOuter)
	close.Activated:Connect(closePicker)
	local list = new("ScrollingFrame", {
		Position = UDim2.fromScale(0.05, 0.09), Size = UDim2.fromScale(0.9, 0.87), CanvasSize = UDim2.new(), ZIndex = 3,
		AutomaticCanvasSize = Enum.AutomaticSize.Y, ScrollBarThickness = 0, ScrollingDirection = Enum.ScrollingDirection.Y,
	}, fill)
	-- Rows: width-dominant aspect so they keep their shape however long the list gets.
	local layout = new("UIGridLayout", { CellSize = UDim2.fromScale(1, 1), CellPadding = UDim2.fromScale(0, 0.012), SortOrder = Enum.SortOrder.LayoutOrder }, list)
	new("UIAspectRatioConstraint", { AspectRatio = 6.5, DominantAxis = Enum.DominantAxis.Width }, layout)
	picker = { gui = gui, list = list, close = close }
end

local function fillPicker()
	local p = picker :: any
	for _, c in p.list:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	local current = if state.dj then state.dj.song else ""
	local rows = { { path = "off", title = "OFF", tag = "NO BOOTH MUSIC" }, { path = "", title = "SHUFFLE ALL", tag = "EVERY OST" } }
	for _, song in library() do
		table.insert(rows, { path = song.path, title = string.upper(song.sound.Name), tag = string.upper(string.match(song.path, "^(.*)/") or "") })
	end
	for i, r in rows do
		local on = r.path == current
		local outer, rowFill = sticker(p.list, if on then RED else CARD, { LayoutOrder = i }, Vector2.new(0.008, 0.06))
		label(rowFill, r.title, WHITE, { Position = UDim2.fromScale(0.04, 0.12), Size = UDim2.fromScale(0.66, 0.5), TextXAlignment = Enum.TextXAlignment.Left })
		label(rowFill, r.tag, if on then YELLOW else DIM, { Position = UDim2.fromScale(0.04, 0.62), Size = UDim2.fromScale(0.66, 0.28), TextXAlignment = Enum.TextXAlignment.Left })
		if on then
			label(rowFill, "NOW", YELLOW, { Position = UDim2.fromScale(0.78, 0.2), Size = UDim2.fromScale(0.18, 0.6) })
		end
		local scale = new("UIScale", {}, outer)
		local b = new("TextButton", { Text = "", Size = UDim2.fromScale(1, 1), ZIndex = 10 }, outer)
		b.MouseEnter:Connect(function()
			TweenService:Create(scale, TweenInfo.new(0.12, Enum.EasingStyle.Back), { Scale = 1.03 }):Play()
		end)
		b.MouseLeave:Connect(function()
			TweenService:Create(scale, TweenInfo.new(0.12), { Scale = 1 }):Play()
		end)
		b.Activated:Connect(function()
			Net.get(Net.Names.Apartment):FireServer("DJ", r.path)
			closePicker()
		end)
	end
end

-- InteractController calls this on E at your own booth.
function DJController.openPicker()
	if state.owner ~= player.UserId then
		return
	end
	if not picker then
		buildPicker()
	end
	fillPicker()
	local p = picker :: any
	p.gui.Enabled = true
	p.close.Modal = true -- frees the mouse while it's up
end

function DJController.init()
	Apartment.changed:Connect(function(uid: string?)
		if uid == nil then
			closePicker() -- in / out / style swap
		end
		refresh() -- in / out, or an item placed / moved / stored
	end)
	Apartment.roomChanged:Connect(function()
		applyMix()
	end)
	Apartment.djChanged:Connect(function()
		if isOff() then
			stop() -- the OST comes back (MusicController.hold off)
		elseif on then
			start() -- the new pick, from its `at`
		else
			refresh() -- back ON from OFF
		end
	end)
end

return DJController
