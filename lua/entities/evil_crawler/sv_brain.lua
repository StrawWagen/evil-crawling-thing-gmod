-- What the crawler wants. It has no eyes. It knows players and NPCs three ways:
--   touch   anyone close enough, whatever they're doing
--   tremor  players running on the ground with nothing solid in between
--   scent   the trails everyone leaves (sv_scent.lua), followed toward
--           fresher scent
-- Hungry, it goes for NPCs it can kill (sv_attack.lua) over players, which it
-- only stalks.
-- Each thought sets self.Goal (a point to crawl toward) and self.Pace (a
-- share of top speed); Crawl does the moving.

local Scent = EvilCrawler.Scent

local cv_puppet = CreateConVar("evil_crawler_puppet", "0", 0, "Crawlers follow their spawner's crosshair instead of thinking")
local cv_debug = CreateConVar("evil_crawler_debug_scent", "0", 0, "Draw scent trails (needs developer 1)")
local ai_ignoreplayers = GetConVar("ai_ignoreplayers")

local THINK_INTERVAL = 0.25
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

local PACE = { roam = 0.45, search = 0.6, track = 0.85, hunt = 1.25, constrict = 0, drag = 0.7, feed = 0 }
local MOOD = { roam = 0, search = 1, track = 1, hunt = 2, constrict = 2, drag = 1, feed = 1 }
local STATE_COLOR = { roam = Color(120, 120, 120), search = Color(255, 200, 0), track = Color(255, 120, 0), hunt = Color(255, 0, 0) }

local function Perceivable(ent)
	if ent:IsFlagSet(FL_NOTARGET) then return false end
	if ent:IsNPC() then return ent:Health() > 0 and not ent.EvilCrawlerVictim end
	return ent:Alive()
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
	self.State = state
	self.Pace = PACE[state]
	self:SetMood(MOOD[state])
end

function ENT:Ponder()
	local now = CurTime()
	local pos = self:GetPos()

	if self:GetAct() ~= EvilCrawler.ACT_NONE then
		self:PonderAct(now)
		return
	end

	self.Puppeting = cv_puppet:GetBool()
	if self.Puppeting then
		self.Goal = self:PuppetGoal()
		self.Pace = 1
		-- steer it into an NPC to test the kill
		for npc in pairs(Scent.npcs) do
			if IsValid(npc) and self:CanAttack(npc) then
				self:StartConstrict(npc)
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
			self:StartConstrict(prey)
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
	if node and (node.dead or Scent.Intensity(node, now) < SCENT_THRESHOLD * 0.5) then node = nil end
	local whiff, strength = Scent.Strongest(pos, SNIFF_RADIUS, now)
	if whiff and strength >= SCENT_THRESHOLD and (not node or strength > Scent.Intensity(node, now) * 1.5) then
		node = whiff
	end

	if node then
		node = self:FollowTrail(node)
		self.Trail = node
		self:SetState("track")
		self.Pace = Lerp(math.min(1, Scent.Intensity(node, now)), 0.6, 1)
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

-- Where to crawl right now: the goal, unless it's detouring.
function ENT:Steer()
	local now = CurTime()
	if now >= (self.NextThought or 0) then
		self.NextThought = now + THINK_INTERVAL
		self:Ponder()
		self:CheckProgress(now)
		if cv_debug:GetBool() and self.Goal then
			local c = STATE_COLOR[self.State] or color_white
			debugoverlay.Line(self:GetPos(), self.Goal, THINK_INTERVAL, c, true)
			debugoverlay.Text(self:GetPos() + self.BodyUp * 40, self.State or "puppet", THINK_INTERVAL)
		end
	end

	if self.DetourUntil and now < self.DetourUntil then
		return self:GetPos() + self.Detour, self.Pace
	end
	return self.Goal, self.Pace or 0
end

-- Debug: crawl to wherever the spawner is looking.
function ENT:PuppetGoal()
	local ply = self.Master
	if not IsValid(ply) then return end

	local eye = ply:EyePos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * 4096, filter = { ply, self } })
	if tr.Hit then return tr.HitPos end
end
