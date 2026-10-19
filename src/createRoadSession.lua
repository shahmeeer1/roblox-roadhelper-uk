--!strict
--[[
	createRoadSession: The active RoadHelper tool session.

	Mounts a DraggerFramework DraggerToolComponent with a custom handle list:
	- EndpointPickHandles: on-demand endpoint picking under the cursor
	- EndpointMoveHandles: move the selected endpoint (resizes segments)
	- EndpointRotateHandles: edit the Adjust dir/grade/bank angles
	- AddHandles: append segments off an open endpoint
	- MarkingHandles: drawing road markings by hand (Draw Markings mode,
	  when the others step aside)

	The session tracks the selected endpoint as a (model, endpoint id) pair and
	re-derives world frames from live instance state, so external edits and
	undo/redo stay consistent. All edits are wrapped in ChangeHistoryService
	recordings.
]]

local CoreGui = game:GetService("CoreGui")
local ChangeHistoryService = game:GetService("ChangeHistoryService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Selection = game:GetService("Selection")

local Packages = script.Parent.Parent.Packages

local DraggerFramework = require(Packages.DraggerFramework)
local DraggerSchemaCore = require(Packages.DraggerSchemaCore)
local Roact = require(Packages.Roact)
local Signal = require(Packages.Signal)

local DraggerContext_PluginImpl = (require :: any)(DraggerFramework.Implementation.DraggerContext_PluginImpl)
local DraggerToolComponent = (require :: any)(DraggerFramework.DraggerTools.DraggerToolComponent)

local RoadMath = require("./RoadMath")
local RoadDefaults = require("./RoadDefaults")
local Markings = require("./Markings")
local EndpointPickHandles = require("./Handles/EndpointPickHandles")
local DeleteExitHandles = require("./Handles/DeleteExitHandles")
local PartialRotateHandleView = require("./Dragger/PartialRotateHandleView")
local EndpointMoveHandles = require("./Handles/EndpointMoveHandles")
local EndpointRotateHandles = require("./Handles/EndpointRotateHandles")
local AddHandles = require("./Handles/AddHandles")
local IslandShapeHandles = require("./Handles/IslandShapeHandles")
local MarkingHandles = require("./Handles/MarkingHandles")

local REFRESH_INTERVAL = 0.25
local JOINT_SEARCH_RADIUS = 10
local REBIND_SEARCH_RADIUS = 8
local REBIND_TOLERANCE = 2

local ADJUST_AXES: { RoadMath.AdjustAxis } = { "Dir", "Grade", "Bank" }

export type EndpointRef = {
	Model: Model,
	Id: RoadMath.EndpointId,
}

export type SelectionState = {
	Kind: "none",
} | {
	Kind: "open" | "closed",
	SegmentKind: RoadMath.SegmentKind,
	EndpointId: RoadMath.EndpointId,
	OtherSegmentKind: RoadMath.SegmentKind?,
	Dir: number,
	Grade: number,
	Bank: number,
	Blend: boolean,
	HaveLaneMarkings: boolean,
	TextureLaneMarkings: boolean,
	MaxAngle: number,
	-- Lanes leaving / entering the segment through the selected end (for
	-- intersections, on the selected exit's road)
	LanesOut: number,
	LanesIn: number,
	-- Lane changes (straights only): whether the segment can have different
	-- lanes at each end, whether it currently has the same at both, whether
	-- the counts actually differ, whether the selected end's counts can be
	-- edited now, and which side lanes end/start on
	CanChangeLanes: boolean,
	SameLanesBothEnds: boolean,
	LanesDiffer: boolean,
	LaneCountsEditable: boolean,
	LaneChangeSide: "Offside" | "Nearside",
	SplitBranchLanes: number?,
	SplitTotalLanes: number?,
	SplitSeparation: number,
	SplitLength: number,
	MiniRoundabout: boolean,
	MiniRoundaboutRaised: boolean,
	MiniRoundaboutDiameter: number,
	RoundaboutCorners: number?,
	SelectedCorner: number?,
	SelectedCornerRadius: number?,
	RingLanes: number?,
	ApronWidth: number?,
	ArmCount: number?,
	ArmLength: number?,
	SplitterWidth: number?,
	EntryKerbRadius: number?,
	ArmIndex: number?,
	ArmExit: number?,
	ArmEntry: number?,
	ArmAngle: number?,
	ArmOwnLength: number?,
	ArmSkew: number?,
	ArmFlare: number?,
	-- The selected arm's entry lanes' arrows, left to right, and whether
	-- they're automatic
	ArmArrows: { string }?,
	ArmArrowsAuto: boolean?,
	FlareLength: number?,
	-- "Concentric", "Spiral" or "None" lane lines round the ring
	RingMarkings: string?,
	SplitterStyle: string?,
	LaneWidth: number,
	SidewalkWidth: number,
	IntersectionAngle: number,
	-- Nominal corner curve radius of an intersection (half the bounding box
	-- size in excess of the roads' widths and crosswalks; exact at 90 degrees)
	CornerRadius: number,
	CrossingWidth: number,
}

-- The Draw Markings tool's state, for the panel: whether it's on, the line
-- being drawn, the selected line and point, and the style options shown
-- (the selected line's, or those new lines get)
export type MarkingState = {
	Active: boolean,
	-- "Line" (draw a line) or "Zone" (divide a stretch of road into lanes)
	Tool: "Line" | "Zone",
	-- Zone tool: the lanes to divide into, whether the sides are drawn too,
	-- and which side is being drawn (1 or 2)
	ZoneLanes: number,
	ZoneEdges: boolean,
	ZoneSide: number,
	Drawing: boolean,
	DraftPoints: number,
	LineSelected: boolean,
	PointCount: number,
	SelectedPoint: number?,
	Style: Markings.Style,
	Colour: Markings.Colour,
	Curved: boolean,
	Width: number,
	Dash: number,
	Gap: number,
}

local function createFixedSelection(onCleared: () -> ())
	local selectionChangedSignal = Signal.new()
	return {
		Get = function()
			return {}
		end,
		Set = function(newSelection, _hint)
			-- The dragger framework clicking on empty space clears the
			-- selection: treat that as deselecting the endpoint.
			if #newSelection == 0 then
				onCleared()
			end
			task.defer(function()
				selectionChangedSignal:Fire()
			end)
		end,
		SelectionChanged = selectionChangedSignal,
	}
end

local function createRoadSchema(getFocusCFrame: () -> CFrame)
	local schema = table.clone(DraggerSchemaCore)
	schema.getMouseTarget = function()
		-- Clicks which don't hit one of our handles hit nothing
		return nil
	end
	schema.addUndoWaypoint = function()
		-- We manage undo with explicit recordings instead
	end
	schema.SelectionInfo = {
		new = function(context, selection)
			return {
				isEmpty = function(self)
					return false
				end,
				getBoundingBox = function(self)
					return getFocusCFrame(), Vector3.zero, Vector3.zero
				end,
				getAllAttachments = function(self)
					return {}
				end,
				getObjectsToTransform = function(self)
					return {}, {}, {}
				end,
				getBasisObject = function(self)
					return nil
				end,
				getOriginalCFrameMap = function(self)
					return {}
				end,
				getTransformedCopy = function(self, globalTransform)
					return self
				end,
			}
		end,
	} :: any
	return schema
end

local GENERATOR_MODULE_NAMES: { [RoadMath.SegmentKind]: string } = {
	Straight = "StraightRoadGenerator",
	Curve = "CurveRoadGenerator",
	Intersection = "RoadIntersectionGenerator",
	Split = "RoadSplitGenerator",
	Roundabout = "RoundaboutGenerator",
}

-- Build a brand new segment from the generator templates packaged inside the
-- plugin, so RoadHelper works even in a place with no road segments yet.
local Templates = script.Parent.Templates
local function createFallbackSegmentModel(kind: RoadMath.SegmentKind): Model?
	local ok, model = pcall(function()
		return Instance.new("ProceduralModel" :: any) :: any
	end)
	if not ok or not model then
		warn("RoadHelper: This Studio version doesn't support creating ProceduralModels.")
		return nil
	end
	model.Name = if kind == "Straight"
		then "StraightRoad"
		elseif kind == "Curve" then "CurveRoad"
		elseif kind == "Split" then "RoadSplit"
		elseif kind == "Roundabout" then "Roundabout"
		else "RoadIntersection"
	local generator = Templates:FindFirstChild(GENERATOR_MODULE_NAMES[kind])
	if generator then
		local generatorCopy = generator:Clone()
		generatorCopy.Parent = model
		-- The engine binds the model to its generator through this property;
		-- it does not discover the module by name.
		model.Generator = generatorCopy
	end
	return model :: Model
end

-- Attributes describing segment geometry rather than appearance; these are
-- not copied onto newly added segments.
local GEOMETRY_ATTRIBUTES = {
	Flip = true,
	AdjustBlueDir = true,
	AdjustBlueGrade = true,
	AdjustBlueBank = true,
	AdjustRedDir = true,
	AdjustRedGrade = true,
	AdjustRedBank = true,
	-- Lane counts depend on which way each segment runs, so they are set
	-- explicitly to match travel directions across the joint
	-- (matchLanesAcrossJoint) rather than copied; and new segments start
	-- with the same lanes at both ends
	LaneCountForward = true,
	LaneCountBackward = true,
	LaneCountForwardRed = true,
	LaneCountBackwardRed = true,
	-- Intersection lane layout (translated onto the road's lane attributes
	-- when extending an intersection end, not copied directly)
	LaneCountForwardX = true,
	LaneCountBackwardX = true,
	LaneCountForwardZ = true,
	LaneCountBackwardZ = true,
	LaneWidthX = true,
	LaneWidthZ = true,
	IntersectionAngle = true,
	ThroughRoad = true,
	-- Y split layout
	SplitLanesLeft = true,
	SplitSeparation = true,
	-- Roundabout layout and island
	IslandShape = true,
	RingLanes = true,
	Arms = true,
	ArmLength = true,
	SplitterWidth = true,
	EntryKerbRadius = true,
	FlareLength = true,
	ApronWidth = true,
	ApronMaterial = true,
	ApronColor = true,
	IslandMaterial = true,
	IslandColor = true,
	-- Mini roundabout (an intersection variant)
	MiniRoundabout = true,
	MiniRoundaboutRaised = true,
	MiniRoundaboutDiameter = true,
	MiniRoundaboutCentreColor = true,
}

-- Give a new road segment the same lanes at both ends (a clone of a
-- lane-change straight would otherwise keep its red-end counts)
local function clearLaneChange(model: Model)
	for _, name in RoadMath.RED_LANE_OVERRIDES do
		model:SetAttribute(name, nil)
	end
end

-- Give one end of a (typically new) segment the lanes matching the end it
-- joins: the traffic leaving through one end enters through the other
local function matchLanesAcrossJoint(mate: RoadMath.Endpoint, model: Model, kind: RoadMath.SegmentKind, id: RoadMath.EndpointId)
	local mateOut, mateIn = RoadMath.getLaneCounts(mate)
	local outName, inName = RoadMath.laneAttributeNames(kind, id)
	model:SetAttribute(outName, mateIn)
	model:SetAttribute(inName, mateOut)
end

local function createRoadSession(plugin: Plugin)
	local session = {}
	local changeSignal = Signal.new()

	--------------------------------------------------------------------------
	-- State
	--------------------------------------------------------------------------

	local selectedRef: EndpointRef? = nil
	local activeRecording: string? = nil

	-- Last successfully resolved state of the selection, used to re-bind it
	-- when undo/redo destroys and recreates the selected segment's instance.
	local lastKnownPosition: Vector3? = nil
	local lastKnownKind: RoadMath.SegmentKind? = nil

	-- Resolve an endpoint ref against live instance state
	local function resolveEndpoint(ref: EndpointRef?): RoadMath.Endpoint?
		if not ref then
			return nil
		end
		if not ref.Model.Parent then
			return nil
		end
		local info = RoadMath.getSegmentInfo(ref.Model)
		-- (The end may be gone: a roundabout arm removed by undo, say)
		if not info or not table.find(RoadMath.pickableEndpointIds(info), ref.Id) then
			return nil
		end
		return RoadMath.getEndpoint(info, ref.Id)
	end

	-- Find an endpoint of the given end color (and optionally segment kind)
	-- close to a world position. Used to re-bind the selection after undo and
	-- redo destroy and recreate segment instances.
	local function findEndpointNear(position: Vector3, kind: RoadMath.SegmentKind?, id: RoadMath.EndpointId): RoadMath.Endpoint?
		local parts = workspace:GetPartBoundsInRadius(position, REBIND_SEARCH_RADIUS)
		local best: RoadMath.Endpoint? = nil
		local bestDistance = REBIND_TOLERANCE
		local seen: { [Model]: boolean } = {}
		for _, part in parts do
			local segment = RoadMath.segmentFromDescendant(part)
			if segment and not seen[segment.Model] then
				seen[segment.Model] = true
				if kind and segment.Kind ~= kind then
					continue
				end
				if not table.find(RoadMath.pickableEndpointIds(segment), id) then
					continue
				end
				local endpoint = RoadMath.getEndpoint(segment, id)
				local distance = (endpoint.WorldCFrame.Position - position).Magnitude
				if distance <= bestDistance then
					bestDistance = distance
					best = endpoint
				end
			end
		end
		return best
	end

	local function tryRebindSelection(): RoadMath.Endpoint?
		local ref = selectedRef
		local position = lastKnownPosition
		if not ref or not position then
			return nil
		end
		return findEndpointNear(position, lastKnownKind, ref.Id)
	end

	local function getSelectedEndpoint(): RoadMath.Endpoint?
		local endpoint = resolveEndpoint(selectedRef)
		if not endpoint and selectedRef then
			-- The selection is sticky: don't clear it just because the
			-- instance can't currently be resolved (mid-undo, or destroyed
			-- and about to be recreated by redo); try to re-bind instead and
			-- otherwise keep waiting.
			endpoint = tryRebindSelection()
			if endpoint then
				selectedRef = { Model = endpoint.Segment.Model, Id = endpoint.Id }
			end
		end
		if endpoint then
			lastKnownPosition = endpoint.WorldCFrame.Position
			lastKnownKind = endpoint.Segment.Kind
		end
		return endpoint
	end

	type SelectionSnapshot = {
		Position: Vector3,
		Kind: RoadMath.SegmentKind,
		Id: RoadMath.EndpointId,
	}?

	local function snapshotSelection(): SelectionSnapshot
		local endpoint = resolveEndpoint(selectedRef)
		if not endpoint then
			return nil
		end
		return {
			Position = endpoint.WorldCFrame.Position,
			Kind = endpoint.Segment.Kind,
			Id = endpoint.Id,
		}
	end

	local function restoreSelection(snapshot: SelectionSnapshot)
		if not snapshot then
			selectedRef = nil
			lastKnownPosition = nil
			lastKnownKind = nil
			return
		end
		lastKnownPosition = snapshot.Position
		lastKnownKind = snapshot.Kind
		local endpoint = findEndpointNear(snapshot.Position, snapshot.Kind, snapshot.Id)
		if endpoint then
			selectedRef = { Model = endpoint.Segment.Model, Id = endpoint.Id }
		else
			-- Leave a stale placeholder ref so the sticky re-bind machinery
			-- keeps looking for an endpoint at this position (e.g. redo may
			-- not have recreated the instance quite yet).
			selectedRef = { Model = Instance.new("Model"), Id = snapshot.Id }
		end
	end

	-- Selection history synchronized with the undo stack: operations which
	-- change the selection (the adds) record what was selected before and
	-- after, keyed by their undo waypoint name, so undoing an add brings the
	-- previous selection back and redoing reselects the added segment's end.
	type SelectionHistoryEntry = {
		Name: string,
		Before: SelectionSnapshot,
		After: SelectionSnapshot,
	}
	local undoSelectionStack: { SelectionHistoryEntry } = {}
	local redoSelectionStack: { SelectionHistoryEntry } = {}

	local function pushSelectionHistory(name: string, before: SelectionSnapshot, after: SelectionSnapshot)
		table.insert(undoSelectionStack, { Name = name, Before = before, After = after })
		table.clear(redoSelectionStack)
	end

	-- Find the mated partner of an endpoint with an on-demand spatial query
	-- around it, so we never have to eagerly inspect the whole place.
	local function partnerOfEndpoint(endpoint: RoadMath.Endpoint): RoadMath.Endpoint?
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { endpoint.Segment.Model }
		local parts = workspace:GetPartBoundsInRadius(
			endpoint.WorldCFrame.Position, JOINT_SEARCH_RADIUS, params)
		local candidates: { RoadMath.SegmentInfo } = {}
		local seen: { [Model]: boolean } = {}
		for _, part in parts do
			local segment = RoadMath.segmentFromDescendant(part)
			if segment and not seen[segment.Model] then
				seen[segment.Model] = true
				table.insert(candidates, segment)
			end
		end
		return RoadMath.findJoint(endpoint, candidates)
	end

	local function getPartnerEndpoint(): RoadMath.Endpoint?
		local selected = getSelectedEndpoint()
		return if selected then partnerOfEndpoint(selected) else nil
	end

	-- Endpoint snapping: while free-dragging an endpoint or drag-placing a new
	-- segment, pull the requested position onto a nearby open end of another
	-- segment so that ends mate exactly.
	local SNAP_DISTANCE = 12

	local function isEndpointOpen(endpoint: RoadMath.Endpoint, excludeSet: { [Model]: boolean }): boolean
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local exclusions: { Instance } = { endpoint.Segment.Model }
		for model in excludeSet do
			table.insert(exclusions, model)
		end
		params.FilterDescendantsInstances = exclusions
		local parts = workspace:GetPartBoundsInRadius(
			endpoint.WorldCFrame.Position, JOINT_SEARCH_RADIUS, params)
		local candidates: { RoadMath.SegmentInfo } = {}
		local seen: { [Model]: boolean } = {}
		for _, part in parts do
			local segment = RoadMath.segmentFromDescendant(part)
			if segment and not seen[segment.Model] and not excludeSet[segment.Model] then
				seen[segment.Model] = true
				table.insert(candidates, segment)
			end
		end
		return RoadMath.findJoint(endpoint, candidates) == nil
	end

	local function snapToOpenEndpoint(
		position: Vector3,
		movingModels: { Model },
		excludeEndpoint: EndpointRef?
	): (Vector3, RoadMath.Endpoint?)
		local excludeSet: { [Model]: boolean } = {}
		local exclusions: { Instance } = {}
		for _, model in movingModels do
			excludeSet[model] = true
			table.insert(exclusions, model)
		end
		local params = OverlapParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = exclusions
		-- Any segment whose end is within snap range has parts near the end,
		-- so a slightly padded part query is enough to find all candidates
		local parts = workspace:GetPartBoundsInRadius(position, SNAP_DISTANCE + 4, params)
		local best: RoadMath.Endpoint? = nil
		local bestDistance = SNAP_DISTANCE
		local seen: { [Model]: boolean } = {}
		for _, part in parts do
			local segment = RoadMath.segmentFromDescendant(part)
			if not segment or seen[segment.Model] or excludeSet[segment.Model] then
				continue
			end
			seen[segment.Model] = true
			for _, id in RoadMath.endpointIds(segment) do
				if excludeEndpoint and excludeEndpoint.Model == segment.Model and excludeEndpoint.Id == id then
					continue
				end
				local endpoint = RoadMath.getEndpoint(segment, id)
				local distance = (endpoint.WorldCFrame.Position - position).Magnitude
				if distance <= bestDistance and isEndpointOpen(endpoint, excludeSet) then
					bestDistance = distance
					best = endpoint
				end
			end
		end
		if best then
			return best.WorldCFrame.Position, best
		end
		return position, nil
	end

	--------------------------------------------------------------------------
	-- Dragger context and schema
	--------------------------------------------------------------------------

	local function clearSelection()
		if not selectedRef then
			return
		end
		selectedRef = nil
		lastKnownPosition = nil
		lastKnownKind = nil
		changeSignal:Fire()
	end

	local fixedSelection = createFixedSelection(clearSelection)

	local draggerContext = DraggerContext_PluginImpl.new(
		plugin,
		game,
		settings(),
		fixedSelection
	)

	local schema = createRoadSchema(function()
		local endpoint = getSelectedEndpoint()
		return if endpoint then endpoint.WorldCFrame else CFrame.identity
	end)

	-- Whether a handle drag gesture (move/rotate/add) is in progress
	local gestureActive = false

	-- Nudge the dragger framework to re-read state. NEVER do this during an
	-- active gesture: the framework responds to selection changes by
	-- cancelling and re-initializing the current handle drag (re-invoking
	-- mouseDown!), which restarts the gesture and can recurse infinitely when
	-- fired from inside a handle callback. Deferred + coalesced for safety
	-- against any other synchronous re-entrance.
	local updateQueued = false
	local function updateDragger()
		if gestureActive or updateQueued then
			return
		end
		updateQueued = true
		task.defer(function()
			updateQueued = false
			if not gestureActive then
				fixedSelection.SelectionChanged:Fire()
			end
		end)
	end

	--------------------------------------------------------------------------
	-- Undo recordings
	--------------------------------------------------------------------------

	local activeRecordingName: string? = nil
	local function beginRecording(name: string)
		if activeRecording then
			return
		end
		activeRecordingName = "RoadHelper " .. name
		local recording = ChangeHistoryService:TryBeginRecording("RoadHelper " .. name)
		if not recording then
			-- Without a recording every individual property change gets auto
			-- committed as its own undo waypoint, fragmenting undo. This
			-- happens when some other plugin (or a previous error) left a
			-- recording dangling; nothing we can do but flag it clearly.
			warn("RoadHelper: Couldn't begin an undo recording (another recording is in progress). " ..
				"Undo will be fragmented for this gesture. If this persists, restarting Studio clears stuck recordings.")
		end
		activeRecording = recording :: any
	end

	local function finishRecording()
		if activeRecording then
			ChangeHistoryService:FinishRecording(activeRecording, Enum.FinishRecordingOperation.Commit)
			activeRecording = nil
		end
	end

	-- Abandon the recording, undoing what it recorded
	local function cancelRecording()
		if activeRecording then
			ChangeHistoryService:FinishRecording(activeRecording, Enum.FinishRecordingOperation.Cancel)
			activeRecording = nil
		end
	end

	--------------------------------------------------------------------------
	-- Edit operations
	--------------------------------------------------------------------------

	local function applySolution(model: Model, solution: RoadMath.MoveSolution)
		local wasFlipped = model:GetAttribute("Flip") == true
		if solution.SwapEnds then
			-- The segment was rotated 180 degrees and its ends traded roles:
			-- move the adjust values to follow their geographic ends.
			local swapped = RoadMath.swappedAdjustValues(function(name: string)
				local value = model:GetAttribute(name)
				return if typeof(value) == "number" then value else 0
			end)
			for name, value in swapped do
				model:SetAttribute(name, value)
			end
			-- Travel through the segment reversed too: its lanes follow
			local info = RoadMath.getSegmentInfo(model)
			if info then
				for name, value in RoadMath.swappedLaneValues(info) do
					model:SetAttribute(name, value)
				end
			end
		end
		if wasFlipped ~= solution.Flip then
			-- Flipping changes the world meaning of some adjust attributes
			-- (curve grades scale with the climb sign; straight dirs mirror
			-- with the path): negate those so each face's actual world
			-- geometry is preserved through the flip.
			local info = RoadMath.getSegmentInfo(model)
			if info then
				local names = if info.Kind == "Curve"
					then { "AdjustBlueGrade", "AdjustRedGrade" }
					else { "AdjustBlueDir", "AdjustRedDir" }
				for _, name in names do
					local value = model:GetAttribute(name)
					if typeof(value) == "number" and value ~= 0 then
						model:SetAttribute(name, -value)
					end
				end
			end
		end
		(model :: any).Size = solution.Size
		model:SetAttribute("Flip", solution.Flip)
		model:PivotTo(solution.Pivot)
	end

	-- Apply a move solution and keep endpoint references coherent: a SwapEnds
	-- solution re-colors the segment's ends, so any refs we hold pointing at
	-- them (the drag target itself and possibly the selection) must flip too.
	local function applySolutionToRef(ref: EndpointRef, solution: RoadMath.MoveSolution)
		applySolution(ref.Model, solution)
		if solution.SwapEnds then
			local newId: RoadMath.EndpointId = if ref.Id == "Blue" then "Red" else "Blue"
			local selected = selectedRef
			if selected and selected ~= ref and selected.Model == ref.Model and selected.Id == ref.Id then
				selected.Id = newId
			end
			ref.Id = newId
			changeSignal:Fire()
		end
	end

	local function setAdjustAttribute(model: Model, id: RoadMath.EndpointId, axis: RoadMath.AdjustAxis, value: number)
		local name = RoadMath.adjustAttributeName(id, axis)
		local current = model:GetAttribute(name)
		if current ~= value and not (current == nil and value == 0) then
			model:SetAttribute(name, value)
		end
	end

	local function captureAdjust(ref: EndpointRef): { [RoadMath.AdjustAxis]: number }
		local values = {}
		for _, axis in ADJUST_AXES do
			local value = ref.Model:GetAttribute(RoadMath.adjustAttributeName(ref.Id, axis))
			values[axis] = if typeof(value) == "number" then value else 0
		end
		return values
	end

	local function restoreAdjust(ref: EndpointRef, saved: { [RoadMath.AdjustAxis]: number })
		for axis, value in saved do
			setAdjustAttribute(ref.Model, ref.Id, axis :: RoadMath.AdjustAxis, value)
		end
	end

	-- When a dragged road end snaps onto another open end, rotate the road's
	-- end face to mate flush: its Dir adjust takes up the yaw between its
	-- nominal frame and the mate's actual face (however the two bounding
	-- boxes are aligned), and its grade/bank match the mate's (zero for the
	-- flat intersections).
	local function alignEndFaceToMate(ref: EndpointRef, mate: RoadMath.Endpoint)
		local info = RoadMath.getSegmentInfo(ref.Model)
		if not info or RoadMath.isJunction(info.Kind) then
			return
		end
		local endpoint = RoadMath.getEndpoint(info, ref.Id)
		local up = endpoint.WorldCFrame.UpVector
		local nominal = endpoint.WorldCFrame.LookVector
		local desired = -RoadMath.actualOutwardDirection(mate)
		local n = nominal - up * nominal:Dot(up)
		local d = desired - up * desired:Dot(up)
		if n.Magnitude < 1e-4 or d.Magnitude < 1e-4 then
			return
		end
		n, d = n.Unit, d.Unit
		local angle = math.deg(math.atan2(n:Cross(d):Dot(up), n:Dot(d)))
		angle = math.round(angle * 100) / 100
		setAdjustAttribute(ref.Model, ref.Id, "Dir", angle / RoadMath.flipFactor(info, "Dir"))
		if RoadMath.isJunction(mate.Segment.Kind) then
			setAdjustAttribute(ref.Model, ref.Id, "Grade", 0)
			setAdjustAttribute(ref.Model, ref.Id, "Bank", 0)
		else
			local matching = RoadMath.matchingAdjust(mate, ref.Id)
			setAdjustAttribute(ref.Model, ref.Id, "Grade", matching.Grade / RoadMath.flipFactor(info, "Grade"))
			setAdjustAttribute(ref.Model, ref.Id, "Bank", matching.Bank)
		end
	end

	-- A road end joined to one of an intersection's exits, and which exit
	type IntersectionConnection = {
		Ref: EndpointRef,
		EndId: RoadMath.EndpointId,
	}

	-- Re-seat each connected road end onto its (possibly moved) exit
	local function reseatConnectedEnds(model: Model, connected: { IntersectionConnection })
		local info = RoadMath.getSegmentInfo(model)
		if not info then
			return
		end
		for _, conn in connected do
			local exit = RoadMath.getEndpoint(info, conn.EndId)
			local roadInfo = RoadMath.getSegmentInfo(conn.Ref.Model)
			if roadInfo then
				local ok, err = pcall(function()
					applySolutionToRef(conn.Ref, RoadMath.solveMove(roadInfo, conn.Ref.Id, exit.WorldCFrame.Position))
				end)
				if not ok then
					warn("RoadHelper: Connected road follow failed: " .. tostring(err))
				end
				alignEndFaceToMate(conn.Ref, exit)
			end
		end
	end

	-- All road ends joined to an intersection's exits
	local function collectIntersectionConnections(segment: RoadMath.SegmentInfo): { IntersectionConnection }
		local connected: { IntersectionConnection } = {}
		for _, endpoint in RoadMath.allEndpoints(segment) do
			local partner = partnerOfEndpoint(endpoint)
			if partner and not RoadMath.isJunction(partner.Segment.Kind) then
				table.insert(connected, {
					Ref = { Model = partner.Segment.Model, Id = partner.Id },
					EndId = endpoint.Id,
				})
			end
		end
		return connected
	end

	-- Move targets are captured at drag start: the selected end plus the mated
	-- partner end if the endpoint is closed. A road end mated to an
	-- intersection instead carries the whole intersection along, and the
	-- intersection's other connected roads follow its exits.
	local moveTargets: { EndpointRef } = {}
	local moveOriginalAdjust: { [RoadMath.AdjustAxis]: number }? = nil
	local moveIntersection: {
		Model: Model,
		StartPivot: CFrame,
		ExitStart: Vector3,
		Connected: { IntersectionConnection },
	}? = nil

	local function startMove()
		moveTargets = {}
		moveOriginalAdjust = nil
		moveIntersection = nil
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		table.insert(moveTargets, { Model = selected.Segment.Model, Id = selected.Id })
		if not RoadMath.isJunction(selected.Segment.Kind) then
			moveOriginalAdjust = captureAdjust(moveTargets[1])
		end
		local partner = getPartnerEndpoint()
		if partner and RoadMath.isJunction(partner.Segment.Kind) then
			-- Only carry the intersection along when the road end actually
			-- mates the exit flush (matching angle, no grade/bank). A
			-- mismatched end instead moves freely, so it can be free-dragged
			-- back onto the exit to re-snap without dragging the
			-- intersection around.
			local facing = RoadMath.actualOutwardDirection(selected):Dot(partner.WorldCFrame.LookVector)
			local flush = facing < -0.9994
				and math.abs(RoadMath.getAdjustValue(selected, "Grade")) < 0.25
				and math.abs(RoadMath.getAdjustValue(selected, "Bank")) < 0.25
			if flush then
				-- The intersection translates along with the dragged end, and
				-- its other connected roads' ends follow its exits
				local connected: { IntersectionConnection } = {}
				for _, endpoint in RoadMath.allEndpoints(partner.Segment) do
					if endpoint.Id ~= partner.Id then
						local mate = partnerOfEndpoint(endpoint)
						if mate
							and not RoadMath.isJunction(mate.Segment.Kind)
							and mate.Segment.Model ~= selected.Segment.Model
						then
							table.insert(connected, {
								Ref = { Model = mate.Segment.Model, Id = mate.Id },
								EndId = endpoint.Id,
							})
						end
					end
				end
				moveIntersection = {
					Model = partner.Segment.Model,
					StartPivot = partner.Segment.Model:GetPivot(),
					ExitStart = partner.WorldCFrame.Position,
					Connected = connected,
				}
			end
		elseif partner then
			table.insert(moveTargets, { Model = partner.Segment.Model, Id = partner.Id })
		end
		gestureActive = true
		beginRecording("Move Endpoint")
	end

	local function applyMove(newWorldPosition: Vector3, snapToEnds: boolean?)
		local snapMate: RoadMath.Endpoint? = nil
		-- With an attached intersection the dragged end stays mated to it, so
		-- snapping onto other open ends doesn't apply
		if snapToEnds and not moveIntersection then
			local movingModels = {}
			for _, target in moveTargets do
				table.insert(movingModels, target.Model)
			end
			newWorldPosition, snapMate = snapToOpenEndpoint(newWorldPosition, movingModels, nil)
		end
		for _, target in moveTargets do
			local info = RoadMath.getSegmentInfo(target.Model)
			if info then
				local ok, err = pcall(function()
					applySolutionToRef(target, RoadMath.solveMove(info, target.Id, newWorldPosition))
				end)
				if not ok then
					warn("RoadHelper: Endpoint move failed: " .. tostring(err))
				end
			end
		end
		local ix = moveIntersection
		if ix then
			-- Follow where the dragged end actually landed rather than the
			-- requested position: solveMove clamps (minimum length/footprint),
			-- and following the raw request would pull the joint apart
			local landed = resolveEndpoint(moveTargets[1])
			local exitTarget = if landed then landed.WorldCFrame.Position else newWorldPosition
			ix.Model:PivotTo(ix.StartPivot + (exitTarget - ix.ExitStart))
			reseatConnectedEnds(ix.Model, ix.Connected)
		end
		local dragged = moveTargets[1]
		if dragged and moveOriginalAdjust and not moveIntersection then
			if snapMate then
				alignEndFaceToMate(dragged, snapMate)
			else
				restoreAdjust(dragged, moveOriginalAdjust)
			end
		end
		changeSignal:Fire()
	end

	local function endMove()
		moveTargets = {}
		moveOriginalAdjust = nil
		moveIntersection = nil
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	-- Rotation: capture the attached ends and their starting attribute values,
	-- then apply cumulative deltas with per-end sign mapping.
	type RotateTarget = {
		Ref: EndpointRef,
		Signs: { [RoadMath.AdjustAxis]: number },
		StartValues: { [RoadMath.AdjustAxis]: number },
	}
	local rotateTargets: { RotateTarget } = {}

	local function captureRotateTarget(selected: RoadMath.Endpoint, endpoint: RoadMath.Endpoint): RotateTarget
		local signs = {}
		local startValues = {}
		for _, axis in ADJUST_AXES do
			signs[axis] = RoadMath.adjustDeltaSign(selected, endpoint, axis)
			startValues[axis] = RoadMath.getAdjustValue(endpoint, axis)
		end
		return {
			Ref = { Model = endpoint.Segment.Model, Id = endpoint.Id },
			Signs = signs,
			StartValues = startValues,
		}
	end

	local function startRotate()
		rotateTargets = {}
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		table.insert(rotateTargets, captureRotateTarget(selected, selected))
		local partner = getPartnerEndpoint()
		-- Intersections have no adjust angles to keep in sync
		if partner and not RoadMath.isJunction(partner.Segment.Kind) then
			table.insert(rotateTargets, captureRotateTarget(selected, partner))
		end
		gestureActive = true
		beginRecording("Rotate Endpoint")
	end

	local function applyRotate(axis: RoadMath.AdjustAxis, deltaDegrees: number)
		for _, target in rotateTargets do
			local name = RoadMath.adjustAttributeName(target.Ref.Id, axis)
			local newValue = target.StartValues[axis] + target.Signs[axis] * deltaDegrees
			-- Keep the stored angles tidy
			newValue = math.round(newValue * 1000) / 1000
			local ok, err = pcall(function()
				target.Ref.Model:SetAttribute(name, newValue)
			end)
			if not ok then
				warn("RoadHelper: Angle change failed: " .. tostring(err))
			end
		end
		changeSignal:Fire()
	end

	local function endRotate()
		rotateTargets = {}
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	--------------------------------------------------------------------------
	-- Adding segments
	--------------------------------------------------------------------------

	-- Scan for a template on demand: this only happens on add clicks, never
	-- per-frame, so a full workspace scan is acceptable.
	-- A copy of a road to build a new one from, without any markings drawn on
	-- it
	local function cloneTemplate(model: Model): Model
		local clone = model:Clone()
		Markings.strip(clone)
		return clone
	end

	local function findTemplate(kind: RoadMath.SegmentKind, near: Vector3?): RoadMath.SegmentInfo?
		local best: RoadMath.SegmentInfo? = nil
		local bestDistance = math.huge
		for _, segment in RoadMath.findSegments(workspace) do
			if segment.Kind == kind then
				local distance = if near then (segment.Pivot.Position - near).Magnitude else 0
				if distance < bestDistance then
					bestDistance = distance
					best = segment
				end
			end
		end
		return best
	end

	-- Create a new segment joined to `openEnd`, cloned from a template of the
	-- right kind with appearance attributes copied from the segment being
	-- extended. Returns the new model and its far (still open) endpoint id.
	local function createJoinedSegment(openEnd: RoadMath.Endpoint, turn: RoadMath.TurnDirection): (Model?, RoadMath.EndpointId?)
		local sourceModel = openEnd.Segment.Model
		local width = RoadMath.endpointWidth(openEnd)
		local kind, joinId, pivot, size = RoadMath.placeNewSegment(openEnd, turn, width)

		local template = if openEnd.Segment.Kind == kind
			then openEnd.Segment
			else findTemplate(kind, openEnd.WorldCFrame.Position)

		local newModel: Model?
		if template then
			newModel = cloneTemplate(template.Model)
			-- Keep the cloned geometry rather than clearing it: the engine
			-- only regenerates on change events, so a clone whose parameters
			-- all end up identical to the template's would otherwise stay
			-- empty. When anything does change, regeneration replaces the
			-- folder contents anyway.
		else
			-- No segment of this kind anywhere: build one from the packaged
			-- generator templates
			newModel = createFallbackSegmentModel(kind)
		end
		if not newModel then
			warn(`RoadHelper: No {kind} road segment available to use as a template.`)
			return nil, nil
		end

		-- Appearance follows the segment being extended
		for name, value in sourceModel:GetAttributes() do
			if not GEOMETRY_ATTRIBUTES[name] then
				newModel:SetAttribute(name, value)
			end
		end
		if openEnd.Segment.Kind == "Intersection" then
			-- Translate the extended exit's road width onto the road's
			local axis = RoadMath.laneSuffix(openEnd.Segment.Kind, openEnd.Id)
			newModel:SetAttribute("LaneWidth", sourceModel:GetAttribute("LaneWidth" .. axis) or RoadDefaults.LaneWidth)
		end
		-- The lanes carry on through the joint in the same travel directions
		clearLaneChange(newModel)
		matchLanesAcrossJoint(openEnd, newModel, kind, joinId)
		newModel:SetAttribute("Flip", false)
		for _, axis in ADJUST_AXES do
			newModel:SetAttribute(RoadMath.adjustAttributeName("Blue", axis), 0)
			newModel:SetAttribute(RoadMath.adjustAttributeName("Red", axis), 0)
		end
		-- The joining end must mate with the open end's dir/grade/bank
		local farId: RoadMath.EndpointId = if joinId == "Blue" then "Red" else "Blue"
		local matching = RoadMath.matchingAdjust(openEnd, joinId)
		newModel:SetAttribute(RoadMath.adjustAttributeName(joinId, "Dir"), matching.Dir)
		newModel:SetAttribute(RoadMath.adjustAttributeName(joinId, "Grade"), matching.Grade)
		newModel:SetAttribute(RoadMath.adjustAttributeName(joinId, "Bank"), matching.Bank)
		if kind == "Straight" then
			-- A straight added off an angled end continues at that angle: the
			-- far end carries the same yaw (same attribute = same effective
			-- world yaw on an unflipped straight), so the road doesn't bend
			-- back to the nominal axis and further adds keep the angle going.
			newModel:SetAttribute(RoadMath.adjustAttributeName(farId, "Dir"), matching.Dir)
		end

		(newModel :: any).Size = size
		newModel:PivotTo(pivot)
		newModel.Parent = sourceModel.Parent

		-- A plain click on the straight handle should jut straight out of the
		-- open end's ACTUAL face even when it is angled: both end Dirs already
		-- match the face's yaw, so aiming the far endpoint along the actual
		-- direction degenerates the path to a dead-straight diagonal within
		-- the box-aligned bounds. (A drag re-solves the far end anyway.)
		if kind == "Straight" and math.abs(matching.Dir) > 0.01 then
			local info = RoadMath.getSegmentInfo(newModel)
			if info then
				local target = openEnd.WorldCFrame.Position
					+ RoadMath.actualOutwardDirection(openEnd) * size.Z
				local ok, err = pcall(function()
					applySolution(newModel, RoadMath.solveMove(info, farId, target))
				end)
				if not ok then
					warn("RoadHelper: Straight extension failed: " .. tostring(err))
				end
			end
		end
		return newModel, farId
	end

	-- Create a new intersection joined to an open road end: its ZMinus exit
	-- mates the end's actual face, sized square at 3x the road width, lane
	-- layout matching the road on both of its axes.
	local function createJoinedIntersection(openEnd: RoadMath.Endpoint): Model?
		local sourceModel = openEnd.Segment.Model
		local template = findTemplate("Intersection", openEnd.WorldCFrame.Position)
		local newModel: Model?
		if template then
			newModel = cloneTemplate(template.Model)
			-- Keep the cloned geometry rather than clearing it: the engine
			-- only regenerates on change events, so a clone whose parameters
			-- all end up identical to the template's would otherwise stay
			-- empty. When anything does change, regeneration replaces the
			-- folder contents anyway.
		else
			-- No intersection anywhere: build one from the packaged template
			newModel = createFallbackSegmentModel("Intersection")
		end
		if not newModel then
			warn("RoadHelper: No RoadIntersection available to use as a template.")
			return nil
		end
		for name, value in sourceModel:GetAttributes() do
			if not GEOMETRY_ATTRIBUTES[name] then
				newModel:SetAttribute(name, value)
			end
		end
		local laneWidth = sourceModel:GetAttribute("LaneWidth")
		newModel:SetAttribute("LaneWidthZ", laneWidth or RoadDefaults.LaneWidth)
		newModel:SetAttribute("LaneWidthX", laneWidth or RoadDefaults.LaneWidth)
		-- The Z road continues the extended road's lanes through the ZMinus
		-- exit; the crossing X road gets the same layout
		matchLanesAcrossJoint(openEnd, newModel, "Intersection", "ZMinus")
		local forwardZ, backwardZ = RoadMath.laneCountNames("Z")
		local forwardX, backwardX = RoadMath.laneCountNames("X")
		newModel:SetAttribute(forwardX, newModel:GetAttribute(forwardZ))
		newModel:SetAttribute(backwardX, newModel:GetAttribute(backwardZ))
		local roadLanesOut, roadLanesIn = RoadMath.getLaneCounts(openEnd)
		newModel:SetAttribute("IntersectionAngle", RoadDefaults.IntersectionAngle)
		newModel:SetAttribute("ThroughRoad", true)
		-- A plain priority junction even when the template was a mini
		-- roundabout (the panel switches it)
		newModel:SetAttribute("MiniRoundabout", false)

		-- Sized from the lane layout: the road width plus the default
		-- corner radius' worth of extra space on each side. Path-like roads
		-- (a single lane with no sidewalks, e.g. dirt/cobblestone/pebble
		-- paths) get tighter corners: half a lane's radius.
		local width = RoadMath.endpointWidth(openEnd)
		local laneWidthNumber = if typeof(laneWidth) == "number" then laneWidth else RoadDefaults.LaneWidth
		local sidewalk = sourceModel:GetAttribute("SidewalkWidth")
		local isPath = roadLanesOut + roadLanesIn == 1 and sidewalk == 0
		local boxSize = width + (if isPath then laneWidthNumber else 2 * RoadDefaults.CornerRadius)
		local size = Vector3.new(boxSize, 0, boxSize);
		(newModel :: any).Size = size
		-- ZMinus (local -Z) exit opposes the road end's actual face
		local outward = RoadMath.actualOutwardDirection(openEnd)
		local rotation = CFrame.lookAlong(Vector3.zero, -outward).Rotation
		local exitLocal = Vector3.new(0, -size.Y / 2, -boxSize / 2)
		newModel:PivotTo(rotation + (openEnd.WorldCFrame.Position - rotation:VectorToWorldSpace(exitLocal)))
		newModel.Parent = sourceModel.Parent
		return newModel
	end

	-- A Y split's box: its layout's width (the geometry depends on attributes
	-- alone; the box just encloses it) and the given length
	local function splitSize(model: Model, length: number): Vector3
		return Vector3.new(RoadMath.splitLayout(model).BoxWidth, 0, length)
	end

	-- Create a new Y split joined to an open road end at its stem, which mates
	-- the end's actual face, carrying on the road's lanes and appearance. The
	-- lanes divide the default way (a two-way road separates into its two
	-- directions, a one-way road splits about in half).
	local function createJoinedSplit(openEnd: RoadMath.Endpoint): Model?
		local sourceModel = openEnd.Segment.Model
		local template = findTemplate("Split", openEnd.WorldCFrame.Position)
		local newModel: Model?
		if template then
			newModel = cloneTemplate(template.Model)
			-- Keep the cloned geometry (see createJoinedIntersection)
		else
			newModel = createFallbackSegmentModel("Split")
		end
		if not newModel then
			warn("RoadHelper: No RoadSplit available to use as a template.")
			return nil
		end
		for name, value in sourceModel:GetAttributes() do
			if not GEOMETRY_ATTRIBUTES[name] then
				newModel:SetAttribute(name, value)
			end
		end
		matchLanesAcrossJoint(openEnd, newModel, "Split", "Stem")
		newModel:SetAttribute("SplitLanesLeft", nil)
		newModel:SetAttribute("SplitSeparation", RoadDefaults.SplitSeparation)

		local size = splitSize(newModel, RoadDefaults.SplitLength);
		(newModel :: any).Size = size
		-- The stem (local -Z face) opposes the road end's actual face
		local outward = RoadMath.actualOutwardDirection(openEnd)
		local rotation = CFrame.lookAlong(Vector3.zero, -outward).Rotation
		local stemLocal = Vector3.new(RoadMath.splitLayout(newModel).StemX, -size.Y / 2, -size.Z / 2)
		newModel:PivotTo(rotation + (openEnd.WorldCFrame.Position - rotation:VectorToWorldSpace(stemLocal)))
		newModel.Parent = sourceModel.Parent
		return newModel
	end

	-- The roundabout arm a roundabout added off a road end joins it by: arm 3
	-- of the default four, pointing back down the road
	local JOINED_ROUNDABOUT_ARM: RoadMath.EndpointId = "Arm3"

	-- Create a new roundabout joined to an open road end: a round island
	-- with four arms, the back one (JOINED_ROUNDABOUT_ARM) mating the end's
	-- actual face. Every arm carries the road's lanes: the lanes heading out
	-- of the road through its end enter the roundabout, and vice versa.
	local function createJoinedRoundabout(openEnd: RoadMath.Endpoint): Model?
		local sourceModel = openEnd.Segment.Model
		local template = findTemplate("Roundabout", openEnd.WorldCFrame.Position)
		local newModel: Model?
		if template then
			newModel = cloneTemplate(template.Model)
			-- Keep the cloned geometry (see createJoinedIntersection)
		else
			newModel = createFallbackSegmentModel("Roundabout")
		end
		if not newModel then
			warn("RoadHelper: No Roundabout available to use as a template.")
			return nil
		end
		for name, value in sourceModel:GetAttributes() do
			if not GEOMETRY_ATTRIBUTES[name] then
				newModel:SetAttribute(name, value)
			end
		end
		local lanesOut, lanesIn = RoadMath.getLaneCounts(openEnd)
		local arm = `{lanesIn},{lanesOut}`
		newModel:SetAttribute("Arms", `0,{arm};90,{arm};180,{arm};270,{arm}`)
		newModel:SetAttribute("IslandShape", `0,0,{RoadDefaults.RoundaboutIslandRadius}`)
		newModel:SetAttribute("RingLanes", RoadDefaults.RoundaboutRingLanes)
		local layout = RoadMath.roundaboutLayout(newModel);
		(newModel :: any).Size = RoadMath.roundaboutSize(layout)

		-- Turn it so the joining arm faces back along the road: its local
		-- direction maps onto the opposite of the road end's actual face
		local joined = assert(layout.Arms[assert(RoadMath.armIndex(JOINED_ROUNDABOUT_ARM))])
		local outward = RoadMath.actualOutwardDirection(openEnd)
		local armYaw = math.atan2(-joined.NZ, joined.NX)
		local faceYaw = math.atan2(outward.Z, -outward.X)
		local rotation = CFrame.Angles(0, faceYaw - armYaw, 0)
		local endLocal = Vector3.new(joined.EndX, 0, joined.EndZ)
		newModel:PivotTo(rotation + (openEnd.WorldCFrame.Position - rotation:VectorToWorldSpace(endLocal)))
		newModel.Parent = sourceModel.Parent
		return newModel
	end

	-- Add-drag state (from AddHandles)
	local addDragRef: EndpointRef? = nil
	local addSourceRef: EndpointRef? = nil
	local addDragOriginalAdjust: { [RoadMath.AdjustAxis]: number }? = nil
	local addBeforeSelection: SelectionSnapshot = nil
	-- Junction (intersection / Y split) adds can't resize on drag; the whole
	-- junction (and the source road's end with it, joined at JoinId) moves
	-- instead
	local intersectionAdd: {
		Model: Model,
		StartPivot: CFrame,
		SourceRef: EndpointRef,
		JoinId: RoadMath.EndpointId,
	}? = nil

	local function startAdd(turn: RoadMath.TurnDirection): number?
		local selected = getSelectedEndpoint()
		if not selected then
			return nil
		end
		gestureActive = true
		addBeforeSelection = snapshotSelection()
		if turn == "Intersection" or turn == "Split" or turn == "Roundabout" then
			-- Each junction: how to make it, the end it joins by, and the end
			-- across from that to select, ready to keep extending
			local create, joinId, selectId, recordingName
			if turn == "Split" then
				create, joinId, selectId, recordingName = createJoinedSplit, "Stem", "BranchLeft", "Add Split"
			elseif turn == "Roundabout" then
				create, joinId, selectId, recordingName = createJoinedRoundabout, JOINED_ROUNDABOUT_ARM, "Arm1", "Add Roundabout"
			else
				create, joinId, selectId, recordingName = createJoinedIntersection, "ZMinus", "ZPlus", "Add Intersection"
			end
			beginRecording(recordingName)
			local newModel = create(selected)
			if not newModel then
				finishRecording()
				gestureActive = false
				return nil
			end
			intersectionAdd = {
				Model = newModel,
				StartPivot = newModel:GetPivot(),
				SourceRef = { Model = selected.Segment.Model, Id = selected.Id },
				JoinId = joinId,
			}
			selectedRef = { Model = newModel, Id = selectId }
			changeSignal:Fire()
			return selected.WorldCFrame.Position.Y
		end
		beginRecording("Add Segment")
		local newModel, farId = createJoinedSegment(selected, turn)
		if not newModel or not farId then
			finishRecording()
			gestureActive = false
			return nil
		end
		addDragRef = { Model = newModel, Id = farId }
		addDragOriginalAdjust = captureAdjust(addDragRef :: any)
		addSourceRef = { Model = selected.Segment.Model, Id = selected.Id }
		selectedRef = addDragRef
		changeSignal:Fire()
		local farEndpoint = resolveEndpoint(addDragRef)
		return if farEndpoint then farEndpoint.WorldCFrame.Position.Y else 0
	end

	local function applyAddDrag(worldPosition: Vector3)
		local ix = intersectionAdd
		if ix then
			-- Drag by the intersection's CENTRE: the cursor positions the
			-- middle of the box, and the extended road end follows the
			-- mating exit wherever it lands
			ix.Model:PivotTo(ix.StartPivot.Rotation + worldPosition)
			local ixInfo = RoadMath.getSegmentInfo(ix.Model)
			local roadInfo = RoadMath.getSegmentInfo(ix.SourceRef.Model)
			if ixInfo and roadInfo then
				local exit = RoadMath.getEndpoint(ixInfo, ix.JoinId)
				local ok, err = pcall(function()
					applySolutionToRef(ix.SourceRef, RoadMath.solveMove(roadInfo, ix.SourceRef.Id, exit.WorldCFrame.Position))
				end)
				if not ok then
					warn("RoadHelper: Intersection placement failed: " .. tostring(err))
				end
				-- solveMove clamps, so the road end may have stopped short of
				-- the exit: pull the intersection back onto it so the joint
				-- stays sealed (the yaw is fixed, so a translation is exact)
				local landed = resolveEndpoint(ix.SourceRef)
				if landed then
					local gap = landed.WorldCFrame.Position - exit.WorldCFrame.Position
					if gap.Magnitude > 1e-3 then
						ix.Model:PivotTo(ix.Model:GetPivot() + gap)
					end
				end
			end
			changeSignal:Fire()
			return
		end
		local ref = addDragRef
		if not ref then
			return
		end
		-- Snap onto nearby open ends, but never back onto the endpoint this
		-- segment was just added to (that would make it degenerate)
		local snapMate: RoadMath.Endpoint? = nil
		worldPosition, snapMate = snapToOpenEndpoint(worldPosition, { ref.Model }, addSourceRef)
		local info = RoadMath.getSegmentInfo(ref.Model)
		if info then
			local ok, err = pcall(function()
				applySolutionToRef(ref, RoadMath.solveMove(info, ref.Id, worldPosition))
			end)
			if not ok then
				warn("RoadHelper: Segment placement failed: " .. tostring(err))
			end
		end
		if addDragOriginalAdjust then
			if snapMate then
				alignEndFaceToMate(ref, snapMate)
			else
				restoreAdjust(ref, addDragOriginalAdjust)
			end
		end
		changeSignal:Fire()
	end

	local function endAdd()
		addDragRef = nil
		addSourceRef = nil
		addDragOriginalAdjust = nil
		intersectionAdd = nil
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, addBeforeSelection, snapshotSelection())
		end
		addBeforeSelection = nil
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	--------------------------------------------------------------------------
	-- Whole-intersection transforms
	--------------------------------------------------------------------------

	-- Moving/rotating an intersection moves the model itself and drags every
	-- connected road end along so the joints stay sealed.
	local intersectionDrag: {
		Model: Model,
		StartPivot: CFrame,
		StartAngle: number,
		Connected: { IntersectionConnection },
	}? = nil

	local function startIntersectionTransform()
		local selected = getSelectedEndpoint()
		if not selected or not RoadMath.isJunction(selected.Segment.Kind) then
			return
		end
		local connected = collectIntersectionConnections(selected.Segment)
		local startAngle = selected.Segment.Model:GetAttribute("IntersectionAngle")
		intersectionDrag = {
			Model = selected.Segment.Model,
			StartPivot = selected.Segment.Model:GetPivot(),
			StartAngle = if typeof(startAngle) == "number" then startAngle else RoadDefaults.IntersectionAngle,
			Connected = connected,
		}
		gestureActive = true
		beginRecording("Move Intersection")
	end

	local function applyIntersectionTransform(pivot: CFrame)
		local state = intersectionDrag
		if not state then
			return
		end
		state.Model:PivotTo(pivot)
		reseatConnectedEnds(state.Model, state.Connected)
		changeSignal:Fire()
	end

	-- Removing an open exit of a 4-way intersection turns it into a T
	-- junction. The T generator always drops the -X stub, so the model is
	-- rotated by the right yaw (and the two roads' roles swapped when a Z
	-- exit is removed) such that the removed exit lands on -X. Every
	-- surviving exit keeps its exact world position and direction through
	-- the transform, so connected roads stay sealed untouched.
	local function getDeletableExits(): { RoadMath.Endpoint }
		local selected = getSelectedEndpoint()
		if not selected
			or selected.Segment.Kind ~= "Intersection"
			or selected.Segment.ThroughRoad == false
		then
			return {}
		end
		local exits = {}
		for _, endpoint in RoadMath.allEndpoints(selected.Segment) do
			if not partnerOfEndpoint(endpoint) then
				table.insert(exits, endpoint)
			end
		end
		return exits
	end

	local function deleteExit(exit: RoadMath.Endpoint)
		local model = exit.Segment.Model
		local selectedBefore = getSelectedEndpoint()
		local selectedPosition = if selectedBefore then selectedBefore.WorldCFrame.Position else nil
		local beforeSelection = snapshotSelection()
		gestureActive = true
		beginRecording("Make T Junction")
		local pivot = model:GetPivot()
		local size = (model :: any).Size :: Vector3
		local angleValue = model:GetAttribute("IntersectionAngle")
		local angleDeg = if typeof(angleValue) == "number" then angleValue else RoadDefaults.IntersectionAngle
		local yaw = 0
		if exit.Id == "XPlus" then
			yaw = 180
		elseif exit.Id == "ZPlus" then
			yaw = angleDeg
		elseif exit.Id == "ZMinus" then
			yaw = angleDeg - 180
		end
		-- The transform reshuffles the exit ids and can reverse which way
		-- each road runs, but every surviving exit keeps its world position:
		-- record each one's lanes out/in there, to re-apply afterwards to
		-- whichever exit lands in its place
		local survivingLanes = {}
		for _, endpoint in RoadMath.allEndpoints(exit.Segment) do
			if endpoint.Id ~= exit.Id then
				local lanesOut, lanesIn = RoadMath.getLaneCounts(endpoint)
				table.insert(survivingLanes, {
					Position = endpoint.WorldCFrame.Position,
					Out = lanesOut,
					In = lanesIn,
				})
			end
		end
		if exit.Id == "ZPlus" or exit.Id == "ZMinus" then
			-- The X road becomes the (straight) crossbar and the Z road the
			-- angled stem: swap the per-road lane widths and box extents,
			-- and mirror the angle (lane counts follow via survivingLanes)
			local widthX = model:GetAttribute("LaneWidthX")
			local widthZ = model:GetAttribute("LaneWidthZ")
			model:SetAttribute("LaneWidthX", widthZ or RoadDefaults.LaneWidth)
			model:SetAttribute("LaneWidthZ", widthX or RoadDefaults.LaneWidth)
			model:SetAttribute("IntersectionAngle", 180 - angleDeg);
			(model :: any).Size = Vector3.new(size.Z, size.Y, size.X)
		end
		model:SetAttribute("ThroughRoad", false)
		if yaw ~= 0 then
			model:PivotTo(CFrame.new(pivot.Position) * pivot.Rotation * CFrame.Angles(0, math.rad(yaw), 0))
		end
		local newInfo = RoadMath.getSegmentInfo(model)
		if newInfo then
			for _, record in survivingLanes do
				for _, endpoint in RoadMath.allEndpoints(newInfo) do
					if (endpoint.WorldCFrame.Position - record.Position).Magnitude < 1 then
						local outName, inName = RoadMath.laneAttributeNames("Intersection", endpoint.Id)
						model:SetAttribute(outName, record.Out)
						model:SetAttribute(inName, record.In)
					end
				end
			end
		end
		-- Endpoint ids were reshuffled by the transform: re-select whichever
		-- surviving end is where the old selection was (or clear it if the
		-- selected exit is the one that was deleted)
		selectedRef = nil
		if newInfo and selectedPosition then
			for _, endpoint in RoadMath.allEndpoints(newInfo) do
				if (endpoint.WorldCFrame.Position - selectedPosition).Magnitude < 1 then
					selectedRef = { Model = model, Id = endpoint.Id }
					break
				end
			end
		end
		-- Restore the selection through undo/redo like the add gestures do
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, beforeSelection, snapshotSelection())
		end
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	-- The reverse: a T junction's missing exit can be restored, turning it
	-- back into a 4-way. Pure attribute toggle; nothing moves.
	local function getRestorableExit(): RoadMath.Endpoint?
		local selected = getSelectedEndpoint()
		if not selected
			or selected.Segment.Kind ~= "Intersection"
			or selected.Segment.ThroughRoad ~= false
		then
			return nil
		end
		return RoadMath.getEndpoint(selected.Segment, "XMinus")
	end

	local function restoreExit(exit: RoadMath.Endpoint)
		local beforeSelection = snapshotSelection()
		gestureActive = true
		beginRecording("Make Cross Intersection")
		exit.Segment.Model:SetAttribute("ThroughRoad", true)
		-- Select the freshly restored exit
		selectedRef = { Model = exit.Segment.Model, Id = "XMinus" }
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, beforeSelection, snapshotSelection())
		end
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	local function endIntersectionTransform()
		intersectionDrag = nil
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end

	-- Add a free-standing segment in front of the camera (UI buttons). When
	-- presetAttributes is given the new segment takes that appearance instead
	-- of inheriting one from the selection or a nearby template.
	local function addInFrontOfCamera(
		kind: RoadMath.SegmentKind,
		alignToWorld: boolean?,
		presetAttributes: { [string]: any }?
	)
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end

		-- Aim at what the camera is looking at, or a point ahead of the camera
		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		raycastParams.FilterDescendantsInstances = {}
		local result = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * 500, raycastParams)
		local target = if result
			then result.Position
			else camera.CFrame.Position + camera.CFrame.LookVector * 200

		-- Predictable template choice: the selected segment when there is one
		-- (its appearance is what the user is working with), otherwise the
		-- segment of the right kind closest to where the new one will spawn.
		local selected = getSelectedEndpoint()
		local template: RoadMath.SegmentInfo? = nil
		if selected and selected.Segment.Kind == kind then
			template = selected.Segment
		else
			template = findTemplate(kind, target)
		end
		local width = RoadDefaults.Width
		if presetAttributes then
			local forward, backward = RoadMath.sanitizeLaneCounts(
				presetAttributes.LaneCountForward,
				presetAttributes.LaneCountBackward
			)
			width = (forward + backward) * presetAttributes.LaneWidth + 2 * presetAttributes.SidewalkWidth
		elseif template then
			width = template.Width
		elseif selected then
			width = RoadMath.endpointWidth(selected)
		end

		local look = camera.CFrame.LookVector * Vector3.new(1, 0, 1)
		look = if look.Magnitude > 0.01 then look.Unit else Vector3.zAxis
		local yaw = math.atan2(look.X, look.Z)
		if alignToWorld then
			-- Snap the new segment to the nearest world axis
			yaw = math.round(yaw / (math.pi / 2)) * (math.pi / 2)
		end
		local rotation = CFrame.Angles(0, yaw, 0)

		local beforeSelection = snapshotSelection()
		beginRecording("Add Segment")
		local newModel: Model?
		if template then
			newModel = cloneTemplate(template.Model)
			-- Keep the cloned geometry rather than clearing it: the engine
			-- only regenerates on change events, so a clone whose parameters
			-- all end up identical to the template's would otherwise stay
			-- empty. When anything does change, regeneration replaces the
			-- folder contents anyway.
		else
			newModel = createFallbackSegmentModel(kind)
		end
		if not newModel then
			finishRecording()
			warn(`RoadHelper: No {kind} road segment available to use as a template.`)
			return
		end
		if presetAttributes then
			-- The preset decides the appearance outright
			for name, value in presetAttributes do
				newModel:SetAttribute(name, value)
			end
		elseif selected and (template == nil or selected.Segment.Model ~= template.Model) then
			-- With a selection, appearance follows the selected segment even
			-- when the template for the geometry kind is some other segment
			for name, value in selected.Segment.Model:GetAttributes() do
				if not GEOMETRY_ATTRIBUTES[name] then
					newModel:SetAttribute(name, value)
				end
			end
			if selected.Segment.Kind == "Intersection" then
				local axis = RoadMath.laneSuffix(selected.Segment.Kind, selected.Id)
				newModel:SetAttribute("LaneWidth", selected.Segment.Model:GetAttribute("LaneWidth" .. axis) or RoadDefaults.LaneWidth)
			end
			-- Same lanes as at the selected end (the free-standing segment's
			-- orientation is arbitrary, so out/in map onto forward/backward)
			local lanesOut, lanesIn = RoadMath.getLaneCounts(selected)
			newModel:SetAttribute("LaneCountForward", lanesOut)
			newModel:SetAttribute("LaneCountBackward", lanesIn)
			width = RoadMath.endpointWidth(selected)
		end
		clearLaneChange(newModel)
		newModel:SetAttribute("Flip", false)
		for _, axis in ADJUST_AXES do
			newModel:SetAttribute(RoadMath.adjustAttributeName("Blue", axis), 0)
			newModel:SetAttribute(RoadMath.adjustAttributeName("Red", axis), 0)
		end

		local size = if kind == "Straight"
			then Vector3.new(width, 0, math.max(2 * width, RoadMath.MIN_LENGTH))
			else Vector3.new(2 * width, 0, 2 * width)

		-- Center the segment on the point the camera is looking at (the pivot
		-- is the bounding box center), rather than having it extend away out
		-- of view
		;(newModel :: any).Size = size
		newModel:PivotTo(rotation + target)
		newModel.Parent = if template then template.Model.Parent else workspace

		selectedRef = { Model = newModel, Id = "Red" }
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, beforeSelection, snapshotSelection())
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	--------------------------------------------------------------------------
	-- Roundabouts
	--------------------------------------------------------------------------

	-- Selecting a roundabout's island selects its centre; selecting one of
	-- its arms' ends selects that arm. Its island outline's circles
	-- ("corners") are edited with IslandShapeHandles and the panel; one
	-- corner at a time can be selected, for the panel to act on.
	local selectedCorner: { Model: Model, Index: number }? = nil

	-- The selected roundabout (its centre or one of its arms), and the
	-- selected arm's index if it's an arm
	local function getSelectedRoundabout(): (Model?, RoadMath.RoundaboutLayout?, number?)
		local selected = getSelectedEndpoint()
		if not selected or not selected.Segment.Roundabout then
			return nil, nil, nil
		end
		return selected.Segment.Model, selected.Segment.Roundabout, RoadMath.armIndex(selected.Id)
	end

	-- The arms as attribute data, for editing
	local function armSpecs(layout: RoadMath.RoundaboutLayout): { RoadMath.ArmSpec }
		local specs = {}
		for _, arm in layout.Arms do
			table.insert(specs, {
				Angle = arm.Angle,
				Exit = arm.Exit,
				Entry = arm.Entry,
				Length = arm.LengthOverride,
				Skew = arm.Skew,
				Flare = arm.Flare,
				Arrows = arm.Arrows,
			})
		end
		return specs
	end

	-- Roads joined to the selected roundabout's arms follow them when the
	-- roundabout changes shape: captured before an edit, re-seated after
	local function captureArmConnections(model: Model): { IntersectionConnection }
		local info = RoadMath.getSegmentInfo(model)
		return if info then collectIntersectionConnections(info) else {}
	end

	local function getSelectedCornerIndex(model: Model, layout: RoadMath.RoundaboutLayout): number?
		local corner = selectedCorner
		if corner and corner.Model == model and corner.Index <= #layout.Circles then
			return corner.Index
		end
		return nil
	end

	-- The middle of the widest gap between angles (degrees)
	local function widestGapAngle(angles: { number }): number
		local sorted = {}
		for _, angle in angles do
			table.insert(sorted, angle % 360)
		end
		table.sort(sorted)
		local best = 0
		local widest = -1
		for i, current in sorted do
			local nextAngle = if i < #sorted then sorted[i + 1] else sorted[1] + 360
			if nextAngle - current > widest then
				widest = nextAngle - current
				best = (current + widest / 2) % 360
			end
		end
		return best
	end

	-- Size a roundabout's box to its layout (its pivot stays at the centre
	-- of its outline circles' space, so nothing moves)
	local function fitRoundaboutSize(model: Model)
		(model :: any).Size = RoadMath.roundaboutSize(RoadMath.roundaboutLayout(model))
	end

	local function writeIslandShape(model: Model, circles: { RoadMath.RoundaboutCircle })
		model:SetAttribute("IslandShape", RoadMath.serializeIslandShape(circles))
		fitRoundaboutSize(model)
	end

	-- Island shapes to start from (circle centres and radii in studs)
	local ISLAND_SHAPES: { [string]: string } = {
		Circle = "0,0,60",
		Oval = "-60,0,45;60,0,45",
		Square = "-45,-45,20;45,-45,20;45,45,20;-45,45,20",
		Rectangle = "-90,-40,20;90,-40,20;90,40,20;-90,40,20",
		Triangle = "0,-60,20;56,36,20;-56,36,20",
	}

	-- Drag edits from IslandShapeHandles: a recording spans the whole drag,
	-- and the roads joined to the arms follow throughout
	local dragConnections: { IntersectionConnection } = {}
	local function startIslandEdit()
		local model = getSelectedRoundabout()
		dragConnections = if model then captureArmConnections(model) else {}
		gestureActive = true
		beginRecording("Shape Roundabout")
	end
	local function endIslandEdit()
		dragConnections = {}
		finishRecording()
		gestureActive = false
		updateDragger()
		changeSignal:Fire()
	end
	local function editCorner(index: number, edit: (RoadMath.RoundaboutCircle) -> ())
		local model, layout = getSelectedRoundabout()
		if not model or not layout or not layout.Circles[index] then
			return
		end
		local circles = layout.Circles
		edit(circles[index])
		writeIslandShape(model, circles)
		reseatConnectedEnds(model, dragConnections)
		changeSignal:Fire()
	end
	local function moveArm(index: number, angle: number)
		local model, layout = getSelectedRoundabout()
		if not model or not layout or not layout.Arms[index] then
			return
		end
		local specs = armSpecs(layout)
		specs[index].Angle = angle
		model:SetAttribute("Arms", RoadMath.serializeArms(specs))
		fitRoundaboutSize(model)
		reseatConnectedEnds(model, dragConnections)
		changeSignal:Fire()
	end

	-- Panel actions on the selected roundabout
	local function roundaboutAction(action: string, value: any)
		local model, layout, armIndex = getSelectedRoundabout()
		if not model or not layout then
			return
		end
		local circles = layout.Circles
		local index = getSelectedCornerIndex(model, layout)
		local specs = armSpecs(layout)
		local connections = captureArmConnections(model)
		beginRecording("Edit Roundabout")
		if action == "AddArm" and #specs < 12 then
			-- In the middle of the widest gap between the arms
			local angles = {}
			for _, spec in specs do
				table.insert(angles, spec.Angle)
			end
			local angle = widestGapAngle(angles)
			table.insert(specs, { Angle = angle, Exit = 1, Entry = 1, Length = 0, Skew = 0, Flare = 0, Arrows = "" })
			model:SetAttribute("Arms", RoadMath.serializeArms(specs))
			fitRoundaboutSize(model)
			-- Select the new arm
			selectedRef = { Model = model, Id = ("Arm" .. #specs) :: any }
		elseif action == "RemoveArm" and armIndex then
			table.remove(specs, armIndex)
			model:SetAttribute("Arms", RoadMath.serializeArms(specs))
			fitRoundaboutSize(model)
			-- The later arms move up a number: re-point their joined roads,
			-- and leave the removed arm's road where it is
			local remapped = {}
			for _, conn in connections do
				local connIndex = RoadMath.armIndex(conn.EndId)
				if connIndex and connIndex ~= armIndex then
					local newIndex = if connIndex > armIndex then connIndex - 1 else connIndex
					table.insert(remapped, { Ref = conn.Ref, EndId = ("Arm" .. newIndex) :: any })
				end
			end
			connections = remapped
			selectedRef = { Model = model, Id = "Centre" }
		elseif (action == "ArmExit" or action == "ArmEntry") and armIndex then
			local spec = specs[armIndex]
			local lanes = math.max(math.round(value), 0)
			if action == "ArmExit" then
				spec.Exit = lanes
			else
				spec.Entry = lanes
			end
			if spec.Exit + spec.Entry < 1 then
				spec.Exit, spec.Entry = math.max(spec.Exit, 1), spec.Entry
			end
			model:SetAttribute("Arms", RoadMath.serializeArms(specs))
			fitRoundaboutSize(model)
		elseif action == "ArmAngle" and armIndex then
			specs[armIndex].Angle = value % 360
			model:SetAttribute("Arms", RoadMath.serializeArms(specs))
			fitRoundaboutSize(model)
		elseif action == "ArmOwnLength" and armIndex then
			-- This arm's own length (the roundabout's when it matches)
			local length = math.max(value, 1)
			specs[armIndex].Length = if math.abs(length - layout.ArmLength) < 1e-3 then 0 else length
			model:SetAttribute("Arms", RoadMath.serializeArms(specs))
			fitRoundaboutSize(model)
		elseif action == "ArmSkew" and armIndex then
			specs[armIndex].Skew = math.clamp(value, -RoadMath.MAX_ARM_SKEW, RoadMath.MAX_ARM_SKEW)
			model:SetAttribute("Arms", RoadMath.serializeArms(specs))
			fitRoundaboutSize(model)
		elseif action == "ArmFlare" and armIndex then
			specs[armIndex].Flare = math.clamp(math.round(value), 0, RoadMath.MAX_ARM_FLARE)
			model:SetAttribute("Arms", RoadMath.serializeArms(specs))
		elseif action == "ArmArrow" and armIndex then
			-- Toggle one letter of one entry lane's arrow (value: { Lane,
			-- Letter }), starting from the automatic arrows if need be
			local spec = specs[armIndex]
			local arrows = RoadMath.laneArrows(spec.Arrows, spec.Entry + (spec.Flare or 0))
			local letters = arrows[value.Lane]
			if letters then
				local toggled = ""
				for _, letter in { "L", "A", "R" } do
					local has = string.find(letters, letter, 1, true) ~= nil
					if has ~= (letter == value.Letter) then
						toggled ..= letter
					end
				end
				arrows[value.Lane] = toggled
				spec.Arrows = RoadMath.serializeLaneArrows(arrows)
				model:SetAttribute("Arms", RoadMath.serializeArms(specs))
			end
		elseif action == "ArmArrowsAuto" and armIndex then
			specs[armIndex].Arrows = ""
			model:SetAttribute("Arms", RoadMath.serializeArms(specs))
		elseif action == "FlareLength" then
			model:SetAttribute("FlareLength", math.max(value, 1))
		elseif action == "RingMarkings" then
			model:SetAttribute(
				"RingMarkings",
				if value == "Spiral" or value == "None" then value else "Concentric"
			)
		elseif action == "SplitterStyle" then
			model:SetAttribute("SplitterStyle", if value == "Hatched" then "Hatched" else "Kerbed")
		elseif action == "ArmLength" or action == "SplitterWidth" or action == "EntryKerbRadius" then
			model:SetAttribute(action, math.max(value, if action == "ArmLength" then 1 else 0))
			fitRoundaboutSize(model)
		elseif action == "Shape" and ISLAND_SHAPES[value] then
			model:SetAttribute("IslandShape", ISLAND_SHAPES[value])
			fitRoundaboutSize(model)
			selectedCorner = nil
		elseif action == "AddCorner" and #circles < RoadDefaults.RoundaboutMaxCorners then
			-- A new corner beside the selected one (or the first): halfway to
			-- the next, or off to the side of a lone circle
			local from = circles[index or 1]
			local nextCircle = circles[(index or 1) % #circles + 1]
			local newCircle
			if #circles == 1 then
				newCircle = { X = from.X + from.Radius * 1.5, Z = from.Z, Radius = from.Radius }
			else
				newCircle = {
					X = (from.X + nextCircle.X) / 2,
					Z = (from.Z + nextCircle.Z) / 2,
					Radius = (from.Radius + nextCircle.Radius) / 2,
				}
			end
			local insertAt = (index or 1) + 1
			table.insert(circles, insertAt, newCircle)
			writeIslandShape(model, circles)
			selectedCorner = { Model = model, Index = insertAt }
		elseif action == "RemoveCorner" and index and #circles > 1 then
			table.remove(circles, index)
			writeIslandShape(model, circles)
			selectedCorner = nil
		elseif action == "CornerRadius" and index then
			circles[index].Radius = math.max(value, 1)
			writeIslandShape(model, circles)
		elseif action == "RingLanes" then
			model:SetAttribute("RingLanes", math.max(math.round(value), 1))
			fitRoundaboutSize(model)
		elseif action == "LaneWidth" or action == "SidewalkWidth" or action == "ApronWidth" then
			model:SetAttribute(action, math.max(value, 0))
			fitRoundaboutSize(model)
		end
		reseatConnectedEnds(model, connections)
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	--------------------------------------------------------------------------
	-- Drawn markings
	--------------------------------------------------------------------------

	-- Draw Markings mode: MarkingHandles take over the viewport. The line
	-- being drawn is a list of world points until it's finished, when it
	-- becomes a real line on the road it was started on (see Markings).
	local markingMode = false
	local draft: { Vector3 } = {}
	local draftParent: Instance? = nil
	local selectedLine: Model? = nil
	local selectedPoint: number? = nil
	-- The style new lines get (the last one chosen)
	local markingDefaults: Markings.Options = {
		Style = "Dashed",
		Colour = "White",
		Curved = true,
		Width = Markings.STYLE_DEFAULTS.Dashed.Width,
		Dash = Markings.STYLE_DEFAULTS.Dashed.Dash,
		Gap = Markings.STYLE_DEFAULTS.Dashed.Gap,
	}

	-- The tool: drawing lines, or marking out a "zone" (a stretch of road,
	-- by its two sides) to divide into lanes. A zone's first side is held
	-- here once it's done, while the second is drawn as the draft.
	local markingTool: "Line" | "Zone" = "Line"
	local zoneLanes = 3
	local zoneEdges = false
	local zoneSideA: { Vector3 } = {}

	-- Something changed that the viewport shows (the line being drawn, the
	-- selection): redraw it as well as the panel. (During a press this waits
	-- for EndPress, which nudges the dragger itself.)
	local markingPressActive = false
	local function markingRefresh()
		-- (A press whose release never arrived, say because the mouse was let
		-- go outside the viewport, must not hold the dragger frozen)
		if markingPressActive and not UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1) then
			markingPressActive = false
			gestureActive = false
		end
		updateDragger()
		changeSignal:Fire()
	end

	-- The selected line, if it still exists (undo can remove it)
	local function getSelectedLine(): Model?
		local line = selectedLine
		if line and (not line:IsDescendantOf(workspace) or not Markings.isLine(line)) then
			selectedLine, selectedPoint = nil, nil
			return nil
		end
		if line and selectedPoint and selectedPoint > #Markings.getWorldPoints(line) then
			selectedPoint = nil
		end
		return line
	end

	local function selectLine(line: Model?, point: number?)
		if selectedLine == line and selectedPoint == point then
			return
		end
		selectedLine, selectedPoint = line, point
		markingRefresh()
	end

	local function startDraft(position: Vector3, surface: Instance)
		-- On the road clicked, so it moves with it (else a markings folder);
		-- a zone's second side stays on its first side's road
		if #zoneSideA == 0 then
			local road = RoadMath.segmentFromDescendant(surface)
			draftParent = if road then road.Model else nil
		end
		draft = { position }
		selectedLine, selectedPoint = nil, nil
		markingRefresh()
	end

	local function cancelDraft()
		draft = {}
		draftParent = nil
		zoneSideA = {}
		markingRefresh()
	end

	-- Where drawn lines go: the road they were started on, or a folder
	local function markingParent(parent: Instance?): Instance
		if parent and parent:IsDescendantOf(workspace) then
			return parent
		end
		local folder = workspace:FindFirstChild("RoadMarkings")
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = "RoadMarkings"
			folder.Parent = workspace
		end
		return assert(folder)
	end

	-- Finish the zone's current side: the first side done moves on to the
	-- second, and the second done draws the lane lines dividing the two
	-- (and, if wanted, the sides themselves) as ordinary lines
	local function finishZoneSide()
		if #draft < 2 then
			return
		end
		if #zoneSideA == 0 then
			zoneSideA = draft
			draft = {}
			markingRefresh()
			return
		end
		local lines = Markings.laneZoneLines(zoneSideA, draft, zoneLanes, zoneEdges, markingDefaults.Curved)
		local parent = markingParent(draftParent)
		draft, zoneSideA, draftParent = {}, {}, nil
		if #lines > 0 then
			beginRecording("Draw Lane Zone")
			for _, line in lines do
				local options = table.clone(markingDefaults)
				if line.Edge then
					-- The sides are solid edge lines
					local solid = Markings.STYLE_DEFAULTS.Solid
					options.Style, options.Width, options.Dash, options.Gap = "Solid", solid.Width, solid.Dash, solid.Gap
				end
				Markings.create(parent, line.Points, options)
			end
			finishRecording()
		end
		markingRefresh()
	end

	local function finishDraft()
		if markingTool == "Zone" then
			finishZoneSide()
			return
		end
		if #draft < 2 then
			cancelDraft()
			return
		end
		local points = draft
		local parent = draftParent
		draft = {}
		draftParent = nil
		beginRecording("Draw Marking")
		Markings.create(markingParent(parent), points, table.clone(markingDefaults))
		finishRecording()
		markingRefresh()
	end

	local function setMarkingMode(on: boolean)
		if markingMode == on then
			return
		end
		if not on then
			if markingTool == "Zone" then
				cancelDraft()
			else
				finishDraft()
			end
			selectedLine, selectedPoint = nil, nil
		else
			-- The endpoint handles step aside
			clearSelection()
		end
		markingMode = on
		markingRefresh()
	end

	-- Edit the selected line's points (world space) in place
	local function editLinePoints(edit: ({ Vector3 }) -> ())
		local line = getSelectedLine()
		if not line then
			return
		end
		local points = Markings.getWorldPoints(line)
		edit(points)
		Markings.setWorldPoints(line, points)
	end

	local markingHandles = MarkingHandles.new(draggerContext, {
		IsActive = function()
			return markingMode
		end,
		GetDraft = function()
			return draft
		end,
		GetDraftCurved = function()
			return markingDefaults.Curved
		end,
		GetZone = function()
			if markingTool ~= "Zone" then
				return nil
			end
			return { SideA = zoneSideA, Lanes = zoneLanes, IncludeEdges = zoneEdges }
		end,
		StartDraft = startDraft,
		AddDraftPoint = function(position: Vector3)
			table.insert(draft, position)
			markingRefresh()
		end,
		FinishDraft = finishDraft,
		CancelDraft = cancelDraft,
		GetSelectedLine = getSelectedLine,
		GetSelectedPoint = function()
			return selectedPoint
		end,
		SelectLine = selectLine,
		BeginPress = function()
			markingPressActive = true
			gestureActive = true
		end,
		EndPress = function()
			markingPressActive = false
			gestureActive = false
			updateDragger()
			changeSignal:Fire()
		end,
		StartEdit = function()
			beginRecording("Edit Marking")
		end,
		MovePoint = function(index: number, position: Vector3)
			editLinePoints(function(points)
				if points[index] then
					points[index] = position
				end
			end)
		end,
		InsertPoint = function(after: number, position: Vector3)
			editLinePoints(function(points)
				table.insert(points, math.clamp(after + 1, 1, #points + 1), position)
			end)
		end,
		EndEdit = function(changed: boolean)
			if changed then
				finishRecording()
			else
				cancelRecording()
			end
		end,
	})

	-- Panel actions: "Tool" ("Line" or "Zone"), and for zones "ZoneLanes" and
	-- "ZoneEdges"; on the line (or zone side) being drawn "Finish", "Cancel"
	-- and "UndoPoint"; "Style", "Colour", "Curved", "Width", "Dash" and "Gap" set
	-- the selected line's options (and new lines'); "RemovePoint" and
	-- "Delete" act on the selected line, and "Deselect" deselects it
	local function markingAction(action: string, value: any)
		if action == "Finish" then
			finishDraft()
			return
		elseif action == "Cancel" then
			cancelDraft()
			return
		elseif action == "UndoPoint" then
			table.remove(draft)
			if #draft == 0 and #zoneSideA > 0 then
				-- Back into the zone's first side
				draft, zoneSideA = zoneSideA, {}
			elseif #draft == 0 then
				draftParent = nil
			end
			markingRefresh()
			return
		elseif action == "Tool" then
			local tool: "Line" | "Zone" = if value == "Zone" then "Zone" else "Line"
			if tool ~= markingTool then
				cancelDraft()
				markingTool = tool
				selectedLine, selectedPoint = nil, nil
				updateDragger()
			end
			markingRefresh()
			return
		elseif action == "ZoneLanes" then
			zoneLanes = math.clamp(math.round(value), 1, 12)
			markingRefresh()
			return
		elseif action == "ZoneEdges" then
			zoneEdges = value == true
			markingRefresh()
			return
		elseif action == "Deselect" then
			selectLine(nil, nil)
			return
		end
		local defaults: any = markingDefaults
		if action == "Style" and Markings.STYLE_DEFAULTS[value] then
			-- A new style brings its own width and marks
			local styleDefaults = Markings.STYLE_DEFAULTS[value]
			defaults.Style = value
			defaults.Width, defaults.Dash, defaults.Gap = styleDefaults.Width, styleDefaults.Dash, styleDefaults.Gap
		elseif action == "Colour" then
			defaults.Colour = if value == "Yellow" then "Yellow" else "White"
		elseif action == "Curved" then
			defaults.Curved = value == true
		elseif action == "Width" then
			defaults.Width = math.max(value, 0.05)
		elseif action == "Dash" or action == "Gap" then
			defaults[action] = math.max(value, 0)
		end
		local line = getSelectedLine()
		if not line then
			markingRefresh()
			return
		end
		if action == "Delete" then
			beginRecording("Delete Marking")
			line.Parent = nil
			finishRecording()
			selectedLine, selectedPoint = nil, nil
		elseif action == "RemovePoint" then
			local points = Markings.getWorldPoints(line)
			if selectedPoint and #points > 2 then
				beginRecording("Edit Marking")
				table.remove(points, selectedPoint)
				Markings.setWorldPoints(line, points)
				finishRecording()
				selectedPoint = nil
			end
		elseif action == "Style" or action == "Colour" or action == "Curved"
			or action == "Width" or action == "Dash" or action == "Gap" then
			beginRecording("Edit Marking")
			if action == "Style" then
				line:SetAttribute("Style", defaults.Style)
				line:SetAttribute("Width", defaults.Width)
				line:SetAttribute("Dash", defaults.Dash)
				line:SetAttribute("Gap", defaults.Gap)
			else
				line:SetAttribute(action, defaults[action])
			end
			Markings.build(line)
			finishRecording()
		end
		markingRefresh()
	end

	local function getMarkingState(): MarkingState
		local line = getSelectedLine()
		local options = if line then Markings.getOptions(line) else markingDefaults
		return {
			Active = markingMode,
			Tool = markingTool,
			ZoneLanes = zoneLanes,
			ZoneEdges = zoneEdges,
			ZoneSide = if #zoneSideA > 0 then 2 else 1,
			Drawing = #draft > 0 or #zoneSideA > 0,
			DraftPoints = #draft,
			LineSelected = line ~= nil,
			PointCount = if line then #Markings.getWorldPoints(line) else 0,
			SelectedPoint = if line then selectedPoint else nil,
			Style = options.Style,
			Colour = options.Colour,
			Curved = options.Curved,
			Width = options.Width,
			Dash = options.Dash,
			Gap = options.Gap,
		}
	end

	-- The other handles step aside while drawing markings
	local function hiddenWhileMarking(handles: any): any
		local wrapper = {}
		function wrapper.update(_, ...)
			if handles.update then
				handles:update(...)
			end
		end
		function wrapper.shouldBiasTowardsObjects(_)
			return handles:shouldBiasTowardsObjects()
		end
		function wrapper.hitTest(_, ...)
			if markingMode then
				return nil
			end
			return handles:hitTest(...)
		end
		function wrapper.render(_, ...)
			if markingMode then
				return Roact.createElement("Folder")
			end
			return handles:render(...)
		end
		function wrapper.mouseDown(_, ...)
			return handles:mouseDown(...)
		end
		function wrapper.mouseDrag(_, ...)
			return handles:mouseDrag(...)
		end
		function wrapper.mouseUp(_, ...)
			return handles:mouseUp(...)
		end
		if handles.keyDown then
			function wrapper.keyDown(_, ...)
				if markingMode then
					return false
				end
				return handles:keyDown(...)
			end
		end
		if handles.keyUp then
			function wrapper.keyUp(_, ...)
				if markingMode then
					return false
				end
				return handles:keyUp(...)
			end
		end
		return wrapper
	end

	--------------------------------------------------------------------------
	-- Handles
	--------------------------------------------------------------------------

	local handlesList = {
		markingHandles,
		EndpointMoveHandles.new(draggerContext, {
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				-- Intersection ends can only be extended, not moved/rotated
				if not endpoint or RoadMath.isJunction(endpoint.Segment.Kind) then
					return nil
				end
				-- Handles align with the end's actual face, not the box
				return RoadMath.actualEndpointFrame(endpoint)
			end,
			GetDragExclusions = function(): { Instance }
				local exclusions: { Instance } = {}
				local selected = getSelectedEndpoint()
				if selected then
					table.insert(exclusions, selected.Segment.Model)
					local partner = getPartnerEndpoint()
					if partner then
						table.insert(exclusions, partner.Segment.Model)
						if RoadMath.isJunction(partner.Segment.Kind) then
							-- The intersection and everything joined to it
							-- move along with the drag
							for _, endpoint in RoadMath.allEndpoints(partner.Segment) do
								local mate = partnerOfEndpoint(endpoint)
								if mate then
									table.insert(exclusions, mate.Segment.Model)
								end
							end
						end
					end
				end
				return exclusions
			end,
			StartMove = startMove,
			ApplyMove = applyMove,
			EndMove = endMove,
		}),
		EndpointRotateHandles.new(draggerContext, {
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				-- Intersection ends can only be extended, not moved/rotated
				if not endpoint or RoadMath.isJunction(endpoint.Segment.Kind) then
					return nil
				end
				-- Handles align with the end's actual face, not the box
				return RoadMath.actualEndpointFrame(endpoint)
			end,
			StartRotate = startRotate,
			ApplyRotate = applyRotate,
			EndRotate = endRotate,
		}),
		-- Whole-intersection move (arrows + free drag) and yaw ring, shown at
		-- the intersection's centre when one of its ends is selected
		EndpointMoveHandles.new(draggerContext, {
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				if endpoint and RoadMath.isJunction(endpoint.Segment.Kind) then
					return endpoint.Segment.Model:GetPivot()
				end
				return nil
			end,
			GetDragExclusions = function(): { Instance }
				local exclusions: { Instance } = {}
				local selected = getSelectedEndpoint()
				if selected and RoadMath.isJunction(selected.Segment.Kind) then
					table.insert(exclusions, selected.Segment.Model)
					local state = intersectionDrag
					if state then
						for _, conn in state.Connected do
							table.insert(exclusions, conn.Ref.Model)
						end
					else
						for _, endpoint in RoadMath.allEndpoints(selected.Segment) do
							local partner = partnerOfEndpoint(endpoint)
							if partner then
								table.insert(exclusions, partner.Segment.Model)
							end
						end
					end
				end
				return exclusions
			end,
			StartMove = startIntersectionTransform,
			ApplyMove = function(newWorldPosition: Vector3)
				local state = intersectionDrag
				if state then
					applyIntersectionTransform(state.StartPivot.Rotation + newWorldPosition)
				end
			end,
			EndMove = endIntersectionTransform,
		}),
		EndpointRotateHandles.new(draggerContext, {
			Axes = { "Dir" },
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				if endpoint and RoadMath.isJunction(endpoint.Segment.Kind) then
					return endpoint.Segment.Model:GetPivot()
				end
				return nil
			end,
			StartRotate = startIntersectionTransform,
			ApplyRotate = function(axis: RoadMath.AdjustAxis, deltaDegrees: number)
				local state = intersectionDrag
				if not state then
					return
				end
				local position = state.StartPivot.Position
				local yaw = CFrame.fromAxisAngle(Vector3.yAxis, math.rad(deltaDegrees))
				applyIntersectionTransform(CFrame.new(position) * yaw * state.StartPivot.Rotation)
			end,
			EndRotate = endIntersectionTransform,
		}),
		-- Partial ring adjusting the intersection's angle (how much the X
		-- road is skewed), with its grabber sitting over the X road
		EndpointRotateHandles.new(draggerContext, {
			Axes = { "Dir" },
			View = PartialRotateHandleView,
			-- Twice the main ring's radius so it reads separately
			RadiusOffset = 5.2,
			Color = Color3.fromRGB(255, 200, 40),
			GetAngleOffset = function()
				local endpoint = getSelectedEndpoint()
				if endpoint and endpoint.Segment.Kind == "Intersection" then
					-- The view's offset runs opposite to the world yaw of the
					-- X road, mirrored about the resting 90 degree position
					return 3 * math.pi / 2 - (endpoint.Segment.Angle or math.pi / 2)
				end
				return 0
			end,
			GetEndpointCFrame = function()
				local endpoint = getSelectedEndpoint()
				if endpoint and endpoint.Segment.Kind == "Intersection" then
					return endpoint.Segment.Model:GetPivot()
				end
				return nil
			end,
			StartRotate = startIntersectionTransform,
			ApplyRotate = function(axis: RoadMath.AdjustAxis, deltaDegrees: number)
				local state = intersectionDrag
				if not state then
					return
				end
				local newAngle = math.clamp(math.round((state.StartAngle + deltaDegrees) * 10) / 10, RoadDefaults.MinIntersectionAngle, RoadDefaults.MaxIntersectionAngle)
				if state.Model:GetAttribute("IntersectionAngle") ~= newAngle then
					state.Model:SetAttribute("IntersectionAngle", newAngle)
					reseatConnectedEnds(state.Model, state.Connected)
				end
				changeSignal:Fire()
			end,
			EndRotate = endIntersectionTransform,
		}),
		DeleteExitHandles.new(draggerContext, {
			GetDeletableExits = getDeletableExits,
			DeleteExit = deleteExit,
			GetRestorableExit = getRestorableExit,
			RestoreExit = restoreExit,
		}),
		AddHandles.new(draggerContext, {
			GetOpenEndpoint = function()
				local endpoint = getSelectedEndpoint()
				-- A roundabout's centre isn't a road end
				if not endpoint or endpoint.Id == "Centre" then
					return nil
				end
				if getPartnerEndpoint() then
					return nil -- Closed endpoints can't be extended
				end
				return endpoint
			end,
			StartAdd = startAdd,
			ApplyAddDrag = applyAddDrag,
			EndAdd = endAdd,
		}),
		IslandShapeHandles.new(draggerContext, {
			GetRoundabout = function()
				local model, layout, armIndex = getSelectedRoundabout()
				if not model or not layout then
					return nil
				end
				local centroidX, centroidZ = RoadMath.islandCentroid(layout.Circles)
				local arm = if armIndex then layout.Arms[armIndex] else nil
				return {
					Model = model,
					Pivot = model:GetPivot(),
					Circles = layout.Circles,
					Selected = getSelectedCornerIndex(model, layout),
					CentroidX = centroidX,
					CentroidZ = centroidZ,
					Arm = armIndex,
					ArmAngle = if arm then arm.Angle else nil,
					-- The arm's mouth: where its axis meets the ring's outer edge
					ArmKnob = if arm then Vector3.new(arm.MouthX, 0, arm.MouthZ) else nil,
				}
			end,
			MoveArm = moveArm,
			SelectCorner = function(index: number)
				local model = getSelectedRoundabout()
				if model then
					selectedCorner = { Model = model, Index = index }
					changeSignal:Fire()
				end
			end,
			StartEdit = startIslandEdit,
			MoveCorner = function(index: number, x: number, z: number)
				editCorner(index, function(circle)
					circle.X = x
					circle.Z = z
				end)
			end,
			SetCornerRadius = function(index: number, radius: number)
				editCorner(index, function(circle)
					circle.Radius = math.max(radius, 1)
				end)
			end,
			EndEdit = endIslandEdit,
		}),
		EndpointPickHandles.new(draggerContext, {
			GetSelectedEndpoint = getSelectedEndpoint,
			GetPartner = partnerOfEndpoint,
			Select = function(endpoint: RoadMath.Endpoint)
				-- Must be a no-op when re-selecting the same endpoint: the
				-- framework responds to our selection-changed nudge by
				-- re-initializing the click (calling mouseDown -> Select
				-- again), so notifying unconditionally would loop forever.
				local ref = selectedRef
				if ref and ref.Model == endpoint.Segment.Model and ref.Id == endpoint.Id then
					return
				end
				selectedRef = { Model = endpoint.Segment.Model, Id = endpoint.Id }
				updateDragger()
				changeSignal:Fire()
			end,
			Deselect = function()
				-- Idempotent for the same reason Select must be: the
				-- framework re-initializes the click on selection changes.
				if not selectedRef then
					return
				end
				clearSelection()
				updateDragger()
			end,
		}),
	}

	-- (Everything but the marking handles steps aside while drawing markings)
	for index = 2, #handlesList do
		handlesList[index] = hiddenWhileMarking(handlesList[index])
	end

	local rootElement = Roact.createElement(DraggerToolComponent, {
		Mouse = plugin:GetMouse(),
		DraggerContext = draggerContext,
		DraggerSchema = schema,
		DraggerSettings = {
			AllowDragSelect = false,
			AnalyticsName = "RoadHelper",
			HandlesList = handlesList,
		},
	})
	local draggerHandle = Roact.mount(rootElement)

	--------------------------------------------------------------------------
	-- Refresh loop
	--------------------------------------------------------------------------

	-- Nudge the dragger periodically so the selected endpoint's handles track
	-- external edits (manual property changes etc.); this reads only the
	-- selected segment's live state, no scanning involved.
	local refreshAccumulator = 0
	local heartbeatCn = RunService.Heartbeat:Connect(function(dt: number)
		refreshAccumulator += dt
		if refreshAccumulator < REFRESH_INTERVAL then
			return
		end
		refreshAccumulator = 0
		updateDragger()
	end)

	-- HACK: Studio selects the instances affected by an undo/redo, which
	-- during a road session means a pile of (regenerated) road parts gets
	-- highlighted. Clear any road-related Studio selection shortly after; a
	-- selection of non-road instances is left alone.
	local sessionAlive = true
	local function clearStudioSelectionAfterHistory()
		local function clearIfRoadRelated()
			if not sessionAlive then
				return
			end
			for _, instance in Selection:Get() do
				if RoadMath.segmentFromDescendant(instance) then
					Selection:Set({})
					return
				end
			end
		end
		-- Once right after the history operation settles, and once the next
		-- frame in case Studio applies its selection late.
		task.defer(clearIfRoadRelated)
		task.delay(0, clearIfRoadRelated)
	end

	local undoCn = ChangeHistoryService.OnUndo:Connect(function(waypointName: string)
		clearStudioSelectionAfterHistory()
		local top = undoSelectionStack[#undoSelectionStack]
		if top and top.Name == waypointName then
			table.remove(undoSelectionStack)
			table.insert(redoSelectionStack, top)
			restoreSelection(top.Before)
		end
		updateDragger()
		changeSignal:Fire()
	end)
	local redoCn = ChangeHistoryService.OnRedo:Connect(function(waypointName: string)
		clearStudioSelectionAfterHistory()
		local top = redoSelectionStack[#redoSelectionStack]
		if top and top.Name == waypointName then
			table.remove(redoSelectionStack)
			table.insert(undoSelectionStack, top)
			restoreSelection(top.After)
		end
		updateDragger()
		changeSignal:Fire()
	end)

	--------------------------------------------------------------------------
	-- Public API
	--------------------------------------------------------------------------

	session.ChangeSignal = changeSignal

	function session.GetSelectionState(): SelectionState
		local selected = getSelectedEndpoint()
		if not selected then
			return { Kind = "none" :: "none" }
		end
		local partner = getPartnerEndpoint()
		local laneAxisSuffix = RoadMath.laneSuffix(selected.Segment.Kind, selected.Id)
		local lanesOut, lanesIn = RoadMath.getLaneCounts(selected)
		local splitLayout = selected.Segment.Split
		local roundabout = selected.Segment.Roundabout
		local roundaboutCorner = if roundabout
			then getSelectedCornerIndex(selected.Segment.Model, roundabout)
			else nil
		local roundaboutArm = if roundabout then RoadMath.armIndex(selected.Id) else nil
		local canChangeLanes = RoadMath.supportsLaneChange(selected.Segment.Kind)
		local sameLanes = not RoadMath.hasLaneChange(selected.Segment)
		local lanesDiffer = false
		if canChangeLanes then
			-- Blue's out/in are backward/forward, red's forward/backward
			local blueOut, blueIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(selected.Segment, "Blue"))
			local redOut, redIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(selected.Segment, "Red"))
			lanesDiffer = blueOut ~= redIn or blueIn ~= redOut
		end
		return {
			Kind = if partner then "closed" else "open",
			SegmentKind = selected.Segment.Kind,
			EndpointId = selected.Id,
			OtherSegmentKind = if partner then partner.Segment.Kind else nil,
			Dir = RoadMath.getAdjustValue(selected, "Dir"),
			Grade = RoadMath.getAdjustValue(selected, "Grade"),
			Bank = RoadMath.getAdjustValue(selected, "Bank"),
			Blend = selected.Segment.Model:GetAttribute("Blend") == true,
			HaveLaneMarkings = selected.Segment.Model:GetAttribute("HaveLaneMarkings") ~= false,
			TextureLaneMarkings = selected.Segment.Model:GetAttribute("TextureLaneMarkings") == true,
			MaxAngle = (selected.Segment.Model:GetAttribute("MaxAngle") :: number?) or RoadDefaults.MaxAngle,
			-- For intersections, the lane layout of the selected end's road
			LanesOut = lanesOut,
			LanesIn = lanesIn,
			CanChangeLanes = canChangeLanes,
			SameLanesBothEnds = sameLanes,
			LanesDiffer = lanesDiffer,
			-- Lane counts of a single end can only change at an open end:
			-- changing a joined end would have to drag its neighbour along
			LaneCountsEditable = sameLanes or not partner,
			LaneChangeSide = if selected.Segment.Model:GetAttribute("LaneChangeSide") == "Nearside"
				then "Nearside"
				else "Offside",
			-- Y splits: the selected branch's lanes (nil at the stem), the
			-- stem's total, the gap between the branches and the length
			SplitBranchLanes = if splitLayout and selected.Id == "BranchLeft"
				then splitLayout.LeftLanes
				elseif splitLayout and selected.Id == "BranchRight" then splitLayout.RightLanes
				else nil,
			SplitTotalLanes = if splitLayout then splitLayout.LeftLanes + splitLayout.RightLanes else nil,
			SplitSeparation = (selected.Segment.Model:GetAttribute("SplitSeparation") :: number?)
				or RoadDefaults.SplitSeparation,
			SplitLength = selected.Segment.Size.Z,
			-- Intersections: the mini roundabout variant
			MiniRoundabout = selected.Segment.Model:GetAttribute("MiniRoundabout") == true,
			MiniRoundaboutRaised = selected.Segment.Model:GetAttribute("MiniRoundaboutRaised") == true,
			MiniRoundaboutDiameter = (selected.Segment.Model:GetAttribute("MiniRoundaboutDiameter") :: number?)
				or RoadDefaults.MiniRoundaboutDiameter,
			-- Roundabouts: the outline's circle count, the selected one and
			-- its radius, the ring's lanes and the apron
			RoundaboutCorners = if roundabout then #roundabout.Circles else nil,
			SelectedCorner = roundaboutCorner,
			SelectedCornerRadius = if roundabout and roundaboutCorner
				then roundabout.Circles[roundaboutCorner].Radius
				else nil,
			RingLanes = if roundabout then roundabout.RingLanes else nil,
			ApronWidth = if roundabout then roundabout.ApronWidth else nil,
			ArmCount = if roundabout then #roundabout.Arms else nil,
			ArmLength = if roundabout then roundabout.ArmLength else nil,
			SplitterWidth = if roundabout then roundabout.SplitterWidth else nil,
			EntryKerbRadius = if roundabout then roundabout.EntryKerbRadius else nil,
			-- The selected arm, if an arm's end is selected
			ArmIndex = roundaboutArm,
			ArmExit = if roundabout and roundaboutArm then roundabout.Arms[roundaboutArm].Exit else nil,
			ArmEntry = if roundabout and roundaboutArm then roundabout.Arms[roundaboutArm].Entry else nil,
			ArmAngle = if roundabout and roundaboutArm then roundabout.Arms[roundaboutArm].Angle else nil,
			ArmOwnLength = if roundabout and roundaboutArm then roundabout.Arms[roundaboutArm].Length else nil,
			ArmSkew = if roundabout and roundaboutArm then roundabout.Arms[roundaboutArm].Skew else nil,
			ArmFlare = if roundabout and roundaboutArm then roundabout.Arms[roundaboutArm].Flare else nil,
			ArmArrows = if roundabout and roundaboutArm
				then RoadMath.laneArrows(
					roundabout.Arms[roundaboutArm].Arrows,
					roundabout.Arms[roundaboutArm].Entry + roundabout.Arms[roundaboutArm].Flare
				)
				else nil,
			ArmArrowsAuto = if roundabout and roundaboutArm then roundabout.Arms[roundaboutArm].Arrows == "" else nil,
			FlareLength = if roundabout then roundabout.FlareLength else nil,
			RingMarkings = if roundabout
				then (selected.Segment.Model:GetAttribute("RingMarkings") :: string?) or "Concentric"
				else nil,
			SplitterStyle = if roundabout then roundabout.SplitterStyle else nil,
			LaneWidth = (selected.Segment.Model:GetAttribute("LaneWidth" .. laneAxisSuffix) :: number?) or RoadDefaults.LaneWidth,
			SidewalkWidth = (selected.Segment.Model:GetAttribute("SidewalkWidth") :: number?) or RoadDefaults.SidewalkWidth,
			IntersectionAngle = (selected.Segment.Model:GetAttribute("IntersectionAngle") :: number?) or RoadDefaults.IntersectionAngle,
			CornerRadius = math.round((selected.Segment.Size.X - selected.Segment.Width
				- 2 * ((selected.Segment.Model:GetAttribute("CrossingWidth") :: number?) or 0)) * 50) / 100,
			CrossingWidth = (selected.Segment.Model:GetAttribute("CrossingWidth") :: number?) or 0,
		} :: any
	end

	-- Set the lane marking mode of the selected endpoint's segment. "None"
	-- leaves TextureLaneMarkings untouched since it isn't relevant then.
	function session.SetLaneMarkings(mode: string)
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		local model = selected.Segment.Model
		beginRecording("Edit Road")
		if mode == "None" then
			model:SetAttribute("HaveLaneMarkings", false)
		else
			model:SetAttribute("HaveLaneMarkings", true)
			model:SetAttribute("TextureLaneMarkings", mode == "Textured")
		end
		finishRecording()
		changeSignal:Fire()
	end

	-- Set a plain attribute of the selected endpoint's segment (from the UI)
	function session.SetSegmentAttribute(name: string, value: any)
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		local connections = if RoadMath.isJunction(selected.Segment.Kind)
			then collectIntersectionConnections(selected.Segment)
			else nil
		beginRecording("Edit Road")
		selected.Segment.Model:SetAttribute(name, value)
		if connections then
			-- Geometry-affecting attributes (like the intersection angle)
			-- move the exits; keep the joined roads sealed
			reseatConnectedEnds(selected.Segment.Model, connections)
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	-- The attribute a Sizing panel field edits for the selected end. Lane
	-- counts are relative to the end ("LanesOut" leave the segment through
	-- it, "LanesIn" enter), and an intersection's lane layout is per road.
	local function sizingAttributeName(selected: RoadMath.Endpoint, name: string): string
		local outName, inName = RoadMath.laneAttributeNames(selected.Segment.Kind, selected.Id)
		if name == "LanesOut" then
			return outName
		elseif name == "LanesIn" then
			return inName
		elseif name == "LaneWidth" then
			return "LaneWidth" .. RoadMath.laneSuffix(selected.Segment.Kind, selected.Id)
		end
		return name
	end

	-- Change the lane layout (lanes out/in, lane width, sidewalk width),
	-- compensating the bounds and pivot so both endpoints stay exactly where
	-- they are and any joints stay sealed.
	function session.SetSizing(name: string, value: number)
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		local model = selected.Segment.Model
		if selected.Segment.Kind == "Split" then
			-- A split's layout derives from its attributes and length. Its stem
			-- stays put (it joins the road being split), and the roads joined
			-- to its branches follow them.
			local layout = assert(selected.Segment.Split)
			local connections = collectIntersectionConnections(selected.Segment)
			local stemBefore = RoadMath.getEndpoint(selected.Segment, "Stem").WorldCFrame.Position
			local length = selected.Segment.Size.Z
			beginRecording("Resize Split")
			if name == "BranchLanes" then
				-- The selected branch's share of the stem's lanes
				local total = layout.LeftLanes + layout.RightLanes
				local leftLanes = if selected.Id == "BranchRight" then total - value else value
				model:SetAttribute("SplitLanesLeft", math.clamp(leftLanes, 1, math.max(total - 1, 1)))
			elseif name == "SplitSeparation" then
				model:SetAttribute("SplitSeparation", math.max(value, 0))
			elseif name == "SplitLength" then
				length = math.max(value, RoadMath.MIN_LENGTH)
			else
				model:SetAttribute(sizingAttributeName(selected, name), value)
			end
			(model :: any).Size = splitSize(model, length)
			local resized = RoadMath.getSegmentInfo(model)
			if resized then
				local stemNow = RoadMath.getEndpoint(resized, "Stem").WorldCFrame.Position
				model:PivotTo(model:GetPivot() + (stemBefore - stemNow))
			end
			reseatConnectedEnds(model, connections)
			finishRecording()
			updateDragger()
			changeSignal:Fire()
			return
		end
		if selected.Segment.Kind == "Intersection" then
			-- Adjust the selected end's road on the intersection. The box
			-- grows/shrinks with the width so the corner turn space is kept,
			-- which moves the exits; the joined roads follow to make space.
			local function roadWidths(): (number, number)
				local info = assert(RoadMath.getSegmentInfo(model))
				return info.Width, info.WidthX or info.Width
			end
			local connections = collectIntersectionConnections(selected.Segment)
			beginRecording("Resize Intersection")
			if name == "CornerRadius" then
				-- The corner curve radius maps to box size: each side of a
				-- road gets one radius' worth of excess space (on top of any
				-- crosswalk allocation), so the corner fillets come out at
				-- (about) the requested radius
				local crossing = (model:GetAttribute("CrossingWidth") :: number?) or 0
				local margin = 2 * math.max(value, 0) + 2 * math.max(crossing, 0)
				local wZ, wX = roadWidths()
				local size = (model :: any).Size :: Vector3
				;(model :: any).Size = Vector3.new(wZ + margin, size.Y, wX + margin)
			elseif name == "CrossingWidth" then
				-- Crosswalks claim space at both ends of each road, so the
				-- box grows by twice the width change on both axes
				local newWidth = math.max(value, 0)
				local oldWidth = (model:GetAttribute("CrossingWidth") :: number?) or 0
				local delta = 2 * (newWidth - oldWidth)
				model:SetAttribute("CrossingWidth", newWidth)
				local size = (model :: any).Size :: Vector3
				;(model :: any).Size = Vector3.new(size.X + delta, size.Y, size.Z + delta)
			else
				local oldWZ, oldWX = roadWidths()
				model:SetAttribute(sizingAttributeName(selected, name), value)
				local newWZ, newWX = roadWidths()
				local size = (model :: any).Size :: Vector3
				-- The Z road spans across the box's X extent and vice versa
				;(model :: any).Size = Vector3.new(size.X + (newWZ - oldWZ), size.Y, size.Z + (newWX - oldWX))
			end
			reseatConnectedEnds(model, connections)
			finishRecording()
			updateDragger()
			changeSignal:Fire()
			return
		end
		local isLaneCount = name == "LanesOut" or name == "LanesIn"
		if isLaneCount and RoadMath.hasLaneChange(selected.Segment) then
			-- Just this end's lanes (a lane change). Only at an open end:
			-- the end moves sideways, which would pull a joint apart.
			if getPartnerEndpoint() then
				return
			end
			beginRecording("Change Lanes")
			local outName, inName = RoadMath.endLaneAttributeNames(selected.Segment, selected.Id)
			local oldWidth = RoadMath.endpointWidth(selected)
			model:SetAttribute(if name == "LanesOut" then outName else inName, value)
			-- Keep both ends where they are through the width change...
			local resized = RoadMath.getSegmentInfo(model)
			if resized then
				local solution = RoadMath.solveWidthChange(selected.Segment, resized.Width, resized.WidthRed);
				(model :: any).Size = solution.Size
				model:PivotTo(solution.Pivot)
				-- ...then slide this end sideways so that the kerb on the
				-- other direction's side stays exactly where it was
				local settled = RoadMath.getSegmentInfo(model)
				if settled then
					local endpoint = RoadMath.getEndpoint(settled, selected.Id)
					local shift = RoadMath.laneChangeShift(
						endpoint,
						name == "LanesOut",
						RoadMath.endpointWidth(endpoint) - oldWidth
					)
					if shift.Magnitude > 1e-4 then
						local ok, err = pcall(function()
							applySolutionToRef(
								{ Model = model, Id = selected.Id },
								RoadMath.solveMove(settled, selected.Id, endpoint.WorldCFrame.Position + shift)
							)
						end)
						if not ok then
							warn("RoadHelper: Lane change failed: " .. tostring(err))
						end
					end
				end
			end
			finishRecording()
			updateDragger()
			changeSignal:Fire()
			return
		end

		beginRecording("Resize Road")
		model:SetAttribute(sizingAttributeName(selected, name), value)
		local resized = RoadMath.getSegmentInfo(model)
		if resized then
			local solution = RoadMath.solveWidthChange(selected.Segment, resized.Width, resized.WidthRed);
			(model :: any).Size = solution.Size
			model:PivotTo(solution.Pivot)
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	-- Turn a straight's per-end lanes on or off ("Same at both ends"). Turning
	-- it off gives the red end its own counts, starting from its current ones,
	-- so nothing changes until an end is edited. Turning it on gives both ends
	-- the selected end's lanes, keeping both ends where they are.
	function session.SetSameLanesBothEnds(same: boolean)
		local selected = getSelectedEndpoint()
		if not selected or not RoadMath.supportsLaneChange(selected.Segment.Kind) then
			return
		end
		local segment = selected.Segment
		local model = segment.Model
		if same == not RoadMath.hasLaneChange(segment) then
			return
		end
		if not same then
			beginRecording("Lane Change")
			-- The red end is a forward end: out = forward, in = backward
			local redOut, redIn = RoadMath.getLaneCounts(RoadMath.getEndpoint(segment, "Red"))
			model:SetAttribute(RoadMath.RED_LANE_OVERRIDES[1], redOut)
			model:SetAttribute(RoadMath.RED_LANE_OVERRIDES[2], redIn)
			finishRecording()
			changeSignal:Fire()
			return
		end
		beginRecording("Same Lanes")
		local lanesOut, lanesIn = RoadMath.getLaneCounts(selected)
		clearLaneChange(model)
		local outName, inName = RoadMath.laneAttributeNames(segment.Kind, selected.Id)
		model:SetAttribute(outName, lanesOut)
		model:SetAttribute(inName, lanesIn)
		local resized = RoadMath.getSegmentInfo(model)
		if resized then
			local solution = RoadMath.solveWidthChange(segment, resized.Width, resized.WidthRed);
			(model :: any).Size = solution.Size
			model:PivotTo(solution.Pivot)
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	-- Toggle the blend skirt of the selected endpoint's segment
	function session.SetBlend(value: boolean)
		local selected = getSelectedEndpoint()
		if not selected then
			return
		end
		beginRecording("Toggle Skirt")
		selected.Segment.Model:SetAttribute("Blend", value)
		finishRecording()
		changeSignal:Fire()
	end

	-- Set an absolute Adjust value on the selected end (from the UI), applying
	-- the equivalent delta to the mated partner end to keep the joint sealed.
	function session.SetAdjustValue(axis: RoadMath.AdjustAxis, value: number)
		local selected = getSelectedEndpoint()
		-- Intersections have no adjust angles
		if not selected or RoadMath.isJunction(selected.Segment.Kind) then
			return
		end
		local delta = value - RoadMath.getAdjustValue(selected, axis)
		beginRecording("Set Angle")
		local function applyTo(endpoint: RoadMath.Endpoint)
			local sign = RoadMath.adjustDeltaSign(selected, endpoint, axis)
			local name = RoadMath.adjustAttributeName(endpoint.Id, axis)
			endpoint.Segment.Model:SetAttribute(name, RoadMath.getAdjustValue(endpoint, axis) + sign * delta)
		end
		applyTo(selected)
		local partner = getPartnerEndpoint()
		-- As with the rotate rings: an intersection partner has no adjust
		-- angles to keep in sync (the road end just stops being flush)
		if partner and not RoadMath.isJunction(partner.Segment.Kind) then
			applyTo(partner)
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	session.AddInFrontOfCamera = addInFrontOfCamera

	-- Add a free-standing intersection in front of the camera (UI buttons):
	-- a 4-way crossing or a T junction depending on throughRoad.
	function session.AddIntersectionInFrontOfCamera(
		throughRoad: boolean,
		alignToWorld: boolean?,
		presetAttributes: { [string]: any }?,
		miniRoundabout: boolean?
	)
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local raycastParams = RaycastParams.new()
		raycastParams.FilterType = Enum.RaycastFilterType.Exclude
		raycastParams.FilterDescendantsInstances = {}
		local result = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * 500, raycastParams)
		local target = if result
			then result.Position
			else camera.CFrame.Position + camera.CFrame.LookVector * 200

		local template = findTemplate("Intersection", target)
		local beforeSelection = snapshotSelection()
		beginRecording("Add Intersection")
		local newModel: Model?
		if template then
			newModel = cloneTemplate(template.Model)
			-- Keep the cloned geometry (see the other add paths)
		else
			newModel = createFallbackSegmentModel("Intersection")
		end
		if not newModel then
			finishRecording()
			warn("RoadHelper: No RoadIntersection available to use as a template.")
			return
		end
		if presetAttributes then
			-- The preset's road lane layout maps onto both of the
			-- intersection's axes; everything else copies directly
			local roadLaneAttributes = {
				LaneCountForward = true,
				LaneCountBackward = true,
				LaneWidth = true,
			}
			for name, value in presetAttributes do
				if not roadLaneAttributes[name] then
					newModel:SetAttribute(name, value)
				end
			end
			for _, axis in { "X", "Z" } do
				local forwardName, backwardName = RoadMath.laneCountNames(axis)
				newModel:SetAttribute(forwardName, presetAttributes.LaneCountForward or RoadDefaults.LaneCountForward)
				newModel:SetAttribute(backwardName, presetAttributes.LaneCountBackward or RoadDefaults.LaneCountBackward)
				newModel:SetAttribute("LaneWidth" .. axis, presetAttributes.LaneWidth or RoadDefaults.LaneWidth)
			end
		end
		newModel:SetAttribute("ThroughRoad", throughRoad)
		newModel:SetAttribute("MiniRoundabout", miniRoundabout == true)
		newModel:SetAttribute("IntersectionAngle", RoadDefaults.IntersectionAngle)

		-- Default size from the lane layout, like extending with one
		local info = assert(RoadMath.getSegmentInfo(newModel))
		local wZ = info.Width
		local wX = info.WidthX or info.Width
		local sidewalk = (newModel:GetAttribute("SidewalkWidth") :: number?) or RoadDefaults.SidewalkWidth
		local laneWidthZ = (newModel:GetAttribute("LaneWidthZ") :: number?) or RoadDefaults.LaneWidth
		local lanesOutZ, lanesInZ = RoadMath.getLaneCounts(RoadMath.getEndpoint(info, "ZPlus"))
		local isPath = lanesOutZ + lanesInZ == 1 and sidewalk == 0
		-- Default corner radius for roads, half a lane for paths
		local extra = if isPath then laneWidthZ else 2 * RoadDefaults.CornerRadius

		local look = camera.CFrame.LookVector * Vector3.new(1, 0, 1)
		look = if look.Magnitude > 0.01 then look.Unit else Vector3.zAxis
		local yaw = math.atan2(look.X, look.Z)
		if alignToWorld then
			yaw = math.round(yaw / (math.pi / 2)) * (math.pi / 2)
		end

		;(newModel :: any).Size = Vector3.new(wZ + extra, 0, wX + extra)
		newModel:PivotTo(CFrame.Angles(0, yaw, 0) + target)
		newModel.Parent = if template then template.Model.Parent else workspace

		selectedRef = { Model = newModel, Id = "ZPlus" }
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, beforeSelection, snapshotSelection())
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	-- Add a roundabout in front of the camera (UI button): a round island
	-- ringed by the default circulating carriageway, in the preset's (or a
	-- nearby roundabout's) appearance
	function session.AddRoundaboutInFrontOfCamera(alignToWorld: boolean?, presetAttributes: { [string]: any }?)
		local camera = workspace.CurrentCamera
		if not camera then
			return
		end
		local result = workspace:Raycast(camera.CFrame.Position, camera.CFrame.LookVector * 800)
		local target = if result
			then result.Position
			else camera.CFrame.Position + camera.CFrame.LookVector * 300

		local template = findTemplate("Roundabout", target)
		local beforeSelection = snapshotSelection()
		beginRecording("Add Roundabout")
		local newModel: Model?
		if template then
			newModel = cloneTemplate(template.Model)
			-- Keep the cloned geometry (see the other add paths)
		else
			newModel = createFallbackSegmentModel("Roundabout")
		end
		if not newModel then
			finishRecording()
			warn("RoadHelper: No Roundabout available to use as a template.")
			return
		end
		if presetAttributes then
			-- Appearance and lane width from the preset; the ring has its own
			-- lane count
			for name, value in presetAttributes do
				if name ~= "LaneCountForward" and name ~= "LaneCountBackward" then
					newModel:SetAttribute(name, value)
				end
			end
		end
		newModel:SetAttribute("IslandShape", ISLAND_SHAPES.Circle)
		newModel:SetAttribute("RingLanes", RoadDefaults.RoundaboutRingLanes)
		newModel:SetAttribute("Arms", RoadDefaults.RoundaboutArms)
		fitRoundaboutSize(newModel)

		local look = camera.CFrame.LookVector * Vector3.new(1, 0, 1)
		look = if look.Magnitude > 0.01 then look.Unit else Vector3.zAxis
		local yaw = math.atan2(look.X, look.Z)
		if alignToWorld then
			yaw = math.round(yaw / (math.pi / 2)) * (math.pi / 2)
		end
		newModel:PivotTo(CFrame.Angles(0, yaw, 0) + target)
		newModel.Parent = if template then template.Model.Parent else workspace

		selectedRef = { Model = newModel, Id = "Centre" }
		selectedCorner = nil
		if activeRecordingName then
			pushSelectionHistory(activeRecordingName, beforeSelection, snapshotSelection())
		end
		finishRecording()
		updateDragger()
		changeSignal:Fire()
	end

	-- Panel actions on the selected roundabout: "Shape" (a preset name),
	-- "AddCorner", "RemoveCorner", "CornerRadius", "RingLanes", "LaneWidth",
	-- "SidewalkWidth", "ApronWidth", "AddArm", "ArmLength", "SplitterWidth",
	-- "EntryKerbRadius", "SplitterStyle", and on the selected arm
	-- "RemoveArm", "ArmExit", "ArmEntry", "ArmAngle", "ArmOwnLength", "ArmSkew"
	session.RoundaboutAction = roundaboutAction

	-- Draw Markings mode, its panel actions (see markingAction) and state
	session.SetMarkingMode = setMarkingMode
	session.MarkingAction = markingAction
	session.GetMarkingState = getMarkingState

	function session.Destroy()
		sessionAlive = false
		-- (A line still being drawn is dropped)
		draft = {}
		heartbeatCn:Disconnect()
		undoCn:Disconnect()
		redoCn:Disconnect()
		finishRecording()
		Roact.unmount(draggerHandle)
	end

	return session
end

export type RoadSession = typeof(createRoadSession(...))

return createRoadSession
