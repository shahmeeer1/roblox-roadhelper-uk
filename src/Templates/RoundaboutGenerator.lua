--!optimize 2
--!native
-- RoadHelper's roundabout generator. The island outline (the convex hull of
-- circles) must match RoadMath's Roundabouts section exactly.

type GenerationFunctionParams<Attributes> = {
	Attributes: Attributes,
	Size: Vector3,
	Pause: (self: GenerationFunctionParams<Attributes>) -> (),
}
type GeneratorModuleDefinition<Attributes> = {
	Attributes: Attributes,
	OnGenerate: (parameters: GenerationFunctionParams<Attributes>, targetContainer: GeneratedFolder) -> (),
}

local defaultAttributes = {
	-- The central island's outline: the convex hull of these circles,
	-- "x,z,radius;x,z,radius;..." in the local XZ plane (one circle is a round
	-- island, two an oval, four a rounded rectangle)
	IslandShape = "0,0,60",
	-- The circulating carriageway: lanes, and each lane's width
	RingLanes = 2,
	LaneWidth = 24,
	-- The footway around the outside
	SidewalkWidth = 8,
	-- A raised apron inside the ring that long vehicles can run over (0 for
	-- none), and its surface
	ApronWidth = 0,
	ApronMaterial = Enum.Material.Cobblestone,
	ApronColor = Color3.fromRGB(120, 116, 110),
	-- The island's surface
	IslandMaterial = Enum.Material.Grass,
	IslandColor = Color3.fromRGB(76, 112, 44),
	Blend = false,
	BlendColor = Color3.fromRGB(66, 102, 12),
	BlendMaterial = Enum.Material.Grass,
	BlendAngle = 30,
	TextureLaneMarkings = false,
	HaveLaneMarkings = true,
	-- "Left" (UK) or "Right": which side traffic keeps to
	DriveSide = "Left",
	RoadMaterial = Enum.Material.Concrete,
	LaneMarkingColor = Color3.fromRGB(163, 161, 165),
	RoadColor = Color3.fromRGB(26, 42, 52),
	SidewalkColor = Color3.fromRGB(163, 162, 165),
}

local ROAD_MATERIAL = Enum.Material.Concrete
local ROAD_MATERIAL_VARIANT = ""
local SIDEWALK_MATERIAL = Enum.Material.Concrete
local SAND = Enum.Material.Sand
local SMOOTH = Enum.SurfaceType.Smooth

local MAX_CORNERS = 12
local DEFAULT_RADIUS = 60
-- Outline sampling: at most this much turn between stations
local ARC_STEP = math.rad(6)
local DOTTED_MARK_TILE_LENGTH = 80

local ROAD_THICKNESS = 0.2
local CURB_HEIGHT = 1
-- A truck apron's low kerb (about 60 mm at 24 studs per 3.65 m lane)
local APRON_RISE = 0.4
local MARK_WIDTH = 0.8
local MARK_THICKNESS = 0.04
local EDGE_INSET = 2.6

local BLEND_LENGTH = 12
local BLEND_THICKNESS = 1

local SOLID_TEXTURE = "rbxassetid://127451784449848"
local DOTTED_TEXTURE = "rbxassetid://129215561553463"

local function createPart(name, color, material, size, cframe)
	local part = Instance.new("Part")
	part.Anchored = true
	part.TopSurface = SMOOTH
	part.BottomSurface = SMOOTH
	part.Name = name
	part.Color = color
	part.Material = material
	part.Size = size
	part.CFrame = cframe
	return part
end

-- The island outline circles (identical to RoadMath.parseIslandShape)
local function parseIslandShape(value)
	local circles = {}
	if typeof(value) == "string" then
		for _, entry in string.split(value, ";") do
			local parts = string.split(entry, ",")
			local x, z, r = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
			if x and z and r and #circles < MAX_CORNERS then
				table.insert(circles, { X = x, Z = z, Radius = math.max(r, 1) })
			end
		end
	end
	if #circles == 0 then
		return { { X = 0, Z = 0, Radius = DEFAULT_RADIUS } }
	end
	return circles
end

-- The convex hull of the circles as arcs in order around the outline, each
-- followed by the straight tangent edge to the next (identical to
-- RoadMath.roundaboutHull)
local function hullOfCircles(circles)
	local kept = {}
	for i, a in circles do
		local contained = false
		for j, b in circles do
			if i ~= j then
				local distance = math.sqrt((a.X - b.X) ^ 2 + (a.Z - b.Z) ^ 2)
				local slack = b.Radius - (distance + a.Radius)
				if slack > 1e-6 or (math.abs(slack) <= 1e-6 and j < i) then
					contained = true
					break
				end
			end
		end
		if not contained then
			table.insert(kept, a)
		end
	end
	if #kept == 1 then
		return { { Circle = kept[1], From = 0, To = 2 * math.pi } }
	end
	local outgoing = {}
	for i, a in kept do
		for j, b in kept do
			if i == j then
				continue
			end
			local dx, dz = b.X - a.X, b.Z - a.Z
			local length = math.sqrt(dx * dx + dz * dz)
			if length < 1e-6 then
				continue
			end
			local cosine = (a.Radius - b.Radius) / length
			if math.abs(cosine) >= 1 then
				continue
			end
			local ux, uz = dx / length, dz / length
			local sine = math.sqrt(1 - cosine * cosine)
			local nx = cosine * ux + sine * uz
			local nz = cosine * uz - sine * ux
			local support = nx * a.X + nz * a.Z + a.Radius
			local valid = true
			for _, c in kept do
				if nx * c.X + nz * c.Z + c.Radius > support + 1e-6 then
					valid = false
					break
				end
			end
			if valid and (outgoing[i] == nil or length > outgoing[i].Length) then
				outgoing[i] = { To = j, NX = nx, NZ = nz, Length = length }
			end
		end
	end
	local start = nil
	for i in kept do
		if outgoing[i] then
			start = i
			break
		end
	end
	if not start then
		return { { Circle = kept[1], From = 0, To = 2 * math.pi } }
	end
	local order = { start }
	local current = start
	for _ = 1, #kept do
		local nextIndex = outgoing[current].To
		if nextIndex == start or not outgoing[nextIndex] then
			break
		end
		table.insert(order, nextIndex)
		current = nextIndex
	end
	local pieces = {}
	for m, index in order do
		local incoming = outgoing[order[(m - 2) % #order + 1]]
		local leaving = outgoing[index]
		local from = math.atan2(incoming.NZ, incoming.NX)
		local to = math.atan2(leaving.NZ, leaving.NX)
		while to < from do
			to += 2 * math.pi
		end
		table.insert(pieces, { Circle = kept[index], From = from, To = to })
	end
	return pieces
end

--[[
	The roundabout is drawn from "stations" around the island outline: points
	on it (P) with the outward normal there (N). The tangent edges between
	the outline's arcs are the straight runs between one arc's last station
	and the next arc's first, which share a normal. Every edge of the
	roundabout is the outline offset outward by some distance d, P + N * d:
	the island and apron inside (negative d), the circulating carriageway
	from 0 to its width, then the footway.
]]
local Generator: GeneratorModuleDefinition<typeof(defaultAttributes)> = {
	Attributes = defaultAttributes,
	OnGenerate = function(parameters, targetContainer)
		local attributes = parameters.Attributes
		local size = parameters.Size
		local bottom = -size.Y / 2

		local circles = parseIslandShape(attributes.IslandShape)
		local ringLanes = math.max(math.floor(attributes.RingLanes or 2), 1)
		local laneWidth = attributes.LaneWidth or 24
		local ringWidth = ringLanes * laneWidth
		local sidewalkWidth = math.max(attributes.SidewalkWidth or 8, 0)
		local smallest = math.huge
		for _, circle in circles do
			smallest = math.min(smallest, circle.Radius)
		end
		local apronWidth = math.clamp(attributes.ApronWidth or 0, 0, math.max(smallest - 1, 0))

		local stations = {}
		for _, piece in hullOfCircles(circles) do
			local circle = piece.Circle
			local steps = math.max(math.ceil((piece.To - piece.From) / ARC_STEP), 1)
			for k = 0, steps do
				local angle = piece.From + (piece.To - piece.From) * k / steps
				local nx, nz = math.cos(angle), math.sin(angle)
				table.insert(stations, {
					PX = circle.X + nx * circle.Radius,
					PZ = circle.Z + nz * circle.Radius,
					NX = nx,
					NZ = nz,
				})
			end
		end
		local count = #stations
		local function point(station, d, h)
			return Vector3.new(station.PX + station.NX * d, bottom + h, station.PZ + station.NZ * d)
		end

		local hRoadTop = ROAD_THICKNESS
		local hSideTop = ROAD_THICKNESS + CURB_HEIGHT
		local roadMaterial = attributes.RoadMaterial or ROAD_MATERIAL
		local roadMaterialVariant = if roadMaterial == ROAD_MATERIAL then ROAD_MATERIAL_VARIANT else ""

		-- two WedgeParts forming triangle pa-pb-pc, extruded `thickness` downward
		local function tri(pa, pb, pc, color, material, mVariant, thickness)
			parameters:Pause()
			local a2, b2, c2 = pa, pb, pc
			local ab, ac, bc = b2 - a2, c2 - a2, c2 - b2
			local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
			if abd > acd and abd > bcd then
				c2, a2 = a2, c2
			elseif acd > bcd and acd > abd then
				a2, b2 = b2, a2
			end
			ab, ac, bc = b2 - a2, c2 - a2, c2 - b2
			local crossV = ac:Cross(ab)
			if crossV.Magnitude < 1e-3 * ab.Magnitude * ac.Magnitude or crossV.Magnitude < 1e-6 then
				return
			end
			local rightV = crossV.Unit
			local up = bc:Cross(rightV).Unit
			local back = bc.Unit
			local height = math.abs(ab:Dot(up))
			local upN = if rightV.Y >= 0 then rightV else -rightV
			local shift = -upN * (thickness / 2)
			local function wedge(pos, rx, vz, depth)
				local w = Instance.new("WedgePart")
				w.Anchored = true
				w.TopSurface = SMOOTH
				w.BottomSurface = SMOOTH
				w.Name = "Fill"
				w.Color = color
				w.Material = material
				w.MaterialVariant = mVariant
				w.Size = Vector3.new(thickness, height, depth)
				w.CFrame = CFrame.fromMatrix(pos + shift, rx, up, vz)
				w.Parent = targetContainer
			end
			wedge((a2 + b2) / 2, rightV, back, math.abs(ab:Dot(back)))
			wedge((a2 + c2) / 2, -rightV, -back, math.abs(ac:Dot(back)))
		end
		-- A quad: one box Part when it's a rectangle, else two triangles
		local function quad(p1, p2, p3, p4, color, material, mVariant, thickness)
			local e1, e2 = p2 - p1, p3 - p2
			local e1len, e2len = e1.Magnitude, e2.Magnitude
			if e1len > 1e-4 and e2len > 1e-4
				and (e1 + (p4 - p3)).Magnitude < 1e-4
				and (e2 + (p1 - p4)).Magnitude < 1e-4
				and math.abs(e1:Dot(e2)) < 1e-4 * e1len * e2len then
				local upN = e2:Cross(e1).Unit
				if upN.Y < 0 then
					upN = -upN
				end
				local center = (p1 + p2 + p3 + p4) / 4 - upN * (thickness / 2)
				local w = createPart("Fill", color, material, Vector3.new(e1len, thickness, e2len),
					CFrame.fromMatrix(center, e1 / e1len, upN))
				w.MaterialVariant = mVariant
				w.Parent = targetContainer
				return
			end
			tri(p1, p2, p3, color, material, mVariant, thickness)
			tri(p1, p3, p4, color, material, mVariant, thickness)
		end
		-- The band between offsets d0 and d1 all the way round, at height h
		local function band(d0, d1, h, color, material, mVariant, thickness)
			if d1 - d0 < 0.01 then
				return
			end
			for i = 1, count do
				local a, b = stations[i], stations[i % count + 1]
				local along = Vector2.new(b.PX - a.PX, b.PZ - a.PZ).Magnitude
				-- (Arcs of very small circles still turn between stations)
				if along > 1e-4 or a.NX ~= b.NX or a.NZ ~= b.NZ then
					quad(point(a, d0, h), point(a, d1, h), point(b, d1, h), point(b, d0, h),
						color, material, mVariant, thickness)
				end
			end
		end

		-- The circulating carriageway, with road surface under the footway
		band(0, ringWidth + sidewalkWidth, hRoadTop, attributes.RoadColor, roadMaterial, roadMaterialVariant, ROAD_THICKNESS)
		-- The footway around the outside
		band(ringWidth, ringWidth + sidewalkWidth, hSideTop, attributes.SidewalkColor, SIDEWALK_MATERIAL, "", CURB_HEIGHT)
		-- The apron: a low raised band just inside the ring
		band(-apronWidth, 0, ROAD_THICKNESS + APRON_RISE, attributes.ApronColor, attributes.ApronMaterial, "",
			ROAD_THICKNESS + APRON_RISE)

		-- The island: a raised fan of triangles from its centroid (it's convex)
		local islandEdge = {}
		local cx, cz = 0, 0
		for _, station in stations do
			local p = point(station, -apronWidth, hSideTop)
			local last = islandEdge[#islandEdge]
			if not last or (p - last).Magnitude > 1e-3 then
				table.insert(islandEdge, p)
				cx += p.X
				cz += p.Z
			end
		end
		if #islandEdge >= 3 then
			local centre = Vector3.new(cx / #islandEdge, bottom + hSideTop, cz / #islandEdge)
			for i = 1, #islandEdge do
				tri(centre, islandEdge[i], islandEdge[i % #islandEdge + 1],
					attributes.IslandColor, attributes.IslandMaterial, "", CURB_HEIGHT)
			end
		end

		-- Markings: edge lines along both sides of the ring, dotted lines
		-- between its lanes
		if attributes.HaveLaneMarkings ~= false then
			local color = attributes.LaneMarkingColor
			local markingCount = 0
			local function strip(pa, pb, dotted, dashOffset)
				local len = (pb - pa).Magnitude
				if len < 0.05 then
					return
				end
				parameters:Pause()
				local part = createPart(
					"RoadMarking",
					color,
					SAND,
					Vector3.new(len + 0.05, MARK_THICKNESS, MARK_WIDTH),
					CFrame.lookAt((pa + pb) / 2, pb) * CFrame.Angles(0, -math.pi / 2, 0)
				)
				if attributes.TextureLaneMarkings then
					local texture = Instance.new("Texture")
					texture.Face = Enum.NormalId.Top
					texture.Color3 = color
					texture.StudsPerTileV = MARK_WIDTH
					if dotted then
						texture.ColorMap = DOTTED_TEXTURE
						texture.StudsPerTileU = DOTTED_MARK_TILE_LENGTH
						texture.OffsetStudsU = dashOffset or 0
					else
						texture.ColorMap = SOLID_TEXTURE
						texture.StudsPerTileU = 21.4
						markingCount += 1
						texture.OffsetStudsU = (markingCount * 7.31) % 21.4
					end
					texture.Parent = part
					part.Transparency = 1
				end
				part.Parent = targetContainer
			end
			local function ringLine(d, dotted)
				local travelled = 0.3125 * DOTTED_MARK_TILE_LENGTH
				for i = 1, count do
					local pa = point(stations[i], d, hRoadTop + 0.05)
					local pb = point(stations[i % count + 1], d, hRoadTop + 0.05)
					strip(pa, pb, dotted, travelled)
					travelled += (pb - pa).Magnitude
				end
			end
			ringLine(EDGE_INSET, false)
			ringLine(ringWidth - EDGE_INSET, false)
			for k = 1, ringLanes - 1 do
				ringLine(k * laneWidth, true)
			end
		end

		-- Blend skirt around the outside
		if attributes.Blend then
			local blendAngle = math.rad(attributes.BlendAngle or 30)
			local cosA, sinA = math.cos(blendAngle), math.sin(blendAngle)
			local blendTop = if sidewalkWidth > 0 then hSideTop else hRoadTop
			local outer = ringWidth + sidewalkWidth
			for i = 1, count do
				local a, b = stations[i], stations[i % count + 1]
				local topA, topB = point(a, outer, blendTop), point(b, outer, blendTop)
				local slopeA = Vector3.new(a.NX * cosA, -sinA, a.NZ * cosA) * BLEND_LENGTH
				local slopeB = Vector3.new(b.NX * cosA, -sinA, b.NZ * cosA) * BLEND_LENGTH
				quad(topA, topB, topB + slopeB, topA + slopeA, attributes.BlendColor, attributes.BlendMaterial, "", BLEND_THICKNESS)
			end
		end
	end,
}

return Generator
