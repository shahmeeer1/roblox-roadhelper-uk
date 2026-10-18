local TestTypes = require("./TestTypes")

local RoadMath = require("./RoadMath")

--[[
	Y splits built from the packaged generator. Its snapping helper cubes mark
	each end's two corners (stem blue, left branch red, right branch orange),
	showing where the generator put each end and how wide it made it: that
	must agree with RoadMath, or roads won't join the split. A screenshot of
	the cases is taken so the gore markings can be judged by eye.
]]

local END_COLORS: { [RoadMath.EndpointId]: Color3 } = {
	Stem = Color3.fromRGB(0, 100, 255),
	BranchLeft = Color3.fromRGB(255, 40, 40),
	BranchRight = Color3.fromRGB(255, 160, 40),
}

local function buildSplit(attributes: { [string]: any }, pivot: CFrame): Model
	local model = Instance.new("ProceduralModel" :: any) :: any
	local generator = script.Parent.Templates.RoadSplitGenerator:Clone()
	generator.Parent = model
	model.Generator = generator
	for name, value in attributes do
		model:SetAttribute(name, value)
	end
	model:SetAttribute("AdjustShowSnappingHelper", true)
	model.Size = Vector3.new(RoadMath.splitLayout(model).BoxWidth, 0, 240)
	model:PivotTo(pivot)
	model.Parent = workspace
	return model
end

-- The helper cubes of one color, once the model has generated
local function waitForHelpers(model: Model, color: Color3): { BasePart }
	local deadline = os.clock() + 10
	while os.clock() < deadline do
		local cubes = {}
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and part.Name == "SnappingHelper" and part.Color == color then
				table.insert(cubes, part)
			end
		end
		if #cubes == 2 then
			return cubes
		end
		task.wait(0.1)
	end
	return {}
end

local function checkEnd(t: TestTypes.TestContext, model: Model, id: RoadMath.EndpointId)
	local info = assert(RoadMath.getSegmentInfo(model))
	local cubes = waitForHelpers(model, END_COLORS[id])
	if #cubes ~= 2 then
		t.fail(`{model.Name}: no {id} snapping helpers were generated`)
		return
	end
	local pivot = model:GetPivot()
	local a = pivot:PointToObjectSpace(cubes[1].Position)
	local b = pivot:PointToObjectSpace(cubes[2].Position)
	local endpoint = RoadMath.getEndpoint(info, id)
	local expectedX = pivot:PointToObjectSpace(endpoint.WorldCFrame.Position).X
	if math.abs((a.X + b.X) / 2 - expectedX) > 0.05 then
		t.fail(`{model.Name}: {id} end centre is at x = {(a.X + b.X) / 2}, RoadMath says {expectedX}`)
	end
	local width = RoadMath.endpointWidth(endpoint)
	if math.abs(math.abs(a.X - b.X) - width) > 0.05 then
		t.fail(`{model.Name}: {id} end is {math.abs(a.X - b.X)} wide, RoadMath says {width}`)
	end
end

return function(t: TestTypes.TestContext)
	local origin = Vector3.new(0, 500, 400)

	t.test("generator and RoadMath agree on split ends", function()
		local base = {
			LaneWidth = 24,
			SidewalkWidth = 8,
			DriveSide = "Left",
			TextureLaneMarkings = true,
			SplitSeparation = 16,
		}
		local function case(name: string, offset: number, attributes: { [string]: any }): Model
			local merged = table.clone(base)
			for key, value in attributes do
				merged[key] = value
			end
			local model = buildSplit(merged, CFrame.new(origin + Vector3.new(offset, 0, 0)))
			model.Name = name
			return model
		end
		local models = {
			-- A two-way road separating into a dual carriageway: diagonal
			-- hatching between the opposing directions
			case("DualSplit", -220, { LaneCountForward = 2, LaneCountBackward = 2 }),
			-- A one-way carriageway diverging: chevrons
			case("Diverge", 0, { LaneCountForward = 3, LaneCountBackward = 0 }),
			-- No footways: the island beyond the nose is a grass verge
			case("RuralDiverge", 220, {
				LaneCountForward = 2,
				LaneCountBackward = 0,
				SidewalkWidth = 0,
				SplitSeparation = 24,
			}),
		}

		local camera = workspace.CurrentCamera
		local previousCFrame = camera.CFrame
		camera.CFrame = CFrame.lookAt(origin + Vector3.new(0, 560, -1), origin)

		local ok, err = pcall(function()
			for _, model in models do
				for id in END_COLORS do
					checkEnd(t, model, id)
				end
			end
			t.screenshot("y splits")
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
