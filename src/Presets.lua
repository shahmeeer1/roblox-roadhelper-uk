--!strict
--[[
	Appearance presets for newly added road segments, shown as image tiles in
	the Presets section of the panel. Selecting one applies its attributes to
	segments created with the Add Straight/Curve buttons; with none selected,
	new segments inherit their appearance from the selection or the nearest
	segment as usual.

	Image is the tile picture (screenshot of the preset); PlaceholderColor
	shows while an image id hasn't been provided yet.

	The UK presets keep the plugin's scale, where a standard 3.65 m UK lane
	is 24 studs (about 6.6 studs per metre); their other dimensions are
	real UK widths converted at that ratio. They all drive on the left.
]]

export type Preset = {
	Key: string,
	Name: string,
	Image: string,
	-- Multiplied over the tile image (ImageColor3), for retinting a
	-- screenshot without retaking it
	ImageTint: Color3?,
	PlaceholderColor: Color3,
	Attributes: { [string]: any },
}

-- UK road colours: black asphalt for fresh surfaces (asphalt renders fairly
-- light, so it needs a pure black tint), dark grey for weathered rural
-- surfaces, white markings throughout and pale grey paving-slab footways
local UK_FRESH_ASPHALT = Color3.fromRGB(0, 0, 0)
local UK_WEATHERED_ASPHALT = Color3.fromRGB(35, 35, 37)
local UK_MARKING_WHITE = Color3.fromRGB(235, 235, 235)
local UK_FOOTWAY = Color3.fromRGB(150, 150, 146)

local List: { Preset } = {
	{
		Key = "UKARoad",
		Name = "UK A Road",
		Image = "",
		PlaceholderColor = Color3.fromRGB(28, 28, 30),
		-- Single carriageway: two 3.65 m lanes, 2 m footways
		Attributes = {
			LaneWidth = 24,
			LaneCount = 2,
			SidewalkWidth = 13,
			TextureLaneMarkings = true,
			HaveLaneMarkings = true,
			DriveSide = "Left",
			RoadMaterial = Enum.Material.Asphalt,
			RoadColor = UK_FRESH_ASPHALT,
			SidewalkColor = UK_FOOTWAY,
			CenterlineColor = UK_MARKING_WHITE,
			LaneMarkingColor = UK_MARKING_WHITE,
		},
	},
	{
		Key = "UKUrbanMultiLane",
		Name = "UK Urban 4-Lane",
		Image = "",
		PlaceholderColor = Color3.fromRGB(34, 34, 38),
		-- Two 3.65 m lanes each way with 3 m town-centre footways
		Attributes = {
			LaneWidth = 24,
			LaneCount = 4,
			SidewalkWidth = 20,
			TextureLaneMarkings = true,
			HaveLaneMarkings = true,
			DriveSide = "Left",
			RoadMaterial = Enum.Material.Asphalt,
			RoadColor = UK_FRESH_ASPHALT,
			SidewalkColor = UK_FOOTWAY,
			CenterlineColor = UK_MARKING_WHITE,
			LaneMarkingColor = UK_MARKING_WHITE,
		},
	},
	{
		Key = "UKResidential",
		Name = "UK Residential",
		Image = "",
		PlaceholderColor = Color3.fromRGB(40, 40, 44),
		-- 5.5 m carriageway (two 2.75 m lanes), 2 m footways, and unmarked
		-- like most residential streets
		Attributes = {
			LaneWidth = 18,
			LaneCount = 2,
			SidewalkWidth = 13,
			TextureLaneMarkings = true,
			HaveLaneMarkings = false,
			DriveSide = "Left",
			RoadMaterial = Enum.Material.Asphalt,
			RoadColor = UK_FRESH_ASPHALT,
			SidewalkColor = UK_FOOTWAY,
			CenterlineColor = UK_MARKING_WHITE,
			LaneMarkingColor = UK_MARKING_WHITE,
		},
	},
	{
		Key = "UKBRoad",
		Name = "UK B Road",
		Image = "",
		PlaceholderColor = Color3.fromRGB(46, 46, 48),
		-- Rural single carriageway: two 3 m lanes, no footways
		Attributes = {
			LaneWidth = 20,
			LaneCount = 2,
			SidewalkWidth = 0,
			TextureLaneMarkings = true,
			HaveLaneMarkings = true,
			DriveSide = "Left",
			RoadMaterial = Enum.Material.Asphalt,
			RoadColor = UK_WEATHERED_ASPHALT,
			SidewalkColor = UK_WEATHERED_ASPHALT,
			CenterlineColor = UK_MARKING_WHITE,
			LaneMarkingColor = UK_MARKING_WHITE,
		},
	},
	{
		Key = "UKCountryLane",
		Name = "UK Country Lane",
		Image = "",
		PlaceholderColor = Color3.fromRGB(52, 60, 40),
		-- Single-track 3 m lane, unmarked, with a grass verge skirt (off by
		-- default; toggle "Have skirt")
		Attributes = {
			LaneWidth = 20,
			LaneCount = 1,
			SidewalkWidth = 0,
			TextureLaneMarkings = false,
			HaveLaneMarkings = false,
			DriveSide = "Left",
			RoadMaterial = Enum.Material.Asphalt,
			RoadColor = UK_WEATHERED_ASPHALT,
			SidewalkColor = UK_WEATHERED_ASPHALT,
			BlendMaterial = Enum.Material.Grass,
			BlendColor = Color3.fromRGB(74, 104, 40),
		},
	},
	{
		Key = "Classic",
		Name = "Classic Roblox",
		Image = "rbxassetid://84342795346543",
		PlaceholderColor = Color3.fromRGB(26, 42, 52),
		-- The ProceduralModel generator defaults
		Attributes = {
			LaneWidth = 24,
			LaneCount = 2,
			SidewalkWidth = 8,
			TextureLaneMarkings = false,
			HaveLaneMarkings = true,
			RoadMaterial = Enum.Material.Concrete,
			RoadColor = Color3.fromRGB(26, 42, 52),
			SidewalkColor = Color3.fromRGB(163, 162, 165),
			CenterlineColor = Color3.fromRGB(244, 205, 47),
			LaneMarkingColor = Color3.fromRGB(163, 161, 165),
		},
	},
	{
		Key = "Dirt",
		Name = "Dirt Road",
		Image = "rbxassetid://108785564035719",
		PlaceholderColor = Color3.fromRGB(104, 60, 30),
		-- Single unmarked lane of dirt, no sidewalks; the blend skirt (off by
		-- default) is dirt as well rather than the usual grass
		Attributes = {
			LaneWidth = 24,
			LaneCount = 1,
			SidewalkWidth = 0,
			TextureLaneMarkings = false,
			HaveLaneMarkings = false,
			RoadMaterial = Enum.Material.Ground,
			RoadColor = Color3.fromRGB(104, 60, 30),
			SidewalkColor = Color3.fromRGB(104, 60, 30),
			BlendMaterial = Enum.Material.Ground,
			BlendColor = Color3.fromRGB(104, 60, 30),
		},
	},
	{
		Key = "RealisticSidewalk",
		Name = "Real, Sidewalk",
		Image = "rbxassetid://94872746387137",
		PlaceholderColor = Color3.fromRGB(20, 20, 22),
		-- Black asphalt, white edge/divider lines, saturated yellow center
		Attributes = {
			LaneWidth = 24,
			LaneCount = 2,
			SidewalkWidth = 8,
			TextureLaneMarkings = true,
			HaveLaneMarkings = true,
			-- Asphalt renders fairly light, so it needs a pure black tint
			RoadMaterial = Enum.Material.Asphalt,
			RoadColor = Color3.fromRGB(0, 0, 0),
			SidewalkColor = Color3.fromRGB(163, 162, 165),
			CenterlineColor = Color3.fromRGB(255, 191, 0),
			LaneMarkingColor = Color3.fromRGB(235, 235, 235),
		},
	},
	{
		Key = "RealisticOpen",
		Name = "Real, no Sidewalk",
		Image = "rbxassetid://85463536875783",
		PlaceholderColor = Color3.fromRGB(28, 28, 30),
		Attributes = {
			LaneWidth = 24,
			LaneCount = 2,
			SidewalkWidth = 0,
			TextureLaneMarkings = true,
			HaveLaneMarkings = true,
			-- Asphalt renders fairly light, so it needs a pure black tint
			RoadMaterial = Enum.Material.Asphalt,
			RoadColor = Color3.fromRGB(0, 0, 0),
			SidewalkColor = Color3.fromRGB(163, 162, 165),
			CenterlineColor = Color3.fromRGB(255, 191, 0),
			LaneMarkingColor = Color3.fromRGB(235, 235, 235),
		},
	},
	{
		Key = "Cobblestone",
		Name = "Cobblestone Path",
		Image = "rbxassetid://122561563144022",
		ImageTint = Color3.fromRGB(140, 160, 200),
		PlaceholderColor = Color3.fromRGB(59, 67, 74),
		Attributes = {
			LaneWidth = 16,
			LaneCount = 1,
			SidewalkWidth = 0,
			TextureLaneMarkings = false,
			HaveLaneMarkings = false,
			RoadMaterial = Enum.Material.Cobblestone,
			RoadColor = Color3.fromRGB(59, 67, 74),
			SidewalkColor = Color3.fromRGB(59, 67, 74),
		},
	},
	{
		Key = "Pebble",
		Name = "Pebble Path",
		Image = "rbxassetid://119185543748250",
		PlaceholderColor = Color3.fromRGB(140, 140, 136),
		Attributes = {
			LaneWidth = 16,
			LaneCount = 1,
			SidewalkWidth = 0,
			TextureLaneMarkings = false,
			HaveLaneMarkings = false,
			RoadMaterial = Enum.Material.Pebble,
			RoadColor = Color3.fromRGB(140, 140, 136),
			SidewalkColor = Color3.fromRGB(140, 140, 136),
		},
	},
}

local ByKey: { [string]: Preset } = {}
for _, preset in List do
	ByKey[preset.Key] = preset
end

return {
	List = List,
	ByKey = ByKey,
	-- Selected on a fresh install
	DefaultKey = "UKARoad",
}
