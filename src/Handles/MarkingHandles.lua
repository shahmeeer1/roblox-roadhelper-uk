--[[
	MarkingHandles: drawing and editing road markings by hand (see Markings).
	Only active in Draw Markings mode, when the other handles step aside.

	- With no line selected, clicking on any surface starts a new line there;
	  each further click adds a point. Double-click or press Enter to finish
	  (Esc cancels). The line so far is previewed, with the next point
	  following the cursor.
	- Clicking an existing line selects it: its points get knobs (drag to
	  move, click to select one for the panel) and each stretch between them
	  a smaller knob in its middle (drag to add a point there). Clicking
	  elsewhere deselects it.
	- Points snap to the ends of generated markings and drawn lines' points,
	  or failing that onto generated markings; hold Alt to place freely.

	Clicks act on release: the framework re-runs mouseDown (after a mouseUp)
	whenever it's nudged mid-click, so the session holds off nudges for the
	whole press (BeginPress / EndPress).
]]

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)
local Math = require(DraggerFramework.Utility.Math)

local Markings = require(script.Parent.Parent.Markings)

local UserInputService = game:GetService("UserInputService")

local RAY_LENGTH = 10000
local KNOB_RADIUS = 0.45
local INSERT_RADIUS = 0.3
local HIT_SCALE = 1.5
-- How near the cursor a point snaps from, and a line is picked from (scaled
-- with distance like handles are)
local SNAP_SCALE = 1.2
local PICK_SCALE = 0.6
local PREVIEW_RADIUS = 0.12
-- Two clicks this close in time and space are a double-click
local DOUBLE_CLICK_TIME = 0.4
local DOUBLE_CLICK_DISTANCE = 3

local DRAFT_COLOR = Color3.fromRGB(255, 200, 60)
local SELECTED_COLOR = Color3.fromRGB(255, 140, 60)
local HOVER_COLOR = Color3.fromRGB(110, 210, 255)
local KNOB_COLOR = Color3.fromRGB(240, 240, 240)
local KNOB_SELECTED_COLOR = Color3.fromRGB(255, 200, 60)
local INSERT_COLOR = Color3.fromRGB(110, 210, 255)
local SNAP_END_COLOR = Color3.fromRGB(80, 230, 120)
local SNAP_LINE_COLOR = Color3.fromRGB(110, 210, 255)
local CURSOR_COLOR = Color3.fromRGB(240, 240, 240)

local MarkingHandles = {}
MarkingHandles.__index = MarkingHandles

export type Props = {
	-- Whether Draw Markings mode is on
	IsActive: () -> boolean,
	-- The line being drawn (world points; empty when not drawing), and
	-- whether its points follow a curve, for the preview
	GetDraft: () -> { Vector3 },
	GetDraftCurved: () -> boolean,
	-- Start a line with its first point on `surface` (what was clicked), add
	-- a point, and finish or cancel it
	StartDraft: (position: Vector3, surface: Instance) -> (),
	AddDraftPoint: (position: Vector3) -> (),
	FinishDraft: () -> (),
	CancelDraft: () -> (),
	-- The selected line and point, and selecting them (nil to deselect)
	GetSelectedLine: () -> Model?,
	GetSelectedPoint: () -> number?,
	SelectLine: (line: Model?, point: number?) -> (),
	-- Hold off nudging the dragger for a press
	BeginPress: () -> (),
	EndPress: () -> (),
	-- Drag edits on the selected line, as one undo step: move point `index`,
	-- or first add a point after `index` and move that
	StartEdit: () -> (),
	MovePoint: (index: number, position: Vector3) -> (),
	InsertPoint: (after: number, position: Vector3) -> (),
	EndEdit: (changed: boolean) -> (),
}

function MarkingHandles.new(draggerContext, props: Props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._knobs = {}
	self._hover = nil
	self._hoverLine = nil
	self._lastClick = nil
	return setmetatable(self, MarkingHandles)
end

local function snappingEnabled(): boolean
	return not (UserInputService:IsKeyDown(Enum.KeyCode.LeftAlt) or UserInputService:IsKeyDown(Enum.KeyCode.RightAlt))
end

-- What's under the mouse: the surface hit (our marking parts aren't
-- queryable, so they never get in the way), and the point to use there,
-- snapped unless Alt is held
function MarkingHandles:_surfaceUnder(mouseRay, ignoreLine: Model?)
	local result = workspace:Raycast(mouseRay.Origin, mouseRay.Direction.Unit * RAY_LENGTH)
	if not result then
		return nil
	end
	local position = result.Position
	local snapKind = nil
	if snappingEnabled() then
		local radius = SNAP_SCALE * self._draggerContext:getHandleScale(position)
		local snapped, kind = Markings.snap(position, radius, ignoreLine)
		if snapped then
			position, snapKind = snapped, kind
		end
	end
	return {
		Instance = result.Instance,
		Distance = result.Distance,
		Raw = result.Position,
		Position = position,
		Snap = snapKind,
	}
end

function MarkingHandles:update(draggerToolModel, selectionInfo)
	self._knobs = {}
	if not self._props.IsActive() or #self._props.GetDraft() > 0 then
		return
	end
	local line = self._props.GetSelectedLine()
	if not line then
		return
	end
	-- Knobs on the selected line's points, and in the middle of each stretch
	-- between them (on its path)
	local points = Markings.getWorldPoints(line)
	local curved = Markings.getOptions(line).Curved
	local path = Markings.samplePath(points, curved)
	local starts = Markings.spanStarts(points, curved)
	for index, point in points do
		local scale = self._draggerContext:getHandleScale(point)
		table.insert(self._knobs, {
			Id = "Point" .. index,
			Kind = "Point",
			Index = index,
			Position = point + Vector3.yAxis * (KNOB_RADIUS * scale),
			Radius = KNOB_RADIUS * scale,
		})
	end
	for index = 1, #points - 1 do
		local from, to = starts[index], starts[index + 1]
		-- (The sample halfway through the span, or between its two)
		local middle = if to - from >= 2
			then path[from + math.floor((to - from) / 2)]
			else (points[index] + points[index + 1]) / 2
		if middle then
			local scale = self._draggerContext:getHandleScale(middle)
			table.insert(self._knobs, {
				Id = "Insert" .. index,
				Kind = "Insert",
				Index = index,
				Position = middle + Vector3.yAxis * (INSERT_RADIUS * scale),
				Radius = INSERT_RADIUS * scale,
			})
		end
	end
end

function MarkingHandles:shouldBiasTowardsObjects()
	return false
end

function MarkingHandles:hitTest(mouseRay, ignoreExtraThreshold)
	self._hover = nil
	self._hoverLine = nil
	if not self._props.IsActive() then
		return nil
	end
	self:update()
	-- The selected line's knobs come first
	local closestId, closestDistance = nil, math.huge
	for _, knob in self._knobs do
		local hit, distance = Math.intersectRaySphere(
			mouseRay.Origin, mouseRay.Direction.Unit, knob.Position, knob.Radius * HIT_SCALE)
		if hit and distance and distance < closestDistance then
			closestId, closestDistance = knob.Id, distance
		end
	end
	if closestId then
		return closestId, closestDistance, true
	end
	local drafting = #self._props.GetDraft() > 0
	local surface = self:_surfaceUnder(mouseRay, nil)
	if not surface then
		-- (Clicking the sky deselects)
		return "Sky", RAY_LENGTH, false
	end
	self._hover = surface
	if not drafting then
		-- An existing line under the cursor, to select
		local pickRadius = PICK_SCALE * self._draggerContext:getHandleScale(surface.Raw)
		local best, bestDistance = nil, math.huge
		for _, line in Markings.allLines() do
			local width = Markings.getOptions(line).Width
			local distance = Markings.distanceTo(line, surface.Raw)
			if distance < math.max(pickRadius, width) and distance < bestDistance then
				best, bestDistance = line, distance
			end
		end
		self._hoverLine = best
	end
	return "Surface", surface.Distance, false
end

-- A thin cylinder along a stretch of path
local function segmentElement(a: Vector3, b: Vector3, radius: number, color: Color3)
	local length = (b - a).Magnitude
	if length < 1e-3 then
		return nil
	end
	return Roact.createElement("CylinderHandleAdornment", {
		Adornee = workspace.Terrain,
		CFrame = CFrame.lookAt((a + b) / 2, b),
		Height = length,
		Radius = radius,
		Color3 = color,
		Transparency = 0.2,
		AlwaysOnTop = true,
		ZIndex = 0,
	})
end

local function sphereElement(position: Vector3, radius: number, color: Color3, transparency: number?)
	return Roact.createElement("SphereHandleAdornment", {
		Adornee = workspace.Terrain,
		CFrame = CFrame.new(position),
		Radius = radius,
		Color3 = color,
		Transparency = transparency or 0.1,
		AlwaysOnTop = true,
		ZIndex = 1,
	})
end

function MarkingHandles:render(hoveredHandleId)
	local children = {}
	if not self._props.IsActive() then
		return Roact.createElement("Folder", {}, children)
	end
	local function drawPath(prefix: string, path: { Vector3 }, color: Color3, scaleAt: Vector3)
		local radius = PREVIEW_RADIUS * self._draggerContext:getHandleScale(scaleAt)
		for i = 1, #path - 1 do
			children[prefix .. i] = segmentElement(path[i], path[i + 1], radius, color)
		end
	end

	local draft = self._props.GetDraft()
	local hover = self._hover
	if #draft > 0 then
		-- The line so far, on to where the next point would go
		local points = table.clone(draft)
		if hover then
			table.insert(points, hover.Position)
		end
		drawPath("Draft", Markings.samplePath(points, self._props.GetDraftCurved()), DRAFT_COLOR, draft[#draft])
		for index, point in draft do
			children["DraftPoint" .. index] =
				sphereElement(point, KNOB_RADIUS * 0.7 * self._draggerContext:getHandleScale(point), DRAFT_COLOR)
		end
	else
		local selected = self._props.GetSelectedLine()
		if self._hoverLine and self._hoverLine ~= selected then
			local line = self._hoverLine
			local points = Markings.getWorldPoints(line)
			if #points > 0 then
				drawPath("Hover", Markings.samplePath(points, Markings.getOptions(line).Curved), HOVER_COLOR, points[1])
			end
		end
		if selected then
			local points = Markings.getWorldPoints(selected)
			if #points > 0 then
				drawPath("Selected", Markings.samplePath(points, Markings.getOptions(selected).Curved), SELECTED_COLOR, points[1])
			end
			local selectedPoint = self._props.GetSelectedPoint()
			for _, knob in self._knobs do
				local hovered = knob.Id == hoveredHandleId or knob.Id == self._dragging
				local color = if knob.Kind == "Insert"
					then INSERT_COLOR
					elseif knob.Index == selectedPoint then KNOB_SELECTED_COLOR
					else KNOB_COLOR
				children[knob.Id] = sphereElement(knob.Position, knob.Radius * (if hovered then 1.25 else 1), color, if hovered then 0 else 0.15)
			end
		end
	end
	-- Where a click would put a point, coloured by what it snapped to
	if hover and hoveredHandleId == "Surface" and (#draft > 0 or not self._hoverLine) then
		local color = if hover.Snap == "End" then SNAP_END_COLOR elseif hover.Snap == "Line" then SNAP_LINE_COLOR else CURSOR_COLOR
		children.Cursor = sphereElement(hover.Position, 0.35 * self._draggerContext:getHandleScale(hover.Position), color, 0.2)
	end
	return Roact.createElement("Folder", {}, children)
end

function MarkingHandles:mouseDown(mouseRay, handleId)
	self._props.BeginPress()
	self._pressId = handleId
	self._pressHover = self._hover
	self._pressHoverLine = self._hoverLine
	self._dragging = nil
	self._changed = false
	local line = self._props.GetSelectedLine()
	for _, knob in self._knobs do
		if knob.Id == handleId and line then
			self._dragging = handleId
			self._dragKind = knob.Kind
			self._dragIndex = knob.Index
			self._dragLine = line
			if knob.Kind == "Point" then
				self._props.SelectLine(line, knob.Index)
			end
			self._props.StartEdit()
			return
		end
	end
end

function MarkingHandles:mouseDrag(mouseRay)
	if not self._dragging then
		return
	end
	local surface = self:_surfaceUnder(mouseRay, self._dragLine)
	if not surface then
		return
	end
	if self._dragKind == "Insert" then
		-- The first movement adds the point; from then on it's dragged
		self._props.InsertPoint(self._dragIndex, surface.Position)
		self._dragKind = "Point"
		self._dragIndex += 1
		self._props.SelectLine(self._dragLine, self._dragIndex)
	else
		self._props.MovePoint(self._dragIndex, surface.Position)
	end
	self._changed = true
end

function MarkingHandles:mouseUp(mouseRay)
	local props = self._props
	if self._dragging then
		self._dragging = nil
		props.EndEdit(self._changed)
		props.EndPress()
		return
	end
	local id, hover, hoverLine = self._pressId, self._pressHover, self._pressHoverLine
	self._pressId = nil
	if id == "Surface" and hover then
		local draft = props.GetDraft()
		local now = os.clock()
		local last = self._lastClick
		self._lastClick = { Time = now, Position = hover.Position }
		if #draft > 0 then
			-- A double-click finishes the line (its first click already added
			-- the last point)
			if last and now - last.Time < DOUBLE_CLICK_TIME
				and (hover.Position - last.Position).Magnitude < DOUBLE_CLICK_DISTANCE then
				self._lastClick = nil
				props.FinishDraft()
			else
				props.AddDraftPoint(hover.Position)
			end
		elseif hoverLine then
			props.SelectLine(hoverLine, nil)
		elseif props.GetSelectedLine() then
			-- Clicking off the selected line deselects it first
			props.SelectLine(nil, nil)
		else
			props.StartDraft(hover.Position, hover.Instance)
		end
	elseif id == "Sky" then
		props.SelectLine(nil, nil)
	end
	props.EndPress()
end

function MarkingHandles:keyDown(keyCode): boolean
	if not self._props.IsActive() or #self._props.GetDraft() == 0 then
		return false
	end
	if keyCode == Enum.KeyCode.Return or keyCode == Enum.KeyCode.KeypadEnter then
		self._props.FinishDraft()
		return true
	elseif keyCode == Enum.KeyCode.Escape then
		self._props.CancelDraft()
		return true
	end
	return false
end

return MarkingHandles
