local TestTypes = require("./TestTypes")

--[[
	Mini roundabouts built from the packaged intersection generator: checks
	the central island was generated (a flush white disc, or a dome on a
	white ring when raised) and takes a screenshot so the give way lines and
	circulation arrows can be judged by eye.
]]

local function buildIntersection(attributes: { [string]: any }, pivot: CFrame): Model
	local model = Instance.new("ProceduralModel" :: any) :: any
	local generator = script.Parent.Templates.RoadIntersectionGenerator:Clone()
	generator.Parent = model
	model.Generator = generator
	for name, value in attributes do
		model:SetAttribute(name, value)
	end
	model.Size = Vector3.new(144, 0, 144)
	model:PivotTo(pivot)
	model.Parent = workspace
	return model
end

-- The first descendant matching a predicate, once the model has generated
local function waitFor(model: Model, predicate: (Instance) -> boolean): Instance?
	local deadline = os.clock() + 10
	while os.clock() < deadline do
		for _, descendant in model:GetDescendants() do
			if predicate(descendant) then
				return descendant
			end
		end
		task.wait(0.1)
	end
	return nil
end

local function isIslandDisc(instance: Instance): boolean
	return instance:IsA("Part") and instance.Shape == Enum.PartType.Cylinder
end

local function isDome(instance: Instance): boolean
	return instance:IsA("BasePart") and instance.Name == "MiniRoundaboutDome"
end

return function(t: TestTypes.TestContext)
	local origin = Vector3.new(0, 500, -400)

	t.test("flat and raised mini roundabouts generate their islands", function()
		local base = {
			LaneWidthX = 24,
			LaneWidthZ = 24,
			SidewalkWidth = 8,
			DriveSide = "Left",
			TextureLaneMarkings = true,
			MiniRoundabout = true,
		}
		local function case(name: string, offset: number, attributes: { [string]: any }): Model
			local merged = table.clone(base)
			for key, value in attributes do
				merged[key] = value
			end
			local model = buildIntersection(merged, CFrame.new(origin + Vector3.new(offset, 0, 0)))
			model.Name = name
			return model
		end
		local flat = case("FlatMini", -100, {})
		local raised = case("RaisedMini", 100, { MiniRoundaboutRaised = true, ThroughRoad = false })
		local models = { flat, raised }

		local camera = workspace.CurrentCamera
		local previousCFrame = camera.CFrame
		camera.CFrame = CFrame.lookAt(origin + Vector3.new(0, 320, -1), origin)

		local ok, err = pcall(function()
			if not waitFor(flat, isIslandDisc) then
				t.fail("The flat mini roundabout has no island disc")
			end
			if waitFor(flat, isDome) then
				t.fail("The flat mini roundabout has a dome")
			end
			if not waitFor(raised, isDome) then
				t.fail("The raised mini roundabout has no dome")
			end
			if not waitFor(raised, isIslandDisc) then
				t.fail("The raised mini roundabout has no white ring")
			end
			t.screenshot("mini roundabouts")
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
