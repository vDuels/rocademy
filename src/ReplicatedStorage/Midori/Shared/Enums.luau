--!strict
local State = table.freeze({
	Idle = "Idle",
	Startup = "Startup",
	Endlag = "Endlag",
	BlockStart = "BlockStart",
	Blocking = "Blocking",
	BlockRecovery = "BlockRecovery",
	Hitstun = "Hitstun",
	ParryStun = "ParryStun",
	GuardBreakStun = "GuardBreakStun",
	Dash = "Dash",
	DashEndlag = "DashEndlag",
	Rush = "Rush", -- rush moves (Feng Critical): charging forward with the hitbox live
	RushMiss = "RushMiss", -- rush ran out without connecting: momentum carry, no hitbox
	Barrage = "Barrage", -- barrage moves (Firecracker Critical): a burst of hits after startup
	Knocked = "Knocked", -- 0 HP: down (ragdolled), can't act or be hit, gets up after D.KNOCKED.duration (KnockService)
	Gripping = "Gripping", -- finishing a knocked fighter: rooted, killed at D.GRIP.at unless interrupted (KnockService)
	Cutscene = "Cutscene", -- in a cutscene (CutsceneService): rooted, can't act or be hit until it ends
	Dead = "Dead",
})

local Result = table.freeze({
	Hit = "Hit",
	Counter = "Counter",
	Clash = "Clash",
	Blocked = "Blocked",
	Parried = "Parried",
	GuardBreak = "GuardBreak",
	Strip = "Strip",
})

local Action = table.freeze({ M1 = "M1", M2 = "M2", R = "R" })

-- Stuns: cannot guard, and ending one starts the post-stun dash delay.
local STUNS = table.freeze({
	[State.Hitstun] = true,
	[State.ParryStun] = true,
	[State.GuardBreakStun] = true,
})

local GUARDING = table.freeze({
	[State.BlockStart] = true,
	[State.Blocking] = true,
	[State.BlockRecovery] = true,
})

return table.freeze({
	State = State,
	Result = Result,
	Action = Action,
	STUNS = STUNS,
	GUARDING = GUARDING,
})
