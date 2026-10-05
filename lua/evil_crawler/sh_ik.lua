EvilCrawler = EvilCrawler or {}

-- FABRIK. `points` is a starting guess for the joint chain and is solved in
-- place so it runs from root toward target with fixed segment lengths. The
-- shape of the guess decides which way the chain bends.
function EvilCrawler.SolveChain(points, lengths, root, target, iterations)
	local n = #points
	for _ = 1, iterations do
		points[n] = target
		for i = n - 1, 1, -1 do
			points[i] = points[i + 1] + (points[i] - points[i + 1]):GetNormalized() * lengths[i]
		end
		points[1] = root
		for i = 2, n do
			points[i] = points[i - 1] + (points[i] - points[i - 1]):GetNormalized() * lengths[i - 1]
		end
	end
end
