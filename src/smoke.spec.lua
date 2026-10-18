local TestTypes = require("./TestTypes")

--[[
	Smoke test: just require every module to catch syntax errors, bad requires,
	and top-level mistakes. The interactive behavior needs a live plugin
	context, so it is exercised manually in Studio.
]]

return function(t: TestTypes.TestContext)
	t.test("all modules load", function()
		require("./RoadMath")
		require("./RoadDefaults")
		require("./Presets")
		require("./Settings")
		require("./createRoadSession")
		require("./RoadHelperGui")
		require("./main")
		require("./Handles/EndpointPickHandles")
		require("./Handles/EndpointMoveHandles")
		require("./Handles/EndpointRotateHandles")
		require("./Handles/AddHandles")
		require("./Handles/DeleteExitHandles")
		require("./Dragger/MoveHandleView")
		require("./Dragger/PartialRotateHandleView")
		require("./PluginGui/Checkbox")
		require("./PluginGui/ChipForToggle")
		require("./PluginGui/Colors")
		require("./PluginGui/HelpGui")
		require("./PluginGui/NumberInput")
		require("./PluginGui/OperationButton")
		require("./PluginGui/PluginGui")
		require("./PluginGui/SubPanel")
		require("./PluginGui/Types")
		-- The packaged fallback generator templates must at least load
		require("./Templates/StraightRoadGenerator")
		require("./Templates/CurveRoadGenerator")
		require("./Templates/RoadIntersectionGenerator")
	end)
end
