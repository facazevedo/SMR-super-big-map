-- Super Big Map -- non-rendered frame cleanup.
--
-- This module used to host the manual fake-terrain HUD (procedural floor plates,
-- sand decals), the flat-floor "lid" mesh that blanketed the non-rendered frame,
-- and the rocket-landing / rover-unload "frame floor" patches. All of that was
-- removed once the frame became real (mirrored) terrain instead of a flat lid:
-- there is no lid, the frame is not flattened, there are no HUD buttons, and
-- rockets/rovers use the real terrain normally.
--
-- What remains is the one still-wanted piece: deleting the vanilla crater decals
-- that the random-map decor pass scatters across the non-rendered frame. It is
-- driven directly by SuperBigMap.Lifecycle on each map load.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end
SuperBigMap.State = SuperBigMap.State or {}

local Engine = SuperBigMap.Engine
local Global = Engine and Engine.Global or function(name)
	return rawget(_G, name)
end

local MODULE = {}

-- ============================================================================
-- Config + debug + generic helpers
-- ============================================================================
local function Cfg()
	return SuperBigMap.Config or {}
end

local function CfgBool(key, default)
	local value = Cfg()[key]
	if value == nil then
		return default == true
	end
	return value == true
end

local function DebugInfo(message, data)
	local debug_log = SuperBigMap.DebugLog
	if debug_log then
		debug_log.Info("FakeTerrain", message, data)
	end
end

local function ObjectValid(obj)
	if not obj then
		return false
	end
	local is_valid = Global("IsValid")
	if type(is_valid) == "function" then
		local ok, valid = pcall(is_valid, obj)
		return ok and valid == true
	end
	return true
end

local function DeleteObject(obj)
	if not obj then
		return
	end
	local done_object = Global("DoneObject")
	if type(done_object) == "function" then
		local ok = pcall(done_object, obj)
		if ok then
			return
		end
	end
	if type(obj.delete) == "function" then
		pcall(obj.delete, obj)
	end
end

local function ReadField(obj, field)
	if not obj then
		return nil
	end
	local ok, value = pcall(function()
		return obj[field]
	end)
	return ok and value or nil
end

local function CallMethod(obj, method, ...)
	local fn = ReadField(obj, method)
	if type(fn) ~= "function" then
		return nil
	end
	local ok, value = pcall(fn, obj, ...)
	return ok and value or nil
end

local function CurrentMap()
	return Global("CurrentMap") or Global("MainMap")
end

-- Source-rectangle ORIGIN (world units) of the rendered scenario inside the
-- allocated map. The original is always corner-anchored at (0,0), so this is
-- effectively (0,0); kept as a helper so frame tests read a defined origin.
local function SourceOriginXY(map)
	if type(map) ~= "table" then
		return 0, 0
	end
	local sx = type(map.SuperBigMapSourceX) == "number" and map.SuperBigMapSourceX or 0
	local sy = type(map.SuperBigMapSourceY) == "number" and map.SuperBigMapSourceY or 0
	return sx, sy
end

-- True when (x,y) world coords fall OUTSIDE the rendered/source rectangle, i.e.
-- in the non-rendered frame. Origin (sx,sy) is the corner anchor (0,0); sw/sh are
-- the source extent (world units).
local function PointOutsideSource(sx, sy, sw, sh, x, y)
	return x < sx or x >= sx + sw or y < sy or y >= sy + sh
end

-- ============================================================================
-- Remove vanilla crater decor from the non-rendered frame
-- ============================================================================
-- Vanilla's random-map decor pass (Proc_PlaceDecors) scatters DecCrater_* decals
-- across the WHOLE allocated map, including the non-rendered frame around the
-- playable source quadrant. Delete only the ones beyond the source extent;
-- craters inside the rendered/playable area are vanilla and left untouched. Runs
-- on each map load (decor is regenerated per map), so this is effectively
-- persistent.
function MODULE.RemoveFrameCraters(map)
	if not CfgBool("REMOVE_FRAME_CRATERS", true) then
		return false, "disabled"
	end
	map = map or CurrentMap()
	if not map then
		return false, "no map"
	end
	-- Once per map: the lifecycle calls this at PostNewMapLoaded, LoadGame AND
	-- MapGenerated, so without this guard a new game scans every DecCrater up to
	-- three times. (Fresh map object on reload resets the flag, as intended.)
	if map.SuperBigMapFrameCratersDone == true then
		return false, "already done"
	end
	local sw = map.SuperBigMapSourceWidth
	local sh = map.SuperBigMapSourceHeight
	if type(sw) ~= "number" or type(sh) ~= "number" then
		return false, "no source extent (map not expanded)"
	end
	local is_kind_of = Global("IsKindOf")
	if type(is_kind_of) ~= "function" then
		return false, "IsKindOf unavailable"
	end
	local sx, sy = SourceOriginXY(map)
	local removed = 0
	-- Frame = anything OUTSIDE the source rect [sx,sx+sw) x [sy,sy+sh). The origin
	-- is the corner anchor 0,0 (frame = x>=sw or y>=sh). Craters inside the rect
	-- are vanilla and kept.
	local function consider(obj)
		if not ObjectValid(obj) or is_kind_of(obj, "DecCrater") ~= true then
			return
		end
		local pos = CallMethod(obj, "GetPos")
		if not pos then
			return
		end
		local ok_xy, x, y = pcall(function()
			return pos:xyz()
		end)
		if not ok_xy or type(x) ~= "number" or type(y) ~= "number" then
			return
		end
		if not PointOutsideSource(sx, sy, sw, sh, x, y) then
			return -- inside the rendered source rect; vanilla, keep it
		end
		DeleteObject(obj)
		removed = removed + 1
	end
	if type(map.MapForEach) == "function" then
		pcall(map.MapForEach, map, "map", "DecCrater", consider)
	elseif type(map.MapGet) == "function" then
		local ok, objects = pcall(map.MapGet, map, "map", "DecCrater")
		if ok and type(objects) == "table" then
			for _, obj in ipairs(objects) do
				consider(obj)
			end
		end
	else
		return false, "no map iterator"
	end
	map.SuperBigMapFrameCratersDone = true
	DebugInfo("frame craters removed", { count = removed, source_w = sw, source_h = sh })
	return true, removed
end

-- ============================================================================
-- Lifecycle
-- ============================================================================
-- Nothing to install/restore: the only behavior left (crater removal) is driven
-- directly by the lifecycle's map-load handlers. These are kept as no-ops so the
-- lifecycle's apply/restore phase ordering is unchanged.
function MODULE.ApplyModBehavior()
	return true
end

function MODULE.RestoreVanillaBehavior()
	return true
end

SuperBigMap.FakeTerrain = MODULE
