--!optimize 2
--!native
-- RoadHelper's roundabout generator. The island outline (the convex hull of
-- circles) and the arms' placement must match RoadMath's Roundabouts section
-- exactly.

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
	-- The arms, "angle,exit,entry[,length,skew];...": the direction from the
	-- island's centroid in degrees (atan2(z, x)), lanes leaving and lanes
	-- entering, and optionally the arm's own length (0 for ArmLength) and
	-- skew off square to the island edge (degrees, up to 45 either way)
	Arms = "0,1,1;90,1,1;180,1,1;270,1,1",
	-- How far the arms run out from the ring, the splitter island between
	-- each arm's entry and exit lanes and its style ("Kerbed": raised, with
	-- hatching ahead of its nose; "Hatched": painted only), and the kerb
	-- radius into the ring
	ArmLength = 120,
	SplitterWidth = 16,
	SplitterStyle = "Kerbed",
	EntryKerbRadius = 24,
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
	AdjustShowSnappingHelper = false,
	TextureLaneMarkings = false,
	HaveLaneMarkings = true,
	-- "Left" (UK) or "Right": which side traffic keeps to
	DriveSide = "Left",
	RoadMaterial = Enum.Material.Concrete,
	CenterlineColor = Color3.fromRGB(244, 205, 47),
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
local MAX_ARMS = 12
local MAX_ARM_SKEW = 45
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
local CENTER_OFFSET = 1
local EDGE_INSET = 2.6

local BLEND_LENGTH = 12
local BLEND_THICKNESS = 1

-- Arms: slices along each arm, how much of its length the splitter island
-- tapers over, the give way line's setback from the ring, where the kerbed
-- island starts and how wide the gap must be for it (its nose), and the
-- hatching ahead of it
local ARM_SLICES = 16
local TAPER_FRACTION = 0.6
local GIVE_WAY_SETBACK = 1.5
local GIVE_WAY_WIDTH = 2
local GIVE_WAY_DASH = 4
local GIVE_WAY_GAP = 2
local ISLAND_START = 4
local NOSE_WIDTH = 6
local HATCH_WIDTH = 2
local HATCH_SPACING = 12
local FILLET_STEPS = 8

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

local function smoothstep(u)
	return u * u * (3 - 2 * u)
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

-- The arms (identical to RoadMath.parseArms)
local function parseArms(value)
	local arms = {}
	if typeof(value) == "string" then
		for _, entry in string.split(value, ";") do
			local parts = string.split(entry, ",")
			local angle, exit, entryLanes = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
			if angle and exit and entryLanes and #arms < MAX_ARMS then
				exit, entryLanes = math.max(math.floor(exit), 0), math.max(math.floor(entryLanes), 0)
				if exit + entryLanes < 1 then
					exit, entryLanes = 1, 1
				end
				table.insert(arms, {
					Angle = angle,
					Exit = exit,
					Entry = entryLanes,
					Length = math.max(tonumber(parts[4]) or 0, 0),
					Skew = math.clamp(tonumber(parts[5]) or 0, -MAX_ARM_SKEW, MAX_ARM_SKEW),
				})
			end
		end
	end
	return arms
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

-- Where the ray from (cx, cz) at an angle leaves the outline, and the
-- outward normal there (identical to RoadMath.outlineHit)
local function outlineHit(stations, cx, cz, angle)
	local dx, dz = math.cos(angle), math.sin(angle)
	local bestT, hitX, hitZ, hitNX, hitNZ = math.huge, cx, cz, dx, dz
	for i = 1, #stations do
		local a, b = stations[i], stations[i % #stations + 1]
		local ex, ez = b.PX - a.PX, b.PZ - a.PZ
		local denominator = dx * ez - dz * ex
		if math.abs(denominator) > 1e-9 then
			local wx, wz = a.PX - cx, a.PZ - cz
			local t = (wx * ez - wz * ex) / denominator
			local s = (wx * dz - wz * dx) / denominator
			if t > 0 and s >= -1e-9 and s <= 1 + 1e-9 and t < bestT then
				bestT = t
				hitX, hitZ = cx + dx * t, cz + dz * t
				local nx, nz = a.NX + (b.NX - a.NX) * s, a.NZ + (b.NZ - a.NZ) * s
				local length = math.sqrt(nx * nx + nz * nz)
				hitNX, hitNZ = nx / length, nz / length
			end
		end
	end
	return hitX, hitZ, hitNX, hitNZ
end

--[[
	The roundabout is drawn from "stations" around the island outline: points
	on it (P) with the outward normal there (N). The tangent edges between
	the outline's arcs are the straight runs between one arc's last station
	and the next arc's first, which share a normal. Every edge of the
	roundabout is the outline offset outward by some distance d, P + N * d:
	the island and apron inside (negative d), the circulating carriageway
	from 0 to its width, then the footway.

	Each arm runs straight out along the outline normal where it attaches,
	from the ring's outer edge. Arm positions are given as (a, lat): a along
	the arm from the ring's outer edge, lat across it (+ to the left looking
	out). Near the ring its exit and entry lanes part around a splitter
	island, and its kerbs curve into the ring's outer kerb along fillet
	circles tangent to both, where the ring's footway and edge line are cut.
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
		local cx, cz = 0, 0
		for _, circle in circles do
			smallest = math.min(smallest, circle.Radius)
			cx += circle.X
			cz += circle.Z
		end
		cx, cz = cx / #circles, cz / #circles
		local apronWidth = math.clamp(attributes.ApronWidth or 0, 0, math.max(smallest - 1, 0))
		local exitSide = if attributes.DriveSide == "Right" then -1 else 1
		local armLength = math.max(attributes.ArmLength or 120, 1)
		local hatchedSplitters = attributes.SplitterStyle == "Hatched"
		local kerbRadius = math.max(attributes.EntryKerbRadius or 24, sidewalkWidth + 2)

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
		-- A point part way (t) along the outline between stations a and b,
		-- offset by d
		local function between(a, b, t, d, h)
			local px, pz = a.PX + (b.PX - a.PX) * t, a.PZ + (b.PZ - a.PZ) * t
			local nx, nz = a.NX + (b.NX - a.NX) * t, a.NZ + (b.NZ - a.NZ) * t
			return Vector3.new(px + nx * d, bottom + h, pz + nz * d)
		end

		local hRoadTop = ROAD_THICKNESS
		local hSideTop = ROAD_THICKNESS + CURB_HEIGHT
		local roadColor = attributes.RoadColor
		local roadMaterial = attributes.RoadMaterial or ROAD_MATERIAL
		local roadMaterialVariant = if roadMaterial == ROAD_MATERIAL then ROAD_MATERIAL_VARIANT else ""
		local sidewalkColor = attributes.SidewalkColor
		-- Kerbed islands: footway-surfaced, or grass on roads without footways
		local islandColor = if sidewalkWidth > 0 then sidewalkColor else attributes.BlendColor
		local islandMaterial = if sidewalkWidth > 0 then SIDEWALK_MATERIAL else attributes.BlendMaterial

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

		--[[
			Arms
		--]]
		local arms = {}
		-- (No attribute at all means the default arms; "" is none)
		for _, spec in parseArms(if attributes.Arms == nil then defaultAttributes.Arms else attributes.Arms) do
			local px, pz, normalX, normalZ = outlineHit(stations, cx, cz, math.rad(spec.Angle))
			-- The arm's direction: the outline normal swung by its skew; it
			-- starts at its mouth, where that axis crosses the ring's outer
			-- edge (identical to RoadMath.roundaboutLayout)
			local skew = math.rad(spec.Skew)
			local nx = normalX * math.cos(skew) - normalZ * math.sin(skew)
			local nz = normalX * math.sin(skew) + normalZ * math.cos(skew)
			local toMouth = ringWidth / math.cos(skew)
			local length = if spec.Length > 0 then spec.Length else armLength
			local arm = {
				Exit = spec.Exit,
				Entry = spec.Entry,
				NX = nx,
				NZ = nz,
				TX = nz,
				TZ = -nx,
				AX = px + nx * toMouth,
				AZ = pz + nz * toMouth,
				Length = length,
				Taper = length * TAPER_FRACTION,
			}
			-- A splitter island only separates two directions
			arm.Splitter = if spec.Exit > 0 and spec.Entry > 0 then math.max(attributes.SplitterWidth or 16, 0) else 0
			-- Lanes on each side (+lat is the left, looking out)
			arm.PlusLanes = if exitSide > 0 then spec.Exit else spec.Entry
			arm.MinusLanes = if exitSide > 0 then spec.Entry else spec.Exit
			table.insert(arms, arm)
		end
		local function axialOf(arm, p: Vector3)
			return (p.X - arm.AX) * arm.NX + (p.Z - arm.AZ) * arm.NZ
		end
		local function lateralOf(arm, p: Vector3)
			return (p.X - arm.AX) * arm.TX + (p.Z - arm.AZ) * arm.TZ
		end
		local function armPoint(arm, a, lat, h)
			return Vector3.new(arm.AX + arm.NX * a + arm.TX * lat, bottom + h, arm.AZ + arm.NZ * a + arm.TZ * lat)
		end
		local function gapAt(arm, a)
			return arm.Splitter * (1 - smoothstep(math.clamp(a / arm.Taper, 0, 1)))
		end
		-- The roadway's outer edge on one side (signed lat) at a
		local function outerAt(arm, side, a)
			local lanes = if side > 0 then arm.PlusLanes else arm.MinusLanes
			return side * (gapAt(arm, a) / 2 + lanes * laneWidth)
		end

		-- Where the line along an arm at a lateral offset crosses the outline
		-- offset by d, on the arm's side of the roundabout (of the line's two
		-- crossings with the convex outline, the one furthest along the arm),
		-- with the outline's normal there. A skewed arm meets the ring at an
		-- angle, so this can lie behind the arm's mouth (negative axial).
		local function crossing(arm, d, lat)
			local best = nil
			for i = 1, count do
				local a, b = stations[i], stations[i % count + 1]
				local qa, qb = point(a, d, 0), point(b, d, 0)
				local la, lb = lateralOf(arm, qa) - lat, lateralOf(arm, qb) - lat
				if la * lb <= 0 and la ~= lb then
					local t = la / (la - lb)
					local p = qa + (qb - qa) * t
					local axial = axialOf(arm, p)
					if best == nil or axial > best.Axial then
						local nx, nz = a.NX + (b.NX - a.NX) * t, a.NZ + (b.NZ - a.NZ) * t
						local length = math.sqrt(nx * nx + nz * nz)
						best = { Point = p, NX = nx / length, NZ = nz / length, Axial = axial }
					end
				end
			end
			return best
		end
		-- How far along an arm the ring's outer edge is, at a lateral offset
		-- (0 if the line misses the ring)
		local function edgeAt(arm, lat)
			local hit = crossing(arm, ringWidth, lat)
			return if hit then hit.Axial else 0
		end

		-- Each side's kerb fillet: a circle of kerbRadius tangent to the arm's
		-- side edge (at its ring end) and to the ring's outer edge, so its
		-- centre lies on the outline offset by ringWidth + kerbRadius, where
		-- that crosses the line kerbRadius beyond the arm's side
		for _, arm in arms do
			arm.Fillets = {}
			for _, side in { 1, -1 } do
				local half = math.abs(outerAt(arm, side, 0))
				local hit = crossing(arm, ringWidth + kerbRadius, side * (half + kerbRadius))
				local fillet = nil
				if hit then
					local ring = hit.Point - Vector3.new(hit.NX, 0, hit.NZ) * kerbRadius
					fillet = {
						Centre = hit.Point,
						Axial = hit.Axial,
						Ring = ring,
						RingLat = lateralOf(arm, ring),
						Side = armPoint(arm, hit.Axial, side * half, 0),
						-- The corner the fillet rounds off: where the arm's side
						-- meets the ring's outer edge
						Corner = (crossing(arm, ringWidth, side * half) or hit).Point,
					}
				end
				arm.Fillets[side] = fillet
			end
			-- The stretch of ring the arm's mouth cuts across
			local plus, minus = arm.Fillets[1], arm.Fillets[-1]
			arm.CutPlus = if plus then plus.RingLat else math.abs(outerAt(arm, 1, 0))
			arm.CutMinus = if minus then minus.RingLat else -math.abs(outerAt(arm, -1, 0))
		end

		-- The parts of the outline between stations a and b (t from 0 to 1)
		-- outside every arm's mouth, judged at the ring's outer edge
		local function visiblePieces(a, b)
			local qa, qb = point(a, ringWidth, 0), point(b, ringWidth, 0)
			local pieces = { { 0, 1 } }
			for _, arm in arms do
				local la, lb = lateralOf(arm, qa), lateralOf(arm, qb)
				local t0, t1
				if math.abs(lb - la) < 1e-9 then
					if la > arm.CutMinus and la < arm.CutPlus then
						t0, t1 = 0, 1
					end
				else
					local ta = (arm.CutMinus - la) / (lb - la)
					local tb = (arm.CutPlus - la) / (lb - la)
					t0, t1 = math.max(math.min(ta, tb), 0), math.min(math.max(ta, tb), 1)
				end
				-- Only the near side of the roundabout
				if t0 and t1 > t0 and axialOf(arm, qa + (qb - qa) * ((t0 + t1) / 2)) > -ringWidth then
					local remaining = {}
					for _, piece in pieces do
						if piece[2] <= t0 or piece[1] >= t1 then
							table.insert(remaining, piece)
						else
							if piece[1] < t0 then
								table.insert(remaining, { piece[1], t0 })
							end
							if piece[2] > t1 then
								table.insert(remaining, { t1, piece[2] })
							end
						end
					end
					pieces = remaining
				end
			end
			return pieces
		end

		-- The band between offsets d0 and d1 all the way round, at height h
		-- (cut at the arms' mouths when `cut`)
		local function band(d0, d1, h, color, material, mVariant, thickness, cut)
			if d1 - d0 < 0.01 then
				return
			end
			for i = 1, count do
				local a, b = stations[i], stations[i % count + 1]
				local along = Vector2.new(b.PX - a.PX, b.PZ - a.PZ).Magnitude
				-- (Arcs of very small circles still turn between stations)
				if along > 1e-4 or a.NX ~= b.NX or a.NZ ~= b.NZ then
					for _, piece in (if cut then visiblePieces(a, b) else { { 0, 1 } }) do
						local t0, t1 = piece[1], piece[2]
						if t1 - t0 > 1e-4 then
							quad(between(a, b, t0, d0, h), between(a, b, t0, d1, h), between(a, b, t1, d1, h), between(a, b, t1, d0, h),
								color, material, mVariant, thickness)
						end
					end
				end
			end
		end

		-- The circulating carriageway, with road surface under the footway
		band(0, ringWidth + sidewalkWidth, hRoadTop, roadColor, roadMaterial, roadMaterialVariant, ROAD_THICKNESS, false)
		-- The footway around the outside, cut where arms join
		band(ringWidth, ringWidth + sidewalkWidth, hSideTop, sidewalkColor, SIDEWALK_MATERIAL, "", CURB_HEIGHT, true)
		-- The apron: a low raised band just inside the ring
		band(-apronWidth, 0, ROAD_THICKNESS + APRON_RISE, attributes.ApronColor, attributes.ApronMaterial, "",
			ROAD_THICKNESS + APRON_RISE, false)

		-- The island: a raised fan of triangles from its centroid (it's convex)
		local islandEdge = {}
		local ix, iz = 0, 0
		for _, station in stations do
			local p = point(station, -apronWidth, hSideTop)
			local last = islandEdge[#islandEdge]
			if not last or (p - last).Magnitude > 1e-3 then
				table.insert(islandEdge, p)
				ix += p.X
				iz += p.Z
			end
		end
		if #islandEdge >= 3 then
			local centre = Vector3.new(ix / #islandEdge, bottom + hSideTop, iz / #islandEdge)
			for i = 1, #islandEdge do
				tri(centre, islandEdge[i], islandEdge[i % #islandEdge + 1],
					attributes.IslandColor, attributes.IslandMaterial, "", CURB_HEIGHT)
			end
		end

		-- Each arm's geometry
		for _, arm in arms do
			-- Where the kerbed splitter island ends (its nose): where the
			-- gap narrows to NOSE_WIDTH
			local noseA = 0
			if arm.Splitter > NOSE_WIDTH and not hatchedSplitters then
				local lo, hi = 0, arm.Taper
				for _ = 1, 30 do
					local mid = (lo + hi) / 2
					if gapAt(arm, mid) > NOSE_WIDTH then
						lo = mid
					else
						hi = mid
					end
				end
				noseA = (lo + hi) / 2
			end
			arm.NoseA = noseA

			-- Where the ring's outer edge crosses the arm's two sides: the arm
			-- starts there (with a skew, behind its mouth on one side and
			-- ahead of it on the other)
			local edgePlus = edgeAt(arm, math.abs(outerAt(arm, 1, 0)))
			local edgeMinus = edgeAt(arm, -math.abs(outerAt(arm, -1, 0)))
			local back = math.min(edgePlus, edgeMinus, 0)
			local front = math.max(edgePlus, edgeMinus)
			-- The splitter island starts clear of the ring across its width
			local islandStart = math.max(edgeAt(arm, arm.Splitter / 2), edgeAt(arm, -arm.Splitter / 2), 0)
				+ ISLAND_START
			arm.IslandStart = islandStart

			-- Slices along the arm, including where it meets the ring and where
			-- the footways start
			local slices = {}
			for k = 0, ARM_SLICES do
				table.insert(slices, arm.Length * k / ARM_SLICES)
			end
			for _, extra in { back, front, islandStart, noseA } do
				if extra < arm.Length then
					table.insert(slices, extra)
				end
			end
			local footwayStart = {}
			for _, side in { 1, -1 } do
				local fillet = arm.Fillets[side]
				footwayStart[side] = if fillet then math.min(fillet.Axial, arm.Length) else 0
				table.insert(slices, footwayStart[side])
			end
			table.sort(slices)
			-- (Nothing behind where the arm meets the ring)
			while slices[1] < back - 1e-6 do
				table.remove(slices, 1)
			end
			arm.Slices = slices
			arm.FootwayStart = footwayStart

			-- The road: across the lanes, and across the footways too beyond
			-- the fillets. Where it overlaps the ring's road (up to the ring
			-- edge's furthest point across the arm) it sits a hair lower, so
			-- the ring's surface shows rather than flickering against it.
			for k = 1, #slices - 1 do
				local a0, a1 = slices[k], slices[k + 1]
				if a1 - a0 > 1e-4 then
					local function edges(a)
						local plusExtra = if a0 >= footwayStart[1] - 1e-4 then sidewalkWidth else 0
						local minusExtra = if a0 >= footwayStart[-1] - 1e-4 then sidewalkWidth else 0
						return outerAt(arm, -1, a) - minusExtra, outerAt(arm, 1, a) + plusExtra
					end
					local lo0, hi0 = edges(a0)
					local lo1, hi1 = edges(a1)
					local top = if a0 < front - 1e-4 then hRoadTop - 0.02 else hRoadTop
					quad(armPoint(arm, a0, lo0, top), armPoint(arm, a0, hi0, top),
						armPoint(arm, a1, hi1, top), armPoint(arm, a1, lo1, top),
						roadColor, roadMaterial, roadMaterialVariant, ROAD_THICKNESS)
					-- Footways along the sides
					for _, side in { 1, -1 } do
						if sidewalkWidth > 0 and a0 >= footwayStart[side] - 1e-4 then
							local i0, i1 = outerAt(arm, side, a0), outerAt(arm, side, a1)
							quad(armPoint(arm, a0, i0, hSideTop), armPoint(arm, a0, i0 + side * sidewalkWidth, hSideTop),
								armPoint(arm, a1, i1 + side * sidewalkWidth, hSideTop), armPoint(arm, a1, i1, hSideTop),
								sidewalkColor, SIDEWALK_MATERIAL, "", CURB_HEIGHT)
						end
					end
					-- The kerbed splitter island, up to its nose
					if a0 >= islandStart - 1e-4 and a1 <= noseA + 1e-4 then
						quad(armPoint(arm, a0, -gapAt(arm, a0) / 2, hSideTop), armPoint(arm, a0, gapAt(arm, a0) / 2, hSideTop),
							armPoint(arm, a1, gapAt(arm, a1) / 2, hSideTop), armPoint(arm, a1, -gapAt(arm, a1) / 2, hSideTop),
							islandColor, islandMaterial, "", CURB_HEIGHT)
					end
				end
			end

			-- The mouth's corners: each fillet's footway, and the road out to
			-- its kerb, fanned from the corner it rounds off (where the arm's
			-- side meets the ring's outer edge), which sees the whole arc
			for _, side in { 1, -1 } do
				local fillet = arm.Fillets[side]
				if fillet then
					local c = fillet.Centre
					local fromAngle = math.atan2(fillet.Ring.Z - c.Z, fillet.Ring.X - c.X)
					local toAngle = math.atan2(fillet.Side.Z - c.Z, fillet.Side.X - c.X)
					local sweep = (toAngle - fromAngle + math.pi) % (2 * math.pi) - math.pi
					fillet.FromAngle, fillet.Sweep = fromAngle, sweep
					local function onArc(k, radius, h)
						local angle = fromAngle + sweep * k / FILLET_STEPS
						return Vector3.new(c.X + math.cos(angle) * radius, bottom + h, c.Z + math.sin(angle) * radius)
					end
					local corner = Vector3.new(fillet.Corner.X, bottom + hRoadTop, fillet.Corner.Z)
					for k = 0, FILLET_STEPS - 1 do
						tri(corner, onArc(k, kerbRadius, hRoadTop), onArc(k + 1, kerbRadius, hRoadTop),
							roadColor, roadMaterial, roadMaterialVariant, ROAD_THICKNESS)
						if sidewalkWidth > 0 then
							quad(onArc(k, kerbRadius - sidewalkWidth, hSideTop), onArc(k, kerbRadius, hSideTop),
								onArc(k + 1, kerbRadius, hSideTop), onArc(k + 1, kerbRadius - sidewalkWidth, hSideTop),
								sidewalkColor, SIDEWALK_MATERIAL, "", CURB_HEIGHT)
						end
					end
				end
			end
		end

		--[[
			Markings
		--]]
		if attributes.HaveLaneMarkings ~= false then
			local laneColor = attributes.LaneMarkingColor
			local centreColor = attributes.CenterlineColor
			local markingCount = 0
			local function strip(pa, pb, color, width, dotted, dashOffset)
				local len = (pb - pa).Magnitude
				if len < 0.05 then
					return
				end
				parameters:Pause()
				local part = createPart(
					"RoadMarking",
					color,
					SAND,
					Vector3.new(len + 0.05, MARK_THICKNESS, width),
					CFrame.lookAt((pa + pb) / 2, pb) * CFrame.Angles(0, -math.pi / 2, 0)
				)
				if attributes.TextureLaneMarkings then
					local texture = Instance.new("Texture")
					texture.Face = Enum.NormalId.Top
					texture.Color3 = color
					texture.StudsPerTileV = width
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
			local markHeight = hRoadTop + 0.05
			-- A line around the ring at offset d (cut at the arms' mouths
			-- when `cut`)
			local function ringLine(d, dotted, cut)
				local travelled = 0.3125 * DOTTED_MARK_TILE_LENGTH
				for i = 1, count do
					local a, b = stations[i], stations[i % count + 1]
					for _, piece in (if cut then visiblePieces(a, b) else { { 0, 1 } }) do
						local pa = between(a, b, piece[1], d, markHeight)
						local pb = between(a, b, piece[2], d, markHeight)
						strip(pa, pb, laneColor, MARK_WIDTH, dotted, travelled)
					end
					travelled += (point(b, d, 0) - point(a, d, 0)).Magnitude
				end
			end
			ringLine(EDGE_INSET, false, false)
			ringLine(ringWidth - EDGE_INSET, false, true)
			for k = 1, ringLanes - 1 do
				ringLine(k * laneWidth, true, false)
			end

			for _, arm in arms do
				local slices = arm.Slices
				-- A line along the arm at lat(a), from a0 (or from where it
				-- meets the ring's outer edge, when a0 is nil) to a1
				local function armLine(latAt, a0, a1, color, dotted)
					a0 = a0 or edgeAt(arm, latAt(0))
					local travelled = 0.3125 * DOTTED_MARK_TILE_LENGTH
					for k = 1, #slices - 1 do
						local s0, s1 = math.max(slices[k], a0), math.min(slices[k + 1], a1)
						if s1 > s0 + 1e-4 then
							local pa = armPoint(arm, s0, latAt(s0), markHeight)
							local pb = armPoint(arm, s1, latAt(s1), markHeight)
							strip(pa, pb, color, MARK_WIDTH, dotted, travelled)
							travelled += (pb - pa).Magnitude
						end
					end
				end
				for _, side in { 1, -1 } do
					-- Edge lines: along the arm, then round the fillet into the
					-- ring's outer edge line
					armLine(function(a)
						return outerAt(arm, side, a) - side * EDGE_INSET
					end, arm.FootwayStart[side], arm.Length, laneColor, false)
					local fillet = arm.Fillets[side]
					if fillet then
						local c = fillet.Centre
						for k = 0, FILLET_STEPS - 1 do
							local function onArc(step)
								local angle = fillet.FromAngle + fillet.Sweep * step / FILLET_STEPS
								local radius = kerbRadius + EDGE_INSET
								return Vector3.new(c.X + math.cos(angle) * radius, bottom + markHeight, c.Z + math.sin(angle) * radius)
							end
							strip(onArc(k), onArc(k + 1), laneColor, MARK_WIDTH, false)
						end
					end
					-- Lane lines between each side's lanes
					local lanes = if side > 0 then arm.PlusLanes else arm.MinusLanes
					for k = 1, lanes - 1 do
						armLine(function(a)
							return side * (gapAt(arm, a) / 2 + k * laneWidth)
						end, nil, arm.Length, laneColor, true)
					end
				end
				if arm.Splitter > 0 then
					-- The centre line: two lines opening out around the
					-- splitter island near the ring
					for _, side in { 1, -1 } do
						armLine(function(a)
							return side * (gapAt(arm, a) / 2 + CENTER_OFFSET)
						end, nil, arm.Length, centreColor, false)
					end
					-- Diagonal hatching between them ahead of the island's
					-- nose, while there's room
					local inset = CENTER_OFFSET + MARK_WIDTH / 2 + HATCH_WIDTH / 2
					local function faceAt(side, a)
						return side * (gapAt(arm, a) / 2 + CENTER_OFFSET) - side * (MARK_WIDTH / 2 + HATCH_WIDTH / 2)
					end
					local a = math.max(arm.NoseA, arm.IslandStart) + HATCH_SPACING / 2
					while a < arm.Taper and gapAt(arm, a) / 2 + CENTER_OFFSET - inset > HATCH_WIDTH / 2 do
						-- A stripe at 45 degrees through (a, 0), meeting each
						-- border's inner face
						local function meet(side)
							local lat = faceAt(side, a)
							for _ = 1, 8 do
								lat = faceAt(side, a + lat)
							end
							return armPoint(arm, a + lat, lat, markHeight)
						end
						strip(meet(-1), meet(1), laneColor, HATCH_WIDTH, false)
						a += HATCH_SPACING
					end
				elseif arm.Exit > 0 and arm.Entry > 0 then
					-- No splitter: a plain double centre line
					for _, side in { 1, -1 } do
						armLine(function()
							return side * CENTER_OFFSET
						end, nil, arm.Length, centreColor, false)
					end
				end
				-- Give way to traffic on the roundabout: a broken line across
				-- the entry lanes, following the ring's outer edge just
				-- outside it (so on a skewed arm it runs along the ring, not
				-- square across the arm)
				if arm.Entry > 0 then
					local entrySide = -exitSide
					local inner = math.abs(gapAt(arm, 0) / 2) + (if arm.Exit > 0 then CENTER_OFFSET + 1 else EDGE_INSET)
					local outer = math.abs(outerAt(arm, entrySide, 0)) - EDGE_INSET
					local function onLine(lat)
						return armPoint(arm, edgeAt(arm, entrySide * lat) + GIVE_WAY_SETBACK, entrySide * lat, markHeight)
					end
					local lat = inner
					while lat < outer do
						local dashEnd = math.min(lat + GIVE_WAY_DASH, outer)
						strip(onLine(lat), onLine(dashEnd), laneColor, GIVE_WAY_WIDTH, false)
						lat = dashEnd + GIVE_WAY_GAP
					end
				end
			end
		end

		-- Blend skirt around the outside of the ring
		if attributes.Blend then
			local blendAngle = math.rad(attributes.BlendAngle or 30)
			local cosA, sinA = math.cos(blendAngle), math.sin(blendAngle)
			local blendTop = if sidewalkWidth > 0 then hSideTop else hRoadTop
			local outer = ringWidth + sidewalkWidth
			for i = 1, count do
				local a, b = stations[i], stations[i % count + 1]
				for _, piece in visiblePieces(a, b) do
					local topA = between(a, b, piece[1], outer, blendTop)
					local topB = between(a, b, piece[2], outer, blendTop)
					local slopeA = Vector3.new(a.NX * cosA, -sinA, a.NZ * cosA) * BLEND_LENGTH
					local slopeB = Vector3.new(b.NX * cosA, -sinA, b.NZ * cosA) * BLEND_LENGTH
					quad(topA, topB, topB + slopeB, topA + slopeA, attributes.BlendColor, attributes.BlendMaterial, "", BLEND_THICKNESS)
				end
			end
		end

		-- Snapping helpers: cubes at each arm end's two corners, 2 studs back
		-- along the arm
		if attributes.AdjustShowSnappingHelper then
			for _, arm in arms do
				local centre = exitSide * (arm.Exit - arm.Entry) * laneWidth / 2
				local half = (arm.Exit + arm.Entry) * laneWidth / 2 + sidewalkWidth
				for _, sgn in { -1, 1 } do
					local p = armPoint(arm, arm.Length - 2, centre + sgn * half, 2)
					local cube = createPart("SnappingHelper", Color3.fromRGB(255, 40, 40), Enum.Material.SmoothPlastic,
						Vector3.new(4, 4, 4), CFrame.new(p))
					cube.CanCollide = false
					cube.Parent = targetContainer
				end
			end
		end
	end,
}

return Generator
