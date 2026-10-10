include("shared.lua")
include("evil_crawler/cl_flesh.lua")

local cv_debug = CreateClientConVar("evil_crawler_debug", "0", false, false, "Draw foot targets")

local LEAD_TIME = 0.18 -- feet aim this far ahead along the body's velocity
local SNAP_GAP = 0.5 -- seconds without an update before limbs are re-planted from scratch
local MAX_AIRBORNE = 0.4 -- share of legs allowed mid-step at once
local MOOD_AGITATION = { [0] = 0, [1] = 0.45, [2] = 1 } -- calm, on a scent, in contact
local THREAT_ARC = 35 -- legs pointing within this many degrees of a player rear up at them
local IK_ITERATIONS = 3
local LOD_DISTANCE = 1500

local ACT_NONE, ACT_STRIKE, ACT_DRAG, ACT_FEED =
	EvilCrawler.ACT_NONE, EvilCrawler.ACT_STRIKE, EvilCrawler.ACT_DRAG, EvilCrawler.ACT_FEED
local WINDUP, LUNGE, WRAP_TIME = EvilCrawler.STRIKE_WINDUP, EvilCrawler.STRIKE_LUNGE, EvilCrawler.WRAP_TIME
local PULL_TIME = EvilCrawler.PULL_TIME
-- legs put to work per act; the first one holds the body while dragging and feeding
local ROLE_COUNT = { [ACT_STRIKE] = 1, [ACT_DRAG] = 1, [ACT_FEED] = 5 }
local COIL_POINTS = 26 -- a coiled leg is drawn through this many points
local REACH_POINTS = 8 -- of which this many reach from the root to the victim

local FOOT_SOUNDS = {
	"npc/antlion/foot1.wav",
	"npc/antlion/foot2.wav",
	"npc/antlion/foot3.wav",
	"npc/antlion/foot4.wav",
}

local FLESH = Color(44, 34, 40)
local BONE = Color(170, 160, 145)
local DEBUG_TARGET = Color(0, 255, 0)
local DEBUG_DANGLE = Color(255, 160, 0)

local Flesh = EvilCrawler.Flesh
local SolveChain = EvilCrawler.SolveChain
local CatmullRom = Flesh.CatmullRom

function ENT:Initialize()
	self:SetRenderBounds(Vector(-400, -400, -400), Vector(400, 400, 400))
	self:DestroyShadow()
end

function ENT:Creature()
	local seed = self:GetSeed()
	if seed == 0 then return end

	if self.GrownFrom ~= seed then
		self.GrownFrom = seed
		self.Morph = EvilCrawler.Grow(seed)
		self.BodyHeight = self.Morph.height
		self.LimbState = nil
	end
	return self.Morph
end

local function Wobble(t, phase, freq)
	return Vector(
		math.sin(t * freq + phase) + 0.5 * math.sin(t * freq * 2.3 + phase * 1.7),
		math.sin(t * freq * 1.3 + phase * 2.1) + 0.5 * math.sin(t * freq * 2.9 + phase),
		math.sin(t * freq * 0.9 + phase * 3.3) + 0.5 * math.sin(t * freq * 3.1 + phase * 0.6)
	)
end

local function Smooth(t)
	return t * t * (3 - 2 * t)
end

-- Lays the chain out as an arch from root to target bulging along `bow`,
-- shaken by noise and twitches, then lets FABRIK pull it to exact lengths.
local function Pose(st, limb, root, target, bow, t, shake)
	local pts = st.points
	local n = limb.segments + 1
	local wobble = limb.length * shake
	for i = 1, n do
		local f = (i - 1) / (n - 1)
		local arch = math.sin(f * math.pi)
		local noise = Wobble(t, limb.phase + i * 1.9, limb.freq) * wobble + st.twitch
		pts[i] = LerpVector(f, root, target) + (bow + noise) * arch
	end
	SolveChain(pts, limb.lengths, root, target, IK_ITERATIONS)
end

-- Smooth curve through a joint chain, resampled to m points.
local function Resample(pts, m, out)
	local n = #pts
	for i = 1, m do
		local u = (i - 1) / (m - 1) * (n - 1)
		local seg = math.min(math.floor(u), n - 2)
		local s = seg + 1
		out[i] = CatmullRom(pts[math.max(s - 1, 1)], pts[s], pts[s + 1], pts[math.min(s + 2, n)], u - seg)
	end
	return out
end

local function Bone(ent, name)
	local bone = ent:LookupBone(name)
	return bone and ent:GetBonePosition(bone)
end

local function Chest(ent)
	return Bone(ent, "ValveBiped.Bip01_Spine2") or ent:WorldSpaceCenter()
end

-- Picks the legs nearest the victim for the job at hand. The leg that struck
-- keeps hold of the body it struck.
function ENT:AssignRoles(morph, act, victim, pos, fwd, left)
	local roles = {}
	if act == ACT_NONE or not IsValid(victim) then return roles end

	local d = victim:WorldSpaceCenter() - pos
	local yaw = math.deg(math.atan2(d:Dot(left), d:Dot(fwd)))
	local order = { unpack(morph.legs) } -- the legs themselves, not copies
	table.sort(order, function(a, b)
		return math.abs(math.AngleDifference(a.angle, yaw)) < math.abs(math.AngleDifference(b.angle, yaw))
	end)
	if act == ACT_STRIKE then
		self.Striker = order[1]
	elseif self.Striker then
		table.RemoveByValue(order, self.Striker)
		table.insert(order, 1, self.Striker)
	end

	local count = math.min(ROLE_COUNT[act], #order - 3)
	for k = 1, count do
		roles[order[k]] = { index = k, count = count, bone = math.random(0, math.max(0, victim:GetBoneCount() - 1)) }
	end
	return roles
end

-- Where the holding leg coils on the body: round the torso, as an axis to
-- wrap round and a radius.
local function GripAxis(body)
	local pelvis = Bone(body, "ValveBiped.Bip01_Pelvis")
	local neck = Bone(body, "ValveBiped.Bip01_Neck1")
	if pelvis and neck then return pelvis, neck, 9 end
	local c = body:WorldSpaceCenter()
	return c - vector_up * 14, c + vector_up * 14, 9
end

-- A leg wrapped round the body: an arch from the root to the near end of the
-- axis, then a helix climbing to the far end over WRAP_TIME.
local function Coil(st, leg, role, root, a, b, r, bulge, t)
	if root:DistToSqr(b) < root:DistToSqr(a) then a, b = b, a end
	local axis = b - a
	local span = axis:Length()
	axis = axis / math.max(span, 1)
	local u = axis:Cross(bulge)
	if u:LengthSqr() < 1e-4 then u = axis:Angle():Right() end
	u:Normalize()
	local v = axis:Cross(u)

	r = r + leg.width * 0.6
	local climb = math.Clamp(t / WRAP_TIME, 0, 1)
	local turns = 2 + (leg.phase % 1) * 0.8
	local spin = role.index % 2 == 0 and 1 or -1
	local theta0 = leg.phase

	local entry = a + (u * math.cos(theta0) + v * math.sin(theta0)) * r
	local mid = (root + entry) * 0.5 + bulge * (root:Distance(entry) * 0.3)

	local pts = st.coil or {}
	st.coil = pts
	for i = 1, REACH_POINTS do
		local f = (i - 1) / REACH_POINTS
		pts[i] = root * ((1 - f) ^ 2) + mid * (2 * (1 - f) * f) + entry * (f * f)
	end

	local helix = COIL_POINTS - REACH_POINTS
	for i = 0, helix - 1 do
		local f = i / (helix - 1) * climb
		local theta = theta0 + spin * f * turns * math.pi * 2
		pts[REACH_POINTS + 1 + i] = a + axis * (span * f) + (u * math.cos(theta) + v * math.sin(theta)) * r
	end
end

-- Where a foot should land: whatever is between root and rest spot (a wall
-- ahead), else the ground under the rest spot, else the face of an edge the
-- body is hanging over. Falls back to a dangling pose.
function ENT:FootTarget(root, rest, up)
	local h = self.BodyHeight

	local reach = self:Trace(root, rest)
	if reach.Hit then return reach.HitPos, true end

	local down = self:Trace(rest, rest - up * (h * 1.6))
	if down.Hit then return down.HitPos, true end

	local back = self:Trace(rest - up * (h + 12), root - up * (h + 12))
	if back.Hit then return back.HitPos, true end

	return rest - up * (h * 0.6), false
end

function ENT:NeighboursPlanted(leg)
	for _, other in ipairs(leg.neighbours) do
		local st = self.LimbState[other]
		if st and st.stepping then return false end
	end
	return true
end

function ENT:UpdateLimbs()
	local morph = self:Creature()
	if not morph then return end

	local now = UnPredictedCurTime()
	local dt = now - (self.LastLimbUpdate or 0)
	if dt <= 0 then return end
	self.LastLimbUpdate = now

	local pos, ang = self:GetPos(), self:GetAngles()

	if not self.LimbState or dt > SNAP_GAP then
		self.LimbState = {}
		self.SmoothVel = Vector()
		self.LastPos = pos
		self.Churn = 0
		self.Agitation = 0
	end

	self.SmoothVel = LerpVector(math.min(1, dt * 10), self.SmoothVel, (pos - self.LastPos) / dt)
	self.LastPos = pos
	local speed = self.SmoothVel:Length()

	-- worked up by what the server-side brain is doing
	local prey = self:GetPrey()
	local feel = IsValid(prey) and prey:EyePos()
	if feel then self.LastFeel = feel end -- so reared legs ease back down after losing them
	self.Agitation = math.Approach(self.Agitation, MOOD_AGITATION[self:GetMood()] or 0, dt * 0.8)
	local agit = self.Agitation

	local act, victim, actStart = self:GetAct(), self:GetVictim(), self:GetActStart()

	-- the tangle keeps turning over on itself, whichever way it's heading,
	-- except while its legs are busy with a victim
	if act == ACT_NONE then
		self.Churn = self.Churn + dt * morph.churn * (1 + math.sin(now * 0.3 + morph.phase)) * (1 + 2 * agit)
	end
	ang:RotateAroundAxis(ang:Up(), self.Churn)

	local fwd, left, up = ang:Forward(), -ang:Right(), ang:Up()

	if self.RolesAct ~= act or self.RolesStart ~= actStart or self.RolesVictim ~= victim then
		self.RolesAct, self.RolesStart, self.RolesVictim = act, actStart, victim
		self.Roles = self:AssignRoles(morph, act, victim, pos, fwd, left)
	end
	local function toWorld(v) return pos + fwd * v.x + left * v.y + up * v.z end

	local lead = self.SmoothVel * LEAD_TIME
	local hurry = math.Clamp(1 - speed * 0.0015, 0.45, 1)
	local shake = 0.04 + 0.04 * agit
	local twitchRate = 0.2 + 1.2 * agit

	local threatYaw
	if feel and agit > 0.5 and speed < 60 then
		local d = feel - pos
		threatYaw = math.deg(math.atan2(d:Dot(left), d:Dot(fwd)))
	end

	local airborne, maxAirborne = 0, math.ceil(#morph.legs * MAX_AIRBORNE)
	for _, leg in ipairs(morph.legs) do
		local st = self.LimbState[leg]
		if st and st.stepping then airborne = airborne + 1 end
	end

	for _, limb in ipairs(morph.legs) do
		local st = self.LimbState[limb]
		if not st then
			st = { points = {}, twitch = Vector(), raise = 0, wrap = 0 }
			self.LimbState[limb] = st
		end

		st.twitch = st.twitch * math.exp(-dt * 7)
		if math.random() < dt * twitchRate then
			st.twitch = VectorRand() * limb.length * 0.2
		end

		local root = toWorld(limb.root)

		local yaw = math.rad(limb.angle)
		local rest = pos + (fwd * math.cos(yaw) + left * math.sin(yaw)) * (limb.length * limb.spread) + lead
		local target, grounded = self:FootTarget(root, rest, up)
		if not grounded then
			target = target + Wobble(now * 2, limb.phase, limb.freq) * limb.length * 0.2
		end
		st.target, st.grounded = target, grounded
		st.foot = st.foot or target

		-- legs put to work on the victim are done walking: they drop out of
		-- the gait until they let go, then step back in from wherever they are.
		-- The feeding legs wait for the body to be hauled in first.
		local role = self.Roles[limb]
		if role and (not IsValid(victim) or (act == ACT_FEED and role.index > 1 and now - actStart < PULL_TIME)) then
			role = nil
		end
		if role and st.stepping then
			st.stepping = false
			airborne = airborne - 1
		end

		local threatened = threatYaw and not role and not st.stepping
			and math.abs(math.AngleDifference(limb.angle, threatYaw)) < THREAT_ARC
		st.raise = math.Approach(st.raise, threatened and 1 or 0, dt * 2.5)

		if role then
			-- busy with the victim
		elseif st.stepping then
			st.t = st.t + dt / (limb.stepTime * hurry)
			if st.t >= 1 then
				st.stepping = false
				st.foot = target
				airborne = airborne - 1
				if grounded then
					local snd = FOOT_SOUNDS[math.random(#FOOT_SOUNDS)]
					sound.Play(snd, target, 65, limb.pitch + math.random(-10, 10), 0.35)
				end
			end
		elseif st.raise > 0 then
			-- rearing: hold the planted spot to come back down onto
		elseif not grounded then
			st.foot = LerpVector(math.min(1, dt * 6), st.foot, target)
		else
			local drift = st.foot:Distance(target)
			local overreach = st.foot:Distance(root) > limb.length * 0.97
			if overreach or (drift > limb.stepDistance and airborne < maxAirborne and self:NeighboursPlanted(limb)) then
				st.stepping, st.t, st.from = true, 0, st.foot
				airborne = airborne + 1
			end
		end

		local foot = st.foot
		if st.stepping then
			local t = st.t
			foot = LerpVector(Smooth(t), st.from, target) + up * (math.sin(t * math.pi) * limb.stepHeight)
		end
		if st.raise > 0 and self.LastFeel then
			local aim = root + (self.LastFeel - root):GetNormalized() * (limb.length * 0.75) + up * (limb.length * 0.25)
				+ Wobble(now * 3, limb.phase, limb.freq) * (limb.length * 0.04)
			foot = LerpVector(Smooth(st.raise), foot, aim)
		end

		-- legs put to work: striking, holding the body, or picking at it
		local holding = role and (act == ACT_DRAG or act == ACT_FEED) and role.index == 1
		if role then
			if act == ACT_STRIKE then
				-- rear up and back from the victim, trembling, then whip through it
				local t = now - actStart
				local chest = Chest(victim)
				local away = root - chest
				away = (away - up * away:Dot(up)):GetNormalized()
				local cocked = root + up * (limb.length * 0.55) + away * (limb.length * 0.2)
					+ Wobble(now * 9, limb.phase, limb.freq) * (limb.length * 0.015)
				if t < WINDUP then
					foot = LerpVector(Smooth(t / WINDUP), foot, cocked)
				else
					local f = math.min(1, (t - WINDUP) / LUNGE)
					foot = LerpVector(f * f, cocked, chest + (chest - root):GetNormalized() * 8)
				end
			elseif holding then
				foot = Chest(victim)
			elseif act == ACT_FEED then
				local meat = victim:GetBonePosition(role.bone) or victim:WorldSpaceCenter()
				local lift = 0.5 + 0.5 * math.cos((now * (1.2 + role.index * 0.37) + role.index) * math.pi * 2)
				foot = meat + (root - meat):GetNormalized() * (lift * 35)
			end
		end

		Pose(st, limb, root, foot, up * (limb.length * 0.35), now, shake)

		if holding and not st.holdSince then st.holdSince = now end
		if not holding then st.holdSince = nil end
		if holding then
			local a, b, r = GripAxis(victim)
			Coil(st, limb, role, root, a, b, r, up, now - st.holdSince)
		end
		st.wrap = math.Approach(st.wrap, holding and 1 or 0, dt * (holding and 12 or 2.5))
	end
end

-- Thick at the root, knuckled at each joint, tapering to a hooked point.
local function LimbRadius(f, limb)
	local r = limb.width * (1 - 0.9 * f ^ 1.3)
	for k = 1, limb.segments - 1 do
		local d = (f - k / limb.segments) / 0.035
		r = r + limb.width * 0.12 * math.exp(-d * d)
	end
	return r
end

local function LimbColor(f, limb)
	local k = f ^ 3
	local b = limb.shade
	return Lerp(k, FLESH.r, BONE.r) * b, Lerp(k, FLESH.g, BONE.g) * b, Lerp(k, FLESH.b, BONE.b) * b
end

function ENT:Draw()
	self:UpdateLimbs()
	local morph = self.Morph
	if not morph or not self.LimbState then return end

	local pos = self:GetPos()
	local near = EyePos():DistToSqr(pos) < LOD_DISTANCE * LOD_DISTANCE
	local sides, sub = near and 6 or 4, near and 3 or 1

	Flesh.SampleLight(pos)
	render.SetMaterial(Flesh.Material)

	for _, limb in ipairs(morph.legs) do
		local st = self.LimbState[limb]
		if st.wrap > 0 and st.coil then
			-- blend between the walking pose and the coil
			local pts = Resample(st.points, COIL_POINTS, st.display or {})
			st.display = pts
			local b = Smooth(st.wrap)
			for i = 1, COIL_POINTS do pts[i] = LerpVector(b, pts[i], st.coil[i]) end
			Flesh.Tube(pts, sides, 1, LimbRadius, LimbColor, limb)
		else
			Flesh.Tube(st.points, sides, sub, LimbRadius, LimbColor, limb)
		end
	end

	if cv_debug:GetBool() then
		for _, leg in ipairs(morph.legs) do
			local st = self.LimbState[leg]
			local c = st.grounded and DEBUG_TARGET or DEBUG_DANGLE
			render.DrawWireframeSphere(st.target, 3, 4, 4, c, true)
		end
	end
end
