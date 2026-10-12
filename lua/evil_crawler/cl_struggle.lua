-- What a player in the coil sees: the jump key, jolting with every press, and
-- how loose they've worked themselves; the world closing in and draining as
-- they go under. Once they've lost and are watching their own body, it stays
-- that way.
EvilCrawler = EvilCrawler or {}

local ACT_GRAPPLE = EvilCrawler.ACT_GRAPPLE

local KEY_SIZE = { 150, 44 }
local KEY_Y = 0.7 -- share of the way down the screen
local BAR_SIZE = { 220, 6 }
local BAR_GAP = 14
local PULSE_TIME = 0.12
local VIGNETTE_STEPS = 24
local VIGNETTE_DEPTH = 0.45 -- share of the screen height the dark reaches in, fully under

local BONE = Color(170, 160, 145)
local KEY_BG = Color(10, 8, 9, 200)
local BAR_BG = Color(255, 255, 255, 25)

surface.CreateFont("EvilCrawlerKey", { font = "Roboto", size = 26, weight = 800 })

local shownFree = 0

-- How far under the local player is, 0..1, and the crawler that has them.
local function Pressure()
	local ply = LocalPlayer()
	if not IsValid(ply) then return 0 end

	local holder = EvilCrawler.Holder(ply)
	if holder then
		if holder:GetAct() ~= ACT_GRAPPLE then return 0, holder end
		return math.Clamp((CurTime() - holder:GetActStart()) / EvilCrawler.StruggleTime(), 0, 1), holder
	end

	local watching = ply:GetObserverTarget()
	if IsValid(watching) and watching:GetNW2Entity(EvilCrawler.OWNER_VAR) == ply then return 1 end
	return 0
end

local function Vignette(k)
	local w, h = ScrW(), ScrH()
	local step = h * VIGNETTE_DEPTH * k / VIGNETTE_STEPS
	if step < 0.5 then return end
	for i = 0, VIGNETTE_STEPS - 1 do
		local a = 235 * k * (1 - i / VIGNETTE_STEPS) ^ 1.5
		surface.SetDrawColor(0, 0, 0, a)
		local inset = i * step
		surface.DrawRect(inset, inset, w - inset * 2, step)
		surface.DrawRect(inset, h - inset - step, w - inset * 2, step)
		surface.DrawRect(inset, inset + step, step, h - inset * 2 - step * 2)
		surface.DrawRect(w - inset - step, inset + step, step, h - inset * 2 - step * 2)
	end
end

hook.Add("HUDPaint", "EvilCrawlerStruggle", function()
	local k, holder = Pressure()
	if k > 0 then Vignette(k) end
	if not holder then
		shownFree = 0
		return
	end

	local ply = LocalPlayer()
	local free = ply:GetNW2Float(EvilCrawler.FREE_VAR, 0)
	shownFree = Lerp(math.min(1, FrameTime() * 15), shownFree, free)
	local pulse = math.Clamp(1 - (RealTime() - (ply.EvilCrawlerPressed or 0)) / PULSE_TIME, 0, 1)
	local shake = 1 + 3 * k

	local cx = ScrW() * 0.5 + math.Rand(-shake, shake)
	local cy = ScrH() * KEY_Y + math.Rand(-shake, shake) + 3 * pulse
	local kw, kh = KEY_SIZE[1], KEY_SIZE[2]
	local x, y = cx - kw * 0.5, cy - kh * 0.5

	draw.RoundedBox(6, x, y, kw, kh, KEY_BG)
	local lit = Lerp(pulse, 0, 85)
	local c = Color(math.min(255, BONE.r + lit), math.min(255, BONE.g + lit), math.min(255, BONE.b + lit))
	surface.SetDrawColor(c)
	surface.DrawOutlinedRect(x, y, kw, kh, 2)
	local key = input.LookupBinding("+jump") or "space"
	draw.SimpleText(key:upper(), "EvilCrawlerKey", cx, cy, c, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)

	local bw, bh = BAR_SIZE[1], BAR_SIZE[2]
	local bx, by = cx - bw * 0.5, y + kh + BAR_GAP
	surface.SetDrawColor(BAR_BG)
	surface.DrawRect(bx, by, bw, bh)
	surface.SetDrawColor(BONE)
	surface.DrawRect(bx, by, bw * math.Clamp(shownFree, 0, 1), bh)
end)

hook.Add("RenderScreenspaceEffects", "EvilCrawlerStruggle", function()
	local k = Pressure()
	if k <= 0 then return end
	DrawColorModify({
		["$pp_colour_addr"] = 0.06 * k,
		["$pp_colour_addg"] = 0,
		["$pp_colour_addb"] = 0,
		["$pp_colour_brightness"] = -0.12 * k,
		["$pp_colour_contrast"] = 1 + 0.1 * k,
		["$pp_colour_colour"] = 1 - 0.7 * k,
		["$pp_colour_mulr"] = 0,
		["$pp_colour_mulg"] = 0,
		["$pp_colour_mulb"] = 0,
	})
	DrawMotionBlur(0.15, 0.5 * k, 0.01)
end)

hook.Add("HUDShouldDraw", "EvilCrawlerStruggle", function(name)
	if name == "CHudCrosshair" and IsValid(LocalPlayer()) and EvilCrawler.Holder(LocalPlayer()) then return false end
end)

-- A player's body wears their colour.
hook.Add("EntityNetworkedVarChanged", "EvilCrawlerStruggle", function(ent, name, _, value)
	if name ~= EvilCrawler.COLOR_VAR then return end
	ent.GetPlayerColor = function() return value end
end)
