-- Super Big Map -- centralized debug logging.
--
-- DebugLog.Info/Warn/Error(scope, message, data) print one line:
--   [Super Big Map] <LEVEL><scope>: <message> {k=v, ...}
-- A line prints when EITHER the master flag SuperBigMap.Config.DEBUG_LOGS is true
-- (turns on every scope), OR the line's own per-scope flag DEBUG_<SCOPE> is true
-- (e.g. scope "Generation" -> DEBUG_GENERATION). This lets you trace a single domain
-- in isolation, or flip everything on at once. Config is read lazily on each call so
-- gating always reflects the live config. ALL mod logging routes through here -- no raw
-- print() in mod-owned modules.
--
-- Scopes in use (each has a matching DEBUG_<SCOPE> flag in sbm_config.lua):
--   Lifecycle, Generation, Sector, SectorSizing, Deposits, RmgPlacement, Seam, Overview,
--   Camera, Rocket, Heat, Bounds, FakeTerrain, Validation, Zoom, ZoomVanilla, RestartNotice,
--   PregameToggle, EditorCamera, InitSeq.

local SuperBigMap = rawget(_G, "SuperBigMap")
if type(SuperBigMap) ~= "table" then
	SuperBigMap = {}
	rawset(_G, "SuperBigMap", SuperBigMap)
end

local PREFIX = "[Super Big Map] "

local function current_config()
	return SuperBigMap.Config or {}
end

-- True when the master flag is on, or this scope's own DEBUG_<SCOPE> flag is on.
local function enabled(scope)
	local cfg = current_config()
	if cfg.DEBUG_LOGS == true then
		return true
	end
	if scope ~= nil and scope ~= "" then
		return cfg["DEBUG_" .. string.upper(tostring(scope))] == true
	end
	return false
end

-- Convert a {key=value} table into a stable, readable string. Values use tostring
-- (safe for engine userdata, which is never indexed here). Keys are sorted for stable
-- output across runs.
local function format_data(data)
	if type(data) ~= "table" then
		return ""
	end
	local keys = {}
	for k in pairs(data) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	local parts = {}
	for i = 1, #keys do
		parts[i] = tostring(keys[i]) .. "=" .. tostring(data[keys[i]])
	end
	if #parts == 0 then
		return ""
	end
	return " {" .. table.concat(parts, ", ") .. "}"
end

local function emit(level, scope, message, data)
	if not enabled(scope) then
		return
	end
	local print_fn = rawget(_G, "print")
	if type(print_fn) ~= "function" then
		return
	end
	print_fn(PREFIX .. level .. tostring(scope) .. ": " .. tostring(message) .. format_data(data))
end

local DebugLog = {}

function DebugLog.Info(scope, message, data)
	emit("", scope, message, data)
end

function DebugLog.Warn(scope, message, data)
	emit("WARN ", scope, message, data)
end

function DebugLog.Error(scope, message, data)
	emit("ERROR ", scope, message, data)
end

-- True when a given scope would print right now. Callers can use this to skip building
-- expensive log data when the scope is off.
function DebugLog.On(scope)
	return enabled(scope)
end

-- Init-sequence trace: the "InitSeq" scope. Kept as named helpers because callers use
-- InitSeqOn() to skip heavy data assembly when the channel is off.
function DebugLog.InitSeqOn()
	return enabled("InitSeq")
end

function DebugLog.InitSeq(message, data)
	if not enabled("InitSeq") then
		return false
	end
	emit("", "InitSeq", message, data)
	return true
end

SuperBigMap.DebugLog = DebugLog
