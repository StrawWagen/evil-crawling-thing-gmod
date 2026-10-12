-- How it feeds: one leg rears back, whips out and coils round an NPC, and
-- holds on while they fight it and the teeth along it put them under
-- (sv_victim.lua). That leg is done walking until it lets go: it carries them
-- somewhere out of sight, waits there until they've stopped struggling, then
-- shifts its grip to the head and hauls them up into its mouth, where the
-- legs meet. It holds them there, asleep, slowly turning, while the other
-- legs stab into the mouthful going in and tear it apart, until it's
-- swallowed and the next is drawn in: head, shoulders, chest, hips, legs,
-- until there's nothing left. It never eats anything still fighting: not
-- worth it. Players are never attacked.

local Victim = EvilCrawler.Victim
local ACT_NONE, ACT_STRIKE, ACT_DRAG, ACT_FEED =
	EvilCrawler.ACT_NONE, EvilCrawler.ACT_STRIKE, EvilCrawler.ACT_DRAG, EvilCrawler.ACT_FEED
local IMPACT_TIME = EvilCrawler.STRIKE_WINDUP + EvilCrawler.STRIKE_LUNGE

local ATTACK_REACH = 140
local MISS_REACH = ATTACK_REACH * 1.5 -- got this far away during the windup: the strike misses
local PULL_TIME = EvilCrawler.PULL_TIME
local TRAIL_RATE = 1.5 -- how fast a carried body swings round behind it
local TRAIL_SPEED = 250 -- past this speed it swings round proportionally faster
local FEEDERS = EvilCrawler.FEEDERS
local BITE_IN, BITE_RIP = EvilCrawler.BITE_IN, EvilCrawler.BITE_RIP
local BiteCycle, BiteBone = EvilCrawler.BiteCycle, EvilCrawler.BiteBone
local PARTS, CurrentPart = EvilCrawler.PARTS, EvilCrawler.CurrentPart
local TORSO_TIME = 6 -- picks at a body it can't swallow this long before it's done
local FINISH_TIME = 2 -- the last mouthful goes down this long after it's torn loose
local GULP_DEPTH = 5 -- how far each swallow draws the mouthful in
local GULP_RATE = 1.7 -- swallows a second, roughly
local FEED_CAP = 60 -- gives up eating after this long, whatever's left
local STAB_FORCE = 120
local RIP_FORCE = 350
local DRAINED = 40 -- rips until the body is as dark as it gets
local TURN_SPEED = 35 -- degrees a second it turns the body over while eating
local DRAG_TIME = 15 -- gives up looking for somewhere private after this long and stops where it is
local SATED_TIME = 90
local ANGER_HUNGER = 0.5 -- each step of anger shortens how long a meal lasts it by this share
local LAIR_TRIES = 12
local LAIR_RANGE = { 700, 2500 } -- far enough that the haul there is a long, fast one
local OUT_OF_SIGHT = 1500 -- what a hiding place gains from being somewhere `threat` can't see
local DISTURB_RANGE = 330

local WINDUP_SOUNDS = { "npc/barnacle/barnacle_tongue_pull1.wav", "npc/barnacle/barnacle_tongue_pull2.wav" }
local LUNGE_SOUND = "npc/zombie/claw_miss1.wav"
local GRAB_SOUNDS = {
	"physics/body/body_medium_impact_soft1.wav",
	"physics/body/body_medium_impact_soft3.wav",
	"physics/body/body_medium_impact_soft5.wav",
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
local CONSUME_SOUNDS = {
	"physics/body/body_medium_break2.wav",
	"physics/body/body_medium_break3.wav",
	"physics/body/body_medium_break4.wav",
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
	self.BitePart = nil
	self.Devoured = nil
end

local function Smooth(t)
	return t * t * (3 - 2 * t)
end

local function Chest(corpse)
	local bone = corpse:LookupBone("ValveBiped.Bip01_Spine2")
	local index = bone and corpse:TranslateBoneToPhysBone(bone) or 0
	return corpse:GetPhysicsObjectNum(index >= 0 and index or 0)
end

function ENT:Sate(now)
	self.SatedUntil = now + SATED_TIME / (1 + ANGER_HUNGER * (self.Anger or 0))
end

-- The leg lands and coils round them, and they're off their feet.
function ENT:Strike(npc)
	local now = CurTime()
	local center = npc:WorldSpaceCenter()
	local dir = (center - self:GetPos()):GetNormalized()

	if npc.DropWeapon and IsValid(npc:GetActiveWeapon()) then npc:DropWeapon() end

	local corpse = Victim.Grab(npc, self)
	if not IsValid(corpse) then
		self:Release() -- nothing it can get a grip on
		return
	end
	sound.Play(GRAB_SOUNDS[math.random(#GRAB_SOUNDS)], center, 75, math.random(80, 95))

	self:SetVictim(corpse)
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
	self.BitePart = nil
end

local function NearestPlayer(spot)
	local nearest = math.huge
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() then nearest = math.min(nearest, ply:GetPos():Distance(spot)) end
	end
	return nearest
end

-- Somewhere private to eat or hide: far from every player (and from
-- `threat`, if given, and out of its sight), ideally with a roof overhead
-- and walls close around.
function ENT:FindLair(threat)
	local pos = self:GetPos()
	local best, bestScore = pos, -math.huge
	for _ = 1, LAIR_TRIES do
		local dir = VectorRand()
		dir.z = dir.z * 0.3
		dir:Normalize()
		local tr = self:Trace(pos, pos + dir * math.Rand(LAIR_RANGE[1], LAIR_RANGE[2]))
		local spot = tr.HitPos - dir * 32

		local score = math.min(NearestPlayer(spot), 3000)
		if threat then
			score = score + math.min(threat:Distance(spot), 3000)
			if self:Trace(threat, spot).Hit then score = score + OUT_OF_SIGHT end
		end
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

-- How far into the haul up into the mouth, 0..1. Reeled in by jerks.
function ENT:Pull(now)
	if self:GetAct() ~= ACT_FEED then return 0 end
	local t = now - self:GetActStart()
	return math.Clamp((t + 0.06 * math.sin(t * 12)) / PULL_TIME, 0, 1)
end

-- Where the holding leg keeps the body: carried low at the leg's length,
-- swinging round to trail behind as it crawls, and hauled up into the mouth
-- once it's somewhere quiet, where every swallow draws it a little further in.
function ENT:HoldPoint(now, dt)
	local pos, up, h = self:GetPos(), self.BodyUp, self.BodyHeight
	local dir = self.CarryDir or -self.Facing
	local speed = self.Vel:Length()
	if speed > 20 then
		local rate = TRAIL_RATE * math.max(1, speed / TRAIL_SPEED)
		dir = LerpVector(1 - math.exp(-dt * rate), dir, -self.Facing)
	end
	dir = dir - up * dir:Dot(up)
	if dir:LengthSqr() < 1e-4 then dir = -self.Facing end
	dir:Normalize()
	self.CarryDir = dir

	local carry = pos - up * (h * 0.6) + dir * (h * 1.1)
	local t = now - self:GetActStart() - PULL_TIME
	local mouth = pos
	if self:GetAct() == ACT_FEED and t > 0 then
		mouth = pos + up * (GULP_DEPTH * math.max(0, math.sin(t * GULP_RATE * math.pi * 2)) ^ 2)
	end
	return LerpVector(Smooth(self:Pull(now)), carry, mouth)
end

local function BitePhys(corpse, name)
	local bone = corpse:LookupBone(name)
	local index = bone and corpse:TranslateBoneToPhysBone(bone) or -1
	if index < 0 then index = math.random(0, corpse:GetPhysicsObjectCount() - 1) end
	local phys = corpse:GetPhysicsObjectNum(index)
	return IsValid(phys) and phys
end

-- What the holding leg has hold of: whatever mouthful is going in once it's
-- started eating, or once anything's gone; the chest before that.
function ENT:Held(corpse)
	local part = CurrentPart(corpse)
	if not part or (part == 1 and self:GetAct() ~= ACT_FEED) then return { Chest(corpse) } end
	local held = {}
	for _, name in ipairs(PARTS[part].grip) do
		local phys = BitePhys(corpse, name)
		if phys then held[#held + 1] = phys end
	end
	return held
end

-- The body hangs from the holding leg by what it's holding. Two bones (a pair
-- of legs) go in side by side. With a loose grip the body keeps more of its
-- own momentum.
function ENT:HoldCorpse(corpse, hold, stiffness, grip)
	local held = self:Held(corpse)
	local side = self.BodyUp:Cross(self.Facing)
	self.HoldLag = 0
	for i, phys in ipairs(held) do
		if IsValid(phys) then
			local at = hold + side * ((i - (#held + 1) / 2) * 7)
			local p = phys:GetPos()
			self.HoldLag = math.max(self.HoldLag, p:Distance(at))
			if p:Distance(at) > 600 then
				self:Release() -- snagged on something; leave it
				return
			end
			phys:SetVelocity(LerpVector(0.5 * grip, phys:GetVelocity(), (at - p) * stiffness + self.Vel))
		end
	end
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

-- A mouthful, stripped down to nothing. Its physics stays on to hold the
-- ragdoll together, but nothing can touch it.
local function Strip(corpse, part)
	for _, bone in ipairs(EvilCrawler.PartBones(corpse, part)) do
		corpse:ManipulateBoneScale(bone, Vector(0, 0, 0))
		local index = corpse:TranslateBoneToPhysBone(bone)
		if index >= 0 and corpse:TranslatePhysBoneToBone(index) == bone then
			local phys = corpse:GetPhysicsObjectNum(index)
			if IsValid(phys) then phys:EnableCollisions(false) end
		end
	end
end

-- The last of a mouthful goes down: a burst of blood out of the mouth.
function ENT:Consume(corpse, part, now)
	local p = self:GetPos()
	Strip(corpse, part)
	corpse:SetNW2Int(EvilCrawler.EATEN_VAR, bit.bor(corpse:GetNW2Int(EvilCrawler.EATEN_VAR, 0), bit.lshift(1, part - 1)))

	local fx = EffectData()
	fx:SetOrigin(p)
	fx:SetNormal(self.BodyUp)
	fx:SetScale(10)
	fx:SetColor(BLOOD_COLOR_RED)
	fx:SetFlags(7)
	util.Effect("bloodspray", fx)
	for _ = 1, 3 do util.Decal("Blood", p, p - self.BodyUp * 200 + VectorRand() * 80, corpse) end
	sound.Play(CONSUME_SOUNDS[math.random(#CONSUME_SOUNDS)], p, 80, math.random(85, 100))
	timer.Simple(0.6, function()
		if IsValid(self) then
			sound.Play(GULP_SOUNDS[math.random(#GULP_SOUNDS)], self:GetPos(), 70, math.random(55, 70))
		end
	end)

	if not CurrentPart(corpse) then
		self.Devoured = true
		self.FeedUntil = math.min(self.FeedUntil, now + FINISH_TIME)
	end
	Victim.Maimed(corpse, PARTS[part].grip[1], self)
end

-- Once the body is hauled in: runs the bite schedule each feeding leg is
-- drawn following, and slowly turns the body as it goes in. Every leg works
-- the mouthful going in until it's gone.
function ENT:Feed(corpse, now)
	local t = now - self:GetActStart() - PULL_TIME
	if t < 0 then return end

	local seed = self:GetSeed()
	self.BiteStage = self.BiteStage or {}
	self.BitePart = self.BitePart or {}
	for k = 1, FEEDERS do
		local n, u = BiteCycle(k, t)
		local stage = n * 3 + (u < BITE_IN and 0 or u < BITE_RIP and 1 or 2)
		local last = self.BiteStage[k]
		self.BiteStage[k] = stage
		if last and stage ~= last and stage % 3 ~= 0 then
			-- which part this bite is on is settled when the leg goes in
			if stage % 3 == 1 then self.BitePart[k] = CurrentPart(corpse) or false end
			local part = self.BitePart[k] or nil
			local phys = BitePhys(corpse, BiteBone(seed, k, n, part))
			if phys then
				if stage % 3 == 1 then
					self:Stab(phys)
					Victim.Pierced(corpse)
				else
					self:Rip(phys, corpse)
					if part and part == CurrentPart(corpse) then
						corpse.EvilCrawlerRips = (corpse.EvilCrawlerRips or 0) + 1
						if corpse.EvilCrawlerRips >= PARTS[part].rips then
							corpse.EvilCrawlerRips = 0
							self:Consume(corpse, part, now)
						end
					end
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
		local there = self:Reached(self.Lair) or now > self.ActDeadline
		if there and Victim.Fighting(self:GetVictim()) then
			-- holds them there until they stop fighting, unless someone comes
			self.Goal = nil
			if self:Disturbed() then self:StartDrag(now) end
		elseif there then
			self:SetAct(ACT_FEED)
			self:SetActStart(now)
			self:SetState("feed")
			self.FeedUntil = now + PULL_TIME + FEED_CAP
			if not CurrentPart(self:GetVictim()) then
				self.FeedUntil = now + PULL_TIME + TORSO_TIME -- nothing left worth the trouble
			end
		end
	elseif act == ACT_FEED then
		self.Goal = nil
		local victim = self:GetVictim()
		if not self.Devoured and self:Disturbed() then
			self:StartDrag(now) -- someone came close: take it somewhere else
		elseif now > self.FeedUntil then
			if Victim.Alive(victim) then Victim.Kill(victim, self) end
			if self.Devoured then victim:Remove() end -- all gone
			self:Sate(now)
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
		self:HoldCorpse(victim, self:HoldPoint(now, FrameTime()), 8, 1)
		if self:GetAct() == ACT_FEED then self:Feed(victim, now) end
	end
end

function ENT:OnRemove()
	self:Release()
end
