AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Evil Crawler (somewhere)"
ENT.Category = "Evil Crawling Thing"
ENT.Spawnable = true

if CLIENT then return end

local TRIES = 60
local FAR = 1500
local REACH = 600
local HOPS = 6
local HOP_LENGTH = 4000
local LIFT = 24
local BOUNDS = Vector(12, 12, 12)

local function Points(from)
	local areas = navmesh.GetAllNavAreas()
	if #areas > 0 then
		return function() return areas[math.random(#areas)]:GetRandomPoint() + vector_up * LIFT end
	end
	local at = from
	return function()
		for _ = 1, HOPS do
			local tr = util.TraceLine({ start = at, endpos = at + VectorRand():GetNormalized() * HOP_LENGTH, mask = MASK_SOLID_BRUSHONLY })
			if tr.Hit and not tr.HitSky and not tr.StartSolid then at = tr.HitPos + tr.HitNormal * LIFT end
		end
		return at
	end
end

local function Cling(point, height)
	for _, dir in ipairs({ VectorRand():GetNormalized(), -vector_up }) do
		local tr = util.TraceLine({ start = point, endpos = point + dir * REACH, mask = MASK_SOLID })
		if tr.HitWorld and not tr.HitSky and not tr.StartSolid then
			local pos = tr.HitPos + tr.HitNormal * height
			local room = util.TraceHull({
				start = tr.HitPos + tr.HitNormal * (BOUNDS.z + 2), endpos = pos,
				mins = -BOUNDS, maxs = BOUNDS, mask = MASK_SOLID,
			})
			if not room.Hit and util.IsInWorld(pos) then return pos, tr.HitNormal end
		end
	end
end

local function Exposure(pos)
	local seen, nearest = false, math.huge
	for _, ply in ipairs(player.GetAll()) do
		if ply:Alive() then
			local eye = ply:EyePos()
			nearest = math.min(nearest, eye:Distance(pos))
			if not util.TraceLine({ start = eye, endpos = pos, mask = MASK_BLOCKLOS, filter = ply }).Hit then seen = true end
		end
	end
	return seen, nearest
end

local function Somewhere(from, height)
	local points = Points(from)
	local best, bestUp, bestScore
	for _ = 1, TRIES do
		local pos, up = Cling(points(), height)
		if pos then
			local seen, dist = Exposure(pos)
			if not seen and dist >= FAR then return pos, up end
			local score = dist - (seen and 1e6 or 0)
			if not bestScore or score > bestScore then best, bestUp, bestScore = pos, up, score end
		end
	end
	return best, bestUp
end

local function LetLoose(ply, from)
	local ent = ents.Create("evil_crawler")
	local pos, up = Somewhere(from, ent.BodyHeight)
	if not pos then
		ent:Remove()
		return
	end
	ent:SetPos(pos)
	ent:SetAngles(Angle(0, math.Rand(0, 360), 0))
	ent.Master = ply
	ent.SpawnUp = up
	ent:Spawn()
	ent:Activate()
	return ent
end

function ENT:SpawnFunction(ply, tr, class)
	return LetLoose(ply, ply:EyePos())
end

function ENT:Initialize()
	LetLoose(nil, self:GetPos())
	SafeRemoveEntityDelayed(self, 0)
end
