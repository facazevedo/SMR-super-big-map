-- 1.1 compatibility: retain the full native terrain/pass grids, but use the
-- pre-1.1 pathfinder on expanded maps. The new connectivity allocator cannot
-- represent an 8192 terrain with no artificial impassable border.
--
-- GameLogic=false is passed ONLY in a private copy to EngineChangeMap. The
-- real Lua mapdata keeps GameLogic=true (cities, units, simulation, persistence).
-- No engine files, terrain dimensions, pass classes or obstacles are changed.
local SBM = rawget(_G, "SuperBigMap")
local Legacy = {}
SBM.LegacyPathfinder = Legacy
local state = SBM.State
state.legacy_pathfinder_hooks = state.legacy_pathfinder_hooks or {}
local hooks = state.legacy_pathfinder_hooks

if not MapVarValues or MapVarValues.SuperBigMapLegacyPathfinder == nil then
	-- NewMap initializes MapVars after EngineChangeMap. Preserve the allocator's
	-- decision instead of resetting it; persistence restores this bit on reload.
	MapVar("SuperBigMapLegacyPathfinder", function(map)
		return map.SuperBigMapLegacyPathfinder == true
	end)
end

local function Resolve(value)
	return value and ResolveMap(value) or nil
end

function Legacy.IsMap(value)
	local map = Resolve(value)
	return map and map.SuperBigMapLegacyPathfinder == true or false
end

local function Class(source, explicit)
	if explicit ~= nil then return explicit end
	return IsValid(source) and source.GetPfClass and source:GetPfClass() or 0
end

local function Position(value)
	if IsPoint(value) then return value end
	return IsValid(value) and value:GetPos() or nil
end

-- A real path search replaces the native O(1) connectivity lookup, and vanilla callers still
-- query it in loops (2026-10-02 "XL map Stutter save": ClearWasteRockConstructionSite:GetOutputPile
-- made ~1900 failing searches without yielding, an 8 s freeze every ~25 s). Memoize only while
-- nothing that a path depends on can change: the same map, the same GameTime and no
-- OnPassabilityChanged since. The key is the exact endpoints and pass class, so every answer is
-- the one a fresh search would return; landscaping and construction still invalidate at once.
state.legacy_pathfinder_pass_version = state.legacy_pathfinder_pass_version or 0
if not state.legacy_pathfinder_pass_msg and SBM.Engine and SBM.Engine.ChainOnMsg then
	state.legacy_pathfinder_pass_msg = true
	SBM.Engine.ChainOnMsg("OnPassabilityChanged", function()
		local live = rawget(_G, "SuperBigMap")
		local s = live and live.State
		if s then s.legacy_pathfinder_pass_version = (s.legacy_pathfinder_pass_version or 0) + 1 end
	end)
end
-- Tunnels join or split path components without a passability change; invalidate on them too.
if not state.legacy_pathfinder_tunnel_msg and SBM.Engine and SBM.Engine.ChainOnMsg then
	state.legacy_pathfinder_tunnel_msg = true
	SBM.Engine.ChainOnMsg("PFTunnelChanged", function()
		local live = rawget(_G, "SuperBigMap")
		local s = live and live.State
		if s then s.legacy_pathfinder_pass_version = (s.legacy_pathfinder_pass_version or 0) + 1 end
	end)
end
local MEMO_LIMIT = 8192
local memo = { map = false, stamp = false, version = false, entries = {}, count = 0 }
local function PathLength(map, from, to, pfclass)
	local game_time = rawget(_G, "GameTime")
	local stamp = type(game_time) == "function" and game_time() or nil
	local version = state.legacy_pathfinder_pass_version
	if stamp == nil then
		local reachable, length = pf.PosPathLen(map, from, to, pfclass)
		return reachable and length or nil
	end
	if memo.map ~= map or memo.stamp ~= stamp or memo.version ~= version or memo.count >= MEMO_LIMIT then
		memo.map, memo.stamp, memo.version, memo.entries, memo.count = map, stamp, version, {}, 0
	end
	local fx, fy, fz = from:xyz()
	local tx, ty, tz = to:xyz()
	local key = tostring(fx) .. "," .. tostring(fy) .. "," .. tostring(fz) .. ">" .. tostring(tx) .. ","
		.. tostring(ty) .. "," .. tostring(tz) .. ":" .. tostring(pfclass)
	local cached = memo.entries[key]
	if cached ~= nil then
		Legacy.memo_hits = (Legacy.memo_hits or 0) + 1
		return cached or nil
	end
	local reachable, length = pf.PosPathLen(map, from, to, pfclass)
	local result = reachable and length or false
	memo.entries[key] = result
	memo.count = memo.count + 1
	Legacy.memo_misses = (Legacy.memo_misses or 0) + 1
	return result or nil
end

-- Return real path length or nil, never a straight-line guess or a partial path.
-- Connectivity's explicit radius is a passable-endpoint search, not permission
-- to walk through impassable cells.
-- Restricted walking searches (see CheckWalkableDistance below): exact path lengths within the
-- disc of radius limit/2 (+ two hexes for the passable-point snap) around the midpoint. They live
-- in vanilla's own map.PathCache (a separate field), so they share its lifetime exactly: reset when
-- map.PassVersion changes and kept by PathLenCacheValidate; the shared lengths table is untouched.
local walk_restrict
local function RestrictedLength(map, pt1, pt2, pfclass, limit)
	local pass_id = map.PassVersion
	local path_cache = map.PathCache
	if not path_cache or path_cache.pass_id ~= pass_id then
		path_cache = { pass_id = pass_id, lengths = {}, hits = 0 }
		map.PathCache = path_cache
	end
	local entries = path_cache.sbm_restricted
	if not entries then
		entries = {}
		path_cache.sbm_restricted = entries
	end
	local ax, ay, az = pt1:xyz()
	local bx, by, bz = pt2:xyz()
	local key = tostring(ax) .. "," .. tostring(ay) .. "," .. tostring(az) .. ">" .. tostring(bx) .. ","
		.. tostring(by) .. "," .. tostring(bz) .. ":" .. tostring(pfclass) .. ":" .. tostring(limit)
	local cached = entries[key]
	if cached ~= nil then return cached or nil end
	-- Every point x of a path no longer than limit has |x-p1| + |x-p2| <= limit, hence lies within
	-- limit/2 of the midpoint m (|x-m| <= (|x-p1| + |x-p2|) / 2): a disc a quarter the area of one
	-- of radius limit around p1, and still containing every path the caller can accept.
	local center = point((ax + bx) // 2, (ay + by) // 2, ((az or 0) + (bz or 0)) // 2)
	local radius = limit // 2 + 2 * const.HexSize
	local reachable, length = pf.PosPathLen(map, pt1, pt2, pfclass, 0, 0, nil, radius, center)
	local result = reachable and length or false
	entries[key] = result
	Legacy.restricted_searches = (Legacy.restricted_searches or 0) + 1
	return result or nil
end

local function Distance(map, source, dest, pfclass, radius)
	local from, to = Position(source), Position(dest)
	if not from or not to then return nil end
	local dest_map = IsValid(dest) and Resolve(dest)
	if dest_map and dest_map ~= map then return nil end
	pfclass = Class(source, pfclass)
	if radius and radius > 0 then
		from = terrain.FindPassable(map, from, pfclass, radius)
		to = terrain.FindPassable(map, to, pfclass, radius)
		if not from or not to then return nil end
	end
	return PathLength(map, from, to, pfclass)
end

-- The list form asks "can the source reach any of these destinations?". Vanilla callers pass
-- whole site peripheries: RCTerraformer automation hands over a landscaping site's
-- drone_dests_cache ("can have 100+ points") and ClearWasteRock asks the same for a rover. Natively
-- that is a cheap region lookup; here every point was a path search, and an unreachable site cost
-- one failing search per point (2026-10-04 "United States of Mars": 149 points, 5.6 s per idle
-- RC Terraformer). Two exact shortcuts:
-- 1. one search to the points' centre that may end anywhere within a radius covering every
--    point (plus the passable-endpoint search radius): if even that fails, no point is reachable;
-- 2. otherwise search the points nearest-first and stop at the first reachable one.
-- Callers only test the result for truth; it is now the first reachable point's path length
-- rather than the shortest one.
local RANGED_MIN_POINTS = 4
local function CheckAny(map, source, dests, pfclass, radius)
	local from = Position(source)
	if not from or #dests == 0 then return nil end
	local points = {}
	for i = 1, #dests do
		if not IsPoint(dests[i]) then points = nil break end
		points[i] = dests[i]
	end
	local class = Class(source, pfclass)
	if points and #points >= RANGED_MIN_POINTS then
		local start = from
		if radius and radius > 0 then start = terrain.FindPassable(map, from, class, radius) end
		if not start then return nil end
		local sx, sy = 0, 0
		for i = 1, #points do
			local x, y = points[i]:xyz()
			sx, sy = sx + x, sy + y
		end
		local cx, cy = sx // #points, sy // #points
		local center = point(cx, cy)
		local cz = type(map.GetHeight) == "function" and map:GetHeight(center) or 0
		center = point(cx, cy, cz)
		local reach = 0
		for i = 1, #points do
			local x, y, z = points[i]:xyz()
			local dx, dy, dz = x - cx, y - cy, (z or cz) - cz
			reach = math.max(reach, math.ceil(math.sqrt(dx * dx + dy * dy + dz * dz)))
		end
		reach = reach + (radius or 0) + const.HexSize
		Legacy.ranged_checks = (Legacy.ranged_checks or 0) + 1
		if not pf.PosPathLen(map, start, center, class, reach) then
			Legacy.ranged_rejects = (Legacy.ranged_rejects or 0) + 1
			return nil
		end
	end
	local order, distance = {}, {}
	local fx, fy = from:xyz()
	for i = 1, #dests do
		order[i] = i
		local p = Position(dests[i])
		if p then
			local x, y = p:xyz()
			distance[i] = (x - fx) * (x - fx) + (y - fy) * (y - fy)
		else
			distance[i] = math.huge
		end
	end
	table.sort(order, function(a, b) return distance[a] < distance[b] end)
	for _, i in ipairs(order) do
		local length = Distance(map, source, dests[i], pfclass, radius)
		if length then return length end
	end
	return nil
end

local function Check(map, source, dest, pfclass, radius, ...)
	-- Public overload: (map, source, x, y, z, pfclass, radius).
	if type(dest) == "number" then
		local passclass, search_radius = ...
		dest, pfclass, radius = point(dest, pfclass, radius), passclass, search_radius
	end
	if type(dest) == "table" and not IsPoint(dest) and not IsValid(dest) then
		return CheckAny(map, source, dest, pfclass, radius)
	end
	return Distance(map, source, dest, pfclass, radius)
end

local function CheckAll(map, source, destinations, pfclass, radius)
	local results = {}
	for i = 1, #destinations do
		results[i] = Distance(map, source, destinations[i], pfclass, radius) or -1
	end
	return results
end

local function CheckSpot(source, target, spot, anim, pfclass, radius)
	local map = Resolve(source)
	if not IsValid(target) or Resolve(target) ~= map then return nil end
	local first, last
	if type(spot) == "number" then first, last = spot, spot
	else first, last = target:GetSpotRange(anim or target:GetStateText(), spot) end
	local best
	for index = first or -1, last or -1 do
		if index >= 0 then
			local length = Distance(map, source, target:GetSpotPos(index), pfclass, radius)
			if length and (not best or length < best) then best = length end
		end
	end
	return best
end

local function InstallGlobal(name, factory)
	local existing = hooks[name]
	if existing and _G[name] == existing.wrapper then return end
	local original = _G[name]
	if type(original) ~= "function" then return end
	local wrapper = factory(original)
	hooks[name] = { original = original, wrapper = wrapper }
	-- Ordinary assignment deliberately follows the mod sandbox's public global
	-- bridge. rawset would shadow only this mod, leaving vanilla consumers native.
	_G[name] = wrapper
end

function Legacy.ApplyModBehavior()
	if not const.ConnectivitySupported then return false end
	InstallGlobal("EngineChangeMap", function(original)
		return function(slot, folder, data, ...)
			local map = Maps[slot]
			-- Size alone identifies an expanded map: vanilla terrains stop at 6144 tiles, and the native
			-- connectivity allocator cannot represent 8192. A cold load from the main menu finds only the
			-- menu map in this slot (no expansion flags), so testing those flags allocated native
			-- connectivity there and logged "l_ConnectivityProcessResume: pConnectivity" (2026-10-02).
			if data and data.GameLogic
				and (data.Width or 0) >= 8192 and (data.Height or 0) >= 8192 then
				local shadow = {}
				for key, value in pairs(data) do shadow[key] = value end
				setmetatable(shadow, getmetatable(data))
				shadow.GameLogic = false
				if map then map.SuperBigMapLegacyPathfinder = true end
				local diagnostic = SBM.Diagnostics and SBM.Diagnostics.Compatibility
				if diagnostic then diagnostic("legacy pathfinder allocation", {slot=slot,width=data.Width,height=data.Height}) end
				return original(slot, folder, shadow, ...)
			end
			return original(slot, folder, data, ...)
		end
	end)
	for _, name in ipairs({"ConnectivityResume", "ConnectivitySuspend"}) do
		InstallGlobal(name, function(original)
			return function(map, ...)
				if Legacy.IsMap(map) then return end
				return original(map, ...)
			end
		end)
	end
	-- GetTopClosestDests ranks a landscaping site's or lake's whole periphery on every drone approach
	-- ("there can be hundreds of destinations ... checked by each PF wave"): one ConnectivityCheckAll,
	-- i.e. one path search per destination on a legacy map. Vanilla falls back to ordering by 2D
	-- distance whenever connectivity data is unavailable, and that is also its exact order when no
	-- destination is reachable. Use that fallback on legacy maps; the drone's Goto to the chosen
	-- destinations still pathfinds for real, with vanilla's Goto_NoDestlock retry.
	-- Vanilla CheckWalkableDistance (domes, emigration, colonists leaving Mars) only accepts a path
	-- no longer than ColonistMaxDomeWalkDist L; pairs farther apart than L in 2D never search. A
	-- path of length <= L never leaves the disc of radius L/2 around the midpoint of its ends, so on
	-- legacy maps the nested PathLenCached searches only that disc (restrict_radius/restrict_center):
	-- the same answer and length for every walkable pair, and a failing pair no longer floods the
	-- whole expanded map (2026-10-05 "United States of Mars" at 5x: 220 and 144 ms stalls; on that
	-- save all 14 dome pairs within L agreed exactly with the unrestricted search). The restricted
	-- results have their own cache, so vanilla's shared path cache (IsConnectedByFoot, uncapped)
	-- never sees them. A pair that is not walkable reports length -1 rather than its long route.
	InstallGlobal("CheckWalkableDistance", function(original)
		return function(map, ...)
			if not Legacy.IsMap(map) then return original(map, ...) end
			local consts = rawget(_G, "g_Consts")
			local limit = consts and consts.ColonistMaxDomeWalkDist
			if type(limit) ~= "number" or limit <= 0 or walk_restrict then return original(map, ...) end
			walk_restrict = limit
			local results = { pcall(original, map, ...) }
			walk_restrict = nil
			if not results[1] then error(results[2], 0) end
			return (table.unpack or unpack)(results, 2)
		end
	end)
	InstallGlobal("PathLenCached", function(original)
		return function(map, pt1, pt2, pfclass, ...)
			if not walk_restrict or not Legacy.IsMap(map) then return original(map, pt1, pt2, pfclass, ...) end
			local len = RestrictedLength(map, pt1, pt2, pfclass, walk_restrict)
			return len ~= nil, len or -1
		end
	end)
	InstallGlobal("GetTopClosestDests", function(original)
		return function(map, dests, unit, top_count, ...)
			if not Legacy.IsMap(Resolve(map) or Resolve(unit)) then return original(map, dests, unit, top_count, ...) end
			top_count = top_count or 10
			local count = #dests
			if count <= top_count then return table.icopy(dests) end
			local order = {}
			for i = 1, count do order[i] = i end
			table.sort(order, function(i1, i2) return IsCloser2D(unit, dests[i1], dests[i2]) end)
			local top_dests = {}
			for i = 1, top_count do top_dests[i] = dests[order[i]] end
			return top_dests
		end
	end)
	for _, name in ipairs({"ConnectivityCheck", "ConnectivityCheckAll"}) do
		local query = name == "ConnectivityCheck" and Check or CheckAll
		InstallGlobal(name, function(original)
			return function(map, source, ...)
				local resolved = Resolve(map) or Resolve(source)
				if Legacy.IsMap(resolved) then return query(resolved, source, ...) end
				return original(map, source, ...)
			end
		end)
	end
	for _, name in ipairs({"ConnectivityCheckObj", "ConnectivityCheckObjAll", "ConnectivityCheckObjSpot"}) do
		local query = name == "ConnectivityCheckObj" and Check or CheckAll
		InstallGlobal(name, function(original)
			return function(source, ...)
				local map = Resolve(source)
				if Legacy.IsMap(map) then
					if name == "ConnectivityCheckObjSpot" then return CheckSpot(source, ...) end
					return query(map, source, ...)
				end
				return original(source, ...)
			end
		end)
	end
	-- Class construction copies native methods, so changing only globals misses
	-- object:ConnectivityCheck, Map:ConnectivityCheck and retail BaseUnit:CanReach.
	local replacements = {}
	for _, hook in pairs(hooks) do replacements[hook.original] = hook.wrapper end
	state.legacy_pathfinder_members = state.legacy_pathfinder_members or {}
	local members = state.legacy_pathfinder_members
	local function ReplaceMembers(target)
		for key, value in pairs(target) do
			local replacement = replacements[value]
			if replacement then
				members[#members+1] = {target=target,key=key,original=value,wrapper=replacement}
				target[key] = replacement
			end
		end
	end
	ReplaceMembers(g_CObjectFuncs or {})
	for _, class in pairs(g_Classes or {}) do ReplaceMembers(class) end
	Legacy.PatchWasteRockDumpSearch(members)
	Legacy.PatchDroneApproachEstimate(members)
	Legacy.PatchTerraformerRanking(members)
	return true
end

-- ClearWasteRockConstructionSite:GetOutputPile(rover) probes up to 7 rings x every drone
-- destination and asks IsRoverReachable for each dump spot found, without yielding. With native
-- connectivity that is cheap; on an expanded map each probe is a path search, and a site with no
-- reachable dump spot froze the game for seconds every time a rover retried (2026-10-02 save).
-- Make the search incremental on legacy maps only: a spot already proved unreachable for this rover
-- position (and unchanged passability) is skipped, and each call spends at most DUMP_BUDGET_MS on
-- new searches; when the budget runs out the call reports no pile, exactly as when none is found,
-- and the next call continues with the spots not yet tried. No spot is ever reported reachable
-- without a real search, and a reachable spot is still found after a few calls.
local DUMP_BUDGET_MS = 100
local dump_state = setmetatable({}, { __mode = "k" })
local active_dump_search
local DUMP_PATCH_TOKEN = {} -- one per module execution; a hot reload re-wraps the originals
function Legacy.PatchWasteRockDumpSearch(members)
	local classes = rawget(_G, "g_Classes")
	local base = classes and classes.ClearWasteRockConstructionSite
	if not base or type(base.GetOutputPile) ~= "function" or type(base.IsRoverReachable) ~= "function" then
		return false
	end
	-- Idempotent across repeated ApplyModBehavior calls and module hot reloads: always wrap the
	-- true vanilla methods, and replace either the vanilla method or an earlier wrapper.
	local saved = state.legacy_dump_patch
	if saved and saved.token == DUMP_PATCH_TOKEN and base.GetOutputPile == saved.pile then return true end
	local original_pile, original_reach = base.GetOutputPile, base.IsRoverReachable
	if saved and (original_pile == saved.pile or original_pile == saved.original_pile) then
		original_pile, original_reach = saved.original_pile, saved.original_reach
	end
	local previous_pile, previous_reach = saved and saved.pile, saved and saved.reach
	local ticks = rawget(_G, "GetPreciseTicks")
	local function pile(self, rover, ...)
		local map = rover and self:GetMap()
		if not rover or not Legacy.IsMap(map) or type(ticks) ~= "function" or active_dump_search then
			return original_pile(self, rover, ...)
		end
		local rx, ry = rover:GetPos():xy()
		local version = state.legacy_pathfinder_pass_version
		local site = dump_state[self]
		if not site or site.version ~= version or site.rover ~= rover or site.x ~= rx or site.y ~= ry then
			site = { version = version, rover = rover, x = rx, y = ry, failed = {} }
			dump_state[self] = site
		end
		active_dump_search = { site = site, started = ticks(), exhausted = false }
		local ok, result = pcall(original_pile, self, rover, ...)
		local search = active_dump_search
		active_dump_search = nil
		if not ok then error(result, 0) end
		Legacy.dump_budget_exhausted = (Legacy.dump_budget_exhausted or 0) + (search.exhausted and 1 or 0)
		return result
	end
	local function reach(self, map, q, r, rover, ...)
		local search = active_dump_search
		if not search or rover ~= search.site.rover then return original_reach(self, map, q, r, rover, ...) end
		local key = tostring(q) .. ":" .. tostring(r)
		if search.site.failed[key] then return false end
		if ticks() - search.started > DUMP_BUDGET_MS then
			search.exhausted = true
			return false
		end
		local reachable = original_reach(self, map, q, r, rover, ...)
		if not reachable then search.site.failed[key] = true end
		return reachable
	end
	-- Class construction copies methods into descendants; patch every copy of the originals.
	for _, class in pairs(classes) do
		local method = class.GetOutputPile
		if method == original_pile or (previous_pile and method == previous_pile) then
			members[#members + 1] = { target = class, key = "GetOutputPile", original = original_pile, wrapper = pile }
			class.GetOutputPile = pile
		end
		method = class.IsRoverReachable
		if method == original_reach or (previous_reach and method == previous_reach) then
			members[#members + 1] = { target = class, key = "IsRoverReachable", original = original_reach, wrapper = reach }
			class.IsRoverReachable = reach
		end
	end
	state.legacy_dump_patch = { original_pile = original_pile, original_reach = original_reach, pile = pile, reach = reach,
		token = DUMP_PATCH_TOKEN }
	return true
end

-- Drone:TryTaskSwap (1.1) weighs swaps with TaskRequester:GetDroneApproachDist, which vanilla
-- documents as a "coarse" connectivity-grid estimate that "needs no computed path"; flying drones
-- use the plain 2D distance. Every pickup compares the drone with each recent drone of its
-- command center, up to three estimates each, and on an expanded map each estimate was a real path
-- search per work spot (2026-10-04 "United States of Mars": 47% of all game execution). 1180
-- remembered reachability per command center, but at 5x speed passability changes so often that
-- the cache still missed 709 times in two minutes (13% of execution, 360 ms stalls; 2026-10-05).
-- On legacy maps a ground drone's estimate is therefore the 2D distance vanilla uses for flying
-- drones, with no path search, and nil for a target this drone already failed to reach
-- (unreachable_buildings, vanilla's own record). TryTaskSwap also skips targets the other drone
-- failed to reach; a swap that hands over an unreachable target ends in vanilla's failed approach,
-- which records it and frees the task.
local APPROACH_PATCH_TOKEN = {}
function Legacy.PatchDroneApproachEstimate(members)
	local classes = rawget(_G, "g_Classes")
	local base = classes and classes.TaskRequester
	if not base or type(base.GetDroneApproachDist) ~= "function" then return false end
	local saved = state.legacy_approach_patch
	if saved and saved.token == APPROACH_PATCH_TOKEN and base.GetDroneApproachDist == saved.wrapper then return true end
	local original = base.GetDroneApproachDist
	if saved and (original == saved.wrapper or original == saved.original) then original = saved.original end
	local previous = saved and saved.wrapper
	local function estimate(self, drone, ...)
		local map = drone and Resolve(drone)
		if not Legacy.IsMap(map) or not IsValid(self) or not IsValid(drone) or IsKindOf(drone, "FlyingObject") then
			return original(self, drone, ...)
		end
		local unreachable = drone.unreachable_buildings
		if unreachable and unreachable[self] then return nil end
		Legacy.approach_estimates = (Legacy.approach_estimates or 0) + 1
		return drone:GetDist2D(self)
	end
	for _, class in pairs(classes) do
		local method = class.GetDroneApproachDist
		if method == original or (previous and method == previous) then
			members[#members + 1] = { target = class, key = "GetDroneApproachDist", original = original, wrapper = estimate }
			class.GetDroneApproachDist = estimate
		end
	end
	state.legacy_approach_patch = { original = original, wrapper = estimate, token = APPROACH_PATCH_TOKEN }
	return true
end

-- RCTerraformer:PickNearestByConnectivity ranks the 8 nearest candidates (up to 24 probes) with
-- ConnectivityCheckAll: up to 24 path searches on a legacy map (243 ms stalls at 5x on
-- 2026-10-05). Vanilla falls back to the 2D-nearest candidate (objects[1] after its own 2D sort)
-- whenever connectivity gives no answer, and its callers then confirm with HasPath and mark an
-- unreachable target. Use that fallback on legacy maps.
local RANKING_PATCH_TOKEN = {}
function Legacy.PatchTerraformerRanking(members)
	local classes = rawget(_G, "g_Classes")
	local base = classes and classes.RCTerraformer
	if not base or type(base.PickNearestByConnectivity) ~= "function" then return false end
	local saved = state.legacy_ranking_patch
	if saved and saved.token == RANKING_PATCH_TOKEN and base.PickNearestByConnectivity == saved.wrapper then return true end
	local original = base.PickNearestByConnectivity
	if saved and (original == saved.wrapper or original == saved.original) then original = saved.original end
	local previous = saved and saved.wrapper
	local function pick(self, objects, ...)
		if not objects or #objects <= 1 or not Legacy.IsMap(Resolve(self)) then
			return original(self, objects, ...)
		end
		table.sort(objects, function(a, b) return self:GetDist2D(a) < self:GetDist2D(b) end)
		return objects[1]
	end
	for _, class in pairs(classes) do
		local method = class.PickNearestByConnectivity
		if method == original or (previous and method == previous) then
			members[#members + 1] = { target = class, key = "PickNearestByConnectivity", original = original, wrapper = pick }
			class.PickNearestByConnectivity = pick
		end
	end
	state.legacy_ranking_patch = { original = original, wrapper = pick, token = RANKING_PATCH_TOKEN }
	return true
end

function Legacy.RestoreVanillaBehavior()
	-- A still-loaded legacy map must never be exposed to native connectivity.
	for _, map in ipairs(LoadedMaps or {}) do if Legacy.IsMap(map) then return false end end
	for i = #(state.legacy_pathfinder_members or {}), 1, -1 do
		local item = state.legacy_pathfinder_members[i]
		if item.target[item.key] == item.wrapper then item.target[item.key] = item.original end
	end
	state.legacy_pathfinder_members = {}
	for name, hook in pairs(hooks) do
		if name ~= "LoadGame" and name ~= "LoadGameFromMem" then
			if _G[name] == hook.wrapper then _G[name] = hook.original end
			hooks[name] = nil
		end
	end
	return true
end

-- A cold load of a save from the main menu can reach vanilla's OnMsg.LoadGame
-- ConnectivityResume before the LoadGame entry wrapper below has reinstalled the hooks
-- (2026-10-02 "XL map Stutter save": "l_ConnectivityProcessResume: pConnectivity" on both
-- maps). PersistPostLoad runs once the saved maps, and their persisted legacy flag, exist and
-- before Msg("LoadGame"), so install there whenever a loaded map uses the legacy pathfinder.
if SBM.Engine and SBM.Engine.ChainOnMsg then
	SBM.Engine.ChainOnMsg("PersistPostLoad", function()
		for _, map in ipairs(LoadedMaps or {}) do
			if Legacy.IsMap(map) then
				Legacy.ApplyModBehavior()
				return
			end
		end
	end)
end

-- Install before lifecycle.lua creates its sandbox-local entry guards. Queries
-- must be ready BEFORE vanilla's LoadGame handlers resume connectivity, including
-- a cold load directly from the main menu with no expanded session yet active.
for _, name in ipairs({"LoadGame", "LoadGameFromMem"}) do
	InstallGlobal(name, function(original)
		return function(...)
			SBM.LegacyPathfinder.ApplyModBehavior()
			return original(...)
		end
	end)
end
