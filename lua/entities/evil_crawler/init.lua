AddCSLuaFile("cl_init.lua")
AddCSLuaFile("shared.lua")
AddCSLuaFile("evil_crawler/sh_ik.lua")
AddCSLuaFile("evil_crawler/sh_morph.lua")
AddCSLuaFile("evil_crawler/cl_flesh.lua")
include("shared.lua")

local cv_speed = CreateConVar("evil_crawler_speed", "220", FCVAR_ARCHIVE, "Top crawl speed")

local GRAVITY = 600
local SURFACE_REACH = 48

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
	self.CoreRadius = morph.core.radius

	local r = self.CoreRadius
	self:SetCollisionBounds(Vector(-r, -r, -r), Vector(r, r, r))

	self.BodyUp = self.SpawnUp or Vector(0, 0, 1)
	self.Facing = self:GetForward()
	self.Vel = Vector()
end

function ENT:Think()
	self:Crawl(FrameTime())
	self:NextThink(CurTime())
	return true
end

-- Prototype brain: crawl to wherever the spawner is looking.
function ENT:GetTargetPos()
	local ply = self.Master
	if not IsValid(ply) then return end

	local eye = ply:EyePos()
	local tr = util.TraceLine({ start = eye, endpos = eye + ply:GetAimVector() * 4096, filter = { ply, self } })
	if tr.Hit then return tr.HitPos end
end

-- The surface the body clings to: a wall ahead it wants to climb, else the
-- ground below, else the face of an edge it just walked over.
function ENT:FindSurface(pos, up, facing, target)
	local h = self.BodyHeight

	local ahead = self:Trace(pos, pos + facing * (h + 12))
	if ahead.Hit and ahead.HitNormal:Dot(up) < 0.7 and target
		and (target - ahead.HitPos):Dot(ahead.HitNormal) < 8 then
		return ahead
	end

	local below = self:Trace(pos + up * 8, pos - up * (h + SURFACE_REACH))
	if below.Hit then return below end

	local under = pos - up * (h + 16)
	local wrap = self:Trace(under, under - facing * (h + 40))
	if wrap.Hit then return wrap end
end

function ENT:Crawl(dt)
	local pos = self:GetPos()
	local up = self.BodyUp
	local target = self:GetTargetPos()
	local surface = self:FindSurface(pos, up, self.Facing, target)

	if surface then
		up = LerpVector(math.min(1, dt * 8), up, surface.HitNormal):GetNormalized()

		local wish = Vector()
		if target then
			local to = target - pos
			local slowdown = math.Clamp((to:Length() - self.BodyHeight) / (self.BodyHeight * 3), 0, 1)
			to = to - up * to:Dot(up)
			if to:LengthSqr() > 1 then
				wish = to:GetNormalized() * cv_speed:GetFloat() * slowdown
			end
		end

		self.Vel = LerpVector(math.min(1, dt * 6), self.Vel, wish)
		self.Vel = self.Vel - up * self.Vel:Dot(up)

		local step = self.Vel * dt
		if step:LengthSqr() > 0 then
			local block = self:Trace(pos, pos + step + step:GetNormalized() * self.CoreRadius)
			if block.Hit then
				step = Vector()
				self.Vel = self.Vel - block.HitNormal * self.Vel:Dot(block.HitNormal)
			end
		end
		pos = pos + step

		-- hold standing height above the surface
		local n = surface.HitNormal
		local err = self.BodyHeight - (pos - surface.HitPos):Dot(n)
		pos = pos + n * err * math.min(1, dt * 12)
	else
		up = LerpVector(math.min(1, dt * 3), up, vector_up):GetNormalized()
		self.Vel = self.Vel - vector_up * GRAVITY * dt

		local fall = self:Trace(pos, pos + self.Vel * dt)
		pos = fall.Hit and fall.HitPos + fall.HitNormal * 2 or pos + self.Vel * dt
	end

	local facing = self.Vel:LengthSqr() > 100 and self.Vel:GetNormalized() or self.Facing
	facing = LerpVector(math.min(1, dt * 8), self.Facing, facing)
	facing = facing - up * facing:Dot(up)
	if facing:LengthSqr() < 0.001 then facing = up:Angle():Up() end
	facing:Normalize()

	self.BodyUp = up
	self.Facing = facing
	self:SetPos(pos)
	self:SetAngles(facing:AngleEx(up))
end
