-- Super Big Map -- object classification and enrichment cloning.
--
-- Pure object-side helpers used by the stretch decoration pass and enrichment
-- top-ups. No terrain/grid logic and no terrain-expansion mode dispatch lives here.

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

-- Cached generation traversals can retain Lua wrappers after their native game objects have been
-- destroyed (notably when underground enrichment markers are staged between decor annotation and
-- decor scaling). Never call a C object method such as GetParent until IsValid confirms the native
-- luaGameObject still exists.
local function IsLiveGameObject(obj)
	if not obj then return false end
	local is_valid = Global("IsValid")
	if type(is_valid) == "function" then
		return SafeCall(is_valid, obj) == true
	end
	return type(obj.GetPos) == "function"
end

local skip_clone_classes = {
	City = true,
	MapSector = true,
	RandomMapGeneratorHolder = true,
	RevealedMapSector = true,
	-- The overview sector-grid visuals are decal objects placed per-sector by
	-- MapSector:UpdateDecal() (PlaceObjectIn "SectorUnexplored"/"SectorScanned").
	-- They are UI overlays, never terrain scatter, so stretch/top-up object
	-- classification must never treat them as cloneable decorations.
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
	-- Buried-wonder markers are gameplay placement records, not cosmetic rocks.  Their centers are
	-- transformed exactly once by ScaleMarkersToFull and their vanilla scale is consumed later when
	-- the assigned wonder is materialized.  Letting the decoration pass see them used to grow the
	-- marker first (100 -> 133), then grow the spawned Jumbo Cave a second time (133 -> 177); it
	-- could also create a random decoration top-up clone and therefore an extra buried wonder.
	"BuriedWonderMarker",
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
-- cloned or repositioned: leave the player's mystery content completely alone.
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
	if not IsLiveGameObject(obj) then
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
	if not IsLiveGameObject(obj) or skip_clone_classes[obj.class or false] then
		return true
	end

	if obj.SuperBigMapEnrichmentClone then
		return true
	end

	-- Never touch mystery content.
	if IsMysteryRelatedObject(obj) then
		return true
	end

	-- Never clone underground entrance/access markers, symbols, or decoration. Game
	-- references: UndergroundPassage.lua defines SurfaceUndergroundTunnelMarker /
	-- Sign, and SurfacePassageRocks.lua uses ElevatorBuildIndicator_UndergroundRocks.
	local underground = IsUndergroundAccessObject(obj)
	if underground then
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

end

local function CloneObjectAtOffset(map, source, offset, skip_deposit_processing)
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

	clone.SuperBigMapEnrichmentClone = true
	CopyObjectTransform(source, clone, offset)
	-- Deposit handling on the clone: scan-gate visibility (hide until its sector is
	-- scanned) + optional reshuffle onto terrain matching the source. No-op for non-deposits.
	local deposits = SuperBigMap.DepositRules
	if skip_deposit_processing ~= true
		and deposits and type(deposits.ProcessClone) == "function" then
		deposits.ProcessClone(map, source, clone)
	end
	return clone
end

-- ============================================================================
-- WHICH OBJECTS GROW WITH THE TERRAIN
-- ============================================================================
-- The expansion is a similarity transform, so COSMETIC DECORATION scales with the ground
-- it sits on -- that is the default, and it covers most classes (Cliff*, Dec*, Rocks*,
-- Stones*, Underground_Arch*, ...). FUNCTIONAL objects keep their vanilla scale, because
-- their size is gameplay or generation geometry (deposit scan radius, entrance/elevator
-- hex footprint, sector extent, prefab placement footprint, sound/particle reach) rather
-- than art. `ScaleMarkersToFull` already states that rule for the marker pass it owns;
-- this predicate is the same rule for every object the decoration pass walks, so a class
-- is judged by WHAT IT IS and never by which map or coordinate is being generated.
--
-- Measured at 30S146E before this existed: the decoration pass scaled whatever it walked,
-- so PrefabMarker (1,424 of 1,475 at 250 -> 333, the other 51 untouched), PrefabDecorMarker,
-- SoundSource and the underground's ParSystem all grew, while the surface's ParSystem did
-- not. That inconsistency is what makes it a defect rather than a policy: the same category
-- of object has to answer the same way on both maps and on every map.
local scale_keep_kinds = {
	"DepositMarker", "Deposit", "Anomaly", "Marker", "Passage", "Tunnel", "Sign",
	"Elevator", "MapSector", "Sector", "GridObjectList", "RandomMapGeneratorHolder",
	"CameraObj", "ParSystem", "SoundSource",
}

local scale_keep_exact = {
	SurfacePassage = true,
	UndergroundPassage = true,
	SurfaceTunnelMarker = true,
	UndergroundTunnelMarker = true,
	SurfaceUndergroundTunnelSign = true,
	ElevatorBuildIndicator_SurfaceDecal = true,
	ElevatorBuildIndicator_UndergroundPassageImprint = true,
}

-- Functional classes that DO grow anyway, by explicit user decision: they are sculpted into
-- the terrain, so a feature that grew with the ground it was carved from is consistent.
local scale_stretch_allowlist = {
	PrefabFeatureMarker = true,   -- geysers and every other prefab feature
	CaveInRubble = true,
	TunnelBlockerRubble = true,
	BottomlessPit = true,
	JumboCave = true,
}

-- True when this class name is expected to grow by the stretch ratio. Name-based, matching
-- the parity gate `class-scale-expected`, so the mod and the gate cannot drift apart.
local function ClassScalesWithTerrain(cls)
	if type(cls) ~= "string" or cls == "" then
		return true                        -- unknown class: keep the decoration default
	end
	if scale_stretch_allowlist[cls] then
		return true                        -- explicit exception, checked first
	end
	if scale_keep_exact[cls] then
		return false
	end
	for i = 1, #scale_keep_kinds do
		if string.find(cls, scale_keep_kinds[i], 1, true) then
			return false
		end
	end
	return true
end

local function ObjectScalesWithTerrain(obj)
	if not obj then return false end
	return ClassScalesWithTerrain(rawget(obj, "class") or obj.class)
end

-- Public API consumed by the stretch and enrichment modules.
local ObjectClone = {
	ClassScalesWithTerrain = ClassScalesWithTerrain,
	ObjectScalesWithTerrain = ObjectScalesWithTerrain,
	IsLiveGameObject = IsLiveGameObject,
	IsMysteryRelatedObject = IsMysteryRelatedObject,
	MatchUndergroundAccessName = MatchUndergroundAccessName,
	ObjectMatchesUndergroundAccessName = ObjectMatchesUndergroundAccessName,
	IsUndergroundAccessObject = IsUndergroundAccessObject,
	IsResourceDepositMarker = IsResourceDepositMarker,
	ShouldSkipObject = ShouldSkipObject,
	IsImportantSectorObject = IsImportantSectorObject,
	CopyObjectTransform = CopyObjectTransform,
	CloneObjectAtOffset = CloneObjectAtOffset,
}
SuperBigMap.ObjectClone = ObjectClone
