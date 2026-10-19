--!strict
--[[
	RoadMath: Pure math for working with procedural road segments.

	A road segment is a ProceduralModel with a StraightRoadGenerator or
	CurveRoadGenerator ModuleScript child. Each segment has two endpoints:
	"Blue" (the start/entry end, matching the AdjustBlue* attributes) and
	"Red" (the end/exit end, matching AdjustRed*).

	Endpoint frames are the segments' *nominal* snap frames: positioned at the
	end edge centre (which is invariant under all the Adjust angle attributes),
	with LookVector pointing outward along the un-adjusted travel direction and
	UpVector equal to the model's up.

	Conventions used throughout (matching the generators):
	- width = (LaneCountForward + LaneCountBackward)*LaneWidth + 2*SidewalkWidth
	  (see the Lanes section for the per-direction counts)
	- Straight: blue at local (-fs*sway, -Y/2, -Z/2) facing -Z, red at
	  (fs*sway, +Y/2, +Z/2) facing +Z, fs = Flip and -1 or 1,
	  sway = max((X - width)/2, 0), width being the wider end's on a
	  lane-change straight. The road always climbs blue -> red.
	- Curve: blue at (-X/2 + w, blueY, -Z/2) facing -Z, red at
	  (X/2, redY, Z/2 - w) facing +X, w = width/2. Flip swaps which end is
	  at the top of the box vertically (blue is the top when Flip).
	- AdjustDir attributes are clockwise-positive in plan view, which matches
	  right-handed rotation about +Y with Roblox's CFrame.Angles.
]]

local RoadDefaults = require("./RoadDefaults")

local RoadMath = {}

export type SegmentKind = "Straight" | "Curve" | "Intersection" | "Split" | "Roundabout"
-- Roads have a Blue and a Red end; intersections have one id per stub; Y
-- splits have a stem and two branches
export type EndpointId =
	"Blue"
	| "Red"
	| "ZPlus"
	| "ZMinus"
	| "XPlus"
	| "XMinus"
	| "Stem"
	| "BranchLeft"
	| "BranchRight"
	-- A roundabout's centre: not an end that joins roads, just what selecting the
	-- roundabout selects (see RoadMath.pickableEndpointIds)
	| "Centre"
	-- A roundabout's arms, numbered in the order they're listed
	| "Arm1"
	| "Arm2"
	| "Arm3"
	| "Arm4"
	| "Arm5"
	| "Arm6"
	| "Arm7"
	| "Arm8"
	| "Arm9"
	| "Arm10"
	| "Arm11"
	| "Arm12"

-- Roundabouts (see the Roundabouts section): one circle of the island
-- outline, in the roundabout's local (pivot) space
export type RoundaboutCircle = {
	X: number,
	Z: number,
	Radius: number,
}

export type RoundaboutLayout = {
	Circles: { RoundaboutCircle },
	RingLanes: number,
	LaneWidth: number,
	-- The circulating carriageway's width at its widest: RingLanes *
	-- LaneWidth, or the most lanes of any section
	RingWidth: number,
	-- Its sections (see Ring sections) in the order stored, none for a ring
	-- of RingLanes all the way round, the ring's length (as positions round
	-- it are measured) and how long lane changes are
	Sections: { RingSection },
	RingLength: number,
	RingTaperLength: number,
	-- The footway around the outside
	SidewalkWidth: number,
	-- The raised apron inside the ring (0 for none), kept within the
	-- smallest outline circle
	ApronWidth: number,
	-- The arms, and their shared length, splitter island width and entry kerb
	-- radius
	Arms: { RoundaboutArm },
	ArmLength: number,
	SplitterWidth: number,
	EntryKerbRadius: number,
	-- "Kerbed" (a raised island, hatched ahead of its nose) or "Hatched"
	-- (painted only)
	SplitterStyle: "Kerbed" | "Hatched",
	-- How far out from the ring an arm's entry flare reaches
	FlareLength: number,
}

-- One of a roundabout's arms (see the Roundabouts section)
export type RoundaboutArm = {
	-- Where it is: the direction from the island's centroid, in degrees
	-- (atan2(z, x) in the local XZ plane)
	Angle: number,
	-- Lanes leaving the roundabout, and lanes entering it
	Exit: number,
	Entry: number,
	-- How far it runs out from the ring (its own LengthOverride, or the
	-- roundabout's ArmLength when that's 0), and its skew in degrees
	Length: number,
	LengthOverride: number,
	Skew: number,
	-- Extra entry lanes the approach flares out to at the give way line, and
	-- the entry lanes' arrows as stored ("" for automatic; see
	-- RoadMath.laneArrows)
	Flare: number,
	Arrows: string,
	-- The ring's width where it attaches, and its position round the ring
	RingWidth: number,
	Position: number,
	-- Where its axis meets the island outline, and its direction (the
	-- outline's outward normal there, swung by the skew)
	AttachX: number,
	AttachZ: number,
	NX: number,
	NZ: number,
	-- Its mouth: where its axis crosses the ring's outer edge
	MouthX: number,
	MouthZ: number,
	-- Its end (the road end that joins roads), and the width there
	EndX: number,
	EndZ: number,
	EndWidth: number,
}

-- One arc of a roundabout outline: a circle's boundary from angle From to To
-- (radians, To >= From, angles measured in the local XZ plane as
-- atan2(z, x)), after which a straight tangent edge runs on to the next
-- piece's circle
export type HullPiece = {
	Circle: RoundaboutCircle,
	From: number,
	To: number,
}

-- The layout of a Y split, in its local (pivot) space: see the Y splits
-- section
export type SplitLayout = {
	StemX: number,
	LeftX: number,
	RightX: number,
	StemWidth: number,
	LeftWidth: number,
	RightWidth: number,
	LeftLanes: number,
	RightLanes: number,
	LeftForward: number,
	LeftBackward: number,
	RightForward: number,
	RightBackward: number,
	BoxWidth: number,
}

export type SegmentInfo = {
	Model: Model, -- Actually a ProceduralModel
	Kind: SegmentKind,
	-- The road width (at the blue end, for a straight with a lane change)
	Width: number,
	-- A lane-change straight's red end width, when it differs from the blue
	WidthRed: number?,
	Size: Vector3,
	Pivot: CFrame,
	Flip: boolean,
	-- Intersection-only fields: the X road's width, its angle from the Z
	-- road (radians), and whether the -X stub exists
	WidthX: number?,
	Angle: number?,
	ThroughRoad: boolean?,
	-- Y split only
	Split: SplitLayout?,
	-- Roundabout only: its island outline circles and ring width
	Roundabout: RoundaboutLayout?,
}

export type Endpoint = {
	Segment: SegmentInfo,
	Id: EndpointId,
	WorldCFrame: CFrame,
}

export type MoveSolution = {
	Size: Vector3,
	Pivot: CFrame,
	Flip: boolean,
	-- True when the segment was rotated 180 degrees so its blue/red ends
	-- swap geographic places. The caller must also swap the segment's
	-- AdjustBlue*/AdjustRed* attributes (negating grades and banks) and
	-- re-color any endpoint references it holds.
	SwapEnds: boolean,
}

-- Shortest allowed segment (along the travel direction for straights)
RoadMath.MIN_LENGTH = 8

-- How close two endpoint centres must be to be considered joined
RoadMath.JOINT_TOLERANCE = 1

local GENERATOR_KINDS: { [string]: SegmentKind } = {
	StraightRoadGenerator = "Straight",
	CurveRoadGenerator = "Curve",
	RoadIntersectionGenerator = "Intersection",
	RoadSplitGenerator = "Split",
	RoundaboutGenerator = "Roundabout",
}

-- Junctions (intersections, Y splits and roundabouts) are flat with fixed
-- exits: their ends have no adjust angles and are only moved as a whole
function RoadMath.isJunction(kind: SegmentKind): boolean
	return kind == "Intersection" or kind == "Split" or kind == "Roundabout"
end

--------------------------------------------------------------------------------
-- Segment discovery
--------------------------------------------------------------------------------

local function getNumberAttribute(model: Instance, name: string, default: number): number
	local value = model:GetAttribute(name)
	if typeof(value) == "number" then
		return value
	end
	return default
end

--------------------------------------------------------------------------------
-- Lanes
--------------------------------------------------------------------------------

--[[
	Lane counts are stored per travel direction. On a road, "forward" lanes
	carry traffic blue -> red and "backward" lanes red -> blue
	(LaneCountForward / LaneCountBackward). On an intersection each road has
	its own pair suffixed X or Z, with forward running toward that road's
	Plus exit. Either count may be zero (a one-way road), but there is always
	at least one lane in all, matching the generators.

	A straight can change lanes along its length: LaneCountForwardRed /
	LaneCountBackwardRed then override the counts at its red end (the base
	pair applies at the blue end). The overrides are only in effect when
	both are set (>= 0; the generator defaults them to -1), and only on
	straights; otherwise the segment has the same lanes at both ends.
	LaneChangeSide ("Offside" by default, or
	"Nearside") says which lane of a changing direction ends or starts.
]]
function RoadMath.sanitizeLaneCounts(forward: number, backward: number): (number, number)
	local f = math.max(math.floor(forward), 0)
	local b = math.max(math.floor(backward), 0)
	if f + b < 1 then
		f = 1
	end
	return f, b
end

-- The forward/backward lane count attribute names for one road of a
-- segment: suffix "" for a road segment, "X" or "Z" for an intersection
function RoadMath.laneCountNames(suffix: string): (string, string)
	return "LaneCountForward" .. suffix, "LaneCountBackward" .. suffix
end

local function readLaneCounts(model: Instance, suffix: string): (number, number)
	local forwardName, backwardName = RoadMath.laneCountNames(suffix)
	return RoadMath.sanitizeLaneCounts(
		getNumberAttribute(model, forwardName, RoadDefaults.LaneCountForward),
		getNumberAttribute(model, backwardName, RoadDefaults.LaneCountBackward)
	)
end

local function totalLanes(model: Instance, suffix: string): number
	local forward, backward = readLaneCounts(model, suffix)
	return forward + backward
end

-- The red-end lane count overrides of a lane-change straight
RoadMath.RED_LANE_OVERRIDES = { "LaneCountForwardRed", "LaneCountBackwardRed" }

-- Whether a segment kind can have different lanes at each end
function RoadMath.supportsLaneChange(kind: SegmentKind): boolean
	return kind == "Straight"
end

-- An override counts when it's a non-negative number: the generator declares
-- them with -1 ("same as the blue end") as the default
local function isOverride(value: any): boolean
	return typeof(value) == "number" and value >= 0
end

local function redOverridesActive(kind: SegmentKind, model: Instance): boolean
	return RoadMath.supportsLaneChange(kind)
		and isOverride(model:GetAttribute(RoadMath.RED_LANE_OVERRIDES[1]))
		and isOverride(model:GetAttribute(RoadMath.RED_LANE_OVERRIDES[2]))
end

-- Whether the segment has its own lane counts at the red end ("Same at both
-- ends" off)
function RoadMath.hasLaneChange(segment: SegmentInfo): boolean
	return redOverridesActive(segment.Kind, segment.Model)
end

-- The forward/backward lane counts at one end of a segment
local function readEndLaneCounts(kind: SegmentKind, model: Instance, id: EndpointId): (number, number)
	local armIndex = RoadMath.armIndex(id)
	if kind == "Roundabout" and armIndex then
		-- Forward is leaving the roundabout
		local arm = RoadMath.roundaboutLayout(model).Arms[armIndex]
		if arm then
			return arm.Exit, arm.Entry
		end
	end
	if kind == "Split" and (id == "BranchLeft" or id == "BranchRight") then
		local layout = RoadMath.splitLayout(model)
		if id == "BranchLeft" then
			return layout.LeftForward, layout.LeftBackward
		end
		return layout.RightForward, layout.RightBackward
	end
	if id == "Red" and redOverridesActive(kind, model) then
		return RoadMath.sanitizeLaneCounts(
			model:GetAttribute(RoadMath.RED_LANE_OVERRIDES[1]) :: number,
			model:GetAttribute(RoadMath.RED_LANE_OVERRIDES[2]) :: number
		)
	end
	return readLaneCounts(model, RoadMath.laneSuffix(kind, id))
end

--------------------------------------------------------------------------------
-- Y splits
--------------------------------------------------------------------------------

--[[
	A Y split is one road dividing into two. Its stem end (facing -Z) joins
	the road; its left and right branch ends face +Z, side by side, with
	"left" as seen looking from the stem toward the branches (+X, which is
	+lat: left of forward travel). The stem's lanes (LaneCountForward /
	LaneCountBackward, forward running stem -> branches) divide across the
	road: the left branch takes SplitLanesLeft lanes from the stem's left
	edge, the right branch the rest, every lane keeping its travel
	direction. So a two-way road can separate into its two directions (the
	start of a dual carriageway), or a one-way carriageway can diverge.

	SplitSeparation is the gap between the two branch roads (outside their
	footways) at the far end. The split line, where the branches part, is at
	local x = 0. The layout depends only on attributes: Size.Z is the length,
	and Size.X is kept at BoxWidth just so the box encloses the geometry.
]]

-- The default left-branch lanes: a two-way road separates into its two
-- directions (driving on the left, the lanes on the left are the ones
-- travelling stem -> branches); a one-way road splits about in half, the
-- smaller part to the left (nearside, for UK diverges)
function RoadMath.defaultSplitLanesLeft(forward: number, backward: number, driveLeft: boolean): number
	if forward > 0 and backward > 0 then
		return if driveLeft then forward else backward
	end
	return math.max(math.floor((forward + backward) / 2), 1)
end

function RoadMath.splitLayout(model: Instance): SplitLayout
	local laneWidth = getNumberAttribute(model, "LaneWidth", RoadDefaults.LaneWidth)
	local sidewalk = getNumberAttribute(model, "SidewalkWidth", RoadDefaults.SidewalkWidth)
	local forward, backward = readLaneCounts(model, "")
	local total = forward + backward
	local driveLeft = model:GetAttribute("DriveSide") ~= "Right"

	local leftValue = model:GetAttribute("SplitLanesLeft")
	local left = if typeof(leftValue) == "number" and leftValue >= 0
		then math.floor(leftValue)
		else RoadMath.defaultSplitLanesLeft(forward, backward, driveLeft)
	-- Each branch keeps at least one lane (a one-lane stem can't really split)
	left = if total >= 2 then math.clamp(left, 1, total - 1) else total
	local right = total - left

	-- Across the stem from right (-x) to left (+x) come the -lat group of
	-- lanes (backward when driving on the left), then the +lat group
	local plusCount = if driveLeft then forward else backward
	local leftPlus = math.min(left, plusCount)
	local leftMinus = left - leftPlus
	local rightPlus = plusCount - leftPlus
	local rightMinus = right - rightPlus
	local leftForward, leftBackward, rightForward, rightBackward
	if driveLeft then
		leftForward, leftBackward, rightForward, rightBackward = leftPlus, leftMinus, rightPlus, rightMinus
	else
		leftForward, leftBackward, rightForward, rightBackward = leftMinus, leftPlus, rightMinus, rightPlus
	end

	local separation = math.max(getNumberAttribute(model, "SplitSeparation", RoadDefaults.SplitSeparation), 0)
	local stemRoadway = total * laneWidth
	local stemWidth = stemRoadway + 2 * sidewalk
	local leftWidth = left * laneWidth + 2 * sidewalk
	local rightWidth = right * laneWidth + 2 * sidewalk
	-- The stem's right-branch lanes lie right of the split line at x = 0
	local stemX = stemRoadway / 2 - right * laneWidth
	-- The two branch roads side by side at the far end, centred on x = 0
	local span = rightWidth + separation + leftWidth
	return {
		StemX = stemX,
		LeftX = span / 2 - leftWidth / 2,
		RightX = -span / 2 + rightWidth / 2,
		StemWidth = stemWidth,
		LeftWidth = leftWidth,
		RightWidth = rightWidth,
		LeftLanes = left,
		RightLanes = right,
		LeftForward = leftForward,
		LeftBackward = leftBackward,
		RightForward = rightForward,
		RightBackward = rightBackward,
		BoxWidth = 2 * math.max(span / 2, math.abs(stemX) + stemWidth / 2),
	}
end

--------------------------------------------------------------------------------
-- Roundabouts
--------------------------------------------------------------------------------

--[[
	A roundabout's central island is outlined by the convex hull of one or
	more circles (IslandShape, "x,z,radius;x,z,radius;..." in the local XZ
	plane): one circle is a round island, two an oval, four a rounded square
	or rectangle, more any convex shape. The circulating carriageway is the
	band from the outline out to RingWidth beyond it, with a footway outside
	that and an optional raised apron just inside the outline.

	Offsetting a hull of circles by d is exactly the hull of the same circles
	with every radius grown by d (the tangent edges keep their directions), so
	every edge of the roundabout is the same outline at a different offset,
	and can never cross itself.
]]

-- (Always a fresh table: callers edit the circles they get)
function RoadMath.parseIslandShape(value: any): { RoundaboutCircle }
	local circles: { RoundaboutCircle } = {}
	if typeof(value) == "string" then
		for _, entry in string.split(value, ";") do
			local parts = string.split(entry, ",")
			local x, z, r = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
			if x and z and r and #circles < RoadDefaults.RoundaboutMaxCorners then
				table.insert(circles, { X = x, Z = z, Radius = math.max(r, 1) })
			end
		end
	end
	if #circles == 0 then
		return { { X = 0, Z = 0, Radius = RoadDefaults.RoundaboutIslandRadius } }
	end
	return circles
end

function RoadMath.serializeIslandShape(circles: { RoundaboutCircle }): string
	local entries = {}
	local function tidy(value: number): string
		return tostring(math.round(value * 100) / 100)
	end
	for _, circle in circles do
		table.insert(entries, `{tidy(circle.X)},{tidy(circle.Z)},{tidy(circle.Radius)}`)
	end
	return table.concat(entries, ";")
end

--[[
	Arms (Arms, "angle,exit,entry;..."): roads joining the roundabout. An
	arm sits where the ray from the island's centroid at its angle meets the
	outline, and runs straight out along the outline's normal there, from
	the ring's outer edge for ArmLength to its end: a normal road end with
	Exit lanes leaving and Entry lanes arriving. Traffic keeps to the
	DriveSide, so (driving on the left) looking out along the arm the exit
	lanes are on the left. Near the ring the exit and entry lanes part
	around a splitter island SplitterWidth wide; the arm's kerbs curve into
	the ring's outer kerb with radius EntryKerbRadius.
]]
local MAX_ARMS = 12

-- An arm as stored: "angle,exit,entry" plus optionally
-- ",length,skew,flare,arrows". A length of 0 uses the roundabout's
-- ArmLength; skew (degrees, within MAX_ARM_SKEW either way) swings the arm
-- off square to the island edge, clockwise seen from above for positive
-- values; flare is extra entry lanes at the give way line (up to
-- MAX_ARM_FLARE); arrows are the entry lanes' arrows (see
-- RoadMath.laneArrows), "" for automatic.
export type ArmSpec = {
	Angle: number,
	Exit: number,
	Entry: number,
	Length: number,
	Skew: number,
	Flare: number?,
	Arrows: string?,
}

local MAX_ARM_SKEW = 45
RoadMath.MAX_ARM_SKEW = MAX_ARM_SKEW
local MAX_ARM_FLARE = 3
RoadMath.MAX_ARM_FLARE = MAX_ARM_FLARE

-- Only arrow letters and separators survive in a stored arrows field
local function sanitizeArrows(value: string?): string
	return (string.gsub(string.upper(value or ""), "[^LAR/%-]", ""))
end

function RoadMath.parseArms(value: any): { ArmSpec }
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
					-- (Only an arm with entry lanes can flare)
					Flare = if entryLanes > 0 then math.clamp(math.floor(tonumber(parts[6]) or 0), 0, MAX_ARM_FLARE) else 0,
					Arrows = sanitizeArrows(parts[7]),
				})
			end
		end
	end
	return arms
end

function RoadMath.serializeArms(arms: { ArmSpec }): string
	local entries = {}
	local function tidy(value: number): string
		return tostring(math.round(value * 100) / 100)
	end
	for _, arm in arms do
		local entry = `{tidy(arm.Angle)},{arm.Exit},{arm.Entry}`
		-- The optional fields, up to the last one that's set
		local extras = {
			tidy(arm.Length or 0),
			tidy(arm.Skew or 0),
			tostring(arm.Flare or 0),
			sanitizeArrows(arm.Arrows),
		}
		while #extras > 0 and (extras[#extras] == "0" or extras[#extras] == "") do
			table.remove(extras)
		end
		if #extras > 0 then
			entry ..= "," .. table.concat(extras, ",")
		end
		table.insert(entries, entry)
	end
	return table.concat(entries, ";")
end

--[[
	Lane arrows on an arm's approach: one designation per entry lane at the
	give way line, listed left to right as the driver sees them, each made
	of the letters L (left), A (ahead) and R (right) in that order, or ""
	for no arrow. Stored as "LA/R" ("-" for a lane without one); with
	nothing stored they're automatic: none for a single lane, otherwise the
	leftmost lane turns left (and goes ahead when there are only two), the
	rightmost turns right, and any between go ahead (Highway Code rule 186).
]]
function RoadMath.laneArrows(stored: string?, lanes: number): { string }
	local arrows = {}
	local value = sanitizeArrows(stored)
	if value == "" then
		for lane = 1, lanes do
			table.insert(
				arrows,
				if lanes < 2 then ""
					elseif lane == 1 then (if lanes == 2 then "LA" else "L")
					elseif lane == lanes then "R"
					else "A"
			)
		end
		return arrows
	end
	local entries = string.split(value, "/")
	for lane = 1, lanes do
		local entry = entries[lane] or ""
		local letters = ""
		for _, letter in { "L", "A", "R" } do
			if string.find(entry, letter, 1, true) then
				letters ..= letter
			end
		end
		table.insert(arrows, letters)
	end
	return arrows
end

-- Lane arrows as stored (never "", which means automatic)
function RoadMath.serializeLaneArrows(arrows: { string }): string
	local entries = {}
	for _, letters in arrows do
		table.insert(entries, if letters == "" then "-" else letters)
	end
	return table.concat(entries, "/")
end

-- Points around the island outline ("stations") with the outward normal at
-- each: the hull's arcs sampled at most 6 degrees apart, the straight
-- tangent edges running between one arc's last station and the next arc's
-- first (which share a normal). The generator samples identically.
function RoadMath.roundaboutStations(circles: { RoundaboutCircle }): { { PX: number, PZ: number, NX: number, NZ: number } }
	local step = math.rad(6)
	local stations = {}
	for _, piece in RoadMath.roundaboutHull(circles) do
		local circle = piece.Circle
		local steps = math.max(math.ceil((piece.To - piece.From) / step), 1)
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
	return stations
end

-- Where the ray from (cx, cz) at an angle (radians) leaves the outline, the
-- outward normal there, and which station segment it's on (the segment from
-- station i to the next, part way t along it)
function RoadMath.outlineHit(
	stations,
	cx: number,
	cz: number,
	angle: number
): (number, number, number, number, number, number)
	local dx, dz = math.cos(angle), math.sin(angle)
	local bestT, hitX, hitZ, hitNX, hitNZ = math.huge, cx, cz, dx, dz
	local hitIndex, hitS = 1, 0
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
				hitIndex, hitS = i, math.clamp(s, 0, 1)
			end
		end
	end
	return hitX, hitZ, hitNX, hitNZ, hitIndex, hitS
end

-- The island's centroid: the mean of its circle centres, always inside it
function RoadMath.islandCentroid(circles: { RoundaboutCircle }): (number, number)
	local cx, cz = 0, 0
	for _, circle in circles do
		cx += circle.X
		cz += circle.Z
	end
	return cx / #circles, cz / #circles
end

--[[
	Ring sections (RingSections, "angle,lanes[,side];..."): the circulating
	carriageway's lane count can change on the way round. Each boundary sits
	where the ray from the island's centroid at its angle meets the outline,
	and sets the lanes from there on in the direction of travel, up to the
	next boundary (with none, the ring has RingLanes all the way round). The
	ring's outer edge follows the lanes: they change over RingTaperLength
	after a boundary, the edge easing out or in, and the side ("Out" or
	"In") is which side of the ring the lane appears or ends on (only the
	markings differ). A lane change can't overlap an arm's mouth, where the
	kerbs need the ring's width steady, so it's moved clear of it, whichever
	way is nearer.

	Positions round the ring are distances along the outline offset by a
	lane width, in the direction of travel, from the first outline station.
	The generator mirrors all of this exactly.
]]
export type RingSectionSpec = {
	Angle: number,
	Lanes: number,
	Side: "In" | "Out",
}

export type RingSection = {
	Angle: number,
	Lanes: number,
	Side: "In" | "Out",
	-- The lanes before it
	Previous: number,
	-- Its boundary's position round the ring, and where its lane change
	-- starts (moved clear of the arms' mouths) and how long it is (0 for none)
	Position: number,
	Start: number,
	Taper: number,
	-- Whether the lane change could be kept clear of the arms' mouths
	Clear: boolean,
	-- Where the boundary meets the outline, the outward normal there, and
	-- the ring's width there
	X: number,
	Z: number,
	NX: number,
	NZ: number,
	Width: number,
}

type Station = { PX: number, PZ: number, NX: number, NZ: number }

-- Distances round the ring: along the outline offset by `reference`, in the
-- direction of travel (`direction` 1: station order; -1: against it)
type RingMeasure = {
	Stations: { Station },
	Cumulative: { number },
	Lengths: { number },
	Total: number,
	Direction: number,
	Reference: number,
}

local MAX_RING_SECTIONS = 12
RoadMath.MAX_RING_SECTIONS = MAX_RING_SECTIONS
-- Room kept clear of a lane change beyond an arm's kerbs
local MOUTH_CLEARANCE = 4
-- A lane change takes at most this much of the way to the next boundary
local TAPER_SHARE = 0.8

local function smoothstep(u: number): number
	return u * u * (3 - 2 * u)
end

function RoadMath.parseRingSections(value: any): { RingSectionSpec }
	local sections: { RingSectionSpec } = {}
	if typeof(value) == "string" then
		for _, entry in string.split(value, ";") do
			local parts = string.split(entry, ",")
			local angle, lanes = tonumber(parts[1]), tonumber(parts[2])
			if angle and lanes and #sections < MAX_RING_SECTIONS then
				table.insert(sections, {
					Angle = angle,
					Lanes = math.max(math.floor(lanes), 1),
					Side = if parts[3] == "In" then "In" else "Out",
				})
			end
		end
	end
	return sections
end

function RoadMath.serializeRingSections(sections: { RingSectionSpec }): string
	local entries = {}
	for _, section in sections do
		local entry = `{math.round(section.Angle * 100) / 100},{section.Lanes}`
		if section.Side == "In" then
			entry ..= ",In"
		end
		table.insert(entries, entry)
	end
	return table.concat(entries, ";")
end

local function ringMeasure(stations: { Station }, reference: number, direction: number): RingMeasure
	local count = #stations
	local cumulative, lengths = {}, {}
	local total = 0
	for i = 1, count do
		local a, b = stations[i], stations[i % count + 1]
		local dx = (b.PX + b.NX * reference) - (a.PX + a.NX * reference)
		local dz = (b.PZ + b.NZ * reference) - (a.PZ + a.NZ * reference)
		cumulative[i] = total
		lengths[i] = math.sqrt(dx * dx + dz * dz)
		total += lengths[i]
	end
	return {
		Stations = stations,
		Cumulative = cumulative,
		Lengths = lengths,
		Total = math.max(total, 1e-6),
		Direction = direction,
		Reference = reference,
	}
end

-- The ring position of the point t along the segment from station i
local function ringPosition(measure: RingMeasure, i: number, t: number): number
	local s = measure.Cumulative[i] + measure.Lengths[i] * t
	return if measure.Direction > 0 then s else (measure.Total - s) % measure.Total
end

-- The ring position nearest a point
local function ringPositionOf(measure: RingMeasure, x: number, z: number): number
	local stations = measure.Stations
	local count = #stations
	local r = measure.Reference
	local best, bestI, bestT = math.huge, 1, 0
	for i = 1, count do
		local a, b = stations[i], stations[i % count + 1]
		local ax, az = a.PX + a.NX * r, a.PZ + a.NZ * r
		local ex, ez = b.PX + b.NX * r - ax, b.PZ + b.NZ * r - az
		local lengthSq = ex * ex + ez * ez
		local t = if lengthSq > 1e-12 then math.clamp(((x - ax) * ex + (z - az) * ez) / lengthSq, 0, 1) else 0
		local dx, dz = ax + ex * t - x, az + ez * t - z
		local distance = dx * dx + dz * dz
		if distance < best then
			best, bestI, bestT = distance, i, t
		end
	end
	return ringPosition(measure, bestI, bestT)
end

-- The stretch of ring (From to To) an arm's mouth spans with its kerbs:
-- `reach` either side of its mouth, along the ring
local function mouthRange(
	measure: RingMeasure,
	px: number,
	pz: number,
	normalX: number,
	normalZ: number,
	nx: number,
	nz: number,
	skew: number,
	ringWidth: number,
	reach: number
): { From: number, To: number }
	local cosine = math.cos(skew)
	local mx, mz = px + nx * ringWidth / cosine, pz + nz * ringWidth / cosine
	local tx, tz = -normalZ, normalX
	local along = reach / cosine
	local total = measure.Total
	local centre = ringPositionOf(measure, mx, mz)
	local low, high = 0, 0
	for _, sign in { -1, 1 } do
		local u = ringPositionOf(measure, mx + tx * along * sign, mz + tz * along * sign)
		local offset = (u - centre + total / 2) % total - total / 2
		low, high = math.min(low, offset), math.max(high, offset)
	end
	return { From = centre + low, To = centre + high }
end

-- Where each section's lane change goes (`positions`: its boundary's ring
-- position), kept clear of the mouths
local function layoutRingSections(
	specs: { RingSectionSpec },
	positions: { number },
	mouths: { { From: number, To: number } },
	total: number,
	taperLength: number
): { any }
	local order = {}
	for i in specs do
		table.insert(order, i)
	end
	table.sort(order, function(x, y)
		if positions[x] ~= positions[y] then
			return positions[x] < positions[y]
		end
		return x < y
	end)
	local laidOut = {}
	for m, i in order do
		local spec = specs[i]
		local previous = specs[order[(m - 2) % #order + 1]]
		local gap = if #order == 1 then total else (positions[order[m % #order + 1]] - positions[i]) % total
		local taper = if previous.Lanes == spec.Lanes then 0 else math.min(taperLength, TAPER_SHARE * gap)
		local start = positions[i]
		local function overlapping(): { From: number, To: number }?
			for _, mouth in mouths do
				if (mouth.From - start) % total < taper or (start - mouth.From) % total < mouth.To - mouth.From then
					return mouth
				end
			end
			return nil
		end
		if taper > 0 then
			-- Push it past the mouths in its way, the nearer way round
			local direction, shifted = 0, 0
			for _ = 1, 2 * #mouths + 2 do
				local mouth = overlapping()
				if not mouth or shifted >= total then
					break
				end
				local forward = (mouth.To - start) % total
				local backward = (start + taper - mouth.From) % total
				if direction == 0 then
					direction = if forward <= backward then 1 else -1
				end
				local step = if direction > 0 then forward else backward
				shifted += step
				start = (start + direction * step) % total
			end
		end
		laidOut[i] = {
			Angle = spec.Angle,
			Lanes = spec.Lanes,
			Side = spec.Side,
			Previous = previous.Lanes,
			Position = positions[i],
			Start = start,
			Taper = taper,
			Clear = taper == 0 or overlapping() == nil,
		}
	end
	return laidOut
end

-- The circulating lanes at a ring position (fractional within a lane
-- change)
local function ringLanesAt(sections: { any }, ringLanes: number, total: number, u: number): number
	local best, bestDistance = nil, math.huge
	for _, section in sections do
		local distance = (u - section.Start) % total
		if distance < bestDistance then
			best, bestDistance = section, distance
		end
	end
	if not best then
		return ringLanes
	end
	if bestDistance < best.Taper then
		return best.Previous + (best.Lanes - best.Previous) * smoothstep(bestDistance / best.Taper)
	end
	return best.Lanes
end

-- The ring's width at a position round it (see Ring sections)
function RoadMath.ringWidthAt(layout: RoundaboutLayout, position: number): number
	return ringLanesAt(layout.Sections, layout.RingLanes, layout.RingLength, position) * layout.LaneWidth
end

function RoadMath.roundaboutLayout(model: Instance): RoundaboutLayout
	local circles = RoadMath.parseIslandShape(model:GetAttribute("IslandShape"))
	local lanes = math.max(math.floor(getNumberAttribute(model, "RingLanes", RoadDefaults.RoundaboutRingLanes)), 1)
	local laneWidth = getNumberAttribute(model, "LaneWidth", RoadDefaults.LaneWidth)
	local sidewalkWidth = math.max(getNumberAttribute(model, "SidewalkWidth", RoadDefaults.SidewalkWidth), 0)
	local armLength = math.max(getNumberAttribute(model, "ArmLength", RoadDefaults.RoundaboutArmLength), 1)
	local splitterWidth = math.max(getNumberAttribute(model, "SplitterWidth", RoadDefaults.RoundaboutSplitterWidth), 0)
	local kerbRadius = math.max(
		getNumberAttribute(model, "EntryKerbRadius", RoadDefaults.RoundaboutEntryKerbRadius),
		sidewalkWidth + 2
	)
	local taperLength =
		math.max(getNumberAttribute(model, "RingTaperLength", RoadDefaults.RoundaboutRingTaperLength), 1)
	local smallest = math.huge
	for _, circle in circles do
		smallest = math.min(smallest, circle.Radius)
	end

	local stations = RoadMath.roundaboutStations(circles)
	local cx, cz = RoadMath.islandCentroid(circles)
	local exitSide = if model:GetAttribute("DriveSide") == "Right" then -1 else 1
	-- Positions round the ring run the way traffic does: with the outline's
	-- stations driving on the left (clockwise seen from above)
	local measure = ringMeasure(stations, laneWidth, exitSide)
	local sectionSpecs = RoadMath.parseRingSections(model:GetAttribute("RingSections"))
	local maxLanes = if #sectionSpecs > 0 then 1 else lanes
	for _, section in sectionSpecs do
		maxLanes = math.max(maxLanes, section.Lanes)
	end
	local ringWidth = maxLanes * laneWidth

	-- No attribute at all means the generator's default arms ("" is none)
	local armsValue = model:GetAttribute("Arms")
	if armsValue == nil then
		armsValue = RoadDefaults.RoundaboutArms
	end
	local specs = RoadMath.parseArms(armsValue)
	-- Where each arm attaches, and the stretch of ring its mouth spans
	local attachments = {}
	local mouths = {}
	for _, arm in specs do
		local px, pz, normalX, normalZ, index, t = RoadMath.outlineHit(stations, cx, cz, math.rad(arm.Angle))
		-- The arm's direction: the outline normal, swung by its skew
		local skew = math.rad(arm.Skew)
		local nx = normalX * math.cos(skew) - normalZ * math.sin(skew)
		local nz = normalX * math.sin(skew) + normalZ * math.cos(skew)
		table.insert(attachments, {
			PX = px,
			PZ = pz,
			NX = nx,
			NZ = nz,
			Skew = skew,
			Position = ringPosition(measure, index, t),
		})
		local splitter = if arm.Exit > 0 and arm.Entry > 0 then splitterWidth else 0
		local reach = splitter / 2
			+ math.max(arm.Exit, arm.Entry + (arm.Flare or 0)) * laneWidth
			+ kerbRadius
			+ MOUTH_CLEARANCE
		table.insert(mouths, mouthRange(measure, px, pz, normalX, normalZ, nx, nz, skew, ringWidth, reach))
	end
	local positions = {}
	local boundaries = {}
	for i, section in sectionSpecs do
		local x, z, nx, nz, index, t = RoadMath.outlineHit(stations, cx, cz, math.rad(section.Angle))
		positions[i] = ringPosition(measure, index, t)
		boundaries[i] = { X = x, Z = z, NX = nx, NZ = nz }
	end
	local sections = layoutRingSections(sectionSpecs, positions, mouths, measure.Total, taperLength)
	for i, section in sections do
		local boundary = boundaries[i]
		section.X, section.Z, section.NX, section.NZ = boundary.X, boundary.Z, boundary.NX, boundary.NZ
		section.Width = ringLanesAt(sections, lanes, measure.Total, section.Position) * laneWidth
	end

	local arms: { RoundaboutArm } = {}
	for k, arm in specs do
		local attachment = attachments[k]
		local px, pz, nx, nz, skew = attachment.PX, attachment.PZ, attachment.NX, attachment.NZ, attachment.Skew
		-- Looking out along the arm, +T is the left
		local tx, tz = nz, -nx
		-- Its mouth: where its axis crosses the ring's outer edge (taking the
		-- outline as straight across the ring's width there)
		local armRingWidth = ringLanesAt(sections, lanes, measure.Total, attachment.Position) * laneWidth
		local toMouth = armRingWidth / math.cos(skew)
		local mouthX, mouthZ = px + nx * toMouth, pz + nz * toMouth
		-- The end is centred on its roadway: the exit lanes one side of the
		-- arm's axis, the entry lanes the other
		local centre = exitSide * (arm.Exit - arm.Entry) * laneWidth / 2
		local length = if arm.Length > 0 then arm.Length else armLength
		table.insert(arms, {
			Angle = arm.Angle,
			Exit = arm.Exit,
			Entry = arm.Entry,
			Length = length,
			LengthOverride = arm.Length,
			Skew = arm.Skew,
			Flare = arm.Flare or 0,
			Arrows = arm.Arrows or "",
			RingWidth = armRingWidth,
			Position = attachment.Position,
			AttachX = px,
			AttachZ = pz,
			NX = nx,
			NZ = nz,
			MouthX = mouthX,
			MouthZ = mouthZ,
			EndX = mouthX + nx * length + tx * centre,
			EndZ = mouthZ + nz * length + tz * centre,
			EndWidth = (arm.Exit + arm.Entry) * laneWidth + 2 * sidewalkWidth,
		})
	end

	return {
		Circles = circles,
		RingLanes = lanes,
		LaneWidth = laneWidth,
		RingWidth = ringWidth,
		SidewalkWidth = sidewalkWidth,
		ApronWidth = math.clamp(
			getNumberAttribute(model, "ApronWidth", RoadDefaults.RoundaboutApronWidth),
			0,
			math.max(smallest - 1, 0)
		),
		Sections = sections,
		RingLength = measure.Total,
		RingTaperLength = taperLength,
		Arms = arms,
		ArmLength = armLength,
		SplitterWidth = splitterWidth,
		SplitterStyle = if model:GetAttribute("SplitterStyle") == "Hatched" then "Hatched" else "Kerbed",
		EntryKerbRadius = kerbRadius,
		FlareLength = math.max(getNumberAttribute(model, "FlareLength", RoadDefaults.RoundaboutFlareLength), 1),
	}
end

-- The box a roundabout needs around its pivot (it's laid out symmetrically,
-- since the outline circles are in pivot space), arms included
function RoadMath.roundaboutSize(layout: RoundaboutLayout): Vector3
	local outer = layout.RingWidth + layout.SidewalkWidth
	local extentX, extentZ = 0, 0
	for _, circle in layout.Circles do
		extentX = math.max(extentX, math.abs(circle.X) + circle.Radius + outer)
		extentZ = math.max(extentZ, math.abs(circle.Z) + circle.Radius + outer)
	end
	for _, arm in layout.Arms do
		extentX = math.max(extentX, math.abs(arm.EndX) + arm.EndWidth / 2)
		extentZ = math.max(extentZ, math.abs(arm.EndZ) + arm.EndWidth / 2)
	end
	return Vector3.new(2 * extentX, 0, 2 * extentZ)
end

-- The arm index of a roundabout end id ("Arm3" -> 3), or nil
function RoadMath.armIndex(id: EndpointId): number?
	local digits = string.match(id, "^Arm(%d+)$")
	return if digits then tonumber(digits) else nil
end

--[[
	The convex hull of circles, as the arcs of the circles on it in order
	around the outline (counterclockwise in the XZ plane taken as math x, y
	axes), each followed by the straight tangent edge to the next. Circles
	inside another circle, or not reaching the hull, don't appear.
]]
function RoadMath.roundaboutHull(circles: { RoundaboutCircle }): { HullPiece }
	-- Drop circles contained in another (of two identical circles, keep the
	-- first)
	local kept: { RoundaboutCircle } = {}
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

	-- Each hull circle's outgoing edge: the outer tangent to another circle
	-- with every circle on its inner side. Travelling counterclockwise, the
	-- outward normal n is to the right, and the tangent condition is
	-- n . (cj - ci) = ri - rj.
	local outgoing: { [number]: { To: number, NX: number, NZ: number, Length: number } } = {}
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
			-- n = cosine * u - sine * (left perpendicular of u)
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
			-- Of edges along the same line (collinear circles), take the
			-- longest, skipping circles that only touch it
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

	local pieces: { HullPiece } = {}
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

function RoadMath.getSegmentInfo(instance: Instance): SegmentInfo?
	if instance.ClassName ~= "ProceduralModel" then
		return nil
	end
	local kind: SegmentKind? = nil
	for _, child in instance:GetChildren() do
		local foundKind = GENERATOR_KINDS[child.Name]
		if foundKind and child:IsA("ModuleScript") then
			kind = foundKind
			break
		end
	end
	if not kind then
		return nil
	end
	local model = instance :: Model
	local sidewalkWidth = getNumberAttribute(model, "SidewalkWidth", RoadDefaults.SidewalkWidth)
	if kind == "Intersection" then
		return {
			Model = model,
			Kind = kind,
			Width = totalLanes(model, "Z") * getNumberAttribute(model, "LaneWidthZ", RoadDefaults.LaneWidth)
				+ 2 * sidewalkWidth,
			WidthX = totalLanes(model, "X") * getNumberAttribute(model, "LaneWidthX", RoadDefaults.LaneWidth)
				+ 2 * sidewalkWidth,
			Angle = math.rad(math.clamp(getNumberAttribute(model, "IntersectionAngle", RoadDefaults.IntersectionAngle),
				RoadDefaults.MinIntersectionAngle, RoadDefaults.MaxIntersectionAngle)),
			ThroughRoad = model:GetAttribute("ThroughRoad") ~= false,
			Size = (model :: any).Size :: Vector3,
			Pivot = model:GetPivot(),
			Flip = false,
		}
	end
	if kind == "Roundabout" then
		local layout = RoadMath.roundaboutLayout(model)
		return {
			Model = model,
			Kind = kind,
			Width = layout.RingWidth,
			Size = (model :: any).Size :: Vector3,
			Pivot = model:GetPivot(),
			Flip = false,
			Roundabout = layout,
		}
	end
	if kind == "Split" then
		local layout = RoadMath.splitLayout(model)
		return {
			Model = model,
			Kind = kind,
			Width = layout.StemWidth,
			Size = (model :: any).Size :: Vector3,
			Pivot = model:GetPivot(),
			Flip = false,
			Split = layout,
		}
	end
	local laneWidth = getNumberAttribute(model, "LaneWidth", RoadDefaults.LaneWidth)
	local blueForward, blueBackward = readEndLaneCounts(kind, model, "Blue")
	local redForward, redBackward = readEndLaneCounts(kind, model, "Red")
	local blueWidth = (blueForward + blueBackward) * laneWidth + 2 * sidewalkWidth
	local redWidth = (redForward + redBackward) * laneWidth + 2 * sidewalkWidth
	return {
		Model = model,
		Kind = kind,
		Width = blueWidth,
		WidthRed = if redWidth ~= blueWidth then redWidth else nil,
		Size = (model :: any).Size :: Vector3,
		Pivot = model:GetPivot(),
		Flip = model:GetAttribute("Flip") == true,
	}
end

-- Walk up from (typically) a generated road part to the segment it belongs to
function RoadMath.segmentFromDescendant(instance: Instance?): SegmentInfo?
	local current = instance
	while current and current ~= workspace and current ~= game do
		local info = RoadMath.getSegmentInfo(current)
		if info then
			return info
		end
		current = current.Parent
	end
	return nil
end

function RoadMath.findSegments(root: Instance): { SegmentInfo }
	local segments = {}
	-- Recurse manually so we can prune: segments never contain other segments
	-- (their contents are just the generator and generated geometry), and
	-- BaseParts never contain them either. This keeps rescans cheap even in
	-- places with a lot of generated road geometry.
	local function visit(container: Instance)
		for _, child in container:GetChildren() do
			local info = RoadMath.getSegmentInfo(child)
			if info then
				table.insert(segments, info)
			elseif not child:IsA("BasePart") then
				visit(child)
			end
		end
	end
	visit(root)
	return segments
end

--------------------------------------------------------------------------------
-- Endpoint frames
--------------------------------------------------------------------------------

-- Endpoint frame in the segment's local (pivot) space
function RoadMath.localEndpointFrame(kind: SegmentKind, size: Vector3, width: number, flip: boolean, id: EndpointId): CFrame
	local halfY = size.Y / 2
	local halfZ = size.Z / 2
	if kind == "Straight" then
		local sway = math.max((size.X - width) / 2, 0)
		local fs = if flip then -1 else 1
		if id == "Blue" then
			return CFrame.lookAlong(Vector3.new(-fs * sway, -halfY, -halfZ), -Vector3.zAxis)
		else
			return CFrame.lookAlong(Vector3.new(fs * sway, halfY, halfZ), Vector3.zAxis)
		end
	else
		local w = width / 2
		local halfX = size.X / 2
		if id == "Blue" then
			local y = if flip then halfY else -halfY
			return CFrame.lookAlong(Vector3.new(-halfX + w, y, -halfZ), -Vector3.zAxis)
		else
			local y = if flip then -halfY else halfY
			return CFrame.lookAlong(Vector3.new(halfX, y, halfZ - w), Vector3.xAxis)
		end
	end
end

-- An intersection's ends sit at the box bottom: the Z road's ends centred on
-- the ±Z faces, and the (possibly angled) X road's squared ends at halfX
-- along its own direction
local function intersectionEndpointFrame(segment: SegmentInfo, id: EndpointId): CFrame
	local size = segment.Size
	local halfY = size.Y / 2
	if id == "ZPlus" then
		return CFrame.lookAlong(Vector3.new(0, -halfY, size.Z / 2), Vector3.zAxis)
	elseif id == "ZMinus" then
		return CFrame.lookAlong(Vector3.new(0, -halfY, -size.Z / 2), -Vector3.zAxis)
	end
	local angle = segment.Angle or math.pi / 2
	local uX = Vector3.new(math.sin(angle), 0, math.cos(angle))
	local s = if id == "XPlus" then 1 else -1
	local p = uX * (s * size.X / 2)
	return CFrame.lookAlong(Vector3.new(p.X, -halfY, p.Z), uX * s)
end

-- A Y split's ends sit at the box bottom: the stem on the -Z face, the two
-- branches side by side on the +Z face (see the Y splits section)
local function splitEndpointFrame(segment: SegmentInfo, id: EndpointId): CFrame
	local layout = assert(segment.Split)
	local halfY = segment.Size.Y / 2
	local halfZ = segment.Size.Z / 2
	if id == "Stem" then
		return CFrame.lookAlong(Vector3.new(layout.StemX, -halfY, -halfZ), -Vector3.zAxis)
	end
	local x = if id == "BranchLeft" then layout.LeftX else layout.RightX
	return CFrame.lookAlong(Vector3.new(x, -halfY, halfZ), Vector3.zAxis)
end

function RoadMath.getEndpoint(segment: SegmentInfo, id: EndpointId): Endpoint
	local localFrame
	local armIndex = RoadMath.armIndex(id)
	if id == "Centre" then
		-- Facing straight up, so it can never pass for a joint with a road end
		local position = Vector3.new(0, -segment.Size.Y / 2, 0)
		localFrame = CFrame.lookAt(position, position + Vector3.yAxis, Vector3.zAxis)
	elseif armIndex and segment.Roundabout and segment.Roundabout.Arms[armIndex] then
		local arm = segment.Roundabout.Arms[armIndex]
		localFrame = CFrame.lookAlong(
			Vector3.new(arm.EndX, -segment.Size.Y / 2, arm.EndZ),
			Vector3.new(arm.NX, 0, arm.NZ)
		)
	elseif segment.Kind == "Intersection" then
		localFrame = intersectionEndpointFrame(segment, id)
	elseif segment.Kind == "Split" then
		localFrame = splitEndpointFrame(segment, id)
	else
		localFrame = RoadMath.localEndpointFrame(segment.Kind, segment.Size, RoadMath.boxWidth(segment), segment.Flip, id)
	end
	return {
		Segment = segment,
		Id = id,
		WorldCFrame = segment.Pivot * localFrame,
	}
end

function RoadMath.getEndpoints(segment: SegmentInfo): (Endpoint, Endpoint)
	return RoadMath.getEndpoint(segment, "Blue"), RoadMath.getEndpoint(segment, "Red")
end

-- The endpoint ids a segment has
function RoadMath.endpointIds(segment: SegmentInfo): { EndpointId }
	if segment.Kind == "Intersection" then
		local ids: { EndpointId } = { "ZPlus", "ZMinus", "XPlus" }
		if segment.ThroughRoad then
			table.insert(ids, "XMinus")
		end
		return ids
	elseif segment.Kind == "Split" then
		return { "Stem", "BranchLeft", "BranchRight" }
	elseif segment.Kind == "Roundabout" then
		local ids: { EndpointId } = {}
		for index in assert(segment.Roundabout).Arms do
			table.insert(ids, ("Arm" .. index) :: any)
		end
		return ids
	end
	return { "Blue", "Red" }
end

-- The ends that can be picked (selected) in the viewport: the joinable ends,
-- plus a roundabout's centre, which selects the roundabout itself
function RoadMath.pickableEndpointIds(segment: SegmentInfo): { EndpointId }
	local ids = table.clone(RoadMath.endpointIds(segment))
	if segment.Kind == "Roundabout" then
		table.insert(ids, "Centre")
	end
	return ids
end

function RoadMath.pickableEndpoints(segment: SegmentInfo): { Endpoint }
	local endpoints = {}
	for _, id in RoadMath.pickableEndpointIds(segment) do
		table.insert(endpoints, RoadMath.getEndpoint(segment, id))
	end
	return endpoints
end

function RoadMath.allEndpoints(segment: SegmentInfo): { Endpoint }
	local endpoints = {}
	for _, id in RoadMath.endpointIds(segment) do
		table.insert(endpoints, RoadMath.getEndpoint(segment, id))
	end
	return endpoints
end

-- Whether forward traffic leaves the segment through this end: a road's red
-- end, an intersection's Plus exits, or a Y split's branches
function RoadMath.isForwardEnd(id: EndpointId): boolean
	-- (A roundabout arm's "forward" lanes are its exit lanes)
	return id == "Red"
		or id == "ZPlus"
		or id == "XPlus"
		or id == "BranchLeft"
		or id == "BranchRight"
		or RoadMath.armIndex(id) ~= nil
end

-- Which road of its segment an end belongs to, as a lane attribute suffix
-- ("" for road segments, "X"/"Z" for an intersection's roads)
function RoadMath.laneSuffix(kind: SegmentKind, id: EndpointId): string
	if kind ~= "Intersection" then
		return ""
	end
	return if id == "XPlus" or id == "XMinus" then "X" else "Z"
end

-- The attributes holding the lanes leaving the segment through an end
-- ("out") and the lanes entering it there ("in"), for the whole road: on a
-- road segment these set both ends' lanes (unless it has a lane change)
function RoadMath.laneAttributeNames(kind: SegmentKind, id: EndpointId): (string, string)
	local forwardName, backwardName = RoadMath.laneCountNames(RoadMath.laneSuffix(kind, id))
	if RoadMath.isForwardEnd(id) then
		return forwardName, backwardName
	end
	return backwardName, forwardName
end

-- Like laneAttributeNames, but the attributes for just this end: the red-end
-- overrides at the red end of a straight with a lane change
function RoadMath.endLaneAttributeNames(segment: SegmentInfo, id: EndpointId): (string, string)
	if id == "Red" and RoadMath.hasLaneChange(segment) then
		-- Red is a forward end: out = forward, in = backward
		return RoadMath.RED_LANE_OVERRIDES[1], RoadMath.RED_LANE_OVERRIDES[2]
	end
	return RoadMath.laneAttributeNames(segment.Kind, id)
end

-- The lanes leaving (out) and entering (in) the segment through an end
function RoadMath.getLaneCounts(endpoint: Endpoint): (number, number)
	local forward, backward = readEndLaneCounts(endpoint.Segment.Kind, endpoint.Segment.Model, endpoint.Id)
	if RoadMath.isForwardEnd(endpoint.Id) then
		return forward, backward
	end
	return backward, forward
end

-- The road width at an endpoint (an intersection's X road can be a
-- different width than its Z road, and a lane-change straight's ends can
-- differ)
function RoadMath.endpointWidth(endpoint: Endpoint): number
	if endpoint.Id == "XPlus" or endpoint.Id == "XMinus" then
		return endpoint.Segment.WidthX or endpoint.Segment.Width
	elseif endpoint.Id == "Red" then
		return endpoint.Segment.WidthRed or endpoint.Segment.Width
	elseif endpoint.Id == "BranchLeft" or endpoint.Id == "BranchRight" then
		local layout = assert(endpoint.Segment.Split)
		return if endpoint.Id == "BranchLeft" then layout.LeftWidth else layout.RightWidth
	end
	local armIndex = RoadMath.armIndex(endpoint.Id)
	if armIndex and endpoint.Segment.Roundabout and endpoint.Segment.Roundabout.Arms[armIndex] then
		return endpoint.Segment.Roundabout.Arms[armIndex].EndWidth
	end
	return endpoint.Segment.Width
end

-- The width a road segment's bounding box is laid out around: the wider of
-- its two ends (they only differ on a lane-change straight)
function RoadMath.boxWidth(segment: SegmentInfo): number
	return math.max(segment.Width, segment.WidthRed or segment.Width)
end

--[[
	The sideways shift of an end's centre which, after one direction's lanes
	at that end change width by deltaWidth, keeps the kerb on the OTHER
	direction's side exactly where it was (so the untouched direction runs
	straight through a lane change). Looking out of an end, the lanes
	leaving through it keep to the driving side: the left for
	DriveSide = "Left".
]]
function RoadMath.laneChangeShift(endpoint: Endpoint, changedOut: boolean, deltaWidth: number): Vector3
	local frame = RoadMath.actualEndpointFrame(endpoint)
	local driveLeft = endpoint.Segment.Model:GetAttribute("DriveSide") ~= "Right"
	local outSide = if driveLeft then -frame.RightVector else frame.RightVector
	local changedSide = if changedOut then outSide else -outSide
	return changedSide * (deltaWidth / 2)
end

-- The effective world yaw (radians) of an end's Dir adjust. Junction
-- (intersection and Y split) exits have no adjust angles: any stray Adjust
-- attribute on a junction model must not rotate its exits.
local function effectiveDirAngle(endpoint: Endpoint): number
	if RoadMath.isJunction(endpoint.Segment.Kind) then
		return 0
	end
	local dirName = if endpoint.Id == "Blue" then "AdjustBlueDir" else "AdjustRedDir"
	local dirAngle = math.rad(getNumberAttribute(endpoint.Segment.Model, dirName, 0))
	return dirAngle * RoadMath.flipFactor(endpoint.Segment, "Dir")
end

-- The endpoint frame rotated to the end's *actual* face: the effective Dir
-- yaw applied about the frame's up axis, position unchanged. Used to align
-- handles and hover UX with the face rather than the bounding box.
function RoadMath.actualEndpointFrame(endpoint: Endpoint): CFrame
	local dirAngle = effectiveDirAngle(endpoint)
	local frame = endpoint.WorldCFrame
	if dirAngle == 0 then
		return frame
	end
	return CFrame.fromAxisAngle(frame.UpVector, dirAngle) * (frame - frame.Position) + frame.Position
end

-- The outward direction of the end's *actual* (Adjust-angle rotated) face, in
-- world space, horizontal component only. Used for placing new segments off an
-- open end so they align with the face rather than the nominal frame.
function RoadMath.actualOutwardDirection(endpoint: Endpoint): Vector3
	local dirAngle = effectiveDirAngle(endpoint)
	local nominalOutward = endpoint.WorldCFrame.LookVector
	local up = endpoint.WorldCFrame.UpVector
	return CFrame.fromAxisAngle(up, dirAngle):VectorToWorldSpace(nominalOutward)
end

--------------------------------------------------------------------------------
-- Joints
--------------------------------------------------------------------------------

-- Find the endpoint of another segment which is joined to this one (a "closed"
-- endpoint), or nil if the endpoint is open.
function RoadMath.findJoint(endpoint: Endpoint, segments: { SegmentInfo }): Endpoint?
	local position = endpoint.WorldCFrame.Position
	local outward = endpoint.WorldCFrame.LookVector
	local bestEndpoint: Endpoint? = nil
	local bestDistance = RoadMath.JOINT_TOLERANCE
	for _, segment in segments do
		if segment.Model == endpoint.Segment.Model then
			continue
		end
		for _, id in RoadMath.endpointIds(segment) do
			local other = RoadMath.getEndpoint(segment, id)
			local distance = (other.WorldCFrame.Position - position).Magnitude
			-- Faces must roughly oppose to count as a joint
			if distance <= bestDistance and other.WorldCFrame.LookVector:Dot(outward) < -0.5 then
				bestDistance = distance
				bestEndpoint = other
			end
		end
	end
	return bestEndpoint
end

--------------------------------------------------------------------------------
-- Moving endpoints
--------------------------------------------------------------------------------

-- Solve the new Size / Pivot / Flip for a segment when one of its endpoints is
-- moved to a new world position while its other endpoint stays fixed. The
-- segment's rotation is unchanged. Clamps keep the segment valid, so the moved
-- endpoint may not exactly reach the requested position.
function RoadMath.solveMove(segment: SegmentInfo, movedId: EndpointId, newWorldPosition: Vector3): MoveSolution
	local fixedId: EndpointId = if movedId == "Blue" then "Red" else "Blue"
	local fixedWorld = RoadMath.getEndpoint(segment, fixedId).WorldCFrame.Position
	local rotation = segment.Pivot.Rotation

	-- Delta from the blue endpoint to the red endpoint, in local space
	local delta = rotation:VectorToObjectSpace(newWorldPosition - fixedWorld)
	if movedId == "Blue" then
		delta = -delta
	end

	local swapEnds = false
	-- (A small tolerance keeps floating point noise on a flat road from
	-- needlessly swapping its ends)
	if segment.Kind == "Straight" and delta.Y < -1e-4 then
		-- Straight roads always climb blue -> red. To pull this end below the
		-- other one, rotate the segment 180 degrees about vertical so the ends
		-- swap roles: the S-bend has 180-degree rotational symmetry, so the
		-- worldly shape (and the sway and Flip values) are preserved, and the
		-- dragged geographic end becomes the (bottom) blue end.
		swapEnds = true
		rotation = rotation * CFrame.Angles(0, math.pi, 0)
		movedId, fixedId = fixedId, movedId
		-- blue->red delta in the rotated frame: X and Z negate twice (once
		-- from reversing the ends, once from the 180 rotation), Y negates once
		delta = Vector3.new(delta.X, -delta.Y, delta.Z)
	end

	-- A straight's box is laid out around its wider end
	local width = RoadMath.boxWidth(segment)
	local newSize: Vector3
	local newFlip: boolean
	if segment.Kind == "Straight" then
		-- Lateral offset becomes sway (and its side selects Flip)
		newFlip = delta.X < 0
		newSize = Vector3.new(
			width + math.abs(delta.X),
			math.max(delta.Y, 0),
			math.max(delta.Z, RoadMath.MIN_LENGTH)
		)
	else
		-- The corner's entry/exit are on perpendicular faces; each in-plane
		-- delta axis maps to one size axis. Flip selects which end is the top.
		newFlip = delta.Y < 0
		local w = width / 2
		newSize = Vector3.new(
			math.max(delta.X, width - w) + w,
			math.abs(delta.Y),
			math.max(delta.Z, width - w) + w
		)
	end

	-- Position the pivot so that the fixed endpoint stays where it was
	local newLocalFixed = RoadMath.localEndpointFrame(segment.Kind, newSize, width, newFlip, fixedId)
	local pivotPosition = fixedWorld - rotation:VectorToWorldSpace(newLocalFixed.Position)
	return {
		Size = newSize,
		Pivot = rotation + pivotPosition,
		Flip = newFlip,
		SwapEnds = swapEnds,
	}
end

-- The attribute updates accompanying a SwapEnds solution: the blue and red
-- adjust values trade places, following their geographic ends. Dir carries
-- over unchanged (yaw angles are frame independent for upright models);
-- grade and bank negate because the travel direction through each geographic
-- end reverses, preserving each face's actual world geometry.
function RoadMath.swappedAdjustValues(get: (name: string) -> number): { [string]: number }
	return {
		AdjustBlueDir = get("AdjustRedDir"),
		AdjustBlueGrade = -get("AdjustRedGrade"),
		AdjustBlueBank = -get("AdjustRedBank"),
		AdjustRedDir = get("AdjustBlueDir"),
		AdjustRedGrade = -get("AdjustBlueGrade"),
		AdjustRedBank = -get("AdjustBlueBank"),
	}
end

-- The lane count updates accompanying a SwapEnds solution: travel through the
-- segment reverses, so forward and backward trade places, and a lane change's
-- blue and red counts follow their geographic ends. (The lanes leaving and
-- entering through each geographic end stay the same.)
function RoadMath.swappedLaneValues(segment: SegmentInfo): { [string]: number }
	local blueForward, blueBackward = readEndLaneCounts(segment.Kind, segment.Model, "Blue")
	if RoadMath.hasLaneChange(segment) then
		local redForward, redBackward = readEndLaneCounts(segment.Kind, segment.Model, "Red")
		return {
			LaneCountForward = redBackward,
			LaneCountBackward = redForward,
			[RoadMath.RED_LANE_OVERRIDES[1]] = blueBackward,
			[RoadMath.RED_LANE_OVERRIDES[2]] = blueForward,
		}
	end
	return {
		LaneCountForward = blueBackward,
		LaneCountBackward = blueForward,
	}
end

--------------------------------------------------------------------------------
-- Adjust angle mapping
--------------------------------------------------------------------------------

export type AdjustAxis = "Dir" | "Grade" | "Bank"

function RoadMath.adjustAttributeName(id: EndpointId, axis: AdjustAxis): string
	return "Adjust" .. (if id == "Blue" then "Blue" else "Red") .. axis
end

function RoadMath.getAdjustValue(endpoint: Endpoint, axis: AdjustAxis): number
	return getNumberAttribute(endpoint.Segment.Model, RoadMath.adjustAttributeName(endpoint.Id, axis), 0)
end

--[[
	Sign mapping for rotating a joint. The rotation gesture is measured at the
	*selected* endpoint's frame:
	- Dir: right-handed angle about the up axis
	- Grade: right-handed angle about the lateral (right) axis, so positive
	  tips the selected end's outward direction upward
	- Bank: right-handed angle about the selected end's outward axis

	For each end attached to the joint, the attribute delta is sign * angle:
	- Dir: +1 for every end (attribute yaw convention matches CFrame yaw for
	  upright models, and all mated faces rotate together about up)
	- Grade/Bank: colorSign * facingSign, where colorSign is +1 for Red and
	  -1 for Blue (Red's travel direction is outward, Blue's is inward), and
	  facingSign is +1 when the end faces the same way as the selected end
	  (i.e. it IS the selected end) and -1 for the mated partner.
]]
--[[
	How a segment's Flip attribute changes the *world* meaning of each Adjust
	attribute (mirroring the corresponding generator math):
	- Curve grades are multiplied by the climb sign, which Flip negates.
	- Straight Flip mirrors the path horizontally, negating the effective yaw
	  of the Dir attributes.
	- Banks (and the remaining combinations) are unaffected.
]]
function RoadMath.flipFactor(segment: SegmentInfo, axis: AdjustAxis): number
	if not segment.Flip then
		return 1
	end
	if axis == "Grade" and segment.Kind == "Curve" then
		return -1
	end
	if axis == "Dir" and segment.Kind == "Straight" then
		return -1
	end
	return 1
end

function RoadMath.adjustDeltaSign(selected: Endpoint, target: Endpoint, axis: AdjustAxis): number
	local flipFactor = RoadMath.flipFactor(target.Segment, axis)
	if axis == "Dir" then
		return flipFactor
	end
	local colorSign = if target.Id == "Red" then 1 else -1
	local facing = target.WorldCFrame.LookVector:Dot(selected.WorldCFrame.LookVector)
	local facingSign = if facing >= 0 then 1 else -1
	return colorSign * facingSign * flipFactor
end

-- The frame new segments are placed against. Normally the endpoint's
-- nominal frame, but an intersection's angled X exits square their outward
-- direction to the intersection's own box axis: the new segment stays
-- box-aligned with the intersection, and its joining end's Dir adjust takes
-- up the skew instead (see matchingAdjust).
function RoadMath.placementFrame(endpoint: Endpoint): CFrame
	if endpoint.Segment.Kind == "Intersection" and (endpoint.Id == "XPlus" or endpoint.Id == "XMinus") then
		local s = if endpoint.Id == "XPlus" then 1 else -1
		local outward = endpoint.Segment.Pivot:VectorToWorldSpace(Vector3.new(s, 0, 0))
		return CFrame.lookAlong(endpoint.WorldCFrame.Position, outward)
	end
	return endpoint.WorldCFrame
end

-- The Adjust values a newly added segment's joining end must have to mate
-- flush with the given open end. The new model is placed aligned with the
-- open end's nominal frame (not its Dir-rotated face), so the joining end
-- needs the same effective world Dir yaw as the open end: rotating both
-- faces of a joint by the same world yaw keeps them flush. The world yaw of
-- any end is flipFactor("Dir") * attribute about +Y regardless of end color,
-- and the new segment is unflipped, so its attribute is the effective yaw
-- directly.
function RoadMath.matchingAdjust(openEnd: Endpoint, newEndId: EndpointId): { Dir: number, Grade: number, Bank: number }
	if RoadMath.isJunction(openEnd.Segment.Kind) then
		-- Flat exits: no grade/bank. Dir takes up the yaw between the
		-- box-aligned placement frame and the actual exit direction (the
		-- skew for an intersection's angled X exits, zero otherwise).
		local n = RoadMath.placementFrame(openEnd).LookVector
		local d = openEnd.WorldCFrame.LookVector
		local yaw = math.deg(math.atan2(n:Cross(d).Y, n:Dot(d)))
		return { Dir = math.round(yaw * 100) / 100, Grade = 0, Bank = 0 }
	end
	local openColorSign = if openEnd.Id == "Red" then 1 else -1
	local newColorSign = if newEndId == "Red" then 1 else -1
	local k = -openColorSign * newColorSign
	-- The new segment is created unflipped, but the open end's attribute
	-- values must be converted through its own flip factors to get their
	-- actual world meaning.
	return {
		Dir = RoadMath.flipFactor(openEnd.Segment, "Dir") * RoadMath.getAdjustValue(openEnd, "Dir"),
		Grade = k * RoadMath.flipFactor(openEnd.Segment, "Grade") * RoadMath.getAdjustValue(openEnd, "Grade"),
		Bank = k * RoadMath.getAdjustValue(openEnd, "Bank"),
	}
end

--------------------------------------------------------------------------------
-- New segment placement
--------------------------------------------------------------------------------

export type TurnDirection = "Left" | "Straight" | "Right" | "Intersection" | "Split" | "Roundabout"

-- Plan-view angle of a direction vector, matching the clockwise-positive
-- convention: angle(v) increases when v is rotated by CFrame.Angles(0, a, 0)
-- with positive a.
local function yawAngleOf(direction: Vector3): number
	return math.atan2(direction.X, direction.Z)
end

--[[
	Compute the placement for a new segment extending the given open end.
	Returns the segment kind, which end of the new segment joins the open end,
	the new segment's pivot CFrame, and its size.

	- Straight extends with a StraightRoad joined at its Blue end.
	- Right turns join a CurveRoad at its Blue (entry) end: entering the curve
	  and exiting +X is a right turn.
	- Left turns join a CurveRoad at its Red (exit) end, traversed backwards.
]]
function RoadMath.placeNewSegment(
	openEnd: Endpoint,
	turn: TurnDirection,
	width: number,
	sizeOverride: Vector3?
): (SegmentKind, EndpointId, CFrame, Vector3)
	local kind: SegmentKind = if turn == "Straight" then "Straight" else "Curve"
	local joinId: EndpointId = if turn == "Left" then "Red" else "Blue"

	local size = sizeOverride
	if not size then
		if kind == "Straight" then
			size = Vector3.new(width, 0, math.max(2 * width, RoadMath.MIN_LENGTH))
		else
			size = Vector3.new(2 * width, 0, 2 * width)
		end
	end
	assert(size)

	-- Yaw the new model so its joining end's nominal outward direction opposes
	-- the open end's PLACEMENT frame: the new model stays aligned the same way
	-- as the segment it extends (box-aligned for an intersection's angled
	-- exits), and any rotation of the actual face is matched by a Dir on the
	-- joining end instead (see matchingAdjust), keeping the joint flush.
	local placement = RoadMath.placementFrame(openEnd)
	local outward = placement.LookVector
	local joinLocal = RoadMath.localEndpointFrame(kind, size, width, false, joinId)
	local targetYaw = yawAngleOf(-outward)
	local nominalYaw = yawAngleOf(joinLocal.LookVector)
	local rotation = CFrame.Angles(0, targetYaw - nominalYaw, 0)

	local pivotPosition = placement.Position - rotation:VectorToWorldSpace(joinLocal.Position)
	return kind, joinId, rotation + pivotPosition, size
end

--------------------------------------------------------------------------------
-- Lane layout changes
--------------------------------------------------------------------------------

--[[
	Compensate the bounds (and pivot) for a road width change so that BOTH
	endpoint positions stay exactly where they are (keeping any joints sealed).

	Straight: endpoints sit at (±sway, ·, ±Z/2) with sway = (X - box)/2, where
	box is the wider end's width, so growing X by the box width delta keeps
	sway (and both endpoints) unchanged. newWidthRed gives a lane-change
	straight's new red end width (omit it when both ends match).

	Curve: blue sits at (-X/2 + w/2, ·, -Z/2) and red at (X/2, ·, Z/2 - w/2)
	in pivot space. Solving both fixed under a delta d gives X' = X + d/2,
	Z' = Z + d/2, with the pivot (box centre) shifted by (-d/4, 0, d/4).
]]
function RoadMath.solveWidthChange(
	segment: SegmentInfo,
	newWidth: number,
	newWidthRed: number?
): { Size: Vector3, Pivot: CFrame }
	local size = segment.Size
	if segment.Kind == "Straight" then
		local newBox = math.max(newWidth, newWidthRed or newWidth)
		local delta = newBox - RoadMath.boxWidth(segment)
		return {
			Size = Vector3.new(math.max(size.X + delta, newBox), size.Y, size.Z),
			Pivot = segment.Pivot,
		}
	else
		local delta = newWidth - segment.Width
		return {
			Size = Vector3.new(size.X + delta / 2, size.Y, size.Z + delta / 2),
			Pivot = segment.Pivot * CFrame.new(-delta / 4, 0, delta / 4),
		}
	end
end

return RoadMath
