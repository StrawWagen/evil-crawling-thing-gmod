EvilCrawler = EvilCrawler or {}

-- Two-bone IK for a leg rooted at `hip` reaching for `target`, bending toward
-- the `pole` direction. Returns knee and foot. The foot stops short of the
-- target when it's out of reach.
function EvilCrawler.SolveTwoBone(hip, target, upper, lower, pole)
	local toTarget = target - hip
	local dist = toTarget:Length()
	local dir = dist > 0.001 and toTarget / dist or pole:GetNormalized()
	dist = math.Clamp(dist, math.abs(upper - lower) + 0.01, upper + lower - 0.01)

	local cosHip = (upper * upper + dist * dist - lower * lower) / (2 * upper * dist)
	local sinHip = math.sqrt(math.max(0, 1 - cosHip * cosHip))

	local bend = pole - dir * pole:Dot(dir)
	if bend:LengthSqr() < 0.0001 then bend = dir:Angle():Up() end
	bend:Normalize()

	local knee = hip + dir * (cosHip * upper) + bend * (sinHip * upper)
	return knee, hip + dir * dist
end
