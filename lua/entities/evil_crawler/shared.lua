include("evil_crawler/sh_ik.lua")
include("evil_crawler/sh_morph.lua")

EvilCrawler.ACT_NONE = 0
EvilCrawler.ACT_STRIKE = 1
EvilCrawler.ACT_DRAG = 2
EvilCrawler.ACT_FEED = 3
EvilCrawler.STRIKE_WINDUP = 0.4 -- one leg rears back, trembling
EvilCrawler.STRIKE_LUNGE = 0.08 -- then whips into the victim
EvilCrawler.WRAP_TIME = 0.15 -- and coils round the body as it drops
EvilCrawler.PULL_TIME = 2 -- somewhere quiet, it hauls the body up into the tangle before eating

-- Feeding: each feeding leg rears over a part of the body, stabs into it,
-- worries at it, then rips out. The schedule is fixed by the creature's seed,
-- so the server's gore and every client's legs land together.
EvilCrawler.FEEDERS = 4
EvilCrawler.BITE_JAB = 0.5 -- share of a cycle spent rearing over the next bite
EvilCrawler.BITE_IN = 0.56 -- the stab lands
EvilCrawler.BITE_RIP = 0.82 -- and tears back out
EvilCrawler.LUMP_TIME = 1.2 -- what it tore off takes this long to travel up the leg
EvilCrawler.BITE_BONES = {
	"ValveBiped.Bip01_Head1", "ValveBiped.Bip01_Spine2", "ValveBiped.Bip01_L_Thigh",
	"ValveBiped.Bip01_R_UpperArm", "ValveBiped.Bip01_Spine", "ValveBiped.Bip01_R_Calf",
	"ValveBiped.Bip01_L_Forearm", "ValveBiped.Bip01_R_Thigh", "ValveBiped.Bip01_L_UpperArm",
	"ValveBiped.Bip01_L_Calf", "ValveBiped.Bip01_R_Forearm",
}

-- Feeding leg k's bite cycle, `t` seconds into feeding: which bite it's on
-- and how far through it, 0..1.
function EvilCrawler.BiteCycle(k, t)
	local x = t / (1.3 + k * 0.29) - k * 0.37
	local n = math.floor(x)
	return n, x - n
end

-- The bone feeding leg k goes for on bite n.
function EvilCrawler.BiteBone(seed, k, n)
	local bones = EvilCrawler.BITE_BONES
	return bones[(seed + k * 7 + n * 5) % #bones + 1]
end

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
	self:NetworkVar("Entity", 1, "Victim") -- the NPC while striking, then its corpse
end

function ENT:Trace(from, to)
	self.TraceFilter = self.TraceFilter or function(e)
		-- ragdolls too, or it would try to walk on the body it's carrying
		return e ~= self and not e:IsPlayer() and not e:IsNPC() and e:GetClass() ~= "prop_ragdoll"
	end
	return util.TraceLine({ start = from, endpos = to, filter = self.TraceFilter, mask = MASK_SOLID })
end
