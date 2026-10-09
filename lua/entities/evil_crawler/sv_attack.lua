-- How it kills: wraps its legs around an NPC like a constrictor, squeezes
-- until the neck snaps, then drags the body somewhere out of sight and feeds
-- on it with the small mouths along its legs. Players are never attacked.

local ACT_NONE, ACT_CONSTRICT, ACT_DRAG, ACT_FEED =
	EvilCrawler.ACT_NONE, EvilCrawler.ACT_CONSTRICT, EvilCrawler.ACT_DRAG, EvilCrawler.ACT_FEED
local WRAP_TIME, SNAP_TIME = EvilCrawler.WRAP_TIME, EvilCrawler.SNAP_TIME

local ATTACK_REACH = 110
local DRAG_TIME = 15 -- gives up looking for somewhere private after this long and eats where it is
local FEED_TIME = 15
local SATED_TIME = 90
local LAIR_TRIES = 12
local DISTURB_RANGE = 330

local GRAB_SOUND = "physics/flesh/flesh_squishy_impact_hard2.wav"
local SNAP_SOUNDS = { "npc/barnacle/neck_snap1.wav", "npc/barnacle/neck_snap2.wav" }
local FEED_SOUNDS = {
	"npc/barnacle/barnacle_crunch2.wav",
	"npc/barnacle/barnacle_crunch3.wav",
	"physics/flesh/flesh_squishy_impact_hard1.wav",
	"physics/flesh/flesh_squishy_impact_hard3.wav",
	"physics/flesh/flesh_squishy_impact_hard4.wav",
}
local SIDES = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0) }

-- Walking NPCs roughly human sized: big enough to wrap, small enough to hold.
function ENT:IsEdible(ent)
	if not ent:IsNPC() or ent:Health() <= 0 or ent.EvilCrawlerVictim then return false end
	if ent:GetMoveType() ~= MOVETYPE_STEP then return false end
	local size = ent:OBBMaxs() - ent:OBBMins()
	return size.z >= 30 and size.z <= 100 and math.max(size.x, size.y) <= 60
end

function ENT:IsHungry()
	return CurTime() >= (self.SatedUntil or 0)
end

function ENT:CanAttack(ent)
	return self:IsHungry() and self:IsEdible(ent)
		and ent:WorldSpaceCenter():Distance(self:GetPos()) < ATTACK_REACH
end

function ENT:StartConstrict(npc)
	npc.EvilCrawlerVictim = self
	npc.EvilCrawlerAngles = npc:GetAngles()
	npc:SetSchedule(SCHED_NPC_FREEZE)
	sound.Play(GRAB_SOUND, npc:WorldSpaceCenter(), 70, math.random(80, 95))

	self:SetPrey(NULL)
	self:SetVictim(npc)
	self:SetAct(ACT_CONSTRICT)
	self:SetActStart(CurTime())
	self:SetState("constrict")
end

-- Ends whatever it's doing. A victim still alive is let go; a corpse is left
-- where it lies.
function ENT:Release()
	local victim = self:GetVictim()
	if IsValid(victim) and victim:IsNPC() and victim.EvilCrawlerVictim == self then
		victim.EvilCrawlerVictim = nil
		if victim:Health() > 0 then victim:SetSchedule(SCHED_IDLE_STAND) end
	end
	self:SetVictim(NULL)
	self:SetAct(ACT_NONE)
	self.Lair = nil
end

-- A ragdoll of the NPC in exactly its current pose, so the kill flows
-- straight into a limp body. Nil if the model has no ragdoll.
local function MakeCorpse(npc)
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

	if rag:GetPhysicsObjectCount() == 0 then
		rag:Remove()
		return
	end

	npc:SetupBones()
	for i = 0, rag:GetPhysicsObjectCount() - 1 do
		local phys = rag:GetPhysicsObjectNum(i)
		local m = npc:GetBoneMatrix(rag:TranslatePhysBoneToBone(i))
		if IsValid(phys) and m then
			phys:SetPos(m:GetTranslation())
			phys:SetAngles(m:GetAngles())
			phys:Wake()
		end
	end

	-- wrench the head round past where a neck allows
	local head = rag:LookupBone("ValveBiped.Bip01_Head1")
	local phys = head and rag:GetPhysicsObjectNum(rag:TranslateBoneToPhysBone(head))
	if IsValid(phys) then phys:AddAngleVelocity(Vector(0, 0, 2000)) end

	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	return rag
end

local function Chest(corpse)
	local bone = corpse:LookupBone("ValveBiped.Bip01_Spine2")
	local index = bone and corpse:TranslateBoneToPhysBone(bone) or 0
	return corpse:GetPhysicsObjectNum(index >= 0 and index or 0)
end

function ENT:Snap(npc)
	local now = CurTime()
	sound.Play(SNAP_SOUNDS[math.random(#SNAP_SOUNDS)], npc:EyePos(), 80, math.random(90, 105))
	if npc.DropWeapon and IsValid(npc:GetActiveWeapon()) then npc:DropWeapon() end

	local corpse = MakeCorpse(npc)
	if not IsValid(corpse) then
		-- no ragdoll for this model: kill it outright and leave it
		local dmg = DamageInfo()
		dmg:SetDamage(npc:Health() + 1000)
		dmg:SetDamageType(DMG_CRUSH)
		dmg:SetAttacker(self)
		dmg:SetInflictor(self)
		npc:TakeDamageInfo(dmg)
		self:Release()
		self.SatedUntil = now + SATED_TIME
		return
	end

	hook.Run("OnNPCKilled", npc, self, self)
	npc.EvilCrawlerVictim = nil
	npc:Remove()

	self:SetVictim(corpse)
	self:StartDrag(now)
end

function ENT:StartDrag(now)
	self:SetAct(ACT_DRAG)
	self:SetActStart(now)
	self:SetState("drag")
	self.Lair = self:FindLair()
	self.ActDeadline = now + DRAG_TIME
end

local function NearestPlayer(spot)
	local nearest = math.huge
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() then nearest = math.min(nearest, ply:GetPos():Distance(spot)) end
	end
	return nearest
end

-- Somewhere private to eat: far from every player, ideally with a roof
-- overhead and walls close around.
function ENT:FindLair()
	local pos = self:GetPos()
	local best, bestScore = pos, -math.huge
	for _ = 1, LAIR_TRIES do
		local dir = VectorRand()
		dir.z = dir.z * 0.3
		dir:Normalize()
		local tr = self:Trace(pos, pos + dir * math.Rand(500, 1500))
		local spot = tr.HitPos - dir * 32

		local score = math.min(NearestPlayer(spot), 3000)
		if self:Trace(spot, spot + Vector(0, 0, 400)).Hit then score = score + 600 end
		for _, side in ipairs(SIDES) do
			if self:Trace(spot, spot + side * 200).Hit then score = score + 150 end
		end
		if score > bestScore then best, bestScore = spot, score end
	end
	return best
end

function ENT:Disturbed()
	local pos = self:GetPos()
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() and ply:GetObserverMode() == OBS_MODE_NONE
			and ply:WorldSpaceCenter():Distance(pos) < DISTURB_RANGE then
			return true
		end
	end
	return false
end

-- The body hangs by its chest from beneath the legs, wherever it crawls.
function ENT:HoldCorpse(corpse, stiffness)
	local phys = Chest(corpse)
	if not IsValid(phys) then return end
	local hold = self:GetPos() - self.BodyUp * (self.BodyHeight * 0.55)
	local p = phys:GetPos()
	if p:Distance(hold) > 600 then
		self:Release() -- snagged on something; leave it
		return
	end
	phys:SetVelocity(LerpVector(0.5, phys:GetVelocity(), (hold - p) * stiffness + self.Vel))
end

function ENT:Bite(corpse)
	self.NextBite = CurTime() + math.Rand(0.3, 0.9)
	local phys = corpse:GetPhysicsObjectNum(math.random(0, corpse:GetPhysicsObjectCount() - 1))
	if not IsValid(phys) then return end

	local p = phys:GetPos()
	phys:ApplyForceCenter(VectorRand() * phys:GetMass() * 250)

	local fx = EffectData()
	fx:SetOrigin(p)
	fx:SetNormal(VectorRand())
	util.Effect("BloodImpact", fx)
	util.Decal("Blood", p, p + VectorRand() * 96, corpse)
	sound.Play(FEED_SOUNDS[math.random(#FEED_SOUNDS)], p, 65, math.random(90, 115), 0.6)
end

-- Brain side: where to go during each act, and when to move on.
function ENT:PonderAct(now)
	local act = self:GetAct()
	if act == ACT_CONSTRICT then
		self.Goal = nil
	elseif act == ACT_DRAG then
		self.Goal = self.Lair
		if self:Reached(self.Lair) or now > self.ActDeadline then
			self:SetAct(ACT_FEED)
			self:SetActStart(now)
			self:SetState("feed")
			self.FeedUntil = now + FEED_TIME
		end
	elseif act == ACT_FEED then
		self.Goal = nil
		if self:Disturbed() then
			self:StartDrag(now) -- someone came close: take it somewhere else
		elseif now > self.FeedUntil then
			self.SatedUntil = now + SATED_TIME
			self:Release()
		end
	end
end

-- Every tick: keep the victim pinned, or the body in hand.
function ENT:UpdateAct(now)
	local act = self:GetAct()
	if act == ACT_NONE then return end

	local victim = self:GetVictim()
	if not IsValid(victim) then
		self:Release()
		return
	end

	if act == ACT_CONSTRICT then
		if victim:Health() <= 0 then
			self:Release() -- something else killed it first
			return
		end
		if not victim:IsCurrentSchedule(SCHED_NPC_FREEZE) then victim:SetSchedule(SCHED_NPC_FREEZE) end
		local t = now - self:GetActStart()
		local squeeze = math.Clamp((t - WRAP_TIME) / (SNAP_TIME - WRAP_TIME), 0, 1)
		victim:SetAngles(victim.EvilCrawlerAngles + Angle(0, math.sin(now * 23) * 8 * squeeze, 0))
		if t >= SNAP_TIME then self:Snap(victim) end
	else
		self:HoldCorpse(victim, act == ACT_FEED and 4 or 8)
		if self:GetAct() == ACT_FEED and now >= (self.NextBite or 0) then self:Bite(victim) end
	end
end

function ENT:OnRemove()
	self:Release()
end
