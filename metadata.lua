return PlaceObj('ModDef', {
	'title', "Bigger Maps",
	'description', "Expands the loaded map's playable construction boundary to the full terrain area.",
	'short_description', "Use the full terrain and experimentally tile random maps 2x2.",
	'id', "BiggerMaps",
	'author', "fredware",
	'version', 1,
	'lua_revision', 350453,
	'saved_with_revision', 380799,
	'code', {
		"Code/bm_config.lua",
		"Code/ZoomPlus.lua",
		"Code/BiggerMaps.lua",
		"Code/bm_quadrant_tiler.lua",
		"Code/bm_sectors.lua",
	},
	'saved', 1780000000,
	'TagGameplay', true,
})
