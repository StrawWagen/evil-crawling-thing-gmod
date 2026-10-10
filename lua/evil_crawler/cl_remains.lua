-- What's left where a part was eaten away: the limb itself is shrunk to
-- nothing on the server, and this draws the stump it leaves behind (a wet
-- cap of meat, a splintered end of bone, ragged strings of sinew) and lets it
-- drip for a while.
EvilCrawler = EvilCrawler or {}
local Flesh = EvilCrawler.Flesh
local PARTS = EvilCrawler.PARTS
local EATEN_VAR = EvilCrawler.EATEN_VAR

local SCAN_INTERVAL = 0.5
local DRIP_TIME = 25 -- a fresh stump drips this long
local DRAW_DISTANCE = 2500
local STRANDS = 5

local MEAT = Color(70, 6, 9)
local SINEW = Color(120, 22, 24)
local MARROW = Color(205, 190, 170)

local remains = {} -- ragdoll -> { [part] = { at = time eaten, shape = the stump's random look } }

-- A stump's look, made once and kept: which way the bone and each strand of
-- sinew stick out, as offsets from the line of the limb that was there.
local function Shape(size)
	local strands = {}
	for i = 1, STRANDS do
		strands[i] = { x = math.Rand(-0.9, 0.9), y = math.Rand(-0.9, 0.9), len = size * math.Rand(1, 2.4), droop = math.Rand(0.3, 1) }
	end
	return { bone = { x = math.Rand(-0.25, 0.25), y = math.Rand(-0.25, 0.25), len = size * math.Rand(1.2, 2) }, strands = strands }
end

timer.Create("EvilCrawlerRemains", SCAN_INTERVAL, 0, function()
	for _, rag in ipairs(ents.FindByClass("prop_ragdoll")) do
		local mask = rag:GetNWInt(EATEN_VAR, 0)
		if mask ~= 0 then
			local r = remains[rag] or {}
			remains[rag] = r
			for i, part in ipairs(PARTS) do
				if not r[i] and bit.band(mask, bit.lshift(1, i - 1)) ~= 0 then
					r[i] = { at = CurTime(), shape = Shape(part.size) }
				end
			end
		end
	end

	local now = CurTime()
	for rag, r in pairs(remains) do
		if not IsValid(rag) then
			remains[rag] = nil
		elseif not rag:IsDormant() then
			for i, stump in pairs(r) do
				local age = now - stump.at
				if age < DRIP_TIME and math.random() < 0.8 * (1 - age / DRIP_TIME) then
					local b = rag:LookupBone(PARTS[i].root)
					local p = b and rag:GetBonePosition(b)
					if p then
						local fx = EffectData()
						fx:SetOrigin(p)
						fx:SetNormal(-vector_up)
						util.Effect("BloodImpact", fx)
						if math.random() < 0.35 then util.Decal("Blood", p, p - vector_up * 256, rag) end
					end
				end
			end
		end
	end
end)

local function Taper(f, size) return size * (1 - 0.8 * f) end
local function Cap(f, size) return size * (1.15 - 0.55 * f * f) end
local function Splinter(f, size) return size * 0.32 * (1 - 0.6 * f) end

local function Solid(c)
	return function() return c.r, c.g, c.b end
end
local MeatColor, SinewColor = Solid(MEAT), Solid(SINEW)
local function BoneColor(f)
	-- bloodied where it leaves the meat
	local k = math.Clamp(f * 1.6, 0, 1)
	return Lerp(k, MEAT.r, MARROW.r), Lerp(k, MEAT.g, MARROW.g), Lerp(k, MEAT.b, MARROW.b)
end

local pts2, pts3 = {}, {}

local function DrawStump(rag, part, shape)
	local b = rag:LookupBone(part.root)
	local parent = b and rag:GetBoneParent(b)
	if not parent or parent < 0 then return end
	local p, pp = rag:GetBonePosition(b), rag:GetBonePosition(parent)
	if not p or not pp then return end

	-- the stump faces the way the limb used to hang off it
	local child = rag:GetChildBones(b)[1]
	local cp = child and rag:GetBonePosition(child)
	local d = cp and cp - p or p - pp
	if d:LengthSqr() < 1e-4 then d = p - pp end
	d:Normalize()
	local ang = d:Angle()
	local u, v = ang:Right(), ang:Up()
	local size = part.size

	Flesh.SampleLight(p)

	pts2[1], pts2[2] = p - d * size * 0.9, p + d * size * 0.35
	Flesh.Tube(pts2, 7, 2, Cap, MeatColor, size)

	local bone = shape.bone
	pts2[1] = p - d * size * 0.3
	pts2[2] = p + (d + u * bone.x + v * bone.y):GetNormalized() * bone.len
	Flesh.Tube(pts2, 5, 2, Splinter, BoneColor, size)

	for _, s in ipairs(shape.strands) do
		local dir = (d + u * s.x + v * s.y):GetNormalized()
		local tip = p + dir * s.len - vector_up * (s.len * 0.4 * s.droop)
		pts3[1] = p + (u * s.x + v * s.y) * size * 0.5
		pts3[2] = p + dir * (s.len * 0.5) - vector_up * (s.len * 0.1 * s.droop)
		pts3[3] = tip
		Flesh.Tube(pts3, 4, 2, Taper, SinewColor, size * 0.22)
	end
end

hook.Add("PostDrawOpaqueRenderables", "EvilCrawlerRemains", function(depth, sky)
	if sky or not next(remains) then return end
	local eye = EyePos()
	render.SetMaterial(Flesh.Material)
	for rag, r in pairs(remains) do
		if IsValid(rag) and not rag:IsDormant() and rag:GetPos():DistToSqr(eye) < DRAW_DISTANCE * DRAW_DISTANCE then
			for i, stump in pairs(r) do DrawStump(rag, PARTS[i], stump.shape) end
		end
	end
end)
