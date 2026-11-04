--!strict
-- Basic style (default moveset). Fields left out fall back to Data/Defaults via MoveSchema.
-- animHit = time of the "hitbox" marker in the animation at 1x speed (measured 2026-10-02).
-- The client scales playback so the marker lands exactly on `startup`.
local M1_BOX = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -2.25) } -- reach 5 (user, 2026-10-11: -0.5)

local function m1(anim: string, animHit: number, startup: number)
	return {
		kind = "M1",
		anim = anim,
		animHit = animHit,
		startup = startup,
		endlag = 0.2,
		damage = 6,
		hitbox = M1_BOX,
	}
end

return {
	name = "Basic",
	-- Combat-mode idle (played while in combat mode and standing still). Leave the
	-- Animation's AnimationId empty to keep the normal idle.
	idle = "Basic/Idle",
	m1Chain = { "M1_1", "M1_2", "M1_3", "M1_4" },
	guardMax = 25, -- user, 2026-10-10
	m2 = "M2",
	r = "Crit",
	moves = {
		M1_1 = m1("Basic/1", 0.267, 0.267),
		M1_2 = m1("Basic/2", 0.283, 0.27),
		M1_3 = m1("Basic/3", 0.25, 0.25),
		M1_4 = m1("Basic/4", 0.267, 0.267),
		M2 = {
			kind = "M2",
			limbFx = "Right Arm", -- M2 limb flash (user, 2026-10-16)
			antiHeal = 1, -- user, 2026-10-14
			anim = "Basic/M2", -- placeholder until an M2 animation exists
			animHit = 0.36,
			startup = 0.36, -- [TBD] spec suggests 0.4-0.5
			endlag = 0.4,
			cooldown = 0.3, -- after endlag
			damage = 10,
			hitbox = { size = Vector3.new(5, 5, 5.5), offset = CFrame.new(0, 0, -3.25) }, -- reach 6 (user, 2026-10-11: -0.5)
		},
		-- Anti-turtle heavy: guard breaks a block (R default) and can't be perfect blocked. Its cost is the slow startup
		-- (a big counter-crit window; it is NOT NoCounter) and being easy to dash.
		Crit = {
			kind = "R",
			anim = "Basic/4", -- placeholder until a Basic crit animation exists
			animHit = 0.267, -- Basic/4's marker; re-measure with the real anim
			startup = 0.6,
			endlag = 0.5,
			damage = 12, -- user, 2026-10-10 (was 17)
			hitstun = 0.5,
			hitbox = { size = Vector3.new(5, 5, 5), offset = CFrame.new(0, 0, -3) }, -- reach 5.5, = Gio's crit (user, 2026-10-25; was 5x5x6 at -3.5, reach 6.5)
		},
	},
	-- Follow-ups allowed to break the section 2 invariants, with the reason.
	invariantExceptions = {
		["*->M2"] = "pending decision: M2 is the dash-read tool, so dashing out before it lands may be intended",
	},
}
