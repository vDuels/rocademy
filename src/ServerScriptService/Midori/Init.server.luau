--!strict
-- Midori server boot. Remotes are created first so client WaitForChild calls resolve.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Paths = require(ReplicatedStorage:WaitForChild("Midori"):WaitForChild("Paths"))
local MoveSchema = Paths.shared("MoveSchema")
local Invariants = Paths.shared("Invariants")
local Registry = Paths.server("FighterRegistry")
local CombatService = Paths.server("CombatService")
local DummyService = Paths.server("DummyService")
local StyleService = Paths.server("StyleService")
local D = Paths.data("Defaults")

local style = MoveSchema.style(D.DEFAULT_STYLE)

Paths.shared("Ragdoll").initServer() -- collision groups (characters / ragdolls / carried bodies), before fighters spawn
CombatService.init() -- creates the remotes (ChronoService needs ChronoDelay)
Paths.server("ChronoService").init() -- character replication for fighters in combat
StyleService.init()
Paths.server("RoleService").init() -- owner-set roles (Dev access); needs the remotes
Paths.server("WeaponService").init() -- style weapons (e.g. BanHammer), before fighters spawn
Paths.shared("AnimDebug").start() -- stuck-animation diagnostic; does nothing unless D.ANIM_DEBUG
Paths.server("RerollService").init() -- before PerkRollService: it hooks PlayerData loading
Paths.server("AdminService").init() -- ,nick / ,bring / ,freeze; before PerkRollService: it hooks PlayerData loading
Paths.server("HeightService").init() -- owner-set height (D.HEIGHT); before PerkRollService: it hooks PlayerData loading
Paths.server("SettingsService").init() -- P menu Settings (FOV / toggle run); before PerkRollService: it hooks PlayerData loading
Paths.server("PerkRollService").init()
Paths.server("CodeService").init()
Paths.server("SodaService").init() -- Bloxy Cola pickups (tagged cans)
Paths.server("BloxyService").init() -- too much Bloxy Cola: blur / drunk / blackout
Paths.server("TravelService").init() -- teleport pads / doors (tagged, "To" attribute)
Paths.server("ApartmentService").init() -- apartments: plots, Furnish edits (pads with Apartment = true get you in)
Paths.server("SeatService").init() -- E to sit (touch-sitting off)
Paths.server("KnockService").init() -- knocked players' Carry prompts + the drop remote
Paths.server("SkateService").init() -- skateboard on/off (the board + "Skating"); riding is client-side
Paths.server("CutsceneService").init() -- dev ",cs <id>"; fight moves call play1v1 / play3P
Paths.server("PrivateServerService").init() -- share-code private servers (P menu SERVERS)
Paths.server("FreecamService").init() -- Roblox's Freecam (Shift+P) for anyone with a title
Paths.server("VoidService").init() -- void deaths: kill below the void, force a respawn if one gets stuck
Registry.trackPlayers(StyleService.styleFor)
if D.CHECK_INVARIANTS then
	Invariants.report(style)
end
DummyService.init(style)

-- Titles for nametags (outside Midori so other server code can require it easily).
require(game:GetService("ServerScriptService"):WaitForChild("NametagService")).init()