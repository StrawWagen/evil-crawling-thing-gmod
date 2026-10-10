-- How it feeds: one leg rears back and whips into an NPC hard enough to
-- knock it senseless, and coils round the body as it falls. It eats them
-- alive (sv_victim.lua keeps them that way). That leg is done walking until it
-- lets go: it drags the body somewhere out of sight, hauls it up into the
-- tangle the legs grow from, and holds it there, turning it over, while other
-- legs stab into it and tear pieces away for the small mouths along them to
-- swallow. Too long finding somewhere quiet and they come to on the way.
-- Players are never attacked.

local Victim = EvilCrawler.Victim
local ACT_NONE, ACT_STRIKE, ACT_DRAG, ACT_FEED =
	EvilCrawler.ACT_NONE, EvilCrawler.ACT_STRIKE, EvilCrawler.ACT_DRAG, EvilCrawler.ACT_FEED
local IMPACT_TIME = EvilCrawler.STRIKE_WINDUP + EvilCrawler.STRIKE_LUNGE

local ATTACK_REACH = 140
local MISS_REACH = ATTACK_REACH * 1.5 -- got this far away during the windup: the strike misses
local KNOCK = 350 -- how hard the strike throws the body
local YANK_TIME = 0.5 -- the body flies loose this long before the leg reels it in
local PULL_TIME = EvilCrawler.PULL_TIME
local TRAIL_RATE = 1.5 -- how fast a carried body swings round behind it
local FEEDERS = EvilCrawler.FEEDERS
local BITE_IN, BITE_RIP = EvilCrawler.BITE_IN, EvilCrawler.BITE_RIP
local BiteCycle, BiteBone = EvilCrawler.BiteCycle, EvilCrawler.BiteBone
local STAB_FORCE = 120
local RIP_FORCE = 350
local DRAINED = 30 -- rips until the body is as dark as it gets
local TURN_SPEED = 35 -- degrees a second it turns the body over while eating
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
local STAB_SOUNDS = {
	"physics/flesh/flesh_impact_bullet1.wav",
	"physics/flesh/flesh_impact_bullet3.wav",
	"physics/flesh/flesh_impact_bullet5.wav",
}
local CRUNCH_SOUNDS = { "npc/barnacle/barnacle_crunch2.wav", "npc/barnacle/barnacle_crunch3.wav" }
local RIP_SOUNDS = {
	"physics/flesh/flesh_bloody_break.wav",
	"physics/flesh/flesh_squishy_impact_hard1.wav",
	"physics/flesh/flesh_squishy_impact_hard3.wav",
	"physics/flesh/flesh_squishy_impact_hard4.wav",
}
local GULP_SOUNDS = { "npc/barnacle/barnacle_gulp1.wav", "npc/barnacle/barnacle_gulp2.wav" }
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
-- again; a body is let go, to get up later if there's anything left of it.
function ENT:Release()
	local victim = self:GetVictim()
	if IsValid(victim) and victim:IsNPC() and victim.EvilCrawlerVictim == self then
		victim.EvilCrawlerVictim = nil
	end
	self:SetVictim(NULL)
	self:SetAct(ACT_NONE)
	self.Lair = nil
	self.CarryDir = nil
	self.BiteStage = nil
end

local function Smooth(t)
	return t * t * (3 - 2 * t)
end

local function Chest(corpse)
	local bone = corpse:LookupBone("ValveBiped.Bip01_Spine2")
	local index = bone and corpse:TranslateBoneToPhysBone(bone) or 0
	return corpse:GetPhysicsObjectNum(index >= 0 and index or 0)
end

-- The leg lands: the NPC drops senseless, thrown along the blow, already
-- caught in the leg's coil.
function ENT:Strike(npc)
	local now = CurTime()
	local center = npc:WorldSpaceCenter()
	local dir = (center - self:GetPos()):GetNormalized()

	sound.Play(HIT_SOUNDS[math.random(#HIT_SOUNDS)], center, 85, math.random(80, 95))
	local fx = EffectData()
	fx:SetOrigin(center)
	fx:SetNormal(-dir)
	util.Effect("BloodImpact", fx)
	util.Decal("Blood", center, center + dir * 160, npc)

	if npc.DropWeapon and IsValid(npc:GetActiveWeapon()) then npc:DropWeapon() end

	local corpse = Victim.KnockOut(npc, self)
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

	self:SetVictim(corpse)
	self.StruckAt = now
	self.CarryDir = dir
	self.Eaten = 0
	self:StartDrag(now)
end

function ENT:StartDrag(now)
	self:SetAct(ACT_DRAG)
	self:SetActStart(now)
	self:SetState("drag")
	self.Lair = self:FindLair()
	self.ActDeadline = now + DRAG_TIME
	self.BiteStage = nil
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

-- How far into the haul up into the tangle, 0..1. Reeled in by jerks.
function ENT:Pull(now)
	if self:GetAct() ~= ACT_FEED then return 0 end
	local t = now - self:GetActStart()
	return math.Clamp((t + 0.06 * math.sin(t * 12)) / PULL_TIME, 0, 1)
end

-- Where the holding leg keeps the body: carried low at the leg's length,
-- swinging round to trail behind as it crawls, and hauled up into the tangle
-- once it's somewhere quiet.
function ENT:HoldPoint(now, dt)
	local pos, up, h = self:GetPos(), self.BodyUp, self.BodyHeight
	local dir = self.CarryDir or -self.Facing
	if self.Vel:LengthSqr() > 400 then
		dir = LerpVector(1 - math.exp(-dt * TRAIL_RATE), dir, -self.Facing)
	end
	dir = dir - up * dir:Dot(up)
	if dir:LengthSqr() < 1e-4 then dir = -self.Facing end
	dir:Normalize()
	self.CarryDir = dir

	local carry = pos - up * (h * 0.6) + dir * (h * 1.1)
	return LerpVector(Smooth(self:Pull(now)), carry, pos)
end

-- The body hangs from the holding leg by its chest. With a loose grip it
-- keeps more of its own momentum.
function ENT:HoldCorpse(corpse, hold, stiffness, grip)
	local phys = Chest(corpse)
	if not IsValid(phys) then return end
	local p = phys:GetPos()
	if p:Distance(hold) > 600 then
		self:Release() -- snagged on something; leave it
		return
	end
	phys:SetVelocity(LerpVector(0.5 * grip, phys:GetVelocity(), (hold - p) * stiffness + self.Vel))
end

local function BitePhys(corpse, name)
	local bone = corpse:LookupBone(name)
	local index = bone and corpse:TranslateBoneToPhysBone(bone) or -1
	if index < 0 then index = math.random(0, corpse:GetPhysicsObjectCount() - 1) end
	local phys = corpse:GetPhysicsObjectNum(index)
	return IsValid(phys) and phys
end

-- A leg drives into the body from above.
function ENT:Stab(phys)
	local p, up = phys:GetPos(), self.BodyUp
	phys:ApplyForceCenter(-up * phys:GetMass() * STAB_FORCE)

	local fx = EffectData()
	fx:SetOrigin(p)
	fx:SetNormal(up)
	util.Effect("BloodImpact", fx)
	util.Decal("Blood", p + up * 24, p - up * 24, self)
	sound.Play(STAB_SOUNDS[math.random(#STAB_SOUNDS)], p, 70, math.random(80, 100), 0.8)
	if math.random() < 0.5 then
		sound.Play(CRUNCH_SOUNDS[math.random(#CRUNCH_SOUNDS)], p, 65, math.random(85, 110), 0.6)
	end
end

-- It tears back out with a piece, jerking the limb after it. A moment later
-- the piece reaches the tangle and goes down.
function ENT:Rip(phys, corpse)
	local p, up = phys:GetPos(), self.BodyUp
	local dir = (up + VectorRand() * 0.5):GetNormalized()
	phys:ApplyForceCenter(dir * phys:GetMass() * RIP_FORCE)

	local fx = EffectData()
	fx:SetOrigin(p)
	fx:SetNormal(dir)
	fx:SetScale(6)
	fx:SetColor(BLOOD_COLOR_RED)
	fx:SetFlags(3)
	util.Effect("bloodspray", fx)
	util.Effect("BloodImpact", fx)
	util.Decal("Blood", p, p - up * 200 + VectorRand() * 40, corpse)
	sound.Play(RIP_SOUNDS[math.random(#RIP_SOUNDS)], p, 72, math.random(85, 110), 0.8)

	Victim.Wound(corpse, self)
	self.Eaten = (self.Eaten or 0) + 1
	local k = math.min(1, self.Eaten / DRAINED)
	corpse:SetColor(Color(255 - 150 * k, 255 - 205 * k, 255 - 205 * k))

	timer.Simple(EvilCrawler.LUMP_TIME, function()
		if IsValid(self) then
			sound.Play(GULP_SOUNDS[math.random(#GULP_SOUNDS)], self:GetPos(), 60, math.random(70, 90), 0.6)
		end
	end)
end

-- Once the body is hauled in: runs the bite schedule each feeding leg is
-- drawn following, and slowly turns the body over to get at all of it.
function ENT:Feed(corpse, now)
	local t = now - self:GetActStart() - PULL_TIME
	if t < 0 then return end

	local seed = self:GetSeed()
	self.BiteStage = self.BiteStage or {}
	for k = 1, FEEDERS do
		local n, u = BiteCycle(k, t)
		local stage = n * 3 + (u < BITE_IN and 0 or u < BITE_RIP and 1 or 2)
		local last = self.BiteStage[k]
		self.BiteStage[k] = stage
		if last and stage ~= last and stage % 3 ~= 0 then
			local phys = BitePhys(corpse, BiteBone(seed, k, n))
			if phys then
				if stage % 3 == 1 then
					self:Stab(phys)
					Victim.Pierced(corpse)
				else
					self:Rip(phys, corpse)
				end
			end
		end
	end

	local chest = Chest(corpse)
	if IsValid(chest) then
		local want = chest:WorldToLocalVector(self.BodyUp) * (TURN_SPEED * math.sin(t * 0.35 + seed % 7))
		chest:AddAngleVelocity((want - chest:GetAngleVelocity()) * 0.05)
	end
end

-- Brain side: where to go during each act, and when to move on.
function ENT:PonderAct(now)
	local act = self:GetAct()
	if act == ACT_STRIKE then
		self.Goal = nil
	elseif act == ACT_DRAG then
		self.Goal = self.Lair
		if Victim.Awake(self:GetVictim()) then self.Pace = 1 end -- they're making a racket
		if self:Reached(self.Lair) or now > self.ActDeadline then
			self:SetAct(ACT_FEED)
			self:SetActStart(now)
			self:SetState("feed")
			self.FeedUntil = now + PULL_TIME + FEED_TIME
		end
	elseif act == ACT_FEED then
		self.Goal = nil
		if self:Disturbed() then
			self:StartDrag(now) -- someone came close: take it somewhere else
		elseif now > self.FeedUntil then
			if Victim.Alive(self:GetVictim()) then Victim.Kill(self:GetVictim(), self) end
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
		self:HoldCorpse(victim, self:HoldPoint(now, FrameTime()), 8, grip * grip)
		if self:GetAct() == ACT_FEED then self:Feed(victim, now) end
	end
end

function ENT:OnRemove()
	self:Release()
end
