local TestTypes = require("./TestTypes")

local RoadMath = require("./RoadMath")

--[[
	Roundabouts built from the packaged generator: a round one, and a rounded
	rectangle with a truck apron. Checks that they generate (island, ring
	markings, apron) and takes a screenshot so the shapes can be judged by
	eye.
]]

local ISLAND_COLOR = Color3.fromRGB(76, 112, 44)
local APRON_COLOR = Color3.fromRGB(120, 116, 110)

local function buildRoundabout(attributes: { [string]: any }, pivot: CFrame): Model
	local model = Instance.new("ProceduralModel" :: any) :: any
	local generator = script.Parent.Templates.RoundaboutGenerator:Clone()
	generator.Parent = model
	model.Generator = generator
	for name, value in attributes do
		model:SetAttribute(name, value)
	end
	model.Size = RoadMath.roundaboutSize(RoadMath.roundaboutLayout(model))
	model:PivotTo(pivot)
	model.Parent = workspace
	return model
end

-- Whether the model generates a part matching a predicate
local function generates(model: Model, predicate: (BasePart) -> boolean): boolean
	local deadline = os.clock() + 10
	while os.clock() < deadline do
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and predicate(descendant) then
				return true
			end
		end
		task.wait(0.1)
	end
	return false
end

return function(t: TestTypes.TestContext)
	local origin = Vector3.new(0, 500, -900)

	t.test("round and rectangular roundabouts generate", function()
		local base = {
			LaneWidth = 24,
			SidewalkWidth = 8,
			RingLanes = 2,
			TextureLaneMarkings = true,
			IslandColor = ISLAND_COLOR,
			ApronColor = APRON_COLOR,
		}
		local round = table.clone(base)
		round.IslandShape = "0,0,60"
		local rectangle = table.clone(base)
		rectangle.IslandShape = "-90,-40,20;90,-40,20;90,40,20;-90,40,20"
		rectangle.ApronWidth = 12
		local models = {
			buildRoundabout(round, CFrame.new(origin + Vector3.new(-200, 0, 0))),
			buildRoundabout(rectangle, CFrame.new(origin + Vector3.new(220, 0, 0))),
		}

		local camera = workspace.CurrentCamera
		local previousCFrame = camera.CFrame
		camera.CFrame = CFrame.lookAt(origin + Vector3.new(0, 700, -1), origin)

		local ok, err = pcall(function()
			for _, model in models do
				if not generates(model, function(part)
					return part.Color == ISLAND_COLOR
				end) then
					t.fail("A roundabout generated no island")
				end
				if not generates(model, function(part)
					return part.Name == "RoadMarking"
				end) then
					t.fail("A roundabout generated no ring markings")
				end
			end
			if not generates(models[2], function(part)
				return part.Color == APRON_COLOR
			end) then
				t.fail("The roundabout with an apron generated none")
			end
			t.screenshot("roundabouts")
		end)
		camera.CFrame = previousCFrame
		for _, model in models do
			model:Destroy()
		end
		if not ok then
			error(err, 0)
		end
	end)
end
