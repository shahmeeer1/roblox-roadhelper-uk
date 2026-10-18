--!optimize 2
--!native
-- RoadHelper's Y split generator: one road dividing into two. The layout must
-- match RoadMath's Y splits section exactly (RoadHelper places and joins
-- splits using it).

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
	LaneWidth = 24,
	-- The stem's lanes per travel direction: forward runs stem -> branches
	LaneCountForward = 1,
	LaneCountBackward = 1,
	-- Lanes the left branch takes from the stem's left edge (looking toward the
	-- branches); the right branch takes the rest. -1 picks the default: a two-way
	-- road separates into its two directions, a one-way road splits about in half.
	SplitLanesLeft = -1,
	-- Gap between the two branch roads (outside their footways) at the far end
	SplitSeparation = 16,
	SidewalkWidth = 8,
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
local SIDEWALK_MATERIAL_VARIANT = ""
local SAND = Enum.Material.Sand
local SMOOTH = Enum.SurfaceType.Smooth

local SLICES = 24
local DOTTED_MARK_TILE_LENGTH = 80

local ROAD_THICKNESS = 0.2
local CURB_HEIGHT = 1
local MARK_WIDTH = 0.8
local MARK_THICKNESS = 0.04
local CENTER_OFFSET = 1
local EDGE_INSET = 2.6

local BLEND_LENGTH = 12
local BLEND_THICKNESS = 1

-- Gore markings (at 24 studs per 3.65 m lane): stripes about 0.3 m wide every
-- 2.4 m along the road at 45 degrees, up to the nose where the raised island
-- begins, about 0.9 m across
local HATCH_WIDTH = 2
local HATCH_SPACING = 16
local NOSE_WIDTH = 6

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

--[[
	The split: a stem end at -Z (joining the road) and two branch ends at +Z,
	side by side. The stem's lanes divide across the road between the two
	branches, each lane keeping its travel direction, and each branch is a
	ribbon of road sliding sideways from its place in the stem to its far end
	(smoothstep along the length). The split line, where the branches part,
	is at x = 0. Between the ribbons opens the gore: hatched road up to the
	nose, then a raised island. Following UK practice (Highway Code rule 130),
	a gore between traffic going the same way gets chevrons bordered by solid
	lines, and one between opposite directions diagonal hatching bordered by
	broken lines.
]]
local Generator: GeneratorModuleDefinition<typeof(defaultAttributes)> = {
	Attributes = defaultAttributes,
	OnGenerate = function(parameters, targetContainer)
		local attributes = parameters.Attributes
		local size = parameters.Size
		local bottom = -size.Y / 2
		local length = size.Z
		local halfZ = length / 2

		-- Layout (identical to RoadMath.splitLayout)
		local laneWidth = attributes.LaneWidth
		local sidewalkWidth = attributes.SidewalkWidth or 8
		local forward = math.max(math.floor(attributes.LaneCountForward or 1), 0)
		local backward = math.max(math.floor(attributes.LaneCountBackward or 1), 0)
		if forward + backward < 1 then
			forward = 1
		end
		local total = forward + backward
		local driveOnLeft = attributes.DriveSide ~= "Right"
		local leftValue = attributes.SplitLanesLeft
		local left
		if typeof(leftValue) == "number" and leftValue >= 0 then
			left = math.floor(leftValue)
		elseif forward > 0 and backward > 0 then
			left = if driveOnLeft then forward else backward
		else
			left = math.max(math.floor(total / 2), 1)
		end
		left = if total >= 2 then math.clamp(left, 1, total - 1) else total
		local right = total - left
		local separation = math.max(attributes.SplitSeparation or 16, 0)
		local stemRoadway = total * laneWidth
		local stemX = stemRoadway / 2 - right * laneWidth
		local leftWidth = left * laneWidth + 2 * sidewalkWidth
		local rightWidth = right * laneWidth + 2 * sidewalkWidth
		local span = rightWidth + separation + leftWidth
		local leftX = span / 2 - leftWidth / 2
		local rightX = -span / 2 + rightWidth / 2

		-- Across the stem from -x to +x, lanes 1..total: first the -lat group
		-- (backward when driving on the left), then the +lat group. The right
		-- branch takes lanes 1..right, the left branch the rest.
		local plusCount = if driveOnLeft then forward else backward
		local minusCount = total - plusCount
		local function laneIsForward(index)
			local inPlusGroup = index > minusCount
			return inPlusGroup == driveOnLeft
		end

		-- Lane boundaries of each ribbon as { S = stem x, F = far x }, from -x
		-- to +x
		local rightBounds = {}
		for j = 0, right do
			rightBounds[j] = {
				S = stemX - stemRoadway / 2 + j * laneWidth,
				F = rightX - right * laneWidth / 2 + j * laneWidth,
			}
		end
		local leftBounds = {}
		for j = 0, left do
			leftBounds[j] = {
				S = j * laneWidth,
				F = leftX - left * laneWidth / 2 + j * laneWidth,
			}
		end
		local function xAt(pair, u)
			return pair.S + (pair.F - pair.S) * smoothstep(u)
		end
		local function point(x, u, h)
			return Vector3.new(x, bottom + h, -halfZ + u * length)
		end

		-- The gore between the ribbons' roadways grows from nothing at the stem
		-- to both footways plus the separation at the far end; the raised
		-- island starts at the nose
		local farGap = separation + 2 * sidewalkWidth
		local noseU = 1
		if farGap > NOSE_WIDTH then
			local lo, hi = 0, 1
			for _ = 1, 30 do
				local mid = (lo + hi) / 2
				if smoothstep(mid) * farGap < NOSE_WIDTH then
					lo = mid
				else
					hi = mid
				end
			end
			noseU = (lo + hi) / 2
		end

		local sliceU = {}
		for k = 0, SLICES do
			table.insert(sliceU, k / SLICES)
		end
		if noseU < 1 then
			table.insert(sliceU, noseU)
			table.sort(sliceU)
		end

		local hRoadTop = ROAD_THICKNESS
		local hSideTop = ROAD_THICKNESS + CURB_HEIGHT
		local roadColor = attributes.RoadColor
		local sidewalkColor = attributes.SidewalkColor
		local centerlineColor = attributes.CenterlineColor
		local laneMarkingColor = attributes.LaneMarkingColor
		local textureLaneMarkings = attributes.TextureLaneMarkings
		local haveLaneMarkings = if attributes.HaveLaneMarkings ~= nil then attributes.HaveLaneMarkings else true
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
		-- A strip of a lateral band { from, to } (each an { S, F } pair) over
		-- the slices between u0 and u1, at height h
		local function band(from, to, u0, u1, h, color, material, mVariant, thickness)
			for k = 1, #sliceU - 1 do
				local ua, ub = sliceU[k], sliceU[k + 1]
				if ua >= u0 - 1e-6 and ub <= u1 + 1e-6 then
					local fa, ta = xAt(from, ua), xAt(to, ua)
					local fb, tb = xAt(from, ub), xAt(to, ub)
					if ta - fa > 0.01 or tb - fb > 0.01 then
						quad(point(fa, ua, h), point(ta, ua, h), point(tb, ub, h), point(fb, ub, h),
							color, material, mVariant, thickness)
					end
				end
			end
		end

		local function offsetPair(pair, ds, df)
			return { S = pair.S + ds, F = pair.F + df }
		end
		local rightOuter = rightBounds[0]
		local rightInner = rightBounds[right]
		local leftInner = leftBounds[0]
		local leftOuter = leftBounds[left]

		-- Road surface across everything, footways included (the gore beyond
		-- the nose is covered by the island)
		band(offsetPair(rightOuter, -sidewalkWidth, -sidewalkWidth), offsetPair(leftOuter, sidewalkWidth, sidewalkWidth),
			0, 1, hRoadTop, roadColor, roadMaterial, roadMaterialVariant, ROAD_THICKNESS)

		-- Outer footways
		band(offsetPair(rightOuter, -sidewalkWidth, -sidewalkWidth), rightOuter, 0, 1, hSideTop,
			sidewalkColor, SIDEWALK_MATERIAL, SIDEWALK_MATERIAL_VARIANT, CURB_HEIGHT)
		band(leftOuter, offsetPair(leftOuter, sidewalkWidth, sidewalkWidth), 0, 1, hSideTop,
			sidewalkColor, SIDEWALK_MATERIAL, SIDEWALK_MATERIAL_VARIANT, CURB_HEIGHT)

		-- Raised island from the nose to the far end: footway-surfaced, or a
		-- grass verge on roads without footways
		if noseU < 1 then
			local islandColor = if sidewalkWidth > 0 then sidewalkColor else attributes.BlendColor
			local islandMaterial = if sidewalkWidth > 0 then SIDEWALK_MATERIAL else attributes.BlendMaterial
			band(rightInner, leftInner, noseU, 1, hSideTop, islandColor, islandMaterial, "", CURB_HEIGHT)
		end

		--[[
			Markings
		--]]
		local markingCount = 0
		-- A flat marking strip from pa to pb
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
			if textureLaneMarkings then
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
		-- A lane line along the whole split, following an { S, F } pair
		local function laneLine(pair, color, dotted)
			-- Dashes start at the middle of a gap, like the road generators
			local travelled = 0.3125 * DOTTED_MARK_TILE_LENGTH
			for k = 1, #sliceU - 1 do
				local pa = point(xAt(pair, sliceU[k]), sliceU[k], hRoadTop + 0.05)
				local pb = point(xAt(pair, sliceU[k + 1]), sliceU[k + 1], hRoadTop + 0.05)
				strip(pa, pb, color, MARK_WIDTH, dotted, travelled)
				travelled += (pb - pa).Magnitude
			end
		end
		-- One ribbon's lines between its lanes: the double centre line where
		-- the two travel directions meet, dotted lane lines otherwise
		local function ribbonLines(bounds, laneCount, firstLane)
			for j = 1, laneCount - 1 do
				local index = firstLane + j - 1 -- the lane left of boundary j
				if laneIsForward(index) ~= laneIsForward(index + 1) then
					for _, offset in { -CENTER_OFFSET, CENTER_OFFSET } do
						laneLine(offsetPair(bounds[j], offset, offset), centerlineColor, false)
					end
				else
					laneLine(bounds[j], laneMarkingColor, true)
				end
			end
		end

		if haveLaneMarkings then
			-- Edge lines along the outer kerbs
			laneLine(offsetPair(rightOuter, EDGE_INSET, EDGE_INSET), laneMarkingColor, false)
			laneLine(offsetPair(leftOuter, -EDGE_INSET, -EDGE_INSET), laneMarkingColor, false)
			ribbonLines(rightBounds, right, 1)
			ribbonLines(leftBounds, left, right + 1)

			-- The gore. Its two border lines open out from the line the
			-- branches part along (the centre line, when the split separates
			-- the two directions) to the branches' inner edge lines.
			local centreSplit = right > 0 and left > 0 and laneIsForward(right) ~= laneIsForward(right + 1)
			local apexOffset = if centreSplit then CENTER_OFFSET else 0
			local rightBorder = { S = -apexOffset, F = rightInner.F - EDGE_INSET }
			local leftBorder = { S = apexOffset, F = leftInner.F + EDGE_INSET }
			-- Chevrons (same direction) get solid borders, diagonal hatching
			-- (opposite directions) broken ones
			local borderColor = if centreSplit then centerlineColor else laneMarkingColor
			laneLine(rightBorder, borderColor, centreSplit)
			laneLine(leftBorder, borderColor, centreSplit)

			-- Hatching between the borders, from the split to the nose
			local function zToU(z)
				return math.clamp((z + halfZ) / length, 0, 1)
			end
			-- Where a stripe through (x0, z0) with z = z0 + slope * (x - x0)
			-- meets a border line's inner face
			local function meetBorder(border, inward, x0, z0, slope)
				local x = xAt(border, zToU(z0)) + inward
				local z = z0
				for _ = 1, 8 do
					z = z0 + slope * (x - x0)
					x = xAt(border, zToU(z)) + inward
				end
				return x, z
			end
			local inset = MARK_WIDTH / 2 + HATCH_WIDTH / 2
			-- The traffic beside the gore, for the chevrons: they point toward
			-- oncoming traffic, i.e. their arms trail downstream
			local goreForward = laneIsForward(right)
			local armSlope = if goreForward then 1 else -1
			local noseZ = -halfZ + noseU * length
			local z = -halfZ + HATCH_SPACING / 2
			while z < noseZ do
				local u = zToU(z)
				local lb = xAt(leftBorder, u) - inset
				local rb = xAt(rightBorder, u) + inset
				if lb - rb > HATCH_WIDTH then
					local c = (lb + rb) / 2
					local h = hRoadTop + 0.05
					if centreSplit then
						-- Diagonal hatching: one stripe across, at 45 degrees
						local xl, zl = meetBorder(leftBorder, -inset, c, z, 1)
						local xr, zr = meetBorder(rightBorder, inset, c, z, 1)
						if zl <= noseZ and zr >= -halfZ then
							strip(point(xr, zToU(zr), h), point(xl, zToU(zl), h), laneMarkingColor, HATCH_WIDTH, false)
						end
					else
						-- A chevron: two arms from the gore's middle out to
						-- the borders
						local xl, zl = meetBorder(leftBorder, -inset, c, z, armSlope)
						local xr, zr = meetBorder(rightBorder, inset, c, z, -armSlope)
						if math.max(zl, zr) <= noseZ and math.min(zl, zr) >= -halfZ then
							local apex = point(c, u, h)
							strip(apex, point(xl, zToU(zl), h), laneMarkingColor, HATCH_WIDTH, false)
							strip(apex, point(xr, zToU(zr), h), laneMarkingColor, HATCH_WIDTH, false)
						end
					end
				end
				z += HATCH_SPACING
			end
		end

		-- Blend skirts along the two outer edges
		if attributes.Blend then
			local blendAngle = math.rad(attributes.BlendAngle or 30)
			local cosA, sinA = math.cos(blendAngle), math.sin(blendAngle)
			local blendTop = if sidewalkWidth > 0 then hSideTop else hRoadTop
			for _, side in { { -1, offsetPair(rightOuter, -sidewalkWidth, -sidewalkWidth) }, { 1, offsetPair(leftOuter, sidewalkWidth, sidewalkWidth) } } do
				local sgn, edge = side[1], side[2]
				local slope = Vector3.new(sgn * cosA, -sinA, 0) * BLEND_LENGTH
				for k = 1, #sliceU - 1 do
					local topA = point(xAt(edge, sliceU[k]), sliceU[k], blendTop)
					local topB = point(xAt(edge, sliceU[k + 1]), sliceU[k + 1], blendTop)
					quad(topA, topB, topB + slope, topA + slope, attributes.BlendColor, attributes.BlendMaterial, "", BLEND_THICKNESS)
				end
			end
		end

		-- Snapping helpers: cubes at each end's two corners, 2 studs inside the
		-- box (stem blue, left branch red, right branch orange)
		if attributes.AdjustShowSnappingHelper then
			local function helperCube(color, x, z)
				local cube = createPart("SnappingHelper", color, Enum.Material.SmoothPlastic, Vector3.new(4, 4, 4),
					CFrame.new(x, bottom + 2, z))
				cube.CanCollide = false
				cube.Parent = targetContainer
			end
			local stemWidth = stemRoadway + 2 * sidewalkWidth
			for _, sgn in { -1, 1 } do
				helperCube(Color3.fromRGB(0, 100, 255), stemX + sgn * stemWidth / 2, -halfZ + 2)
				helperCube(Color3.fromRGB(255, 40, 40), leftX + sgn * leftWidth / 2, halfZ - 2)
				helperCube(Color3.fromRGB(255, 160, 40), rightX + sgn * rightWidth / 2, halfZ - 2)
			end
		end
	end,
}

return Generator
