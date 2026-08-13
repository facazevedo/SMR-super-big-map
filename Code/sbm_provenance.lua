-- Super Big Map -- vanilla-object provenance records.
--
-- Objects that exist when the natively generated population is handed to the expanded map are
-- stamped with SuperBigMapNativeSource* by TransferGeneratedObjects. Vanilla creates a second
-- group of objects LATER, after that transfer, from those stamped objects:
--
--   * SpawnsOnCityInit:Spawn -> UndergroundTunnelMarker / SurfaceTunnelMarker /
--     SubsurfaceSpecialAnomalyMarker (marker.spawner is the generated prefab),
--   * SurfaceUndergroundTunnelMarker:PlaceSign -> SurfaceUndergroundTunnelSign
--     (sign.tunnel_marker is the marker),
--   * DepositMarker:SpawnDeposit -> the live Deposit object (deposit.marker is the marker),
--   * attached children (ParSystem effects, ElevatorBuildIndicator_* decals) of any of those.
--
-- Those objects are not mod-created extras: the vanilla twin creates exactly the same object
-- from exactly the same generated parent. They simply never pass through the transfer, so they
-- carry no record of which vanilla object they correspond to, which makes a record-level
-- one-to-one comparison against the vanilla twin impossible for them.
--
-- This module records that correspondence. It writes a SEPARATE field namespace
-- (SuperBigMapProvenance*), never SuperBigMapNativeSource*, because several placement decisions
-- branch on the presence of a native stamp (the marker pass hex-snaps only stamped objects, the
-- enrichment recreation path treats a stamped marker as native) and must keep behaving exactly
-- as before. Nothing in this file moves, creates, or destroys an object.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local Engine = SuperBigMap.Engine
local Global = Engine and Engine.Global or function(name) return rawget(_G, name) end
local SafeCall = Engine and Engine.SafeCall or function(fn, ...)
	if type(fn) ~= "function" then return nil end
	local ok, value = pcall(fn, ...)
	if ok then return value end
	return nil
end

local Provenance = {}

-- Order matters only for readability: an object reaches at most one stamped ancestor in
-- practice, and the first stamped one found is the object vanilla derived it from.
local DONOR_FIELDS = { "marker", "tunnel_marker", "spawner", "passage", "linked_obj" }
local MAX_DONOR_DEPTH = 8

local function IsLiveObject(obj)
	if type(obj) ~= "table" then return false end
	local is_valid = Global("IsValid")
	if type(is_valid) == "function" then
		return SafeCall(is_valid, obj) == true
	end
	return type(obj.GetPos) == "function"
end

-- The immutable native coordinate this object already carries, from either namespace.
local function RecordedSource(obj)
	local x, y = obj.SuperBigMapNativeSourceX, obj.SuperBigMapNativeSourceY
	if type(x) == "number" and type(y) == "number" then
		return x, y, (type(obj.SuperBigMapNativeSourceZ) == "number")
			and obj.SuperBigMapNativeSourceZ or nil
	end
	x, y = obj.SuperBigMapProvenanceX, obj.SuperBigMapProvenanceY
	if type(x) == "number" and type(y) == "number" then
		return x, y, (type(obj.SuperBigMapProvenanceZ) == "number")
			and obj.SuperBigMapProvenanceZ or nil
	end
	return nil
end

Provenance.RecordedSource = RecordedSource

-- Write a provenance record for an object the mod itself recreates in the source domain (the
-- bootstrap surface passage anchor). Never overwrites an existing record.
function Provenance.RecordNativeSpawn(obj, kind, from)
	if type(obj) ~= "table" or RecordedSource(obj) then return false end
	local pos = type(obj.GetPos) == "function" and SafeCall(obj.GetPos, obj) or nil
	if not pos then return false end
	local x = type(pos.x) == "function" and SafeCall(pos.x, pos) or nil
	local y = type(pos.y) == "function" and SafeCall(pos.y, pos) or nil
	if type(x) ~= "number" or type(y) ~= "number" then return false end
	obj.SuperBigMapProvenanceX = x
	obj.SuperBigMapProvenanceY = y
	local z = type(pos.z) == "function" and SafeCall(pos.z, pos) or nil
	if type(z) == "number" then obj.SuperBigMapProvenanceZ = z end
	obj.SuperBigMapProvenanceClass = tostring(obj.class or "?")
	obj.SuperBigMapProvenanceKind = tostring(kind or "native_spawn")
	obj.SuperBigMapProvenanceFrom = tostring(from or "?")
	return true
end

local function Donors(obj)
	local list = {}
	if type(obj.GetParent) == "function" then
		local parent = SafeCall(obj.GetParent, obj)
		if type(parent) == "table" then list[#list + 1] = parent end
	end
	for i = 1, #DONOR_FIELDS do
		local donor = obj[DONOR_FIELDS[i]]
		if type(donor) == "table" then list[#list + 1] = donor end
	end
	return list
end

-- Walk the creation chain until a recorded source is found. Returns the coordinate plus the
-- object it came from, so the derived record names its donor and stays auditable.
local function ResolveDonorSource(obj, seen, depth)
	if type(obj) ~= "table" or seen[obj] or depth > MAX_DONOR_DEPTH then return nil end
	seen[obj] = true
	if not IsLiveObject(obj) then return nil end
	local x, y, z = RecordedSource(obj)
	if x then return x, y, z, obj end
	local donors = Donors(obj)
	for i = 1, #donors do
		local dx, dy, dz, from = ResolveDonorSource(donors[i], seen, depth + 1)
		if dx then return dx, dy, dz, from end
	end
	return nil
end

-- Fill in the derived records for one map. Idempotent: an object that already carries a record
-- in either namespace is left untouched, so repeated calls cannot change anything.
function Provenance.Propagate(map, reason)
	if type(map) ~= "table" or type(map.MapGet) ~= "function" then return 0, 0 end
	local objs = SafeCall(map.MapGet, map, "map")
	if type(objs) ~= "table" then return 0, 0 end
	local pause_ild = Global("PauseInfiniteLoopDetection")
	local resume_ild = Global("ResumeInfiniteLoopDetection")
	if type(pause_ild) == "function" then pcall(pause_ild, "SuperBigMapProvenance") end
	local derived, unresolved = 0, 0
	local ok, err = pcall(function()
		for i = 1, #objs do
			local obj = objs[i]
			if type(obj) == "table" and IsLiveObject(obj) and not RecordedSource(obj) then
				local x, y, z, from = ResolveDonorSource(obj, {}, 0)
				if x then
					obj.SuperBigMapProvenanceX = x
					obj.SuperBigMapProvenanceY = y
					if type(z) == "number" then obj.SuperBigMapProvenanceZ = z end
					obj.SuperBigMapProvenanceClass = tostring(obj.class or "?")
					obj.SuperBigMapProvenanceKind = "derived"
					obj.SuperBigMapProvenanceFrom = tostring(from and from.class or "?")
					derived = derived + 1
				else
					unresolved = unresolved + 1
				end
			end
		end
	end)
	if type(resume_ild) == "function" then pcall(resume_ild, "SuperBigMapProvenance") end
	map.SuperBigMapProvenanceDerived = derived
	map.SuperBigMapProvenanceUnresolved = unresolved
	local diagnostics = SuperBigMap.Diagnostics
	if diagnostics and type(diagnostics.LoadingStep) == "function" then
		SafeCall(diagnostics.LoadingStep, "derived object provenance recorded", {
			reason = tostring(reason or "?"),
			derived = derived,
			unresolved = unresolved,
			error = ok and "" or tostring(err),
		}, map)
	end
	return derived, unresolved
end

SuperBigMap.Provenance = Provenance
