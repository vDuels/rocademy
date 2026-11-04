--!strict
-- Emote pool (user, 2026-10-18). You hold SLOTS emotes (the G wheel); each slot is rerolled with 1
-- reroll from the P menu's Emotes page (RerollService, keys "Emote<n>"), never onto one you already hold.
-- `anim` = an Animation asset id string ("rbxassetid://..."); "" = no animation yet (the wheel just
-- shows the name). `loop` = keeps playing until you move (EmoteController restarts it each time it ends).
-- `speed` = playback speed (1 = as authored). `sound` = a Sound in Assets.Sfx.Emotes, played from the
-- emoter's character for everyone around (each client hears it when it sees that animation start).
-- Saves store the id: a slot holding an id that's gone gets a free reroll on load.
-- (2026-11-01, user: "remove the ability to do /e emotes and save them as emotes to be used in our game,
-- remove all current emotes"): these are the animations Roblox's /e commands played (the R6 Animate
-- script's wave / point / cheer / laugh / dance1-3, first variant of each dance). Rarities are my picks.
return {
	SLOTS = 4,
	items = {
		{ id = "Wave", name = "Wave", rarity = "Common", anim = "rbxassetid://128777973" },
		{ id = "Point", name = "Point", rarity = "Common", anim = "rbxassetid://128853357" },
		{ id = "Cheer", name = "Cheer", rarity = "Common", anim = "rbxassetid://129423030" },
		{ id = "Laugh", name = "Laugh", rarity = "Rare", anim = "rbxassetid://129423131" },
		{ id = "Dance", name = "Dance", rarity = "Rare", anim = "rbxassetid://182435998", loop = true },
		{ id = "Dance2", name = "Dance 2", rarity = "Epic", anim = "rbxassetid://182436842", loop = true },
		{ id = "Dance3", name = "Dance 3", rarity = "Legendary", anim = "rbxassetid://182436935", loop = true },
		-- user, 2026-11-01: 25% faster, its own sound, plays once, Legendary
		{ id = "LoudLaugh", name = "Loud Laugh", rarity = "Legendary", anim = "rbxassetid://78333497105617", speed = 1.25, sound = "LoudLaugh" },
		-- user, 2026-11-01: Mythic, looped, with a sound (put it in Assets.Sfx.Emotes as "TakeTheL"; silent until then)
		{ id = "TakeTheL", name = "Take The L", rarity = "Mythic", anim = "rbxassetid://107395028525016", loop = true, sound = "TakeTheL" },
	},
}
