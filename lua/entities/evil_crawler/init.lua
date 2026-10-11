AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
AddCSLuaFile("evil_crawler/sh_ik.lua")
AddCSLuaFile("evil_crawler/sh_morph.lua")
AddCSLuaFile("evil_crawler/cl_flesh.lua")
AddCSLuaFile("evil_crawler/cl_remains.lua")
include("shared.lua")
include("sv_brain.lua")
include("sv_attack.lua")

local cv_speed = CreateConVar("evil_crawler_speed", "220", FCVAR_ARCHIVE, "Top crawl speed")
local cv_probes = CreateConVar("evil_crawler_debug_probes", "0", 0, "Draw surface probes (needs developer 1)")

local GRAVITY = 600
local STICK_RATE = 8 -- how fast the body turns to match the surface under it
local HOLD_RATE = 10 -- how fast it settles back to standing height
local GRIP = 0.05 -- probe weight needed to hold on; below it, it falls
local REGRIP = 0.2 -- probe weight needed to catch hold again while falling
local PROBE_REACH = 2.2 -- probes feel this many body heights out

-- Probe directions in body space (x forward, y left, z up): straight down,
-- two cones fanning out below, and a horizontal ring.
local DOWN, RING = { Vector(0, 0, -1) }, {}
for i = 0, 7 do
	local a = i / 8 * math.pi * 2
	local h = Vector(math.cos(a), math.sin(a), 0)
	DOWN[#DOWN + 1] = (h * 0.7 - Vector(0, 0, 1)):GetNormalized()
	DOWN[#DOWN + 1] = (h * 1.6 - Vector(0, 0, 1)):GetNormalized()
	RING[#RING + 1] = h
end
local WRAP_DEPTHS = { 1.15, 1.6 }
local PROBE_COLOR = Color(0, 200, 255)

local function Rotate(v, axis, angle)
	local c, s = math.cos(angle), math.sin(angle)
	return v * c + axis:Cross(v) * s + axis * (axis:Dot(v) * (1 - c))
end

-- Turns the body frame so up swings a fraction t of the way toward n.
-- Facing rides along on the same rotation, so walking straight into a wall
-- turns facing up the wall instead of collapsing.
local function Turn(up, facing, n, t)
	local axis = up:Cross(n)
	local s, c = axis:Length(), up:Dot(n)
	if s < 1e-4 then
		if c > 0 then return up, facing end
		axis = facing
	else
		axis = axis / s
	end
	local angle = math.atan2(s, c) * t
	return Rotate(up, axis, angle):GetNormalized(), Rotate(facing, axis, angle):GetNormalized()
end

function ENT:SpawnFunction(ply, tr, class)
	if not tr.Hit then return end

	local ent = ents.Create(class)
	ent:SetPos(tr.HitPos + tr.HitNormal * self.BodyHeight)
	ent:SetAngles(Angle(0, ply:EyeAngles().y + 180, 0))
	ent.Master = ply
	ent.SpawnUp = tr.HitNormal
	ent:Spawn()
	ent:Activate()
	return ent
end

function ENT:Initialize()
	self:SetModel("models/props_junk/PopCan01a.mdl")
	self:SetMoveType(MOVETYPE_NOCLIP)
	self:SetSolid(SOLID_BBOX)

	if self:GetSeed() == 0 then self:SetSeed(math.random(1, 2 ^ 30)) end
	local morph = EvilCrawler.Grow(self:GetSeed())
	self.BodyHeight = morph.height
	self:SetCollisionBounds(Vector(-12, -12, -12), Vector(12, 12, 12))
	self:SetSaveValue("m_takedamage", 2) -- DAMAGE_YES, so blasts and blows reach OnTakeDamage

	local up = self.SpawnUp or Vector(0, 0, 1)
	local facing = self:GetForward()
	facing = facing - up * facing:Dot(up)
	if facing:LengthSqr() < 1e-4 then facing = up:Angle():Up() end

	self.BodyUp = up
	self.Facing = facing:GetNormalized()
	self.Vel = Vector()
	self.Falling = false
end

function ENT:Think()
	self:Crawl(FrameTime())
	self:UpdateAct(CurTime())
	self:NextThink(CurTime())
	return true
end

-- Feels for nearby surfaces with a spread of rays and blends everything they
-- touch, nearer hits weighing more. Near a corner both faces get felt, so the
-- blended surface (and the body with it) rounds the corner instead of
-- snapping between faces. Returns the blended normal, a point on the blended
-- surface, and the total grip.
function ENT:SenseSurface(pos, fwd, left, up, move)
	local h = self.BodyHeight
	local reach = h * PROBE_REACH
	local normal, point, grip = Vector(), Vector(), 0

	local function probe(from, dir, len, weight)
		local tr = self:Trace(from, from + dir * len)
		if not tr.Hit or tr.StartSolid then return false end
		if cv_probes:GetBool() then debugoverlay.Line(from, tr.HitPos, 0.05, PROBE_COLOR, true) end
		local near = 1 - math.min(1, tr.HitPos:Distance(pos) / reach)
		local w = weight * near * near
		normal:Add(tr.HitNormal * w)
		point:Add(tr.HitPos * w)
		grip = grip + w
		return true
	end

	local function world(v)
		return fwd * v.x + left * v.y + up * v.z
	end

	local downHits = 0
	for _, d in ipairs(DOWN) do
		if probe(pos, world(d), reach, 1) then downHits = downHits + 1 end
	end

	-- walls around it, felt mostly in the direction it's going
	for _, d in ipairs(RING) do
		local dir = world(d)
		probe(pos, dir, h * 1.5, math.max(0.25, dir:Dot(move)))
	end

	-- partly over an edge: reach in from beyond and below for the face it's
	-- going over, so it can wrap around onto it
	if downHits < #DOWN * 0.6 then
		for _, depth in ipairs(WRAP_DEPTHS) do
			local below = pos - up * (h * depth)
			for _, d in ipairs(RING) do
				local dir = world(d)
				probe(below + dir * (h * 1.3), -dir, h * 1.3, math.max(0.3, dir:Dot(move)))
			end
		end
	end

	if grip <= 0 then return nil, nil, 0 end
	return normal:GetNormalized(), point / grip, grip
end

-- Moves without passing through anything, sliding along what it hits.
function ENT:SafeMove(from, to)
	local tr = self:Trace(from, to)
	if not tr.Hit then return to end
	if tr.StartSolid then return from end
	self.Vel = self.Vel - tr.HitNormal * math.min(0, self.Vel:Dot(tr.HitNormal))
	return tr.HitPos + tr.HitNormal
end

function ENT:Crawl(dt)
	local h = self.BodyHeight
	local pos = self:GetPos()
	local up, fwd = self.BodyUp, self.Facing
	local move = self.Vel:LengthSqr() > 100 and self.Vel:GetNormalized() or fwd
	local normal, anchor, grip = self:SenseSurface(pos, fwd, up:Cross(fwd), up, move)

	self.Falling = grip < (self.Falling and REGRIP or GRIP) or CurTime() < (self.LetGoUntil or 0)

	if not self.Falling then
		up, fwd = Turn(up, fwd, normal, 1 - math.exp(-dt * STICK_RATE))

		local wish = Vector()
		local target, pace = self:Steer()
		if target then
			local to = target - pos
			local flat = to - up * to:Dot(up)
			local along = flat:Length()
			-- puppeted at a point straight overhead: carry on until a wall turns it that way
			if self.Puppeting and along < to:Length() * 0.3 then flat, along = fwd, h * 3 end
			wish = flat:GetNormalized() * cv_speed:GetFloat() * pace * math.Clamp((along - 24) / (h * 1.5), 0, 1)
		end

		self.Vel = LerpVector(1 - math.exp(-dt * 6), self.Vel, wish)
		self.Vel = self.Vel - up * self.Vel:Dot(up)

		local err = h - (pos - anchor):Dot(normal)
		pos = self:SafeMove(pos, pos + self.Vel * dt + normal * (err * (1 - math.exp(-dt * HOLD_RATE))))
	else
		up, fwd = Turn(up, fwd, vector_up, 1 - math.exp(-dt * 3))
		self.Vel = self.Vel - vector_up * (GRAVITY * dt)
		pos = self:SafeMove(pos, pos + self.Vel * dt)
	end

	if not self.Falling and self.Vel:LengthSqr() > 100 then
		fwd = LerpVector(1 - math.exp(-dt * 6), fwd, self.Vel:GetNormalized())
	end
	fwd = fwd - up * fwd:Dot(up)
	if fwd:LengthSqr() < 1e-4 then fwd = up:Angle():Up() end
	fwd:Normalize()

	self.BodyUp = up
	self.Facing = fwd
	self:SetPos(pos)
	self:SetAngles(fwd:AngleEx(up))
end
