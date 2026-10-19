local TestTypes = require("./TestTypes")

local RoadMath = require("./RoadMath")

local WIDTH = 64

local function makeSegment(kind: RoadMath.SegmentKind, size: Vector3, pivot: CFrame, flip: boolean?): RoadMath.SegmentInfo
	-- Stand-in for a ProceduralModel: only GetAttribute is needed by RoadMath
	local fakeModel: any = {
		attrs = {} :: { [string]: any },
	}
	fakeModel.GetAttribute = function(self, name: string)
		return self.attrs[name]
	end
	return {
		Model = fakeModel :: any,
		Kind = kind,
		Width = WIDTH,
		Size = size,
		Pivot = pivot,
		Flip = flip or false,
	}
end

local function expectFuzzy(t: TestTypes.TestContext, actual: Vector3, expected: Vector3, epsilon: number?)
	if not actual:FuzzyEq(expected, epsilon or 0.01) then
		t.fail(`Expected {expected}, got {actual}`)
	end
end

return function(t: TestTypes.TestContext)
	--
	-- Endpoint frames
	--

	t.test("straight endpoints: flat straight road", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local blue, red = RoadMath.getEndpoints(seg)
		expectFuzzy(t, blue.WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, blue.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
		expectFuzzy(t, red.WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, red.WorldCFrame.LookVector, Vector3.new(0, 0, 1))
	end)

	t.test("straight endpoints: swayed climbing road with flip", function()
		-- sway = (200 - 64)/2 = 68; flip mirrors X so blue is at +68
		local seg = makeSegment("Straight", Vector3.new(200, 30, 300), CFrame.identity, true)
		local blue, red = RoadMath.getEndpoints(seg)
		expectFuzzy(t, blue.WorldCFrame.Position, Vector3.new(68, -15, -150))
		expectFuzzy(t, red.WorldCFrame.Position, Vector3.new(-68, 15, 150))
	end)

	t.test("straight endpoints: respect the model pivot", function()
		local pivot = CFrame.new(100, 5, 20) * CFrame.Angles(0, math.rad(90), 0)
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), pivot)
		local blue = RoadMath.getEndpoint(seg, "Blue")
		expectFuzzy(t, blue.WorldCFrame.Position, (pivot * CFrame.new(0, 0, -100)).Position)
		expectFuzzy(t, blue.WorldCFrame.LookVector, pivot:VectorToWorldSpace(Vector3.new(0, 0, -1)))
	end)

	t.test("curve endpoints: flat square curve", function()
		local seg = makeSegment("Curve", Vector3.new(120, 0, 120), CFrame.identity)
		local blue, red = RoadMath.getEndpoints(seg)
		expectFuzzy(t, blue.WorldCFrame.Position, Vector3.new(-60 + 32, 0, -60))
		expectFuzzy(t, blue.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
		expectFuzzy(t, red.WorldCFrame.Position, Vector3.new(60, 0, 60 - 32))
		expectFuzzy(t, red.WorldCFrame.LookVector, Vector3.new(1, 0, 0))
	end)

	t.test("curve endpoints: flip swaps climb ends", function()
		local seg = makeSegment("Curve", Vector3.new(120, 20, 120), CFrame.identity, true)
		local blue, red = RoadMath.getEndpoints(seg)
		t.expect(blue.WorldCFrame.Position.Y).toBe(10)
		t.expect(red.WorldCFrame.Position.Y).toBe(-10)
	end)

	--
	-- Moving endpoints
	--

	t.test("solveMove straight: extend red end forward", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local solution = RoadMath.solveMove(seg, "Red", Vector3.new(0, 0, 150))
		expectFuzzy(t, solution.Size, Vector3.new(WIDTH, 0, 250))
		t.expect(solution.Flip).toBe(false)
		-- Blue endpoint must stay at (0, 0, -100)
		local newSeg = makeSegment("Straight", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(0, 0, 150))
	end)

	t.test("solveMove straight: lateral move creates sway and sets Flip by side", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)

		-- Move red +X: red ends up on the +X side, no flip
		local plus = RoadMath.solveMove(seg, "Red", Vector3.new(40, 0, 100))
		expectFuzzy(t, plus.Size, Vector3.new(WIDTH + 40, 0, 200))
		t.expect(plus.Flip).toBe(false)
		local plusSeg = makeSegment("Straight", plus.Size, plus.Pivot, plus.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(plusSeg, "Blue").WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, RoadMath.getEndpoint(plusSeg, "Red").WorldCFrame.Position, Vector3.new(40, 0, 100))

		-- Move red -X: crosses to the other side, Flip
		local minus = RoadMath.solveMove(seg, "Red", Vector3.new(-40, 0, 100))
		t.expect(minus.Flip).toBe(true)
		local minusSeg = makeSegment("Straight", minus.Size, minus.Pivot, minus.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(minusSeg, "Blue").WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, RoadMath.getEndpoint(minusSeg, "Red").WorldCFrame.Position, Vector3.new(-40, 0, 100))
	end)

	t.test("solveMove straight: moving the blue end keeps red fixed", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local solution = RoadMath.solveMove(seg, "Blue", Vector3.new(-30, 0, -160))
		local newSeg = makeSegment("Straight", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, Vector3.new(-30, 0, -160))
		-- Blue moved -X means red is on the +X side relative to blue: no flip
		t.expect(solution.Flip).toBe(false)
	end)

	t.test("solveMove straight: vertical move up sets height without a swap", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local up = RoadMath.solveMove(seg, "Red", Vector3.new(0, 25, 100))
		t.expect(up.Size.Y).toBe(25)
		t.expect(up.SwapEnds).toBe(false)
		local newSeg = makeSegment("Straight", up.Size, up.Pivot, up.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, Vector3.new(0, 0, -100))
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(0, 25, 100))
	end)

	t.test("solveMove straight: moving red below blue swaps ends, preserving sway", function()
		-- Swayed segment: sway 30, blue at (-30, 0, -100), red at (30, 0, 100)
		local seg = makeSegment("Straight", Vector3.new(WIDTH + 60, 0, 200), CFrame.identity)
		local oldBlue = RoadMath.getEndpoint(seg, "Blue").WorldCFrame.Position
		local target = Vector3.new(30, -25, 100) -- straight down from red
		local solution = RoadMath.solveMove(seg, "Red", target)
		t.expect(solution.SwapEnds).toBe(true)
		t.expect(solution.Size.Y).toBe(25)
		-- Sway and Flip are preserved by the 180-degree rotational symmetry
		t.expect(solution.Size.X).toBe(WIDTH + 60)
		t.expect(solution.Flip).toBe(false)
		local newSeg = makeSegment("Straight", solution.Size, solution.Pivot, solution.Flip)
		-- The dragged geographic end is now the blue (bottom) end
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, target)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, oldBlue)
	end)

	t.test("solveMove straight: swap works when moving the blue end up", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local oldRed = RoadMath.getEndpoint(seg, "Red").WorldCFrame.Position
		local target = Vector3.new(0, 30, -100) -- blue end pulled above red
		local solution = RoadMath.solveMove(seg, "Blue", target)
		t.expect(solution.SwapEnds).toBe(true)
		t.expect(solution.Size.Y).toBe(30)
		local newSeg = makeSegment("Straight", solution.Size, solution.Pivot, solution.Flip)
		-- The dragged geographic end is now the red (top) end
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, target)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, oldRed)
	end)

	t.test("swappedAdjustValues: dir carries, grade and bank negate", function()
		local values = {
			AdjustBlueDir = 10, AdjustBlueGrade = 5, AdjustBlueBank = 3,
			AdjustRedDir = -20, AdjustRedGrade = 8, AdjustRedBank = -4,
		}
		local swapped = RoadMath.swappedAdjustValues(function(name)
			return values[name]
		end)
		t.expect(swapped.AdjustBlueDir).toBe(-20)
		t.expect(swapped.AdjustBlueGrade).toBe(-8)
		t.expect(swapped.AdjustBlueBank).toBe(4)
		t.expect(swapped.AdjustRedDir).toBe(10)
		t.expect(swapped.AdjustRedGrade).toBe(-5)
		t.expect(swapped.AdjustRedBank).toBe(-3)
	end)

	t.test("solveMove straight: respects rotated pivots", function()
		local pivot = CFrame.new(50, 0, 50) * CFrame.Angles(0, math.rad(90), 0)
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), pivot)
		local oldBlue = RoadMath.getEndpoint(seg, "Blue").WorldCFrame.Position
		local oldRed = RoadMath.getEndpoint(seg, "Red").WorldCFrame.Position
		-- Extend along the world direction the road actually runs
		local newRed = oldRed + (oldRed - oldBlue).Unit * 50
		local solution = RoadMath.solveMove(seg, "Red", newRed)
		local newSeg = makeSegment("Straight", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, oldBlue)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, newRed)
	end)

	t.test("solveMove curve: endpoints track moved corners", function()
		local seg = makeSegment("Curve", Vector3.new(120, 0, 120), CFrame.identity)
		local oldBlue = RoadMath.getEndpoint(seg, "Blue").WorldCFrame.Position
		local solution = RoadMath.solveMove(seg, "Red", Vector3.new(100, 10, 28))
		local newSeg = makeSegment("Curve", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, oldBlue)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(100, 10, 28))
		t.expect(solution.Flip).toBe(false)
	end)

	t.test("solveMove curve: moving red below blue flips", function()
		local seg = makeSegment("Curve", Vector3.new(120, 0, 120), CFrame.identity)
		local oldBlue = RoadMath.getEndpoint(seg, "Blue").WorldCFrame.Position
		local solution = RoadMath.solveMove(seg, "Red", Vector3.new(60, -18, 28))
		t.expect(solution.Flip).toBe(true)
		t.expect(solution.Size.Y).toBe(18)
		local newSeg = makeSegment("Curve", solution.Size, solution.Pivot, solution.Flip)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, oldBlue)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, Vector3.new(60, -18, 28))
	end)

	t.test("solveMove curve: clamps to minimum footprint", function()
		local seg = makeSegment("Curve", Vector3.new(120, 0, 120), CFrame.identity)
		-- Try to collapse the curve entirely
		local solution = RoadMath.solveMove(seg, "Red", Vector3.new(-60, 0, -60))
		t.expect(solution.Size.X >= WIDTH).toBe(true)
		t.expect(solution.Size.Z >= WIDTH).toBe(true)
	end)

	--
	-- Joints
	--

	t.test("findJoint: mated red->blue endpoints are closed", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		-- B continues from A's red end at (0, 0, 100), heading +Z
		local segB = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 150))
		local segments = { segA, segB }
		local joint = RoadMath.findJoint(RoadMath.getEndpoint(segA, "Red"), segments)
		t.expect(joint ~= nil).toBe(true)
		assert(joint)
		t.expect(joint.Id).toBe("Blue")
		t.expect(joint.Segment).toBe(segB)
	end)

	t.test("findJoint: far endpoints and same-facing endpoints are open", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local segFar = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 500))
		-- Same position as A's red end but facing the same way (overlapping, not mated)
		local segSame = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 50))
		local segments = { segA, segFar, segSame }
		local joint = RoadMath.findJoint(RoadMath.getEndpoint(segA, "Red"), segments)
		t.expect(joint == nil).toBe(true)
	end)

	--
	-- Adjust mapping
	--

	t.test("adjustDeltaSign: dir is +1 for both sides of a joint", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local segB = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 150))
		local selected = RoadMath.getEndpoint(segA, "Red")
		local partner = RoadMath.getEndpoint(segB, "Blue")
		t.expect(RoadMath.adjustDeltaSign(selected, selected, "Dir")).toBe(1)
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Dir")).toBe(1)
	end)

	t.test("adjustDeltaSign: grade/bank match for red->blue joints", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local segB = makeSegment("Straight", Vector3.new(WIDTH, 0, 100), CFrame.new(0, 0, 150))
		local selected = RoadMath.getEndpoint(segA, "Red")
		local partner = RoadMath.getEndpoint(segB, "Blue")
		-- selected red: colorSign +1, facing itself +1 => +1
		t.expect(RoadMath.adjustDeltaSign(selected, selected, "Grade")).toBe(1)
		-- partner blue: colorSign -1, facing opposite -1 => +1 (grades stay equal)
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Grade")).toBe(1)
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Bank")).toBe(1)
	end)

	t.test("adjustDeltaSign: grade/bank negate for blue-blue joints", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		-- B's blue end mates with A's blue end (B runs the other way)
		local segB = makeSegment(
			"Straight",
			Vector3.new(WIDTH, 0, 100),
			CFrame.new(0, 0, -150) * CFrame.Angles(0, math.rad(180), 0)
		)
		local selected = RoadMath.getEndpoint(segA, "Blue")
		local partner = RoadMath.getEndpoint(segB, "Blue")
		-- Sanity: they are mated
		t.expect((selected.WorldCFrame.Position - partner.WorldCFrame.Position).Magnitude < 0.1).toBe(true)
		-- selected blue: colorSign -1, facing itself +1 => -1
		t.expect(RoadMath.adjustDeltaSign(selected, selected, "Grade")).toBe(-1)
		-- partner blue: colorSign -1, facing opposite -1 => +1
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Grade")).toBe(1)
	end)

	t.test("adjustDeltaSign: grade flips on flipped curves (V-shape bug)", function()
		-- Straight A with its blue end at (0, 0, -100) facing -Z
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		-- Flipped curve B rotated so its red end mates with A's blue end
		local rotation = CFrame.Angles(0, math.rad(-90), 0)
		local redLocal = RoadMath.localEndpointFrame("Curve", Vector3.new(120, 20, 120), WIDTH, true, "Red")
		local pivot = rotation + (Vector3.new(0, 0, -100) - rotation:VectorToWorldSpace(redLocal.Position))
		local segB = makeSegment("Curve", Vector3.new(120, 20, 120), pivot, true)

		local selected = RoadMath.getEndpoint(segA, "Blue")
		local partner = RoadMath.getEndpoint(segB, "Red")
		-- Sanity: mated
		t.expect((selected.WorldCFrame.Position - partner.WorldCFrame.Position).Magnitude < 0.1).toBe(true)
		t.expect(partner.WorldCFrame.LookVector:Dot(selected.WorldCFrame.LookVector) < -0.9).toBe(true)

		-- Selected straight blue: colorSign -1 * facing +1 * flip 1 = -1
		t.expect(RoadMath.adjustDeltaSign(selected, selected, "Grade")).toBe(-1)
		-- Partner FLIPPED curve red: colorSign +1 * facing -1 * flip -1 = +1
		-- (opposite attribute deltas <=> equal world pitch, because the flipped
		-- curve's grade attribute means the opposite world pitch)
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Grade")).toBe(1)
		-- Bank has no curve flip factor: colorSign +1 * facing -1 = -1
		t.expect(RoadMath.adjustDeltaSign(selected, partner, "Bank")).toBe(-1)

		-- An UNFLIPPED curve in the same spot keeps the plain mapping
		local redLocalUnflipped = RoadMath.localEndpointFrame("Curve", Vector3.new(120, 20, 120), WIDTH, false, "Red")
		local pivotUnflipped = rotation + (Vector3.new(0, 0, -100) - rotation:VectorToWorldSpace(redLocalUnflipped.Position))
		local segC = makeSegment("Curve", Vector3.new(120, 20, 120), pivotUnflipped, false)
		local partnerUnflipped = RoadMath.getEndpoint(segC, "Red")
		t.expect(RoadMath.adjustDeltaSign(selected, partnerUnflipped, "Grade")).toBe(-1)
	end)

	t.test("adjustDeltaSign: dir mirrors on flipped straights", function()
		local seg = makeSegment("Straight", Vector3.new(200, 0, 200), CFrame.identity, true)
		local endpoint = RoadMath.getEndpoint(seg, "Red")
		t.expect(RoadMath.adjustDeltaSign(endpoint, endpoint, "Dir")).toBe(-1)
		local unflipped = makeSegment("Straight", Vector3.new(200, 0, 200), CFrame.identity, false)
		local endpoint2 = RoadMath.getEndpoint(unflipped, "Red")
		t.expect(RoadMath.adjustDeltaSign(endpoint2, endpoint2, "Dir")).toBe(1)
	end)

	t.test("actualOutwardDirection: mirrors dir on flipped straights", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity, true);
		(seg.Model :: any).attrs.AdjustRedDir = 30
		local endpoint = RoadMath.getEndpoint(seg, "Red")
		local outward = RoadMath.actualOutwardDirection(endpoint)
		-- Effective yaw is -30 degrees on a flipped straight
		local expected = CFrame.Angles(0, math.rad(-30), 0):VectorToWorldSpace(Vector3.new(0, 0, 1))
		if not outward:FuzzyEq(expected, 0.01) then
			t.fail(`Expected {expected}, got {outward}`)
		end
	end)

	t.test("matchingAdjust: converts through the open end's curve flip", function()
		local rotation = CFrame.Angles(0, math.rad(-90), 0)
		local redLocal = RoadMath.localEndpointFrame("Curve", Vector3.new(120, 20, 120), WIDTH, true, "Red")
		local pivot = rotation + (Vector3.new(0, 0, -100) - rotation:VectorToWorldSpace(redLocal.Position))
		local segB = makeSegment("Curve", Vector3.new(120, 20, 120), pivot, true);
		(segB.Model :: any).attrs.AdjustRedGrade = 10
		local openEnd = RoadMath.getEndpoint(segB, "Red")
		-- Flipped curve red with grade 10 actually exits pitching -10; a new
		-- (unflipped) blue end mating it must enter with grade -10.
		local matching = RoadMath.matchingAdjust(openEnd, "Blue")
		t.expect(matching.Grade).toBe(-10)
	end)

	--
	-- New segment placement
	--

	t.test("placeNewSegment: straight extension joins blue to the open red end", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local openEnd = RoadMath.getEndpoint(segA, "Red") -- at (0, 0, 100) facing +Z
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, "Straight", WIDTH)
		t.expect(kind).toBe("Straight")
		t.expect(joinId).toBe("Blue")
		local newSeg = makeSegment("Straight", size, pivot)
		local joined = RoadMath.getEndpoint(newSeg, joinId)
		expectFuzzy(t, joined.WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, joined.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
	end)

	t.test("placeNewSegment: right turn joins a curve's blue end", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, "Right", WIDTH)
		t.expect(kind).toBe("Curve")
		t.expect(joinId).toBe("Blue")
		local newSeg = makeSegment("Curve", size, pivot)
		local joined = RoadMath.getEndpoint(newSeg, joinId)
		expectFuzzy(t, joined.WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, joined.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
		-- Right turn: the curve's far (red) endpoint should be on the +X side
		local far = RoadMath.getEndpoint(newSeg, "Red")
		t.expect(far.WorldCFrame.Position.X > 10).toBe(true)
	end)

	t.test("placeNewSegment: left turn joins a curve's red end, exits -X side", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, "Left", WIDTH)
		t.expect(kind).toBe("Curve")
		t.expect(joinId).toBe("Red")
		local newSeg = makeSegment("Curve", size, pivot)
		local joined = RoadMath.getEndpoint(newSeg, joinId)
		expectFuzzy(t, joined.WorldCFrame.Position, Vector3.new(0, 0, 100))
		expectFuzzy(t, joined.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
		-- Left turn: the curve's far (blue) endpoint should be on the -X side
		local far = RoadMath.getEndpoint(newSeg, "Blue")
		t.expect(far.WorldCFrame.Position.X < -10).toBe(true)
	end)

	t.test("placeNewSegment: joint seals via matching Dir on an adjusted end", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity);
		(segA.Model :: any).attrs.AdjustRedDir = 30
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, "Straight", WIDTH)
		local matching = RoadMath.matchingAdjust(openEnd, joinId)
		local newSeg = makeSegment(kind, size, pivot);
		(newSeg.Model :: any).attrs[RoadMath.adjustAttributeName(joinId, "Dir")] = matching.Dir
		local joined = RoadMath.getEndpoint(newSeg, joinId)
		-- The model itself stays nominal-frame aligned, but with the matching
		-- Dir applied the two faces' actual directions must oppose exactly,
		-- sealing the joint.
		local openActual = RoadMath.actualOutwardDirection(openEnd)
		local joinActual = RoadMath.actualOutwardDirection(joined)
		expectFuzzy(t, joinActual, -openActual)
	end)

	t.test("intersection endpoints: ids, frames, and widths", function()
		local fake: any = { attrs = {} }
		fake.GetAttribute = function(self, name)
			return self.attrs[name]
		end
		local seg: RoadMath.SegmentInfo = {
			Model = fake,
			Kind = "Intersection",
			Width = 64,
			WidthX = 112,
			Angle = math.rad(60),
			ThroughRoad = true,
			Size = Vector3.new(250, 0, 250),
			Pivot = CFrame.new(10, 0, 20),
			Flip = false,
		}
		t.expect(#RoadMath.endpointIds(seg)).toBe(4)
		seg.ThroughRoad = false
		t.expect(#RoadMath.endpointIds(seg)).toBe(3)
		seg.ThroughRoad = true

		local zPlus = RoadMath.getEndpoint(seg, "ZPlus")
		expectFuzzy(t, zPlus.WorldCFrame.Position, Vector3.new(10, 0, 145))
		expectFuzzy(t, zPlus.WorldCFrame.LookVector, Vector3.new(0, 0, 1))
		t.expect(RoadMath.endpointWidth(zPlus)).toBe(64)

		local uX = Vector3.new(math.sin(math.rad(60)), 0, math.cos(math.rad(60)))
		local xPlus = RoadMath.getEndpoint(seg, "XPlus")
		expectFuzzy(t, xPlus.WorldCFrame.Position, Vector3.new(10, 0, 20) + uX * 125)
		expectFuzzy(t, xPlus.WorldCFrame.LookVector, uX)
		t.expect(RoadMath.endpointWidth(xPlus)).toBe(112)

		-- A road end placed against an intersection end joins to it
		local roadPivot = CFrame.new(zPlus.WorldCFrame.Position + Vector3.new(0, 0, 100))
		local road = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), roadPivot)
		local joint = RoadMath.findJoint(RoadMath.getEndpoint(road, "Blue"), { seg })
		t.expect(joint ~= nil).toBe(true)
		t.expect((joint :: any).Id).toBe("ZPlus")
	end)

	t.test("intersection exits: stray Adjust attributes don't rotate them", function()
		local fake: any = { attrs = { AdjustRedDir = 25, AdjustBlueDir = -40 } }
		fake.GetAttribute = function(self, name)
			return self.attrs[name]
		end
		local seg: RoadMath.SegmentInfo = {
			Model = fake,
			Kind = "Intersection",
			Width = 64,
			WidthX = 64,
			Angle = math.rad(90),
			ThroughRoad = true,
			Size = Vector3.new(250, 0, 250),
			Pivot = CFrame.identity,
			Flip = false,
		}
		for _, id in RoadMath.endpointIds(seg) do
			local exit = RoadMath.getEndpoint(seg, id)
			expectFuzzy(t, RoadMath.actualOutwardDirection(exit), exit.WorldCFrame.LookVector)
			expectFuzzy(t, RoadMath.actualEndpointFrame(exit).LookVector, exit.WorldCFrame.LookVector)
		end
	end)

	t.test("intersection exits: box-aligned placement with matching Dir", function()
		local fake: any = { attrs = {} }
		fake.GetAttribute = function(self, name)
			return self.attrs[name]
		end
		local seg: RoadMath.SegmentInfo = {
			Model = fake,
			Kind = "Intersection",
			Width = 64,
			WidthX = 64,
			Angle = math.rad(60),
			ThroughRoad = true,
			Size = Vector3.new(250, 0, 250),
			Pivot = CFrame.identity,
			Flip = false,
		}
		local xPlus = RoadMath.getEndpoint(seg, "XPlus")
		-- Placement squares to the box +X axis at the exit position
		local placement = RoadMath.placementFrame(xPlus)
		expectFuzzy(t, placement.LookVector, Vector3.new(1, 0, 0))
		expectFuzzy(t, placement.Position, xPlus.WorldCFrame.Position)
		-- The joining end's Dir takes up the skew: at 60 degrees the exit is
		-- 30 degrees toward +Z from the +X box axis
		local matching = RoadMath.matchingAdjust(xPlus, "Blue")
		t.expect(math.abs(matching.Dir - -30) < 0.01).toBe(true)
		t.expect(matching.Grade).toBe(0)
		-- placeNewSegment yields a box-aligned pivot (no 60 degree yaw)
		local _, _, pivot = RoadMath.placeNewSegment(xPlus, "Straight", 64)
		t.expect(math.abs(pivot.LookVector.Z) < 1e-5).toBe(true)
		-- Z exits place with zero Dir
		local zPlus = RoadMath.getEndpoint(seg, "ZPlus")
		t.expect(RoadMath.matchingAdjust(zPlus, "Blue").Dir).toBe(0)
	end)

	t.test("matchingAdjust: negates for same-color joins, copies for opposite", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local mockModel = {
			attrs = { AdjustRedGrade = 10, AdjustRedBank = 5 },
		}
		(mockModel :: any).GetAttribute = function(self, name)
			return self.attrs[name]
		end
		segA.Model = mockModel :: any
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		-- Red joined to Blue: k = -(+1)(-1) = +1 (copy)
		local blueJoin = RoadMath.matchingAdjust(openEnd, "Blue")
		t.expect(blueJoin.Grade).toBe(10)
		t.expect(blueJoin.Bank).toBe(5)
		-- Red joined to Red: k = -(+1)(+1) = -1 (negate)
		local redJoin = RoadMath.matchingAdjust(openEnd, "Red")
		t.expect(redJoin.Grade).toBe(-10)
		t.expect(redJoin.Bank).toBe(-5)
	end)

	t.test("matchingAdjust: Dir carries the open end's effective yaw", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity);
		(segA.Model :: any).attrs.AdjustRedDir = 15
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		-- Same world yaw regardless of which end of the new segment joins
		t.expect(RoadMath.matchingAdjust(openEnd, "Blue").Dir).toBe(15)
		t.expect(RoadMath.matchingAdjust(openEnd, "Red").Dir).toBe(15)
		-- A flipped straight negates the effective yaw of its Dir attributes
		segA.Flip = true
		t.expect(RoadMath.matchingAdjust(openEnd, "Blue").Dir).toBe(-15)
	end)

	t.test("solveWidthChange: straight keeps both endpoints fixed", function()
		-- Swayed straight so the compensation must preserve sway too
		local seg = makeSegment("Straight", Vector3.new(WIDTH + 40, 10, 200), CFrame.new(30, 5, -20))
		local blue = RoadMath.getEndpoint(seg, "Blue").WorldCFrame.Position
		local red = RoadMath.getEndpoint(seg, "Red").WorldCFrame.Position
		local solution = RoadMath.solveWidthChange(seg, WIDTH + 24)
		local newSeg = makeSegment("Straight", solution.Size, solution.Pivot)
		newSeg.Width = WIDTH + 24
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, blue)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, red)
	end)

	t.test("solveWidthChange: curve keeps both endpoints fixed", function()
		local pivot = CFrame.new(50, 0, 10) * CFrame.Angles(0, math.rad(30), 0)
		local seg = makeSegment("Curve", Vector3.new(140, 0, 140), pivot)
		local blue = RoadMath.getEndpoint(seg, "Blue").WorldCFrame.Position
		local red = RoadMath.getEndpoint(seg, "Red").WorldCFrame.Position
		local solution = RoadMath.solveWidthChange(seg, WIDTH - 20)
		local newSeg = makeSegment("Curve", solution.Size, solution.Pivot)
		newSeg.Width = WIDTH - 20
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Blue").WorldCFrame.Position, blue)
		expectFuzzy(t, RoadMath.getEndpoint(newSeg, "Red").WorldCFrame.Position, red)
	end)

	t.test("placeNewSegment: aligns to the nominal frame despite end Dir", function()
		local segA = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity);
		(segA.Model :: any).attrs.AdjustRedDir = 30
		local openEnd = RoadMath.getEndpoint(segA, "Red")
		local _, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, "Straight", WIDTH)
		-- The new model must stay world-aligned like its source rather than
		-- being yawed 30 degrees to the end's rotated face: extending an
		-- identity-aligned segment must produce an axis-aligned pivot.
		t.expect(math.abs(pivot.LookVector.Z) > 0.99999).toBe(true)
		-- And the joining ends still coincide (positions are Dir-invariant)
		local newSeg = makeSegment("Straight", size, pivot)
		local joinEnd = RoadMath.getEndpoint(newSeg, joinId)
		t.expect((joinEnd.WorldCFrame.Position - openEnd.WorldCFrame.Position).Magnitude < 0.001).toBe(true)
	end)

	--
	-- Lanes
	--

	t.test("lanes: sanitize keeps whole non-negative counts, at least one lane", function()
		local f, b = RoadMath.sanitizeLaneCounts(2.7, -1)
		t.expect(f).toBe(2)
		t.expect(b).toBe(0)
		f, b = RoadMath.sanitizeLaneCounts(0, 0)
		t.expect(f + b).toBe(1)
	end)

	t.test("lanes: out/in attribute names follow the end", function()
		local outName, inName = RoadMath.laneAttributeNames("Straight", "Red")
		t.expect(outName).toBe("LaneCountForward")
		t.expect(inName).toBe("LaneCountBackward")
		outName, inName = RoadMath.laneAttributeNames("Curve", "Blue")
		t.expect(outName).toBe("LaneCountBackward")
		t.expect(inName).toBe("LaneCountForward")
		outName, inName = RoadMath.laneAttributeNames("Intersection", "ZMinus")
		t.expect(outName).toBe("LaneCountBackwardZ")
		t.expect(inName).toBe("LaneCountForwardZ")
		outName, inName = RoadMath.laneAttributeNames("Intersection", "XPlus")
		t.expect(outName).toBe("LaneCountForwardX")
		t.expect(inName).toBe("LaneCountBackwardX")
	end)

	t.test("lanes: counts read relative to the end", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity);
		(seg.Model :: any).attrs.LaneCountForward = 2;
		(seg.Model :: any).attrs.LaneCountBackward = 1
		local lanesOut, lanesIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(seg, "Red"))
		t.expect(lanesOut).toBe(2)
		t.expect(lanesIn).toBe(1)
		lanesOut, lanesIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(seg, "Blue"))
		t.expect(lanesOut).toBe(1)
		t.expect(lanesIn).toBe(2)
	end)

	t.test("lanes: travel directions carry through a same-colour joint", function()
		-- A left turn joins a curve's red end to a straight's red end, so the
		-- curve runs backwards relative to the straight: the 2 lanes leaving
		-- the straight must be the 2 entering the curve and leaving its far
		-- (blue) end.
		local straight = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity);
		(straight.Model :: any).attrs.LaneCountForward = 2;
		(straight.Model :: any).attrs.LaneCountBackward = 1
		local openEnd = RoadMath.getEndpoint(straight, "Red")
		local curve = makeSegment("Curve", Vector3.new(128, 0, 128), CFrame.identity)
		-- What the session's matchLanesAcrossJoint does
		local mateOut, mateIn = RoadMath.getLaneCounts(openEnd)
		local outName, inName = RoadMath.laneAttributeNames("Curve", "Red");
		(curve.Model :: any).attrs[outName] = mateIn;
		(curve.Model :: any).attrs[inName] = mateOut
		local farOut, farIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(curve, "Blue"))
		t.expect(farOut).toBe(2)
		t.expect(farIn).toBe(1)
	end)

	--
	-- Lane changes
	--

	t.test("lane change: red overrides need both counts, and only apply to straights", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 0, 200), CFrame.identity)
		local attrs = (seg.Model :: any).attrs
		attrs.LaneCountForward = 2
		attrs.LaneCountBackward = 2
		attrs.LaneCountForwardRed = 1
		-- Only one override: not a lane change yet
		t.expect(RoadMath.hasLaneChange(seg)).toBe(false)
		-- -1 (the generator default) means unset
		attrs.LaneCountBackwardRed = -1
		t.expect(RoadMath.hasLaneChange(seg)).toBe(false)
		local lanesOut, lanesIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(seg, "Red"))
		t.expect(lanesOut).toBe(2)
		t.expect(lanesIn).toBe(2)

		attrs.LaneCountBackwardRed = 2
		t.expect(RoadMath.hasLaneChange(seg)).toBe(true)
		lanesOut, lanesIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(seg, "Red"))
		t.expect(lanesOut).toBe(1)
		t.expect(lanesIn).toBe(2)
		-- The blue end keeps the base counts
		lanesOut, lanesIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(seg, "Blue"))
		t.expect(lanesOut).toBe(2)
		t.expect(lanesIn).toBe(2)
		-- Single-end writes at red go to the overrides
		local outName, inName = RoadMath.endLaneAttributeNames(seg, "Red")
		t.expect(outName).toBe("LaneCountForwardRed")
		t.expect(inName).toBe("LaneCountBackwardRed")

		-- Curves ignore the overrides
		local curve = makeSegment("Curve", Vector3.new(128, 0, 128), CFrame.identity);
		(curve.Model :: any).attrs = table.clone(attrs)
		t.expect(RoadMath.hasLaneChange(curve)).toBe(false)
		lanesOut = RoadMath.getLaneCounts(RoadMath.getEndpoint(curve, "Red"))
		t.expect(lanesOut).toBe(2)
	end)

	t.test("lane change: endpoints and moves lay the box out around the wider end", function()
		-- Blue 64 wide, red 88 wide, box X 108: sway = (108 - 88) / 2 = 10
		local seg = makeSegment("Straight", Vector3.new(108, 0, 200), CFrame.identity)
		seg.WidthRed = 88
		t.expect(RoadMath.endpointWidth(RoadMath.getEndpoint(seg, "Red"))).toBe(88)
		t.expect(RoadMath.endpointWidth(RoadMath.getEndpoint(seg, "Blue"))).toBe(WIDTH)
		local blue, red = RoadMath.getEndpoints(seg)
		expectFuzzy(t, blue.WorldCFrame.Position, Vector3.new(-10, 0, -100))
		expectFuzzy(t, red.WorldCFrame.Position, Vector3.new(10, 0, 100))

		local target = Vector3.new(30, 0, 100)
		local solution = RoadMath.solveMove(seg, "Red", target)
		t.expect(solution.Size.X).toBe(88 + 40)
		local moved = makeSegment("Straight", solution.Size, solution.Pivot, solution.Flip)
		moved.WidthRed = 88
		local movedBlue, movedRed = RoadMath.getEndpoints(moved)
		expectFuzzy(t, movedBlue.WorldCFrame.Position, blue.WorldCFrame.Position)
		expectFuzzy(t, movedRed.WorldCFrame.Position, target)
	end)

	t.test("solveWidthChange: one end widening keeps both endpoints fixed", function()
		local seg = makeSegment("Straight", Vector3.new(100, 0, 200), CFrame.identity)
		local blue, red = RoadMath.getEndpoints(seg)
		local solution = RoadMath.solveWidthChange(seg, WIDTH, 88)
		local resized = makeSegment("Straight", solution.Size, solution.Pivot)
		resized.WidthRed = 88
		local newBlue, newRed = RoadMath.getEndpoints(resized)
		expectFuzzy(t, newBlue.WorldCFrame.Position, blue.WorldCFrame.Position)
		expectFuzzy(t, newRed.WorldCFrame.Position, red.WorldCFrame.Position)
	end)

	t.test("swappedLaneValues: lanes out/in stay with each geographic end", function()
		local seg = makeSegment("Straight", Vector3.new(WIDTH, 10, 200), CFrame.identity)
		local attrs = (seg.Model :: any).attrs
		attrs.LaneCountForward = 2
		attrs.LaneCountBackward = 1
		-- Plain road: forward and backward trade places
		local swapped = RoadMath.swappedLaneValues(seg)
		t.expect(swapped.LaneCountForward).toBe(1)
		t.expect(swapped.LaneCountBackward).toBe(2)
		t.expect(swapped.LaneCountForwardRed).toBe(nil)

		-- Lane change: blue 2/1, red 1/1. The old blue end (2 in, 1 out)
		-- becomes the red end: forward (out at red) = 1, backward (in) = 2
		attrs.LaneCountForwardRed = 1
		attrs.LaneCountBackwardRed = 1
		swapped = RoadMath.swappedLaneValues(seg)
		t.expect(swapped.LaneCountForwardRed).toBe(1)
		t.expect(swapped.LaneCountBackwardRed).toBe(2)
		t.expect(swapped.LaneCountForward).toBe(1)
		t.expect(swapped.LaneCountBackward).toBe(1)
	end)

	t.test("lane width change: ends can be different widths, centred", function()
		-- 1 + 1 lanes of 24 at the blue end, 30 at the red, sidewalks 8:
		-- widths 64 and 76, box 76
		local seg = makeSegment("Straight", Vector3.new(76, 0, 200), CFrame.identity)
		local attrs = (seg.Model :: any).attrs
		attrs.LaneWidth = 24
		attrs.SidewalkWidth = 8
		attrs.LaneCountForward = 1
		attrs.LaneCountBackward = 1
		t.expect(RoadMath.hasLaneWidthChange(seg)).toBe(false)
		-- -1 (the generator default) is unset
		attrs.LaneWidthRed = -1
		t.expect(RoadMath.hasLaneWidthChange(seg)).toBe(false)
		t.expect(RoadMath.laneWidthAttributeName(seg, "Red")).toBe("LaneWidth")

		attrs.LaneWidthRed = 30
		t.expect(RoadMath.hasLaneWidthChange(seg)).toBe(true)
		t.expect(RoadMath.laneWidthAttributeName(seg, "Red")).toBe("LaneWidthRed")
		t.expect(RoadMath.laneWidthAttributeName(seg, "Blue")).toBe("LaneWidth")
		t.expect(RoadMath.endLaneWidth(RoadMath.getEndpoint(seg, "Blue"))).toBe(24)
		t.expect(RoadMath.endLaneWidth(RoadMath.getEndpoint(seg, "Red"))).toBe(30)
		-- Curves ignore it
		local curve = makeSegment("Curve", Vector3.new(128, 0, 128), CFrame.identity);
		(curve.Model :: any).attrs = table.clone(attrs)
		t.expect(RoadMath.hasLaneWidthChange(curve)).toBe(false)

		-- Swapping the ends takes the widths with their geographic ends
		local swapped = RoadMath.swappedLaneValues(seg)
		t.expect(swapped.LaneWidth).toBe(30)
		t.expect(swapped.LaneWidthRed).toBe(24)
		attrs.LaneWidthRed = nil
		t.expect(RoadMath.swappedLaneValues(seg).LaneWidth).toBe(nil)
	end)

	t.test("laneChangeShift: the other direction's kerb stays put", function()
		local seg = makeSegment("Straight", Vector3.new(96, 0, 200), CFrame.identity)
		-- Red end faces +Z; looking out of it, right is -X. Driving on the
		-- left, the lanes leaving through red are on the +X side. Dropping
		-- one 24-stud lane there must keep the -X (right) kerb in place.
		local red = RoadMath.getEndpoint(seg, "Red")
		local right = red.WorldCFrame.RightVector
		local shift = RoadMath.laneChangeShift(red, true, -24)
		expectFuzzy(t, shift, Vector3.new(-12, 0, 0))
		local kerbBefore = red.WorldCFrame.Position + right * (96 / 2)
		local kerbAfter = red.WorldCFrame.Position + shift + right * (72 / 2)
		expectFuzzy(t, kerbAfter, kerbBefore)

		-- Blue end faces -Z (right is +X); gaining a lane entering through it
		-- (the right-hand side) keeps the left (-X) kerb in place
		local blue = RoadMath.getEndpoint(seg, "Blue")
		local blueRight = blue.WorldCFrame.RightVector
		local blueShift = RoadMath.laneChangeShift(blue, false, 24)
		local leftBefore = blue.WorldCFrame.Position - blueRight * (96 / 2)
		local leftAfter = blue.WorldCFrame.Position + blueShift - blueRight * (120 / 2)
		expectFuzzy(t, leftAfter, leftBefore);

		-- Driving on the right mirrors it
		(seg.Model :: any).attrs.DriveSide = "Right"
		expectFuzzy(t, RoadMath.laneChangeShift(red, true, -24), Vector3.new(12, 0, 0))
	end)

	--
	-- Y splits
	--

	local function makeSplit(attrs: { [string]: any }, length: number?): RoadMath.SegmentInfo
		local fake: any = { attrs = attrs }
		fake.GetAttribute = function(self, name)
			return self.attrs[name]
		end
		local layout = RoadMath.splitLayout(fake)
		return {
			Model = fake,
			Kind = "Split",
			Width = layout.StemWidth,
			Size = Vector3.new(layout.BoxWidth, 0, length or 240),
			Pivot = CFrame.identity,
			Flip = false,
			Split = layout,
		}
	end

	t.test("split: a two-way road separates into its two directions", function()
		local split = makeSplit({
			LaneWidth = 24,
			SidewalkWidth = 8,
			LaneCountForward = 2,
			LaneCountBackward = 2,
			SplitSeparation = 16,
		})
		local layout = assert(split.Split)
		-- Driving on the left, the left branch takes the forward lanes
		t.expect(layout.LeftForward).toBe(2)
		t.expect(layout.LeftBackward).toBe(0)
		t.expect(layout.RightForward).toBe(0)
		t.expect(layout.RightBackward).toBe(2)
		-- The split line is the centre line, at x = 0
		t.expect(layout.StemX).toBe(0)
		t.expect(layout.LeftX).toBe(40)
		t.expect(layout.RightX).toBe(-40)
		t.expect(layout.BoxWidth).toBe(144)

		local stem = RoadMath.getEndpoint(split, "Stem")
		expectFuzzy(t, stem.WorldCFrame.Position, Vector3.new(0, 0, -120))
		expectFuzzy(t, stem.WorldCFrame.LookVector, Vector3.new(0, 0, -1))
		local left = RoadMath.getEndpoint(split, "BranchLeft")
		expectFuzzy(t, left.WorldCFrame.Position, Vector3.new(40, 0, 120))
		expectFuzzy(t, left.WorldCFrame.LookVector, Vector3.new(0, 0, 1))
		t.expect(RoadMath.endpointWidth(left)).toBe(64)

		-- Lanes out/in at each end
		local lanesOut, lanesIn = RoadMath.getLaneCounts(left)
		t.expect(lanesOut).toBe(2)
		t.expect(lanesIn).toBe(0)
		lanesOut, lanesIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(split, "BranchRight"))
		t.expect(lanesOut).toBe(0)
		t.expect(lanesIn).toBe(2)
		lanesOut, lanesIn = RoadMath.getLaneCounts(stem)
		t.expect(lanesOut).toBe(2)
		t.expect(lanesIn).toBe(2)

		-- The gap between the branch roads' outer footway edges is the
		-- separation
		t.expect((layout.LeftX - 32) - (layout.RightX + 32)).toBe(16)
	end)

	t.test("split: a one-way road diverges, the smaller part to the left", function()
		local split = makeSplit({
			LaneWidth = 24,
			SidewalkWidth = 8,
			LaneCountForward = 3,
			LaneCountBackward = 0,
			SplitSeparation = 16,
		})
		local layout = assert(split.Split)
		t.expect(layout.LeftLanes).toBe(1)
		t.expect(layout.RightLanes).toBe(2)
		t.expect(layout.LeftForward).toBe(1)
		t.expect(layout.RightForward).toBe(2)
		-- The split line (x = 0) is one lane in from the stem's left edge
		t.expect(layout.StemX + 36 - 24).toBe(0)
		-- Stem roadway edges and branch positions
		t.expect(layout.LeftX).toBe(40)
		t.expect(layout.RightX).toBe(-28)
	end)

	t.test("split: branch lanes clamp, and follow the driving side", function()
		local split = makeSplit({
			LaneCountForward = 2,
			LaneCountBackward = 2,
			SplitLanesLeft = 9,
		})
		t.expect((split.Split :: any).LeftLanes).toBe(3)
		t.expect((split.Split :: any).RightLanes).toBe(1)

		local rightHand = makeSplit({
			LaneCountForward = 2,
			LaneCountBackward = 1,
			DriveSide = "Right",
		})
		-- Driving on the right, the left side carries the backward lanes
		t.expect((rightHand.Split :: any).LeftBackward).toBe(1)
		t.expect((rightHand.Split :: any).LeftForward).toBe(0)
		t.expect((rightHand.Split :: any).RightForward).toBe(2)
	end)

	--
	-- Roundabouts
	--

	local function sweeps(pieces: { RoadMath.HullPiece }): (number, { number })
		local total = 0
		local each = {}
		for _, piece in pieces do
			table.insert(each, piece.To - piece.From)
			total += piece.To - piece.From
		end
		return total, each
	end

	t.test("roundabout: island shapes parse, round-trip, and fall back to a circle", function()
		local circles = RoadMath.parseIslandShape("-90,-40,20; 90,-40,20;90,40,20;-90,40,20")
		t.expect(#circles).toBe(4)
		t.expect(circles[2].X).toBe(90)
		t.expect(RoadMath.serializeIslandShape(circles)).toBe("-90,-40,20;90,-40,20;90,40,20;-90,40,20")
		-- Garbage (or nothing) gives the default round island
		local fallback = RoadMath.parseIslandShape("not a shape")
		t.expect(#fallback).toBe(1)
		t.expect(fallback[1].Radius).toBe(60)
		-- Each call returns fresh circles, safe to edit
		fallback[1].Radius = 5
		t.expect(RoadMath.parseIslandShape(nil)[1].Radius).toBe(60)
	end)

	t.test("roundabout hull: circle, oval and rounded square", function()
		local pieces = RoadMath.roundaboutHull({ { X = 0, Z = 0, Radius = 60 } })
		t.expect(#pieces).toBe(1)
		t.expect(math.abs(sweeps(pieces) - 2 * math.pi) < 1e-6).toBe(true)

		pieces = RoadMath.roundaboutHull({ { X = -60, Z = 0, Radius = 45 }, { X = 60, Z = 0, Radius = 45 } })
		t.expect(#pieces).toBe(2)
		local total, each = sweeps(pieces)
		t.expect(math.abs(total - 2 * math.pi) < 1e-6).toBe(true)
		t.expect(math.abs(each[1] - math.pi) < 1e-6).toBe(true)

		pieces = RoadMath.roundaboutHull(RoadMath.parseIslandShape("-45,-45,20;45,-45,20;45,45,20;-45,45,20"))
		t.expect(#pieces).toBe(4)
		total, each = sweeps(pieces)
		t.expect(math.abs(total - 2 * math.pi) < 1e-6).toBe(true)
		for _, sweep in each do
			t.expect(math.abs(sweep - math.pi / 2) < 1e-6).toBe(true)
		end
	end)

	t.test("roundabout hull: unequal, contained and collinear circles", function()
		-- A big and a small circle: the big one wraps more than half way round
		local pieces = RoadMath.roundaboutHull({ { X = 0, Z = 0, Radius = 40 }, { X = 100, Z = 0, Radius = 10 } })
		t.expect(#pieces).toBe(2)
		local total = sweeps(pieces)
		t.expect(math.abs(total - 2 * math.pi) < 1e-6).toBe(true)
		local big = if pieces[1].Circle.Radius == 40 then pieces[1] else pieces[2]
		t.expect(big.To - big.From > math.pi).toBe(true)
		-- The arcs meet the tangent edges: each piece's end normal is the
		-- next piece's start normal (same direction)
		for m, piece in pieces do
			local nextPiece = pieces[m % #pieces + 1]
			local a, b = piece.To, nextPiece.From
			t.expect(math.abs(math.cos(a) - math.cos(b)) < 1e-6 and math.abs(math.sin(a) - math.sin(b)) < 1e-6).toBe(true)
		end

		-- A circle inside another doesn't shape the outline
		pieces = RoadMath.roundaboutHull({ { X = 0, Z = 0, Radius = 60 }, { X = 10, Z = 0, Radius = 5 } })
		t.expect(#pieces).toBe(1)
		t.expect(pieces[1].Circle.Radius).toBe(60)

		-- Three equal circles in a line: the middle one only touches the
		-- outline
		pieces = RoadMath.roundaboutHull({
			{ X = -60, Z = 0, Radius = 20 },
			{ X = 0, Z = 0, Radius = 20 },
			{ X = 60, Z = 0, Radius = 20 },
		})
		t.expect(#pieces).toBe(2)
	end)

	t.test("roundabout: box size covers the ring and footway", function()
		local fake: any = {
			attrs = {
				IslandShape = "-90,-40,20;90,-40,20;90,40,20;-90,40,20",
				RingLanes = 2,
				LaneWidth = 24,
				SidewalkWidth = 8,
				ApronWidth = 50,
				Arms = "",
			},
		}
		fake.GetAttribute = function(self, name)
			return self.attrs[name]
		end
		local layout = RoadMath.roundaboutLayout(fake)
		t.expect(layout.RingWidth).toBe(48)
		-- The apron stays within the smallest circle
		t.expect(layout.ApronWidth).toBe(19)
		-- Half extents: centre offset + radius + ring + footway
		local size = RoadMath.roundaboutSize(layout)
		t.expect(size.X).toBe(2 * (90 + 20 + 48 + 8))
		t.expect(size.Z).toBe(2 * (40 + 20 + 48 + 8))
	end)

	local function makeRoundabout(attrs: { [string]: any }): RoadMath.SegmentInfo
		local fake: any = { attrs = attrs }
		fake.GetAttribute = function(self, name)
			return self.attrs[name]
		end
		local layout = RoadMath.roundaboutLayout(fake)
		return {
			Model = fake,
			Kind = "Roundabout",
			Width = layout.RingWidth,
			Size = RoadMath.roundaboutSize(layout),
			Pivot = CFrame.identity,
			Flip = false,
			Roundabout = layout,
		}
	end

	t.test("roundabout arms: parse, and meet the outline along its normal", function()
		local arms = RoadMath.parseArms("0,1,1;90,2,1;45,0,0;junk")
		t.expect(#arms).toBe(3)
		-- No lanes at all becomes one each way
		t.expect(arms[3].Exit).toBe(1)
		t.expect(arms[3].Entry).toBe(1)
		t.expect(RoadMath.serializeArms(arms)).toBe("0,1,1;90,2,1;45,1,1")

		-- A rectangle's side: hit straight on, normal square to it
		local stations = RoadMath.roundaboutStations(RoadMath.parseIslandShape("-90,-40,20;90,-40,20;90,40,20;-90,40,20"))
		local x, z, nx, nz = RoadMath.outlineHit(stations, 0, 0, 0)
		t.expect(math.abs(x - 110) < 1e-6 and math.abs(z) < 1e-6).toBe(true)
		t.expect(math.abs(nx - 1) < 1e-6 and math.abs(nz) < 1e-6).toBe(true)
	end)

	t.test("roundabout arms: ends, widths and lanes", function()
		local roundabout = makeRoundabout({
			IslandShape = "0,0,60",
			RingLanes = 2,
			LaneWidth = 24,
			SidewalkWidth = 8,
			ArmLength = 120,
			Arms = "0,1,1;90,2,1",
		})
		local ids = RoadMath.endpointIds(roundabout)
		t.expect(#ids).toBe(2)
		t.expect(ids[2]).toBe("Arm2")
		t.expect(table.find(RoadMath.pickableEndpointIds(roundabout), "Centre") ~= nil).toBe(true)

		-- Arm 1 runs out along +X from the ring's outer edge (60 + 48) for
		-- 120, centred on its axis (one lane each way)
		local first = RoadMath.getEndpoint(roundabout, "Arm1")
		expectFuzzy(t, first.WorldCFrame.Position, Vector3.new(228, 0, 0))
		expectFuzzy(t, first.WorldCFrame.LookVector, Vector3.new(1, 0, 0))
		t.expect(RoadMath.endpointWidth(first)).toBe(64)
		local lanesOut, lanesIn = RoadMath.getLaneCounts(first)
		t.expect(lanesOut).toBe(1)
		t.expect(lanesIn).toBe(1)

		-- Arm 2 runs along +Z; with 2 exit lanes to 1 entry its roadway's
		-- centre sits half a lane to the exit side (the left looking out,
		-- driving on the left: +X when facing +Z)
		local second = RoadMath.getEndpoint(roundabout, "Arm2")
		expectFuzzy(t, second.WorldCFrame.Position, Vector3.new(12, 0, 228))
		t.expect(RoadMath.endpointWidth(second)).toBe(3 * 24 + 16)
		lanesOut, lanesIn = RoadMath.getLaneCounts(second)
		t.expect(lanesOut).toBe(2)
		t.expect(lanesIn).toBe(1)

		-- The box takes in the arms
		t.expect(roundabout.Size.X >= 2 * (228 + 0)).toBe(true)
		t.expect(roundabout.Size.Z >= 2 * 228).toBe(true)
	end)

	t.test("roundabout arms: own lengths and skew", function()
		local arms = RoadMath.parseArms("0,1,1,200,30;90,1,1,0,80")
		t.expect(arms[1].Length).toBe(200)
		t.expect(arms[1].Skew).toBe(30)
		-- Skew is limited to 45 degrees either way
		t.expect(arms[2].Skew).toBe(45)
		-- Extra fields are only written when set
		t.expect(RoadMath.serializeArms(arms)).toBe("0,1,1,200,30;90,1,1,0,45")
		t.expect(RoadMath.serializeArms({ { Angle = 10, Exit = 1, Entry = 1, Length = 0, Skew = 0 } })).toBe("10,1,1")

		local roundabout = makeRoundabout({
			IslandShape = "0,0,60",
			RingLanes = 2,
			LaneWidth = 24,
			SidewalkWidth = 8,
			ArmLength = 120,
			Arms = "0,1,1,200,30",
		})
		local arm = (roundabout.Roundabout :: any).Arms[1]
		t.expect(arm.Length).toBe(200)
		-- The arm leaves the island at (60, 0) swung 30 degrees off the +X
		-- normal; its mouth is where that axis crosses the ring's outer edge
		-- (48 across the ring, taken as straight)
		local direction = Vector3.new(math.cos(math.rad(30)), 0, math.sin(math.rad(30)))
		local mouth = Vector3.new(60, 0, 0) + direction * (48 / math.cos(math.rad(30)))
		expectFuzzy(t, Vector3.new(arm.MouthX, 0, arm.MouthZ), mouth)
		local ending = RoadMath.getEndpoint(roundabout, "Arm1")
		expectFuzzy(t, ending.WorldCFrame.Position, mouth + direction * 200)
		expectFuzzy(t, ending.WorldCFrame.LookVector, direction)
	end)

	t.test("roundabout arms: individual splitter widths", function()
		local arms = RoadMath.parseArms("0,1,1;90,1,1,0,0,0,,0;180,1,1,0,0,0,,24.5")
		t.expect(arms[1].Splitter).toBe(nil)
		-- Zero is a real width, not "unset"
		t.expect(arms[2].Splitter).toBe(0)
		t.expect(arms[3].Splitter).toBe(24.5)
		t.expect(RoadMath.serializeArms(arms)).toBe("0,1,1;90,1,1,0,0,0,,0;180,1,1,0,0,0,,24.5")

		-- Arms without their own width use the roundabout's
		local model = makeRoundabout({ IslandShape = "0,0,60", Arms = "0,1,1;90,1,1,0,0,0,,4", SplitterWidth = 10 })
		local layout = assert(model.Roundabout)
		t.expect(layout.Arms[1].Splitter).toBe(10)
		t.expect(layout.Arms[1].SplitterOverride).toBe(nil)
		t.expect(layout.Arms[2].Splitter).toBe(4)
		t.expect(layout.Arms[2].SplitterOverride).toBe(4)
	end)

	t.test("roundabout arms: flares and lane arrows", function()
		local arms = RoadMath.parseArms("0,1,2,0,0,1,la/x/AR;90,1,0,0,0,2;180,1,1,0,0,9")
		t.expect(arms[1].Flare).toBe(1)
		-- Arrow fields keep only arrow letters and separators
		t.expect(arms[1].Arrows).toBe("LA//AR")
		-- An exit-only arm can't flare; flares are limited
		t.expect(arms[2].Flare).toBe(0)
		t.expect(arms[3].Flare).toBe(RoadMath.MAX_ARM_FLARE)
		t.expect(RoadMath.serializeArms(arms)).toBe("0,1,2,0,0,1,LA//AR;90,1,0;180,1,1,0,0,3")
		t.expect(RoadMath.serializeArms({ { Angle = 0, Exit = 1, Entry = 1, Length = 0, Skew = 0, Flare = 0, Arrows = "L/R" } }))
			.toBe("0,1,1,0,0,0,L/R")

		-- Automatic arrows: none on one lane; two lanes are left-and-ahead
		-- and right; more have left, aheads and right
		t.expect(RoadMath.laneArrows("", 1)[1]).toBe("")
		local two = RoadMath.laneArrows(nil, 2)
		t.expect(two[1]).toBe("LA")
		t.expect(two[2]).toBe("R")
		local four = RoadMath.laneArrows("", 4)
		t.expect(table.concat(four, "/")).toBe("L/A/A/R")
		-- Stored arrows: letters tidied into L, A, R order, missing lanes blank
		local stored = RoadMath.laneArrows("RA/-", 3)
		t.expect(stored[1]).toBe("AR")
		t.expect(stored[2]).toBe("")
		t.expect(stored[3]).toBe("")
		t.expect(RoadMath.serializeLaneArrows(stored)).toBe("AR/-/-")

		-- A flare doesn't move the arm's end
		local plain = makeRoundabout({ IslandShape = "0,0,60", Arms = "0,1,1" })
		local flared = makeRoundabout({ IslandShape = "0,0,60", Arms = "0,1,1,0,0,2" })
		expectFuzzy(t, RoadMath.getEndpoint(flared, "Arm1").WorldCFrame.Position,
			RoadMath.getEndpoint(plain, "Arm1").WorldCFrame.Position)
	end)
end
