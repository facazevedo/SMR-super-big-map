-- Super Big Map -- object classification & cloning for the L-frame expansion.
--
-- Pure object-side helpers used by the sector-block copy: which objects may be
-- cloned (ShouldSkipObject and the underground-access / mystery / deposit-marker
-- classifiers), how a clone's transform and mirror orientation are copied, and the
-- per-object spawn. NO terrain/grid logic and NO dependency on the other generation
-- modules -- self-contained so it can load first and sbm_terrain_copy can bind these
-- helpers at load time. Generic primitives come from sbm_engine.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine.Global
local SafeCall = Engine.SafeCall
local TryCall = Engine.TryCall
local IsKindOfSafe = Engine.IsKindOf
local ObjectPosition = Engine.ObjectPos

local function cfg_bool(key, default)
	local value = (SuperBigMap.Config or {})[key]
	if type(value) == "boolean" then
		return value
	end
	return default
end

local function DebugPrint(text)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("Generation", text)
	end
end

local function VerbosePrint(text)
	local DebugLog = SuperBigMap.DebugLog
	if DebugLog then
		DebugLog.Info("GenerationVerbose", text)
	end
end

local function PointXY(pos)
	if not pos then
		return false
	end
	if type(pos.xy) == "function" then
		local x, y = SafeCall(pos.xy, pos)
		return x, y
	end
	if type(pos.x) == "number" and type(pos.y) == "number" then
		return pos.x, pos.y
	end
	return false
end

local skip_clone_classes = {
	City = true,
	MapSector = true,
	RandomMapGeneratorHolder = true,
	RevealedMapSector = true,
	-- The overview sector-grid visuals are decal objects placed per-sector by
	-- MapSector:UpdateDecal() (PlaceObjectIn "SectorUnexplored"/"SectorScanned").
	-- They sit INSIDE the L-frame destination boxes, so without these entries
	-- CopySectorBlock's dest-clear phase destroys them and the frame's overview grid
	-- disappears (the sectors stay scannable -- only the decals were deleted). They
	-- are a UI overlay, never terrain scatter, so they must never be cloned/deleted.
	SectorUnexplored = true,
	SectorScanned = true,
}

-- Surface/underground access visuals are generated from marker/passage objects and
-- are not terrain scatter. Keep this separate from the generic skip list so attached
-- visual children can be recognized through their parent or entity name.
local underground_access_clone_kinds = {
	"SurfaceUndergroundTunnelMarker", -- surface & underground tunnel entrance markers
	                                  -- (SurfaceTunnelMarker / UndergroundTunnelMarker inherit
	                                  -- from this, so they are covered too)
	"SurfacePassageBase",             -- surface-side passage / entrance structure
	"UndergroundPassageBase",         -- underground-side passage marker spawned by the game
	"SurfaceUndergroundTunnelSign",   -- the entrance's surface sign
	"SurfacePassageRocks",            -- entrance decoration, entity ElevatorBuildIndicator_UndergroundRocks
	"UndergroundWonder",              -- JumboCave / CaveOfWonders (cave entrances)
}

local skip_clone_kinds = {
	"Building",
	"Colonist",
	"ConstructionSite",
	"DroneBase",
	"BaseRover",
	"RocketBase",
	"ResourceStockpileBase",
	"Unit",
}
for i = 1, #underground_access_clone_kinds do
	skip_clone_kinds[#skip_clone_kinds + 1] = underground_access_clone_kinds[i]
end
-- (Sinkhole is a Building, already covered by the "Building" entry above.)

local underground_access_name_patterns = {
	"SurfaceUndergroundTunnel",
	"SurfacePassage",
	"UndergroundPassage",
	"ElevatorBuildIndicator_Underground",
	"SignUnderground",
}

-- Anything related to a MYSTERY (Black Cubes -- incl. the "mysterious pile of
-- stone" -- Marsgate, and any mystery-named class/controller) must never be
-- cloned, deleted, or tiled: leave the player's mystery content completely alone.
local mystery_name_patterns = { "BlackCube", "Marsgate", "Mystery" }
local mystery_kinds = {
	"MysteryBase",
	"BlackCubeStockpileBase",
	"BlackCubeMonolithBase",
	"BlackCubeDumpSite",
}
local function IsMysteryRelatedObject(obj)
	if not obj then
		return false
	end
	local class = obj.class
	if type(class) == "string" then
		for i = 1, #mystery_name_patterns do
			if string.find(class, mystery_name_patterns[i], 1, true) then
				return true
			end
		end
	end
	for i = 1, #mystery_kinds do
		if IsKindOfSafe(obj, mystery_kinds[i]) then
			return true
		end
	end
	return false
end

local function MatchUndergroundAccessName(field, value)
	if type(value) ~= "string" then
		return false
	end
	for i = 1, #underground_access_name_patterns do
		local pattern = underground_access_name_patterns[i]
		if string.find(value, pattern, 1, true) then
			return true, field, pattern
		end
	end
	return false
end

local function ObjectMatchesUndergroundAccessName(obj)
	if not obj then
		return false
	end

	local matched, field, pattern = MatchUndergroundAccessName("class", obj.class)
	if matched then return true, field, pattern end

	matched, field, pattern = MatchUndergroundAccessName("entity", obj.entity)
	if matched then return true, field, pattern end

	matched, field, pattern = MatchUndergroundAccessName("template_name", obj.template_name)
	if matched then return true, field, pattern end

	matched, field, pattern = MatchUndergroundAccessName("template", obj.template)
	if matched then return true, field, pattern end

	matched, field, pattern = MatchUndergroundAccessName("name", obj.name)
	if matched then return true, field, pattern end

	if type(obj.GetEntity) == "function" then
		local entity = SafeCall(obj.GetEntity, obj)
		matched, field, pattern = MatchUndergroundAccessName("GetEntity", entity)
		if matched then return true, field, pattern end
	end

	return false
end

local function IsUndergroundAccessObject(obj)
	if not obj then
		return false
	end

	for i = 1, #underground_access_clone_kinds do
		local kind = underground_access_clone_kinds[i]
		if IsKindOfSafe(obj, kind) then
			return true, "kind", kind
		end
	end

	local matched, field, pattern = ObjectMatchesUndergroundAccessName(obj)
	if matched then
		return true, field, pattern
	end

	if type(obj.GetParent) == "function" then
		local parent = SafeCall(obj.GetParent, obj)
		if parent and parent ~= obj then
			for i = 1, #underground_access_clone_kinds do
				local kind = underground_access_clone_kinds[i]
				if IsKindOfSafe(parent, kind) then
					return true, "parent_kind", kind
				end
			end

			matched, field, pattern = ObjectMatchesUndergroundAccessName(parent)
			if matched then
				return true, "parent_" .. tostring(field), pattern
			end
		end
	end

	return false
end

-- Resource deposit MARKERS we copy: surface, subsurface (incl. deep), concrete/terrain.
-- We copy the invisible MARKERS (which spawn the real deposit on scan), NOT spawned deposit
-- objects -- and NO anomalies/effects (siblings under DepositMarker but not these classes).
local function IsResourceDepositMarker(obj)
	return IsKindOfSafe(obj, "SurfaceDepositMarker")
		or IsKindOfSafe(obj, "SubsurfaceDepositMarker")
		or IsKindOfSafe(obj, "TerrainDepositMarker")
end

local function ShouldSkipObject(obj)
	if not obj or skip_clone_classes[obj.class or false] then
		return true
	end

	if obj.SuperBigMapQuadrantClone then
		return true
	end

	-- Never touch mystery content.
	if IsMysteryRelatedObject(obj) then
		return true
	end

	-- Never clone underground entrance/access markers, symbols, or decoration. Game
	-- references: UndergroundPassage.lua defines SurfaceUndergroundTunnelMarker /
	-- Sign, and SurfacePassageRocks.lua uses ElevatorBuildIndicator_UndergroundRocks.
	local underground, reason, match = IsUndergroundAccessObject(obj)
	if underground then
		VerbosePrint(string.format(
			"skip underground access object: class=%s reason=%s match=%s",
			tostring(obj.class),
			tostring(reason),
			tostring(match)
		))
		return true
	end

	-- Marker-based deposit copy: do NOT clone spawned deposit OBJECTS (we copy the markers
	-- instead, which spawn on scan), and never copy anomalies or effect-deposit markers --
	-- only resource deposit markers are wanted.
	if not IsResourceDepositMarker(obj) then
		if IsKindOfSafe(obj, "Deposit")
			or IsKindOfSafe(obj, "SubsurfaceAnomaly")
			or IsKindOfSafe(obj, "SubsurfaceAnomalyMarker")
			or IsKindOfSafe(obj, "EffectDepositMarker") then
			return true
		end
	end

	for i = 1, #skip_clone_kinds do
		if IsKindOfSafe(obj, skip_clone_kinds[i]) then
			return true
		end
	end

	return false
end

-- Resource deposit markers are ALWAYS cloned (never thinned by the decor skip-Nth cap,
-- never dropped for edge-touching); only cosmetic decor (rocks, decals, terrain prefabs)
-- is subject to skipping.
local function IsImportantSectorObject(obj)
	return IsResourceDepositMarker(obj)
end

-- True if the object's bounding sphere (world center +/- GetRadius) is fully inside
-- the world box [x1,y1..x2,y2]. Used to skip cloning decor that straddles the
-- source-block edge -- its mirrored copy would overhang the seam / map edge.
local function ObjectInsideBox(obj, x1, y1, x2, y2)
	local pos = ObjectPosition(obj)
	if not pos then return false end
	local cx, cy = PointXY(pos)
	if type(cx) ~= "number" or type(cy) ~= "number" then return false end
	local r = 0
	if type(obj.GetRadius) == "function" then
		local ok, rad = pcall(obj.GetRadius, obj)
		if ok and type(rad) == "number" and rad > 0 then r = rad end
	end
	return (cx - r) >= x1 and (cx + r) <= x2 and (cy - r) >= y1 and (cy + r) <= y2
end

local function CopyObjectTransform(source, clone, offset)
	local pos = ObjectPosition(source)
	if pos and type(clone.SetPos) == "function" then
		SafeCall(clone.SetPos, clone, pos + offset)
	end

	if type(source.GetAngle) == "function" and type(clone.SetAngle) == "function" then
		local angle = SafeCall(source.GetAngle, source)
		if angle then
			SafeCall(clone.SetAngle, clone, angle)
		end
	end

	if type(source.GetScale) == "function" and type(clone.SetScale) == "function" then
		local scale = SafeCall(source.GetScale, source)
		if scale then
			SafeCall(clone.SetScale, clone, scale)
		end
	end

	if type(source.GetColorizationPalette) == "function" and type(clone.SetColorizationPalette) == "function" then
		local palette = SafeCall(source.GetColorizationPalette, source)
		if palette then
			SafeCall(clone.SetColorizationPalette, clone, palette)
		end
	end

	if type(source.GetColorsAsTable) == "function" and type(clone.SetColorsFromTable) == "function" then
		local colors = SafeCall(source.GetColorsAsTable, source)
		if colors then
			SafeCall(clone.SetColorsFromTable, clone, colors)
		end
	end

	if type(source.GetGameFlags) == "function" and type(clone.SetGameFlags) == "function" then
		local flags = SafeCall(source.GetGameFlags, source)
		if type(flags) == "number" and flags ~= 0 then
			SafeCall(clone.SetGameFlags, clone, flags)
		end
	end

	if cfg_bool("QUADRANT_COPY_ENUM_FLAGS", false) and type(source.GetEnumFlags) == "function" and type(clone.SetEnumFlags) == "function" then
		local flags = SafeCall(source.GetEnumFlags, source)
		if type(flags) == "number" and flags ~= 0 then
			SafeCall(clone.SetEnumFlags, clone, flags)
		end
	end
end

local function CloneObjectAtOffset(map, source, offset)
	local place_object = Global("PlaceObject")
	local pos = ObjectPosition(source)
	if type(place_object) ~= "function" or not pos then
		return false
	end

	local ok, clone = TryCall(place_object, source.class, nil, map, nil, pos + offset)
	if not ok or not clone then
		return false
	end

	if type(clone.CopyProperties) == "function" then
		SafeCall(clone.CopyProperties, clone, source)
	end

	clone.SuperBigMapQuadrantClone = true
	CopyObjectTransform(source, clone, offset)
	-- Deposit handling on the clone: scan-gate visibility (hide until the frame sector is
	-- scanned) + optional reshuffle onto terrain matching the source. No-op for non-deposits.
	local deposits = SuperBigMap.DepositRules
	if deposits and type(deposits.ProcessClone) == "function" then
		deposits.ProcessClone(map, source, clone)
	end
	return clone
end

-- Apply a clone's mirror orientation so it matches the grid flips: toggle the
-- Mirrored mesh flag on an ODD number of reflections, and reflect the yaw per axis
-- (mirror_x: 180-a, mirror_y: -a, both: 180+a). Angle is in minutes (circle=21600).
-- Shared by the per-sector (CopySectorTerrain) and block (CopySectorBlock) copies.
local function ApplyMirrorOrientation(obj, clone, mirror_x, mirror_y)
	if not (mirror_x or mirror_y) then return end
	if type(obj.GetAngle) == "function" and type(clone.SetAngle) == "function" then
		local ok_a, a = pcall(obj.GetAngle, obj)
		if ok_a and type(a) == "number" then
			a = a % 21600
			local na
			if mirror_x and mirror_y then
				na = (a + 10800) % 21600
			elseif mirror_x then
				na = (10800 - a) % 21600
			else
				na = (21600 - a) % 21600
			end
			pcall(clone.SetAngle, clone, na)
		end
	end
	local odd = (mirror_x and not mirror_y) or (mirror_y and not mirror_x)
	if odd and type(clone.SetMirrored) == "function" then
		local src_mirrored = false
		if type(obj.GetMirrored) == "function" then
			local ok_m, m = pcall(obj.GetMirrored, obj)
			src_mirrored = ok_m and m == true
		end
		pcall(clone.SetMirrored, clone, not src_mirrored)
	end
end

-- Public API: classifiers + clone helpers consumed by sbm_terrain_copy (and the
-- runtime deposit hook). Object-side only; terrain/grid copy lives in sbm_terrain_copy.
local ObjectClone = {
	IsMysteryRelatedObject = IsMysteryRelatedObject,
	MatchUndergroundAccessName = MatchUndergroundAccessName,
	ObjectMatchesUndergroundAccessName = ObjectMatchesUndergroundAccessName,
	IsUndergroundAccessObject = IsUndergroundAccessObject,
	IsResourceDepositMarker = IsResourceDepositMarker,
	ShouldSkipObject = ShouldSkipObject,
	IsImportantSectorObject = IsImportantSectorObject,
	ObjectInsideBox = ObjectInsideBox,
	CopyObjectTransform = CopyObjectTransform,
	CloneObjectAtOffset = CloneObjectAtOffset,
	ApplyMirrorOrientation = ApplyMirrorOrientation,
}
SuperBigMap.ObjectClone = ObjectClone
