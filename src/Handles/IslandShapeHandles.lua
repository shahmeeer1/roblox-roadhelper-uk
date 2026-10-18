--[[
	IslandShapeHandles: shaping a selected roundabout's central island. Its
	outline is the convex hull of circles; each circle gets a knob above its
	centre (click to select it for the panel, drag to move it) and a knob on
	its edge (drag to change its radius), plus a ring showing the circle.
	Corner knobs float above the road so they stay clear of the roundabout's
	own move handle at its centre.
]]

local Packages = script.Parent.Parent.Parent.Packages
local Roact = require(Packages.Roact)
local DraggerFramework = require(Packages.DraggerFramework)
local Math = require(DraggerFramework.Utility.Math)

local RoadMath = require(script.Parent.Parent.RoadMath)

local DraggerService = game:GetService("DraggerService")

local CORNER_RADIUS = 0.8
local RADIUS_KNOB_RADIUS = 0.6
local HIT_SCALE = 1.4
local CORNER_LIFT = 3
local RING_THICKNESS = 0.6

local CORNER_COLOR = Color3.fromRGB(240, 240, 240)
local SELECTED_COLOR = Color3.fromRGB(255, 200, 60)
local RADIUS_COLOR = Color3.fromRGB(110, 210, 255)
local RING_COLOR = Color3.fromRGB(110, 210, 255)

local IslandShapeHandles = {}
IslandShapeHandles.__index = IslandShapeHandles

export type Roundabout = {
	Model: Model,
	Pivot: CFrame,
	Circles: { RoadMath.RoundaboutCircle },
	-- The selected circle's index, if any
	Selected: number?,
}

export type Props = {
	-- The selected roundabout, if the selection is one
	GetRoundabout: () -> Roundabout?,
	SelectCorner: (index: number) -> (),
	StartEdit: () -> (),
	MoveCorner: (index: number, x: number, z: number) -> (),
	SetCornerRadius: (index: number, radius: number) -> (),
	EndEdit: () -> (),
}

function IslandShapeHandles.new(draggerContext, props: Props)
	local self = {}
	self._draggerContext = draggerContext
	self._props = props
	self._handles = {}
	return setmetatable(self, IslandShapeHandles)
end

function IslandShapeHandles:update(draggerToolModel, selectionInfo)
	if self._dragging then
		-- Keep the handles following the shape being dragged
		self._roundabout = self._props.GetRoundabout() or self._roundabout
	else
		self._roundabout = self._props.GetRoundabout()
	end
	local roundabout = self._roundabout
	self._handles = {}
	if not roundabout then
		return
	end
	for index, circle in roundabout.Circles do
		local centre = roundabout.Pivot * Vector3.new(circle.X, 0, circle.Z)
		local scale = self._draggerContext:getHandleScale(centre)
		self._handles["Corner" .. index] = {
			Kind = "Corner",
			Index = index,
			Position = centre + Vector3.yAxis * (CORNER_LIFT * scale),
			Ground = centre,
			Radius = CORNER_RADIUS * scale,
			Circle = circle,
		}
		local edge = roundabout.Pivot * Vector3.new(circle.X + circle.Radius, 0, circle.Z)
		self._handles["Radius" .. index] = {
			Kind = "Radius",
			Index = index,
			Position = edge + Vector3.yAxis * 0.5,
			Radius = RADIUS_KNOB_RADIUS * self._draggerContext:getHandleScale(edge),
		}
	end
end

function IslandShapeHandles:shouldBiasTowardsObjects()
	return false
end

function IslandShapeHandles:hitTest(mouseRay, ignoreExtraThreshold)
	local closestId, closestDistance = nil, math.huge
	for handleId, handle in self._handles do
		local hit, distance = Math.intersectRaySphere(
			mouseRay.Origin, mouseRay.Direction.Unit, handle.Position, handle.Radius * HIT_SCALE)
		if hit and distance and distance < closestDistance then
			closestDistance = distance
			closestId = handleId
		end
	end
	return closestId, closestDistance, true
end

function IslandShapeHandles:render(hoveredHandleId)
	local children = {}
	local roundabout = self._roundabout
	if not roundabout then
		return Roact.createElement("Folder", {}, children)
	end
	for handleId, handle in self._handles do
		local hovered = handleId == hoveredHandleId or handleId == self._dragging
		local color = if handle.Kind == "Radius"
			then RADIUS_COLOR
			elseif handle.Index == roundabout.Selected then SELECTED_COLOR
			else CORNER_COLOR
		children[handleId] = Roact.createElement("SphereHandleAdornment", {
			Adornee = workspace.Terrain,
			CFrame = CFrame.new(handle.Position),
			Radius = handle.Radius * (if hovered then 1.25 else 1),
			Color3 = color,
			Transparency = if hovered then 0 else 0.2,
			AlwaysOnTop = true,
			ZIndex = 1,
		})
		if handle.Kind == "Corner" then
			-- A stem down to the circle centre, and the circle itself
			local stemLength = (handle.Position - handle.Ground).Magnitude
			children[handleId .. "Stem"] = Roact.createElement("CylinderHandleAdornment", {
				Adornee = workspace.Terrain,
				CFrame = CFrame.lookAt((handle.Position + handle.Ground) / 2, handle.Ground),
				Height = stemLength,
				Radius = handle.Radius * 0.15,
				Color3 = color,
				Transparency = 0.3,
				AlwaysOnTop = true,
				ZIndex = 0,
			})
			local circle = handle.Circle
			if circle.Radius > RING_THICKNESS then
				-- A cylinder adornment's axis is its Z: lay it flat
				children[handleId .. "Ring"] = Roact.createElement("CylinderHandleAdornment", {
					Adornee = workspace.Terrain,
					CFrame = CFrame.new(handle.Ground + Vector3.yAxis * 0.4) * CFrame.Angles(math.rad(90), 0, 0),
					Height = 0.2,
					Radius = circle.Radius,
					InnerRadius = circle.Radius - RING_THICKNESS,
					Color3 = if handle.Index == roundabout.Selected then SELECTED_COLOR else RING_COLOR,
					Transparency = 0.4,
					AlwaysOnTop = false,
					ZIndex = 0,
				})
			end
		end
	end
	return Roact.createElement("Folder", {}, children)
end

-- Where the mouse ray meets the roundabout's ground plane, in its local XZ
local function localGroundPoint(pivot: CFrame, mouseRay): (number?, number?)
	local origin = pivot:PointToObjectSpace(mouseRay.Origin)
	local direction = pivot:VectorToObjectSpace(mouseRay.Direction.Unit)
	if math.abs(direction.Y) < 1e-4 then
		return nil, nil
	end
	local t = -origin.Y / direction.Y
	if t <= 0 then
		return nil, nil
	end
	local p = origin + direction * t
	return p.X, p.Z
end

local function snap(value: number): number
	if DraggerService.LinearSnapEnabled then
		local increment = DraggerService.LinearSnapIncrement
		if increment > 0 then
			return math.floor(value / increment + 0.5) * increment
		end
	end
	return value
end

function IslandShapeHandles:mouseDown(mouseRay, handleId)
	local handle = self._handles[handleId]
	local roundabout = self._roundabout
	if not handle or not roundabout then
		return
	end
	local x, z = localGroundPoint(roundabout.Pivot, mouseRay)
	if not x or not z then
		return
	end
	local circle = roundabout.Circles[handle.Index]
	self._dragging = handleId
	self._kind = handle.Kind
	self._index = handle.Index
	self._pivot = roundabout.Pivot
	-- Drag relative to where the knob was grabbed, so it doesn't jump
	self._grabX, self._grabZ = x, z
	self._startX, self._startZ, self._startRadius = circle.X, circle.Z, circle.Radius
	self._props.SelectCorner(handle.Index)
	self._props.StartEdit()
end

function IslandShapeHandles:mouseDrag(mouseRay)
	if not self._dragging then
		return
	end
	local x, z = localGroundPoint(self._pivot, mouseRay)
	if not x or not z then
		return
	end
	if self._kind == "Corner" then
		self._props.MoveCorner(
			self._index,
			self._startX + snap(x - self._grabX),
			self._startZ + snap(z - self._grabZ)
		)
	else
		local distance = math.sqrt((x - self._startX) ^ 2 + (z - self._startZ) ^ 2)
		local grabDistance = math.sqrt((self._grabX - self._startX) ^ 2 + (self._grabZ - self._startZ) ^ 2)
		self._props.SetCornerRadius(self._index, math.max(self._startRadius + snap(distance - grabDistance), 1))
	end
end

function IslandShapeHandles:mouseUp(mouseRay)
	if not self._dragging then
		return
	end
	self._dragging = nil
	self._props.EndEdit()
end

return IslandShapeHandles
