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
-- worries at it, then rips out. The timing is fixed by the creature's seed,
-- so the server's gore and every client's legs land together.
EvilCrawler.FEEDERS = 4
EvilCrawler.BITE_JAB = 0.5 -- share of a cycle spent rearing over the next bite
EvilCrawler.BITE_IN = 0.56 -- the stab lands
EvilCrawler.BITE_RIP = 0.82 -- and tears back out
EvilCrawler.LUMP_TIME = 1.2 -- what it tore off takes this long to travel up the leg

-- What it eats, a limb at a time from the hand or foot inward, head last,
-- until only the torso is left. Each part goes with everything below it.
-- `size` scales the stump left behind.
local B = "ValveBiped.Bip01_"
EvilCrawler.PARTS = {
	{ root = B .. "L_Forearm", bites = { B .. "L_Hand", B .. "L_Forearm" }, size = 2.2 },
	{ root = B .. "L_UpperArm", bites = { B .. "L_UpperArm" }, size = 2.8 },
	{ root = B .. "R_Forearm", bites = { B .. "R_Hand", B .. "R_Forearm" }, size = 2.2 },
	{ root = B .. "R_UpperArm", bites = { B .. "R_UpperArm" }, size = 2.8 },
	{ root = B .. "L_Calf", bites = { B .. "L_Foot", B .. "L_Calf" }, size = 3 },
	{ root = B .. "L_Thigh", bites = { B .. "L_Thigh" }, size = 3.8 },
	{ root = B .. "R_Calf", bites = { B .. "R_Foot", B .. "R_Calf" }, size = 3 },
	{ root = B .. "R_Thigh", bites = { B .. "R_Thigh" }, size = 3.8 },
	{ root = B .. "Head1", bites = { B .. "Head1", B .. "Neck1" }, size = 3.2 },
}
EvilCrawler.TORSO_BITES = { B .. "Spine2", B .. "Spine1", B .. "Spine", B .. "Pelvis" }
EvilCrawler.EATEN_VAR = "EvilCrawlerEaten" -- networked on the corpse: bit i set once part i is gone

local LIMBS = { { 1, 2 }, { 3, 4 }, { 5, 6 }, { 7, 8 } }
local orders = {}

-- The order a creature eats in: its limbs in an order of its own, each from
-- the end inward, then the head.
function EvilCrawler.EatOrder(seed)
	local order = orders[seed]
	if order then return order end
	order = {}
	local first, step = seed % 4, seed % 3 == 0 and 3 or 1
	for i = 0, 3 do
		for _, part in ipairs(LIMBS[(first + i * step) % 4 + 1]) do order[#order + 1] = part end
	end
	order[#order + 1] = 9
	orders[seed] = order
	return order
end

function EvilCrawler.Eaten(corpse, part)
	return bit.band(corpse:GetNWInt(EvilCrawler.EATEN_VAR, 0), bit.lshift(1, part - 1)) ~= 0
end

-- The part it's eating now, or nil once nothing is left but the torso.
function EvilCrawler.CurrentPart(corpse, seed)
	for _, part in ipairs(EvilCrawler.EatOrder(seed)) do
		if not EvilCrawler.Eaten(corpse, part) and corpse:LookupBone(EvilCrawler.PARTS[part].root) then
			return part
		end
	end
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
