--!strict
-- Checks the two frame-data invariants from the spec for every follow-up pair:
--   gapOk:  hitstun < endlag + nextStartup          (victim gets a gap to block in)
--   dashOk: hitstun + 0.2 > endlag + nextStartup    (dash never escapes straight out of hitstun)
-- nextStartup is scaled by attack speed at each tested adrenaline level.
local Paths = require(script.Parent.Parent:WaitForChild("Paths"))
local D = Paths.data("Defaults")
local CombatMath = Paths.shared("CombatMath")

export type Row = {
	from: string,
	to: string,
	adrenaline: number,
	hitstun: number,
	gap: number,
	gapOk: boolean,
	dashOk: boolean,
	exception: string?,
}

local Invariants = {}

Invariants.ADRENALINE_LEVELS = { 0, 250, 500 }

local function followUps(style: any): { { string } }
	local list = {}
	local chain = style.m1Chain
	for i, id in ipairs(chain) do
		-- The last hit ends the combo (COMBO_END_DELAY), so it has no M1 follow-up.
		if i < #chain then
			table.insert(list, { id, chain[i + 1] })
		end
		if style.m2 then
			table.insert(list, { id, style.m2 })
		end
	end
	if style.m2 then
		table.insert(list, { style.m2, chain[1] })
		table.insert(list, { style.m2, style.m2 })
	end
	return list
end

function Invariants.check(style: any): ({ Row }, number)
	local rows: { Row } = {}
	local failures = 0
	local exc = style.invariantExceptions
	for _, pair in followUps(style) do
		local from, to = style.moves[pair[1]], style.moves[pair[2]]
		for _, adr in Invariants.ADRENALINE_LEVELS do
			local gap = from.endlag + to.startup / CombatMath.speed(adr)
			local row: Row = {
				from = from.id,
				to = to.id,
				adrenaline = adr,
				hitstun = from.hitstun,
				gap = gap,
				gapOk = from.hitstun < gap,
				dashOk = from.hitstun + D.POST_STUN_DASH_DELAY > gap,
				exception = exc[from.id .. "->" .. to.id] or exc["*->" .. to.id] or exc[from.id .. "->*"],
			}
			if not (row.gapOk and row.dashOk) and not row.exception then
				failures += 1
			end
			table.insert(rows, row)
		end
	end
	return rows, failures
end

function Invariants.report(style: any): number
	local rows, failures = Invariants.check(style)
	for _, r in rows do
		if r.gapOk and r.dashOk then
			continue
		end
		local broken = if not r.gapOk then "no block gap" else "dash escapes"
		local msg = string.format(
			"[Invariants] %s -> %s @%d adrenaline: hitstun %.3f vs follow-up %.3f (%s)",
			r.from,
			r.to,
			r.adrenaline,
			r.hitstun,
			r.gap,
			broken
		)
		if r.exception then
			print(msg .. " | allowed: " .. r.exception)
		else
			warn(msg)
		end
	end
	print(string.format("[Invariants] %s: %d checks, %d unexpected failures", style.name, #rows, failures))
	return failures
end

return Invariants
