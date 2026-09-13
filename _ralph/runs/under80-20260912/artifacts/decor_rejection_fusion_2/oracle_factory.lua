return function(deps)
local terrain_api = {GetTerrainType=deps.get_type}
local map = deps.map
local point_fn = deps.point_fn
local type_tile = deps.type_tile
local SafeCall = deps.SafeCall
local matches_cache = deps.matches_cache
local revision = deps.revision
local version = deps.version
local circle_hits = deps.circle_hits
local obstruct = deps.obstruct
local decorated = deps.decorated
local allowed_count = deps.allowed_count
local allowed_types = deps.allowed_types
local get_type = terrain_api.GetTerrainType
			local type_cache = deps.type_cache
			local function terrain_type_at(x, y)
				if type(get_type) ~= "function" then return 0 end
				local key = math.floor(x / type_tile) * 1000003 + math.floor(y / type_tile)
				local cached = type_cache[key]
				if cached ~= nil then return cached end
				local okt, t = pcall(get_type, map, point_fn(x, y))
				t = okt and type(t) == "number" and t or -1
				type_cache[key] = t
				return t
			end
					local function try_stamp(marker, sx, sy, site_radius)
			local prefabs = matches_cache[marker]
			if prefabs == nil then
				prefabs = SafeCall(marker.GetMatchingMarkers, marker, revision, version)
				-- Cache legitimate empty lists too, but never make a failed call
				-- permanent. Preserve no_match precedence over spacing rejection.
				if type(prefabs) == "table" then matches_cache[marker] = prefabs end
			end
			if type(prefabs) ~= "table" or #prefabs == 0 then return "no_match" end
			if circle_hits(obstruct, sx, sy, site_radius) then return "obstruct" end
			if circle_hits(decorated, sx, sy, site_radius) then return "decorated" end
			return nil, prefabs
		end
return function(marker, sx, sy, site_radius)
 if allowed_count > 0 and not allowed_types[terrain_type_at(sx, sy)] then return "terrain" end
 return try_stamp(marker, sx, sy, site_radius)
end
end
