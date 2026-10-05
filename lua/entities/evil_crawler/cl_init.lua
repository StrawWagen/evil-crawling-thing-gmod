include("shared.lua")

local cv_debug = CreateClientConVar("evil_crawler_debug", "0", false, false, "Draw foot targets")

local STEP_DISTANCE = 20 -- how far a planted foot may drift from its target before stepping
local STEP_HEIGHT = 14
local LEAD_TIME = 0.18 -- feet aim this far ahead along the body's velocity
local SNAP_GAP = 0.5 -- seconds without an update before feet are re-planted from scratch

local FOOT_SOUNDS = {
	"npc/antlion/foot1.wav",
	"npc/antlion/foot2.wav",
	"npc/antlion/foot3.wav",
	"npc/antlion/foot4.wav",
}

local BODY = Color(40, 32, 30)
local EYE = Color(255, 30, 20)
local DEBUG_TARGET = Color(0, 255, 0)
local DEBUG_DANGLE = Color(255, 160, 0)

local SolveTwoBone = EvilCrawler.SolveTwoBone

function ENT:Initialize()
	self:SetRenderBounds(Vector(-100, -100, -100), Vector(100, 100, 100))
	self:DestroyShadow()
end

-- Where a leg's foot should land: whatever is between hip and rest spot
-- (a wall ahead), else the ground under the rest spot, else the face of an
-- edge the body is hanging over. Falls back to a dangling pose.
function ENT:FootTarget(hip, rest, up)
	local h = self.BodyHeight

	local reach = self:Trace(hip, rest)
	if reach.Hit then return reach.HitPos, true end

	local down = self:Trace(rest, rest - up * (h + 40))
	if down.Hit then return down.HitPos, true end

	local back = self:Trace(rest - up * (h + 12), hip - up * (h + 12))
	if back.Hit then return back.HitPos, true end

	return rest - up * (h * 0.6), false
end

function ENT:NeighboursPlanted(i)
	for _, n in ipairs(self.Neighbours[i]) do
		if self.LegState[n].stepping then return false end
	end
	return true
end

function ENT:UpdateLegs()
	local now = UnPredictedCurTime()
	local dt = now - (self.LastLegUpdate or 0)
	if dt <= 0 then return end
	self.LastLegUpdate = now

	local pos, ang = self:GetPos(), self:GetAngles()
	local fwd, left, up = ang:Forward(), -ang:Right(), ang:Up()

	local fresh = not self.LegState or dt > SNAP_GAP
	if fresh then
		self.LegState = {}
		self.SmoothVel = Vector()
		self.LastPos = pos
	end

	self.SmoothVel = LerpVector(math.min(1, dt * 10), self.SmoothVel, (pos - self.LastPos) / dt)
	self.LastPos = pos

	local lead = self.SmoothVel * LEAD_TIME
	local stepTime = math.Clamp(0.2 - self.SmoothVel:Length() * 0.0003, 0.09, 0.2)

	for i, leg in ipairs(self.Legs) do
		local hip = pos + fwd * leg.hip.x + left * leg.hip.y + up * leg.hip.z
		local rest = pos + fwd * leg.rest.x + left * leg.rest.y + up * leg.rest.z + lead
		local target, grounded = self:FootTarget(hip, rest, up)

		local st = self.LegState[i]
		if not st then
			st = { foot = target, stepping = false }
			self.LegState[i] = st
		end
		st.target, st.grounded = target, grounded

		if st.stepping then
			st.t = st.t + dt / stepTime
			if st.t >= 1 then
				st.stepping = false
				st.foot = target
				if grounded then
					sound.Play(FOOT_SOUNDS[math.random(#FOOT_SOUNDS)], target, 55, math.random(150, 180), 0.25)
				end
			end
		elseif not grounded then
			st.foot = LerpVector(math.min(1, dt * 8), st.foot, target)
		else
			local drift = st.foot:Distance(target)
			local overreach = st.foot:Distance(hip) > (leg.upper + leg.lower) * 0.95
			if overreach or (drift > STEP_DISTANCE and self:NeighboursPlanted(i)) then
				st.stepping, st.t, st.from = true, 0, st.foot
			end
		end

		local footPos = st.foot
		if st.stepping then
			local t = st.t
			footPos = LerpVector(t * t * (3 - 2 * t), st.from, target) + up * (math.sin(t * math.pi) * STEP_HEIGHT)
		end

		local out = hip - pos
		out = out - up * out:Dot(up)
		st.hip = hip
		st.knee, st.pos = SolveTwoBone(hip, footPos, leg.upper, leg.lower, out:GetNormalized() + up * 1.5)
	end
end

local function Shade(base, light)
	local b = math.Clamp(0.3 + (light.x + light.y + light.z) * 0.5, 0.3, 1.3)
	return Color(base.r * b, base.g * b, base.b * b)
end

function ENT:Draw()
	self:UpdateLegs()
	if not self.LegState then return end

	local pos, ang = self:GetPos(), self:GetAngles()
	local fwd, left, up = ang:Forward(), -ang:Right(), ang:Up()
	local function at(x, y, z) return pos + fwd * x + left * y + up * z end

	local col = Shade(BODY, render.GetLightColor(pos))
	render.SetColorMaterial()

	render.DrawSphere(at(10, 0, 2), 9, 12, 12, col)
	render.DrawSphere(at(-16, 0, 6), 14, 14, 14, col)

	for _, s in ipairs({ 1, -1 }) do
		render.DrawSphere(at(18, 2.5 * s, 6), 1.2, 6, 6, EYE)
		render.DrawSphere(at(17, 5 * s, 4), 1, 6, 6, EYE)
		render.DrawBeam(at(17, 2 * s, 0), at(21, 1.5 * s, -6), 1.5, 0, 1, col)
	end

	for _, st in ipairs(self.LegState) do
		render.StartBeam(3)
		render.AddBeam(st.hip, 3.5, 0, col)
		render.AddBeam(st.knee, 2.5, 0.5, col)
		render.AddBeam(st.pos, 0.8, 1, col)
		render.EndBeam()
		render.DrawSphere(st.knee, 1.6, 6, 6, col)
	end

	if cv_debug:GetBool() then
		for _, st in ipairs(self.LegState) do
			local c = st.grounded and DEBUG_TARGET or DEBUG_DANGLE
			render.DrawWireframeSphere(st.target, 2, 4, 4, c, true)
			render.DrawLine(st.pos, st.target, c, true)
		end
	end
end
