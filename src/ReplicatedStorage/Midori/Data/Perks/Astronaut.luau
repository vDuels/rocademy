--!strict
-- Prodigy style perk (user, 2026-10-23): turns on Focus (D.FOCUS, ServerScriptService.Midori.FocusSystem).
-- Dodges give Focus instead of adrenaline; landed hits add a little; taking damage loses it. Focus adds
-- anti-heal and counter damage and cuts endlag (no damage bonus), scaling with how full it is.
return {
	id = "Astronaut",
	name = "Astronaut",
	desc = "Landed hits build Focus (counters much more); dodges give no adrenaline. Focus adds up to +10% anti-heal and +25% counter damage and cuts up to 30% endlag, but at 60%+ Focus your M1s deal 3. Getting hit drains it.",
	style = "Prodigy", -- style perk: always on for Prodigy
	behaviour = "Modifiers",
	mods = { focus = 1 },
}
