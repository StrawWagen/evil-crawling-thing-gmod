EvilCrawler = EvilCrawler or {}

local ACT_GRAPPLE = EvilCrawler.ACT_GRAPPLE

local KEY_SIZE = { 150, 44 }
local KEY_Y = 0.7
local BAR_SIZE = { 220, 6 }
local BAR_GAP = 14
local PULSE_TIME = 0.12
local VIGNETTE_STEPS = 24
local VIGNETTE_DEPTH = 0.45
local WATCHING = 0.55
local ORBIT_DISTANCE = 3.6
local ORBIT_DRIFT = 7
local ORBIT_PITCH = { 5, 75 }
local ORBIT_TILT = 25
local FOCUS_RATE = 6
local UP_RATE = 3

local BONE = Color(170, 160, 145)
local KEY_BG = Color(10, 8, 9, 200)
local BAR_BG = Color(255, 255, 255, 25)

surface.CreateFont("EvilCrawlerKey", { font = "Roboto", size = 26, weight = 800 })

local shownFree = 0

function EvilCrawler.Devoured(ply)
	if ply:GetObserverMode() == OBS_MODE_NONE then return end
	local target = ply:GetObserverTarget()
	if not IsValid(target) then return end
	if target:GetClass() == "evil_crawler" or target:GetNW2Entity(EvilCrawler.OWNER_VAR) == ply then return target end
end

local function Pressure()
	local ply = LocalPlayer()
	if not IsValid(ply) then return 0 end

	local holder = EvilCrawler.Holder(ply)
	if holder then
		if holder:GetAct() ~= ACT_GRAPPLE then return 0, holder end
		return math.Clamp((CurTime() - holder:GetActStart()) / EvilCrawler.StruggleTime(), 0, 1), holder
	end

	if EvilCrawler.Devoured(ply) then return WATCHING end
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

hook.Add("EntityNetworkedVarChanged", "EvilCrawlerStruggle", function(ent, name, _, value)
	if name ~= EvilCrawler.COLOR_VAR then return end
	ent.GetPlayerColor = function() return value end
end)

local focus, orbitUp

hook.Add("CalcView", "EvilCrawlerDevoured", function(ply, _, angles, fov)
	local target = EvilCrawler.Devoured(ply)
	if not target then
		focus, orbitUp = nil, nil
		return
	end

	local crawler = target:GetClass() == "evil_crawler"
	local want = crawler and target:GetPos() or target:WorldSpaceCenter()
	local wantUp = crawler and target:GetUp() or vector_up
	local dt = FrameTime()
	focus = focus and LerpVector(math.min(1, dt * FOCUS_RATE), focus, want) or want
	orbitUp = orbitUp and LerpVector(math.min(1, dt * UP_RATE), orbitUp, wantUp):GetNormalized() or wantUp

	local yaw = math.rad(angles.y + 180 + RealTime() * ORBIT_DRIFT)
	local around = Vector(math.cos(yaw), math.sin(yaw), 0)
	around = around - orbitUp * around:Dot(orbitUp)
	if around:LengthSqr() < 1e-4 then around = orbitUp:Angle():Right() end
	around:Normalize()
	local pitch = math.rad(math.Clamp(angles.p + ORBIT_TILT, ORBIT_PITCH[1], ORBIT_PITCH[2]))
	local out = around * math.cos(pitch) + orbitUp * math.sin(pitch)

	local reach = (crawler and target.BodyHeight or 40) * ORBIT_DISTANCE
	local tr = util.TraceLine({ start = focus, endpos = focus + out * reach, mask = MASK_SOLID_BRUSHONLY })
	local eye = tr.HitPos + tr.HitNormal * 6

	return { origin = eye, angles = (focus - eye):Angle(), fov = fov, drawviewer = false }
end)
