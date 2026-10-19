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
  - `MarkingHandles.lua` — drawing and editing hand-drawn markings (Draw Markings mode).
- `src/Dragger/` — handle view components (arrows/partial arcs) carried over from Redupe.
- `src/RoadHelperGui.lua` + `src/PluginGui/` — React settings panel and reusable components.
- `src/Presets.lua` — appearance presets applied by the panel's Add buttons.
- `src/Markings.lua` — hand-drawn markings: line data, curve sampling, building strips,
  snapping.
- `src/Settings.lua` — persisted plugin settings (saved on plugin unload).
- `src/Templates/` — packaged copies of the generators, used as a fallback when the place has
  no segment of the needed kind. Note that adds normally clone an existing segment *including
  its generator*, so changes here only reach places without existing roads of that kind.

## Key Facts About Road Segments

- `ProceduralModel` is a Model subclass with a `Size` Vector3 property; the generated geometry
  regenerates automatically when Size or attributes change. Move it with `PivotTo()`; the pivot
  is the center of the nominal bounding box that the generator works in. The engine binds a
  model to its generator through `model.Generator`, not by the module's name.
- Lanes are counted per travel direction: `LaneCountForward` (blue → red) and
  `LaneCountBackward` (red → blue); either may be 0 (one-way), at least one lane in all. On an
  intersection each road has its own pair suffixed `X`/`Z`, forward running toward its Plus
  exit. The panel shows them relative to the selected end as lanes **out**/**in**
  (`RoadMath.getLaneCounts`/`laneAttributeNames`), and new segments match them across the
  joint (`matchLanesAcrossJoint`) since joined segments can run opposite ways.
- Road width is derived: `width = (LaneCountForward + LaneCountBackward)*LaneWidth +
  2*SidewalkWidth` (per road on an intersection, with `LaneWidthX/Z`). Width depends only on
  the total, so lane edits that keep the total don't move anything.
- Lane boundaries sit every `LaneWidth` across the roadway; the boundary between the two
  directions gets the double centre line. Generator `lat` (lateral offset) is positive to the
  LEFT of forward travel, so driving on the left puts the forward lanes on the +lat side.
- Lane changes (straights only): `LaneCountForwardRed`/`LaneCountBackwardRed` override the
  red end's counts when both are >= 0 (the generator defaults them to -1, "same as blue").
  The whole segment is the taper; `LaneChangeSide` ("Offside"/"Nearside") picks which lane
  ends or starts. A straight's box is laid out around its wider end (`RoadMath.boxWidth`).
  Editing one end's lanes shifts that end sideways by half the width change
  (`RoadMath.laneChangeShift`) so the other direction's kerb stays put; the generator blends
  lane positions by the path's sideways progress, so that kerb comes out straight. Single-end
  edits are only allowed at open ends. SwapEnds moves swap lane counts too
  (`RoadMath.swappedLaneValues`), since travel through the segment reverses.
- StraightRoad endpoints (local): blue `(∓sway, -Y/2, -Z/2)` outward -Z, red `(±sway, +Y/2, +Z/2)`
  outward +Z, where `sway = max((X - width)/2, 0)` and the sign pair mirrors with `Flip`.
- CurveRoad endpoints (local): blue `(-X/2 + width/2, ·, -Z/2)` outward -Z, red
  `(X/2, ·, Z/2 - width/2)` outward +X; `Flip` mirrors the climb only (blue at top when Flip).
- Intersection exits sit at the box bottom: `ZPlus`/`ZMinus` centred on the ±Z faces; the X
  road runs at `IntersectionAngle` (clamped 25–155) from the Z road, its exits at ±X/2 along
  its own direction. `ThroughRoad = false` drops `XMinus` (T junction). Intersections are flat
  and have no Adjust angles.
- Y splits (`RoadSplitGenerator`, kind `"Split"`, ends `Stem`/`BranchLeft`/`BranchRight`): one
  road dividing into two. The stem (-Z face) joins the road; the branches leave the +Z face
  side by side ("left" looking from the stem). The stem's lanes divide across the road:
  `SplitLanesLeft` lanes from the left edge go left, the rest right, each keeping its direction
  (default: a two-way road separates into its directions, a one-way road splits about in half).
  `SplitSeparation` is the gap between the branch roads (outside footways) at the far end; the
  split line is at local x = 0, and the layout depends only on attributes and Size.Z
  (`RoadMath.splitLayout`, mirrored in the generator). The gore gets chevrons with solid
  borders when both sides carry the same direction, diagonal hatching with broken borders
  when they're opposite (Highway Code rule 130), then a raised island from the nose. Splits
  are junctions (`RoadMath.isJunction`): flat, no adjust angles, moved as a whole.
- Mini roundabouts are a variant of the intersection (`MiniRoundabout = true`), not a separate
  kind, so they get everything junctions do (T/4-way, angle, lanes, crosswalks, moving).
  UK layout: a white central island (`MiniRoundaboutDiameter`, 1-4 m = 7-26 studs, capped at
  half the narrower roadway), every entry giving way at a single broken line at the junction
  mouth (crosswalks set back beyond it), and circulation arrows between the arms (clockwise
  when driving on the left). `MiniRoundaboutRaised` swaps the flush disc for a non-colliding
  dome (125 mm) in `MiniRoundaboutCentreColor`, ringed in white.
- Roundabouts (`RoundaboutGenerator`, kind `"Roundabout"`, a junction) are their own kind, built
  in phases (1: ring and island; 2: arms; 3: lanes inside the ring, spiral markings; 4: extras
  such as signals). The island outline is the convex hull of circles (`IslandShape`,
  `"x,z,r;..."` in pivot space; `RoadMath.roundaboutHull`, mirrored in the generator), so every
  edge is the outline offset by some distance and can't self-intersect; concave islands would
  need another method. Ring: `RingLanes` x `LaneWidth`, footway outside, optional raised
  `ApronWidth` inside. Size is derived (`RoadMath.roundaboutSize`). Selecting a roundabout
  selects its `"Centre"` pseudo-endpoint (pickable, faces up so it never joins anything; see
  `RoadMath.pickableEndpointIds`). `IslandShapeHandles` drag the outline circles.
- Roundabout arms (`Arms`, `"angle,exit,entry;..."`; ends `Arm1`..`Arm12`, forward = exit):
  each sits where the ray from the island centroid at its angle meets the outline, running out
  along the outline normal from the ring's outer edge for `ArmLength`. Exit lanes keep to the
  DriveSide (left looking out, in the UK); near the ring the directions part around a splitter
  island (`SplitterWidth`, kerbed to its nose, hatched ahead), and kerb fillets
  (`EntryKerbRadius`) join the arm's kerbs to the ring's, found exactly on the outline offset
  by ringWidth + radius; the ring's footway and outer edge line are cut across each mouth.
  Missing `Arms` means the 4-arm default in both RoadMath and the generator ("" is none).
  Optional per-arm fields `,length,skew`: an own length (0 = `ArmLength`) and a skew off the
  outline normal (degrees, clamped to +-45, positive clockwise from above); a skewed arm starts
  at its mouth, where its axis crosses the ring's outer edge (`MouthX/Z`). Further optional
  fields `,flare,arrows`: extra entry lanes at the give way line (kerb side, up to 3; full
  width for the first half of `FlareLength`, then tapering, never reaching the arm's end), and
  the entry lanes' arrows left to right as the driver sees them (`"LA/R"`, `-` for none, empty
  for automatic per Highway Code rule 186; `RoadMath.laneArrows`, mirrored in the generator).
  Kerb fillets are fitted to the arm's width where they touch its side (it narrows as the
  splitter and flare taper), the arm's road running straight out to the fillet's line until
  then.
  `SplitterStyle` "Kerbed" (default) or "Hatched" (painted only). The Roundabout add cone
  builds a 4-arm roundabout whose `Arm3` joins the road end (arms carry the road's lanes).
  Removing an arm renumbers later ones, so joined roads are remapped, not re-seated by old id.
- Roundabout ring markings (`RingMarkings`): "Concentric" (default), "Spiral" or "None" (to
  draw your own: see Drawn markings). Spiral stretches run from the end of one exit arm's mouth (its entry-side kerb) to the end of the
  next's; over a stretch line k sweeps out by that exit's lanes (capped at ring lanes - 1),
  so the line between continuing and leaving lanes ends at the exit's nose (lat
  `exitSide*Splitter/2` at the ring edge) and lines between leaving lanes meet the exit's own
  lane lines there. The exit side of an arm is its upstream side round the ring. Markings
  only: nothing in RoadMath depends on it.
- Drawn markings (`Markings`): each line is a Model tagged `RoadHelperMarking`, parented to the
  road it was started on (else a workspace `RoadMarkings` folder), with attributes `Points`
  (`"x,y,z;..."` relative to the road's pivot, so it moves with the road; world space off a
  road), `Style` (Dashed/Solid/GiveWay/Double), `Colour` (White/Yellow = the road's
  LaneMarkingColor/CenterlineColor), `Curved` (centripetal Catmull-Rom), `Width`, `Dash`,
  `Gap`. Its `MarkingStrip` parts are rebuilt from those (`Markings.build`) and are
  CanQuery/CanCollide false, so raycasts, joint queries and snapping never see them. They're
  deliberately not generator geometry: reshaping a road leaves them to be adjusted by hand.
  Roads cloned as templates are stripped of them (`cloneTemplate`). In Draw Markings mode
  every other handle is wrapped by `hiddenWhileMarking`; `MarkingHandles` act on mouse-up
  and hold `gestureActive` for the whole press, because a dragger nudge mid-click re-runs
  mouseUp/mouseDown. Points snap to the ends of generated `RoadMarking` strips and drawn
  lines' points, else onto generated strips (Alt places freely).
- The Adjust dir/grade/bank rotations all pivot about the endpoint centre point, so endpoint
  *positions* are invariant under angle edits — only move edits Size/pivot.
- Joints are purely spatial: two ends within `RoadMath.JOINT_TOLERANCE` facing opposite ways.
  Neighbours are found with spatial queries against generated parts, and anything that moves
  an end must explicitly re-seat what's joined to it.
- `DriveSide` attribute (`"Left"` default, or `"Right"`): which side traffic keeps to. All
  generators use it to place the forward/backward lanes, and the intersection for stop bars.
  Any new side-dependent marking should read it.

## Key Conventions

Same as Redupe: `--!strict`, React via `React.createElement` (aliased `e`), Signal library for
events, modules returning a single function, undo via ChangeHistoryService recordings.

- Viewport handles render with legacy **Roact 1.4.4** (`Packages.Roact`, required by
  DraggerFramework); the panel uses **React 17** (`Packages.React`). Don't mix their elements.
- Never nudge the dragger (`updateDragger`) during a gesture, and keep handle `Select`/
  `Deselect` callbacks idempotent: the framework re-runs `mouseDown` on selection changes.
- Source files use CRLF line endings; keep them when editing.
