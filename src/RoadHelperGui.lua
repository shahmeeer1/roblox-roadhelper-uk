--!strict
local Plugin = script.Parent.Parent
local Packages = Plugin.Packages
local React = require(Packages.React)
local e = React.createElement

local Colors = require("./PluginGui/Colors")
local SubPanel = require("./PluginGui/SubPanel")
local NumberInput = require("./PluginGui/NumberInput")
local Checkbox = require("./PluginGui/Checkbox")
local ChipForToggle = require("./PluginGui/ChipForToggle")
local HelpGui = require("./PluginGui/HelpGui")
local PluginGui = require("./PluginGui/PluginGui")
local OperationButton = require("./PluginGui/OperationButton")
local PluginGuiTypes = require("./PluginGui/Types")

local createRoadSession = require("./createRoadSession")
local Presets = require("./Presets")
local RoadDefaults = require("./RoadDefaults")
local RoadMath = require("./RoadMath")
local Settings = require("./Settings")

local function createNextOrder(): () -> number
	local order = 0
	return function()
		order += 1
		return order
	end
end

local function TutorialStub(props: PluginGuiTypes.TutorialElementProps)
	return nil :: any
end

local ROADHELPER_CONFIG: PluginGuiTypes.PluginGuiConfig = {
	PluginName = "RoadHelper",
	PendingText = "Click the end of a road segment to select that endpoint.",
	TutorialElement = TutorialStub :: any,
}

local function describeStatus(state: createRoadSession.SelectionState): string
	if state.Kind == "none" then
		return "Click the end of a road segment to select that endpoint."
	elseif (state :: any).SegmentKind == "Roundabout" and (state :: any).ArmIndex then
		return "<b>Roundabout arm selected.</b>"
			.. "\nDrag the knob at its mouth to move it round, or a cone to extend it with a road. Click the island to select the whole roundabout."
	elseif (state :: any).SegmentKind == "Roundabout" then
		return "<b>Roundabout selected.</b>"
			.. "\nDrag the white knobs to reshape the island and the blue knobs to resize its corners; the central handles move the whole roundabout."
	elseif (state :: any).SegmentKind == "Intersection" then
		local junction = if (state :: any).MiniRoundabout then "Mini roundabout" else "Intersection"
		if state.Kind == "open" then
			return `<b>{junction} exit selected.</b>`
				.. "\nDrag a cone to extend this exit; the central handles move the whole junction."
		else
			return `<b>Connected {string.lower(junction)} exit selected.</b>`
		end
	elseif (state :: any).SegmentKind == "Split" then
		local which = if (state :: any).EndpointId == "Stem" then "stem" else "branch"
		if state.Kind == "open" then
			return `<b>Y split {which} selected.</b>`
				.. "\nDrag a cone to extend it; the central handles move the whole split."
		else
			return `<b>Connected Y split {which} selected.</b>`
				.. "\nThe central handles move the whole split; roads joined to it follow."
		end
	elseif state.Kind == "open" then
		return "<b>Open endpoint selected.</b>"
			.. "\nDrag the handles to move it, the rings to adjust its angles, or drag one of the cones to extend the road with a new segment."
	else
		return "<b>Joint selected.</b>"
			.. "\nDrag the handles to move the joint, or the rings to adjust its angles. Both segments follow."
	end
end

local function StatusPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	LayoutOrder: number?,
})
	return e(SubPanel, {
		Title = "Status",
		LayoutOrder = props.LayoutOrder,
	}, {
		Status = e("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			TextColor3 = Colors.WHITE,
			RichText = true,
			Text = describeStatus(props.SelectionState),
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.SourceSans,
			TextSize = 18,
		}),
	})
end

local function ParametersPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	SetAdjustValue: (axis: RoadMath.AdjustAxis, value: number) -> (),
	SetBlend: (value: boolean) -> (),
	SetSegmentAttribute: (name: string, value: any) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	if state.Kind == "none" then
		return nil :: any
	end
	if (state :: any).SegmentKind == "Intersection" then
		return e(SubPanel, {
			Title = "Parameters (Attributes)",
			Padding = UDim.new(0, 6),
			LayoutOrder = props.LayoutOrder,
		}, {
			AngleInput = e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "The angle between the intersection's two roads. The angled road's exits swing to match, and joined roads follow.",
				}),
				LayoutOrder = 1,
				Subject = e(NumberInput, {
					Label = "Angle",
					Value = (state :: any).IntersectionAngle,
					Unit = "°",
					ValueEntered = function(value: number): number?
						local clamped = math.clamp(value, RoadDefaults.MinIntersectionAngle, RoadDefaults.MaxIntersectionAngle)
						props.SetSegmentAttribute("IntersectionAngle", clamped)
						return clamped
					end,
				}),
			}),
			HaveSkirt = e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "Adds a sloped fill skirt along the intersection's edges that ramps down into the surrounding terrain.",
				}),
				LayoutOrder = 2,
				Subject = e(Checkbox, {
					Label = "Have skirt",
					Checked = state.Blend,
					Changed = props.SetBlend,
				}),
			}),
			MiniRoundabout = e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "Make this junction a mini roundabout, laid out as in the UK: a white central island 1 to 4 m across, every entry giving way to traffic from the right at a broken white line, and arrows showing the clockwise circulation.",
				}),
				LayoutOrder = 3,
				Subject = e(Checkbox, {
					Label = "Mini roundabout",
					Checked = (state :: any).MiniRoundabout,
					Changed = function(value: boolean)
						props.SetSegmentAttribute("MiniRoundabout", value)
					end,
				}),
			}),
			MiniRoundaboutRaised = if (state :: any).MiniRoundabout
				then e(HelpGui.WithHelpIcon, {
					Help = e(HelpGui.BasicTooltip, {
						HelpRichText = "A raised (domed) island, at most 125 mm high so vehicles can still run over it, with a darker centre ringed in white. Off for a flush painted circle.",
					}),
					LayoutOrder = 4,
					Subject = e(Checkbox, {
						Label = "Raised island",
						Checked = (state :: any).MiniRoundaboutRaised,
						Changed = function(value: boolean)
							props.SetSegmentAttribute("MiniRoundaboutRaised", value)
						end,
					}),
				})
				else nil,
			MiniRoundaboutDiameter = if (state :: any).MiniRoundabout
				then e(HelpGui.WithHelpIcon, {
					Help = e(HelpGui.BasicTooltip, {
						HelpRichText = "The central island's diameter in studs: UK mini roundabout islands are 1 to 4 m across (7 to 26 studs). It's also kept to half the narrower road's width, leaving room to drive round.",
					}),
					LayoutOrder = 5,
					Subject = e(NumberInput, {
						Label = "Island Diameter",
						Value = (state :: any).MiniRoundaboutDiameter,
						ValueEntered = function(value: number): number?
							local diameter = math.clamp(
								value,
								RoadDefaults.MiniRoundaboutMinDiameter,
								RoadDefaults.MiniRoundaboutMaxDiameter
							)
							props.SetSegmentAttribute("MiniRoundaboutDiameter", diameter)
							return diameter
						end,
					}),
				})
				else nil,
		})
	end
	if (state :: any).SegmentKind == "Split" or (state :: any).SegmentKind == "Roundabout" then
		-- Splits and roundabouts are flat: no angles to edit
		return e(SubPanel, {
			Title = "Parameters (Attributes)",
			Padding = UDim.new(0, 6),
			LayoutOrder = props.LayoutOrder,
		}, {
			HaveSkirt = e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "Adds a sloped fill skirt along the outer edges that ramps down into the surrounding terrain.",
				}),
				LayoutOrder = 1,
				Subject = e(Checkbox, {
					Label = "Have skirt",
					Checked = state.Blend,
					Changed = props.SetBlend,
				}),
			}),
		})
	end
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Parameters (Attributes)",
		Padding = UDim.new(0, 6),
		LayoutOrder = props.LayoutOrder,
	}, {
		DirectionInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Horizontal angle of the road face at this end, pivoting about the endpoint. A joined neighbor's end follows so the joint stays sealed.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Direction",
				Value = state.Dir,
				Unit = "°",
				ValueEntered = function(value: number): number?
					props.SetAdjustValue("Dir", value)
					return value
				end,
			}),
		}),
		GradeInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Vertical slope of the road at this end. Positive slopes upward heading out of the segment.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Grade",
				Value = state.Grade,
				Unit = "°",
				ValueEntered = function(value: number): number?
					props.SetAdjustValue("Grade", value)
					return value
				end,
			}),
		}),
		BankInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Roll of the road surface at this end, for banking corners. The surface twists smoothly between the two ends' bank angles.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(NumberInput, {
				Label = "Bank",
				Value = state.Bank,
				Unit = "°",
				ValueEntered = function(value: number): number?
					props.SetAdjustValue("Bank", value)
					return value
				end,
			}),
		}),
		HaveSkirt = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Adds a sloped fill skirt along the road edges that ramps down into the surrounding terrain, hiding the hard seam.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(Checkbox, {
				Label = "Have skirt",
				Checked = state.Blend,
				Changed = props.SetBlend,
			}),
		}),
	})
end

local DETAIL_LEVELS = {
	{ Label = "Low", MaxAngle = 15 },
	{ Label = "Normal", MaxAngle = 10 },
	{ Label = "High", MaxAngle = 5 },
}

local function DetailPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	SetSegmentAttribute: (name: string, value: any) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	-- Y splits and roundabouts don't tessellate by angle
	if state.Kind == "none" or (state :: any).SegmentKind == "Split" or (state :: any).SegmentKind == "Roundabout" then
		return nil :: any
	end
	local chips: { [string]: any } = {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	}
	for index, level in DETAIL_LEVELS do
		chips[level.Label] = e(ChipForToggle, {
			Text = level.Label,
			IsCurrent = state.MaxAngle == level.MaxAngle,
			LayoutOrder = index,
			OnClick = function()
				props.SetSegmentAttribute("MaxAngle", level.MaxAngle)
			end,
		})
	end
	return e(SubPanel, {
		Title = "Detail Level",
		Padding = UDim.new(0, 6),
		LayoutOrder = props.LayoutOrder,
	}, {
		Chips = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "How finely the road surface is tessellated (how many degrees of turn or twist each row of parts may span). Higher detail looks smoother but uses more parts.",
			}),
			LayoutOrder = 2,
			Subject = e("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				BorderSizePixel = 0,
				BackgroundColor3 = Colors.ACTION_BLUE,
				AutomaticSize = Enum.AutomaticSize.Y,
			}, chips),
		}),
	})
end

local LANE_MARKING_MODES = { "None", "Parts", "Textured" }

local function LaneMarkingsPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	SetLaneMarkings: (mode: string) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	if state.Kind == "none" then
		return nil :: any
	end
	local current = if not (state :: any).HaveLaneMarkings
		then "None"
		elseif state.TextureLaneMarkings then "Textured"
		else "Parts"
	local chips: { [string]: any } = {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	}
	for index, mode in LANE_MARKING_MODES do
		chips[mode] = e(ChipForToggle, {
			Text = mode,
			IsCurrent = current == mode,
			LayoutOrder = index,
			OnClick = function()
				props.SetLaneMarkings(mode)
			end,
		})
	end
	return e(SubPanel, {
		Title = "Lane Markings",
		LayoutOrder = props.LayoutOrder,
	}, {
		Chips = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "\u{2022} <b>None</b> hides the lane markings, leaving clear pavement to paint custom markings on."
					.. "\n\u{2022} <b>Parts</b> draws them as solid colored strips."
					.. "\n\u{2022} <b>Textured</b> paints them with textures, including properly dashed divider lines, at a small perf cost.",
			}),
			Subject = e("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				BorderSizePixel = 0,
				BackgroundColor3 = Colors.ACTION_BLUE,
				AutomaticSize = Enum.AutomaticSize.Y,
			}, chips),
		}),
	})
end

local LANE_CHANGE_SIDES = { "Offside", "Nearside" }

local function SizingPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	SetSizing: (name: string, value: number) -> (),
	SetSameLanesBothEnds: (same: boolean) -> (),
	SetSegmentAttribute: (name: string, value: any) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState
	-- Roundabouts have their own panel
	if state.Kind == "none" or (state :: any).SegmentKind == "Roundabout" then
		return nil :: any
	end
	local lanesEditable = (state :: any).LaneCountsEditable
	local isSplit = (state :: any).SegmentKind == "Split"
	-- A split's branches take a share of the stem's lanes rather than
	-- having lanes out/in of their own
	local isSplitBranch = isSplit and (state :: any).EndpointId ~= "Stem"
	local showLaneCounts = lanesEditable and not isSplitBranch
	-- A split's stem needs two lanes to divide between its branches
	local minLanes = if isSplit then 2 else 1
	local laneChangeSideChips: { [string]: any } = {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	}
	for index, side in LANE_CHANGE_SIDES do
		laneChangeSideChips[side] = e(ChipForToggle, {
			Text = side,
			IsCurrent = (state :: any).LaneChangeSide == side,
			LayoutOrder = index,
			OnClick = function()
				props.SetSegmentAttribute("LaneChangeSide", side)
			end,
		})
	end
	return e(SubPanel, {
		Title = "Sizing",
		Padding = UDim.new(0, 6),
		LayoutOrder = props.LayoutOrder,
	}, {
		LanesHint = if not lanesEditable
			then e("TextLabel", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				TextColor3 = Colors.OFFWHITE,
				Text = "This end is joined to another road, so its lanes can't change on their own. Select the open end of this lane change, or tick Same at both ends.",
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				Font = Enum.Font.SourceSans,
				TextSize = 16,
				LayoutOrder = 1,
			})
			else nil,
		LanesOutInput = if showLaneCounts then e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Lanes carrying traffic <b>out</b> through the selected end. Zero makes a one-way road. The centre line sits between the two directions, and the bounds adjust so both endpoints stay in place.",
			}),
			LayoutOrder = 1,
			Subject = e(NumberInput, {
				Label = "Lanes Out",
				Value = state.LanesOut,
				ValueEntered = function(value: number): number?
					local count = math.max(math.round(value), 0)
					if count + state.LanesIn < minLanes then
						-- Too few lanes in all: revert
						return state.LanesOut
					end
					props.SetSizing("LanesOut", count)
					return count
				end,
			}),
		}) else nil,
		LanesInInput = if showLaneCounts then e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Lanes carrying traffic <b>in</b> through the selected end. Zero makes a one-way road. The centre line sits between the two directions, and the bounds adjust so both endpoints stay in place.",
			}),
			LayoutOrder = 2,
			Subject = e(NumberInput, {
				Label = "Lanes In",
				Value = state.LanesIn,
				ValueEntered = function(value: number): number?
					local count = math.max(math.round(value), 0)
					if count + state.LanesOut < minLanes then
						-- Too few lanes in all: revert
						return state.LanesIn
					end
					props.SetSizing("LanesIn", count)
					return count
				end,
			}),
		}) else nil,
		SameLanesCheckbox = if (state :: any).CanChangeLanes
			then e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "Untick to give the two ends different lane counts: a lane change. Lanes Out / In then set just the selected end, which must be open. The road tapers over its whole length, and the other direction runs straight through.",
				}),
				LayoutOrder = 3,
				Subject = e(Checkbox, {
					Label = "Same at both ends",
					Checked = (state :: any).SameLanesBothEnds,
					Changed = props.SetSameLanesBothEnds,
				}),
			})
			else nil,
		LaneChangeSide = if (state :: any).CanChangeLanes and (state :: any).LanesDiffer
			then e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "Which lane ends or starts.\n\u{2022} <b>Offside</b>: the lane by the centre line, e.g. a right-turn lane opening before a junction."
						.. "\n\u{2022} <b>Nearside</b>: the lane by the kerb, e.g. a lane ending after a merge.",
				}),
				LayoutOrder = 4,
				Subject = e("Frame", {
					Size = UDim2.new(1, 0, 0, 0),
					BorderSizePixel = 0,
					BackgroundColor3 = Colors.ACTION_BLUE,
					AutomaticSize = Enum.AutomaticSize.Y,
				}, laneChangeSideChips),
			})
			else nil,
		BranchLanesInput = if isSplitBranch
			then e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "How many of the stem's lanes this branch takes, counted from its outer edge; the other branch takes the rest. Each lane keeps its direction, so taking exactly one direction's lanes separates a two-way road into a dual carriageway.",
				}),
				LayoutOrder = 1,
				Subject = e(NumberInput, {
					Label = "Branch Lanes",
					Value = (state :: any).SplitBranchLanes,
					ValueEntered = function(value: number): number?
						local total = (state :: any).SplitTotalLanes
						local count = math.clamp(math.round(value), 1, math.max(total - 1, 1))
						props.SetSizing("BranchLanes", count)
						return count
					end,
				}),
			})
			else nil,
		SplitSeparationInput = if isSplit
			then e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "The gap between the two branch roads (outside their footways) at the far end, in studs. The gore between them is hatched up to the nose, then a raised island. Roads joined to the branches follow.",
				}),
				LayoutOrder = 9,
				Subject = e(NumberInput, {
					Label = "Separation",
					Value = (state :: any).SplitSeparation,
					ValueEntered = function(value: number): number?
						local separation = math.max(value, 0)
						props.SetSizing("SplitSeparation", separation)
						return separation
					end,
				}),
			})
			else nil,
		SplitLengthInput = if isSplit
			then e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "How far the branches take to part, in studs. UK diverges on faster roads are long and gentle; the stem stays put and the branches move.",
				}),
				LayoutOrder = 10,
				Subject = e(NumberInput, {
					Label = "Length",
					Value = (state :: any).SplitLength,
					ValueEntered = function(value: number): number?
						if value <= 0 then
							return (state :: any).SplitLength
						end
						props.SetSizing("SplitLength", value)
						return value
					end,
				}),
			})
			else nil,
		LaneWidthInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Width of each lane in studs. The bounds adjust so both endpoints stay in place.",
			}),
			LayoutOrder = 5,
			Subject = e(NumberInput, {
				Label = "Lane Width",
				Value = state.LaneWidth,
				ValueEntered = function(value: number): number?
					if value <= 0 then
						return nil
					end
					props.SetSizing("LaneWidth", value)
					return value
				end,
			}),
		}),
		SidewalkWidthInput = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Width of the raised sidewalk on each side, in studs. Zero removes the sidewalks entirely.",
			}),
			LayoutOrder = 6,
			Subject = e(NumberInput, {
				Label = "Sidewalk Width",
				Value = state.SidewalkWidth,
				ValueEntered = function(value: number): number?
					local width = math.max(value, 0)
					props.SetSizing("SidewalkWidth", width)
					return width
				end,
			}),
		}),
		CrossingWidthInput = if (state :: any).SegmentKind == "Intersection"
			then e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "Width of the zebra crosswalks in front of the stop lines. Zero removes them. The bounding box grows to make room, so the turning space is kept.",
				}),
				LayoutOrder = 8,
				Subject = e(NumberInput, {
					Label = "Crosswalk Width",
					Value = (state :: any).CrossingWidth,
					ValueEntered = function(value: number): number?
						local width = math.max(value, 0)
						props.SetSizing("CrossingWidth", width)
						return width
					end,
				}),
			})
			else nil,
		CornerRadiusInput = if (state :: any).SegmentKind == "Intersection"
			then e(HelpGui.WithHelpIcon, {
				Help = e(HelpGui.BasicTooltip, {
					HelpRichText = "The corner curve radius, controlled through the bounding box size beyond what the roads' widths require. Exact for 90 degree intersections; skewed corners vary around it.",
				}),
				LayoutOrder = 7,
				Subject = e(NumberInput, {
					Label = "Corner Radius",
					Value = (state :: any).CornerRadius,
					ValueEntered = function(value: number): number?
						local radius = math.max(value, 0)
						props.SetSizing("CornerRadius", radius)
						return radius
					end,
				}),
			})
			else nil,
	})
end

local function AddPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	CurrentSettings: Settings.RoadHelperSettings,
	UpdatedSettings: () -> (),
	AddSegment: (kind: RoadMath.SegmentKind) -> (),
	AddIntersection: (throughRoad: boolean, miniRoundabout: boolean?) -> (),
	AddRoundabout: () -> (),
	LayoutOrder: number?,
})
	-- With an endpoint selected the add handles in the viewport are the way to
	-- extend the road; the camera-add section only applies when nothing is.
	if props.SelectionState.Kind ~= "none" then
		return nil :: any
	end
	local nextOrder = createNextOrder()
	return e(SubPanel, {
		Title = "Add",
		Padding = UDim.new(0, 8),
		LayoutOrder = props.LayoutOrder,
	}, {
		Hint = e("TextLabel", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			TextColor3 = Colors.OFFWHITE,
			Text = "Add a segment in front of the camera:",
			TextWrapped = true,
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.SourceSans,
			TextSize = 16,
			LayoutOrder = nextOrder(),
		}),
		AlignToWorld = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Snap added segments to the nearest world axis instead of following the camera's heading.",
			}),
			LayoutOrder = nextOrder(),
			Subject = e(Checkbox, {
				Label = "Align to world",
				Checked = props.CurrentSettings.AlignToWorld,
				Changed = function(checked: boolean)
					props.CurrentSettings.AlignToWorld = checked
					props.UpdatedSettings()
				end,
			}),
		}),
		Buttons = e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 4),
			}),
			StraightButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 1,
			}, {
				Button = e(OperationButton, {
					Text = "Straight",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = function()
						props.AddSegment("Straight")
					end,
				}),
			}),
			CurveButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,
			}, {
				Button = e(OperationButton, {
					Text = "Curve",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = function()
						props.AddSegment("Curve")
					end,
				}),
			}),
		}),
		IntersectionButtons = e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 4),
			}),
			TButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 1,
			}, {
				Button = e(OperationButton, {
					Text = "T Junction",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = function()
						props.AddIntersection(false)
					end,
				}),
			}),
			XButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,
			}, {
				Button = e(OperationButton, {
					Text = "X Junction",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = function()
						props.AddIntersection(true)
					end,
				}),
			}),
		}),
		RoundaboutButtons = e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = nextOrder(),
		}, {
			ListLayout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 4),
			}),
			MiniButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 1,
			}, {
				Button = e(OperationButton, {
					Text = "Mini Roundabout",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = function()
						props.AddIntersection(true, true)
					end,
				}),
			}),
			RoundaboutButton = e("Frame", {
				Size = UDim2.new(0.5, -2, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 2,
			}, {
				Button = e(OperationButton, {
					Text = "Roundabout",
					Height = 28,
					Disabled = false,
					Color = Colors.ACTION_BLUE,
					OnClick = props.AddRoundabout,
				}),
			}),
		}),
	})
end

local function PresetTile(props: {
	Preset: Presets.Preset,
	Selected: boolean,
	LayoutOrder: number?,
	OnClick: () -> (),
})
	local preset = props.Preset
	return e("ImageButton", {
		BackgroundColor3 = preset.PlaceholderColor,
		BorderSizePixel = 0,
		Image = preset.Image,
		ImageColor3 = preset.ImageTint or Color3.new(1, 1, 1),
		ScaleType = Enum.ScaleType.Crop,
		AutoButtonColor = true,
		LayoutOrder = props.LayoutOrder,
		[React.Event.MouseButton1Click] = props.OnClick,
	}, {
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 6),
		}),
		Stroke = if props.Selected
			then e("UIStroke", {
				Color = Colors.ACTION_BLUE,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
			})
			else nil,
		NameLabel = e("TextLabel", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -4),
			Size = UDim2.new(1, -8, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			Text = preset.Name,
			TextColor3 = Colors.WHITE,
			TextWrapped = true,
			Font = Enum.Font.SourceSansBold,
			TextSize = 14,
		}, {
			-- A UIStroke outlines the glyphs thicker and more opaque than
			-- the built-in TextStroke can
			Outline = e("UIStroke", {
				Color = Colors.BLACK,
				Thickness = 2,
				ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
			}),
		}),
	})
end

local function PresetsPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	CurrentSettings: Settings.RoadHelperSettings,
	UpdatedSettings: () -> (),
	LayoutOrder: number?,
})
	-- Shown alongside the Add section: presets only affect the add buttons
	if props.SelectionState.Kind ~= "none" then
		return nil :: any
	end
	local tiles: { [string]: any } = {
		Layout = e("UIGridLayout", {
			CellSize = UDim2.new(0.5, -3, 0, 54),
			CellPadding = UDim2.fromOffset(6, 6),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}
	for index, preset in Presets.List do
		local selected = props.CurrentSettings.SelectedPreset == preset.Key
		tiles[preset.Key] = e(PresetTile, {
			Preset = preset,
			Selected = selected,
			LayoutOrder = index,
			OnClick = function()
				-- Clicking the selected tile deselects it, going back to
				-- inheriting appearance from nearby roads
				props.CurrentSettings.SelectedPreset = if selected then "" else preset.Key
				props.UpdatedSettings()
			end,
		})
	end
	return e(SubPanel, {
		Title = "Preset",
		LayoutOrder = props.LayoutOrder,
	}, {
		Grid = e("Frame", {
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
		}, tiles),
	})
end

local function CloseButton(props: {
	HandleAction: (string) -> (),
	LayoutOrder: number?,
})
	return e("Frame", {
		Size = UDim2.fromScale(1, 0),
		BackgroundTransparency = 1,
		LayoutOrder = props.LayoutOrder,
		AutomaticSize = Enum.AutomaticSize.Y,
	}, {
		Padding = e("UIPadding", {
			PaddingTop = UDim.new(0, 8),
			PaddingBottom = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
		CancelButton = e(OperationButton, {
			Text = "Close <i>RoadHelper</i>",
			Color = Colors.DARK_RED,
			Disabled = false,
			Height = 30,
			OnClick = function()
				props.HandleAction("cancel")
			end,
		}),
	})
end

local ISLAND_SHAPE_NAMES = { "Circle", "Oval", "Square", "Rectangle", "Triangle" }

local function RoundaboutPanel(props: {
	SelectionState: createRoadSession.SelectionState,
	RoundaboutAction: (action: string, value: any) -> (),
	LayoutOrder: number?,
})
	local state = props.SelectionState :: any
	if state.Kind == "none" or state.SegmentKind ~= "Roundabout" then
		return nil :: any
	end
	local shapeChips: { [string]: any } = {
		ListLayout = e("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Left,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Wraps = true,
		}),
		Corner = e("UICorner", {
			CornerRadius = UDim.new(0, 4),
		}),
	}
	for index, shape in ISLAND_SHAPE_NAMES do
		shapeChips[shape] = e(ChipForToggle, {
			Text = shape,
			IsCurrent = false,
			LayoutOrder = index,
			OnClick = function()
				props.RoundaboutAction("Shape", shape)
			end,
		})
	end
	local function halfButton(text: string, order: number, disabled: boolean, onClick: () -> ())
		return e("Frame", {
			Size = UDim2.new(0.5, -2, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = order,
		}, {
			Button = e(OperationButton, {
				Text = text,
				Height = 28,
				Disabled = disabled,
				Color = Colors.ACTION_BLUE,
				OnClick = onClick,
			}),
		})
	end
	local function numberField(label: string, help: string, order: number, value: number, minimum: number, action: string)
		return e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = help,
			}),
			LayoutOrder = order,
			Subject = e(NumberInput, {
				Label = label,
				Value = value,
				ValueEntered = function(entered: number): number?
					local clamped = math.max(entered, minimum)
					props.RoundaboutAction(action, clamped)
					return clamped
				end,
			}),
		})
	end
	if state.ArmIndex then
		-- One of the roundabout's arms
		return e(SubPanel, {
			Title = `Roundabout Arm {state.ArmIndex}`,
			Padding = UDim.new(0, 6),
			LayoutOrder = props.LayoutOrder,
		}, {
			ExitLanes = numberField(
				"Exit Lanes",
				"Lanes leaving the roundabout along this arm. Zero makes it entry only.",
				1,
				state.ArmExit,
				0,
				"ArmExit"
			),
			EntryLanes = numberField(
				"Entry Lanes",
				"Lanes arriving at the roundabout along this arm, which give way to traffic already on it. Zero makes it exit only.",
				2,
				state.ArmEntry,
				0,
				"ArmEntry"
			),
			Position = numberField(
				"Position",
				"Where the arm leaves the roundabout, as an angle around the island in degrees. You can also drag the knob at its mouth; joined roads follow.",
				3,
				state.ArmAngle,
				-360,
				"ArmAngle"
			),
			Remove = e("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				LayoutOrder = 4,
			}, {
				Button = e(OperationButton, {
					Text = "Remove Arm",
					Height = 28,
					Disabled = false,
					Color = Colors.DARK_RED,
					OnClick = function()
						props.RoundaboutAction("RemoveArm")
					end,
				}),
			}),
		})
	end
	local selectedCorner = state.SelectedCorner
	return e(SubPanel, {
		Title = "Roundabout",
		Padding = UDim.new(0, 6),
		LayoutOrder = props.LayoutOrder,
	}, {
		Shapes = e(HelpGui.WithHelpIcon, {
			Help = e(HelpGui.BasicTooltip, {
				HelpRichText = "Start the island from a shape. The island is outlined around one or more circles: drag the white knobs to move them and the blue knobs to resize them, or add and remove circles below.",
			}),
			LayoutOrder = 1,
			Subject = e("Frame", {
				Size = UDim2.new(1, 0, 0, 0),
				BorderSizePixel = 0,
				BackgroundColor3 = Colors.ACTION_BLUE,
				AutomaticSize = Enum.AutomaticSize.Y,
			}, shapeChips),
		}),
		CornerButtons = e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 2,
		}, {
			ListLayout = e("UIListLayout", {
				SortOrder = Enum.SortOrder.LayoutOrder,
				FillDirection = Enum.FillDirection.Horizontal,
				Padding = UDim.new(0, 4),
			}),
			Add = halfButton("Add Corner", 1, state.RoundaboutCorners >= RoadDefaults.RoundaboutMaxCorners, function()
				props.RoundaboutAction("AddCorner")
			end),
			Remove = halfButton("Remove Corner", 2, selectedCorner == nil or state.RoundaboutCorners <= 1, function()
				props.RoundaboutAction("RemoveCorner")
			end),
		}),
		CornerRadius = if selectedCorner
			then numberField(
				"Corner Radius",
				"The selected circle's radius in studs. The island is the shape wrapping all its circles, so this rounds that corner (or sizes a round island).",
				3,
				state.SelectedCornerRadius,
				1,
				"CornerRadius"
			)
			else nil,
		CornerHint = if not selectedCorner
			then e("TextLabel", {
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
				TextColor3 = Colors.OFFWHITE,
				Text = "Click a white knob to select a corner.",
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				Font = Enum.Font.SourceSans,
				TextSize = 16,
				LayoutOrder = 3,
			})
			else nil,
		RingLanes = numberField(
			"Ring Lanes",
			"Lanes on the circulating carriageway (all one way: clockwise when driving on the left).",
			4,
			state.RingLanes,
			1,
			"RingLanes"
		),
		LaneWidth = numberField(
			"Lane Width",
			"Width of each circulating lane in studs.",
			5,
			state.LaneWidth,
			1,
			"LaneWidth"
		),
		SidewalkWidth = numberField(
			"Footway Width",
			"Width of the footway around the outside, in studs. Zero leaves none.",
			6,
			state.SidewalkWidth,
			0,
			"SidewalkWidth"
		),
		ApronWidth = numberField(
			"Apron Width",
			"A raised apron around the island that long vehicles can run over, with a low kerb (common on UK roundabouts). Zero leaves none.",
			7,
			state.ApronWidth,
			0,
			"ApronWidth"
		),
		AddArm = e("Frame", {
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundTransparency = 1,
			LayoutOrder = 8,
		}, {
			Button = e(OperationButton, {
				Text = `Add Arm ({state.ArmCount} now)`,
				Height = 28,
				Disabled = state.ArmCount >= 12,
				Color = Colors.ACTION_BLUE,
				OnClick = function()
					props.RoundaboutAction("AddArm")
				end,
			}),
		}),
		ArmLength = numberField(
			"Arm Length",
			"How far every arm runs out from the ring before its road end, in studs.",
			9,
			state.ArmLength,
			1,
			"ArmLength"
		),
		SplitterWidth = numberField(
			"Splitter Width",
			"Width of the splitter island between each arm's entry and exit lanes at the ring, in studs. It tapers away along the arm, hatched ahead of its kerbed nose. Zero leaves just a centre line.",
			10,
			state.SplitterWidth,
			0,
			"SplitterWidth"
		),
		EntryKerbRadius = numberField(
			"Kerb Radius",
			"Radius of the kerbs curving from each arm into the ring, in studs.",
			11,
			state.EntryKerbRadius,
			1,
			"EntryKerbRadius"
		),
	})
end

local function RoadHelperGui(props: {
	GuiState: PluginGuiTypes.PluginGuiMode,
	SelectionState: createRoadSession.SelectionState,
	SetAdjustValue: (axis: RoadMath.AdjustAxis, value: number) -> (),
	SetBlend: (value: boolean) -> (),
	SetSegmentAttribute: (name: string, value: any) -> (),
	SetLaneMarkings: (mode: string) -> (),
	SetSizing: (name: string, value: number) -> (),
	SetSameLanesBothEnds: (same: boolean) -> (),
	RoundaboutAction: (action: string, value: any) -> (),
	AddSegment: (kind: RoadMath.SegmentKind) -> (),
	AddIntersection: (throughRoad: boolean, miniRoundabout: boolean?) -> (),
	AddRoundabout: () -> (),
	CurrentSettings: Settings.RoadHelperSettings,
	UpdatedSettings: () -> (),
	HandleAction: (string) -> (),
	Panelized: boolean,
})
	local nextOrder = createNextOrder()
	return e(PluginGui, {
		Config = ROADHELPER_CONFIG,
		State = {
			Mode = props.GuiState,
			Settings = props.CurrentSettings,
			UpdatedSettings = props.UpdatedSettings,
			HandleAction = props.HandleAction,
			Panelized = props.Panelized,
		},
	}, {
		StatusPanel = e(StatusPanel, {
			SelectionState = props.SelectionState,
			LayoutOrder = nextOrder(),
		}),
		ParametersPanel = e(ParametersPanel, {
			SelectionState = props.SelectionState,
			SetAdjustValue = props.SetAdjustValue,
			SetBlend = props.SetBlend,
			SetSegmentAttribute = props.SetSegmentAttribute,
			LayoutOrder = nextOrder(),
		}),
		DetailPanel = e(DetailPanel, {
			SelectionState = props.SelectionState,
			SetSegmentAttribute = props.SetSegmentAttribute,
			LayoutOrder = nextOrder(),
		}),
		LaneMarkingsPanel = e(LaneMarkingsPanel, {
			SelectionState = props.SelectionState,
			SetLaneMarkings = props.SetLaneMarkings,
			LayoutOrder = nextOrder(),
		}),
		SizingPanel = e(SizingPanel, {
			SelectionState = props.SelectionState,
			SetSizing = props.SetSizing,
			SetSameLanesBothEnds = props.SetSameLanesBothEnds,
			SetSegmentAttribute = props.SetSegmentAttribute,
			LayoutOrder = nextOrder(),
		}),
		RoundaboutPanel = e(RoundaboutPanel, {
			SelectionState = props.SelectionState,
			RoundaboutAction = props.RoundaboutAction,
			LayoutOrder = nextOrder(),
		}),
		AddPanel = e(AddPanel, {
			SelectionState = props.SelectionState,
			CurrentSettings = props.CurrentSettings,
			UpdatedSettings = props.UpdatedSettings,
			AddSegment = props.AddSegment,
			AddIntersection = props.AddIntersection,
			AddRoundabout = props.AddRoundabout,
			LayoutOrder = nextOrder(),
		}),
		PresetsPanel = e(PresetsPanel, {
			SelectionState = props.SelectionState,
			CurrentSettings = props.CurrentSettings,
			UpdatedSettings = props.UpdatedSettings,
			LayoutOrder = nextOrder(),
		}),
		CloseButton = e(CloseButton, {
			HandleAction = props.HandleAction,
			LayoutOrder = nextOrder(),
		}),
	})
end

return RoadHelperGui
