-- Utilities > Evil Crawling Thing > Settings: the server settings
-- (sh_settings.lua). Only superadmins can change them.
local SEND_DELAY = 0.25 -- a dragged slider sends once it settles
local SETTLE = 1 -- and stops following the server's value this long, for the change to come back

local function Send(s, value)
	s.pending = RealTime() + SEND_DELAY + SETTLE
	timer.Create("EvilCrawlerSetting_" .. s.name, SEND_DELAY, 1, function()
		if math.abs(GetConVar(s.convar):GetFloat() - value) < 1e-3 then return end
		net.Start("EvilCrawlerSetting")
		net.WriteString(s.convar)
		net.WriteString(tostring(value))
		net.SendToServer()
	end)
end

-- Whether a control should show the server's value: not while a change it
-- sent is still on its way.
local function Settled(s)
	return RealTime() > (s.pending or 0)
end

local function Admin(control)
	local ply = LocalPlayer()
	local admin = IsValid(ply) and ply:IsSuperAdmin()
	if control:IsEnabled() ~= admin then control:SetEnabled(admin) end
end

local function Build(panel)
	for _, s in ipairs(EvilCrawler.SETTINGS) do
		local cv = GetConVar(s.convar)
		local control
		if s.max == 1 and not s.decimals then
			control = panel:CheckBox(s.label)
			control:SetChecked(cv:GetBool())
			control.OnChange = function(_, on) Send(s, on and 1 or 0) end
			control.Think = function(self)
				Admin(self)
				if Settled(s) and self:GetChecked() ~= cv:GetBool() then self:SetChecked(cv:GetBool()) end
			end
		else
			control = panel:NumSlider(s.label, nil, s.min, s.max, s.decimals)
			control:SetValue(cv:GetFloat())
			control.OnValueChanged = function(_, value) Send(s, value) end
			control.Think = function(self)
				Admin(self)
				-- keep up with changes made elsewhere
				if Settled(s) and not self:IsEditing() and math.abs(self:GetValue() - cv:GetFloat()) > 1e-3 then self:SetValue(cv:GetFloat()) end
			end
		end
		control:SetTooltip(s.help)
	end
end

hook.Add("PopulateToolMenu", "EvilCrawlerSettings", function()
	spawnmenu.AddToolMenuOption("Utilities", "Evil Crawling Thing", "evil_crawler_settings", "Settings", "", "", Build)
end)
