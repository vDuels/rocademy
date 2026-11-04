--!strict
-- The only place remote names live. The server creates them in init(); everyone uses get().
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "MidoriRemotes"

local Names = table.freeze({
	-- client -> server
	Attack = "Attack", -- (kind: "M1"|"M2"|"R", clientTime)
	AttackPose = "AttackPose", -- (rootCFrame) streamed while attacking; the server places our hitboxes there
	AttackRelease = "AttackRelease", -- (kind, clientTime) the attack button was let go (charge moves)
	Block = "Block", -- (pressed: boolean, clientTime)
	Dash = "Dash", -- (direction: Vector3, kind: "Front"|"Side"|"Back", clientTime)
	CombatMode = "CombatMode", -- (on: boolean)
	Reroll = "Reroll", -- (tab: "Appearance"|"Loadout"|"Emotes", key: appearance slot | "Style" | "Traits" (the equipped locker's unlocked traits; costs TRAIT_LOCK_MULT ^ locks) | "Emote<n>", target?) reroll ONE thing, costs 1 spin
	RerollMany = "RerollMany", -- (slots: { appearance slot }, target?) several appearance rerolls in one go, all-or-nothing; answered as RerollResult("Many", nil, { slot = id }?, rolls)
	RerollResult = "RerollResult", -- (tab, slot, id?) to the roller; id nil = rejected ("Gender"/"Dev"/"Equip" answers too)
	Undo = "Undo", -- (key: appearance slot | loadout key) free swap back to what the last reroll replaced
	Locker = "Locker", -- ("Store", what: appearance slot | "Style") puts what you wear in an empty locker slot; ("Swap", n) wears locker slot n's item, yours goes in its place. Answered as RerollResult("Locker", action, ok?)
	TraitLock = "TraitLock", -- (t: number) toggle the lock on your trait t (free); answered as RerollResult("Lock", t, locked?)
	ServerCreate = "ServerCreate", -- () make a private server and teleport there
	ServerJoin = "ServerJoin", -- (code: string) join a private server by its code
	ServerLeave = "ServerLeave", -- () back to a public server
	ServerResult = "ServerResult", -- (ok: boolean, message: string) to the asker
	Cutscene = "Cutscene", -- (id, anchor: CFrame, actors: { [role]: Model }, startAt: number) play cutscene id (Data/Cutscenes)
	SetGender = "SetGender", -- (gender: "Male"|"Female") free; swaps to that gender's own saved look
	DevSet = "DevSet", -- (key: appearance slot | "Title" | "Style" | "Trait<n>" (equipped style slot), value: string, targetUserId: number?) devs only; target must be in this server
	SetRole = "SetRole", -- (target: UserId | username, role: "Player"|"Dev"|nil) owner only; nil role = look it up
	RoleResult = "RoleResult", -- (ok, message, role?) to the owner
	ChronoDelay = "ChronoDelay", -- ({ [Player]: seconds }) how far behind we draw each Chrono fighter (lag comp)
	RedeemCode = "RedeemCode", -- (code: string) redeem a code (CodeService); answered with CodeResult
	Carry = "Carry", -- ("PickUp", knocked model) hover pick (InteractController) | ("Grip", knocked model) finish them | ("Drop") put down who you carry
	Skate = "Skate", -- (on: boolean) board on/off (SkateService welds the board, sets the "Skating" character attribute)
	Soda = "Soda", -- client -> server ("Pickup", can) | ("Buy", vending machine) | "Open"|"Drink"|"Sip"|"Drop"; server -> the holder ("Pickup")
	Travel = "Travel", -- client -> server (pad: BasePart) use a teleport pad / door; server -> the traveller "Out" | "In" (screen fade)
	Sit = "Sit", -- (seat: Seat) sit in it (SeatService)
	RoleList = "RoleList", -- client -> server ("List") | ("Strip", userId) owners only (RoleService); server -> asker (ok, message, { {id, name, role} }?)
	OwnerGive = "OwnerGive", -- client -> server (who: "me" | name start, kind: "Spins" | "Bux", amount) owners (D.OWNER_IDS) give rerolls / Bux (AdminService); server -> asker (ok, message)
	Settings = "Settings", -- client -> server ("Fov", number) | ("ToggleRun", boolean): saved (SettingsService), echoed as Player attributes SetFov / SetToggleRun
	RigVending = "RigVending", -- client -> server () Panel RIG NEXT CAN (D.OWNER_IDS only): the next vending buy fires the can at the buyer (SodaService); server -> asker (ok, message)
	Furnish = "Furnish", -- client -> server ("Place", { item, room?, parent?, x, z, rot }) | ("Move", uid, same) | ("PickUp", uid) | ("Buy", furniture id); server -> asker (ok, message, action)
	Apartment = "Apartment", -- client -> server ("Leave") | ("Build", on) | ("Style", style); server -> the people inside ("Load", plot CFrame, owner UserId, style, items, owned counts (owner only)) | ("Set", uid, item) | ("Remove", uid) | ("Unload"); -> the owner ("Owned", counts) after a buy / code; -> a refused visitor ("Locked")
	-- server -> clients
	AttackStarted = "AttackStarted", -- (model, moveId, speed)
	DashStarted = "DashStarted", -- (model, direction, isCancel)
	HitResult = "HitResult", -- (attacker, victim, result, position, info)
	Dodged = "Dodged", -- (dodger, attacker) a hitbox whiffed on dash i-frames (once per dash)
	StateSync = "StateSync", -- (state, stateEndsAt, reason) to one player when a prediction was wrong
	Knockback = "Knockback", -- (direction, distance, duration) to the victim, who runs it; distance 0 = stop
	CodeResult = "CodeResult", -- (ok, message) to the redeemer
	Announce = "Announce", -- (from: string, text: string) an owner's ,m server-wide message (AnnounceController banner)
	TraitProc = "TraitProc", -- (key) to one player: a perk mod (or a perk's `proc` key) just changed an outcome; the HUD lights that trait's card
	Shot = "Shot", -- ("Fire", id, thrower model, from: Vector3, dir: Vector3, at: server time) | ("End", id, pos: Vector3): a projectile's real path (CombatService shots; client KickCan draws it)
})

local Net = { Names = Names }

local cache: { [string]: RemoteEvent } = {}

function Net.init()
	assert(RunService:IsServer(), "Net.init is server-only")
	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME) or Instance.new("Folder")
	folder.Name = FOLDER_NAME
	for _, name in Names do
		local remote = (folder:FindFirstChild(name) or Instance.new("RemoteEvent")) :: RemoteEvent
		remote.Name = name
		remote.Parent = folder
		cache[name] = remote
	end
	folder.Parent = ReplicatedStorage
end

function Net.get(name: string): RemoteEvent
	local cached = cache[name]
	if cached then
		return cached
	end
	assert((Names :: any)[name], `unknown remote {name}`)
	local remote = ReplicatedStorage:WaitForChild(FOLDER_NAME):WaitForChild(name) :: RemoteEvent
	cache[name] = remote
	return remote
end

return Net
