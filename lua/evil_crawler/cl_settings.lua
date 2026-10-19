local SEND_DELAY = 0.25
local SETTLE = 1

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

local function Settled(s)
	return RealTime() > (s.pending or 0)
end

local function Pack(c)
	return math.Round(c.r) * 65536 + math.Round(c.g) * 256 + math.Round(c.b)
end

local function Admin(control)
	local ply = LocalPlayer()
	local admin = IsValid(ply) and ply:IsSuperAdmin()
	if control:IsEnabled() ~= admin then control:SetEnabled(admin) end
end

local function Build(panel)
	panel:CheckBox("Show the mash prompt", "evil_crawler_struggle_prompt")
	for _, s in ipairs(EvilCrawler.SETTINGS) do
		local cv = GetConVar(s.convar)
		local control
		if s.color then
			panel:Help(s.label)
			control = vgui.Create("DColorMixer")
			control:SetAlphaBar(false)
			control:SetTall(180)
			panel:AddItem(control)
			control:SetColor(EvilCrawler.FleshColor())
			control.ValueChanged = function(_, c) Send(s, Pack(c)) end
			control.Think = function(self)
				local ply = LocalPlayer()
				self:SetMouseInputEnabled(IsValid(ply) and ply:IsSuperAdmin())
				if Settled(s) and Pack(self:GetColor()) ~= cv:GetInt() then self:SetColor(EvilCrawler.FleshColor()) end
			end
		elseif s.max == 1 and not s.decimals then
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
				if Settled(s) and not self:IsEditing() and math.abs(self:GetValue() - cv:GetFloat()) > 1e-3 then self:SetValue(cv:GetFloat()) end
			end
		end
		control:SetTooltip(s.help)
	end
	local reset = panel:Button("Reset to defaults")
	reset.DoClick = function()
		for _, s in ipairs(EvilCrawler.SETTINGS) do Send(s, s.default) end
	end
	reset.Think = Admin
end

hook.Add("PopulateToolMenu", "EvilCrawlerSettings", function()
	spawnmenu.AddToolMenuOption("Utilities", "Syhgma's Evil Entities", "evil_crawler_settings", "Evil Crawling Thing", "", "", Build)
end)
