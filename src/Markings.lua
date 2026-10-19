--!strict
--[[
	Markings: road markings drawn by hand with the Draw Markings tool.

	Each drawn line is a Model tagged RoadHelperMarking which holds its own
	strip parts, built from its attributes:
	- Points: "x,y,z;..." the points it passes through, on the road surface,
	  in the space of the road it was drawn on (its parent's pivot), or in
	  world space when it isn't on a road
	- Style: "Dashed", "Solid", "GiveWay" or "Double"
	- Colour: "White" (the road's LaneMarkingColor) or "Yellow" (its
	  CenterlineColor)
	- Curved: a smooth curve through the points, or straight between them
	- Width, Dash, Gap: the line's width, and its marks' and gaps' lengths
	  for the broken styles

	They're not part of any road's generated geometry: a line drawn on a road
	is parented to it so it moves with it, but resizing or reshaping the road
	leaves it where it is, to be adjusted by hand. Their parts don't collide
	and are invisible to raycasts and spatial queries, so they're never
	mistaken for road (or picked when drawing on top of them).
]]

local CollectionService = game:GetService("CollectionService")

local Markings = {}

Markings.TAG = "RoadHelperMarking"

export type Style = "Dashed" | "Solid" | "GiveWay" | "Double"
export type Colour = "White" | "Yellow"

export type Options = {
	Style: Style,
	Colour: Colour,
	Curved: boolean,
	Width: number,
	Dash: number,
	Gap: number,
}

-- Each style's width, mark and gap lengths (studs; 24 studs = a 3.65 m lane):
-- lane lines 3 m marks with 6 m gaps, give way lines 600 mm by 300 mm, as
-- generated
local STYLE_DEFAULTS: { [string]: { Width: number, Dash: number, Gap: number } } = {
	Dashed = { Width = 0.8, Dash = 20, Gap = 40 },
	Solid = { Width = 0.8, Dash = 0, Gap = 0 },
	GiveWay = { Width = 2, Dash = 4, Gap = 2 },
	Double = { Width = 0.8, Dash = 0, Gap = 0 },
}
Markings.STYLE_DEFAULTS = STYLE_DEFAULTS
Markings.STYLES = { "Dashed", "Solid", "GiveWay", "Double" } :: { Style }

-- How far apart a double line's two lines are (centre to centre), as
-- generated
local DOUBLE_SPACING = 2
-- Strips sit just above the surface they were drawn on (and above generated
-- markings there)
local LIFT = 0.06
local THICKNESS = 0.04
-- Curves are sampled about this often
local SAMPLE_SPACING = 3
local MAX_SPAN_SAMPLES = 48

local WHITE = Color3.fromRGB(235, 235, 230)
local YELLOW = Color3.fromRGB(244, 205, 47)

--------------------------------------------------------------------------------
-- Data
--------------------------------------------------------------------------------

function Markings.isLine(instance: Instance?): boolean
	return instance ~= nil and instance:IsA("Model") and CollectionService:HasTag(instance, Markings.TAG)
end

-- Every drawn line in the place
function Markings.allLines(): { Model }
	local lines = {}
	for _, instance in CollectionService:GetTagged(Markings.TAG) do
		if instance:IsA("Model") and instance:IsDescendantOf(workspace) then
			table.insert(lines, instance)
		end
	end
	return lines
end

function Markings.parsePoints(value: any): { Vector3 }
	local points = {}
	if typeof(value) == "string" then
		for _, entry in string.split(value, ";") do
			local parts = string.split(entry, ",")
			local x, y, z = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
			if x and y and z then
				table.insert(points, Vector3.new(x, y, z))
			end
		end
	end
	return points
end

function Markings.serializePoints(points: { Vector3 }): string
	local entries = {}
	local function tidy(value: number): string
		return tostring(math.round(value * 1000) / 1000)
	end
	for _, point in points do
		table.insert(entries, `{tidy(point.X)},{tidy(point.Y)},{tidy(point.Z)}`)
	end
	return table.concat(entries, ";")
end

-- The space a line's points are stored in: its road's pivot, so it moves
-- with the road, or the world when it isn't on one
local function isRoad(instance: Instance?): boolean
	return instance ~= nil and instance.ClassName == "ProceduralModel"
end

local function frameOf(line: Instance): CFrame
	local parent = line.Parent
	if parent and isRoad(parent) then
		return (parent :: Model):GetPivot()
	end
	return CFrame.identity
end

function Markings.getOptions(line: Instance): Options
	local style = line:GetAttribute("Style")
	if typeof(style) ~= "string" or not STYLE_DEFAULTS[style] then
		style = "Dashed"
	end
	local defaults = STYLE_DEFAULTS[style]
	local function number(name: string, default: number): number
		local value = line:GetAttribute(name)
		return if typeof(value) == "number" then value else default
	end
	return {
		Style = style :: Style,
		Colour = if line:GetAttribute("Colour") == "Yellow" then "Yellow" else "White",
		Curved = line:GetAttribute("Curved") ~= false,
		Width = math.max(number("Width", defaults.Width), 0.05),
		Dash = math.max(number("Dash", defaults.Dash), 0),
		Gap = math.max(number("Gap", defaults.Gap), 0),
	}
end

function Markings.getWorldPoints(line: Instance): { Vector3 }
	local frame = frameOf(line)
	local points = {}
	for _, point in Markings.parsePoints(line:GetAttribute("Points")) do
		table.insert(points, frame:PointToWorldSpace(point))
	end
	return points
end

--------------------------------------------------------------------------------
-- Geometry
--------------------------------------------------------------------------------

-- A point on the centripetal Catmull-Rom span from p1 to p2, part way u
-- along it
local function catmullRom(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, u: number): Vector3
	local function knot(t: number, a: Vector3, b: Vector3): number
		return t + math.sqrt(math.max((b - a).Magnitude, 1e-4))
	end
	local t0 = 0
	local t1 = knot(t0, p0, p1)
	local t2 = knot(t1, p1, p2)
	local t3 = knot(t2, p2, p3)
	local t = t1 + (t2 - t1) * u
	local a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
	local a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
	local a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
	local b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
	local b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
	return b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1))
end

-- The path a line takes through its points: a smooth curve through them
-- (when curved), or straight between them, as a polyline
function Markings.samplePath(points: { Vector3 }, curved: boolean): { Vector3 }
	if #points < 2 then
		return table.clone(points)
	end
	if not curved or #points == 2 then
		return table.clone(points)
	end
	local path = { points[1] }
	for i = 1, #points - 1 do
		local p1, p2 = points[i], points[i + 1]
		-- (The ends continue straight on)
		local p0 = points[i - 1] or (p1 * 2 - p2)
		local p3 = points[i + 2] or (p2 * 2 - p1)
		local steps = math.clamp(math.ceil((p2 - p1).Magnitude / SAMPLE_SPACING), 1, MAX_SPAN_SAMPLES)
		for k = 1, steps do
			table.insert(path, if k == steps then p2 else catmullRom(p0, p1, p2, p3, k / steps))
		end
	end
	return path
end

-- Where a span's samples start in a sampled path (the index of points[i]),
-- so the span from point i to point i + 1 runs from there to the next
function Markings.spanStarts(points: { Vector3 }, curved: boolean): { number }
	local starts = { 1 }
	local index = 1
	for i = 1, #points - 1 do
		local steps = if curved and #points > 2
			then math.clamp(math.ceil((points[i + 1] - points[i]).Magnitude / SAMPLE_SPACING), 1, MAX_SPAN_SAMPLES)
			else 1
		index += steps
		table.insert(starts, index)
	end
	return starts
end

-- The path offset sideways (to the left, looking along it, in plan)
local function offsetPath(path: { Vector3 }, offset: number): { Vector3 }
	local result = {}
	for i, point in path do
		local before = path[math.max(i - 1, 1)]
		local after = path[math.min(i + 1, #path)]
		local direction = Vector3.new(after.X - before.X, 0, after.Z - before.Z)
		if direction.Magnitude < 1e-6 then
			table.insert(result, point)
			continue
		end
		direction = direction.Unit
		local left = Vector3.new(direction.Z, 0, -direction.X)
		table.insert(result, point + left * offset)
	end
	return result
end

local function colourOf(line: Instance, colour: Colour): Color3
	local road = line.Parent
	local value = if road and isRoad(road)
		then road:GetAttribute(if colour == "Yellow" then "CenterlineColor" else "LaneMarkingColor")
		else nil
	if typeof(value) == "Color3" then
		return value
	end
	return if colour == "Yellow" then YELLOW else WHITE
end

local function makeStrip(parent: Instance, a: Vector3, b: Vector3, width: number, color: Color3)
	local length = (b - a).Magnitude
	if length < 0.02 then
		return
	end
	local part = Instance.new("Part")
	part.Name = "MarkingStrip"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Material = Enum.Material.Sand
	part.Color = color
	-- (A hair longer, so strips meeting at an angle leave no gap)
	part.Size = Vector3.new(length + 0.05, THICKNESS, width)
	-- Its X axis runs along it
	part.CFrame = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, -math.pi / 2, 0)
	part.Parent = parent
end

-- Strips along a path, solid or broken into marks
local function stripsAlong(parent: Instance, path: { Vector3 }, width: number, color: Color3, dash: number, gap: number)
	local lift = Vector3.yAxis * LIFT
	if dash <= 0 or gap <= 0 then
		for i = 1, #path - 1 do
			makeStrip(parent, path[i] + lift, path[i + 1] + lift, width, color)
		end
		return
	end
	-- Walk along the path, marking the first `dash` of every dash + gap
	local period = dash + gap
	local travelled = 0
	for i = 1, #path - 1 do
		local a, b = path[i], path[i + 1]
		local length = (b - a).Magnitude
		local from = 0
		while from < length - 1e-6 do
			local phase = (travelled + from) % period
			local marking = phase < dash
			local to = math.min(length, from + (if marking then dash - phase else period - phase))
			if marking then
				makeStrip(parent, a:Lerp(b, from / length) + lift, a:Lerp(b, to / length) + lift, width, color)
			end
			from = to
		end
		travelled += length
	end
end

-- Rebuild a line's strips from its attributes
function Markings.build(line: Model)
	for _, child in line:GetChildren() do
		if child:IsA("BasePart") then
			child:Destroy()
		end
	end
	local options = Markings.getOptions(line)
	local path = Markings.samplePath(Markings.getWorldPoints(line), options.Curved)
	if #path < 2 then
		return
	end
	local color = colourOf(line, options.Colour)
	if options.Style == "Double" then
		for _, side in { 1, -1 } do
			stripsAlong(line, offsetPath(path, side * DOUBLE_SPACING / 2), options.Width, color, 0, 0)
		end
	else
		stripsAlong(line, path, options.Width, color, options.Dash, options.Gap)
	end
end

-- Store a line's points (given in world space) and rebuild it
function Markings.setWorldPoints(line: Model, points: { Vector3 })
	local frame = frameOf(line)
	local localPoints = {}
	for _, point in points do
		table.insert(localPoints, frame:PointToObjectSpace(point))
	end
	line:SetAttribute("Points", Markings.serializePoints(localPoints))
	Markings.build(line)
end

-- A new line through world points, on `parent` (a road, or anything else)
function Markings.create(parent: Instance, points: { Vector3 }, options: Options): Model
	local line = Instance.new("Model")
	line.Name = "Marking"
	line:SetAttribute("Style", options.Style)
	line:SetAttribute("Colour", options.Colour)
	line:SetAttribute("Curved", options.Curved)
	line:SetAttribute("Width", options.Width)
	line:SetAttribute("Dash", options.Dash)
	line:SetAttribute("Gap", options.Gap)
	CollectionService:AddTag(line, Markings.TAG)
	line.Parent = parent
	Markings.setWorldPoints(line, points)
	return line
end

-- Remove any drawn lines from a copy of a road (a new road cloned from
-- another shouldn't bring its markings along)
function Markings.strip(root: Instance)
	for _, descendant in root:GetDescendants() do
		if Markings.isLine(descendant) then
			descendant:Destroy()
		end
	end
end

--------------------------------------------------------------------------------
-- Snapping
--------------------------------------------------------------------------------

-- The ends of a generated marking strip (generated markings are named
-- "RoadMarking", with their X axis along them)
local function stripEnds(part: BasePart): (Vector3, Vector3)
	local half = part.CFrame.RightVector * (math.max(part.Size.X - 0.05, 0) / 2)
	return part.Position - half, part.Position + half
end

local function nearestOnSegment(a: Vector3, b: Vector3, p: Vector3): Vector3
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	if lengthSq < 1e-9 then
		return a
	end
	return a + ab * math.clamp((p - a):Dot(ab) / lengthSq, 0, 1)
end

export type SnapKind = "End" | "Line"

-- Where to snap a point near `position` within `radius`: the nearest end of
-- a generated marking strip or point of a drawn line ("End"), or failing
-- that the nearest point along a generated marking ("Line"). `ignore` is a
-- drawn line to leave out (the one being edited).
function Markings.snap(position: Vector3, radius: number, ignore: Model?): (Vector3?, SnapKind?)
	local bestEnd: Vector3?, bestEndDistance = nil, radius
	local bestLine: Vector3?, bestLineDistance = nil, radius * 0.6
	local function considerEnd(point: Vector3)
		local distance = (point - position).Magnitude
		if distance < bestEndDistance then
			bestEnd, bestEndDistance = point, distance
		end
	end
	for _, part in workspace:GetPartBoundsInRadius(position, radius) do
		if part.Name == "RoadMarking" and part:IsA("Part") then
			local a, b = stripEnds(part)
			considerEnd(a)
			considerEnd(b)
			local onLine = nearestOnSegment(a, b, position)
			local distance = (onLine - position).Magnitude
			if distance < bestLineDistance then
				bestLine, bestLineDistance = onLine, distance
			end
		end
	end
	for _, line in Markings.allLines() do
		if line ~= ignore then
			for _, point in Markings.getWorldPoints(line) do
				considerEnd(point)
			end
		end
	end
	if bestEnd then
		return bestEnd, "End"
	elseif bestLine then
		return bestLine, "Line"
	end
	return nil, nil
end

-- How far a point is from a drawn line's path (in plan), for picking lines
function Markings.distanceTo(line: Model, position: Vector3): number
	local path = Markings.samplePath(Markings.getWorldPoints(line), Markings.getOptions(line).Curved)
	local flat = Vector3.new(position.X, 0, position.Z)
	local best = math.huge
	for i = 1, #path - 1 do
		local a = Vector3.new(path[i].X, 0, path[i].Z)
		local b = Vector3.new(path[i + 1].X, 0, path[i + 1].Z)
		best = math.min(best, (nearestOnSegment(a, b, flat) - flat).Magnitude)
	end
	return best
end

--------------------------------------------------------------------------------
-- Lane zones
--------------------------------------------------------------------------------

-- A path resampled into `count` points at equal distances along it, ends
-- included
function Markings.resamplePath(path: { Vector3 }, count: number): { Vector3 }
	if #path < 2 or count < 2 then
		return table.clone(path)
	end
	local cumulative = { 0 }
	for i = 2, #path do
		cumulative[i] = cumulative[i - 1] + (path[i] - path[i - 1]).Magnitude
	end
	local total = cumulative[#path]
	if total < 1e-6 then
		return table.clone(path)
	end
	local result = {}
	local segment = 1
	for k = 0, count - 1 do
		local distance = total * k / (count - 1)
		while segment < #path - 1 and cumulative[segment + 1] < distance do
			segment += 1
		end
		local span = cumulative[segment + 1] - cumulative[segment]
		local t = if span > 1e-9 then (distance - cumulative[segment]) / span else 0
		table.insert(result, path[segment]:Lerp(path[segment + 1], math.clamp(t, 0, 1)))
	end
	return result
end

local function distanceToChord(p: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local lengthSq = ab:Dot(ab)
	if lengthSq < 1e-12 then
		return (p - a).Magnitude
	end
	local t = math.clamp((p - a):Dot(ab) / lengthSq, 0, 1)
	return (p - (a + ab * t)).Magnitude
end

-- A path reduced to the fewest points that keep it within `tolerance` of the
-- original (Ramer-Douglas-Peucker), ends included
function Markings.simplifyPath(path: { Vector3 }, tolerance: number): { Vector3 }
	if #path <= 2 then
		return table.clone(path)
	end
	local keep = { [1] = true, [#path] = true }
	local stack = { { 1, #path } }
	while #stack > 0 do
		local range = table.remove(stack) :: { number }
		local first, last = range[1], range[2]
		local worst, worstIndex = 0, nil
		for i = first + 1, last - 1 do
			local distance = distanceToChord(path[i], path[first], path[last])
			if distance > worst then
				worst, worstIndex = distance, i
			end
		end
		if worstIndex and worst > tolerance then
			keep[worstIndex] = true
			table.insert(stack, { first, worstIndex })
			table.insert(stack, { worstIndex, last })
		end
	end
	local result = {}
	for i, point in path do
		if keep[i] then
			table.insert(result, point)
		end
	end
	return result
end

-- How closely simplified lane lines follow the full path (studs; the lines
-- are drawn as smooth curves through their points, which then follow it much
-- more closely than the chords between them do), and about how far apart the
-- lines are sampled between the two sides
local ZONE_TOLERANCE = 0.6
local ZONE_SPACING = 4

export type ZoneLine = {
	Points: { Vector3 },
	-- One of the two sides themselves rather than a line dividing them
	Edge: boolean,
}

-- The lines dividing the space between two sides (each a list of points
-- along one edge of a stretch of road) into `lanes` equal lanes: lane line k
-- of `lanes` runs between the two sides at k / lanes of the way across,
-- matching the sides up by how far along each they are. Each is reduced to
-- a few points so it stays easy to bend by hand. With `includeEdges` the two
-- sides themselves come too, through exactly the points given.
function Markings.laneZoneLines(
	sideA: { Vector3 },
	sideB: { Vector3 },
	lanes: number,
	includeEdges: boolean,
	curved: boolean
): { ZoneLine }
	local lines: { ZoneLine } = {}
	if #sideA < 2 or #sideB < 2 then
		return lines
	end
	local pathA = Markings.samplePath(sideA, curved)
	local pathB = Markings.samplePath(sideB, curved)
	local function length(path: { Vector3 }): number
		local total = 0
		for i = 2, #path do
			total += (path[i] - path[i - 1]).Magnitude
		end
		return total
	end
	local count = math.max(8, math.ceil(math.max(length(pathA), length(pathB)) / ZONE_SPACING))
	local a = Markings.resamplePath(pathA, count)
	local b = Markings.resamplePath(pathB, count)
	for k = 1, lanes - 1 do
		local across = k / lanes
		local line = {}
		for i = 1, count do
			table.insert(line, a[i]:Lerp(b[i], across))
		end
		table.insert(lines, { Points = Markings.simplifyPath(line, ZONE_TOLERANCE), Edge = false })
	end
	if includeEdges then
		table.insert(lines, { Points = table.clone(sideA), Edge = true })
		table.insert(lines, { Points = table.clone(sideB), Edge = true })
	end
	return lines
end

return Markings
