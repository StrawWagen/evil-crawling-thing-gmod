-- A player in the coil. Their arms are pinned and their feet are off the
-- ground; all they can do is look around and fight it, by hammering jump.
-- Each press works them a little looser, and the coil keeps tightening. Get
-- all the way loose before they go under and they're out (sv_attack.lua).
EvilCrawler = EvilCrawler or {}

EvilCrawler.HELD_VAR = "EvilCrawlerHeld" -- on the player: the crawler that has them
EvilCrawler.FREE_VAR = "EvilCrawlerFree" -- on the player: how loose they've worked themselves, 0..1
EvilCrawler.OWNER_VAR = "EvilCrawlerOwner" -- on a body: the player it is
EvilCrawler.COLOR_VAR = "EvilCrawlerColor" -- on a body: its player's colour

function EvilCrawler.StruggleTime()
	return math.max(0.5, EvilCrawler.Setting("struggle_time"))
end

function EvilCrawler.Holder(ply)
	local holder = ply:GetNW2Entity(EvilCrawler.HELD_VAR)
	return IsValid(holder) and holder
end

hook.Add("StartCommand", "EvilCrawlerStruggle", function(ply, cmd)
	local holder = EvilCrawler.Holder(ply)
	if not holder then
		ply.EvilCrawlerJump = nil
		return
	end

	local jump = cmd:KeyDown(IN_JUMP)
	if jump and not ply.EvilCrawlerJump then
		if SERVER then
			holder:Struggled(ply)
		else
			ply.EvilCrawlerPressed = RealTime()
		end
	end
	ply.EvilCrawlerJump = jump

	cmd:ClearMovement()
	cmd:ClearButtons()
end)
