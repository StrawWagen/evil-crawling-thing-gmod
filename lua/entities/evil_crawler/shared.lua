include("evil_crawler/sh_ik.lua")
include("evil_crawler/sh_morph.lua")

EvilCrawler.ACT_NONE = 0
EvilCrawler.ACT_CONSTRICT = 1
EvilCrawler.ACT_DRAG = 2
EvilCrawler.ACT_FEED = 3
EvilCrawler.WRAP_TIME = 1.2 -- legs coil up the victim
EvilCrawler.SNAP_TIME = 3 -- then squeeze until the neck goes

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Evil Crawler"
ENT.Category = "Evil Crawling Thing"
ENT.Spawnable = true
ENT.RenderGroup = RENDERGROUP_OPAQUE

ENT.BodyHeight = 64 -- until the creature has grown and knows its own height

function ENT:SetupDataTables()
	self:NetworkVar("Int", 0, "Seed")
	self:NetworkVar("Int", 1, "Mood") -- 0 calm, 1 on a scent, 2 in contact
	self:NetworkVar("Entity", 0, "Prey")
	self:NetworkVar("Int", 2, "Act") -- what it's doing to its victim, EvilCrawler.ACT_*
	self:NetworkVar("Float", 0, "ActStart")
	self:NetworkVar("Entity", 1, "Victim") -- the NPC while constricting, then its corpse
end

function ENT:Trace(from, to)
	self.TraceFilter = self.TraceFilter or function(e)
		-- ragdolls too, or it would try to walk on the body it's carrying
		return e ~= self and not e:IsPlayer() and not e:IsNPC() and e:GetClass() ~= "prop_ragdoll"
	end
	return util.TraceLine({ start = from, endpos = to, filter = self.TraceFilter, mask = MASK_SOLID })
end
