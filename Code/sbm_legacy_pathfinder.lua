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

-- Return real path length or nil, never a straight-line guess or a partial path.
-- Connectivity's explicit radius is a passable-endpoint search, not permission
-- to walk through impassable cells. Do not cache: landscaping changes paths.
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
	local reachable, length = pf.PosPathLen(map, from, to, pfclass)
	return reachable and length or nil
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
			if data and data.GameLogic and map
				and (map.SuperBigMapExpansionPending or map.SuperBigMapExpanded
					or map.SuperBigMapLegacyPathfinder)
				and (data.Width or 0) >= 8192 and (data.Height or 0) >= 8192 then
				local shadow = {}
				for key, value in pairs(data) do shadow[key] = value end
				setmetatable(shadow, getmetatable(data))
				shadow.GameLogic = false
				map.SuperBigMapLegacyPathfinder = true
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
