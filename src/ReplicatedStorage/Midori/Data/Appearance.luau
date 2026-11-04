--!strict
-- Appearance reroll pools (ServerScriptService.Midori.RerollService). Each reroll changes ONE slot.
-- `id` is a Roblox catalog asset id (SkinTone: a BrickColor name; 0 = nothing), `name` is what the
-- menu shows, `rarity` is Common/Rare/Epic/Legendary/Mythic (Shared/Rarity), optional `gender`
-- ("Male"/"Female", nil = anyone) limits who can roll it. Saves store the id, so removing an item
-- from a pool doesn't take it from players who already have it.
-- PLACEHOLDERS (2026-10-05): classic Roblox-made items, asset types checked with GetProductInfo.
-- Face also takes the special id "Headless". Optional `thumb` = asset id for the menu icon.
-- `field` = the HumanoidDescription property the slot sets; `types` = catalog AssetTypeIds the dev
-- menu accepts for the slot (accessory slots take any accessory type). `none` = chance a roll lands on
-- nothing (id 0, checked before rarity; never when you already have nothing), `noneName` = how
-- nothing shows (default "None"). `rerollable = false` = no reroll button.
-- Shirts/pants are NOT slots (removed 2026-10-17): everyone wears D.UNIFORM (RerollService.describe).
local ACCESSORY_TYPES = { 8, 41, 42, 43, 44, 45, 46, 47, 57, 58 }

local Appearance = {
	order = { "SkinTone", "Face", "Hair", "Hat", "FaceAccessory", "BackAccessory" },
	slots = {
		SkinTone = {
			label = "Skin Tone",
			items = {
				{ id = "Light orange", name = "Light Orange", rarity = "Common" },
				{ id = "Nougat", name = "Nougat", rarity = "Common" },
				{ id = "Pastel brown", name = "Pastel Brown", rarity = "Common" },
				{ id = "Brown", name = "Brown", rarity = "Common" },
				{ id = "Reddish brown", name = "Reddish Brown", rarity = "Common" },
				{ id = "Brick yellow", name = "Brick Yellow", rarity = "Rare" },
				{ id = "Bright yellow", name = "Noob Yellow", rarity = "Epic" },
				{ id = "Medium stone grey", name = "Stone", rarity = "Legendary" },
				{ id = "Really black", name = "Void", rarity = "Mythic" },
			},
		},
		Face = {
			label = "Face",
			field = "Face",
			types = { 18 },
			items = {
				{ id = 144075659, name = "Smile", rarity = "Common" },
				{ id = 7074764, name = "Chill", rarity = "Common" },
				{ id = 7076110, name = "Chubs", rarity = "Rare" },
				{ id = 7317793, name = "Good Intentioned", rarity = "Rare" },
				{ id = 7074786, name = "Check It", rarity = "Common" },
				{ id = 209995366, name = "Joyful Smile", rarity = "Epic" },
				{ id = 7699174, name = "Silly Fun", rarity = "Common" },
				{ id = 20052135, name = "Prankster", rarity = "Legendary" },
				{ id = 7131361, name = "Sad Zombie", rarity = "Legendary" },
				-- Not a catalog face: RerollService hides the head instead (hats/hair still show). `thumb` = icon asset.
				{ id = "Headless", name = "Headless", rarity = "Mythic", thumb = 134082579 },
			},
		},
		Hair = {
			label = "Hair",
			perGender = true, -- each gender keeps its own (RerollService.swapLook); every other slot carries over
			none = 0.05, -- chance a roll lands on nothing
			noneName = "Bald",
			field = "HairAccessory",
			types = ACCESSORY_TYPES,
			items = {
				-- Men (user's list, 2026-10-05)
				{ id = 32278814, name = "Trecky Hair", rarity = "Common", gender = "Male" },
				{ id = 26658141, name = "Messy Hair", rarity = "Common", gender = "Male" },
				{ id = 188003563, name = "Brown Hair Dude", rarity = "Common", gender = "Male" },
				{ id = 83013207, name = "Charming Brown-haired Fellow", rarity = "Common", gender = "Male" },
				{ id = 80921949, name = "Blonde Charmer", rarity = "Common", gender = "Male" },
				{ id = 20372960, name = "Bed Hair", rarity = "Rare", gender = "Male" },
				{ id = 212967757, name = "Chestnut Style", rarity = "Rare", gender = "Male" },
				{ id = 62246484, name = "Auburn Scene Hair", rarity = "Rare", gender = "Male" },
				{ id = 323476364, name = "Brown Scene Hair", rarity = "Rare", gender = "Male" },
				{ id = 293316132, name = "Blue Scene Hair", rarity = "Rare", gender = "Male" },
				{ id = 76059443, name = "Dark Blue Light Hair", rarity = "Rare", gender = "Male" },
				{ id = 19327469, name = "Equinox", rarity = "Epic", gender = "Male" },
				{ id = 77359955, name = "Lava Hair", rarity = "Epic", gender = "Male" },
				{ id = 2566049121, name = "Split Equinox", rarity = "Epic", gender = "Male" },
				{ id = 456225312, name = "Midnight Motor Magnifique", rarity = "Epic", gender = "Male" },
				{ id = 154818848, name = "Even More Mad Scientist Hair", rarity = "Epic", gender = "Male" },
				{ id = 1492205990, name = "Zeus Beard", rarity = "Legendary", gender = "Male" },
				{ id = 2316715505, name = "Blue Split Charismatic Hair", rarity = "Epic", gender = "Male" },
				{ id = 191101707, name = "Flaming Mohawk", rarity = "Mythic", gender = "Male" },
				{ id = 21635620, name = "Samurai Hair", rarity = "Epic", gender = "Male" }, -- user, 2026-10-10
				-- Beautiful Hair family (user, 2026-10-10; all share mesh 16627529 unless noted):
				-- plain colours Common, special textures/meshes ("like Adurite") Rare.
				{ id = 16630147, name = "Beautiful Hair for Beautiful People", rarity = "Common", gender = "Male" },
				{ id = 17877340, name = "Beautiful Brown Hair for Beautiful People", rarity = "Common", gender = "Male" },
				{ id = 233615637, name = "Beautiful Blonde Hair for Beautiful People", rarity = "Common", gender = "Male" },
				{ id = 376805560, name = "Beautiful Orange Hair for Beautiful People", rarity = "Common", gender = "Male" },
				{ id = 221175027, name = "Beautiful Red Hair for Beautiful People", rarity = "Common", gender = "Male" },
				{ id = 226186871, name = "Beautiful Green Hair for Beautiful People", rarity = "Common", gender = "Male" },
				{ id = 17424092, name = "Beautiful Hair for Purple People", rarity = "Common", gender = "Male" },
				{ id = 151786902, name = "Neon Green Beautiful Hair", rarity = "Common", gender = "Male" }, -- limited
				{ id = 3185830268, name = "Pastel Hair for Beautiful People", rarity = "Rare", gender = "Male" },
				{ id = 1191145114, name = "Adurite Hair for Beautiful People", rarity = "Rare", gender = "Male" }, -- own mesh
				{ id = 564449640, name = "Beautiful Hair for Beautiful Space People", rarity = "Rare", gender = "Male" }, -- own mesh, limited
				-- Manga Hero colours (user, 2026-10-10, unisex)
				{ id = 553917533, name = "Blonde Manga Hero", rarity = "Epic" },
				{ id = 398672920, name = "Black Manga Hero Hair", rarity = "Epic" },
				{ id = 398672568, name = "Blue Manga Hero Hair", rarity = "Epic" },
				{ id = 315353828, name = "Neon Rocker", rarity = "Legendary" }, -- user, 2026-10-10
				{ id = 1213432315, name = "Frozen Snowflake Hair", rarity = "Legendary" },
				-- Women
				{ id = 62724852, name = "Chestnut Bun", rarity = "Common", gender = "Female" },
				{ id = 451220849, name = "Lavender Updo", rarity = "Common", gender = "Female" },
				-- Anime Girl colours (user, 2026-10-10)
				{ id = 185812297, name = "Golden Anime Girl Hair", rarity = "Rare", gender = "Female" },
				{ id = 164482409, name = "Blue Anime Girl Hair", rarity = "Rare", gender = "Female" },
				{ id = 164482468, name = "Black Anime Girl Hair", rarity = "Rare", gender = "Female" },
				{ id = 835064879, name = "Teal Anime Girl Hair", rarity = "Rare", gender = "Female" },
				-- Golden Hair colours (user, 2026-10-10)
				{ id = 13476917, name = "Golden Hair", rarity = "Common", gender = "Female" },
				{ id = 13745548, name = "Cinnamon Hair", rarity = "Common", gender = "Female" },
				-- Action Ponytail colours (user, 2026-10-10; 8-Bit and Frozen are different meshes, left out)
				{ id = 398673196, name = "Blonde Action Ponytail", rarity = "Common", gender = "Female" },
				{ id = 398673423, name = "Purple Action Ponytail", rarity = "Common", gender = "Female" },
				{ id = 2042026822, name = "Brunette Action Ponytail", rarity = "Common", gender = "Female" },
				{ id = 1708329071, name = "Black Action Ponytail", rarity = "Common", gender = "Female" },
				{ id = 1513252656, name = "Red Action Ponytail", rarity = "Common", gender = "Female" },
				{ id = 638100095, name = "Teal Action Ponytail", rarity = "Common", gender = "Female" },
				-- User's list (2026-10-10)
				{ id = 25517576, name = "Sassy Headband", rarity = "Common", gender = "Female" },
				{ id = 1772372988, name = "Black Long and Straight Hair", rarity = "Rare", gender = "Female" },
				{ id = 2588168421, name = "Frozen Action Ponytail", rarity = "Epic", gender = "Female" },
				{ id = 365632597, name = "Cool Blue Girl Hair", rarity = "Rare", gender = "Female" },
				{ id = 439984886, name = "Universe Girl Hair", rarity = "Epic", gender = "Female" },
				{ id = 878922157, name = "Long Twilight Hair", rarity = "Epic", gender = "Female" },
				{ id = 727320877, name = "Long Pastel Hair", rarity = "Epic", gender = "Female" },
				{ id = 430063008, name = "Strawberry Ice Cream Hair", rarity = "Legendary", gender = "Female" },
				{ id = 2706161833, name = "Vanilla Ice Cream Hair", rarity = "Legendary", gender = "Female" },
				{ id = 553892446, name = "Mint Ice Cream Hair", rarity = "Legendary", gender = "Female" },
				{ id = 600982603, name = "Orange Sherbet Hair", rarity = "Legendary", gender = "Female" },
				{ id = 268197996, name = "Green Hair with Oversized Bow", rarity = "Legendary", gender = "Female" },
				{ id = 241671246, name = "Rainbow Club Kid Hair", rarity = "Legendary", gender = "Female" },
				{ id = 2804642677, name = "Half-Dragon Heir Hair", rarity = "Legendary", gender = "Female" },
				{ id = 362030276, name = "Ice Princess Ceremonial Horns", rarity = "Epic", gender = "Female" },
				{ id = 168167316, name = "Animazing Hair", rarity = "Epic", gender = "Female" }, -- user listed it as epic AND mythic; asked
				{ id = 1743937917, name = "Ice Prince Ceremonial Horns", rarity = "Mythic", gender = "Female" },
			},
		},
		Hat = {
			label = "Hat",
			none = 0.5,
			field = "HatAccessory",
			types = ACCESSORY_TYPES,
			items = {
				{ id = 1374269, name = "Kitty Ears", rarity = "Legendary" },
				{ id = 607702162, name = "Roblox Baseball Cap", rarity = "Common" },
				{ id = 2646473721, name = "Roblox Visor", rarity = "Common" },
				{ id = 607700713, name = "Roblox Logo Visor", rarity = "Common" }, -- user said "Uncommon" (no such tier yet)
				{ id = 617605556, name = "Medieval Hood of Mystery", rarity = "Rare" },
				{ id = 2316680311, name = "Azul Tigre Fedora", rarity = "Epic" },
				{ id = 2565914585, name = "Breakfast Fedora", rarity = "Legendary" },
				-- User's list (2026-10-10). Rarities are the user's, even for the limiteds
				-- (Lampshade, Sinister Branches, Chill Cap); Bunny Ears is the only Mythic hat.
				{ id = 89615321, name = "Hungry Dino", rarity = "Common" },
				{ id = 6837506, name = "Tin Pot", rarity = "Rare" },
				{ id = 10476359, name = "Paper Hat", rarity = "Common" },
				{ id = 15967743, name = "Empyrean Reignment", rarity = "Legendary" },
				{ id = 150337814, name = "Violet Ribbons", rarity = "Legendary" },
				{ id = 139152472, name = "Holiday Crown", rarity = "Rare" },
				{ id = 277857132, name = "Obvious Spy Cap", rarity = "Common" },
				{ id = 122277006, name = "Canadian Toque", rarity = "Common" },
				{ id = 68259961, name = "Buddy's Baseball Cap", rarity = "Rare" },
				{ id = 63689493, name = "Hunter Snow Cap", rarity = "Common" },
				{ id = 335078777, name = "Brown Furry Animal Hood and Scarf", rarity = "Epic" },
				{ id = 102619342, name = "Punk Kid", rarity = "Common" },
				{ id = 74219283, name = "Red Spikes of Victory", rarity = "Rare" },
				{ id = 3185834086, name = "Pink Unicorn Headband", rarity = "Rare" },
				{ id = 1374256, name = "Antennae", rarity = "Epic" },
				{ id = 125886373, name = "Classic Fisherman's Cap", rarity = "Common" },
				{ id = 489168523, name = "Wanwood Branches", rarity = "Rare" },
				{ id = 140481395, name = "Telamon's Turkey Suit", rarity = "Epic" },
				{ id = 1080949, name = "Bunny Ears", rarity = "Mythic" },
				{ id = 1098282, name = "Lampshade", rarity = "Legendary" },
				{ id = 111902832, name = "Red Animal Hoodie", rarity = "Rare" },
				{ id = 71484026, name = "Sinister Branches", rarity = "Epic" },
				{ id = 321570512, name = "Chill Cap", rarity = "Epic" },
				{ id = 187846561, name = "Neon Purple Animal Hoodie", rarity = "Epic" },
				{ id = 1046283703, name = "Fishing Lure Hat", rarity = "Common" },
				{ id = 60674565, name = "8-Ball Headphones", rarity = "Legendary" },
				{ id = 335134524, name = "Poets Cap", rarity = "Common" },
				{ id = 49939622, name = "Newspaper Bandit", rarity = "Common" },
				{ id = 215724779, name = "Robot Beanie", rarity = "Rare" },
				{ id = 122275601, name = "Camp ROBLOX", rarity = "Common" },
			},
		},
		FaceAccessory = {
			label = "Face Accessory",
			none = 0.5,
			field = "FaceAccessory",
			types = ACCESSORY_TYPES,
			items = {
				{ id = 11884330, name = "Nerd Glasses", rarity = "Common" },
				{ id = 20642008, name = "Bandit", rarity = "Common" }, -- user, 2026-10-10 (was Rare)
				{ id = 1192464705, name = "Bear Face Mask", rarity = "Common" }, -- user, 2026-10-10 (was Rare)
				{ id = 22070802, name = "Secret Kid Wizard Glasses", rarity = "Rare" },
				{ id = 11748356, name = "Clockwork's Shades", rarity = "Mythic" },
				-- User's list (2026-10-10)
				{ id = 15727015, name = "Eye Poppers", rarity = "Legendary" },
				{ id = 15318115, name = "Neon Green Shutter Shades", rarity = "Epic" },
				{ id = 19380685, name = "Snake Eyes", rarity = "Epic" },
				{ id = 1744055577, name = "Vampire Face Mask", rarity = "Epic" },
				{ id = 15726947, name = "Retro 3D Glasses", rarity = "Rare" },
				{ id = 63995305, name = "Rainbow Shades", rarity = "Epic" },
				{ id = 60662943, name = "Aloha Shades", rarity = "Epic" },
				{ id = 62690529, name = "Thick Rimmed Glasses 3.0", rarity = "Common" },
				{ id = 125369932, name = "Hipster Glasses", rarity = "Common" },
				{ id = 2830417823, name = "Cat Mouth Mask", rarity = "Epic" },
				{ id = 1536058591, name = "Bunny Face Mask", rarity = "Epic" },
				{ id = 3756446030, name = "Genkuro: Black Kitsune Mask", rarity = "Legendary" },
				{ id = 3210207381, name = "Kitsune Mask", rarity = "Legendary" },
			},
		},
		BackAccessory = {
			label = "Back Accessory",
			none = 0.5,
			field = "BackAccessory",
			types = ACCESSORY_TYPES,
			items = {
				{ id = 106690045, name = "Classic Swordpack Throwback", rarity = "Common" }, -- user, 2026-10-10 (was Rare)
				-- User's list (2026-10-10). Back Axe Guitar + Katana Traveling Pack are limiteds (user's rarities kept).
				{ id = 1180432276, name = "Stealthy Ninja Swordpack", rarity = "Rare" },
				{ id = 62673504, name = "Dark Age Ninja Swordpack", rarity = "Epic" },
				{ id = 1230404580, name = "Back Axe Guitar", rarity = "Legendary" },
				{ id = 398673908, name = "Katana Traveling Pack", rarity = "Epic" },
				{ id = 1744123855, name = "Light Back Axe Guitar", rarity = "Legendary" },
				{ id = 258183674, name = "Shoulder Sloth", rarity = "Legendary" },
				{ id = 417455866, name = "Guitar Backpack", rarity = "Epic" },
				{ id = 302281482, name = "Deluxe Bat Wings", rarity = "Epic" },
				{ id = 2705898346, name = "Xanwood Back Guitar", rarity = "Epic" },
			},
		},
	},
}

-- The items of `slot` that `gender` can roll (unisex + that gender's).
function Appearance.eligible(slot: string, gender: string?): { any }
	local out = {}
	for _, item in Appearance.slots[slot].items do
		if item.gender == nil or item.gender == gender then
			table.insert(out, item)
		end
	end
	return out
end

return Appearance
