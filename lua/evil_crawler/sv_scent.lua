-- Every player and NPC leaves a scent trail as they move: a chain of nodes, each one
-- fading over time. Crawlers don't know where players are; they smell where
-- players have been and follow the chain toward fresher scent. One shared
-- scent map serves every crawler on the server.
-- Frightened NPCs, and players who got out of a crawler's coil, sweat fear
-- into their trail: it draws crawlers in whether they're hungry or not.
EvilCrawler = EvilCrawler or {}
local Scent = EvilCrawler.Scent or {}
EvilCrawler.Scent = Scent

local DROP_INTERVAL = 0.25
local DROP_SPACING = 48 -- a moving player leaves a node every this many units
local LINGER_REFRESH = 3 -- a player standing still re-marks their spot this often
local TELEPORT = 512 -- moving further than this between drops starts a new trail
local HALF_LIFE = 45 -- seconds for scent to fade to half strength
local MAX_AGE = 240
local BLEED_TIME = 10 -- seconds after taking damage that a player's scent is stronger
local NPC_SLOW, NPC_FAST = 40, 240 -- NPC speeds that leave the faintest and heaviest trails
local FEAR = 1.5 -- extra strength a frightened NPC's trail carries
local FIGHTING = 0.4 -- and one in a fight
local CELL = 128

local cv_debug = CreateConVar("evil_crawler_debug_scent", "0", 0, "Draw scent trails (needs developer 1)")

Scent.cells = Scent.cells or {} -- spatial hash: cell key -> set of nodes
Scent.trails = Scent.trails or {} -- set of live trails
Scent.active = Scent.active or {} -- player or NPC -> the trail they're currently laying
Scent.npcs = Scent.npcs or {} -- every live NPC, so nothing has to scan all entities

local function Key(ix, iy, iz)
	return (ix + 512) * 1048576 + (iy + 512) * 1024 + (iz + 512)
end

local function CellOf(pos)
	return math.floor(pos.x / CELL), math.floor(pos.y / CELL), math.floor(pos.z / CELL)
end

local function Insert(node)
	local key = Key(CellOf(node.pos))
	local cell = Scent.cells[key]
	if not cell then
		cell = {}
		Scent.cells[key] = cell
	end
	cell[node] = true
	node.cell = key
end

local function Remove(node)
	local cell = Scent.cells[node.cell]
	if cell then
		cell[node] = nil
		if next(cell) == nil then Scent.cells[node.cell] = nil end
	end
	node.dead = true
end

function Scent.Intensity(node, now)
	return node.strength * 0.5 ^ ((now - node.time) / HALF_LIFE)
end

local function Afraid(ent, now)
	return now < (ent.EvilCrawlerFearUntil or 0)
end

-- Frightens every NPC within radius of pos for `duration` seconds.
function Scent.Frighten(pos, radius, duration)
	local now, r2 = CurTime(), radius * radius
	for npc in pairs(Scent.npcs) do
		if IsValid(npc) and not npc.EvilCrawlerVictim and npc:GetPos():DistToSqr(pos) <= r2 then
			npc.EvilCrawlerFearUntil = math.max(npc.EvilCrawlerFearUntil or 0, now + duration)
		end
	end
end

-- Sprinting and bleeding leave a heavy trail, crouching a faint one. NPCs
-- running, fighting or frightened leave a heavier one than NPCs standing about.
local function Strength(ply, now)
	local s = 1
	if ply:IsNPC() then
		s = Lerp(math.Clamp(((ply.EvilCrawlerSpeed or 0) - NPC_SLOW) / (NPC_FAST - NPC_SLOW), 0, 1), 0.6, 1.6)
		if ply:GetNPCState() == NPC_STATE_COMBAT then s = s + FIGHTING end
		if Afraid(ply, now) then s = s + FEAR end
	elseif ply:Crouching() then
		s = 0.35
	elseif ply:KeyDown(IN_SPEED) and ply:GetVelocity():Length2D() > ply:GetWalkSpeed() then
		s = 1.6
	elseif ply:KeyDown(IN_WALK) then
		s = 0.6
	end
	if now - (ply.EvilCrawlerHurt or -math.huge) < BLEED_TIME then
		s = s + 1.5
	end
	return s
end

local ai_ignoreplayers = GetConVar("ai_ignoreplayers")

local function LeavesScent(ent)
	if ent:IsFlagSet(FL_NOTARGET) then return false end
	if ent:IsNPC() then
		return ent:Health() > 0 and not ent.EvilCrawlerVictim and ent:GetMoveType() == MOVETYPE_STEP
	end
	local ply = ent
	return ply:Alive()
		and not (ai_ignoreplayers and ai_ignoreplayers:GetBool())
		and not ply:InVehicle()
		and ply:GetMoveType() ~= MOVETYPE_NOCLIP
		and ply:GetObserverMode() == OBS_MODE_NONE
end

local function Drop(ply, now)
	local pos = ply:GetPos()
	local trail = Scent.active[ply]
	local last = trail and trail.last

	if last then
		local moved = pos:Distance(last.pos)
		if moved > TELEPORT then
			trail = nil
		elseif moved < DROP_SPACING and now - last.time < LINGER_REFRESH then
			return
		end
	end

	if not trail then
		trail = { owner = ply }
		Scent.active[ply] = trail
		Scent.trails[trail] = true
	end

	local node = {
		pos = pos, time = now, strength = Strength(ply, now), trail = trail, prev = trail.last,
		npc = ply:IsNPC(), fear = Afraid(ply, now),
	}
	if trail.last then trail.last.next = node else trail.first = node end
	trail.last = node
	Insert(node)
end

local function Prune(now)
	for trail in pairs(Scent.trails) do
		local node = trail.first
		while node and now - node.time > MAX_AGE do
			Remove(node)
			node = node.next
		end
		if node then
			node.prev = nil
			trail.first = node
		else
			Scent.trails[trail] = nil
			if Scent.active[trail.owner] == trail then Scent.active[trail.owner] = nil end
		end
	end
end

-- The strongest scent within radius of pos, and how strong it is. `weigh`,
-- if given, says how strong a node counts as instead of its intensity.
function Scent.Strongest(pos, radius, now, weigh)
	local best, bestIntensity = nil, 0
	local r2 = radius * radius
	local x0, y0, z0 = CellOf(pos - Vector(radius, radius, radius))
	local x1, y1, z1 = CellOf(pos + Vector(radius, radius, radius))
	for ix = x0, x1 do
		for iy = y0, y1 do
			for iz = z0, z1 do
				local cell = Scent.cells[Key(ix, iy, iz)]
				if cell then
					for node in pairs(cell) do
						if node.pos:DistToSqr(pos) <= r2 then
							local i = weigh and weigh(node, now) or Scent.Intensity(node, now)
							if i > bestIntensity then best, bestIntensity = node, i end
						end
					end
				end
			end
		end
	end
	return best, bestIntensity
end

local function DrawDebug(now)
	for trail in pairs(Scent.trails) do
		local node = trail.first
		while node do
			local i = math.min(1, Scent.Intensity(node, now))
			local c = node.fear and Color(60, 255 * i, 60) or Color(255 * i, 60, 255 * (1 - i))
			debugoverlay.Cross(node.pos, 4, DROP_INTERVAL + 0.05, c, true)
			if node.next then debugoverlay.Line(node.pos, node.next.pos, DROP_INTERVAL + 0.05, c, true) end
			node = node.next
		end
	end
end

timer.Create("EvilCrawlerScent", DROP_INTERVAL, 0, function()
	local now = CurTime()
	local function visit(ent)
		if ent:IsNPC() then
			local pos = ent:GetPos()
			ent.EvilCrawlerSpeed = ent.EvilCrawlerLastPos and pos:Distance(ent.EvilCrawlerLastPos) / DROP_INTERVAL or 0
			ent.EvilCrawlerLastPos = pos
		end
		if LeavesScent(ent) then
			Drop(ent, now)
		else
			Scent.active[ent] = nil -- whatever they do next starts a new trail
		end
	end
	for _, ply in ipairs(player.GetAll()) do visit(ply) end
	for npc in pairs(Scent.npcs) do
		if IsValid(npc) then visit(npc) else Scent.npcs[npc] = nil end
	end
	Prune(now)
	if cv_debug:GetBool() then DrawDebug(now) end
end)

hook.Add("EntityTakeDamage", "EvilCrawlerScent", function(ent)
	if ent:IsPlayer() or ent:IsNPC() then ent.EvilCrawlerHurt = CurTime() end
end)

hook.Add("OnEntityCreated", "EvilCrawlerScent", function(ent)
	timer.Simple(0, function()
		if IsValid(ent) and ent:IsNPC() then Scent.npcs[ent] = true end
	end)
end)

hook.Add("EntityRemoved", "EvilCrawlerScent", function(ent)
	Scent.npcs[ent] = nil
	Scent.active[ent] = nil
end)

for _, ent in ipairs(ents.GetAll()) do
	if ent:IsNPC() then Scent.npcs[ent] = true end
end
