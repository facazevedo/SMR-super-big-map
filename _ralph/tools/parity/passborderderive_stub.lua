-- Standalone engine-geometry stub for exercising the production pass-border module.
-- The dimensions and calibrated property lattice come from the preserved sweep-03
-- probes; no expected box coordinates are supplied to the production derivation.

local module_path = assert(arg[1], "production module path is required")

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
for i = 1, #specs do
	local spec = specs[i]
	io.write(string.format("box,id=%d,minx=%d,miny=%d,maxx=%d,maxy=%d,kind=%s\n",
		i, spec[1], spec[2], spec[3], spec[4], tostring(spec.kind)))
end
