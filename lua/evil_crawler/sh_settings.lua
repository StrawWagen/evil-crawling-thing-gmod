EvilCrawler = EvilCrawler or {}

EvilCrawler.SETTINGS = {
	{ name = "attack_players", default = 1, min = 0, max = 1, label = "Goes for players",
		help = "Crawlers go for players too. At 0 they leave players alone entirely" },
	{ name = "npcs_fight", default = 1, min = 0, max = 1, label = "NPCs fight back",
		help = "NPCs treat crawlers as enemies and shoot at them" },
	{ name = "open_doors", default = 1, min = 0, max = 1, label = "Opens doors",
		help = "Crawlers force doors open, locked or not" },
	{ name = "squeeze", default = 1, min = 0, max = 1, label = "Squeezes through gaps",
		help = "Crawlers shrink down to follow through vents, crawlspaces and low holes" },
	{ name = "victim_voices", default = 1, min = 0, max = 1, label = "Victims cry out",
		help = "Grabbed NPCs and players scream for help and cry out while it has them" },
	{ name = "struggle_time", default = 3.5, min = 0.5, max = 15, decimals = 1, label = "Struggle time",
		help = "Seconds a grabbed player has to fight free before going under" },
	{ name = "sedate_time", default = 10, min = 0.1, max = 60, decimals = 1, label = "Sedate time",
		help = "Seconds a held NPC takes to go under" },
	{ name = "digest_time", default = 10, min = 0, max = 120, decimals = 0, label = "Digest time",
		help = "Seconds a crawler leaves players alone after a meal, unless they've hurt it" },
	{ name = "reroute_time", default = 0.6, min = 0.1, max = 5, decimals = 1, label = "Reroute time",
		help = "Seconds a crawler stays over someone it can't reach before going round another way" },
	{ name = "sated_time", default = 90, min = 0, max = 600, decimals = 0, label = "Sated time",
		help = "Seconds a meal keeps a crawler from going after NPCs. Anger shortens it" },
	{ name = "hide_time", default = 40, min = 0, max = 180, decimals = 0, label = "Hide time",
		help = "Seconds, give or take a third, a crawler has to stay unseen after it's hurt before coming back" },
	{ name = "flee_hits", default = 1, min = 1, max = 50, decimals = 0, label = "Flee hits",
		help = "Hits inside 30 seconds before a crawler runs off to hide" },
	{ name = "rage_hits", default = 6, min = 1, max = 50, decimals = 0, label = "Rage hits",
		help = "Hits inside 30 seconds that send a crawler into a rage" },
	{ name = "rage_time", default = 10, min = 0, max = 60, decimals = 0, label = "Rage time",
		help = "Seconds a rage lasts. At 0 it never rages" },
	{ name = "npc_hits", default = 0.1, min = 0, max = 1, decimals = 2, label = "NPC hit weight",
		help = "How much an NPC's hit counts toward rage and knockouts, next to a player's" },
	{ name = "knockout_hits", default = 6, min = 0, max = 50, decimals = 0, label = "Knockout hits",
		help = "Hits while it's raging that knock it out cold. At 0 it never goes down" },
	{ name = "knockout_anytime", default = 0, min = 0, max = 1, label = "Knock out anytime",
		help = "Knockout hits count when it isn't raging too, inside 30 seconds" },
	{ name = "knockout_time", default = 25, min = 1, max = 120, decimals = 0, label = "Knockout time",
		help = "Seconds, give or take a fifth, it stays down" },
	{ name = "tired_time", default = 20, min = 0, max = 120, decimals = 0, label = "Tired time",
		help = "Seconds of chasing it takes to get its full speed back after a knockout. At 0 it wakes up fresh" },
	{ name = "killable", default = 1, min = 0, max = 1, label = "Killable",
		help = "Enough hits from players while it's knocked out kills it" },
	{ name = "escape_tighten", default = 0.5, min = 0, max = 3, decimals = 2, label = "Coil tightening",
		help = "How much harder the coil is to fight out of for each time that player got away lately" },
	{ name = "burst", default = 1100, min = 100, max = 3000, decimals = 0, label = "Dart speed",
		help = "Top speed of a dart" },
	{ name = "sight_range", default = 4000, min = 0, max = 10000, decimals = 0, label = "Sight range",
		help = "How far crawlers can see" },
	{ name = "hearing", default = 1, min = 0, max = 5, decimals = 1, label = "Hearing",
		help = "How far crawlers hear gunfire, explosions, running and other loud sounds. At 0 they're deaf" },
	{ name = "show_scent", default = 0, min = 0, max = 1, label = "Show scent trails",
		help = "Marks scent trails on the ground for everyone: players amber, NPCs green, fear magenta, "
			.. "a trail a crawler is following cyan, and the spot it's heading for ringed" },
}

local convars, byConVar = {}, {}
for _, s in ipairs(EvilCrawler.SETTINGS) do
	s.convar = "evil_crawler_" .. s.name
	convars[s.name] = CreateConVar(s.convar, tostring(s.default), bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED), s.help, s.min, s.max)
	byConVar[s.convar] = s
end

function EvilCrawler.Setting(name)
	return convars[name]:GetFloat()
end

if CLIENT then return end

util.AddNetworkString("EvilCrawlerSetting")

net.Receive("EvilCrawlerSetting", function(_, ply)
	local s = byConVar[net.ReadString()]
	local value = tonumber(net.ReadString())
	if not s or not value or not IsValid(ply) or not ply:IsSuperAdmin() then return end
	RunConsoleCommand(s.convar, tostring(math.Clamp(value, s.min, s.max)))
end)
