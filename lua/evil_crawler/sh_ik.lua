EvilCrawler = EvilCrawler or {}

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
