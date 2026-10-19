local TestTypes = require("./TestTypes")

local Markings = require("./Markings")

--[[
	Hand-drawn markings (see Markings) on a straight road built from the
	packaged generator: a line drawn on the road is built into strips that
	nothing can hit, survives the road regenerating, moves with the road,
	and isn't copied onto roads cloned from it. A screenshot shows each style.
]]

local function buildStraight(pivot: CFrame): Model
	local model = Instance.new("ProceduralModel" :: any) :: any
	local generator = script.Parent.Templates.StraightRoadGenerator:Clone()
	generator.Parent = model
	model.Generator = generator
	model.Size = Vector3.new(64, 0, 240)
	model:PivotTo(pivot)
	model.Parent = workspace
	return model
end

local function strips(line: Model): { BasePart }
	local list = {}
	for _, child in line:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(list, child)
		end
	end
	return list
end

return function(t: TestTypes.TestContext)
	local origin = Vector3.new(0, 500, 900)

	t.test("drawn markings stay on their road", function()
		local road = buildStraight(CFrame.new(origin))
		local camera = workspace.CurrentCamera
		local previousCFrame = camera.CFrame
		local ok, err = pcall(function()
			local base = origin + Vector3.new(0, 0.2, 0)
			local lines = {}
			for index, style in Markings.STYLES do
				local x = -24 + (index - 1) * 16
				local defaults = Markings.STYLE_DEFAULTS[style]
				table.insert(lines, Markings.create(road, {
					base + Vector3.new(x, 0, -100),
					base + Vector3.new(x + 6, 0, -20),
					base + Vector3.new(x, 0, 60),
				}, {
					Style = style,
					Colour = if style == "Double" then "Yellow" else "White",
					Curved = true,
					Width = defaults.Width,
					Dash = defaults.Dash,
					Gap = defaults.Gap,
				}))
			end
			local line = lines[1]
			t.expect(#Markings.getWorldPoints(line)).toBe(3)
			t.expect(#strips(line) > 0).toBe(true)
			for _, part in strips(line) do
				if part.CanQuery or part.CanCollide then
					t.fail("A marking strip can be hit or collided with")
					break
				end
			end

			-- The road regenerating (here for a lane width change) leaves the
			-- line alone
			road:SetAttribute("LaneWidth", 22)
			task.wait(1)
			t.expect(line.Parent).toBe(road)
			t.expect(#strips(line) > 0).toBe(true)

			-- Moving the road carries the line, and its points, along
			local before = strips(line)[1].Position
			road:PivotTo(road:GetPivot() + Vector3.new(0, 0, 30))
			task.wait(0.2)
			local after = strips(line)[1].Position
			t.expect((after - before - Vector3.new(0, 0, 30)).Magnitude < 1e-3).toBe(true)
			local first = Markings.getWorldPoints(line)[1]
			t.expect((first - (base + Vector3.new(-24, 0, -70))).Magnitude < 1e-3).toBe(true)

			-- A copy of the road for building another doesn't bring them
			local copy = road:Clone()
			Markings.strip(copy)
			for _, descendant in copy:GetDescendants() do
				if Markings.isLine(descendant) then
					t.fail("A copied road kept a drawn line")
					break
				end
			end
			copy:Destroy()

			camera.CFrame = CFrame.lookAt(origin + Vector3.new(0, 160, 31), origin + Vector3.new(0, 0, 30))
			task.wait(0.5)
			t.screenshot("drawn markings")
		end)
		camera.CFrame = previousCFrame
		road:Destroy()
		if not ok then
			error(err, 0)
		end
	end)
	t.test("lane zones divide the space between two sides evenly", function()
		local function expectNear(value: number, expected: number, tolerance: number, message: string)
			if math.abs(value - expected) > tolerance then
				t.fail(`{message}: {value} is not {expected}`)
			end
		end
		-- Straight parallel sides 30 apart, 3 lanes: lines a third and two
		-- thirds across, each just its two end points
		local straight = Markings.laneZoneLines(
			{ Vector3.new(0, 0, 0), Vector3.new(100, 0, 0) },
			{ Vector3.new(0, 0, 30), Vector3.new(100, 0, 30) },
			3, false, true
		)
		t.expect(#straight).toBe(2)
		t.expect(#straight[1].Points).toBe(2)
		expectNear(straight[1].Points[1].Z, 10, 1e-6, "first lane line")
		expectNear(straight[2].Points[1].Z, 20, 1e-6, "second lane line")

		-- Concentric quarter arcs (radii 60 and 108) give lines on radii 76
		-- and 92, in a handful of points
		local function arc(radius: number): { Vector3 }
			local points = {}
			for i = 0, 6 do
				local angle = math.rad(15 * i)
				table.insert(points, Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius))
			end
			return points
		end
		local arcs = Markings.laneZoneLines(arc(60), arc(108), 3, false, true)
		for index, radius in { 76, 92 } do
			t.expect(#arcs[index].Points <= 10).toBe(true)
			for _, point in Markings.samplePath(arcs[index].Points, true) do
				expectNear(math.sqrt(point.X ^ 2 + point.Z ^ 2), radius, 0.5, "arc lane line radius")
			end
		end

		-- A side with no length (the cursor still on the point just placed)
		-- doesn't break the zone: it just gives lines that fan in to a point
		local pinched = Markings.laneZoneLines(
			{ Vector3.new(0, 0, 0), Vector3.new(100, 0, 0) },
			{ Vector3.new(0, 0, 30), Vector3.new(0, 0, 30) },
			3, false, true
		)
		t.expect(#pinched).toBe(2)

		-- One lane needs no dividers; edges come only when asked for
		t.expect(#Markings.laneZoneLines(arc(60), arc(108), 1, false, true)).toBe(0)
		local edged = Markings.laneZoneLines(arc(60), arc(108), 2, true, true)
		t.expect(#edged).toBe(3)
		t.expect(edged[2].Edge and edged[3].Edge and not edged[1].Edge).toBe(true)
	end)
end
