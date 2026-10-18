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
			t.expect(attributes.LaneCount).toBe(RoadDefaults.LaneCount)
			t.expect(attributes.SidewalkWidth).toBe(RoadDefaults.SidewalkWidth)
			t.expect(attributes.MaxAngle).toBe(RoadDefaults.MaxAngle)
		end
	end)

	t.test("intersection generator matches the defaults", function()
		local attributes = require("./Templates/RoadIntersectionGenerator").Attributes
		for _, axis in { "X", "Z" } do
			t.expect(attributes["LaneWidth" .. axis]).toBe(RoadDefaults.LaneWidth)
			t.expect(attributes["LaneCount" .. axis]).toBe(RoadDefaults.LaneCount)
		end
		t.expect(attributes.SidewalkWidth).toBe(RoadDefaults.SidewalkWidth)
		t.expect(attributes.MaxAngle).toBe(RoadDefaults.MaxAngle)
		t.expect(attributes.IntersectionAngle).toBe(RoadDefaults.IntersectionAngle)
	end)
end
