-- Every player leaves a scent trail as they move: a chain of nodes, each one
-- fading over time. Crawlers don't know where players are; they smell where
-- players have been and follow the chain toward fresher scent. One shared
-- scent map serves every crawler on the server.
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
local CELL = 128

local cv_debug = CreateConVar("evil_crawler_debug_scent", "0", 0, "Draw scent trails (needs developer 1)")

Scent.cells = Scent.cells or {} -- spatial hash: cell key -> set of nodes
Scent.trails = Scent.trails or {} -- set of live trails
Scent.active = Scent.active or {} -- player -> the trail they're currently laying

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

-- Sprinting and bleeding leave a heavy trail, crouching a faint one.
local function Strength(ply, now)
	local s = 1
	if ply:Crouching() then
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

local function LeavesScent(ply)
	return ply:Alive()
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

	local node = { pos = pos, time = now, strength = Strength(ply, now), trail = trail, prev = trail.last }
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

-- The strongest scent within radius of pos, and how strong it is.
function Scent.Strongest(pos, radius, now)
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
							local i = Scent.Intensity(node, now)
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
			local c = Color(255 * i, 60, 255 * (1 - i))
			debugoverlay.Cross(node.pos, 4, DROP_INTERVAL + 0.05, c, true)
			if node.next then debugoverlay.Line(node.pos, node.next.pos, DROP_INTERVAL + 0.05, c, true) end
			node = node.next
		end
	end
end

timer.Create("EvilCrawlerScent", DROP_INTERVAL, 0, function()
	local now = CurTime()
	for _, ply in ipairs(player.GetAll()) do
		if LeavesScent(ply) then
			Drop(ply, now)
		else
			Scent.active[ply] = nil -- whatever they do next starts a new trail
		end
	end
	Prune(now)
	if cv_debug:GetBool() then DrawDebug(now) end
end)

hook.Add("EntityTakeDamage", "EvilCrawlerScent", function(ent)
	if ent:IsPlayer() then ent.EvilCrawlerHurt = CurTime() end
end)
