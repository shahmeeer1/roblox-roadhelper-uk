# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RoadHelper is a Roblox Studio plugin (based on the Redupe plugin's architecture) for working
with procedural road segments — `ProceduralModel` instances containing a
`StraightRoadGenerator`, `CurveRoadGenerator` or `RoadIntersectionGenerator` ModuleScript, as
found in the ProceduralCarts place. This fork is being adapted for realistic UK roads. The core
mechanic is selecting and manipulating segment *endpoints*:

- A road endpoint is one end of a segment: **blue** (start/entry) or **red** (end/exit),
  matching the road generators' `AdjustBlue*`/`AdjustRed*` attribute naming. Intersections
  have one endpoint ("exit") per stub instead: `ZPlus`/`ZMinus`/`XPlus`/`XMinus`.
- An endpoint is **open** (no adjacent road) or **closed** (two segment ends joined).
- Selected road endpoints get **move handles** (repositions the endpoint by editing the
  segment's Size/pivot/Flip — both segments for a closed joint) and **rotate handles** (edits
  the `AdjustBlue/RedDir/Grade/Bank` attributes — both sides of a closed joint stay continuous).
  A road end joined flush to an intersection carries the whole intersection along.
- Open endpoints additionally get **add handles** (left turn / straight / right turn, plus
  intersection on road ends): click to append a new segment, click-drag to place its far
  endpoint following the cursor.
- Selecting an intersection exit shows handles at the intersection's centre: move, yaw ring,
  an angle ring for the skewed road, and delete/restore markers that toggle between a 4-way
  crossing and a T junction. Connected roads are re-seated to follow.
- The UI panel shows the selected endpoint's angles, detail level, lane markings and sizing for
  numeric editing. With nothing selected it shows an Add section (Straight/Curve/T/X buttons
  that add in front of the camera) and appearance Presets.

## Build Commands

```bash
# Build the plugin (default build task)
rojo build -p "RoadHelper V1.0.rbxmx"

# Run tests (*.spec.lua files in the src folder); requires the runtests.rbxl place open
# (gitignored; its Workspace must be renamed "runtests") and `pip install websockets`
python runtests.py [filter]

# Install dependencies (must fix the Luau types after installing)
wally install
rojo sourcemap default.project.json --output sourcemap.json
wally-package-types --sourcemap sourcemap.json Packages
```

## Architecture

**Entry point:** `loader.server.lua` creates the toolbar button and dock widget, then
lazy-loads `src/main.lua` on first activation.

- `src/main.lua` — Orchestrator: plugin activation lifecycle, React UI root, session management.
- `src/RoadMath.lua` — Pure math: segment descriptors from a ProceduralModel's Size/attributes/
  pivot, endpoint world frames, endpoint-move solving (Size + pivot + Flip), joint detection,
  Adjust-attribute sign mapping, new-segment placement and width-change compensation.
- `src/RoadDefaults.lua` — Plugin-side attribute defaults (lane layout, intersection angle
  range, corner radius). Must match the generators' `defaultAttributes`
  (`RoadDefaults.spec.lua` checks this).
- `src/createRoadSession.lua` — Active tool session: mounts a DraggerFramework
  DraggerToolComponent with a custom handle list, tracks the selected endpoint, implements all
  edit operations (move/rotate/add/intersection transforms/panel edits) with
  ChangeHistoryService recordings, and keeps the selection in step with undo/redo.
- `src/Handles/` — Handle implementations following the DraggerFramework handles protocol
  (`update`/`hitTest`/`render`/`mouseDown`/`mouseDrag`/`mouseUp`):
  - `EndpointPickHandles.lua` — raycast hover/click picking of the endpoint under the cursor.
  - `EndpointMoveHandles.lua` — arrow + free-drag handles (road ends, and intersection centres).
  - `EndpointRotateHandles.lua` — arc handles editing Adjust angles (also the intersection yaw
    and angle rings).
  - `AddHandles.lua` — left/straight/right/intersection append handles on open endpoints.
  - `DeleteExitHandles.lua` — 4-way ↔ T junction exit toggles.
- `src/Dragger/` — handle view components (arrows/partial arcs) carried over from Redupe.
- `src/RoadHelperGui.lua` + `src/PluginGui/` — React settings panel and reusable components.
- `src/Presets.lua` — appearance presets applied by the panel's Add buttons.
- `src/Settings.lua` — persisted plugin settings (saved on plugin unload).
- `src/Templates/` — packaged copies of the generators, used as a fallback when the place has
  no segment of the needed kind. Note that adds normally clone an existing segment *including
  its generator*, so changes here only reach places without existing roads of that kind.

## Key Facts About Road Segments

- `ProceduralModel` is a Model subclass with a `Size` Vector3 property; the generated geometry
  regenerates automatically when Size or attributes change. Move it with `PivotTo()`; the pivot
  is the center of the nominal bounding box that the generator works in. The engine binds a
  model to its generator through `model.Generator`, not by the module's name.
- Road width is derived: `width = LaneCount*LaneWidth + 2*SidewalkWidth` (per road on an
  intersection: `LaneCountX/Z`, `LaneWidthX/Z`).
- StraightRoad endpoints (local): blue `(∓sway, -Y/2, -Z/2)` outward -Z, red `(±sway, +Y/2, +Z/2)`
  outward +Z, where `sway = max((X - width)/2, 0)` and the sign pair mirrors with `Flip`.
- CurveRoad endpoints (local): blue `(-X/2 + width/2, ·, -Z/2)` outward -Z, red
  `(X/2, ·, Z/2 - width/2)` outward +X; `Flip` mirrors the climb only (blue at top when Flip).
- Intersection exits sit at the box bottom: `ZPlus`/`ZMinus` centred on the ±Z faces; the X
  road runs at `IntersectionAngle` (clamped 25–155) from the Z road, its exits at ±X/2 along
  its own direction. `ThroughRoad = false` drops `XMinus` (T junction). Intersections are flat
  and have no Adjust angles.
- The Adjust dir/grade/bank rotations all pivot about the endpoint centre point, so endpoint
  *positions* are invariant under angle edits — only move edits Size/pivot.
- Joints are purely spatial: two ends within `RoadMath.JOINT_TOLERANCE` facing opposite ways.
  Neighbours are found with spatial queries against generated parts, and anything that moves
  an end must explicitly re-seat what's joined to it.
- `DriveSide` attribute (`"Left"` default, or `"Right"`): which side traffic keeps to. The
  intersection generator uses it for stop bar placement; the road generators carry it so it
  propagates along the network. Any new side-dependent marking should read it.

## Key Conventions

Same as Redupe: `--!strict`, React via `React.createElement` (aliased `e`), Signal library for
events, modules returning a single function, undo via ChangeHistoryService recordings.

- Viewport handles render with legacy **Roact 1.4.4** (`Packages.Roact`, required by
  DraggerFramework); the panel uses **React 17** (`Packages.React`). Don't mix their elements.
- Never nudge the dragger (`updateDragger`) during a gesture, and keep handle `Select`/
  `Deselect` callbacks idempotent: the framework re-runs `mouseDown` on selection changes.
- Source files use CRLF line endings; keep them when editing.
