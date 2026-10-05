EvilCrawler = EvilCrawler or {}

-- Park-Miller PRNG, so a seed grows the same creature on the server and every
-- client without touching the global math.random state.
local function Rng(seed)
	local s = seed % 2147483646 + 1
	return function(a, b)
		s = s * 16807 % 2147483647
		local f = (s - 1) / 2147483646
		return a and a + f * (b - a) or f
	end
end

local function Int(rand, a, b)
	return math.floor(rand(a, b + 1))
end

-- Random point on a sphere of radius r, with z limited to [minZ, maxZ] (-1..1).
local function OnSphere(rand, r, minZ, maxZ)
	local yaw = math.rad(rand(0, 360))
	local z = rand(minZ, maxZ)
	local flat = math.sqrt(1 - z * z)
	return Vector(math.cos(yaw) * flat * r, math.sin(yaw) * flat * r, z * r)
end

-- Uneven segment lengths adding up to `total`.
local function Segments(rand, count, total)
	local lengths, sum = {}, 0
	for i = 1, count do
		lengths[i] = rand(0.6, 1.4)
		sum = sum + lengths[i]
	end
	for i = 1, count do
		lengths[i] = lengths[i] / sum * total
	end
	return lengths
end

-- A swollen, churning core with every limb growing out of it. Three kinds:
--   leg    walks: plants a foot and steps when it drifts
--   knot   a sinew looping over the core's surface from one point to another
--   feeler rises and sways, and reaches for anyone who comes close
function EvilCrawler.Grow(seed)
	local rand = Rng(seed)
	local radius = rand(13, 17)
	local creature = {
		limbs = {},
		legs = {},
		churn = rand(-30, 30),
		phase = rand(0, 100),
		core = {
			radius = radius,
			stretch = Vector(rand(1.1, 1.5), rand(0.8, 1.1), rand(0.6, 0.85)),
			waves = {},
		},
	}
	local stretch = creature.core.stretch

	-- two slow swells that keep the core misshapen, then finer ripples
	for i = 1, 6 do
		local d = OnSphere(rand, 1, -1, 1)
		local slow = i <= 2
		creature.core.waves[i] = {
			x = d.x, y = d.y, z = d.z,
			freq = slow and rand(1, 2) or rand(3, 6),
			speed = slow and rand(0.2, 0.6) or rand(0.5, 2),
			phase = rand(0, math.pi * 2),
			amp = slow and rand(0.1, 0.18) or rand(0.02, 0.05),
		}
	end

	-- a point inside the core, `depth` of the way out to its surface;
	-- roots sit deep so limbs grow out of the mass instead of ending at it
	local function inside(depth, minZ, maxZ)
		local p = OnSphere(rand, radius * depth, minZ, maxZ)
		return Vector(p.x * stretch.x, p.y * stretch.y, p.z * stretch.z)
	end

	local function add(limb)
		limb.lengths = Segments(rand, limb.segments, limb.length)
		limb.rootDir = limb.root:GetNormalized()
		limb.swell = limb.width / radius * 0.6 -- how much the core bulges where it grows out
		limb.phase = rand(0, 100)
		limb.freq = rand(0.6, 2.4)
		limb.shade = rand(0.75, 1.2)
		creature.limbs[#creature.limbs + 1] = limb
		return limb
	end

	local legCount = Int(rand, 7, 10)
	local reach = 0
	for i = 1, legCount do
		local length = rand(150, 230)
		reach = reach + length
		creature.legs[i] = add({
			kind = "leg",
			root = inside(0.35, -0.3, 0.9),
			angle = (i - 1) / legCount * 360 + rand(-14, 14),
			spread = rand(0.45, 0.65),
			segments = Int(rand, 3, 5),
			length = length,
			width = rand(5, 9),
			stepDistance = rand(35, 65),
			stepTime = rand(0.2, 0.34),
			stepHeight = rand(20, 45),
			pitch = Int(rand, 55, 120),
		})
	end
	creature.height = reach / legCount * 0.36

	for _ = 1, Int(rand, 3, 5) do
		local root = inside(0.55, -0.6, 1)
		local tip = inside(0.55, -0.6, 1)
		add({
			kind = "knot",
			root = root,
			tip = tip,
			segments = Int(rand, 3, 4),
			length = root:Distance(tip) * rand(1.3, 1.7) + radius * 0.6,
			width = rand(3, 5),
		})
	end

	for _ = 1, Int(rand, 2, 4) do
		add({
			kind = "feeler",
			root = inside(0.4, 0.2, 1),
			segments = Int(rand, 6, 8),
			length = rand(120, 200),
			width = rand(3, 6),
		})
	end

	-- legs wait for the legs beside them to land before stepping
	local gap = 360 / legCount * 1.6
	for _, leg in ipairs(creature.legs) do
		leg.neighbours = {}
		for _, other in ipairs(creature.legs) do
			if other ~= leg and math.abs(math.AngleDifference(leg.angle, other.angle)) < gap then
				leg.neighbours[#leg.neighbours + 1] = other
			end
		end
	end

	return creature
end
