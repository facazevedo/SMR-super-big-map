-- The seating planner now rounds to the same integer terrain coordinate as
-- MarkNativeAuthored. An authored float's target is its scaled vanilla allowance
-- less one pose-rounding unit, even on a steep terrain cell.
local checks = 0
local function check(ok, message) assert(ok, message); checks = checks + 1 end

-- Terrain: a slope falling 3 units per unit of x distinguishes half-up from
-- the engine point constructor's truncation at x = 10.6.
local heights = function(x, y) return -3 * x end
local points = {}
local globals = {
	IsValid = function(o) return o ~= nil end,
	const = { HeightTileSize = 100 }, guim = 1000,
	point = function(x, y, z)
		-- The engine truncates fractional coordinates.
		local p = { x = math.floor(x), y = math.floor(y) }
		points[#points + 1] = p
		return p
	end,
	terrain = { GetHeight = function(map, p) return heights(p.x, p.y) end },
}
SuperBigMap = { Engine = { Global = function(n) return globals[n] end } }
dofile('Code/sbm_decoration_geometry.lua')
dofile('Code/sbm_decoration_validation.lua')
local V = SuperBigMap.DecorationValidation
check(type(V.NativeAllowedTarget) == "function", "the planner target helper must be exported")

-- One component whose support vertex sits at x = 10.6: truncated height -30, rounded height -33.
-- The record's pose has identity columns, so these are already world points.
local vertices = { { 10.6, 0.2, 100 }, { 10.6, 0.2, 101 }, { 10.6, 1.2, 100 }, { 11.6, 0.2, 100 } }
local component = { bounds = { 10, 0, 100, 12, 2, 101 }, vertices = { 1, 2, 3, 4 },
	triangles = { { 1, 3, 2 }, { 1, 2, 4 }, { 1, 4, 3 }, { 2, 3, 4 } }, closed = true }
local geometry = { vertices = vertices, components = { component } }
local record = { obj = { handle = 1 }, pose = { matrix = { origin = { 0, 0, 0 }, columns = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } } },
	shift = { 0, 0, 0 }, scale = 100 } }
local node = { record = record, key = "piece", geometry = geometry, component = component, native_allowed = 70 }
record.nodes = { node }

local target = V.NativeAllowedTarget({}, record, node)
check(target == 69, "matching planner/verifier samples retain only the pose margin: " .. tostring(target))

-- Flat terrain: both samplings agree and the target is the plain allowance less one.
heights = function(x, y) return 5 end
check(V.NativeAllowedTarget({}, record, node) == 69, "no sampling difference on flat terrain")

-- A rising slope also uses the same target; no gradient-specific adjustment remains.
heights = function(x, y) return 3 * x end
check(V.NativeAllowedTarget({}, record, node) == 69, "a favourable sampling difference must not raise the target")

-- No allowance: no target.
node.native_allowed = nil
check(V.NativeAllowedTarget({}, record, node) == nil, "components without a vanilla allowance have no target")
node.native_allowed = 70

-- This helper does not sample terrain; the planner's vertex query remains the
-- source of terrain evidence and must still reject unavailable terrain.
globals.terrain.GetHeight = function() return nil end
check(V.NativeAllowedTarget({}, record, node) == 69, "target must not invent a terrain witness")

-- Both seating-evidence sites use the helper.
local f = assert(io.open("Code/sbm_decoration_validation.lua", "rb")); local src = f:read("*a"); f:close()
local _, direct = src:gsub("=NativeAllowedTarget%(map,record,node%)", "")
local _, grouped = src:gsub("and NativeAllowedTarget%(map,record,node%)", "")
check(direct == 1 and grouped == 1, "both evidence sites must use the shared target, found " .. direct .. "+" .. grouped)
print("native allowed target: " .. checks .. " checks passed")
