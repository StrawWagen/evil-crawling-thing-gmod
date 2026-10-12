-- Show scent trails: the scent the server sends (sv_scent.lua), drawn flat
-- on the ground as glowing marks, brighter where it's fresher, joined up
-- along each trail. The spot a crawler is heading for gets a ring and a
-- beam up out of the floor.
local STALE = 1.5 -- drawn this long after the last update, so it clears when the setting goes off
local LIFT = 1.5 -- off the ground, so it doesn't flicker into it
local SIZE = { 10, 26 } -- a mark's size, faintest to freshest
local FAINTEST = 0.2 -- how visible the faintest scent still is
local HEAD_SIZE = 44
local HEAD_BEAM = 64
local LINK_WIDTH = 2

local PLAYER = Color(255, 170, 40)
local NPC = Color(90, 220, 90)
local FEAR = Color(230, 60, 200)
local FOLLOWED = Color(40, 220, 255)

local GLOW = Material("sprites/light_glow02_add")
local RING = Material("effects/select_ring")
local BEAM = Material("trails/laser")

local trails, received = {}, -math.huge

net.Receive("EvilCrawlerScent", function()
	trails = {}
	while net.ReadBool() do
		local trail = { npc = net.ReadBool(), followed = net.ReadBool(), nodes = {} }
		for i = 1, net.ReadUInt(12) do
			trail.nodes[i] = {
				pos = net.ReadVector(), normal = net.ReadNormal(), strength = net.ReadUInt(8) / 255,
				fear = net.ReadBool(), head = net.ReadBool(), linked = net.ReadBool(),
			}
		end
		trails[#trails + 1] = trail
	end
	received = RealTime()
end)

-- The sprites are additive, so fading them means darkening them.
local function Shade(base, k)
	local a = Lerp(k, FAINTEST, 1)
	return Color(base.r * a, base.g * a, base.b * a, 255 * a)
end

hook.Add("PostDrawTranslucentRenderables", "EvilCrawlerScent", function(depth, sky)
	if depth or sky or RealTime() - received > STALE then return end
	local pulse = 0.75 + 0.25 * math.sin(RealTime() * 6)

	for _, trail in ipairs(trails) do
		local base = trail.followed and FOLLOWED or trail.npc and NPC or PLAYER
		local prev
		render.SetMaterial(BEAM)
		for _, node in ipairs(trail.nodes) do
			node.at = node.pos + node.normal * LIFT
			if node.linked and prev then
				render.DrawBeam(prev.at, node.at, LINK_WIDTH, 0, 1, Shade(base, math.min(prev.strength, node.strength)))
			end
			prev = node
		end

		render.SetMaterial(GLOW)
		for _, node in ipairs(trail.nodes) do
			local k = node.strength
			local size = Lerp(k, SIZE[1], SIZE[2])
			render.DrawQuadEasy(node.at, node.normal, size, size, Shade(node.fear and FEAR or base, k), 0)
		end

		for _, node in ipairs(trail.nodes) do
			if node.head then
				render.SetMaterial(RING)
				render.DrawQuadEasy(node.at, node.normal, HEAD_SIZE * pulse, HEAD_SIZE * pulse, FOLLOWED, RealTime() * 90 % 360)
				render.SetMaterial(BEAM)
				render.DrawBeam(node.at, node.at + node.normal * HEAD_BEAM, 4, 0, 1, FOLLOWED)
			end
		end
	end
end)
