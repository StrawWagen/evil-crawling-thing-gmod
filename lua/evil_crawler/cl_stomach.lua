local TEXT = Color(230, 230, 230)

local function Parts(v)
	return ("%d/%d"):format(v.parts or 0, #EvilCrawler.PARTS)
end

Evil.StomachView({
	class = "evil_crawler",
	title = "Evil Crawling Thing stomach",
	top = 66,
	columns = {
		{ "Parts", 50, function(v) return Parts(v), v.parts or 0 end },
	},
	summary = function(view)
		local s = view.summary
		local know = {}
		for trick, k in SortedPairs(s.know or {}) do know[#know + 1] = ("%s %.2f"):format(view.Title(trick), k) end
		draw.SimpleText(("%d parts eaten    Knows %s"):format(s.gorged or 0, #know > 0 and table.concat(know, ", ") or "nothing"),
			"DermaDefault", 8, 42, TEXT)
	end,
	info = function(view, v)
		view:Pair("Parts eaten", Parts(v))
	end,
})
