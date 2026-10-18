local TestTypes = require("./TestTypes")

local RoadDefaults = require("./RoadDefaults")

--[[
	The generators can't share RoadDefaults (they are copied into place
	models), so check their defaultAttributes haven't drifted from it.
]]

return function(t: TestTypes.TestContext)
	t.test("road generators match the lane layout defaults", function()
		for _, generator in {
			require("./Templates/StraightRoadGenerator"),
			require("./Templates/CurveRoadGenerator"),
		} do
			local attributes = generator.Attributes
			t.expect(attributes.LaneWidth).toBe(RoadDefaults.LaneWidth)
			t.expect(attributes.LaneCountForward).toBe(RoadDefaults.LaneCountForward)
			t.expect(attributes.LaneCountBackward).toBe(RoadDefaults.LaneCountBackward)
			t.expect(attributes.SidewalkWidth).toBe(RoadDefaults.SidewalkWidth)
			t.expect(attributes.MaxAngle).toBe(RoadDefaults.MaxAngle)
		end
	end)

	t.test("roundabout generator matches the defaults", function()
		local RoadMath = require("./RoadMath")
		local attributes = require("./Templates/RoundaboutGenerator").Attributes
		t.expect(attributes.LaneWidth).toBe(RoadDefaults.LaneWidth)
		t.expect(attributes.SidewalkWidth).toBe(RoadDefaults.SidewalkWidth)
		t.expect(attributes.RingLanes).toBe(RoadDefaults.RoundaboutRingLanes)
		t.expect(attributes.ApronWidth).toBe(RoadDefaults.RoundaboutApronWidth)
		local island = RoadMath.parseIslandShape(attributes.IslandShape)
		t.expect(#island).toBe(1)
		t.expect(island[1].Radius).toBe(RoadDefaults.RoundaboutIslandRadius)
	end)

	t.test("split generator matches the defaults", function()
		local attributes = require("./Templates/RoadSplitGenerator").Attributes
		t.expect(attributes.LaneWidth).toBe(RoadDefaults.LaneWidth)
		t.expect(attributes.LaneCountForward).toBe(RoadDefaults.LaneCountForward)
		t.expect(attributes.LaneCountBackward).toBe(RoadDefaults.LaneCountBackward)
		t.expect(attributes.SidewalkWidth).toBe(RoadDefaults.SidewalkWidth)
		t.expect(attributes.SplitSeparation).toBe(RoadDefaults.SplitSeparation)
	end)

	t.test("intersection generator matches the defaults", function()
		local attributes = require("./Templates/RoadIntersectionGenerator").Attributes
		for _, axis in { "X", "Z" } do
			t.expect(attributes["LaneWidth" .. axis]).toBe(RoadDefaults.LaneWidth)
			t.expect(attributes["LaneCountForward" .. axis]).toBe(RoadDefaults.LaneCountForward)
			t.expect(attributes["LaneCountBackward" .. axis]).toBe(RoadDefaults.LaneCountBackward)
		end
		t.expect(attributes.SidewalkWidth).toBe(RoadDefaults.SidewalkWidth)
		t.expect(attributes.MaxAngle).toBe(RoadDefaults.MaxAngle)
		t.expect(attributes.IntersectionAngle).toBe(RoadDefaults.IntersectionAngle)
		t.expect(attributes.MiniRoundaboutDiameter).toBe(RoadDefaults.MiniRoundaboutDiameter)
	end)
end
