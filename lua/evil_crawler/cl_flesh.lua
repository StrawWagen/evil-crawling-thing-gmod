-- Procedural flesh: lit tubes for limbs and a rippling blob for the core,
-- rebuilt as dynamic meshes every frame. Lighting is sampled once per frame
-- as an ambient cube and applied per vertex, since the material is unlit.
EvilCrawler = EvilCrawler or {}
local Flesh = {}
EvilCrawler.Flesh = Flesh

Flesh.Material = CreateMaterial("evil_crawler_flesh", "UnlitGeneric", {
	["$basetexture"] = "vgui/white",
	["$vertexcolor"] = 1,
	["$nocull"] = 1,
})

local AXES = { Vector(1, 0, 0), Vector(-1, 0, 0), Vector(0, 1, 0), Vector(0, -1, 0), Vector(0, 0, 1), Vector(0, 0, -1) }
local cube = { 0, 0, 0, 0, 0, 0 }

function Flesh.SampleLight(pos)
	for i, axis in ipairs(AXES) do
		local c = render.ComputeLighting(pos, axis) + render.ComputeDynamicLighting(pos, axis)
		cube[i] = (c.x + c.y + c.z) / 3
	end
end

local function Bright(nx, ny, nz)
	local l = nx * nx * (nx > 0 and cube[1] or cube[2])
		+ ny * ny * (ny > 0 and cube[3] or cube[4])
		+ nz * nz * (nz > 0 and cube[5] or cube[6])
	return math.min(1.6, 0.08 + math.sqrt(l) * 1.3)
end

local scratch = Vector()
local vx, vy, vz, vr, vg, vb = {}, {}, {}, {}, {}, {}

local function Vert(i, u, v)
	scratch:SetUnpacked(vx[i], vy[i], vz[i])
	mesh.Position(scratch)
	mesh.TexCoord(0, u, v)
	mesh.Color(math.min(255, vr[i]), math.min(255, vg[i]), math.min(255, vb[i]), 255)
	mesh.AdvanceVertex()
end

local trig = {}
local function Trig(sides)
	local t = trig[sides]
	if not t then
		t = { c = {}, s = {} }
		for k = 0, sides do
			local a = k / sides * math.pi * 2
			t.c[k], t.s[k] = math.cos(a), math.sin(a)
		end
		trig[sides] = t
	end
	return t
end

local function CatmullRom(p0, p1, p2, p3, t)
	local t2 = t * t
	local t3 = t2 * t
	return (p1 * 2 + (p2 - p0) * t + (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2 + (p1 * 3 - p0 - p2 * 3 + p3) * t3) * 0.5
end

local px, py, pz, pf = {}, {}, {}, {}

-- A smooth tube through the joint chain `pts`. radiusAt(f, data) and
-- colorAt(f, data) shape it along its length, f running 0 at the root to 1
-- at the tip. `sub` is curve samples per segment.
function Flesh.Tube(pts, sides, sub, radiusAt, colorAt, data)
	local n = #pts
	if n < 2 then return end

	local count = 0
	for i = 1, n - 1 do
		local p0, p1, p2, p3 = pts[math.max(i - 1, 1)], pts[i], pts[i + 1], pts[math.min(i + 2, n)]
		for s = 0, sub - 1 do
			local t = s / sub
			local p = CatmullRom(p0, p1, p2, p3, t)
			count = count + 1
			px[count], py[count], pz[count] = p.x, p.y, p.z
			pf[count] = (i - 1 + t) / (n - 1)
		end
	end
	count = count + 1
	px[count], py[count], pz[count], pf[count] = pts[n].x, pts[n].y, pts[n].z, 1

	-- rings around each sample, oriented by a parallel-transported frame so
	-- the tube doesn't twist
	local tr = Trig(sides)
	local nx, ny, nz
	for j = 1, count do
		local a, b = math.max(j - 1, 1), math.min(j + 1, count)
		local tx, ty, tz = px[b] - px[a], py[b] - py[a], pz[b] - pz[a]
		local tl = math.sqrt(tx * tx + ty * ty + tz * tz)
		if tl < 1e-6 then tx, ty, tz, tl = 0, 0, 1, 1 end
		tx, ty, tz = tx / tl, ty / tl, tz / tl

		if not nx then
			if math.abs(tz) < 0.9 then nx, ny, nz = 0, 0, 1 else nx, ny, nz = 1, 0, 0 end
		end
		local d = nx * tx + ny * ty + nz * tz
		nx, ny, nz = nx - tx * d, ny - ty * d, nz - tz * d
		local nl = math.sqrt(nx * nx + ny * ny + nz * nz)
		if nl < 1e-6 then
			if math.abs(tz) < 0.9 then nx, ny, nz = -ty, tx, 0 else nx, ny, nz = 0, -tz, ty end
			nl = math.sqrt(nx * nx + ny * ny + nz * nz)
		end
		nx, ny, nz = nx / nl, ny / nl, nz / nl
		local bx, by, bz = ty * nz - tz * ny, tz * nx - tx * nz, tx * ny - ty * nx

		local f = pf[j]
		local r = radiusAt(f, data)
		local cr, cg, cb = colorAt(f, data)
		for k = 0, sides - 1 do
			local c, s = tr.c[k], tr.s[k]
			local dx, dy, dz = nx * c + bx * s, ny * c + by * s, nz * c + bz * s
			local i = (j - 1) * sides + k + 1
			vx[i], vy[i], vz[i] = px[j] + dx * r, py[j] + dy * r, pz[j] + dz * r
			local l = Bright(dx, dy, dz)
			vr[i], vg[i], vb[i] = cr * l, cg * l, cb * l
		end
	end

	mesh.Begin(MATERIAL_QUADS, (count - 1) * sides)
	for j = 1, count - 1 do
		local v0, v1 = pf[j] * 4, pf[j + 1] * 4
		for k = 0, sides - 1 do
			local k2 = (k + 1) % sides
			local u0, u1 = k / sides, (k + 1) / sides
			Vert((j - 1) * sides + k + 1, u0, v0)
			Vert((j - 1) * sides + k2 + 1, u1, v0)
			Vert(j * sides + k2 + 1, u1, v1)
			Vert(j * sides + k + 1, u0, v1)
		end
	end
	mesh.End()
end

local gdx, gdy, gdz = {}, {}, {}

-- A deformed sphere. radiusAt(dx, dy, dz, data) gives the radius along a
-- local unit direction; fwd/left/up place local space in the world. Dips
-- below `nominal` radius are shaded darker, like folds.
function Flesh.Blob(center, fwd, left, up, rings, segs, radiusAt, nominal, cr, cg, cb, data)
	local row = segs + 1
	for i = 0, rings do
		local lat = i / rings * math.pi
		local sl, cl = math.sin(lat), math.cos(lat)
		for j = 0, segs do
			local lon = j / segs * math.pi * 2
			local lx, ly, lz = sl * math.cos(lon), sl * math.sin(lon), cl
			local r = radiusAt(lx, ly, lz, data)
			local wx = fwd.x * lx + left.x * ly + up.x * lz
			local wy = fwd.y * lx + left.y * ly + up.y * lz
			local wz = fwd.z * lx + left.z * ly + up.z * lz
			local idx = i * row + j + 1
			vx[idx], vy[idx], vz[idx] = center.x + wx * r, center.y + wy * r, center.z + wz * r
			gdx[idx], gdy[idx], gdz[idx] = wx, wy, wz
			vr[idx] = r / nominal -- stash for the shading pass below
		end
	end

	for i = 0, rings do
		for j = 0, segs do
			local idx = i * row + j + 1
			local dx, dy, dz = gdx[idx], gdy[idx], gdz[idx]
			local nx, ny, nz = dx, dy, dz
			if i > 0 and i < rings then
				local up_, dn = idx - row, idx + row
				local jl = j == 0 and segs - 1 or j - 1
				local jr = j == segs and 1 or j + 1
				local lf, rt = i * row + jl + 1, i * row + jr + 1
				local ax, ay, az = vx[dn] - vx[up_], vy[dn] - vy[up_], vz[dn] - vz[up_]
				local bx, by, bz = vx[rt] - vx[lf], vy[rt] - vy[lf], vz[rt] - vz[lf]
				local cx, cy, cz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
				local cl = math.sqrt(cx * cx + cy * cy + cz * cz)
				if cl > 1e-6 then
					if cx * dx + cy * dy + cz * dz < 0 then cl = -cl end
					nx, ny, nz = cx / cl, cy / cl, cz / cl
				end
			end
			local fold = math.Clamp(vr[idx], 0.8, 1.15)
			local l = Bright(nx, ny, nz) * fold * fold * fold
			vr[idx], vg[idx], vb[idx] = cr * l, cg * l, cb * l
		end
	end

	mesh.Begin(MATERIAL_QUADS, rings * segs)
	for i = 0, rings - 1 do
		local v0, v1 = i / rings, (i + 1) / rings
		for j = 0, segs - 1 do
			local u0, u1 = j / segs * 2, (j + 1) / segs * 2
			Vert(i * row + j + 1, u0, v0)
			Vert(i * row + j + 2, u1, v0)
			Vert((i + 1) * row + j + 2, u1, v1)
			Vert((i + 1) * row + j + 1, u0, v1)
		end
	end
	mesh.End()
end
