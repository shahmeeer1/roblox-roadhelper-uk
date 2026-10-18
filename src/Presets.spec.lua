local TestTypes = require("./TestTypes")

local Presets = require("./Presets")

return function(t: TestTypes.TestContext)
	t.test("keys are unique and the default exists", function()
		local seen = {}
		for _, preset in Presets.List do
			if seen[preset.Key] then
				t.fail(`Duplicate preset key {preset.Key}`)
			end
			seen[preset.Key] = true
		end
		t.expect(Presets.ByKey[Presets.DefaultKey] ~= nil).toBe(true)
	end)

	t.test("every preset sets a valid lane layout", function()
		-- The Add buttons compute the new segment's width from these
		for _, preset in Presets.List do
			local attrs = preset.Attributes
			for _, name in { "LaneCountForward", "LaneCountBackward", "LaneWidth", "SidewalkWidth" } do
				if typeof(attrs[name]) ~= "number" then
					t.fail(`{preset.Key} is missing a numeric {name}`)
				end
			end
			if attrs.LaneCountForward < 0 or attrs.LaneCountBackward < 0
				or attrs.LaneCountForward + attrs.LaneCountBackward < 1
				or attrs.LaneWidth <= 0 or attrs.SidewalkWidth < 0
			then
				t.fail(`{preset.Key} has an invalid lane layout`)
			end
		end
	end)

	t.test("UK presets drive on the left", function()
		for _, preset in Presets.List do
			if preset.Key:sub(1, 2) == "UK" then
				t.expect(preset.Attributes.DriveSide).toBe("Left")
			end
		end
	end)
end
