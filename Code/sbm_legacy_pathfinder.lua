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

local function Check(map, source, dest, pfclass, radius, ...)
	-- Public overload: (map, source, x, y, z, pfclass, radius).
	if type(dest) == "number" then
		local passclass, search_radius = ...
		dest, pfclass, radius = point(dest, pfclass, radius), passclass, search_radius
	end
	if type(dest) == "table" and not IsPoint(dest) and not IsValid(dest) then
		local best
		for i = 1, #dest do
			local length = Distance(map, source, dest[i], pfclass, radius)
			if length and (not best or length < best) then best = length end
		end
		return best
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
