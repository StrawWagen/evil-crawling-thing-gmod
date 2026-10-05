include("evil_crawler/sh_ik.lua")
include("evil_crawler/sh_morph.lua")

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Evil Crawler"
ENT.Category = "Evil Crawling Thing"
ENT.Spawnable = true
ENT.RenderGroup = RENDERGROUP_OPAQUE

ENT.BodyHeight = 64 -- until the creature has grown and knows its own height

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "Seed")
end

function ENT:Trace(from, to)
	self.TraceFilter = self.TraceFilter or function(e)
		return e ~= self and not e:IsPlayer() and not e:IsNPC()
	end
	return util.TraceLine({ start = from, endpos = to, filter = self.TraceFilter, mask = MASK_SOLID })
end
