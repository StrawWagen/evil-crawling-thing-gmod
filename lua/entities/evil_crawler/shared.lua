include("evil_crawler/sh_ik.lua")

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Evil Crawler"
ENT.Category = "Evil Crawling Thing"
ENT.Spawnable = true
ENT.RenderGroup = RENDERGROUP_OPAQUE

ENT.BodyHeight = 26

-- Leg pairs front to back, mirrored across the body. Body space, left side:
-- hip is the socket, rest is where the foot wants to land.
local PAIRS = {
	{ hip = Vector(20, 7, 0), rest = Vector(52, 44, 0) },
	{ hip = Vector(7, 9, 0), rest = Vector(22, 50, 0) },
	{ hip = Vector(-6, 9, 0), rest = Vector(-14, 50, 0) },
	{ hip = Vector(-18, 7, 0), rest = Vector(-46, 42, 0) },
}

ENT.Legs = {}
for i, pair in ipairs(PAIRS) do
	for _, side in ipairs({ 1, -1 }) do
		ENT.Legs[#ENT.Legs + 1] = {
			pair = i,
			side = side,
			hip = Vector(pair.hip.x, pair.hip.y * side, pair.hip.z),
			rest = Vector(pair.rest.x, pair.rest.y * side, pair.rest.z),
			upper = 34,
			lower = 42,
		}
	end
end

-- A leg waits to step while any neighbour is mid-step: the opposite leg of
-- its pair and the legs in front and behind on its own side.
ENT.Neighbours = {}
for i, leg in ipairs(ENT.Legs) do
	local list = {}
	for j, other in ipairs(ENT.Legs) do
		local across = other.pair == leg.pair and other.side ~= leg.side
		local along = other.side == leg.side and math.abs(other.pair - leg.pair) == 1
		if across or along then list[#list + 1] = j end
	end
	ENT.Neighbours[i] = list
end

function ENT:Trace(from, to)
	self.TraceFilter = self.TraceFilter or function(e)
		return e ~= self and not e:IsPlayer() and not e:IsNPC()
	end
	return util.TraceLine({ start = from, endpos = to, filter = self.TraceFilter, mask = MASK_SOLID })
end
