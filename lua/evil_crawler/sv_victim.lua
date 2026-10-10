-- What happens to the NPCs a crawler strikes. The strike doesn't kill: the
-- NPC is put away, frozen and hidden, and a ragdoll lies in for it, out cold.
-- Left long enough it comes to. Still held, it screams and fights the leg;
-- dropped, it gets back up and runs, unless it's missing a part, in which
-- case it lies where it's dropped and bleeds out. It dies once it's been
-- eaten enough, when its head goes, or when someone shoots the body.
EvilCrawler = EvilCrawler or {}
local Victim = EvilCrawler.Victim or {}
EvilCrawler.Victim = Victim

local cv_knockout = CreateConVar("evil_crawler_knockout", "12", FCVAR_ARCHIVE, "Seconds a struck NPC stays out cold, give or take a quarter")

local GETUP_TIME = 2 -- lies there this long after it's let go before getting up
local SETTLED = 60 -- and not until the body has stopped tumbling
local THRASH_FORCE = 450
local WOUND = { 0.08, 0.13 } -- share of max health each piece torn away costs
local FADING = 0.3 -- below this share of health, too far gone to scream
local BLEED = 0.02 -- share of max health lost a second once a part is gone

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

-- Moves a ragdoll's bones into the NPC's current pose, so the strike flows
-- straight into a limp body.
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

-- Knocks the NPC out cold and returns the ragdoll lying in for it, held by
-- `holder`, or nil if no ragdoll can be had.
function Victim.KnockOut(npc, holder)
	local rag = ents.Create("prop_ragdoll")
	if not IsValid(rag) then return end
	rag:SetModel(npc:GetModel())
	rag:SetPos(npc:GetPos())
	rag:SetAngles(npc:GetAngles())
	rag:SetSkin(npc:GetSkin())
	for _, group in ipairs(npc:GetBodyGroups()) do
		rag:SetBodygroup(group.id, npc:GetBodygroup(group.id))
	end
	rag:Spawn()
	rag:Activate()

	local ok, err = pcall(Pose, rag, npc)
	if not ok or rag:GetPhysicsObjectCount() == 0 then
		if not ok then ErrorNoHalt("[evil_crawler] couldn't pose body: " .. tostring(err) .. "\n") end
		rag:Remove()
		return
	end
	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)

	npc.EvilCrawlerVictim = true
	npc.EvilCrawlerBody = rag
	Hide(npc)

	local knockout = cv_knockout:GetFloat()
	rag.EvilCrawlerNPC = npc
	rag.EvilCrawlerHolder = holder
	rag.EvilCrawlerVoice = VoiceOf(npc, rag)
	rag.EvilCrawlerPitch = math.random(94, 106)
	rag.WakeAt = CurTime() + knockout * math.Rand(0.75, 1.25)
	Victim.bodies[rag] = true

	-- the blow knocks the cry clean out of them
	local cry = Say(rag, "pain", 80)
	if cry then
		timer.Simple(0.18, function()
			if IsValid(rag) then rag:StopSound(cry) end
		end)
	end
	return rag
end

function Victim.Alive(rag)
	return IsValid(rag) and IsValid(rag.EvilCrawlerNPC)
end

function Victim.Awake(rag)
	return Victim.Alive(rag) and rag.Awake == true
end

-- The body is just a body now.
function Victim.Kill(rag, attacker)
	local npc = rag.EvilCrawlerNPC
	if not IsValid(npc) then return end
	Victim.bodies[rag] = nil
	rag.EvilCrawlerNPC = nil

	if rag.Awake then Say(rag, "die", 75) end
	Thrash(rag, 1.5, 4)

	npc.EvilCrawlerBody = nil
	npc:SetHealth(0)
	hook.Run("OnNPCKilled", npc, attacker, attacker)
	npc:Remove()
end

-- Something hurt the body, or tore a piece off it.
function Victim.Hurt(rag, amount, attacker)
	local npc = rag.EvilCrawlerNPC
	if not IsValid(npc) then return end
	npc:SetHealth(npc:Health() - amount)
	if npc:Health() <= 0 then Victim.Kill(rag, attacker) end
end

function Victim.Wound(rag, attacker)
	local npc = rag.EvilCrawlerNPC
	if not IsValid(npc) then return end
	Victim.Hurt(rag, math.max(1, npc:GetMaxHealth()) * math.Rand(WOUND[1], WOUND[2]), attacker)
end

-- A leg drives into them. Nobody sleeps through that.
function Victim.Pierced(rag)
	local npc = rag.EvilCrawlerNPC
	if not IsValid(npc) then return end
	if not rag.Awake then
		rag.Awake = true
		rag.NextCry = CurTime() + 1
	end
	if npc:Health() / math.max(1, npc:GetMaxHealth()) > FADING then
		Say(rag, "pain", 95)
	elseif math.random() < 0.5 then
		Say(rag, "die", 65)
	end
	Thrash(rag, 1.2, 3)
end

-- A part of them has been eaten away. Without a head that's the end of it;
-- otherwise they won't be getting up again.
function Victim.Maimed(rag, bone, attacker)
	if not Victim.Alive(rag) then return end
	if bone == "ValveBiped.Bip01_Head1" then
		rag.Awake = false -- nothing left to cry out with
		Victim.Kill(rag, attacker)
		return
	end
	rag.Maimed = true
end

-- Somewhere the NPC fits standing up, near the body.
local function StandingSpot(npc, rag)
	local pos = rag:GetPos()
	local mins, maxs = npc:OBBMins(), npc:OBBMaxs()
	for _, offset in ipairs(STANDING_OFFSETS) do
		local from = pos + offset + Vector(0, 0, 8)
		local tr = util.TraceHull({
			start = from, endpos = from - Vector(0, 0, 96),
			mins = mins, maxs = maxs, mask = MASK_NPCSOLID, filter = { npc, rag },
		})
		if not tr.StartSolid then return tr.HitPos end
	end
	return pos
end

-- It gets up, worse for wear, and runs.
local function GetUp(rag, npc)
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
	rag.EvilCrawlerNPC = nil
	rag:Remove()
	npc:SetSchedule(SCHED_RUN_RANDOM)
end

local function Update(rag, now)
	local npc = rag.EvilCrawlerNPC
	if not IsValid(npc) then
		Victim.bodies[rag] = nil
		return
	end
	npc:SetPos(rag:GetPos())

	local holder = rag.EvilCrawlerHolder
	local held = IsValid(holder) and holder:GetVictim() == rag
	local eaten = held and holder:GetAct() == EvilCrawler.ACT_FEED
	if held then rag.LetGoAt = nil else rag.LetGoAt = rag.LetGoAt or now end

	if not rag.Awake then
		-- once it's started eating, the first stab wakes them instead
		if now < rag.WakeAt or eaten then return end
		rag.Awake = true
		rag.NextCry = now + math.Rand(1, 1.8)
		Say(rag, "wake")
		Thrash(rag, 1.6, 6)
	end

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
			if now >= (rag.NextThrash or 0) then
				local life = math.Clamp(npc:Health() / math.max(1, npc:GetMaxHealth()), 0.1, 1)
				rag.NextThrash = now + math.Rand(0.5, 1.5) / life
				Thrash(rag, life * 0.6, 1)
			end
			if now >= rag.NextCry then
				rag.NextCry = now + math.Rand(2.5, 5)
				Say(rag, "die", 70)
			end
			return
		end
		local root = rag:GetPhysicsObject()
		local still = not IsValid(root) or root:GetVelocity():Length() < SETTLED
		if still and now - rag.LetGoAt > GETUP_TIME then GetUp(rag, npc) end
		return
	end

	-- fights it, less and less as there's less of them
	local life = math.Clamp(npc:Health() / math.max(1, npc:GetMaxHealth()), 0.2, 1)
	if now >= (rag.NextThrash or 0) then
		rag.NextThrash = now + math.Rand(0.12, 0.4) / life
		Thrash(rag, life, math.random(1, 2))
	end
	-- while it's eating, the stabs do the screaming (Victim.Pierced)
	if not eaten and now >= rag.NextCry then
		rag.NextCry = now + math.Rand(1.8, 3.4)
		Say(rag, "help")
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

-- Cleaning up the body takes the NPC with it.
hook.Add("EntityRemoved", "EvilCrawlerVictims", function(ent)
	local npc = ent.EvilCrawlerNPC
	Victim.bodies[ent] = nil
	if IsValid(npc) then npc:Remove() end
end)
