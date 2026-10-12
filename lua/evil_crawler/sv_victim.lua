-- What happens to the NPCs a crawler grabs. The NPC is put away, frozen and
-- hidden, and a ragdoll lies in for it, wide awake. It fights the leg and
-- screams while small teeth along the coil work something into it, and over
-- a few seconds it goes under: thrashing, then whimpering, then asleep.
-- Dropped, it wears off; once it can, it gets back up and runs, unless it's
-- missing a part, in which case it lies where it's dropped and bleeds out. It
-- dies once it's been eaten enough, when its head goes, or when someone
-- shoots the body.
-- A player who couldn't fight their way out of the coil goes the same way,
-- already most of the way under. They watch the crawler from outside their
-- body (cl_struggle.lua) while it has them, and right to the end. If it ever
-- drops them, they watch the body instead, and get back up in it with what
-- they were carrying once they come round.
EvilCrawler = EvilCrawler or {}
local Victim = EvilCrawler.Victim or {}
EvilCrawler.Victim = Victim

local cv_sedate = CreateConVar("evil_crawler_sedate_time", "10", FCVAR_ARCHIVE, "Seconds a held NPC takes to go under")

local WEAR_OFF = 20 -- seconds for being fully under to wear off once it's let go
local GETUP_SEDATION = 0.35 -- gets up once it's worn off this far
local GETUP_TIME = 2 -- lies there at least this long after it's let go before getting up
local SETTLED = 60 -- and not until the body has stopped tumbling
local THRASH_FORCE = 450
local WOUND = { 0.08, 0.13 } -- share of max health each piece torn away costs
local FADING = 0.3 -- below this share of health, too far gone to scream
local CRY_FEAR = { radius = 900, time = 30 } -- NPCs this close to a cry are frightened this long
local STRIKE_FEAR = { radius = 600, time = 20 } -- and to the grab
local ESCAPE_FEAR = 90 -- an NPC that got away stays frightened this long
local BLEED = 0.02 -- share of max health lost a second once a part is gone
local TAKEN_SEDATION = 0.7 -- how far under a player is by the time they lose the fight

local NIP_SOUNDS = {
	"physics/flesh/flesh_impact_bullet2.wav",
	"physics/flesh/flesh_impact_bullet4.wav",
}

Victim.bodies = Victim.bodies or {} -- every ragdoll standing in for a live NPC

local LIMBS = {
	"ValveBiped.Bip01_L_Hand", "ValveBiped.Bip01_R_Hand", "ValveBiped.Bip01_L_Forearm",
	"ValveBiped.Bip01_R_Forearm", "ValveBiped.Bip01_L_Foot", "ValveBiped.Bip01_R_Foot",
	"ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_R_Calf", "ValveBiped.Bip01_Head1",
}
local STANDING_OFFSETS = {
	Vector(0, 0, 0), Vector(24, 0, 0), Vector(-24, 0, 0), Vector(0, 24, 0), Vector(0, -24, 0), Vector(0, 0, 24),
}

-- Voices: what they cry out when they come to, while they're carried, while
-- they're eaten, and at the end.
local function Numbered(path, from, to)
	local t = {}
	for i = from, to do t[#t + 1] = string.format(path, i) end
	return t
end

local function Citizen(who)
	local vo = "vo/npc/" .. who .. "/"
	return {
		wake = { vo .. "startle01.wav", vo .. "startle02.wav", vo .. "ohno.wav" },
		help = { vo .. "help01.wav", vo .. "help01.wav", vo .. "no01.wav", vo .. "no02.wav", vo .. "gethellout.wav" },
		pain = Numbered(vo .. "pain%02d.wav", 1, 9),
		die = Numbered(vo .. "moan%02d.wav", 1, 5),
	}
end

local MALE, FEMALE = Citizen("male01"), Citizen("female01")

local ZOMBIE = {
	wake = Numbered("npc/zombie/zombie_alert%d.wav", 1, 3),
	help = Numbered("npc/zombie/zombie_pain%d.wav", 1, 6),
	pain = Numbered("npc/zombie/zombie_pain%d.wav", 1, 6),
	die = Numbered("npc/zombie/zombie_die%d.wav", 1, 3),
}

local VOICES = {
	npc_barney = {
		wake = { "vo/npc/barney/ba_ohshit03.wav" },
		help = { "vo/npc/barney/ba_no01.wav", "vo/npc/barney/ba_no02.wav" },
		pain = Numbered("vo/npc/barney/ba_pain%02d.wav", 1, 10),
		die = { "vo/npc/barney/ba_pain06.wav" },
	},
	npc_alyx = {
		wake = { "vo/npc/alyx/ohno_startle01.wav", "vo/npc/alyx/ohno_startle03.wav" },
		help = { "vo/npc/alyx/no01.wav", "vo/npc/alyx/no02.wav", "vo/npc/alyx/no03.wav" },
		pain = { "vo/npc/alyx/hurt04.wav", "vo/npc/alyx/hurt05.wav", "vo/npc/alyx/hurt06.wav", "vo/npc/alyx/hurt08.wav" },
		die = { "vo/npc/alyx/gasp02.wav", "vo/npc/alyx/gasp03.wav" },
	},
	npc_kleiner = {
		wake = { "vo/k_lab/kl_dearme.wav", "vo/k_lab/kl_ohdear.wav" },
		help = { "vo/k_lab/kl_ahhhh.wav", "vo/k_lab/kl_fiddlesticks.wav" },
		pain = { "vo/k_lab/kl_ahhhh.wav" },
		die = { "vo/k_lab/kl_ahhhh.wav" },
	},
	npc_monk = {
		wake = Numbered("vo/ravenholm/monk_helpme%02d.wav", 1, 5),
		help = Numbered("vo/ravenholm/monk_helpme%02d.wav", 1, 5),
		pain = Numbered("vo/ravenholm/monk_pain%02d.wav", 1, 12),
		die = { "vo/ravenholm/monk_pain12.wav" },
	},
	npc_metropolice = {
		wake = { "npc/metropolice/vo/officerneedsassistance.wav" },
		help = { "npc/metropolice/vo/officerneedshelp.wav", "npc/metropolice/vo/officerneedsassistance.wav", "npc/metropolice/vo/help.wav" },
		pain = Numbered("npc/metropolice/pain%d.wav", 1, 4),
		die = Numbered("npc/metropolice/die%d.wav", 1, 4),
	},
	npc_combine_s = {
		wake = { "npc/combine_soldier/vo/on1.wav", "npc/combine_soldier/vo/on2.wav" },
		help = Numbered("npc/combine_soldier/pain%d.wav", 1, 3),
		pain = Numbered("npc/combine_soldier/pain%d.wav", 1, 3),
		die = Numbered("npc/combine_soldier/die%d.wav", 1, 3),
	},
	npc_zombie = ZOMBIE,
	npc_zombie_torso = ZOMBIE,
	npc_poisonzombie = ZOMBIE,
	npc_zombine = {
		wake = Numbered("npc/zombine/zombine_alert%d.wav", 1, 7),
		help = Numbered("npc/zombine/zombine_pain%d.wav", 1, 4),
		pain = Numbered("npc/zombine/zombine_pain%d.wav", 1, 4),
		die = Numbered("npc/zombine/zombine_die%d.wav", 1, 2),
	},
	npc_fastzombie = {
		wake = { "npc/fast_zombie/wake1.wav" },
		help = { "npc/fast_zombie/fz_scream1.wav", "npc/fast_zombie/fz_frenzy1.wav" },
		pain = { "npc/fast_zombie/fz_scream1.wav" },
		die = { "npc/fast_zombie/fz_alert_close1.wav" },
	},
}

-- Anything else with a human skeleton gets a citizen's voice; anything else
-- at all suffers quietly.
local function VoiceOf(npc, rag)
	local voice = VOICES[npc:GetClass()]
	if voice then return voice end
	if not rag:LookupBone("ValveBiped.Bip01_Head1") then return end
	local model = npc:GetModel():lower()
	if model:find("zombi") or model:find("vort") then return end
	for _, f in ipairs({ "female", "alyx", "mossman", "chell" }) do
		if model:find(f, 1, true) then return FEMALE end
	end
	return MALE
end

local function Say(rag, kind, level)
	local lines = rag.EvilCrawlerVoice and rag.EvilCrawlerVoice[kind]
	if not lines then return end
	local line = lines[math.random(#lines)]
	rag:EmitSound(line, level or 90, rag.EvilCrawlerPitch, 1, CHAN_VOICE)
	EvilCrawler.Scent.Frighten(rag:GetPos(), CRY_FEAR.radius, CRY_FEAR.time)
	return line
end

local function PhysOf(rag, bone)
	local b = rag:LookupBone(bone)
	local index = b and rag:TranslateBoneToPhysBone(b) or -1
	if index < 0 then index = math.random(0, rag:GetPhysicsObjectCount() - 1) end
	local phys = rag:GetPhysicsObjectNum(index)
	return IsValid(phys) and phys
end

local function Gone(rag, bone)
	local b = rag:LookupBone(bone)
	return b and rag:GetManipulateBoneScale(b).x == 0
end

local function Thrash(rag, strength, kicks)
	for _ = 1, kicks do
		local limb = LIMBS[math.random(#LIMBS)]
		local phys = not Gone(rag, limb) and PhysOf(rag, limb)
		if phys then phys:ApplyForceCenter(VectorRand() * phys:GetMass() * THRASH_FORCE * strength) end
	end
end

-- A few small teeth through the clothes. Too fine to draw blood.
local function Nip(rag)
	local phys = PhysOf(rag, LIMBS[math.random(#LIMBS)])
	if not phys then return end
	sound.Play(NIP_SOUNDS[math.random(#NIP_SOUNDS)], phys:GetPos(), 55, math.random(130, 160), 0.4)
end

-- The body doesn't bleed (onto the floor it's dragged across, say) until
-- the first stab opens it up.
function Victim.Opened(rag)
	if rag.EvilCrawlerOpened then return end
	rag.EvilCrawlerOpened = true
	rag:SetBloodColor(BLOOD_COLOR_RED)
end

-- Moves a ragdoll's bones into the NPC's current pose, so the grab flows
-- straight into the body in the leg's coil.
local function Pose(rag, npc)
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		local m = npc:GetBoneMatrix(rag:TranslatePhysBoneToBone(i))
		if IsValid(phys) and m then
			phys:SetPos(m:GetTranslation())
			phys:SetAngles(m:GetAngles())
			phys:Wake()
		end
	end
end

local function Hide(npc)
	npc.EvilCrawlerHadNoTarget = npc:IsFlagSet(FL_NOTARGET)
	npc:SetNoDraw(true)
	npc:DrawShadow(false)
	npc:SetNotSolid(true)
	npc:SetMoveType(MOVETYPE_NONE)
	npc:AddFlags(FL_NOTARGET)
	npc:AddEFlags(EFL_NO_THINK_FUNCTION)
	npc:ClearSchedule()
end

-- A ragdoll dressed and posed as `ent`, or nil if none can be had.
local function Body(ent)
	local rag = ents.Create("prop_ragdoll")
	if not IsValid(rag) then return end
	rag:SetModel(ent:GetModel())
	rag:SetPos(ent:GetPos())
	rag:SetAngles(ent:GetAngles())
	rag:SetSkin(ent:GetSkin())
	for _, group in ipairs(ent:GetBodyGroups()) do
		rag:SetBodygroup(group.id, ent:GetBodygroup(group.id))
	end
	rag:Spawn()
	rag:Activate()

	local ok, err = pcall(Pose, rag, ent)
	if not ok or rag:GetPhysicsObjectCount() == 0 then
		if not ok then ErrorNoHalt("[evil_crawler] couldn't pose body: " .. tostring(err) .. "\n") end
		rag:Remove()
		return
	end
	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	rag:SetBloodColor(DONT_BLEED) -- until Victim.Opened
	return rag
end

-- `ent` is in the body now, held by `holder`, `sedation` of the way under.
local function Hold(rag, ent, holder, sedation)
	ent.EvilCrawlerBody = rag
	rag.EvilCrawlerOwner = ent
	rag.EvilCrawlerHolder = holder
	rag.EvilCrawlerVoice = VoiceOf(ent, rag)
	rag.EvilCrawlerPitch = math.random(94, 106)
	rag.Sedation = sedation
	rag.NextCry = CurTime() + math.Rand(0.8, 1.4)
	Victim.bodies[rag] = true
	EvilCrawler.Scent.Frighten(rag:GetPos(), STRIKE_FEAR.radius, STRIKE_FEAR.time)
end

-- Takes the NPC in hand and returns the ragdoll lying in for it, held by
-- `holder`, or nil if no ragdoll can be had.
function Victim.Grab(npc, holder)
	local rag = Body(npc)
	if not rag then return end

	npc.EvilCrawlerVictim = true
	Hide(npc)
	Hold(rag, npc, holder, 0)

	Say(rag, "wake")
	Thrash(rag, 1.6, 6)
	return rag
end

-- A player who lost the fight in the coil. What they were carrying is put
-- by, and they watch their body from outside it.
function Victim.Take(ply, holder)
	local rag = Body(ply)
	if not rag then return end

	local active = ply:GetActiveWeapon()
	local kit = { armor = ply:Armor(), ammo = ply:GetAmmo(), weapons = {}, active = IsValid(active) and active:GetClass() }
	for _, wep in ipairs(ply:GetWeapons()) do
		kit.weapons[#kit.weapons + 1] = { class = wep:GetClass(), clip1 = wep:Clip1(), clip2 = wep:Clip2() }
	end
	ply.EvilCrawlerKit = kit
	ply:StripWeapons()
	ply:Spectate(OBS_MODE_CHASE)
	ply:SpectateEntity(IsValid(holder) and holder or rag)

	rag:SetNW2Entity(EvilCrawler.OWNER_VAR, ply)
	rag:SetNW2Vector(EvilCrawler.COLOR_VAR, ply:GetPlayerColor())
	Hold(rag, ply, holder, TAKEN_SEDATION)

	Say(rag, "pain", 80)
	Thrash(rag, 0.8, 4)
	return rag
end

function Victim.Alive(rag)
	return IsValid(rag) and IsValid(rag.EvilCrawlerOwner)
end

-- Still alive and not yet gone under.
function Victim.Fighting(rag)
	return Victim.Alive(rag) and rag.Sedation < 1
end

-- How much of them is still there to fight and cry out, 0..1.
local function Lucid(rag)
	return 1 - rag.Sedation
end

-- What a player in the body watches: whatever has hold of it, or the body
-- itself once it's dropped.
local function Watched(rag)
	local holder = rag.EvilCrawlerHolder
	if IsValid(holder) and holder:GetVictim() == rag then return holder end
	return rag
end

-- The body is just a body now.
function Victim.Kill(rag, attacker)
	local npc = rag.EvilCrawlerOwner
	if not IsValid(npc) then return end
	Victim.bodies[rag] = nil
	rag.EvilCrawlerOwner = nil

	if Lucid(rag) > 0.3 then Say(rag, "die", 75) end
	Thrash(rag, 1.5, 4)

	npc.EvilCrawlerBody = nil
	if npc:IsPlayer() then
		-- dead, and still watching what's left of them
		npc:KillSilent()
		npc:AddDeaths(1)
		hook.Run("PlayerDeath", npc, attacker, attacker)
		npc:Spectate(OBS_MODE_CHASE)
		npc:SpectateEntity(Watched(rag))
		return
	end
	npc:SetHealth(0)
	hook.Run("OnNPCKilled", npc, attacker, attacker)
	npc:Remove()
end

-- Something hurt the body, or tore a piece off it.
function Victim.Hurt(rag, amount, attacker)
	local npc = rag.EvilCrawlerOwner
	if not IsValid(npc) then return end
	npc:SetHealth(npc:Health() - amount)
	if npc:Health() <= 0 then Victim.Kill(rag, attacker) end
end

function Victim.Wound(rag, attacker)
	local npc = rag.EvilCrawlerOwner
	if not IsValid(npc) then return end
	Victim.Hurt(rag, math.max(1, npc:GetMaxHealth()) * math.Rand(WOUND[1], WOUND[2]), attacker)
end

-- A leg drives into them. Under, they barely stir; anyone still lucid
-- screams with every one.
function Victim.Pierced(rag)
	Victim.Opened(rag)
	local npc = rag.EvilCrawlerOwner
	if not IsValid(npc) then return end
	local lucid = Lucid(rag)
	if lucid <= 0 then
		Thrash(rag, 0.4, 1)
		if math.random() < 0.15 then Say(rag, "die", 55) end
		return
	end
	if npc:Health() / math.max(1, npc:GetMaxHealth()) > FADING then
		Say(rag, "pain", 95)
	elseif math.random() < 0.5 then
		Say(rag, "die", 65)
	end
	Thrash(rag, 1.2 * lucid, 3)
end

-- A part of them has been eaten away. Without a head that's the end of it;
-- otherwise they won't be getting up again.
function Victim.Maimed(rag, bone, attacker)
	if not Victim.Alive(rag) then return end
	if bone == "ValveBiped.Bip01_Head1" then
		rag.Sedation = 1 -- nothing left to cry out with
		Victim.Kill(rag, attacker)
		return
	end
	rag.Maimed = true
end

-- Somewhere the NPC or player fits standing up, near the body.
local function StandingSpot(npc, rag)
	local pos = rag:GetPos()
	local mins, maxs, mask = npc:OBBMins(), npc:OBBMaxs(), MASK_NPCSOLID
	if npc:IsPlayer() then
		mins, maxs = npc:GetHull()
		mask = MASK_PLAYERSOLID
	end
	for _, offset in ipairs(STANDING_OFFSETS) do
		local from = pos + offset + Vector(0, 0, 8)
		local tr = util.TraceHull({
			start = from, endpos = from - Vector(0, 0, 96),
			mins = mins, maxs = maxs, mask = mask, filter = { npc, rag },
		})
		if not tr.StartSolid then return tr.HitPos end
	end
	return pos
end

-- A player comes round and is back in their body, with everything they had
-- on them.
local function PlayerGetUp(rag, ply)
	Victim.bodies[rag] = nil
	rag.EvilCrawlerOwner = nil
	ply.EvilCrawlerBody = nil
	local spot, health, kit = StandingSpot(ply, rag), ply:Health(), ply.EvilCrawlerKit or {}
	ply.EvilCrawlerKit = nil

	ply.EvilCrawlerGettingUp = true
	ply:UnSpectate()
	ply:Spawn()
	ply.EvilCrawlerGettingUp = nil

	ply:SetPos(spot)
	ply:SetHealth(health)
	ply:SetArmor(kit.armor or 0)
	ply:StripWeapons()
	ply:RemoveAllAmmo()
	for _, w in ipairs(kit.weapons or {}) do
		local wep = ply:Give(w.class, true)
		if IsValid(wep) then
			wep:SetClip1(w.clip1)
			wep:SetClip2(w.clip2)
		end
	end
	for id, count in pairs(kit.ammo or {}) do ply:SetAmmo(count, id) end
	if kit.active then ply:SelectWeapon(kit.active) end
	ply.EvilCrawlerFearUntil = CurTime() + ESCAPE_FEAR
	rag:Remove()
end

-- It gets up, worse for wear, and runs.
local function GetUp(rag, npc)
	if npc:IsPlayer() then
		PlayerGetUp(rag, npc)
		return
	end
	Victim.bodies[rag] = nil
	npc:SetPos(StandingSpot(npc, rag))
	npc:SetAngles(Angle(0, math.Rand(0, 360), 0))
	npc:SetColor(rag:GetColor())
	npc:RemoveEFlags(EFL_NO_THINK_FUNCTION)
	npc:SetMoveType(MOVETYPE_STEP)
	npc:SetNotSolid(false)
	npc:SetNoDraw(false)
	npc:DrawShadow(true)
	if not npc.EvilCrawlerHadNoTarget then npc:RemoveFlags(FL_NOTARGET) end
	npc.EvilCrawlerVictim = nil
	npc.EvilCrawlerBody = nil
	npc.EvilCrawlerFearUntil = CurTime() + ESCAPE_FEAR
	rag.EvilCrawlerOwner = nil
	rag:Remove()
	npc:SetSchedule(SCHED_RUN_RANDOM)
end

local function Update(rag, now)
	local npc = rag.EvilCrawlerOwner
	if not IsValid(npc) then
		Victim.bodies[rag] = nil
		return
	end
	npc:SetPos(rag:GetPos())
	if npc:IsPlayer() then
		local watch = Watched(rag)
		if npc:GetObserverTarget() ~= watch then npc:SpectateEntity(watch) end
	end

	local holder = rag.EvilCrawlerHolder
	local held = IsValid(holder) and holder:GetVictim() == rag
	local eaten = held and holder:GetAct() == EvilCrawler.ACT_FEED
	if held then rag.LetGoAt = nil else rag.LetGoAt = rag.LetGoAt or now end

	-- held, the teeth keep it going under; let go, it wears off
	local dt = FrameTime()
	if held then
		rag.Sedation = math.min(1, rag.Sedation + dt / math.max(0.1, cv_sedate:GetFloat()))
	else
		rag.Sedation = math.max(0, rag.Sedation - dt / WEAR_OFF)
	end
	local lucid = Lucid(rag)

	if rag.Maimed then
		rag.Bled = (rag.Bled or 0) + FrameTime()
		if rag.Bled >= 0.5 then
			Victim.Hurt(rag, npc:GetMaxHealth() * BLEED * rag.Bled, game.GetWorld())
			rag.Bled = 0
			if not Victim.Alive(rag) then return end
		end
	end

	if not held then
		if rag.Maimed then
			-- can't get up like this: writhes where it lies, fainter and fainter
			if lucid < 0.15 then return end
			if now >= (rag.NextThrash or 0) then
				local life = math.Clamp(npc:Health() / math.max(1, npc:GetMaxHealth()), 0.1, 1)
				rag.NextThrash = now + math.Rand(0.5, 1.5) / (life * lucid)
				Thrash(rag, life * lucid * 0.6, 1)
			end
			if now >= rag.NextCry then
				rag.NextCry = now + math.Rand(2.5, 5)
				Say(rag, "die", 70)
			end
			return
		end
		local root = rag:GetPhysicsObject()
		local still = not IsValid(root) or root:GetVelocity():Length() < SETTLED
		if still and rag.Sedation < GETUP_SEDATION and now - rag.LetGoAt > GETUP_TIME then GetUp(rag, npc) end
		return
	end

	-- the teeth: small bites wherever they can get through
	if lucid > 0 and now >= (rag.NextNip or 0) then
		rag.NextNip = now + math.Rand(0.5, 1.1)
		Nip(rag)
	end

	-- fights it, less and less as it goes under and as there's less of them
	if lucid < 0.15 then return end
	local life = math.Clamp(npc:Health() / math.max(1, npc:GetMaxHealth()), 0.2, 1)
	if now >= (rag.NextThrash or 0) then
		rag.NextThrash = now + math.Rand(0.12, 0.4) / (life * lucid)
		Thrash(rag, life * lucid, math.random(1, 2))
	end
	-- while it's eating, the stabs do the screaming (Victim.Pierced)
	if not eaten and now >= rag.NextCry then
		rag.NextCry = now + math.Rand(1.8, 3.4) * (1 + 1.5 * rag.Sedation)
		if lucid > 0.6 then
			Say(rag, "help")
		elseif lucid > 0.3 then
			Say(rag, "pain", 78)
		else
			Say(rag, "die", 62)
		end
	end
end

hook.Add("Think", "EvilCrawlerVictims", function()
	local now = CurTime()
	for rag in pairs(Victim.bodies) do
		if IsValid(rag) then Update(rag, now) else Victim.bodies[rag] = nil end
	end
end)

-- Shooting the body hurts whoever's in it. The hidden NPC itself can't be hurt.
hook.Add("EntityTakeDamage", "EvilCrawlerVictims", function(ent, dmg)
	if ent.EvilCrawlerBody then return true end
	if not Victim.Alive(ent) or dmg:IsDamageType(DMG_CRUSH) then return end
	local attacker = dmg:GetAttacker()
	if IsValid(attacker) and (attacker:IsPlayer() or attacker:IsNPC()) then
		Victim.Hurt(ent, dmg:GetDamage(), attacker)
	end
end)

-- Cleaning up the body takes the NPC with it, or kills the player in it.
hook.Add("EntityRemoved", "EvilCrawlerVictims", function(ent)
	local owner = ent.EvilCrawlerOwner
	Victim.bodies[ent] = nil
	if not IsValid(owner) then return end
	owner.EvilCrawlerBody = nil
	if not owner:IsPlayer() then
		owner:Remove()
	elseif owner:Alive() then
		owner:KillSilent()
	end
end)

-- A player in a body who dies or respawns some other way leaves it behind as
-- just a body.
local function Disown(ply)
	local rag = ply.EvilCrawlerBody
	ply.EvilCrawlerBody = nil
	if IsValid(rag) then
		rag.EvilCrawlerOwner = nil
		Victim.bodies[rag] = nil
	end
end
hook.Add("PostPlayerDeath", "EvilCrawlerVictims", Disown)
hook.Add("PlayerSpawn", "EvilCrawlerVictims", function(ply)
	if ply.EvilCrawlerGettingUp then return end
	Disown(ply)
	-- respawned out of a strike or a coil: whatever had them lets go
	for _, crawler in ipairs(ents.FindByClass("evil_crawler")) do
		if crawler:GetVictim() == ply then crawler:Release() end
	end
	ply.EvilCrawlerVictim = nil
end)
