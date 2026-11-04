--!strict
-- Feng style perk. While your dash is off cooldown a chamber fills over `fillTime`; when it
-- is full you hold one extra dash. Dashing uses your normal dash first (it goes on cooldown
-- as usual), so the chambered dash can be burned right after. The chamber stops filling
-- while the dash is on cooldown and keeps its progress.
return {
	id = "ChamberedDash",
	name = "Chambered Dash",
	style = "Feng", -- style perk: only Feng can have it (nil = any style)
	behaviour = "ChamberedDash", -- ServerScriptService/Midori/PerkBehaviours/<behaviour>
	fillTime = 4.6, -- seconds of dash-off-cooldown time to fill the chamber (user, 2026-11-03: was 5; 2026-10-06: was 3)
	charges = 1, -- extra dashes a full chamber holds
}
