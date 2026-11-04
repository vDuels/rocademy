--!strict
-- OST pools (user, 2026-10-27). Songs are Sounds in ReplicatedStorage.Assets.Music/<pool>/; the Sound's Name is
-- the title shown, its Volume is the song's level. LocationController calls setPool(<area name>) when you
-- enter an area and setPool(nil) when you leave the last one; a pool with no folder (or an empty one) plays
-- "Default". A random song each time (never the same one twice in a row unless it's the only one), the
-- next when it ends; changing pool crossfades. Each new song pops a NOW PLAYING card on the middle right.
-- hold(true) (DJController: a DJ booth is playing) fades the OST out and keeps it out; hold(false) brings the
-- pool you're in back. announce(title) pops the same NOW PLAYING card for someone else's song.
-- Volume: the MidoriMusic SoundGroup (DJ booths play through it too) = D.MUSIC.volume x the Settings page's
-- MUSIC VOLUME % (Player attribute SetMusic; setVolume = live while the slider drags).
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local D = Paths.data("Defaults")
local Sticker = require(script.Parent:WaitForChild("Sticker"))

local DEFAULT = "Default"

local MusicController = {}

local folder: Instance
local group: SoundGroup
local emotes: SoundGroup -- emote sounds: the MUSIC VOLUME slider alone (no D.MUSIC.volume)
local card: any
local pool: Instance? = nil -- the pool folder playing now
local current: Sound? = nil
local last: { [Instance]: Sound } = {} -- last song per pool
local gen = 0
local held = false
local wanted: string? = nil -- the area pool asked for (kept while held)

local function hasSongs(f: Instance?): boolean
	return f ~= nil and f:FindFirstChildWhichIsA("Sound") ~= nil
end

local function poolFolder(name: string?): Instance?
	local f = if name then folder:FindFirstChild(name) else nil
	if hasSongs(f) then
		return f
	end
	local d = folder:FindFirstChild(DEFAULT)
	return if hasSongs(d) then d else nil
end

local function fadeOut(s: Sound)
	local t = TweenService:Create(s, TweenInfo.new(D.MUSIC.fade), { Volume = 0 })
	t.Completed:Once(function()
		s:Destroy()
	end)
	t:Play()
end

local function playFrom(f: Instance)
	gen += 1
	local my = gen
	local songs = {}
	for _, c in f:GetChildren() do
		if c:IsA("Sound") then
			table.insert(songs, c)
		end
	end
	local i = math.random(#songs)
	if #songs > 1 and songs[i] == last[f] then
		i = i % #songs + 1
	end
	local pick = songs[i]
	last[f] = pick
	if current then
		fadeOut(current)
	end
	local s = pick:Clone()
	s.Looped = false
	s.Volume = 0
	s.SoundGroup = group
	s.Parent = SoundService -- client-made: only we hear it
	s:Play()
	TweenService:Create(s, TweenInfo.new(D.MUSIC.fade), { Volume = pick.Volume }):Play()
	current = s
	card:show(pick.Name)
	task.delay(D.MUSIC.cardHold, function()
		if gen == my then
			card:hide()
		end
	end)
	-- ponytail: a song that never loads never ends, so the pool goes quiet until you change area.
	s.Ended:Once(function()
		if current == s and gen == my then
			current = nil
			s:Destroy()
			playFrom(f)
		end
	end)
end

-- The area you're in (nil = none). Same pool as now = keep the song going.
function MusicController.setPool(name: string?)
	wanted = name
	local f = if held then nil else poolFolder(name)
	if f == pool then
		return
	end
	pool = f
	if f then
		playFrom(f)
	elseif current then
		gen += 1
		fadeOut(current)
		current = nil
	end
end

local volumePct = 100

function MusicController.setVolume(pct: number)
	volumePct = math.clamp(pct, 0, 100)
	if group then
		group.Volume = D.MUSIC.volume * volumePct / 100
	end
	if emotes then
		emotes.Volume = volumePct / 100
	end
end

-- The music SoundGroup (nil before init). Ask for it here: BloxyController re-parents every SoundService
-- group under its master, so SoundService.MidoriMusic doesn't stay where it was made.
function MusicController.group(): SoundGroup?
	return group
end

-- Emote sounds' SoundGroup (user, 2026-11-01: the MUSIC VOLUME slider turns them down too). Their own group so
-- they aren't also cut to D.MUSIC.volume like the soundtrack.
function MusicController.emoteGroup(): SoundGroup?
	return emotes
end

function MusicController.hold(on: boolean)
	if on == held then
		return
	end
	held = on
	if folder then -- before init, init's own setPool picks it up
		MusicController.setPool(wanted)
	end
end

function MusicController.announce(title: string)
	if not card then
		return -- not set up yet (init waits on the Locations folder's task)
	end
	gen += 1
	local my = gen
	card:show(title)
	task.delay(D.MUSIC.cardHold, function()
		if gen == my then
			card:hide()
		end
	end)
end

function MusicController.init()
	folder = Paths.Assets:WaitForChild("Music")
	group = Instance.new("SoundGroup")
	group.Name = "MidoriMusic"
	group.Parent = SoundService
	emotes = Instance.new("SoundGroup")
	emotes.Name = "MidoriEmotes"
	emotes.Parent = SoundService
	local function loadVolume()
		local v = Players.LocalPlayer:GetAttribute("SetMusic")
		MusicController.setVolume(if typeof(v) == "number" then v else volumePct)
	end
	Players.LocalPlayer:GetAttributeChangedSignal("SetMusic"):Connect(loadVolume)
	loadVolume()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MidoriMusic"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 3
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	card = Sticker.new({
		parent = gui,
		tag = "NOW PLAYING",
		anchor = Vector2.new(1, 0.5),
		position = UDim2.new(1, -12, 0.5, 0),
		size = 34,
		away = Vector2.new(380, 0), -- slides in from the right edge, leaves back out
	})
	MusicController.setPool(nil)
end

return MusicController
