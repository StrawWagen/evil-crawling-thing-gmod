EvilCrawler = EvilCrawler or {}

EvilCrawler.HELD_VAR = "EvilCrawlerHeld"
EvilCrawler.FREE_VAR = "EvilCrawlerFree"
EvilCrawler.OWNER_VAR = "EvilCrawlerOwner"
EvilCrawler.COLOR_VAR = "EvilCrawlerColor"

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
	if CLIENT and jump then cmd:SetButtons(IN_JUMP) end
end)
