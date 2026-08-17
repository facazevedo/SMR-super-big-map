-- Standalone engine-geometry stub for exercising the production pass-border module.
-- The dimensions and calibrated property lattice come from the preserved sweep-03
-- probes; no expected box coordinates are supplied to the production derivation.

local module_path = assert(arg[1], "production module path is required")

-- The game runtime preserves integer division, unlike the standalone Lua used by
-- this stub. Bind the four required promotions explicitly and retain the exact
-- live-red arithmetic as a destructive control. Removing any promotion makes
-- this stub fail before the full derivation can be accepted.
local module_file = assert(io.open(module_path, "rb"))
local module_source = assert(module_file:read("*a"))
module_file:close()
local promotion_sites = {
	"(expanded_gw * source_w + 0.0) / desired_w",
	"(expanded_gh * source_h + 0.0) / desired_h",
	"(desired_w + 0.0) / source_w",
	"(desired_h + 0.0) / source_h",
}
local missing_promotions = {}
for i = 1, #promotion_sites do
	if not module_source:find(promotion_sites[i], 1, true) then
		missing_promotions[#missing_promotions + 1] = promotion_sites[i]
	end
end
assert(#missing_promotions == 0,
	"production arithmetic lacks explicit float promotion: " .. table.concat(missing_promotions, "; "))

local function engine_div(numerator, denominator, promoted)
	if promoted then return (numerator + 0.0) / denominator end
	return math.floor(numerator / denominator)
end

local function round_nonnegative(value)
	return math.floor(value + 0.5)
end

local unpromoted_source_gw = round_nonnegative(engine_div(820 * 6144, 8192, false))
local unpromoted_source_gh = round_nonnegative(engine_div(946 * 6144, 8192, false))
local promoted_source_gw = round_nonnegative(engine_div(820 * 6144, 8192, true))
local promoted_source_gh = round_nonnegative(engine_div(946 * 6144, 8192, true))
local unpromoted_scale = engine_div(8192, 6144, false)
local promoted_scale = engine_div(8192, 6144, true)
assert(unpromoted_source_gw == 615 and unpromoted_source_gh == 709,
	"integer-division lattice control no longer reproduces the live red baseline")
assert(promoted_source_gw == 615 and promoted_source_gh == 710,
	"promoted lattice control does not recover the exact source dimensions")
assert(unpromoted_scale == 1 and math.abs(promoted_scale - 4 / 3) < 1e-12,
	"integer-division scale control no longer discriminates promotion")

local globals = {}
globals.const = { HeightTileSize = 100 }
globals.HexToWorld = function(q, r)
	local sx = q + r / 2
	return sx * 1000 + (r % 2) * 500, r * 866
end

SuperBigMap = {
	Config = { STRETCH_VANILLA_EXACT_PASSBORDER = true },
	Engine = {
		Global = function(name) return globals[name] end,
	},
}

local grid = {}
function grid:size() return 820, 946 end

local map = {
	mapdata = {
		PassBorder = 0,
		SuperBigMapOriginalPassBorder = 102400,
	},
	buildable = { z_grid = grid },
	SuperBigMapDesiredWidthTiles = 8192,
	SuperBigMapDesiredHeightTiles = 8192,
	SuperBigMapGeneratorWidthTiles = 6144,
	SuperBigMapGeneratorHeightTiles = 6144,
	SuperBigMapSourceX = 0,
	SuperBigMapSourceY = 0,
}

assert(dofile(module_path) == true, "production module did not load")
local specs, stats = SuperBigMap.PassBorderReplay.Derive(map)
assert(type(specs) == "table" and type(stats) == "table", "derivation failed")
io.write(string.format(
	"stats,boxes=%d,core=%d,fringe=%d,fringe_sites=%d,mapped=%d,border=%d,"
		.. "source_gw=%d,source_gh=%d,expanded_gw=%d,expanded_gh=%d,orientation=%s\n",
	stats.total_boxes, stats.core_boxes, stats.fringe_boxes, stats.fringe_sites,
	stats.mapped_sites, stats.border_sites, stats.source_gw, stats.source_gh,
	stats.expanded_gw, stats.expanded_gh, stats.orientation))
io.write(string.format(
	"idiv_control,promotions=%d,unpromoted_source_gw=%d,unpromoted_source_gh=%d,"
		.. "promoted_source_gw=%d,promoted_source_gh=%d,unpromoted_scale=%.6f,promoted_scale=%.6f\n",
	#promotion_sites, unpromoted_source_gw, unpromoted_source_gh,
	promoted_source_gw, promoted_source_gh, unpromoted_scale, promoted_scale))
for i = 1, #specs do
	local spec = specs[i]
	io.write(string.format("box,id=%d,minx=%d,miny=%d,maxx=%d,maxy=%d,kind=%s\n",
		i, spec[1], spec[2], spec[3], spec[4], tostring(spec.kind)))
end
