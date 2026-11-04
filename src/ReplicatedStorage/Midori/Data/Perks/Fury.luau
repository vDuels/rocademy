--!strict
-- Furious Feng style perk (user, 2026-11-03): landing a dash attack (the dash kick, KickCan) sets your left leg
-- on fire (Vfx.FuriousFengFire + a ghost of the leg) until one of your attacks misses (connects with nobody).
-- While lit: +20% anti-heal on every hit, every landed hit takes 1s off the dash cooldown and adds 1s of
-- Chambered Dash fill, no natural healing, and you burn 2 HP a second, all of it healable. The hit that lights
-- it gets no Fury refund (user). Logic: PerkBehaviours/Fury.
return {
	id = "Fury",
	name = "Fury",
	desc = "Landing a dash attack lights your leg until you miss: +20% anti-heal, landed hits refund 1s of dash, no natural healing, you burn 2 healable HP a second.",
	style = "FuriousFeng", -- style perk: always on for Furious Feng
	icon = 1, -- ponytail: borrowed (Fleet Foot's) until it has its own art in D.HUD_ATLAS
	color = Color3.fromRGB(130, 40, 220),
	behaviour = "Fury",
	proc = "Fury", -- lights the card when it ignites
	limb = "Left Leg",
	ghostColor = Color3.fromRGB(70, 0, 110), -- the KickUp's limbColor
	burn = 2, -- HP per second, all healable (user, 2026-11-03: was 1)
	mods = { antiHeal = 0.2, hitDashRefund = 1, noRegen = 1 }, -- on only while lit; noRegen: no natural healing (user, 2026-11-03)
}
