local CollectionService = game:GetService("CollectionService")

local TestTypes = require("./TestTypes")

local Finalise = require("./Finalise")
local RoadMath = require("./RoadMath")

--[[
	Finalising a road built from the packaged generator: the result is a plain
	model with no generator or helper cubes, tagged and backed up, and
	unfinalising brings the ProceduralModel back where the model now is.
]]

local function buildStraight(): Model
	local model = Instance.new("ProceduralModel" :: any) :: any
	local generator = script.Parent.Templates.StraightRoadGenerator:Clone()
	generator.Parent = model
	model.Generator = generator
	model:SetAttribute("AdjustShowSnappingHelper", true)
	model.Size = Vector3.new(112, 0, 240)
	model:PivotTo(CFrame.new(0, 500, 0))
	model.Name = "FinaliseTestRoad"
	model.Parent = workspace
	return model
end

local function countParts(model: Instance): number
	local count = 0
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

-- Wait for the road to generate
local function waitForParts(model: Instance): boolean
	local deadline = os.clock() + 10
	while os.clock() < deadline do
		if countParts(model) > 0 then
			task.wait(0.5)
			return true
		end
		task.wait(0.1)
	end
	return false
end

return function(t: TestTypes.TestContext)
	t.test("finalise and unfinalise a road", function()
		local road = buildStraight()
		local ok, err = pcall(function()
			if not waitForParts(road) then
				t.fail("the road never generated")
				return
			end
			local before = countParts(road)
			local options = table.clone(Finalise.DEFAULT_OPTIONS)
			local report = Finalise.finalise({ road }, options, function() end)
			t.expect(report.Roads).toBe(1)
			t.expect(report.Failed).toBe(0)

			local finalised = Finalise.findFinalised()
			local mine
			for _, model in finalised do
				if model.Name == "FinaliseTestRoad" then
					mine = model
				end
			end
			if not mine then
				t.fail("no finalised model was found")
				return
			end
			t.expect(mine.ClassName).toBe("Model")
			t.expect(RoadMath.getSegmentInfo(mine)).toBe(nil)
			t.expect(mine:FindFirstChildWhichIsA("ModuleScript", true)).toBe(nil)
			t.expect(CollectionService:HasTag(mine, Finalise.TAG)).toBe(true)
			t.expect(countParts(mine) <= before).toBe(true)
			for _, descendant in mine:GetDescendants() do
				if descendant.Name == "SnappingHelper" then
					t.fail("a snapping helper was left in")
				end
			end

			-- Moved since: the restored road goes where the model is
			mine:PivotTo(mine:GetPivot() + Vector3.new(0, 0, 300))
			local expected = mine:GetPivot().Position
			local restored, missing = Finalise.unfinalise({ mine })
			t.expect(restored).toBe(1)
			t.expect(missing).toBe(0)
			local back = workspace:FindFirstChild("FinaliseTestRoad")
			t.expect(back ~= nil and RoadMath.getSegmentInfo(back) ~= nil).toBe(true)
			if back then
				t.expect((back:GetPivot().Position - expected).Magnitude < 0.01).toBe(true)
			end
		end)
		for _, model in workspace:GetChildren() do
			if model.Name == "FinaliseTestRoad" then
				model:Destroy()
			end
		end
		Finalise.deleteBackups()
		if not ok then
			error(err, 0)
		end
	end)
end
