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

-- Every limb grows out of a small core. Three kinds:
--   leg    walks: plants a foot and steps when it drifts
--   knot   loops from one point on the core back into another, forming the mass
--   feeler rises and sways, and reaches for anyone who comes close
function EvilCrawler.Grow(seed)
	local rand = Rng(seed)
	local core = rand(7, 11)
	local creature = {
		limbs = {},
		legs = {},
		churn = rand(-35, 35),
		phase = rand(0, 100),
	}

	local function add(limb)
		limb.lengths = Segments(rand, limb.segments, limb.length)
		limb.phase = rand(0, 100)
		limb.freq = rand(0.6, 2.4)
		limb.shade = rand(0.7, 1.25)
		creature.limbs[#creature.limbs + 1] = limb
		return limb
	end

	local legCount = Int(rand, 7, 11)
	local reach = 0
	for i = 1, legCount do
		local length = rand(60, 105)
		reach = reach + length
		creature.legs[i] = add({
			kind = "leg",
			root = OnSphere(rand, core, -0.3, 0.95),
			angle = (i - 1) / legCount * 360 + rand(-14, 14),
			spread = rand(0.45, 0.7),
			segments = Int(rand, 3, 5),
			length = length,
			width = rand(2.5, 5),
			stepDistance = rand(14, 28),
			stepTime = rand(0.12, 0.26),
			stepHeight = rand(8, 22),
			pitch = Int(rand, 80, 190),
		})
	end
	creature.height = reach / legCount * 0.38

	for _ = 1, Int(rand, 4, 7) do
		add({
			kind = "knot",
			root = OnSphere(rand, core, -0.6, 1),
			tip = OnSphere(rand, core, -0.6, 1),
			segments = Int(rand, 3, 5),
			length = rand(core * 2.5, core * 4.5),
			width = rand(3, 6),
		})
	end

	for _ = 1, Int(rand, 2, 4) do
		add({
			kind = "feeler",
			root = OnSphere(rand, core, 0.2, 1),
			segments = Int(rand, 5, 7),
			length = rand(50, 110),
			width = rand(1.5, 3),
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
