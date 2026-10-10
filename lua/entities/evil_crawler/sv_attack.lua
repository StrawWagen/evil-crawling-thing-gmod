-- How it kills: one leg rears back and whips into an NPC hard enough to
-- drop it dead on the spot, and coils round the body as it falls. Then it
-- drags the body somewhere out of sight and feeds on it with the small mouths
-- along its legs. Players are never attacked.

local ACT_NONE, ACT_STRIKE, ACT_DRAG, ACT_FEED =
	EvilCrawler.ACT_NONE, EvilCrawler.ACT_STRIKE, EvilCrawler.ACT_DRAG, EvilCrawler.ACT_FEED
local IMPACT_TIME = EvilCrawler.STRIKE_WINDUP + EvilCrawler.STRIKE_LUNGE

local ATTACK_REACH = 140
local MISS_REACH = ATTACK_REACH * 1.5 -- got this far away during the windup: the strike misses
local KNOCK = 350 -- how hard the strike throws the body
local YANK_TIME = 0.5 -- the body flies loose this long before the leg reels it in
local DRAG_TIME = 15 -- gives up looking for somewhere private after this long and eats where it is
local FEED_TIME = 15
local SATED_TIME = 90
local LAIR_TRIES = 12
local DISTURB_RANGE = 330

local WINDUP_SOUNDS = { "npc/barnacle/barnacle_tongue_pull1.wav", "npc/barnacle/barnacle_tongue_pull2.wav" }
local LUNGE_SOUND = "npc/zombie/claw_miss1.wav"
local HIT_SOUNDS = {
	"physics/body/body_medium_impact_hard1.wav",
	"physics/body/body_medium_impact_hard4.wav",
	"physics/body/body_medium_impact_hard6.wav",
}
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

function ENT:StartStrike(npc)
	npc.EvilCrawlerVictim = self
	sound.Play(WINDUP_SOUNDS[math.random(#WINDUP_SOUNDS)], self:GetPos(), 60, math.random(70, 85), 0.7)

	self:SetPrey(NULL)
	self:SetVictim(npc)
	self:SetAct(ACT_STRIKE)
	self:SetActStart(CurTime())
	self:SetState("strike")
	self.Lunged = false
end

-- Ends whatever it's doing. A victim that dodged the strike is fair game
-- again; a corpse is left where it lies.
function ENT:Release()
	local victim = self:GetVictim()
	if IsValid(victim) and victim:IsNPC() and victim.EvilCrawlerVictim == self then
		victim.EvilCrawlerVictim = nil
	end
	self:SetVictim(NULL)
	self:SetAct(ACT_NONE)
	self.Lair = nil
end

-- Moves a ragdoll's bones into the NPC's current pose, so the kill flows
-- straight into a limp body.
local function PoseCorpse(rag, npc)
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
end

-- A ragdoll standing in for the NPC, or nil if that can't be done.
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

	local ok, err = pcall(PoseCorpse, rag, npc)
	if not ok or rag:GetPhysicsObjectCount() == 0 then
		if not ok then ErrorNoHalt("[evil_crawler] couldn't pose corpse: " .. tostring(err) .. "\n") end
		rag:Remove()
		return
	end

	rag:SetCollisionGroup(COLLISION_GROUP_WEAPON)
	return rag
end

local function Chest(corpse)
	local bone = corpse:LookupBone("ValveBiped.Bip01_Spine2")
	local index = bone and corpse:TranslateBoneToPhysBone(bone) or 0
	return corpse:GetPhysicsObjectNum(index >= 0 and index or 0)
end

-- The leg lands: the NPC drops as a corpse thrown along the blow, already
-- caught in the leg's coil.
function ENT:Strike(npc)
	local now = CurTime()
	local center = npc:WorldSpaceCenter()
	local dir = (center - self:GetPos()):GetNormalized()

	sound.Play(HIT_SOUNDS[math.random(#HIT_SOUNDS)], center, 85, math.random(80, 95))
	sound.Play(SNAP_SOUNDS[math.random(#SNAP_SOUNDS)], npc:EyePos(), 80, math.random(90, 105))
	local fx = EffectData()
	fx:SetOrigin(center)
	fx:SetNormal(-dir)
	util.Effect("BloodImpact", fx)
	util.Decal("Blood", center, center + dir * 160, npc)

	if npc.DropWeapon and IsValid(npc:GetActiveWeapon()) then npc:DropWeapon() end

	local corpse = MakeCorpse(npc)
	if not IsValid(corpse) then
		-- no ragdoll to be had: kill it outright and leave it
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

	local knock = dir * KNOCK + vector_up * 120
	for i = 0, corpse:GetPhysicsObjectCount() - 1 do
		local phys = corpse:GetPhysicsObjectNum(i)
		if IsValid(phys) then phys:SetVelocity(knock) end
	end

	hook.Run("OnNPCKilled", npc, self, self)
	npc.EvilCrawlerVictim = nil
	npc:Remove()

	self:SetVictim(corpse)
	self.StruckAt = now
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
-- With a loose grip it keeps more of its own momentum.
function ENT:HoldCorpse(corpse, stiffness, grip)
	local phys = Chest(corpse)
	if not IsValid(phys) then return end
	local hold = self:GetPos() - self.BodyUp * (self.BodyHeight * 0.55)
	local p = phys:GetPos()
	if p:Distance(hold) > 600 then
		self:Release() -- snagged on something; leave it
		return
	end
	phys:SetVelocity(LerpVector(0.5 * grip, phys:GetVelocity(), (hold - p) * stiffness + self.Vel))
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
	if act == ACT_STRIKE then
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

-- Every tick: time the strike, or keep the body in hand.
function ENT:UpdateAct(now)
	local act = self:GetAct()
	if act == ACT_NONE then return end

	local victim = self:GetVictim()
	if not IsValid(victim) then
		self:Release()
		return
	end

	if act == ACT_STRIKE then
		if victim:Health() <= 0 then
			self:Release() -- something else killed it first
			return
		end
		local t = now - self:GetActStart()
		if not self.Lunged and t >= EvilCrawler.STRIKE_WINDUP then
			self.Lunged = true
			sound.Play(LUNGE_SOUND, self:GetPos(), 75, math.random(60, 75))
		end
		if t >= IMPACT_TIME then
			if victim:WorldSpaceCenter():Distance(self:GetPos()) < MISS_REACH then
				self:Strike(victim)
			else
				self:Release()
			end
		end
	else
		local grip = math.Clamp((now - (self.StruckAt or 0)) / YANK_TIME, 0.05, 1)
		self:HoldCorpse(victim, act == ACT_FEED and 4 or 8, grip * grip)
		if self:GetAct() == ACT_FEED and now >= (self.NextBite or 0) then self:Bite(victim) end
	end
end

function ENT:OnRemove()
	self:Release()
end
