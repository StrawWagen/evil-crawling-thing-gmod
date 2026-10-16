EvilCrawler = EvilCrawler or {}
local Hearing = EvilCrawler.Hearing or {}
EvilCrawler.Hearing = Hearing

local KEEP = 2
local QUIET = 80
local LOUDEST = 4000
local NEAR = 300
local MERGE = 200
local GUNFIRE = 3000
local BLAST = 4000
local SPRINT, STEP = 700, 300
local SNEAK = 150

Hearing.noises = Hearing.noises or {}
Hearing.crawlers = Hearing.crawlers or {}

function Hearing.Make(pos, range, source)
	if not next(Hearing.crawlers) then return end
	for crawler in pairs(Hearing.crawlers) do
		if IsValid(crawler) and crawler:GetPos():Distance(pos) < NEAR then return end
	end
	local now, noises = CurTime(), Hearing.noises
	while noises[1] and now - noises[1].time > KEEP do table.remove(noises, 1) end
	for i = #noises, 1, -1 do
		local n = noises[i]
		if now - n.time > 0.5 then break end
		if n.pos:Distance(pos) < MERGE then
			n.range = math.max(n.range, range)
			return
		end
	end
	noises[#noises + 1] = { pos = pos, range = range, time = now, source = IsValid(source) and source or nil }
end

hook.Add("OnEntityCreated", "EvilCrawlerHearing", function(ent)
	if ent:GetClass() == "evil_crawler" then Hearing.crawlers[ent] = true end
end)

hook.Add("EntityRemoved", "EvilCrawlerHearing", function(ent)
	Hearing.crawlers[ent] = nil
end)

hook.Add("EntityEmitSound", "EvilCrawlerHearing", function(data)
	local level = data.SoundLevel or 0
	if level < QUIET or not next(Hearing.crawlers) then return end
	local ent = data.Entity
	local pos = data.Pos or IsValid(ent) and ent:GetPos()
	if not pos then return end
	if IsValid(ent) and (ent.EvilCrawlerVictim or ent.EvilCrawlerOwner) then return end
	Hearing.Make(pos, math.min(LOUDEST, 1000 * 2 ^ ((level - QUIET) / 10)) * math.sqrt(data.Volume or 1), ent)
end)

hook.Add("EntityFireBullets", "EvilCrawlerHearing", function(shooter, data)
	Hearing.Make(data.Src, GUNFIRE, IsValid(data.Attacker) and data.Attacker or shooter)
end)

hook.Add("EntityTakeDamage", "EvilCrawlerHearing", function(ent, dmg)
	if dmg:IsExplosionDamage() then Hearing.Make(dmg:GetDamagePosition(), BLAST, dmg:GetAttacker()) end
end)

hook.Add("PlayerFootstep", "EvilCrawlerHearing", function(ply, pos)
	if ply:Crouching() or not ply:IsOnGround() then return end
	local speed = ply:GetVelocity():Length2D()
	if speed < SNEAK then return end
	Hearing.Make(pos, speed > ply:GetWalkSpeed() * 1.1 and SPRINT or STEP, ply)
end)

for _, ent in ipairs(ents.FindByClass("evil_crawler")) do Hearing.crawlers[ent] = true end
