include("evil_crawler/sh_ik.lua")
include("evil_crawler/sh_morph.lua")

EvilCrawler.ACT_NONE = 0
EvilCrawler.ACT_STRIKE = 1
EvilCrawler.ACT_DRAG = 2
EvilCrawler.ACT_FEED = 3
EvilCrawler.STRIKE_WINDUP = 0.4 -- one leg rears back, trembling
EvilCrawler.STRIKE_LUNGE = 0.08 -- then whips into the victim
EvilCrawler.WRAP_TIME = 0.15 -- and coils round the body as it drops
EvilCrawler.PULL_TIME = 2 -- somewhere quiet, it hauls the body up into its mouth head first

-- Feeding: the mouth is where the legs meet. Each feeding leg rears over the
-- mouthful going in, stabs into it, worries at it, then rips out. The timing
-- is fixed by the creature's seed, so the server's gore and every client's
-- legs land together.
EvilCrawler.FEEDERS = 4
EvilCrawler.BITE_JAB = 0.5 -- share of a cycle spent rearing over the next bite
EvilCrawler.BITE_IN = 0.56 -- the stab lands
EvilCrawler.BITE_RIP = 0.82 -- and tears back out
EvilCrawler.LUMP_TIME = 1.2 -- what it tore off takes this long to travel up the leg

-- What it eats, in order, head first, a mouthful at a time. While a mouthful
-- goes it's held in the mouth by its `grip` bones. Eating it takes `bones`
-- and everything below `roots`, and `rips` tears. It leaves `stumps`, the
-- open end of what's left, each a bone and the bone below it that the stump
-- points away from; `size` scales them.
local B = "ValveBiped.Bip01_"
EvilCrawler.PARTS = {
	{ -- head
		grip = { B .. "Head1" }, roots = { B .. "Head1" }, bones = { B .. "Neck1" }, rips = 6,
		stumps = { { B .. "Spine4", B .. "Spine2" } }, size = 3.4,
	},
	{ -- shoulders and arms
		grip = { B .. "Spine2" }, roots = { B .. "L_Clavicle", B .. "R_Clavicle" }, bones = { B .. "Spine4" }, rips = 8,
		stumps = { { B .. "Spine2", B .. "Spine1" } }, size = 4.6,
	},
	{ -- chest
		grip = { B .. "Spine2" }, bones = { B .. "Spine2", B .. "Spine1" }, rips = 8,
		stumps = { { B .. "Spine", B .. "Pelvis" } }, size = 4.6,
	},
	{ -- belly and hips
		grip = { B .. "Pelvis" }, bones = { B .. "Spine", B .. "Pelvis" }, rips = 8,
		stumps = { { B .. "L_Thigh", B .. "L_Calf" }, { B .. "R_Thigh", B .. "R_Calf" } }, size = 3.8,
	},
	{ -- thighs
		grip = { B .. "L_Thigh", B .. "R_Thigh" }, bones = { B .. "L_Thigh", B .. "R_Thigh" }, rips = 6,
		stumps = { { B .. "L_Calf", B .. "L_Foot" }, { B .. "R_Calf", B .. "R_Foot" } }, size = 3,
	},
	{ -- shins and feet
		grip = { B .. "L_Calf", B .. "R_Calf" }, roots = { B .. "L_Calf", B .. "R_Calf" }, rips = 5,
		stumps = {}, size = 2.5,
	},
}
for _, part in ipairs(EvilCrawler.PARTS) do
	part.bites = {}
	for _, b in ipairs(part.grip) do part.bites[#part.bites + 1] = b end
	for _, b in ipairs(part.bones or {}) do
		if not table.HasValue(part.bites, b) then part.bites[#part.bites + 1] = b end
	end
end
EvilCrawler.TORSO_BITES = { B .. "Spine2", B .. "Spine1", B .. "Spine", B .. "Pelvis" }
EvilCrawler.EATEN_VAR = "EvilCrawlerEaten" -- networked on the corpse: bit i set once part i is gone

function EvilCrawler.Eaten(corpse, part)
	return bit.band(corpse:GetNW2Int(EvilCrawler.EATEN_VAR, 0), bit.lshift(1, part - 1)) ~= 0
end

-- The mouthful it's on, or nil once there's nothing left it knows how to eat.
function EvilCrawler.CurrentPart(corpse)
	for part, p in ipairs(EvilCrawler.PARTS) do
		if not EvilCrawler.Eaten(corpse, part) then
			return corpse:LookupBone(p.grip[1]) and part or nil
		end
	end
end

-- Every bone a mouthful takes, looked up on `ent` and kept there.
function EvilCrawler.PartBones(ent, part)
	ent.EvilCrawlerPartBones = ent.EvilCrawlerPartBones or {}
	local bones = ent.EvilCrawlerPartBones[part]
	if bones then return bones end
	bones = {}
	local function subtree(b)
		bones[#bones + 1] = b
		for _, child in ipairs(ent:GetChildBones(b)) do subtree(child) end
	end
	local p = EvilCrawler.PARTS[part]
	for _, name in ipairs(p.roots or {}) do
		local b = ent:LookupBone(name)
		if b then subtree(b) end
	end
	for _, name in ipairs(p.bones or {}) do
		local b = ent:LookupBone(name)
		if b and not table.HasValue(bones, b) then bones[#bones + 1] = b end
	end
	ent.EvilCrawlerPartBones[part] = bones
	return bones
end

-- Feeding leg k's bite cycle, `t` seconds into feeding: which bite it's on
-- and how far through it, 0..1.
function EvilCrawler.BiteCycle(k, t)
	local x = t / (1.3 + k * 0.29) - k * 0.37
	local n = math.floor(x)
	return n, x - n
end

-- The bone feeding leg k goes for on bite n, eating `part` (nil: the torso).
function EvilCrawler.BiteBone(seed, k, n, part)
	local bones = part and EvilCrawler.PARTS[part].bites or EvilCrawler.TORSO_BITES
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
