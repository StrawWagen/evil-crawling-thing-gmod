include("shared.lua")
include("evil_crawler/cl_flesh.lua")
include("evil_crawler/cl_remains.lua")
include("evil_crawler/cl_struggle.lua")

local cv_debug = CreateClientConVar("evil_crawler_debug", "0", false, false, "Draw foot targets")

local LEAD_TIME = 0.18 -- feet aim this far ahead along the body's velocity
local SNAP_GAP = 0.5 -- seconds without an update before limbs are re-planted from scratch
local MAX_AIRBORNE = 0.4 -- share of legs allowed mid-step at once
local SKITTER = { 400, 1000, 0.6 } -- between these speeds steps quicken in proportion, go low, and up to this share of legs is up at once
local MAX_LEAD = 0.9 -- feet never aim more than this many body heights ahead
local FOOT_SOUND_GAP = 0.03 -- a skitter is a clatter, not a hundred sounds at once
local MOOD_AGITATION = { [0] = 0, [1] = 0.45, [2] = 1 } -- calm, on a scent, in contact
local THREAT_ARC = 35 -- legs pointing within this many degrees of a player rear up at them
local IK_ITERATIONS = 3
local LOD_DISTANCE = 1500

local ACT_NONE, ACT_STRIKE, ACT_DRAG, ACT_FEED =
	EvilCrawler.ACT_NONE, EvilCrawler.ACT_STRIKE, EvilCrawler.ACT_DRAG, EvilCrawler.ACT_FEED
local ACT_GRAPPLE, ACT_STUN = EvilCrawler.ACT_GRAPPLE, EvilCrawler.ACT_STUN
local STUN_TIME = EvilCrawler.STUN_TIME
local WINDUP, LUNGE, WRAP_TIME = EvilCrawler.STRIKE_WINDUP, EvilCrawler.STRIKE_LUNGE, EvilCrawler.WRAP_TIME
local PULL_TIME = EvilCrawler.PULL_TIME
local BITE_JAB, BITE_IN, BITE_RIP = EvilCrawler.BITE_JAB, EvilCrawler.BITE_IN, EvilCrawler.BITE_RIP
local LUMP_TIME = EvilCrawler.LUMP_TIME
local BiteCycle, BiteBone, CurrentPart = EvilCrawler.BiteCycle, EvilCrawler.BiteBone, EvilCrawler.CurrentPart
local STAB_DEPTH = 10 -- how far into the body a stab sinks
local SWALLOW_GAP = { 1.2, 2.2 } -- seconds between swallows down the holding leg
-- legs put to work per act; the first one holds the body while dragging and feeding
local ROLE_COUNT = { [ACT_STRIKE] = 1, [ACT_DRAG] = 1, [ACT_FEED] = 1 + EvilCrawler.FEEDERS, [ACT_GRAPPLE] = 1 }
local CURL = 0.25 -- stunned, legs draw in to this share of where they were
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
local BLOOD = Color(80, 6, 8)
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

-- A player's own bones aren't set up while they're in first person, so
-- players are measured from their feet.
local PLAYER_CHEST = Vector(0, 0, 46)
local PLAYER_COIL = { Vector(0, 0, 12), Vector(0, 0, 58), 11 } -- round them from shins to chin, arms and all

local function Chest(ent)
	if ent:IsPlayer() then return ent:GetPos() + PLAYER_CHEST end
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

	local count = math.min(ROLE_COUNT[act] or 0, #order - 3)
	for k = 1, count do
		roles[order[k]] = { index = k, count = count }
	end
	return roles
end

-- Where feeding leg k is during its bite cycle: rearing over the next part
-- of the body, trembling, then stabbing down into it, worrying at it, and
-- tearing back out. Also says which bite it's on and how far through.
-- `bites` remembers which bone each bite went for, so a leg mid-bite keeps
-- at it when the part it's on is finished.
local function BitePose(victim, seed, k, t, up, now, limb, bites)
	local n, u = BiteCycle(k, t)
	local center = victim:WorldSpaceCenter()
	local part = CurrentPart(victim)

	-- the legs come at the same part from all round it
	local function spot(m)
		local name = bites[m]
		if not name then
			name = BiteBone(seed, k, m, part)
			bites[m] = name
		end
		local p = Bone(victim, name) or center
		local side = p - center
		side = side - up * side:Dot(up)
		side = side:LengthSqr() > 1 and side:GetNormalized() or up:Angle():Right()
		local a = k * math.pi * 0.5 + m * 0.6
		side = side * math.cos(a) + up:Cross(side) * math.sin(a)
		return p + side * 3, p + up * 45 + side * 12, side -- the bite, where the leg tears out to, and which side it's on
	end

	local bite, out, side = spot(n)
	local _, from = spot(n - 1)
	bites[n - 3] = nil
	local cocked = bite + up * 38 + side * 14
	local deep = bite + (bite - cocked):GetNormalized() * STAB_DEPTH

	if u < BITE_JAB then
		local f = u / BITE_JAB
		return LerpVector(Smooth(f), from, cocked) + Wobble(now * 11, limb.phase, limb.freq) * (2.5 * f), n, u
	elseif u < BITE_IN then
		local f = (u - BITE_JAB) / (BITE_IN - BITE_JAB)
		return LerpVector(f * f, cocked, deep), n, u
	elseif u < BITE_RIP then
		return deep + Wobble(now * 30, limb.phase, limb.freq) * 1.5, n, u
	end
	local f = (u - BITE_RIP) / (1 - BITE_RIP)
	return LerpVector(1 - (1 - f) ^ 3, deep, out), n, u
end

-- Where the holding leg coils on the body: round the torso, or once it's
-- being eaten, round what's left of it from the mouth down, as an axis to
-- wrap round and a radius.
local function GripAxis(body)
	if body:IsPlayer() then
		local feet = body:GetPos()
		return feet + PLAYER_COIL[1], feet + PLAYER_COIL[2], PLAYER_COIL[3]
	end
	local part = CurrentPart(body)
	if part and part > 1 then
		local top = Bone(body, EvilCrawler.PARTS[part].grip[1])
		local lf, rf = Bone(body, "ValveBiped.Bip01_L_Foot"), Bone(body, "ValveBiped.Bip01_R_Foot")
		if top and lf and rf then return top, (lf + rf) * 0.5, 7 end
	end
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

	self.SmoothVel = LerpVector(math.min(1, dt * 20), self.SmoothVel, (pos - self.LastPos) / dt)
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
	local maxLead = self.BodyHeight * MAX_LEAD
	if lead:LengthSqr() > maxLead * maxLead then lead = lead:GetNormalized() * maxLead end
	local skitter = math.Clamp((speed - SKITTER[1]) / (SKITTER[2] - SKITTER[1]), 0, 1)
	local hurry = math.Clamp(1 - speed * 0.0015, 0.45, 1) * math.min(1, SKITTER[1] / math.max(speed, 1))
	local low = 1 - 0.65 * skitter
	local loud = math.Clamp(speed / SKITTER[2], 0, 1)
	local shake = 0.04 + 0.04 * agit
	local twitchRate = 0.2 + 1.2 * agit

	local threatYaw
	if feel and agit > 0.5 and speed < 60 then
		local d = feel - pos
		threatYaw = math.deg(math.atan2(d:Dot(left), d:Dot(fwd)))
	end

	local airborne, maxAirborne = 0, math.ceil(#morph.legs * Lerp(skitter, MAX_AIRBORNE, SKITTER[3]))
	for _, leg in ipairs(morph.legs) do
		local st = self.LimbState[leg]
		if st and st.stepping then airborne = airborne + 1 end
	end

	for _, limb in ipairs(morph.legs) do
		local st = self.LimbState[limb]
		if not st then
			st = { points = {}, twitch = Vector(), raise = 0, wrap = 0, lumps = {}, blood = 0 }
			self.LimbState[limb] = st
		end
		st.lumps, st.blood = st.lumps or {}, st.blood or 0 -- survives a lua refresh mid-game

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
				if grounded and now >= (self.NextFootSound or 0) then
					self.NextFootSound = now + FOOT_SOUND_GAP
					local snd = FOOT_SOUNDS[math.random(#FOOT_SOUNDS)]
					sound.Play(snd, target, 65 + 12 * loud, limb.pitch + math.random(-10, 10) + 15 * loud, 0.35 + 0.4 * loud)
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
			foot = LerpVector(Smooth(t), st.from, target) + up * (math.sin(t * math.pi) * limb.stepHeight * low)
		end
		if st.raise > 0 and self.LastFeel then
			local aim = root + (self.LastFeel - root):GetNormalized() * (limb.length * 0.75) + up * (limb.length * 0.25)
				+ Wobble(now * 3, limb.phase, limb.freq) * (limb.length * 0.04)
			foot = LerpVector(Smooth(st.raise), foot, aim)
		end

		-- stunned: every leg snatched in tight under it, shuddering, then
		-- slowly letting go
		if act == ACT_STUN then
			local t = now - actStart
			local k = Smooth(math.Clamp(t / 0.12, 0, 1)) * Smooth(math.Clamp((STUN_TIME - t) / 0.8, 0, 1))
			local curled = root + (foot - root) * CURL - up * (limb.length * 0.1)
				+ Wobble(now * 26, limb.phase, limb.freq) * (limb.length * 0.04 * k)
			foot = LerpVector(k, foot, curled)
		end

		-- legs put to work: striking, holding the body, or picking at it
		local holding = role and (act == ACT_DRAG or act == ACT_FEED or act == ACT_GRAPPLE) and role.index == 1
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
				st.bites = st.bites or {}
				local bite, n, u = BitePose(victim, self:GetSeed(), role.index - 1, now - actStart - PULL_TIME, up, now, limb, st.bites)
				st.work = math.Approach(st.work or 0, 1, dt * 3)
				foot = LerpVector(Smooth(st.work), foot, bite)
				-- blood on the point once it's been in, and a piece going up the leg each tear
				local stage = u < BITE_IN and 0 or u < BITE_RIP and 1 or 2
				if st.biteN == n and st.biteStage ~= stage then
					if stage == 1 then st.blood = 1 end
					if stage == 2 then st.lumps[#st.lumps + 1] = now end
				end
				st.biteN, st.biteStage = n, stage
			end
		end
		if not (role and act == ACT_FEED) then st.work, st.bites = 0, nil end

		-- the holding leg swallows too, every so often
		if act == ACT_FEED and role and role.index == 1 and now - actStart > PULL_TIME then
			if now >= (st.nextSwallow or 0) then
				if st.nextSwallow then st.lumps[#st.lumps + 1] = now end
				st.nextSwallow = now + math.Rand(SWALLOW_GAP[1], SWALLOW_GAP[2])
			end
		else
			st.nextSwallow = nil
		end
		while st.lumps[1] and now - st.lumps[1] > LUMP_TIME do table.remove(st.lumps, 1) end
		st.blood = math.max(0, st.blood - dt * 0.02)

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

-- The leg being drawn: what it's swallowing, and how bloody it is.
local drawing, drawNow

-- Thick at the root, knuckled at each joint, tapering to a hooked point,
-- swelling where a swallowed piece is working its way up to the root.
local function LimbRadius(f, limb)
	local r = limb.width * (1 - 0.9 * f ^ 1.3)
	for k = 1, limb.segments - 1 do
		local d = (f - k / limb.segments) / 0.035
		r = r + limb.width * 0.12 * math.exp(-d * d)
	end
	for _, born in ipairs(drawing.lumps) do
		local d = (f - (1 - (drawNow - born) / LUMP_TIME)) / 0.07
		r = r + limb.width * 0.9 * math.exp(-d * d)
	end
	return r
end

local function LimbColor(f, limb)
	local k = f ^ 3
	local b = limb.shade
	local r, g, bl = Lerp(k, FLESH.r, BONE.r), Lerp(k, FLESH.g, BONE.g), Lerp(k, FLESH.b, BONE.b)
	local stain = drawing.blood * math.Clamp((f - 0.55) / 0.3, 0, 1)
	return Lerp(stain, r, BLOOD.r) * b, Lerp(stain, g, BLOOD.g) * b, Lerp(stain, bl, BLOOD.b) * b
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

	drawNow = UnPredictedCurTime()
	for _, limb in ipairs(morph.legs) do
		local st = self.LimbState[limb]
		drawing = st
		if st.wrap > 0 and st.coil then
			-- blend between the walking pose and the coil
			local pts = Resample(st.points, COIL_POINTS, st.display or {})
			st.display = pts
			local b = Smooth(st.wrap)
			for i = 1, COIL_POINTS do pts[i] = LerpVector(b, pts[i], st.coil[i]) end
			Flesh.Tube(pts, sides, 1, LimbRadius, LimbColor, limb)
		else
			-- finer when something's going up it, so the lump travels smoothly
			Flesh.Tube(st.points, sides, st.lumps[1] and sub * 2 or sub, LimbRadius, LimbColor, limb)
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
