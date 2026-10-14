local Scent = EvilCrawler.Scent

local cv_puppet = CreateConVar("evil_crawler_puppet", "0", 0, "Crawlers follow their spawner's crosshair instead of thinking")
local cv_debug = GetConVar("evil_crawler_debug_scent")
local ai_ignoreplayers = GetConVar("ai_ignoreplayers")
local ai_disabled = GetConVar("ai_disabled")

function EvilCrawler.IgnoresPlayers()
	return EvilCrawler.Setting("attack_players") == 0 or (ai_ignoreplayers and ai_ignoreplayers:GetBool())
end

local THINK_INTERVAL = 0.25
local QUICK_INTERVAL = 0.1
local SNAP = 22
local SNAGGED = { 120, 400 }
local SNIFF_RADIUS = 400
local SCENT_THRESHOLD = 0.12
local TOUCH_RANGE = 220
local TREMOR_RANGE = 1000
local TREMOR_SPEED = 150
local SIGHT_CLEAR = 500
local SIGHT_STILL, SIGHT_RUN = 0.2, 400
local SIGHT_CROUCH = 0.5
local SIGHT_LIT = 2
local FIRED_TIME = 1
local SIGHT_GAIN = 3
local SIGHT_FADE = 0.25
local NOTICE = 0.35
local LEAD = 0.6
local REACHED = 72
local SKIP_AHEAD = 260
local SEARCH_TIME = 8
local SEARCH_SPREAD = 300
local STUCK_TIME = 2.5
local HUNGRY_PULL = 2
local FED_PULL = 0.3
local FEAR_PULL = 1.5
local GRUDGE_PULL = 2.5
local FLEE_TIME = 8
local HIDE_SPREAD = { 2 / 3, 4 / 3 }
local ANGER_MAX = 3
local ANGER_FADE = 180
local ANGER_PACE = 0.15
local PAIN_SOUNDS = { "npc/barnacle/barnacle_die1.wav", "npc/barnacle/barnacle_die2.wav" }
local PAIN_HIT_SOUND = "physics/flesh/flesh_squishy_impact_hard2.wav"
local SHOT_RADIUS = 0.9
local RAGE_WINDOW = 30
local RAGE_REACH = 110
local RAGE_SOUND = "ambient/fire/gascan_ignite1.wav"
local RAGE_LOOP = "ambient/fire/fire_med_loop1.wav"

local RHYTHM = {
	roam = { pace = 0.09, go = { 3, 8 }, stop = { 1, 4 } },
	search = { pace = 0.55, go = { 0.3, 0.8 }, stop = { 0.5, 1.6 } },
	track = { pace = 0.7, go = { 0.4, 1.1 }, stop = { 0.3, 1.2 } },
	hunt = { pace = 1, go = { 0.6, 1.5 }, stop = { 0.08, 0.3 }, freeze = { 0.3, 0.7 } },
	strike = { pace = 0 },
	drag = { pace = 1.15 },
	feed = { pace = 0 },
	flee = { pace = 1.2 },
	hide = { pace = 0 },
	grapple = { pace = 0 },
	stunned = { pace = 0 },
	watch = { pace = 0 },
	rage = { pace = 1.3 },
}
local MOOD = {
	roam = 0, search = 1, track = 1, hunt = 2, strike = 2, drag = 2, feed = 1, flee = 2, hide = 0, grapple = 2,
	stunned = 0, watch = 2, rage = 2,
}
local CHASING = { search = true, track = true, hunt = true }
local STATE_COLOR = {
	roam = Color(120, 120, 120), search = Color(255, 200, 0), track = Color(255, 120, 0), hunt = Color(255, 0, 0),
	flee = Color(0, 200, 255), hide = Color(0, 80, 160), watch = Color(255, 0, 255), rage = Color(255, 60, 0),
}

local function Perceivable(ent)
	if ent:IsFlagSet(FL_NOTARGET) then return false end
	if ent:IsNPC() then return ent:Health() > 0 and not ent.EvilCrawlerVictim end
	return ent:Alive()
		and not ent.EvilCrawlerVictim
		and ent:GetMoveType() ~= MOVETYPE_NOCLIP
		and ent:GetObserverMode() == OBS_MODE_NONE
end

function ENT:SurfaceDistance(point)
	local to = point - self:GetPos()
	return (to - self.BodyUp * to:Dot(self.BodyUp)):Length()
end

function ENT:Reached(point)
	return self:SurfaceDistance(point) < REACHED
end

function ENT:Feels(ent, pos)
	if not Perceivable(ent) or (ent:IsPlayer() and not self:Wants(ent)) then return false end
	local center = ent:WorldSpaceCenter()
	local d = center:Distance(pos)
	if self.Spotted[ent] and self.InView[ent] then return true, d end
	local tremor = d < TREMOR_RANGE and ent:IsOnGround() and ent:GetVelocity():Length() > TREMOR_SPEED
	if (d < TOUCH_RANGE or tremor) and not self:Trace(pos, center).Hit then return true, d end
	return false
end

function ENT:Visibility(ent, pos, now)
	if not Perceivable(ent) or (ent:IsPlayer() and not self:Wants(ent)) then return 0 end
	local range = EvilCrawler.Setting("sight_range")
	local center = ent:WorldSpaceCenter()
	local d = center:Distance(pos)
	if d >= range then return 0 end
	if self:Trace(pos, ent:EyePos(), MASK_OPAQUE).Hit and self:Trace(pos, center, MASK_OPAQUE).Hit then return 0 end

	local speed = ent:IsNPC() and (ent.EvilCrawlerSpeed or 0) or ent:GetVelocity():Length()
	local v = Lerp(math.min(1, speed / SIGHT_RUN), SIGHT_STILL, 1)
	v = v * math.min(1, 1 - (d - SIGHT_CLEAR) / math.max(1, range - SIGHT_CLEAR))
	if ent:IsPlayer() and ent:Crouching() then v = v * SIGHT_CROUCH end
	if (ent:IsPlayer() and ent:FlashlightIsOn()) or now - (ent.EvilCrawlerFiredAt or -math.huge) < FIRED_TIME then
		v = v * SIGHT_LIT
	end
	return v
end

function ENT:Look(now)
	local pos = self:GetPos()
	local dt = math.min(now - (self.LastLook or now), THINK_INTERVAL * 2)
	self.LastLook = now
	self.Awareness = self.Awareness or {}
	self.Spotted = self.Spotted or {}
	self.InView = {}

	local seen = {}
	local function look(ent)
		local v = self:Visibility(ent, pos, now)
		if v <= 0 then return end
		seen[ent] = v
		self.InView[ent] = true
		self.Awareness[ent] = self.Awareness[ent] or 0
	end
	for _, ply in ipairs(player.GetAll()) do look(ply) end
	if self:IsHungry() then
		for npc in pairs(Scent.npcs) do
			if IsValid(npc) and self:IsEdible(npc) then look(npc) end
		end
	end

	for ent, sure in pairs(self.Awareness) do
		local v = seen[ent] or 0
		sure = math.Clamp(sure + (v * SIGHT_GAIN - SIGHT_FADE) * dt, 0, 1)
		if self.Spotted[ent] and v > 0 then sure = 1 end
		if sure >= 1 then
			self.Spotted[ent] = true
		elseif sure < NOTICE then
			self.Spotted[ent] = nil
		end
		if sure <= 0 or not IsValid(ent) then
			self.Awareness[ent], self.Spotted[ent] = nil, nil
		else
			self.Awareness[ent] = sure
		end
	end
end

function ENT:Glimpse()
	local best, bestSure
	for ent in pairs(self.InView) do
		local sure = self.Awareness[ent] or 0
		if sure >= NOTICE and not self.Spotted[ent] and (not best or sure > bestSure) then best, bestSure = ent, sure end
	end
	return best
end

function ENT:Lead(ent)
	if not ent:IsPlayer() then return ent:GetPos() end
	local from = ent:GetPos() + Vector(0, 0, 32)
	local tr = self:Trace(from, from + ent:GetVelocity() * LEAD)
	return tr.HitPos + tr.HitNormal * 16 - Vector(0, 0, 32)
end

function ENT:Sense()
	local pos = self:GetPos()
	local meal, mealDist, person, personDist

	if self:IsHungry() then
		for npc in pairs(Scent.npcs) do
			if IsValid(npc) and self:IsEdible(npc) then
				local felt, d = self:Feels(npc, pos)
				if felt and (not meal or d < mealDist) then meal, mealDist = npc, d end
			end
		end
	end
	if meal then return meal end

	for _, ply in ipairs(player.GetAll()) do
		local felt, d = self:Feels(ply, pos)
		if felt and (not person or d < personDist) then person, personDist = ply, d end
	end
	return person
end

function ENT:Appeal(node, now)
	local owner = node.trail.owner
	if not node.npc and not (IsValid(owner) and self:Wants(owner)) then return 0 end
	local w = 1
	if node.npc then w = self:IsHungry() and HUNGRY_PULL or FED_PULL end
	if node.fear then w = math.max(w, 1) * FEAR_PULL end
	if self.Grudge and node.trail.owner == self.Grudge then w = math.max(w, 1) * GRUDGE_PULL end
	return Scent.Intensity(node, now) * w
end

function ENT:FollowTrail(node)
	local pos = self:GetPos()
	while node.next and not node.next.dead do
		if self:Reached(node.pos) or node.next.pos:Distance(pos) < SKIP_AHEAD then
			node = node.next
		else
			break
		end
	end
	return node
end

function ENT:Around(center, spread)
	local offset = VectorRand() * spread
	return center + offset - self.BodyUp * offset:Dot(self.BodyUp)
end

function ENT:SetState(state)
	local r = RHYTHM[state]
	if state ~= self.State then
		local first = r.freeze or r.go
		self.Still = r.freeze ~= nil
		self.FitUntil = first and CurTime() + math.Rand(first[1], first[2]) or 0
		self.OverSince = nil
	end
	self.State = state
	self.Pace = r.pace
	self:SetMood(MOOD[state])
end

function ENT:Ponder()
	local now = CurTime()
	local pos = self:GetPos()

	if self:GetAct() ~= EvilCrawler.ACT_NONE then
		self:PonderAct(now)
		return
	end
	if self.State == "rage" and self:Rampage(now) then return end
	self:Cool(now)
	if self:LyingLow(now) then return end

	self.Puppeting = cv_puppet:GetBool()
	if self.Puppeting then
		self.Goal = self:PuppetGoal()
		self.Pace = 0.4
		for npc in pairs(Scent.npcs) do
			if IsValid(npc) and self:CanAttack(npc) then
				self:StartStrike(npc)
				return
			end
		end
		return
	end

	self:Look(now)
	local prey = self:Sense()
	self:SetPrey(prey or NULL)
	if prey then
		if self:CanAttack(prey) then
			self:StartStrike(prey)
			return
		end
		self:SetState("hunt")
		self.Goal = prey:GetPos()
		self.LastKnown = self:Lead(prey)
		self:Overhead(prey, now)
		return
	end
	if self.State == "hunt" then
		self:SetState("search")
		self.Goal = self.LastKnown
		self.SearchUntil = now + SEARCH_TIME
	end

	local glimpse = self:Glimpse()
	if glimpse then
		self:SetPrey(glimpse)
		self:SetState("watch")
		self.Goal = nil
		self.LastKnown = glimpse:GetPos()
		return
	end
	if self.State == "watch" then
		self:SetState("search")
		self.Goal = self.LastKnown
		self.SearchUntil = now + SEARCH_TIME
	end

	local node = self.Trail
	if node and (node.dead or self:Appeal(node, now) < SCENT_THRESHOLD * 0.5) then node = nil end
	self.WeighScent = self.WeighScent or function(n, t) return self:Appeal(n, t) end
	local whiff, strength = Scent.Strongest(pos, SNIFF_RADIUS, now, self.WeighScent)
	if whiff and strength >= SCENT_THRESHOLD and (not node or strength > self:Appeal(node, now) * 1.5) then
		node = whiff
	end

	if node then
		node = self:FollowTrail(node)
		self.Trail = node
		self:SetState("track")
		self.Pace = RHYTHM.track.pace * Lerp(math.min(1, Scent.Intensity(node, now)), 0.6, 1)
		if node.next or not self:Reached(node.pos) then
			self.Goal = node.pos
		elseif not self.Goal or self:Reached(self.Goal) or self.Goal:Distance(node.pos) > 200 then
			self.Goal = self:Around(node.pos, 150)
		end
		return
	end
	self.Trail = nil

	if self.State == "search" and now < self.SearchUntil then
		if self:Reached(self.Goal) then self.Goal = self:Around(self.LastKnown, SEARCH_SPREAD) end
		return
	end

	if self.State ~= "roam" or now > (self.NextVeer or 0) then
		self.Heading = VectorRand():GetNormalized()
		self.NextVeer = now + math.Rand(4, 9)
	end
	self:SetState("roam")
	self.Goal = pos + self.Heading * 1000
end

function ENT:CheckProgress(now)
	if not self.Goal then return end

	if not self.ProgressGoal or self.ProgressGoal:Distance(self.Goal) > 100 then
		self.ProgressGoal, self.BestDist, self.ProgressTime = self.Goal, math.huge, now
	end

	if self.Still then
		self.ProgressTime = now
		return
	end

	local d = self:SurfaceDistance(self.Goal)
	if d < self.BestDist - 16 or d < REACHED then
		self.BestDist, self.ProgressTime = d, now
	elseif now - self.ProgressTime > STUCK_TIME then
		self.BestDist, self.ProgressTime = d, now
		if self.BodyUp.z < -0.5 then
			self.LetGoUntil = now + 0.4
		else
			self:Veer(now, 1.5)
		end
	end
end

function ENT:Veer(now, time)
	self.Detour = (self:Around(self:GetPos(), 1) - self:GetPos()):GetNormalized() * 400
	self.DetourUntil = now + time
end

function ENT:Overhead(prey, now)
	if not self:Reached(prey:GetPos()) then
		self.OverSince = nil
		return
	end
	if (prey:WorldSpaceCenter() - self:GetPos()):Dot(self.BodyUp) < 0 then
		self.LetGoUntil = now + 0.4
		self.OverSince = nil
		return
	end
	self.OverSince = self.OverSince or now
	if now - self.OverSince > EvilCrawler.Setting("reroute_time") then
		self.OverSince = nil
		self:Veer(now, 0.4)
	end
end

function ENT:Fits(now)
	local r = RHYTHM[self.State]
	if self.Puppeting or not (r and r.go) then
		self.Still = false
		return
	end
	if now < self.FitUntil then return end
	self.Still = not self.Still
	local span = self.Still and r.stop or r.go
	self.FitUntil = now + math.Rand(span[1], span[2])
end

function ENT:Switched()
	if not (ai_disabled and ai_disabled:GetBool()) then return false end
	if self:GetAct() ~= EvilCrawler.ACT_NONE then self:Release() end
	self:SetPrey(NULL)
	self:SetMood(0)
	self.DetourUntil = nil
	return true
end

function ENT:Steer()
	if self.Off then return nil, 0, SNAP end
	local now = CurTime()
	if now >= (self.NextThought or 0) then
		self.NextThought = now + ((self.Pace or 0) > 0.3 and QUICK_INTERVAL or THINK_INTERVAL)
		self:Ponder()
		self:CheckProgress(now)
		if cv_debug:GetBool() and self.Goal then
			local c = STATE_COLOR[self.State] or color_white
			debugoverlay.Line(self:GetPos(), self.Goal, THINK_INTERVAL, c, true)
			debugoverlay.Text(self:GetPos() + self.BodyUp * 40, (self.State or "puppet") .. " " .. #(self.Hits or {}), THINK_INTERVAL)
		end
	end

	local burst = EvilCrawler.Setting("burst")
	if self.DetourUntil and now < self.DetourUntil then
		return self:GetPos() + self.Detour, (self.Pace or 0) * burst, SNAP
	end
	self:Fits(now)
	if self.Still then return nil, 0, SNAP end
	local pace = self.Pace or 0
	if CHASING[self.State] then pace = pace * (1 + ANGER_PACE * (self.Anger or 0)) end
	if self.State == "drag" then
		pace = pace * (1 - math.Clamp(((self.HoldLag or 0) - SNAGGED[1]) / (SNAGGED[2] - SNAGGED[1]), 0, 0.9))
	end
	return self.Goal, pace * burst, SNAP
end

local EYE_FLAGS = 65536 + 131072

local function Disposition()
	return EvilCrawler.Setting("npcs_fight") > 0 and D_HT or D_NU
end

local function Fights(npc)
	return IsValid(npc) and npc:IsNPC() and npc:GetClass() ~= "npc_bullseye"
end

function ENT:Expose()
	local eye = ents.Create("npc_bullseye")
	eye:SetPos(self:GetPos())
	eye:SetParent(self)
	eye:SetKeyValue("spawnflags", tostring(EYE_FLAGS))
	eye:Spawn()
	eye:Activate()
	self:DeleteOnRemove(eye)
	self.Eye = eye
	self:AddEFlags(EFL_DONTBLOCKLOS)
	self:AddFlags(FL_OBJECT)
	self.DrGBase_Target = true
	self.VJ_ID_Destructible = true
	self.MovementType = VJ_MOVETYPE_STATIONARY

	local d = Disposition()
	for _, npc in ipairs(ents.GetAll()) do
		if Fights(npc) then npc:AddEntityRelationship(eye, d, 0) end
	end
end

local function Eyes()
	local eyes = {}
	for _, crawler in ipairs(ents.FindByClass("evil_crawler")) do
		if IsValid(crawler.Eye) then eyes[#eyes + 1] = crawler.Eye end
	end
	return eyes
end

local function Meet(ent, eyes)
	local d = Disposition()
	if ent.IsDrGNextbot then ent:SetClassRelationship("evil_crawler", d, 2) end
	if not Fights(ent) then return end
	for _, eye in ipairs(eyes) do ent:AddEntityRelationship(eye, d, 0) end
end

hook.Add("OnEntityCreated", "EvilCrawlerEnemy", function(ent)
	if not (ent:IsNPC() or ent:IsNextBot()) then return end
	timer.Simple(0, function()
		if IsValid(ent) then Meet(ent, Eyes()) end
	end)
end)

cvars.AddChangeCallback("evil_crawler_npcs_fight", function()
	local eyes = Eyes()
	for _, ent in ipairs(ents.GetAll()) do Meet(ent, eyes) end
end, "EvilCrawlerEnemy")

function ENT:HandlePerceivedRelationship()
	return Disposition()
end

timer.Create("EvilCrawlerEnemy", 1, 0, function()
	local crawlers = ents.FindByClass("evil_crawler")
	if #crawlers == 0 then return end
	for npc in pairs(Scent.npcs) do
		local list, memory
		if IsValid(npc) then list, memory = npc.RelationshipEnts, npc.RelationshipMemory end
		if list and memory then
			for _, crawler in ipairs(crawlers) do
				if not table.HasValue(list, crawler) then
					memory[crawler] = memory[crawler] or {}
					list[#list + 1] = crawler
				end
			end
		end
	end
end)

function ENT:OnTakeDamage(dmg)
	if dmg:GetDamage() <= 0 then return end
	self:Hurt(dmg:GetAttacker(), dmg:GetDamagePosition())
end

function ENT:Hurt(attacker, from)
	local now = CurTime()

	if now >= (self.NextPain or 0) then
		self.NextPain = now + 1.5
		self:EmitSound(PAIN_SOUNDS[math.random(#PAIN_SOUNDS)], 85, math.random(135, 155))
	end
	if self.Off then return end
	if self:Raging(now) then
		if IsValid(attacker) and attacker ~= self and not attacker:IsWorld() then self.Grudge = attacker end
		return
	end
	if self:Provoked(now) then
		self:Rage(attacker, now)
		return
	end
	if self:GetAct() ~= EvilCrawler.ACT_NONE then self:Release() end
	if self.State == "flee" then
		if IsValid(attacker) and attacker ~= self and not attacker:IsWorld() then self.Grudge = attacker end
		return
	end

	self:Enrage(attacker, now)
	self:SetPrey(NULL)
	self:SetState("flee")
	self.Goal = self:FindLair(IsValid(attacker) and attacker:EyePos() or from)
	self.FleeUntil = now + FLEE_TIME
	self.Trail = nil
	self.DetourUntil = nil
end

function ENT:Raging(now)
	return now < self:GetRageUntil()
end

function ENT:Provoked(now)
	if EvilCrawler.Setting("rage_time") <= 0 then return false end
	self.Hits = self.Hits or {}
	self.Hits[#self.Hits + 1] = now
	while now - self.Hits[1] > RAGE_WINDOW do table.remove(self.Hits, 1) end
	return #self.Hits >= EvilCrawler.Setting("rage_hits")
end

function ENT:Rage(by, now)
	self.Hits = nil
	if self:GetAct() ~= EvilCrawler.ACT_NONE then self:Release() end
	if IsValid(by) and by ~= self and not by:IsWorld() then self.Grudge = by end
	self:SetRageUntil(now + EvilCrawler.Setting("rage_time"))
	self:SetState("rage")
	self.Trail, self.DetourUntil, self.Goal = nil, nil, nil
	self:EmitSound(RAGE_SOUND, 90, 80)
	self.Roar = self.Roar or CreateSound(self, RAGE_LOOP)
	self.Roar:Stop()
	self.Roar:PlayEx(1, 120)
end

local function Burnable(ent)
	if not IsValid(ent) or not (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then return false end
	if ent.EvilCrawlerVictim or ent:IsFlagSet(FL_NOTARGET) then return false end
	if ent:IsPlayer() then
		return ent:Alive() and not EvilCrawler.IgnoresPlayers() and not ent:HasGodMode() and not ent:InVehicle()
			and ent:GetMoveType() ~= MOVETYPE_NOCLIP and ent:GetObserverMode() == OBS_MODE_NONE
	end
	return (ent:IsNPC() or ent:IsNextBot()) and ent:Health() > 0 and ent:GetClass() ~= "npc_bullseye"
end

function ENT:Quarry()
	if Burnable(self.Grudge) then return self.Grudge end
	local pos = self:GetPos()
	local best, bestDist = nil, EvilCrawler.Setting("sight_range")
	for _, ent in ipairs(ents.FindInSphere(pos, bestDist)) do
		if Burnable(ent) then
			local d = ent:WorldSpaceCenter():Distance(pos)
			if d < bestDist and not self:Trace(pos, ent:WorldSpaceCenter(), MASK_OPAQUE).Hit then best, bestDist = ent, d end
		end
	end
	return best
end

function ENT:Rampage(now)
	if not self:Raging(now) then
		if self.Roar then self.Roar:FadeOut(1) end
		self:SetPrey(NULL)
		self:SetState("flee")
		self.Goal = self:FindLair()
		self.FleeUntil = now + FLEE_TIME
		return false
	end

	local pos = self:GetPos()
	local target = self:Quarry()
	self:SetPrey(target or NULL)
	if not target then
		if not self.Goal or self:Reached(self.Goal) then self.Goal = self:Around(pos, 600) end
		return true
	end
	if target:NearestPoint(pos):Distance(pos) < RAGE_REACH and not self:Trace(pos, target:WorldSpaceCenter(), MASK_OPAQUE).Hit then
		self:Sear(target)
		return true
	end
	self.Goal = target:GetPos()
	self:Overhead(target, now)
	return true
end

function ENT:ShotHits(src, dir, range, shooter)
	local center = self:GetPos()
	local r = self.BodyHeight * SHOT_RADIUS
	local t = (center - src):Dot(dir)
	local miss = (src + dir * t):DistToSqr(center)
	if t < 0 or miss > r * r then return end
	local enter = math.max(0, t - math.sqrt(r * r - miss))
	if enter > range then return end

	local hit = src + dir * enter
	local tr = util.TraceLine({ start = src, endpos = hit, mask = MASK_SHOT, filter = shooter })
	if tr.Hit and tr.Entity ~= self then return end
	return hit, enter
end

hook.Add("EntityFireBullets", "EvilCrawlerShot", function(shooter, data)
	shooter.EvilCrawlerFiredAt = CurTime()
	local dir = data.Dir:GetNormalized()
	local range = data.Distance or 56756
	local filter = { shooter, data.IgnoreEntity }
	local struck, hit, nearest
	for _, crawler in ipairs(ents.FindByClass("evil_crawler")) do
		local p, d = crawler:ShotHits(data.Src, dir, range, filter)
		if p and (not nearest or d < nearest) then struck, hit, nearest = crawler, p, d end
	end
	if not struck then return end

	local fx = EffectData()
	fx:SetOrigin(hit)
	fx:SetNormal(-dir)
	fx:SetColor(BLOOD_COLOR_YELLOW)
	util.Effect("BloodImpact", fx)
	sound.Play(PAIN_HIT_SOUND, hit, 70, math.random(90, 110), 0.7)

	local attacker = IsValid(data.Attacker) and data.Attacker or shooter
	struck:Hurt(attacker, hit)

	data.Distance = nearest
	return true
end)

function ENT:LyingLow(now)
	if self.State == "flee" then
		if self.Goal and not self:Reached(self.Goal) and now < self.FleeUntil then return true end
		self:SetState("hide")
		self.HideUntil = now + EvilCrawler.Setting("hide_time") * math.Rand(HIDE_SPREAD[1], HIDE_SPREAD[2])
	end
	if self.State ~= "hide" then return false end
	if now < self.HideUntil then
		self.Goal = nil
		return true
	end
	self:SetState("roam")
	return false
end

function ENT:Enrage(by, now)
	if IsValid(by) and by ~= self and not by:IsWorld() then self.Grudge = by end
	self.Anger = math.min(ANGER_MAX, (self.Anger or 0) + 1)
	self.CalmAt = now + ANGER_FADE
end

function ENT:Cool(now)
	if (self.Anger or 0) > 0 and now > self.CalmAt then
		self.Anger = self.Anger - 1
		self.CalmAt = now + ANGER_FADE
		if self.Anger == 0 then self.Grudge = nil end
	end
end

function ENT:PuppetGoal()
	local ply = self.Master
	if not IsValid(ply) then return end

	local eye = ply:EyePos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * 4096, filter = { ply, self } })
	if tr.Hit then return tr.HitPos end
end
