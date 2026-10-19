local TestTypes = require("./TestTypes")

local RoadMath = require("./RoadMath")

--[[
	Roundabouts built from the packaged generator: a round one with four
	arms, a rounded rectangle with a truck apron and uneven arms, and an oval
	with spiral lane markings. Checks that they generate (island, markings,
	apron), that every arm's road end is where RoadMath puts it, and takes a
	screenshot so the shapes, mouths, splitter islands and markings can be
	judged by eye.
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
	model:SetAttribute("AdjustShowSnappingHelper", true)
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
		round.Arms = "0,1,1;90,1,1;180,1,1;270,1,1"
		round.SplitterStyle = "Hatched"
		local rectangle = table.clone(base)
		rectangle.IslandShape = "-90,-40,20;90,-40,20;90,40,20;-90,40,20"
		rectangle.ApronWidth = 12
		-- An uneven mix: a two-lane approach flaring to three with its own
		-- arrows, an exit-only arm, an arm off at an odd angle, and a longer
		-- arm skewed 25 degrees with a flare and automatic arrows
		rectangle.Arms = "0,1,2,0,0,1,L/A/AR;100,1,1;200,1,0;300,2,1,180,25,1"
		-- A three-lane oval with spiral lane lines
		local spiral = table.clone(base)
		spiral.IslandShape = "-60,0,45;60,0,45"
		spiral.RingLanes = 3
		spiral.Arms = "0,1,1;120,2,2,0,0,1;240,1,1"
		spiral.RingMarkings = "Spiral"
		local models = {
			buildRoundabout(round, CFrame.new(origin + Vector3.new(-200, 0, 0))),
			buildRoundabout(rectangle, CFrame.new(origin + Vector3.new(220, 0, 0))),
			buildRoundabout(spiral, CFrame.new(origin + Vector3.new(0, 0, 420))),
		}

		local camera = workspace.CurrentCamera
		local previousCFrame = camera.CFrame
		camera.CFrame = CFrame.lookAt(origin + Vector3.new(0, 900, 179), origin + Vector3.new(0, 0, 180))

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
			-- Each arm's road end must be where RoadMath says, or roads won't
			-- join it: the generator marks each end's corners with helper
			-- cubes 2 studs back along the arm
			for _, model in models do
				local info = assert(RoadMath.getSegmentInfo(model))
				local cubes = {}
				for _, descendant in model:GetDescendants() do
					if descendant:IsA("BasePart") and descendant.Name == "SnappingHelper" then
						table.insert(cubes, descendant.Position)
					end
				end
				for _, endpoint in RoadMath.allEndpoints(info) do
					local frame = endpoint.WorldCFrame
					local half = RoadMath.endpointWidth(endpoint) / 2
					local found = 0
					for _, sign in { -1, 1 } do
						local expected = frame.Position - frame.LookVector * 2 + frame.RightVector * (sign * half)
							+ Vector3.yAxis * 2
						for _, cube in cubes do
							if (cube - expected).Magnitude < 0.1 then
								found += 1
								break
							end
						end
					end
					if found ~= 2 then
						t.fail(`{endpoint.Id}: the generator's arm end isn't where RoadMath puts it`)
					end
				end
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
