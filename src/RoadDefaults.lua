--!strict
--[[
	RoadDefaults: the plugin-side defaults for segment attributes, used
	whenever a segment doesn't have the attribute set.

	These must match the generators' own defaultAttributes (Templates/*).
	The generators can't require this module because they are copied into
	place models, so RoadDefaults.spec checks the two stay in sync.
]]

local RoadDefaults = {
	LaneWidth = 24,
	-- Lanes per travel direction (see RoadMath's Lanes section)
	LaneCountForward = 1,
	LaneCountBackward = 1,
	SidewalkWidth = 8,
	MaxAngle = 10,
	IntersectionAngle = 90,
	-- The range the intersection generator clamps IntersectionAngle to
	MinIntersectionAngle = 25,
	MaxIntersectionAngle = 155,
	-- Corner curve radius given to new intersections (path-like roads get
	-- half a lane instead)
	CornerRadius = 16,
	-- Y splits: the gap between the two branch roads at the far end (about a
	-- 2.4 m central reserve at 24 studs per 3.65 m lane), and the length of a
	-- new split (about 36 m)
	SplitSeparation = 16,
	SplitLength = 240,
	-- Mini roundabout central islands: UK islands are 1 to 4 m across
	MiniRoundaboutDiameter = 20,
	MiniRoundaboutMinDiameter = 7,
	MiniRoundaboutMaxDiameter = 26,
}

-- Total road width with the default lane layout
RoadDefaults.Width = (RoadDefaults.LaneCountForward + RoadDefaults.LaneCountBackward) * RoadDefaults.LaneWidth
	+ 2 * RoadDefaults.SidewalkWidth

return RoadDefaults
