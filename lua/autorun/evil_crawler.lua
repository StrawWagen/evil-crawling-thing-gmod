AddCSLuaFile("evil_crawler/sh_settings.lua")
AddCSLuaFile("evil_crawler/cl_settings.lua")
include("evil_crawler/sh_settings.lua")
if CLIENT then include("evil_crawler/cl_settings.lua") end
