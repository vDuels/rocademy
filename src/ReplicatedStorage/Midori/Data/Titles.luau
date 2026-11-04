--!strict
-- Title looks. Each title is shown above the player's name with a gradient (`from` ->
-- `to`) across its letters and an icon to the RIGHT of the text.
--   shift: animate the gradient (colour-shifting text); `shiftSpeed` = sweeps per second.
--   icon:  your uploaded image id. While it's "" or rbxassetid://0, a diamond in the
--          title's colours is drawn instead so the slot is never empty.
-- Give titles on the server: require(game.ServerScriptService.NametagService).SetTitle(player, "Developer")
export type Title = {
	text: string,
	from: Color3,
	to: Color3,
	icon: string,
	shift: boolean,
	shiftSpeed: number,
}

local Titles: { [string]: Title } = {
	["Content Creator"] = {
		text = "Content Creator",
		from = Color3.fromHex("6bc7ff"), -- user, 2026-11-01
		to = Color3.fromHex("009fd4"),
		icon = "rbxassetid://0",
		shift = true,
		shiftSpeed = 0.5,
	},
	Contributor = {
		text = "Contributor",
		from = Color3.fromRGB(46, 189, 89), -- green
		to = Color3.fromRGB(168, 240, 158), -- light green
		icon = "rbxassetid://0",
		shift = true,
		shiftSpeed = 0.5,
	},
	Developer = {
		text = "Developer",
		from = Color3.fromRGB(44, 116, 255), -- blue
		to = Color3.fromRGB(150, 200, 255), -- pastel blue
		icon = "rbxassetid://0",
		shift = true,
		shiftSpeed = 0.5,
	},
	Helper = {
		text = "Helper",
		from = Color3.fromHex("46ff4f"), -- green (user, 2026-10-22)
		to = Color3.fromHex("ffffff"), -- white
		icon = "rbxassetid://0",
		shift = true,
		shiftSpeed = 0.5,
	},
	Manager = {
		text = "Manager",
		from = Color3.fromRGB(255, 30, 40), -- red
		to = Color3.fromRGB(120, 10, 25), -- maroon
		icon = "rbxassetid://0",
		shift = true,
		shiftSpeed = 0.5,
	},
	Staff = {
		text = "Staff",
		from = Color3.fromRGB(140, 60, 255), -- purple
		to = Color3.fromRGB(225, 120, 255), -- pinkish purple
		icon = "rbxassetid://0",
		shift = true,
		shiftSpeed = 0.5,
	},
	Tester = {
		text = "Tester",
		from = Color3.fromRGB(255, 140, 40), -- orange
		to = Color3.fromRGB(255, 214, 140), -- light amber
		icon = "rbxassetid://0",
		shift = true,
		shiftSpeed = 0.5,
	},
}

return table.freeze(Titles)
