--!strict
--[[
	PartCulling: finding parts that can never be seen, so they can be deleted.

	A part is hidden when it lies wholly inside an opaque block part that is
	at least as solid as it is (strictly inside, by a small margin: a part
	flush with a surface is not counted, since it may show on that face).
	Parts that coincide exactly are duplicates, and all but the first go too
	(they'd only z-fight).

	Pure geometry on the parts' CFrame, Size, Transparency and CanCollide,
	with a grid over the plan view to avoid comparing every pair.
]]

local PartCulling = {}

-- A part must be inside another by at least this much on every side
local MARGIN = 0.01
local CELL = 32

local function cellKey(cx: number, cz: number): number
	return (cx + 8192) * 16384 + (cz + 8192)
end

-- The axis-aligned box around a part: minX, minZ, maxX, maxZ (and centre)
local function planBounds(part: BasePart): (number, number, number, number)
	local x, _, z, r00, r01, r02, _, _, _, r20, r21, r22 = part.CFrame:GetComponents()
	local size = part.Size
	local halfX = (math.abs(r00) * size.X + math.abs(r01) * size.Y + math.abs(r02) * size.Z) / 2
	local halfZ = (math.abs(r20) * size.X + math.abs(r21) * size.Y + math.abs(r22) * size.Z) / 2
	return x - halfX, z - halfZ, x + halfX, z + halfZ
end

-- Whether `inner`'s whole bounding box lies inside `outer` (a block), by at
-- least the margin
function PartCulling.contains(outer: BasePart, inner: BasePart): boolean
	local outerCFrame = outer.CFrame
	local half = outer.Size / 2
	local limitX, limitY, limitZ = half.X - MARGIN, half.Y - MARGIN, half.Z - MARGIN
	if limitX <= 0 or limitY <= 0 or limitZ <= 0 then
		return false
	end
	local innerCFrame = inner.CFrame
	local reach = inner.Size / 2
	for sx = -1, 1, 2 do
		for sy = -1, 1, 2 do
			for sz = -1, 1, 2 do
				local corner = innerCFrame * Vector3.new(sx * reach.X, sy * reach.Y, sz * reach.Z)
				local local3 = outerCFrame:PointToObjectSpace(corner)
				if math.abs(local3.X) > limitX or math.abs(local3.Y) > limitY or math.abs(local3.Z) > limitZ then
					return false
				end
			end
		end
	end
	return true
end

local function isBlock(part: BasePart): boolean
	return part.ClassName == "Part" and (part :: any).Shape == Enum.PartType.Block
end

-- An identical part's key: same class, size, position and orientation
local function duplicateKey(part: BasePart): string
	local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = part.CFrame:GetComponents()
	local size = part.Size
	return string.format(
		"%s|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f|%s",
		part.ClassName,
		size.X, size.Y, size.Z,
		x, y, z,
		r00, r01, r02, r10, r11, r12, r20, r21, r22,
		tostring(part.CanCollide)
	)
end

-- The parts that can't be seen: wholly inside a solid opaque block, or an
-- exact duplicate of an earlier part
function PartCulling.findHidden(parts: { BasePart }): { BasePart }
	local hidden: { BasePart } = {}
	local gone: { [BasePart]: boolean } = {}

	-- Duplicates
	local seen: { [string]: boolean } = {}
	for _, part in parts do
		local key = duplicateKey(part)
		if seen[key] then
			gone[part] = true
			table.insert(hidden, part)
		else
			seen[key] = true
		end
	end

	-- Opaque blocks, indexed by every grid cell their plan view touches
	local grid: { [number]: { BasePart } } = {}
	for _, part in parts do
		if not gone[part] and isBlock(part) and part.Transparency == 0 then
			local minX, minZ, maxX, maxZ = planBounds(part)
			for cx = math.floor(minX / CELL), math.floor(maxX / CELL) do
				for cz = math.floor(minZ / CELL), math.floor(maxZ / CELL) do
					local key = cellKey(cx, cz)
					local cell = grid[key]
					if not cell then
						cell = {}
						grid[key] = cell
					end
					table.insert(cell, part)
				end
			end
		end
	end

	-- A part inside a block has its centre inside that block's plan view, so
	-- the block is in the centre's cell
	for _, part in parts do
		if not gone[part] then
			local position = part.Position
			local cell = grid[cellKey(math.floor(position.X / CELL), math.floor(position.Z / CELL))]
			if cell then
				for _, outer in cell do
					-- (An inner part that collides can only go if the block does
					-- too: its collision goes with it)
					if outer ~= part and not gone[outer] and (outer.CanCollide or not part.CanCollide)
						and PartCulling.contains(outer, part)
					then
						gone[part] = true
						table.insert(hidden, part)
						break
					end
				end
			end
		end
	end
	return hidden
end

return PartCulling
