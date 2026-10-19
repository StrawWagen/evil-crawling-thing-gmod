if not file.Exists("evil_api/init.lua", "LUA") then return ErrorNoHalt("Evil Crawling Thing needs Syhgma's Evil API\n") end
include("evil_api/init.lua")

AddCSLuaFile("evil_crawler/sh_settings.lua")
AddCSLuaFile("evil_crawler/cl_scent.lua")
include("evil_crawler/sh_settings.lua")
if CLIENT then
	include("evil_crawler/cl_scent.lua")
end
