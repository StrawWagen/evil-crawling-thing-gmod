include("shared.lua")

local cv_debug = CreateClientConVar("evil_crawler_debug", "0", false, false, "Draw foot targets")

local LEAD_TIME = 0.18 -- feet aim this far ahead along the body's velocity
local SNAP_GAP = 0.5 -- seconds without an update before limbs are re-planted from scratch
local MAX_AIRBORNE = 0.4 -- share of legs allowed mid-step at once
local FEEL_RANGE = 500
local IK_ITERATIONS = 3

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

local SolveChain = EvilCrawler.SolveChain

function ENT:Initialize()
	self:SetRenderBounds(Vector(-160, -160, -160), Vector(160, 160, 160))
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

-- Lays the chain out as an arch from root to target bulging along `bow`,
-- shaken by noise and twitches, then lets FABRIK pull it to exact lengths.
local function Pose(st, limb, root, target, bow, t)
	local pts = st.points
	local n = limb.segments + 1
	local wobble = limb.length * 0.08
	for i = 1, n do
		local f = (i - 1) / (n - 1)
		local arch = math.sin(f * math.pi)
		local shake = Wobble(t, limb.phase + i * 1.9, limb.freq) * wobble + st.twitch
		pts[i] = LerpVector(f, root, target) + (bow + shake) * arch
	end
	SolveChain(pts, limb.lengths, root, target, IK_ITERATIONS)
end

-- Where a foot should land: whatever is between root and rest spot (a wall
-- ahead), else the ground under the rest spot, else the face of an edge the
-- body is hanging over. Falls back to a dangling pose.
function ENT:FootTarget(root, rest, up)
	local h = self.BodyHeight

	local reach = self:Trace(root, rest)
	if reach.Hit then return reach.HitPos, true end

	local down = self:Trace(rest, rest - up * (h + 40))
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

function ENT:FeelTarget(pos)
	local best, bestDist = nil, FEEL_RANGE * FEEL_RANGE
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() then
			local d = ply:EyePos():DistToSqr(pos)
			if d < bestDist then best, bestDist = ply, d end
		end
	end
	return best and best:EyePos()
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
	end

	self.SmoothVel = LerpVector(math.min(1, dt * 10), self.SmoothVel, (pos - self.LastPos) / dt)
	self.LastPos = pos

	-- the core keeps turning over on itself, whichever way it's heading
	self.Churn = self.Churn + dt * morph.churn * (1 + math.sin(now * 0.3 + morph.phase))
	ang:RotateAroundAxis(ang:Up(), self.Churn)

	local fwd, left, up = ang:Forward(), -ang:Right(), ang:Up()
	local function toWorld(v) return pos + fwd * v.x + left * v.y + up * v.z end

	local lead = self.SmoothVel * LEAD_TIME
	local hurry = math.Clamp(1 - self.SmoothVel:Length() * 0.0015, 0.45, 1)

	local airborne, maxAirborne = 0, math.ceil(#morph.legs * MAX_AIRBORNE)
	for _, leg in ipairs(morph.legs) do
		local st = self.LimbState[leg]
		if st and st.stepping then airborne = airborne + 1 end
	end

	local feel = self:FeelTarget(pos)

	for _, limb in ipairs(morph.limbs) do
		local st = self.LimbState[limb]
		if not st then
			st = { points = {}, twitch = Vector(), reach = 0 }
			self.LimbState[limb] = st
		end

		st.twitch = st.twitch * math.exp(-dt * 7)
		if math.random() < dt * 0.25 then
			st.twitch = VectorRand() * limb.length * 0.25
		end

		local root = toWorld(limb.root)

		if limb.kind == "leg" then
			local yaw = math.rad(limb.angle)
			local rest = pos + (fwd * math.cos(yaw) + left * math.sin(yaw)) * (limb.length * limb.spread) + lead
			local target, grounded = self:FootTarget(root, rest, up)
			if not grounded then
				target = target + Wobble(now * 2, limb.phase, limb.freq) * limb.length * 0.2
			end
			st.target, st.grounded = target, grounded
			st.foot = st.foot or target

			if st.stepping then
				st.t = st.t + dt / (limb.stepTime * hurry)
				if st.t >= 1 then
					st.stepping = false
					st.foot = target
					airborne = airborne - 1
					if grounded then
						local snd = FOOT_SOUNDS[math.random(#FOOT_SOUNDS)]
						sound.Play(snd, target, 55, limb.pitch + math.random(-15, 15), 0.2)
					end
				end
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
				foot = LerpVector(t * t * (3 - 2 * t), st.from, target) + up * (math.sin(t * math.pi) * limb.stepHeight)
			end
			Pose(st, limb, root, foot, up * (limb.length * 0.35), now)

		elseif limb.kind == "knot" then
			local tip = toWorld(limb.tip)
			local mid = (root + tip) * 0.5 - pos
			local bow = mid:LengthSqr() > 1 and mid:GetNormalized() or up
			Pose(st, limb, root, tip, bow * (limb.length * 0.35), now)

		else
			local out = (root - pos):GetNormalized()
			local idle = root + (up * 0.8 + out * 0.5):GetNormalized() * (limb.length * 0.7)
				+ Wobble(now * 0.7, limb.phase, limb.freq) * (limb.length * 0.25)
			if feel then st.feel = feel end
			st.reach = math.Approach(st.reach, feel and 1 or 0, dt * 1.5)
			local target = st.feel and LerpVector(st.reach, idle, st.feel) or idle
			local bow = up * (limb.length * 0.2) + Wobble(now * 0.5, limb.phase + 50, limb.freq) * (limb.length * 0.3)
			Pose(st, limb, root, target, bow, now)
		end
	end
end

local function Tint(limb, f, light)
	local b = light * limb.shade
	local k = f * f * f
	return Color(
		Lerp(k, FLESH.r, BONE.r) * b,
		Lerp(k, FLESH.g, BONE.g) * b,
		Lerp(k, FLESH.b, BONE.b) * b
	)
end

function ENT:Draw()
	self:UpdateLimbs()
	local morph = self.Morph
	if not morph or not self.LimbState then return end

	local l = render.GetLightColor(self:GetPos())
	local light = math.Clamp(0.3 + (l.x + l.y + l.z) * 0.5, 0.3, 1.3)

	render.SetColorMaterial()

	for _, limb in ipairs(morph.limbs) do
		local pts = self.LimbState[limb].points
		local n = #pts
		render.StartBeam(n)
		for i = 1, n do
			local f = (i - 1) / (n - 1)
			render.AddBeam(pts[i], Lerp(f, limb.width, 0.4), f, Tint(limb, f, light))
		end
		render.EndBeam()
		render.DrawSphere(pts[1], limb.width * 0.6, 6, 6, Tint(limb, 0, light))
	end

	if cv_debug:GetBool() then
		for _, leg in ipairs(morph.legs) do
			local st = self.LimbState[leg]
			local c = st.grounded and DEBUG_TARGET or DEBUG_DANGLE
			render.DrawWireframeSphere(st.target, 2, 4, 4, c, true)
		end
	end
end
