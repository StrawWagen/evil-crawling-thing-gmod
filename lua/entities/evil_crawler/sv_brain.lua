-- What the crawler wants. It has no eyes. It knows players and NPCs three ways:
--   touch   anyone close enough, whatever they're doing
--   tremor  players running on the ground with nothing solid in between
--   scent   the trails everyone leaves (sv_scent.lua), followed toward
--           fresher scent
-- Hungry, it goes for NPCs it can eat (sv_attack.lua) over players, and
-- follows NPC trails over theirs. Fed, it loses interest in NPC trails but
-- not in players. Fear draws it either way.
-- Hurt, it drops whatever it's holding and runs for somewhere out of the way
-- to lie low. It comes back out angrier: quicker, hungrier sooner, and
-- following whoever hurt it.
-- It moves in fits, like something small and quick: dead still, then a dart
-- faster than anyone can run, then still again. Each thought sets self.Goal
-- (a point to crawl toward) and self.Pace (a share of dart speed); Crawl
-- does the moving.

local Scent = EvilCrawler.Scent

local cv_burst = CreateConVar("evil_crawler_burst", "1100", FCVAR_ARCHIVE, "Top speed of a dart")
local cv_puppet = CreateConVar("evil_crawler_puppet", "0", 0, "Crawlers follow their spawner's crosshair instead of thinking")
local cv_debug = CreateConVar("evil_crawler_debug_scent", "0", 0, "Draw scent trails (needs developer 1)")
local ai_ignoreplayers = GetConVar("ai_ignoreplayers")

local THINK_INTERVAL = 0.25
local QUICK_INTERVAL = 0.1 -- while darting, or it overshoots everything
local SNAP = 22 -- how hard it starts and stops
local SNAGGED = { 120, 400 } -- a body dragging this far behind slows it to a crawl, to yank it free
local SNIFF_RADIUS = 400
local SCENT_THRESHOLD = 0.12 -- faintest scent worth following
local TOUCH_RANGE = 220
local TREMOR_RANGE = 1000
local TREMOR_SPEED = 150 -- players moving slower than this make no tremor
local REACHED = 72 -- distance along the surface at which a goal counts as reached
local SKIP_AHEAD = 260 -- heads straight for trail nodes this close, skipping the ones between
local SEARCH_TIME = 8
local SEARCH_SPREAD = 300
local STUCK_TIME = 2.5
local HUNGRY_PULL = 2 -- how much more an NPC's trail draws it when it's hungry
local FED_PULL = 0.3 -- and when it isn't
local FEAR_PULL = 1.5
local GRUDGE_PULL = 2.5 -- how much more the trail of whoever hurt it draws it
local FLEE_TIME = 8 -- runs this long at most before hiding wherever it's got to
local HIDE_TIME = { 20, 40 }
local ANGER_MAX = 3
local ANGER_FADE = 180 -- seconds for each step of anger to wear off
local ANGER_PACE = 0.15 -- each step of anger makes it this much quicker on someone's trail
local PAIN_SOUNDS = { "npc/barnacle/barnacle_die1.wav", "npc/barnacle/barnacle_die2.wav" }
local PAIN_HIT_SOUND = "physics/flesh/flesh_squishy_impact_hard2.wav"
local SHOT_RADIUS = 0.9 -- body heights round the tangle that a bullet counts as hitting the legs

-- How it moves in each state: `pace` is a share of dart speed, held for `go`
-- seconds at a time with dead stillness for `stop` seconds between. It
-- freezes for `freeze` seconds the moment it enters a state, then goes.
local RHYTHM = {
	roam = { pace = 0.09, go = { 3, 8 }, stop = { 1, 4 } },
	search = { pace = 0.55, go = { 0.3, 0.8 }, stop = { 0.5, 1.6 } },
	track = { pace = 0.7, go = { 0.4, 1.1 }, stop = { 0.3, 1.2 } },
	hunt = { pace = 1, go = { 0.6, 1.5 }, stop = { 0.08, 0.3 }, freeze = { 0.3, 0.7 } },
	strike = { pace = 0 },
	drag = { pace = 1.15 }, -- bolts with the body, flat out, never stopping
	feed = { pace = 0 },
	flee = { pace = 1.2 },
	hide = { pace = 0 },
	grapple = { pace = 0 },
	stunned = { pace = 0 },
}
local MOOD = { roam = 0, search = 1, track = 1, hunt = 2, strike = 2, drag = 2, feed = 1, flee = 2, hide = 0, grapple = 2, stunned = 0 }
local CHASING = { search = true, track = true, hunt = true }
local STATE_COLOR = {
	roam = Color(120, 120, 120), search = Color(255, 200, 0), track = Color(255, 120, 0), hunt = Color(255, 0, 0),
	flee = Color(0, 200, 255), hide = Color(0, 80, 160),
}

local function Perceivable(ent)
	if ent:IsFlagSet(FL_NOTARGET) then return false end
	if ent:IsNPC() then return ent:Health() > 0 and not ent.EvilCrawlerVictim end
	return ent:Alive()
		and not ent.EvilCrawlerVictim
		and ent:GetMoveType() ~= MOVETYPE_NOCLIP
		and ent:GetObserverMode() == OBS_MODE_NONE
		and not (ai_ignoreplayers and ai_ignoreplayers:GetBool())
end

-- Distance to a point measured along the surface the body is on, so a
-- crawler on the ceiling counts as having reached a point on the floor below.
function ENT:SurfaceDistance(point)
	local to = point - self:GetPos()
	return (to - self.BodyUp * to:Dot(self.BodyUp)):Length()
end

function ENT:Reached(point)
	return self:SurfaceDistance(point) < REACHED
end

function ENT:Feels(ent, pos)
	if not Perceivable(ent) then return false end
	local d = ent:WorldSpaceCenter():Distance(pos)
	if d < TOUCH_RANGE then return true, d end
	if d < TREMOR_RANGE and ent:IsOnGround() and ent:GetVelocity():Length() > TREMOR_SPEED then
		return not self:Trace(pos, ent:WorldSpaceCenter()).Hit, d
	end
	return false
end

-- What it can feel directly, by touch or tremor: the nearest NPC it could
-- eat if it's hungry, otherwise the nearest player.
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

-- How strongly a bit of scent draws it.
function ENT:Appeal(node, now)
	local w = 1
	if node.npc then w = self:IsHungry() and HUNGRY_PULL or FED_PULL end
	if node.fear then w = math.max(w, 1) * FEAR_PULL end
	if self.Grudge and node.trail.owner == self.Grudge then w = math.max(w, 1) * GRUDGE_PULL end
	return Scent.Intensity(node, now) * w
end

-- Walks a trail toward fresher scent, past every node already reached or
-- close enough to head for directly.
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

-- A random spot around `center`, flattened onto the surface the body is on.
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
	self:Cool(now)
	if self:LyingLow(now) then return end

	self.Puppeting = cv_puppet:GetBool()
	if self.Puppeting then
		self.Goal = self:PuppetGoal()
		self.Pace = 0.4
		-- steer it into an NPC to test the kill
		for npc in pairs(Scent.npcs) do
			if IsValid(npc) and self:CanAttack(npc) then
				self:StartStrike(npc)
				return
			end
		end
		return
	end

	-- 1. direct contact beats everything
	local prey = self:Sense()
	self:SetPrey(prey or NULL)
	if prey then
		if self:CanAttack(prey) then
			self:StartStrike(prey)
			return
		end
		self:SetState("hunt")
		self.Goal = prey:GetPos()
		self.LastKnown = prey:GetPos()
		-- hanging from the ceiling right over them: drop
		if self.BodyUp.z < -0.5 and self:Reached(prey:GetPos()) then
			self.LetGoUntil = now + 0.4
		end
		return
	end
	if self.State == "hunt" then
		self:SetState("search")
		self.Goal = self.LastKnown
		self.SearchUntil = now + SEARCH_TIME
	end

	-- 2. a scent trail: stay on the current one unless a much fresher one crosses it
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
			-- end of the trail and nobody here: they're close, keep feeling around
			self.Goal = self:Around(node.pos, 150)
		end
		return
	end
	self.Trail = nil

	-- 3. lost them: comb the area where they were last felt
	if self.State == "search" and now < self.SearchUntil then
		if self:Reached(self.Goal) then self.Goal = self:Around(self.LastKnown, SEARCH_SPREAD) end
		return
	end

	-- 4. nothing: wander, holding a heading for a while
	if self.State ~= "roam" or now > (self.NextVeer or 0) then
		self.Heading = VectorRand():GetNormalized()
		self.NextVeer = now + math.Rand(4, 9)
	end
	self:SetState("roam")
	self.Goal = pos + self.Heading * 1000
end

-- Not getting any closer: on a ceiling it lets go and drops, anywhere else
-- it veers off sideways for a moment.
function ENT:CheckProgress(now)
	if not self.Goal then return end

	if not self.ProgressGoal or self.ProgressGoal:Distance(self.Goal) > 100 then
		self.ProgressGoal, self.BestDist, self.ProgressTime = self.Goal, math.huge, now
	end

	if self.Still then
		self.ProgressTime = now -- holding still isn't being stuck
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
			self.Detour = self:Around(self:GetPos(), 1) - self:GetPos()
			self.Detour = self.Detour:GetNormalized() * 400
			self.DetourUntil = now + 1.5
		end
	end
end

-- Starts and stops the fits: a dart, then still, then another.
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

-- Where to crawl right now, how fast, and how sharply to get going: the
-- goal, unless it's detouring or holding still.
function ENT:Steer()
	local now = CurTime()
	if now >= (self.NextThought or 0) then
		self.NextThought = now + ((self.Pace or 0) > 0.3 and QUICK_INTERVAL or THINK_INTERVAL)
		self:Ponder()
		self:CheckProgress(now)
		if cv_debug:GetBool() and self.Goal then
			local c = STATE_COLOR[self.State] or color_white
			debugoverlay.Line(self:GetPos(), self.Goal, THINK_INTERVAL, c, true)
			debugoverlay.Text(self:GetPos() + self.BodyUp * 40, self.State or "puppet", THINK_INTERVAL)
		end
	end

	local burst = cv_burst:GetFloat()
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

function ENT:OnTakeDamage(dmg)
	if dmg:GetDamage() <= 0 then return end
	self:Hurt(dmg:GetAttacker(), dmg:GetDamagePosition())
end

-- Shot, stabbed, blown up: it lets go of whatever it has and runs.
function ENT:Hurt(attacker, from)
	local now = CurTime()

	if now >= (self.NextPain or 0) then
		self.NextPain = now + 1.5
		self:EmitSound(PAIN_SOUNDS[math.random(#PAIN_SOUNDS)], 85, math.random(135, 155))
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

-- Where a shot from `src` along `dir` first meets the legs, and how far
-- along, if it does before `range` and nothing else is in the way. The legs
-- are only drawn on clients, so the server counts a ball round the tangle.
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

-- Bullets are caught by hand: the legs have no collision of their own.
hook.Add("EntityFireBullets", "EvilCrawlerShot", function(shooter, data)
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

	-- the bullet stops in the legs
	data.Distance = nearest
	return true
end)

-- Running, then hiding until it's sure. True while it wants nothing else.
function ENT:LyingLow(now)
	if self.State == "flee" then
		if self.Goal and not self:Reached(self.Goal) and now < self.FleeUntil then return true end
		self:SetState("hide")
		self.HideUntil = now + math.Rand(HIDE_TIME[1], HIDE_TIME[2])
	end
	if self.State ~= "hide" then return false end
	if now < self.HideUntil then
		self.Goal = nil
		return true
	end
	self:SetState("roam")
	return false
end

-- Someone's hurt it: it's angrier for a while, and it remembers who.
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

-- Debug: crawl to wherever the spawner is looking.
function ENT:PuppetGoal()
	local ply = self.Master
	if not IsValid(ply) then return end

	local eye = ply:EyePos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * 4096, filter = { ply, self } })
	if tr.Hit then return tr.HitPos end
end
