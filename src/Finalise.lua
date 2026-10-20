--!strict
--[[
	Finalise: turn finished roads into plain, cheap geometry.

	A road segment is a ProceduralModel that regenerates its parts whenever its
	size or attributes change, and carries its generator script. Once the roads
	are built none of that is needed. Finalising a road:

	  1. Keeps a copy of the original in ServerStorage.RoadHelperBackups (the
	     copy is not replicated to players), so it can be unfinalised.
	  2. Removes parts nothing needs: snapping helper cubes, invisible parts
	     that don't collide, and parts wholly hidden inside others
	     (PartCulling).
	  3. Sets the parts up for runtime: markings don't collide, can't be hit by
	     raycasts, cast no shadow; nothing sends touch events or fluid forces.
	  4. Optionally merges parts of the same look into unions (a handful of
	     parts, rather than hundreds, for the engine to draw).
	  5. Replaces the ProceduralModel with a plain Model holding the parts: no
	     generator script, so nothing can regenerate it.

	Hand-drawn markings (Markings) are folded into the same pool of parts, so
	they're optimised and merged with the rest.
]]

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")

local PartCulling = require("./PartCulling")
local RoadMath = require("./RoadMath")

local Finalise = {}

-- Tag on finalised models, and the attribute holding their backup's name
Finalise.TAG = "RoadHelperFinalised"
Finalise.ID_ATTRIBUTE = "RoadHelperBackupId"
local BACKUP_FOLDER = "RoadHelperBackups"

export type Options = {
	-- Remove snapping helper cubes and invisible parts that don't collide
	RemoveHelpers: boolean,
	-- Remove parts hidden inside others, and duplicates
	RemoveHidden: boolean,
	-- Set collision, query, touch and shadow properties for runtime
	TuneParts: boolean,
	-- Merge parts that look alike into unions (slow)
	Merge: boolean,
}

export type Report = {
	Roads: number,
	-- Roads that couldn't be finalised (left as they were)
	Failed: number,
	-- Parts before and after
	Before: number,
	After: number,
	Helpers: number,
	Hidden: number,
	-- Parts merged away, and the unions they became
	Merged: number,
	Unions: number,
	-- Why merging was skipped or fell short, if it did
	MergeNote: string?,
}

Finalise.DEFAULT_OPTIONS = {
	RemoveHelpers = true,
	RemoveHidden = true,
	TuneParts = true,
	Merge = false,
} :: Options

local MARKING_NAMES: { [string]: boolean } = {
	RoadMarking = true,
	MarkingStrip = true,
}

-- Merging: parts sorted by where they are, in chunks of this many, so each
-- union stays local and small enough for the engine to build
local MERGE_CHUNK = 40
local MERGE_CELL = 64

local function backupFolder(create: boolean): Folder?
	local folder = ServerStorage:FindFirstChild(BACKUP_FOLDER)
	if not folder and create then
		folder = Instance.new("Folder")
		folder.Name = BACKUP_FOLDER
		folder.Parent = ServerStorage
	end
	return folder :: Folder?
end

local function collectParts(model: Instance): { BasePart }
	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

local function isMarking(part: BasePart): boolean
	return MARKING_NAMES[part.Name] == true
end

-- Runtime settings for a part kept as it is
local function tunePart(part: BasePart)
	part.Anchored = true
	part.CanTouch = false
	if isMarking(part) then
		-- Paint: nothing to collide with, hit with a raycast or shade
		part.CanCollide = false
		part.CanQuery = false
		part.CastShadow = false
	end
	pcall(function()
		part.EnableFluidForces = false
	end)
end

--------------------------------------------------------------------------------
-- Merging
--------------------------------------------------------------------------------

-- Block, wedge and corner wedge parts without attached textures or
-- decals can be unioned without losing anything
local function mergeable(part: BasePart): boolean
	if #part:GetChildren() > 0 then
		return false
	end
	if part.ClassName == "Part" then
		return (part :: any).Shape == Enum.PartType.Block
	end
	return part.ClassName == "WedgePart" or part.ClassName == "CornerWedgePart"
end

-- Parts with the same look and physics can share a union
local function mergeKey(part: BasePart): string
	return string.format(
		"%s|%d|%s|%.3f|%.3f|%s|%s|%s|%s",
		part.Color:ToHex(),
		part.Material.Value,
		part.MaterialVariant,
		part.Reflectance,
		part.Transparency,
		tostring(part.CanCollide),
		tostring(part.CanQuery),
		tostring(part.CastShadow),
		tostring(isMarking(part))
	)
end

-- Union a chunk of parts into one. Returns the union(s), or nil if the
-- engine couldn't (the chunk's parts are then left alone).
local function unionChunk(service: any, chunk: { BasePart }): { BasePart }?
	local first = chunk[1]
	local others = table.move(chunk, 2, #chunk, 1, {})
	local solid = first.CanCollide
	local ok, result = pcall(function()
		return service:UnionAsync(first, others, {
			CollisionFidelity = if solid then Enum.CollisionFidelity.PreciseConvexDecomposition else Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
			SplitApart = false,
		})
	end)
	if not ok or typeof(result) ~= "table" or #result == 0 then
		return nil
	end
	for _, union in result do
		union.Name = if isMarking(first) then "RoadMarkings" else "RoadSurface"
		union.Anchored = true
		union.Color = first.Color
		union.Material = first.Material
		union.MaterialVariant = first.MaterialVariant
		union.Reflectance = first.Reflectance
		union.Transparency = first.Transparency
		union.CanCollide = first.CanCollide
		union.CanQuery = first.CanQuery
		union.CanTouch = first.CanTouch
		union.CastShadow = first.CastShadow
		pcall(function()
			(union :: any).UsePartColor = true
			union.EnableFluidForces = false
		end)
	end
	return result
end

-- Merge parts that look alike. Returns the parts that were merged away and
-- the unions they became; parts that couldn't be merged are simply left out
-- of both.
local function mergeParts(service: any, parts: { BasePart }, report: Report): ({ BasePart }, { BasePart })
	local groups: { [string]: { BasePart } } = {}
	for _, part in parts do
		if mergeable(part) then
			local key = mergeKey(part)
			local group = groups[key]
			if not group then
				group = {}
				groups[key] = group
			end
			table.insert(group, part)
		end
	end
	local merged: { BasePart } = {}
	local unions: { BasePart } = {}
	local failures = 0
	for _, group in groups do
		-- Neighbours together, so each union covers a small area
		table.sort(group, function(a, b)
			local pa, pb = a.Position, b.Position
			local ax, bx = math.floor(pa.X / MERGE_CELL), math.floor(pb.X / MERGE_CELL)
			if ax ~= bx then
				return ax < bx
			end
			local az, bz = math.floor(pa.Z / MERGE_CELL), math.floor(pb.Z / MERGE_CELL)
			if az ~= bz then
				return az < bz
			end
			return pa.Y < pb.Y
		end)
		for start = 1, #group, MERGE_CHUNK do
			local chunk = table.move(group, start, math.min(start + MERGE_CHUNK - 1, #group), 1, {})
			if #chunk > 1 then
				local result = unionChunk(service, chunk)
				if result then
					for _, part in chunk do
						table.insert(merged, part)
					end
					for _, union in result do
						table.insert(unions, union)
					end
				else
					failures += 1
				end
				task.wait()
			end
		end
	end
	if failures > 0 then
		report.MergeNote = `{failures} group(s) of parts couldn't be merged and were left as they are.`
	end
	return merged, unions
end

--------------------------------------------------------------------------------
-- Finalising
--------------------------------------------------------------------------------

-- Finalise one road. Returns whether it was done; on failure the road is left
-- as it was (apart from harmless property tweaks).
local function finaliseRoad(model: Model, options: Options, service: any, report: Report): boolean
	local parts = collectParts(model)
	local before = #parts

	-- The original is kept first, before anything is touched
	local id = HttpService:GenerateGUID(false)
	local backup = model:Clone()
	backup.Name = id
	backup:SetAttribute(Finalise.ID_ATTRIBUTE, id)

	-- 1. Parts nothing needs
	local helpers = 0
	local kept: { BasePart } = {}
	for _, part in parts do
		if options.RemoveHelpers and (part.Name == "SnappingHelper" or (part.Transparency >= 0.99 and not part.CanCollide)) then
			helpers += 1
		else
			table.insert(kept, part)
		end
	end

	-- 2. Parts hidden inside others
	local hidden = 0
	if options.RemoveHidden then
		local gone: { [BasePart]: boolean } = {}
		for _, part in PartCulling.findHidden(kept) do
			gone[part] = true
			hidden += 1
		end
		if hidden > 0 then
			local remaining: { BasePart } = {}
			for _, part in kept do
				if not gone[part] then
					table.insert(remaining, part)
				end
			end
			kept = remaining
		end
	end

	-- 3. Runtime settings
	if options.TuneParts then
		for _, part in kept do
			tunePart(part)
		end
	end

	-- 4. Merging
	local unions: { BasePart } = {}
	local merged = 0
	if options.Merge and service then
		local mergedAway, made = mergeParts(service, kept, report)
		if #mergedAway > 0 then
			local away: { [BasePart]: boolean } = {}
			for _, part in mergedAway do
				away[part] = true
			end
			local remaining: { BasePart } = {}
			for _, part in kept do
				if not away[part] then
					table.insert(remaining, part)
				end
			end
			kept = remaining
			unions = made
			merged = #mergedAway
		end
	end

	-- 5. The plain model replaces the road
	local result = Instance.new("Model")
	result.Name = model.Name
	for name, value in model:GetAttributes() do
		result:SetAttribute(name, value)
	end
	for _, tag in CollectionService:GetTags(model) do
		result:AddTag(tag)
	end
	result:SetAttribute(Finalise.ID_ATTRIBUTE, id)
	result:AddTag(Finalise.TAG)
	result.WorldPivot = model:GetPivot()
	-- (Copies: the generated container is the engine's to manage, and goes
	-- with the model)
	for _, part in kept do
		part:Clone().Parent = result
	end
	for _, union in unions do
		union.Parent = result
	end
	local parent = model.Parent
	backup.Parent = backupFolder(true)
	result.Parent = parent
	model:Destroy()

	report.Before += before
	report.After += #kept + #unions
	report.Helpers += helpers
	report.Hidden += hidden
	report.Merged += merged
	report.Unions += #unions
	return true
end

-- Finalise the given road segments (ProceduralModels). Yields.
function Finalise.finalise(models: { Model }, options: Options, progress: (text: string) -> ()): Report
	local report: Report = {
		Roads = 0,
		Failed = 0,
		Before = 0,
		After = 0,
		Helpers = 0,
		Hidden = 0,
		Merged = 0,
		Unions = 0,
		MergeNote = nil,
	}
	local service: any = nil
	if options.Merge then
		local ok, found = pcall(function()
			return game:GetService("GeometryService")
		end)
		if ok then
			service = found
		else
			report.MergeNote = "Merging needs GeometryService, which this version of Studio doesn't have."
		end
	end
	for index, model in models do
		progress(`Finalising road {index} of {#models}...`)
		local ok, err = pcall(finaliseRoad, model, options, service, report)
		if ok then
			report.Roads += 1
		else
			report.Failed += 1
			warn(`RoadHelper: Couldn't finalise {model:GetFullName()}: {err}`)
		end
		task.wait()
	end
	return report
end

-- The finalised models in workspace
function Finalise.findFinalised(): { Model }
	local found = {}
	for _, instance in CollectionService:GetTagged(Finalise.TAG) do
		if instance:IsA("Model") and instance:IsDescendantOf(workspace) then
			table.insert(found, instance)
		end
	end
	return found
end

-- Put the original roads back in place of finalised models. Returns how many
-- were restored and how many had no backup left.
function Finalise.unfinalise(models: { Model }): (number, number)
	local folder = backupFolder(false)
	local restored, missing = 0, 0
	for _, model in models do
		local id = model:GetAttribute(Finalise.ID_ATTRIBUTE)
		local backup = if folder and typeof(id) == "string" then folder:FindFirstChild(id) else nil
		if backup and backup:IsA("Model") then
			-- (Moved since it was finalised? The road goes where the model is.)
			local road = backup:Clone()
			road.Name = model.Name
			road:SetAttribute(Finalise.ID_ATTRIBUTE, nil)
			road.Parent = model.Parent
			road:PivotTo(model:GetPivot())
			model:Destroy()
			backup:Destroy()
			restored += 1
		else
			missing += 1
		end
		task.wait()
	end
	return restored, missing
end

-- Delete every backup, for good: finalised roads can no longer be restored
function Finalise.deleteBackups(): number
	local folder = backupFolder(false)
	if not folder then
		return 0
	end
	local count = #folder:GetChildren()
	folder:Destroy()
	return count
end

--------------------------------------------------------------------------------
-- Which roads to act on
--------------------------------------------------------------------------------

-- The road segments in (or containing) the given instances, without repeats
function Finalise.roadsIn(instances: { Instance }): { Model }
	local seen: { [Model]: boolean } = {}
	local roads: { Model } = {}
	local function add(model: Model)
		if not seen[model] then
			seen[model] = true
			table.insert(roads, model)
		end
	end
	for _, instance in instances do
		local segment = RoadMath.segmentFromDescendant(instance)
		if segment then
			add(segment.Model)
		else
			for _, found in RoadMath.findSegments(instance) do
				add(found.Model)
			end
		end
	end
	return roads
end

-- The finalised models in (or containing) the given instances
function Finalise.finalisedIn(instances: { Instance }): { Model }
	local seen: { [Model]: boolean } = {}
	local models: { Model } = {}
	local function add(model: Instance)
		if model:IsA("Model") and not seen[model] then
			seen[model] = true
			table.insert(models, model)
		end
	end
	for _, instance in instances do
		local current: Instance? = instance
		local inside = false
		while current and current ~= workspace do
			if CollectionService:HasTag(current, Finalise.TAG) then
				add(current)
				inside = true
				break
			end
			current = current.Parent
		end
		if not inside then
			for _, descendant in instance:GetDescendants() do
				if CollectionService:HasTag(descendant, Finalise.TAG) then
					add(descendant)
				end
			end
		end
	end
	return models
end

return Finalise
