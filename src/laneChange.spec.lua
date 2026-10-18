local TestTypes = require("./TestTypes")

local RoadMath = require("./RoadMath")

--[[
	Lane-change straights built from the packaged generator. The generator's
	snapping helper cubes mark each end's two corners, so they show where the
	generator put each end and how wide it made it: that must agree with
	RoadMath, or joints won't line up. Screenshots of each case are taken so
	the taper itself can be judged by eye.
]]

local BLUE = Color3.fromRGB(0, 100, 255)
local RED = Color3.fromRGB(255, 40, 40)

local function buildStraight(attributes: { [string]: any }, size: Vector3, pivot: CFrame): Model
	local model = Instance.new("ProceduralModel" :: any) :: any
	local generator = script.Parent.Templates.StraightRoadGenerator:Clone()
	generator.Parent = model
	model.Generator = generator
	for name, value in attributes do
		model:SetAttribute(name, value)
	end
	model:SetAttribute("AdjustShowSnappingHelper", true)
	model.Size = size
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
	local cubes = waitForHelpers(model, if id == "Blue" then BLUE else RED)
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
	local origin = Vector3.new(0, 500, 0)

	local function case(name: string, offset: number, attributes: { [string]: any }, size: Vector3)
		local base = {
			LaneWidth = 24,
			SidewalkWidth = 8,
			DriveSide = "Left",
			LaneCountForward = 2,
			LaneCountBackward = 2,
			TextureLaneMarkings = true,
		}
		for key, value in attributes do
			base[key] = value
		end
		local model = buildStraight(base, size, CFrame.new(origin + Vector3.new(offset, 0, 0)))
		model.Name = name
		return model
	end

	t.test("generator and RoadMath agree on lane-change ends", function()
		local models = {
			-- 2 + 2 lanes tapering to 1 + 2: the 24-stud lane loss shifts the
			-- red end 12 studs sideways (sway 6), Flip picking the side
			case("OffsideDrop", -180, {
				LaneCountForwardRed = 1,
				LaneCountBackwardRed = 2,
				LaneChangeSide = "Offside",
				Flip = true,
			}, Vector3.new(124, 0, 240)),
			case("NearsideDrop", 0, {
				LaneCountForwardRed = 1,
				LaneCountBackwardRed = 2,
				LaneChangeSide = "Nearside",
				Flip = true,
			}, Vector3.new(124, 0, 240)),
			-- A lane gain the other way round, and a plain road for comparison
			case("OffsideGain", 180, {
				LaneCountForward = 1,
				LaneCountForwardRed = 2,
				LaneCountBackwardRed = 2,
				LaneChangeSide = "Offside",
			}, Vector3.new(124, 0, 240)),
			case("Plain", 360, {}, Vector3.new(112, 0, 240)),
		}

		local camera = workspace.CurrentCamera
		local previousCFrame = camera.CFrame
		camera.CFrame = CFrame.lookAt(origin + Vector3.new(90, 520, -1), origin + Vector3.new(90, 0, 0))

		local ok, err = pcall(function()
			for _, model in models do
				checkEnd(t, model, "Blue")
				checkEnd(t, model, "Red")
			end
			t.screenshot("lane changes")
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
