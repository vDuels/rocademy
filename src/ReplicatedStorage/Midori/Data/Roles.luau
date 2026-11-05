--!strict
-- Roles (RoleService, user 2026-10-16). Set from the P menu's Panel (Owner and Managers).
-- A player can hold SEVERAL roles (user, 2026-11-01): what they can do is everything any of them gives;
-- the nametag shows the title they pick in Settings (else their highest role's). Each role gives:
--   title      a nametag title (a Data/Titles id, nil = none). A title given from the Panel overrides
--              the role's until the role changes again.
--   dev        the Panel, changing YOURSELF only, + dev chat commands (,e / ,cs ...).
--   cosmetics  the Panel can also set OTHER players' cosmetics (look, clothes, gender, reset look), not
--              their titles, style, traits or Bux (user, 2026-10-22: Staff).
--   manage     the Panel for anyone in the server (yourself included), titles, and giving roles
--              ranked below Manager (user, 2026-10-22).
--   freeSpins  rerolls cost nothing while you have the role (the saved Spins count is untouched; lose
--              the role and you're back on it). EVERY role but Player has it unless it says
--              freeSpins = false (user, 2026-10-22). Several roles: any one that has it is enough.
--   selfHeight { min, max }: may set their OWN height (D.HEIGHT scale) in that range from the Panel's
--              Height row (RerollService DevSet), no one else's (user, 2026-11-04: Investor).
export type Role = { title: string?, dev: boolean, cosmetics: boolean?, manage: boolean?, freeSpins: boolean?, selfHeight: { number }? }

return table.freeze({
	-- Settable roles, lowest first (a Manager can give the ones before "Manager").
	order = table.freeze({ "Player", "Tester", "Helper", "Contributor", "Content Creator", "Investor", "Staff", "Developer", "Manager" }),
	roles = table.freeze({
		Player = { title = nil, dev = false, freeSpins = false },
		Tester = { title = "Tester", dev = false }, -- user, 2026-10-17
		Helper = { title = "Helper", dev = false },
		Contributor = { title = "Contributor", dev = false },
		["Content Creator"] = { title = "Content Creator", dev = false, freeSpins = false }, -- user, 2026-11-01: a title, no free rerolls
		-- user, 2026-11-04: white -> grey title; the Panel on themselves only (+ Height in range), no free rerolls
		Investor = { title = "Investor", dev = true, freeSpins = false, selfHeight = { 0.8, 1.23 } },
		Staff = { title = "Staff", dev = true, cosmetics = true },
		Developer = { title = "Developer", dev = true },
		Manager = { title = "Manager", dev = true, manage = true }, -- user, 2026-10-22: red -> maroon
		Owner = { title = "Developer", dev = true, manage = true }, -- D.OWNER_USER_ID only; can't be set or removed
	} :: { [string]: Role }),
	-- Roles for anyone with nothing saved from the Panel.
	defaults = table.freeze({
		[2314601548] = "Staff", -- getaway
		[5485915239] = "Staff", -- CA5_UAL
		[1336190713] = "Tester",
		[140164153] = "Tester", -- EssArchives
		[1544270685] = "Tester", -- Erranthehyper
		[8384705672] = "Tester", -- lawljp
	} :: { [number]: string }),
})
