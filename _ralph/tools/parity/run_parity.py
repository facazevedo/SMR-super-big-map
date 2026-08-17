"""Generate the 30S146E vanilla and expanded twins headlessly and dump every object.

Each twin runs in its OWN fresh MarsDebug.exe process so the vanilla control can
never be contaminated by mod state left behind by an expanded run (the failure mode
behind iterations 67-69).  The vanilla underground seed is carried across processes
through a JSON file and injected into the expanded twin with
SuperBigMap.MapGeneration.SetTwinUndergroundSeedForTest.

The vanilla control's own underground seed is a fresh AsyncRand draw, so it is pinned
to REFERENCE_UNDERGROUND_SEED (see below) to keep the underground control identical
across runs; both twins of a pair therefore share one fixed reference underground.

Surface seed parity needs no injection: GetOverlayValues(1800, 8760) sets
g_CurrentMapParams.Seed = xxhash(lat, long), so both twins derive the same surface
seed from the coordinate alone.
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

HARNESS_DIR = Path(r"D:\PROJS\SMR\smr-harness")
sys.path.insert(0, str(HARNESS_DIR))

import dap
import cli

GAME_EXE = r"C:\Games\Surviving Mars Relaunched\MarsDebug.exe"
GAME_DIR = Path(r"C:\Games\Surviving Mars Relaunched")

HERE = Path(__file__).resolve().parent
OUT = HERE / "out"
GEN_TEMPLATE = HERE / "gen_template.lua"
DUMP_TEMPLATE = HERE / "dump_template.lua"
HEXGRID_TEMPLATE = HERE / "hexgrid_template.lua"
SAVE_TEMPLATE = HERE / "save_template.lua"
LOAD_TEMPLATE = HERE / "load_template.lua"

# The stock underground seed is drawn from AsyncRand inside FillRandomMapGen
# (ModTools PreGameMenus.lua:166, because MapData["BlankUnderground_0X"].map_randomizeseed
# is true), so three identical vanilla runs generated three different undergrounds
# (6504 / 6327 / 6560 objects) and no underground gate could be scored across runs.
# Pin the control to one fixed reference underground instead.  The value below is a real
# AsyncRand draw captured from the iteration-001 vanilla twin, which is the underground the
# ratchet baseline in artifacts/best.json was measured on, so pinned runs compare directly
# against it.
REFERENCE_UNDERGROUND_SEED = 6074387974731471656

# Fixed SOURCE cells around the underground Bottomless Pit at 45S82E, chosen offline from the
# iter-022 twin lattices (`out/passrb-t6{b,y}.csv`, picker `_ralph/tmp/.tmp_fzp_pickcells.py`):
# 12 that vanilla blocks and the expanded map does not, 4 passable on both, 4 blocked on both.
# Shared by every pass-input probe so each one interrogates exactly the same ground.
PASS_FORENSIC_CELLS = (
    '{{2983,3017,"diff"}, {2998,3068,"diff"}, {3061,3011,"diff"}, {2881,3029,"diff"}, '
    '{3046,3107,"diff"}, {2851,3008,"diff"}, {2857,3083,"diff"}, {3064,3140,"diff"}, '
    '{2818,3035,"diff"}, {3064,3164,"diff"}, {2815,3092,"diff"}, {3064,3185,"diff"}, '
    '{2980,3014,"free"}, {2881,2993,"free"}, {3004,2873,"free"}, {2986,2840,"free"}, '
    '{2968,2969,"both"}, {2902,2990,"both"}, {3010,2891,"both"}, {3025,2840,"both"}}')

# Vanilla control only: let the stock draw happen (the RNG stream keeps its cardinality,
# exactly as the mod's expanded seam does), then substitute the reference seed for the
# underground map alone.  The surface FillRandomMapGen call is untouched.
UNDERGROUND_PIN_BLOCK = """		do
			local original_fill = FillRandomMapGen
			if type(original_fill) ~= "function" then
				error("FillRandomMapGen unavailable; cannot pin the reference underground")
			end
			g_ParityUndergroundPin = {seed}
			FillRandomMapGen = function(gen, map, params)
				local result = original_fill(gen, map, params)
				local map_data = MapData and MapData[map]
				local environment = map_data and map_data.Environment
				if environment == "Underground"
					or (type(map) == "string" and map:find("Underground", 1, true)) then
					gen.Seed = {seed}
					g_ParityUndergroundPinApplied = true
				end
				return result
			end
		end"""

# Seed of the dedicated passage-fallback stream installed by PASSAGE_PIN_BLOCK.  Any value is
# equally valid (see that block's rationale); this one is fixed forever so every run and both
# twins draw the same sequence.
PASSAGE_FALLBACK_PIN_SEED = 301460102

# Opt-in with the "passagepin" argument.  THE control pin, not a probe.  iter-004 proved the
# 45S82E variant flip is thread interleaving on the shared session stream: 753 SessionRandom
# draws happen during a control run, 752 of them from city threads started by CityStart
# (InitApplicantPool, SurfaceDeposit:Init, rivals, geysers, meteors, vegetation, dust storms),
# and exactly ONE from the map generator's own thread - the second underground passage's
# fallback, Pathfinding.lua:168 <- SurfacePassage.lua:119 <- RandomMapGen_PlaceArtefacts_Passages.
# Whether the generator thread reaches that draw before or after the applicant pool decides which
# value it gets (variant A = draw #11 -> 2067812733 -> site (211000,171468); variant B = draw #738
# -> 228955110 -> site (208500,463310)), and every later session consumer shifts with it, which is
# why SurfaceDeposit rows differ too.  artifacts/draw_probe_verdict.md.
#
# The pin takes that one draw OFF the shared stream: GetRandomPassableAroundOnMap takes a `random`
# parameter and only falls back to SessionRandom when the caller passes none (Pathfinding.lua:163-170),
# and SurfacePassage.lua:119 passes none, so supplying a dedicated fixed-seed GameRandom removes the
# race without touching any other consumer - the remaining 752 draws keep their order among
# themselves because they are issued by the same city threads in the same order.  The resulting
# passage site is a site vanilla itself can produce (the draw is an ordinary GameRandom value fed to
# the stock map:GetRandomPassablePoint), so the control stays a valid vanilla map; what stops being
# valid is only its dependence on thread timing.  Applied symmetrically to BOTH twins, the two sides
# feed the same value to the same stock chooser.
#
# GetRandomPassable (Pathfinding.lua:1-6, reached only when the around-variant returns nothing, and
# never once in the probed runs) draws from city:Random(); it is pinned the same way by reproducing
# its two-line body against the dedicated stream, guarded so any surprise there fails loudly instead
# of silently reintroducing a shared-stream draw.
PASSAGE_PIN_BLOCK = """		do
			if type(GameRandom) ~= "table" or type(GameRandom.new) ~= "function" then
				error("GameRandom unavailable; cannot pin the passage fallback")
			end
			local pin_random = GameRandom:new(nil, __PIN_SEED__)
			if type(pin_random) ~= "table" or type(pin_random.Random) ~= "function" then
				error("could not build the dedicated passage-fallback stream")
			end
			rawset(_G, "g_ParityPassagePin", __PIN_SEED__)
			rawset(_G, "g_ParityPassagePinAround", 0)
			rawset(_G, "g_ParityPassagePinPassable", 0)
			-- iter-007: record every redirected call so both twins' fallback arguments can be
			-- compared.  Pure observation on the pinned path (no traceback, no extra draw), so
			-- the pinned sequence and the dump stay exactly what an unrecorded pinned run gives.
			rawset(_G, "g_ParityPassagePinCalls", {})

			local function pin_point_text(p)
				if p == nil or p == false then return tostring(p) end
				local ok, x, y, z = pcall(function() return p:xyz() end)
				if ok and x then
					return string.format("(%s,%s,%s)", tostring(x), tostring(y), tostring(z))
				end
				return tostring(p)
			end

			local function pin_map_text(map)
				if type(map) ~= "table" then return "map=" .. tostring(map) end
				local size = "?"
				local ok, w, h = pcall(function() return map:GetMapSize() end)
				if ok then size = tostring(w) .. "x" .. tostring(h) end
				local env = map.mapdata and map.mapdata.Environment or "?"
				return string.format("slot=%s env=%s size=%s", tostring(map.slot), tostring(env), size)
			end

			-- iter-008: on an expanded twin the mod presents the SOURCE extent to vanilla's default
			-- radius expression (config PairingSourceFallbackRadius) for exactly this call.  Record
			-- its state and the live global's identity so a wrong radius says WHICH link failed:
			-- mod_radius=nil = the mod block never ran, mod_calls=0 = its GetMapSize shadow was
			-- never consulted, and around_global ~= pin = something replaced the global after the
			-- pin was installed.
			local function pin_mod_text(map)
				if type(map) ~= "table" then return "mod_radius=?" end
				return string.format("mod_radius=%s mod_calls=%s",
					tostring(rawget(map, "SuperBigMapPassageFallbackRadius")),
					tostring(rawget(map, "SuperBigMapPassageFallbackRadiusCalls")))
			end

			local function pin_cursor()
				local ok, last = pcall(function() return pin_random.rand_state:Last() end)
				if ok then return tostring(last) end
				return "?"
			end

			local pin_around_wrapper
			local function pin_record(kind, map, center, max_radius, min_radius, filter,
					cursor_before, result)
				local calls = rawget(_G, "g_ParityPassagePinCalls")
				if type(calls) ~= "table" or #calls >= 64 then return end
				calls[#calls + 1] = string.format(
					"#%02d %s status=%s %s center=%s max_radius=%s min_radius=%s filter=%s "
					.. "cursor=%s->%s -> %s %s around_global=%s pin=%s",
					#calls + 1, kind, tostring(rawget(_G, "g_ParityStatus")), pin_map_text(map),
					pin_point_text(center), tostring(max_radius), tostring(min_radius),
					type(filter), cursor_before, pin_cursor(), pin_point_text(result),
					pin_mod_text(map), tostring(rawget(_G, "GetRandomPassableAroundOnMap")),
					tostring(pin_around_wrapper))
			end

			local original_around = rawget(_G, "GetRandomPassableAroundOnMap")
			if type(original_around) ~= "function" then
				error("GetRandomPassableAroundOnMap unavailable; cannot pin the passage fallback")
			end
			-- Signature per Lua/Pathfinding.lua:163.  Only the caller-supplied-nothing case is
			-- redirected; a caller with its own stream (map generator rand, city rand) is untouched.
			pin_around_wrapper = function(map, center, max_radius, min_radius, random, filter, ...)
				if random ~= nil then
					return original_around(map, center, max_radius, min_radius, random, filter, ...)
				end
				g_ParityPassagePinAround = g_ParityPassagePinAround + 1
				local cursor_before = pin_cursor()
				local result = original_around(map, center, max_radius, min_radius, pin_random,
					filter, ...)
				pin_record("around", map, center, max_radius, min_radius, filter, cursor_before,
					result)
				return result
			end
			_G.GetRandomPassableAroundOnMap = pin_around_wrapper

			local original_passable = rawget(_G, "GetRandomPassable")
			if type(original_passable) ~= "function" then
				error("GetRandomPassable unavailable; cannot pin the passage fallback")
			end
			_G.GetRandomPassable = function(map)
				if type(map) == "table" and type(map.GetRandomPassablePoint) == "function" then
					g_ParityPassagePinPassable = g_ParityPassagePinPassable + 1
					return map:GetRandomPassablePoint(pin_random:Random())
				end
				error("passage pin: GetRandomPassable called with an unusable map")
			end
		end"""

# Opt-in with the "pointprobe" argument.  iter-008 left one defect at 45S82E: with the IDENTICAL
# center (180500,298770), the IDENTICAL resolved radius (307200, after the mod's GetMapSize shadow)
# and the IDENTICAL pinned seed (777998755), map:GetRandomPassablePoint returns (283625,152875) on
# the 614400 control and (239275,266625) on the 819200 expanded map.  That leaves two possibilities:
# the native chooser indexes the same passable set differently because it is bound to the map's real
# extent (=> only retaining the native surface map through passage selection can fix it), or the two
# maps' passability fields simply differ inside the source square and some seeds still agree
# (=> a much cheaper passability-side alignment exists).
#
# This block decides it in ONE run per twin.  It wraps the global AFTER the passage pin installed
# its wrapper, and on the same caller-less redirected call it sweeps a fixed seed list through
# map:GetRandomPassablePoint with the radius vanilla itself would resolve (Pathfinding.lua:165),
# recording each seed's point.  It draws from no stream, passes explicit seeds, and calls through
# to the pinned wrapper unchanged, so a probed run's dump must stay byte-identical to an unprobed
# pinned one - which is the inertness check.  PROBE_POINT_SEEDS[1] is the real pinned seed, so the
# probe reproduces the recorded call and proves itself before any new seed is believed.
PROBE_POINT_SEEDS = [
    777998755, 1, 2, 3, 7, 42, 1000, 65537,
    123456789, 314159265, 271828182, 161803398, 141421356, 236067977,
    500000000, 999999999,
]

POINT_PROBE_BLOCK = """		do
			local probe_seeds = {__PROBE_SEEDS__}
			g_ParityPointProbe = {}
			g_ParityPointProbeCalls = 0

			local function probe_point_text(p)
				if p == nil or p == false then return tostring(p) end
				local ok, x, y = pcall(function() return p:xyz() end)
				if ok and x then return string.format("(%s,%s)", tostring(x), tostring(y)) end
				return tostring(p)
			end

			local probe_original = rawget(_G, "GetRandomPassableAroundOnMap")
			if type(probe_original) ~= "function" then
				error("GetRandomPassableAroundOnMap unavailable; cannot probe the point chooser")
			end
			_G.GetRandomPassableAroundOnMap = function(map, center, max_radius, min_radius, random,
					filter, ...)
				local records = rawget(_G, "g_ParityPointProbe")
				if random == nil and type(map) == "table" and type(records) == "table"
					and #records < 400
					and type(map.GetRandomPassablePoint) == "function" then
					g_ParityPointProbeCalls = (rawget(_G, "g_ParityPointProbeCalls") or 0) + 1
					-- Exactly the expression Pathfinding.lua:165 uses, evaluated at the same
					-- moment, so the expanded twin sees whatever the mod's shadow presents.
					local resolved_max = max_radius or Max(map:GetMapSize()) / 2
					local resolved_min = min_radius or 0
					local w, h = map:GetMapSize()
					records[#records + 1] = string.format(
						"call#%02d status=%s size=%sx%s center=%s max_radius=%s min_radius=%s",
						rawget(_G, "g_ParityPointProbeCalls"),
						tostring(rawget(_G, "g_ParityStatus")), tostring(w), tostring(h),
						probe_point_text(center), tostring(resolved_max), tostring(resolved_min))
					for i = 1, #probe_seeds do
						local seed = probe_seeds[i]
						local ok, pt = pcall(function()
							return map:GetRandomPassablePoint(center, resolved_max, resolved_min,
								seed, 0)
						end)
						records[#records + 1] = string.format("  call#%02d seed=%s -> %s",
							rawget(_G, "g_ParityPointProbeCalls"), tostring(seed),
							ok and probe_point_text(pt) or ("ERROR " .. tostring(pt)))
					end
				end
				return probe_original(map, center, max_radius, min_radius, random, filter, ...)
			end
		end"""

# Opt-in with the "fieldprobe" argument.  iter-010 proved 0 of 16 seeds agree between the twins
# at the identical fallback call, but could not say WHY: either the two maps' passability fields
# differ inside the retained source square (the disc around (180500,298770) with radius 307200 lies
# entirely inside it on BOTH maps, so a differing passable set is a real candidate and would have a
# cheap fix - bridge passability the way the buildable grid is already bridged), or the native
# chooser indexes an identical set differently because it is bound to the map's real extent (=>
# only retaining the native surface map through passage selection can fix it).
#
# This block separates those two in ONE run per twin, all read-only:
#   (1) map:GetPassablePointNearby(center, 0, max, min) - the seedless, deterministic sibling of
#       the chooser.  Same answer on both twins => the disc geometry and the local passable set
#       agree and only the random indexing is extent-bound.
#   (2) a radius sweep at fixed seeds: if small radii agree and large ones do not, the divergence
#       scales with the searched set, not with the local field.
#   (3) map:IsPassable at every point BOTH twins returned in iter-010: if the control's point is
#       impassable on the expanded map, the field differs and that alone explains the miss.
#   (4) a coarse passability census over the source square (per-row counts), which localizes any
#       field difference instead of merely detecting it.
# It draws from no stream and calls through unchanged, so a probed dump must stay byte-identical
# to its unprobed pinned sibling - the inertness check.
PROBE_FIELD_POINTS = [
    # Control k13's sweep (artifacts/pointprobe-k13.log); "kr" is the real pinned seed's point.
    (283625, 152875, "kr"), (168925, 446025, "k1"), (169525, 446025, "k2"),
    (170125, 446025, "k3"), (173625, 446025, "k7"), (212025, 446025, "k42"),
    (169325, 446025, "k1000"), (238875, 446025, "k65537"), (174775, 110425, "k123456789"),
    (224575, 400425, "k314159265"), (137125, 463675, "k271828182"),
    (245075, 456525, "k161803398"), (420225, 455175, "k141421356"),
    (364375, 461325, "k236067977"), (395625, 134825, "k500000000"),
    (303425, 167275, "k999999999"),
    # Expanded e07's first-call sweep (artifacts/pointprobe-e07.log); "er" is its real-seed point.
    (239275, 266625, "er"), (259825, 277575, "e1"), (260425, 277575, "e2"),
    (261025, 277575, "e3"), (264525, 277575, "e7"), (302925, 277575, "e42"),
    (260225, 277575, "e1000"), (329775, 277575, "e65537"), (344525, 233075, "e123456789"),
    (350125, 293675, "e314159265"), (174325, 291525, "e271828182"),
    (292975, 285875, "e161803398"), (306425, 284825, "e141421356"),
    (336875, 289675, "e236067977"), (107175, 201525, "e500000000"),
    (417725, 328825, "e999999999"),
]
PROBE_FIELD_RADII = [307200, 153600, 76800, 38400, 19200, 9600, 4800]
PROBE_FIELD_RADIUS_SEEDS = [777998755, 1, 42]
# 128x128 = 16384 native passability queries over the 614400 source square, cheap enough to run
# inside the synchronous selection window with loop detection paused.
PROBE_FIELD_LATTICE_STEP = 4800
PROBE_FIELD_LATTICE_SPAN = 614400

FIELD_PROBE_BLOCK = """		do
			local field_points = {__FIELD_POINTS__}
			local field_radii = {__FIELD_RADII__}
			local field_seeds = {__FIELD_RADIUS_SEEDS__}
			local lattice_step, lattice_span = __FIELD_STEP__, __FIELD_SPAN__
			g_ParityFieldProbe = {}
			g_ParityFieldProbeCalls = 0

			local function field_point_text(p)
				if p == nil or p == false then return tostring(p) end
				local ok, x, y = pcall(function() return p:xyz() end)
				if ok and x then return string.format("(%s,%s)", tostring(x), tostring(y)) end
				return tostring(p)
			end

			local field_original = rawget(_G, "GetRandomPassableAroundOnMap")
			if type(field_original) ~= "function" then
				error("GetRandomPassableAroundOnMap unavailable; cannot probe the passability field")
			end
			_G.GetRandomPassableAroundOnMap = function(map, center, max_radius, min_radius, random,
					filter, ...)
				local records = rawget(_G, "g_ParityFieldProbe")
				if random == nil and type(map) == "table" and type(records) == "table"
					and (rawget(_G, "g_ParityFieldProbeCalls") or 0) < 2
					and type(map.GetRandomPassablePoint) == "function" then
					g_ParityFieldProbeCalls = (rawget(_G, "g_ParityFieldProbeCalls") or 0) + 1
					local call_no = rawget(_G, "g_ParityFieldProbeCalls")
					-- Exactly the expression Pathfinding.lua:165 uses, evaluated at the same
					-- moment, so the expanded twin sees whatever the mod's shadow presents.
					local resolved_max = max_radius or Max(map:GetMapSize()) / 2
					local resolved_min = min_radius or 0
					local w, h = map:GetMapSize()
					local function record(...)
						records[#records + 1] = string.format(...)
					end
					record("call#%02d status=%s size=%sx%s center=%s max_radius=%s min_radius=%s "
						.. "pass_version=%s", call_no, tostring(rawget(_G, "g_ParityStatus")),
						tostring(w), tostring(h), field_point_text(center), tostring(resolved_max),
						tostring(resolved_min), tostring(rawget(map, "PassVersion")))
					local ok_near, nearby = pcall(function()
						return map:GetPassablePointNearby(center, 0, resolved_max, resolved_min)
					end)
					record("  call#%02d nearby -> %s", call_no,
						ok_near and field_point_text(nearby) or ("ERROR " .. tostring(nearby)))
					for i = 1, #field_radii do
						for j = 1, #field_seeds do
							local radius, seed = field_radii[i], field_seeds[j]
							local ok_pt, pt = pcall(function()
								return map:GetRandomPassablePoint(center, radius, resolved_min,
									seed, 0)
							end)
							record("  call#%02d radius=%s seed=%s -> %s", call_no, tostring(radius),
								tostring(seed), ok_pt and field_point_text(pt)
								or ("ERROR " .. tostring(pt)))
						end
					end
					for i = 1, #field_points do
						local entry = field_points[i]
						local ok_pass, passable = pcall(function()
							return map:IsPassable(point(entry[1], entry[2]))
						end)
						record("  call#%02d ispassable %s (%s,%s) -> %s", call_no,
							tostring(entry[3]), tostring(entry[1]), tostring(entry[2]),
							ok_pass and tostring(passable and true or false)
							or ("ERROR " .. tostring(passable)))
					end
					local pause_ild = rawget(_G, "PauseInfiniteLoopDetection")
					local resume_ild = rawget(_G, "ResumeInfiniteLoopDetection")
					if type(pause_ild) == "function" then pcall(pause_ild, "SBMParityFieldProbe") end
					local total, rows = 0, {}
					local ok_lattice, lattice_err = pcall(function()
						for y = 0, lattice_span - 1, lattice_step do
							local row = 0
							for x = 0, lattice_span - 1, lattice_step do
								if map:IsPassable(point(x, y)) then row = row + 1 end
							end
							rows[#rows + 1] = row
							total = total + row
						end
					end)
					if type(resume_ild) == "function" then
						pcall(resume_ild, "SBMParityFieldProbe")
					end
					record("  call#%02d lattice step=%s span=%s ok=%s rows=%s total=%s%s", call_no,
						tostring(lattice_step), tostring(lattice_span), tostring(ok_lattice),
						tostring(#rows), tostring(total),
						ok_lattice and "" or (" ERROR " .. tostring(lattice_err)))
					local chunk, chunk_first = {}, 1
					for i = 1, #rows do
						chunk[#chunk + 1] = tostring(rows[i])
						if #chunk == 32 or i == #rows then
							record("  call#%02d latticerow %03d %s", call_no, chunk_first,
								table.concat(chunk, ","))
							chunk, chunk_first = {}, i + 1
						end
					end
				end
				return field_original(map, center, max_radius, min_radius, random, filter, ...)
			end
		end"""

# Opt-in with the "slotprobe" argument.  iter-011 proved the defect is the passable SET: the
# expanded surface map's own native pathfinding field answers the fallback in source coordinates.
# The named fix (route 2) is to ask the question on a map whose passable set IS the native source's
# - i.e. keep the temporary source surface map loaded through the passage bootstrap and shadow
# GetRandomPassablePoint on the surface-map INSTANCE to delegate to it.  Two facts must hold for
# that to be writable, and neither has been measured:
#   (A) SLOT LIFETIME - a map slot must be available to hold the retained source map at the moment
#       of the fallback call.  The source unload (sbm_map_generation.lua ~4907) is documented as
#       "keeps the slot available for the vanilla additional-map/underground phase", so the count
#       of slots and their occupancy at the fallback decide whether retention needs to fight the
#       underground phase for a slot or can simply use another one.
#   (B) INSTANCE HONOURING - the native chooser must answer for the map instance it is called on,
#       not for the current map.  map.lua binds these as raw native functions taking the map as
#       first argument (`IsPassable = terrain.IsPassable`, and LuaExportedDocs/Game/realm.lua:57
#       documents `GetPassablePointNearby(map, ...)`), and Map:Init stores `self[true] = self.slot`
#       for the native side, which is static evidence but not proof.
# This block measures both, read-only, in ONE run: it records config.MapSlots, the current slot,
# and every occupied/free slot with its environment and extent, then asks EVERY other loaded map
# the identical passability questions the fallback asks (IsPassable at the center, the seedless
# GetPassablePointNearby, and the chooser at fixed seeds) side by side with the call's own map.
# Different answers from a co-loaded map prove (B) - the query follows the instance - and identical
# answers would kill route 2 outright.  It draws from no stream and calls through unchanged, so a
# probed dump must stay byte-identical to its unprobed pinned sibling (the inertness check).
SLOT_PROBE_SEEDS = [777998755, 1, 42]

SLOT_PROBE_BLOCK = """		do
			local slot_seeds = {__SLOT_SEEDS__}
			g_ParitySlotProbe = {}
			g_ParitySlotProbeCalls = 0

			local function slot_point_text(p)
				if p == nil or p == false then return tostring(p) end
				local ok, x, y = pcall(function() return p:xyz() end)
				if ok and x then return string.format("(%s,%s)", tostring(x), tostring(y)) end
				return tostring(p)
			end

			local function slot_call(fn)
				local ok, value = pcall(fn)
				if not ok then return "ERROR " .. tostring(value) end
				return slot_point_text(value)
			end

			local slot_original = rawget(_G, "GetRandomPassableAroundOnMap")
			if type(slot_original) ~= "function" then
				error("GetRandomPassableAroundOnMap unavailable; cannot probe the map slots")
			end
			_G.GetRandomPassableAroundOnMap = function(map, center, max_radius, min_radius, random,
					filter, ...)
				local records = rawget(_G, "g_ParitySlotProbe")
				if random == nil and type(map) == "table" and type(records) == "table"
					and (rawget(_G, "g_ParitySlotProbeCalls") or 0) < 2
					and type(map.GetRandomPassablePoint) == "function" then
					g_ParitySlotProbeCalls = (rawget(_G, "g_ParitySlotProbeCalls") or 0) + 1
					local call_no = rawget(_G, "g_ParitySlotProbeCalls")
					local function record(...)
						records[#records + 1] = string.format(...)
					end
					-- Exactly the expression Pathfinding.lua:165 uses, so the radius is the one the
					-- real call will resolve (on an expanded twin: the mod's source-extent shadow).
					local resolved_max = max_radius or Max(map:GetMapSize()) / 2
					local resolved_min = min_radius or 0
					local maps = rawget(_G, "Maps")
					local cfg = rawget(_G, "config")
					local max_slots = type(cfg) == "table" and cfg.MapSlots or nil
					local get_current = rawget(_G, "GetCurrentMapSlot")
					local current_slot = "?"
					if type(get_current) == "function" then
						local ok_slot, slot_value = pcall(get_current)
						if ok_slot then current_slot = tostring(slot_value) end
					end
					record("call#%02d status=%s call_map_slot=%s map_slots=%s current_slot=%s "
						.. "current_is_call_map=%s main_is_call_map=%s center=%s max_radius=%s "
						.. "min_radius=%s", call_no, tostring(rawget(_G, "g_ParityStatus")),
						tostring(map.slot), tostring(max_slots), current_slot,
						tostring(rawget(_G, "CurrentMap") == map),
						tostring(rawget(_G, "MainMap") == map), slot_point_text(center),
						tostring(resolved_max), tostring(resolved_min))
					record("  call#%02d modstate radius=%s radius_calls=%s pending_buildable=%s "
						.. "gen_world=%s gen_tiles=%s", call_no,
						tostring(rawget(map, "SuperBigMapPassageFallbackRadius")),
						tostring(rawget(map, "SuperBigMapPassageFallbackRadiusCalls")),
						type(rawget(map, "SuperBigMapPendingNativeSurfacePassageBuildable")),
						tostring(rawget(map, "SuperBigMapGeneratorWidth")),
						tostring(rawget(map, "SuperBigMapGeneratorWidthTiles")))
					local others, free = {}, {}
					local slot_limit = tonumber(max_slots) or 16
					for slot = 1, slot_limit do
						local m = type(maps) == "table" and maps[slot] or nil
						if m == nil then
							free[#free + 1] = tostring(slot)
						else
							local size = "?"
							local ok_size, w, h = pcall(function() return m:GetMapSize() end)
							if ok_size then size = tostring(w) .. "x" .. tostring(h) end
							local md = type(m) == "table" and m.mapdata or nil
							record("  call#%02d slot%02d map=%s env=%s size=%s mapdata=%sx%s "
								.. "changing=%s is_call_map=%s", call_no, slot,
								tostring(type(m) == "table" and m.name or m),
								tostring(md and md.Environment), size,
								tostring(md and md.Width), tostring(md and md.Height),
								tostring(type(m) == "table" and m.changing), tostring(m == map))
							if m ~= map then others[#others + 1] = { slot, m } end
						end
					end
					record("  call#%02d free_slots=%s others=%s", call_no,
						#free > 0 and table.concat(free, ",") or "none", tostring(#others))
					-- (B): the identical questions on the call's map and on every co-loaded map.
					local function ask(label, m)
						record("  call#%02d %s ispassable_center=%s nearby=%s", call_no, label,
							slot_call(function() return m:IsPassable(center) and true or false end),
							slot_call(function()
								return m:GetPassablePointNearby(center, 0, resolved_max, resolved_min)
							end))
						for i = 1, #slot_seeds do
							local seed = slot_seeds[i]
							record("  call#%02d %s seed=%s -> %s", call_no, label, tostring(seed),
								slot_call(function()
									return m:GetRandomPassablePoint(center, resolved_max,
										resolved_min, seed, 0)
								end))
						end
					end
					ask(string.format("callmap(slot=%s)", tostring(map.slot)), map)
					for i = 1, #others do
						local slot, m = others[i][1], others[i][2]
						ask(string.format("other(slot=%s)", tostring(slot)), m)
					end
				end
				return slot_original(map, center, max_radius, min_radius, random, filter, ...)
			end
		end"""

TWIN_SEED_BLOCK = """		if type(SBM.MapGeneration) == "table"
			and type(SBM.MapGeneration.SetTwinUndergroundSeedForTest) == "function" then
			local applied, why = SBM.MapGeneration.SetTwinUndergroundSeedForTest(
				{seed}, "parity_30S146E_fresh_vanilla_twin")
			if not applied then
				error("twin underground seed rejected: " .. tostring(why))
			end
		else
			error("SetTwinUndergroundSeedForTest unavailable")
		end"""


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def spawn_game(tag):
    OUT.mkdir(parents=True, exist_ok=True)
    log_path = OUT / f"game-{tag}.log"
    lf = open(log_path, "wb")
    cmdline = [GAME_EXE, "-nointro", "-no_interactive_asserts", "-stdout", "-hidden"]
    proc = subprocess.Popen(
        cmdline, cwd=str(GAME_DIR), stdout=lf, stderr=subprocess.STDOUT,
        stdin=subprocess.DEVNULL,
    )
    log(f"spawned MarsDebug.exe pid={proc.pid} ({tag}), log -> {log_path}")
    return proc, lf


def poll_status(client, var, done_values, error_values, max_wait, label):
    """Poll a Lua status global until it reaches a terminal value."""
    start = time.time()
    last = None
    while time.time() - start < max_wait:
        try:
            err, val = cli.marshal_value(client, var, timeout=60.0)
            if err:
                log(f"  {label}: marshal error {err[2] if len(err) > 2 else err}")
            else:
                if val != last:
                    log(f"  {label}: {val}  (+{int(time.time() - start)}s)")
                    last = val
                if val in done_values:
                    return val
                if val in error_values:
                    return val
        except dap.DapTimeout:
            log(f"  {label}: engine busy (+{int(time.time() - start)}s)")
        except dap.DapClosed as e:
            raise RuntimeError(f"{label}: game process died: {e}")
        time.sleep(4)
    raise RuntimeError(f"{label}: timed out after {max_wait}s (last status {last!r})")


PLACE_PROBE_BLOCK = """		-- Trace every deposit placement with a traceback (parity forensics; harness-only).
		g_ParityPlaceLog = {}
		do
			local dm = rawget(_G, "DepositMarker")
			local base = dm and dm.PlaceDeposit
			if type(base) == "function" then
				dm.PlaceDeposit = function(self, depth, spawn_pos, ...)
					local ok_pos, px, py = pcall(self.GetVisualPosXYZ, self)
					g_ParityPlaceLog[#g_ParityPlaceLog + 1] = {
						class = tostring(self.class),
						x = ok_pos and px or -1, y = ok_pos and py or -1,
						src_x = tostring(rawget(self, "SuperBigMapNativeSourceX")),
						src_y = tostring(rawget(self, "SuperBigMapNativeSourceY")),
						trace = tostring(debug and debug.traceback and debug.traceback("", 2) or "?"),
					}
					return base(self, depth, spawn_pos, ...)
				end
			end
		end"""


# Opt-in with the "tagorder" argument.  THE second control pin, not a probe (see `passagepin`).
# Iteration 009's playprobe NAMED b2-01's control race: the only difference between two otherwise
# identical vanilla processes inside `Proc_FindPrefabPos_Playable` is the ORDER of adjacent calls
# whose grid arguments are the same set - `pairs(prefab.group_tags)` walking a string-keyed set,
# and Lua seeding its string hash per process.  `similar_apply`
# (Lua/RandomMap/RandomMapGenerator.lua:1390-1401) folds one `similar_grids[tag]` per tag into ONE
# destination with integer `GridMulDivAdd`, and integer rounding does not commute, so two processes
# compose DIFFERENT candidate grids from identical inputs and `grand` picks a different prefab
# position.  `Proc_FindPrefabPos_Border` never calls `similar_apply`, which is exactly why
# iteration 008's boundary #0004 agreed and #0005 diverged.
# artifacts/b201_tagorder_verdict.md.
#
# The pin replaces the process-dependent order with the CANONICAL (sorted) one, which every process
# can derive identically - so unlike a captured value this needs no capture/inject channel; the same
# canonicalization installed on both twins makes them agree by construction.  `similar_apply` is a
# local closure and cannot be patched, so the seam is the global `pairs`: the block snapshots every
# `group_tags` table reachable from `PrefabMarkers`, and `pairs` returns a sorted stateless iterator
# for EXACTLY those tables while forwarding every other call to the original.  A sorted walk is an
# order vanilla itself can produce, so the control stays a valid vanilla map; what stops being valid
# is only its dependence on this process's string-hash seed.
#
# Written into the generator's own lookup path as well as `_G` (same caution as the raster pin: a
# private function environment would make a `_G`-only write verify and do nothing), and the runtime
# hit counter is read back after the run so a silently inert pin fails loudly instead of producing a
# control that merely looks pinned.  The wrapper is deliberately NEVER uninstalled: restoring it at
# some point during the run would itself be a timing-dependent input.
TAG_ORDER_PIN_BLOCK = """		do
			local orig_pairs = rawget(_G, "pairs")
			local orig_next = rawget(_G, "next")
			if type(orig_pairs) ~= "function" or type(orig_next) ~= "function" then
				error("pairs/next unavailable; cannot canonicalize prefab group-tag order")
			end
			local canon = {}
			local hits = 0
			g_ParityTagOrderPin = "installing"
			g_ParityTagOrderTables = 0
			g_ParityTagOrderMulti = 0
			g_ParityTagOrderRefresh = 0
			g_ParityTagOrderHits = 0
			g_ParityTagOrderEnvs = 0

			-- Total order over keys of any type, so table.sort can never see an inconsistent
			-- comparator (tags are strings; the rest is belt and braces).
			local function key_less(a, b)
				local ta, tb = type(a), type(b)
				if ta ~= tb then return ta < tb end
				if ta == "number" or ta == "string" then return a < b end
				return tostring(a) < tostring(b)
			end

			-- Stateless iterator with the same contract as `next`: (table, control) -> k, v.
			local function canon_next(t, k)
				local e = canon[t]
				if e == nil then return orig_next(t, k) end
				local nk
				if k == nil then nk = e.first else nk = e.nxt[k] end
				if nk == nil then return nil end
				return nk, t[nk]
			end

			local pairs_wrapper = function(t, ...)
				if canon[t] ~= nil then
					hits = hits + 1
					return canon_next, t, nil
				end
				return orig_pairs(t, ...)
			end

			-- Snapshot the tag sets.  Rebuilt from scratch on every refresh so a prefab list
			-- reloaded between maps cannot leave a stale order behind.
			local function refresh(reason)
				local list = rawget(_G, "PrefabMarkers")
				if type(list) ~= "table" then
					g_ParityTagOrderPin = "no PrefabMarkers at " .. tostring(reason)
					return
				end
				local fresh, tables, multi = {}, 0, 0
				for i = 1, #list do
					local m = list[i]
					local gt = type(m) == "table" and rawget(m, "group_tags") or nil
					if type(gt) == "table" and fresh[gt] == nil then
						local keys = {}
						for key in orig_next, gt do keys[#keys + 1] = key end
						table.sort(keys, key_less)
						local nxt = {}
						for j = 1, #keys - 1 do nxt[keys[j]] = keys[j + 1] end
						fresh[gt] = {first = keys[1], nxt = nxt}
						tables = tables + 1
						if #keys >= 2 then multi = multi + 1 end
					end
				end
				canon = fresh
				g_ParityTagOrderTables = tables
				g_ParityTagOrderMulti = multi
				g_ParityTagOrderRefresh = (rawget(_G, "g_ParityTagOrderRefresh") or 0) + 1
				g_ParityTagOrderPin = "installed"
			end

			-- Install on every table the generator's own name lookup can reach.
			local gen_class = rawget(_G, "RandomMapGenerator")
			local body = gen_class and gen_class.DoGenerate
			local envs, seen = {}, {}
			local function add(t)
				if type(t) == "table" and not seen[t] then seen[t] = true; envs[#envs + 1] = t end
			end
			add(rawget(_G, "_G"))
			add(_G)
			if type(body) == "function" and type(getfenv) == "function" then
				local ok_env, env = pcall(getfenv, body)
				if ok_env and type(env) == "table" then
					add(env)
					local mt = getmetatable(env)
					local idx = mt and rawget(mt, "__index")
					if type(idx) == "table" then add(idx) end
				end
			end
			for i = 1, #envs do envs[i].pairs = pairs_wrapper end
			g_ParityTagOrderEnvs = #envs

			-- Verify through the generator's own lookup path, not ours.
			if type(body) == "function" and type(getfenv) == "function" then
				local ok_env, env = pcall(getfenv, body)
				if ok_env and type(env) == "table" then
					local ok_p, p = pcall(function() return env.pairs end)
					if not ok_p or p ~= pairs_wrapper then
						error("group-tag order pin did not reach the generator's own environment")
					end
				end
			end
			if rawget(_G, "pairs") ~= pairs_wrapper then
				error("group-tag order pin not installed on _G")
			end

			refresh("install")

			-- The prefab list is loaded from assets, so re-snapshot at each map's generation
			-- entry point (class-method shadow: engine callers see it, per the fxprobe result).
			if type(body) == "function" then
				gen_class.DoGenerate = function(self, map, ...)
					refresh("dogenerate")
					local a, b, c = body(self, map, ...)
					-- Published per map so the counter is final before the dump is scored.
					g_ParityTagOrderHits = hits
					return a, b, c
				end
			end
		end"""


SERIAL_RASTER_BLOCK = """		-- Serialize stock prefab rasterization for this control.
		--
		-- The value MUST be written into the table the generator's own compiled body reads.
		-- RandomMapGenerator.DoGenerate owns a private _ENV, so the ambient `const` visible to
		-- this script can be a DIFFERENT table: writing there succeeds, verifies, and has no
		-- effect on generation. The mod hit exactly this and fixed it by resolving `const`
		-- through the DoGenerate closure environment (sbm_map_generation.lua:9719-9722,
		-- commit 3520c72). Do the same here, and FAIL LOUDLY if the generator's own view does
		-- not read 1 afterwards - a control that silently stayed parallel is worse than none.
		do
			local gen_class = rawget(_G, "RandomMapGenerator")
			local body = gen_class and gen_class.DoGenerate
			local getfenv_fn = rawget(_G, "getfenv")
			local envs, seen = {}, {}
			local function add(t)
				if type(t) == "table" and not seen[t] then seen[t] = true; envs[#envs + 1] = t end
			end
			if type(body) == "function" and type(getfenv_fn) == "function" then
				local ok_env, env = pcall(getfenv_fn, body)
				if ok_env and type(env) == "table" then
					add(rawget(env, "const"))
					local mt = getmetatable(env)
					local idx = mt and rawget(mt, "__index")
					if type(idx) == "table" then add(rawget(idx, "const")) end
				end
			end
			add(rawget(_G, "const"))
			if #envs == 0 then error("no const table reachable to serialize prefab rasterization") end
			rawset(_G, "g_ParityRasterTables", #envs)
			rawset(_G, "g_ParityRasterDivBefore", envs[1].PrefabRasterParallelDiv)
			for i = 1, #envs do envs[i].PrefabRasterParallelDiv = 1 end
			-- Verify through the generator's own lookup path, not ours.
			local check
			if type(body) == "function" and type(getfenv_fn) == "function" then
				local ok_env, env = pcall(getfenv_fn, body)
				if ok_env and type(env) == "table" then
					local ok_c, c = pcall(function() return env.const end)
					if ok_c and type(c) == "table" then check = c.PrefabRasterParallelDiv end
				end
			end
			check = check or (rawget(_G, "const") or {}).PrefabRasterParallelDiv
			rawset(_G, "g_ParityRasterDivAfter", check)
			if check ~= 1 then
				error("prefab rasterization not serialized in the generator's own environment: "
					.. tostring(check))
			end
		end"""


# Diagnostic only, opt-in with the "entranceaudit" argument.  Turns on the mod's own gated
# elevator audit channel (sbm_diagnostics.lua: DEBUG_LOGGING_ENABLED + DEBUG_ELEVATOR_SUPPLY)
# so the passage planner's PASSAGE_PLAN_* records reach the game log.  It only flips two
# config booleans that gate print() calls - no wrapper, no object touched, no RNG consumed -
# so the dump must stay byte-identical to a run without it.
ENTRANCE_AUDIT_BLOCK = """		do
			local C = SBM.Config
			if type(C) ~= "table" then error("SuperBigMap.Config unavailable for the entrance audit") end
			C.DEBUG_LOGGING_ENABLED = true
			C.DEBUG_ELEVATOR_SUPPLY = true
			local D = SBM.Diagnostics
			if type(D) ~= "table" or type(D.ElevatorSupplyEnabled) ~= "function"
				or D.ElevatorSupplyEnabled() ~= true then
				error("entrance audit channel did not turn on")
			end
			g_ParityEntranceAudit = true
		end"""


# Diagnostic only, opt-in with the "probe" argument.  The expanded underground dumps zero
# SectorUnexplored overview decals while its surface dumps 399.  Iteration 005 ruled out
# destruction (no DoneObject on an underground decal, census never saw one exist), so the
# defect is creation-side, and this block separates the three remaining creation-side
# outcomes: UpdateDecal never called for an underground sector, called and suppressed by the
# mod's own patch (sbm_sector_highlight.lua destroys the decal and returns early for an
# expanded underground map when Config.UNDERGROUND_EXPLORATION_UI is on), or called and
# raising inside one of the swallowing pcalls.  It therefore counts BEFORE calling, runs the
# original under xpcall (re-raising so behaviour is unchanged), records every input of the
# mod's suppression predicate at the call site, wraps PlaceObjectIn so decal creation is seen
# independently of the caller, hooks MapSector construction to name what builds the 400
# underground sectors, and re-asserts the wrapper each census tick so a later class-method
# swap is detected.  It changes no generation input and consumes no map RNG.
DECAL_PROBE_BLOCK = """		do
			local probe_lines = {}
			local probe_tracebacks = 0
			local function probe_ticks()
				if type(GetPreciseTicks) == "function" then return GetPreciseTicks() end
				return 0
			end
			local probe_t0 = probe_ticks()
			local function probe_log(text)
				if #probe_lines >= 6000 then return end
				probe_lines[#probe_lines + 1] = string.format(
					"[%7dms][%s] %s", probe_ticks() - probe_t0,
					tostring(rawget(_G, "g_ParityStatus")), tostring(text))
			end
			g_ParityProbeLines = probe_lines
			g_ParityProbeStatus = "running"

			local function probe_map_of(obj)
				if type(obj) ~= "table" or type(obj.GetMap) ~= "function" then return nil end
				local ok, m = pcall(obj.GetMap, obj)
				if ok then return m end
				return nil
			end
			local function probe_env(map)
				if not map then return "nomap" end
				local env = map.mapdata and map.mapdata.Environment or "?"
				return tostring(env) .. "#" .. tostring(map.slot)
			end
			local function probe_is_decal(obj)
				if type(obj) ~= "table" then return false end
				local cls = obj.class
				return cls == "SectorUnexplored" or cls == "SectorScanned"
			end
			-- Every input of the mod's underground suppression branch, read at the call site.
			local function probe_predicates(map)
				local cfg = (type(SBM) == "table" and SBM.Config) or {}
				local is_mod = "?"
				if type(IsModMap) == "function" then
					local ok_mod, value = pcall(IsModMap, map)
					is_mod = ok_mod and tostring(value) or "err"
				end
				return string.format("ug_ui=%s is_mod_map=%s env=%s expanded=%s",
					tostring(cfg.UNDERGROUND_EXPLORATION_UI), is_mod,
					tostring(map and map.mapdata and map.mapdata.Environment),
					tostring(map and map.SuperBigMapExpanded))
			end
			local function probe_summary(name, tbl)
				local parts = {}
				for key, value in pairs(tbl or {}) do
					parts[#parts + 1] = string.format("%s=%s", tostring(key), tostring(value))
				end
				table.sort(parts)
				probe_log(string.format("SUMMARY %s: %s", name,
					#parts > 0 and table.concat(parts, " ") or "(none)"))
			end

			local sector_class = rawget(_G, "g_Classes") and g_Classes.MapSector
			local update_calls, update_errors, update_created, update_detail = {}, {}, {}, {}
			local our_update_wrapper = nil
			g_ParityProbeUpdateCalls = update_calls
			g_ParityProbeUpdateErrors = update_errors
			local function probe_wrap_update(original)
				if type(original) ~= "function" then return nil end
				return function(self, ...)
					local map = probe_map_of(self)
					local key = probe_env(map)
					update_calls[key] = (update_calls[key] or 0) + 1
					local n = update_calls[key]
					local detail = (update_detail[key] or 0) < 2
					if detail then
						update_detail[key] = (update_detail[key] or 0) + 1
						probe_log(string.format(
							"UpdateDecal ENTER %s n=%d sector=%s status=%s %s\\n%s",
							key, n, tostring(self.id), tostring(self.status),
							probe_predicates(map), debug.traceback("", 2)))
					end
					local ok_call, a, b = xpcall(original, debug.traceback, self, ...)
					if not ok_call then
						update_errors[key] = (update_errors[key] or 0) + 1
						if update_errors[key] <= 3 then
							probe_log(string.format("UpdateDecal RAISED %s n=%d sector=%s\\n%s",
								key, n, tostring(self.id), tostring(a)))
						end
						error(a, 0)
					end
					if IsValid(self.decal) then
						update_created[key] = (update_created[key] or 0) + 1
					end
					if detail or (n % 100) == 1 then
						probe_log(string.format(
							"UpdateDecal EXIT %s n=%d with_decal=%d errors=%d",
							key, n, update_created[key] or 0, update_errors[key] or 0))
					end
					return a, b
				end
			end
			if sector_class and type(sector_class.UpdateDecal) == "function" then
				our_update_wrapper = probe_wrap_update(sector_class.UpdateDecal)
				sector_class.UpdateDecal = our_update_wrapper
				probe_log("wrapped MapSector:UpdateDecal")
			else
				probe_log("MapSector:UpdateDecal unavailable - creation side not instrumented")
			end

			-- Independent of who calls it: every sector-decal object creation.
			local original_place_in = rawget(_G, "PlaceObjectIn")
			if type(original_place_in) == "function" then
				local placed, placed_detail = {}, {}
				g_ParityProbePlaced = placed
				PlaceObjectIn = function(class, target, ...)
					local obj = original_place_in(class, target, ...)
					if class == "SectorUnexplored" or class == "SectorScanned" then
						local key = probe_env(probe_map_of(obj)) .. "/" .. tostring(class)
						placed[key] = (placed[key] or 0) + 1
						if (placed_detail[key] or 0) < 2 then
							placed_detail[key] = (placed_detail[key] or 0) + 1
							probe_log(string.format("PlaceObjectIn %s n=%d valid=%s\\n%s",
								key, placed[key], tostring(IsValid(obj)),
								debug.traceback("", 2)))
						elseif (placed[key] % 100) == 1 then
							probe_log(string.format("PlaceObjectIn %s n=%d", key, placed[key]))
						end
					end
					return obj
				end
				probe_log("wrapped PlaceObjectIn")
			end

			-- Name what builds the 400 underground MapSectors.
			if sector_class then
				local original_init = sector_class.Init
				local inits, inits_detail = {}, {}
				g_ParityProbeSectorInits = inits
				sector_class.Init = function(self, ...)
					local a, b
					if type(original_init) == "function" then a, b = original_init(self, ...) end
					local key = probe_env(probe_map_of(self))
					inits[key] = (inits[key] or 0) + 1
					if (inits_detail[key] or 0) < 2 then
						inits_detail[key] = (inits_detail[key] or 0) + 1
						probe_log(string.format("MapSector Init %s n=%d id=%s\\n%s",
							key, inits[key], tostring(self.id), debug.traceback("", 2)))
					elseif (inits[key] % 100) == 1 then
						probe_log(string.format("MapSector Init %s n=%d", key, inits[key]))
					end
					return a, b
				end
				probe_log("wrapped MapSector:Init")
			end

			local original_done = rawget(_G, "DoneObject")
			if type(original_done) == "function" then
				local destroyed = {}
				g_ParityProbeDestroyed = destroyed
				DoneObject = function(obj, ...)
					if probe_is_decal(obj) then
						local key = probe_env(probe_map_of(obj)) .. "/" .. tostring(obj.class)
						destroyed[key] = (destroyed[key] or 0) + 1
						if probe_tracebacks < 10 then
							probe_tracebacks = probe_tracebacks + 1
							probe_log(string.format("DoneObject %s n=%d\\n%s",
								key, destroyed[key], debug.traceback("", 2)))
						elseif (destroyed[key] % 100) == 1 then
							probe_log(string.format("DoneObject %s n=%d", key, destroyed[key]))
						end
					end
					return original_done(obj, ...)
				end
				probe_log("wrapped DoneObject")
			end

			local original_done_objects = rawget(_G, "DoneObjects")
			if type(original_done_objects) == "function" then
				DoneObjects = function(list, ...)
					if type(list) == "table" then
						local hits = 0
						for i = 1, #list do
							if probe_is_decal(list[i]) then hits = hits + 1 end
						end
						if hits > 0 then
							probe_log(string.format("DoneObjects list hits=%d of %d\\n%s",
								hits, #list, debug.traceback("", 2)))
						end
					end
					return original_done_objects(list, ...)
				end
				probe_log("wrapped DoneObjects")
			end

			CreateRealTimeThread(function()
				local last = {}
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					-- The mod reinstalls its own MapSector:UpdateDecal patch on demand and the
					-- generator re-runs sector construction, so the wrapper can be swapped out
					-- mid-run; detect that and re-wrap whatever is installed now.
					if sector_class and our_update_wrapper
						and sector_class.UpdateDecal ~= our_update_wrapper then
						probe_log("MapSector:UpdateDecal was REPLACED by another system; re-wrapping")
						our_update_wrapper = probe_wrap_update(sector_class.UpdateDecal)
						sector_class.UpdateDecal = our_update_wrapper
					end
					for i = 1, #(rawget(_G, "Maps") or {}) do
						local m = Maps[i]
						-- Skip a map that is loading or being destroyed: MapGet before the native
						-- map is mounted trips luaQuery.cpp ASSERT(m_pMap) (seen in iteration 011).
						if m and type(m.MapGet) == "function" and not m.changing then
							local ok_d, decals = pcall(m.MapGet, m, "map", "SectorUnexplored")
							local ok_s, scanned = pcall(m.MapGet, m, "map", "SectorScanned")
							local ok_m, sectors = pcall(m.MapGet, m, "map", "MapSector")
							local nd = ok_d and #(decals or {}) or -1
							local ns = ok_s and #(scanned or {}) or -1
							local nm = ok_m and #(sectors or {}) or -1
							local key = probe_env(m)
							local cur = string.format("%d/%d/%d", nd, ns, nm)
							if last[key] ~= cur then
								probe_log(string.format(
									"census %s unexplored=%d scanned=%d sectors=%d", key, nd, ns, nm))
								last[key] = cur
							end
						end
					end
					if status == "complete" or status == "error" then break end
					Sleep(400)
				end
				probe_log("final census taken; writing probe log")
				probe_summary("UpdateDecal calls", update_calls)
				probe_summary("UpdateDecal raised", update_errors)
				probe_summary("UpdateDecal left a decal", update_created)
				probe_summary("PlaceObjectIn decals", rawget(_G, "g_ParityProbePlaced"))
				probe_summary("MapSector Init", rawget(_G, "g_ParityProbeSectorInits"))
				probe_summary("DoneObject decals", rawget(_G, "g_ParityProbeDestroyed"))
				-- Read-only post-mortem of the suppression predicate on a real underground sector.
				for i = 1, #(rawget(_G, "Maps") or {}) do
					local m = Maps[i]
					local env = m and m.mapdata and m.mapdata.Environment
					if env == "Underground" and type(m.MapGet) == "function" then
						local ok_s, sectors = pcall(m.MapGet, m, "map", "MapSector")
						local sector = ok_s and sectors and sectors[1]
						probe_log(string.format("postmortem %s sectors=%d sample=%s %s",
							probe_env(m), ok_s and #(sectors or {}) or -1,
							tostring(sector and sector.id),
							probe_predicates(m)))
						local state = (type(SBM) == "table" and SBM.State) or {}
						probe_log(string.format(
							"postmortem patch: class_update=%s our_wrapper=%s mod_saved_original=%s",
							tostring(sector_class and sector_class.UpdateDecal),
							tostring(our_update_wrapper),
							tostring(state.original_map_sector_update_decal)))
					end
				end
				local werr = AsyncStringToFile("__PROBE_OUT__", table.concat(probe_lines, "\\n"))
				g_ParityProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "cameraprobe" argument.  `CameraObj` is the last
# infrastructure class without a proven cardinality rule: the engine creates exactly one per
# map (MapVar "g_CameraObj", CommonLua/Classes/ActionFX.lua:4322, initialized from
# OnMsg.NewMap through InitMapVarValue in CommonLua/Core/lib.lua:995), yet the expanded
# surface dumps TWO - one at the vanilla-twin camera pose carrying a self-stamp from the
# pre-stretch capture, one at the expanded pose with no stamp - while every other map dumps
# one.  Either a second engine-side MapVar initialization happens on that map (orphaning the
# first object) or something creates a CameraObj directly.  This block names the creator: it
# wraps CameraObj:Init to log a traceback per construction, wraps DoneObject to see any
# destruction, samples per-map CameraObj counts plus the identity of map.g_CameraObj so a
# silent replacement is visible, and enumerates every surviving instance at the end (pose,
# whether it is the live g_CameraObj, stamp, flags).  It creates no object, consumes no map
# RNG, and changes no generation input.
CAMERA_PROBE_BLOCK = """		do
			local cam_lines = {}
			local function cam_ticks()
				if type(GetPreciseTicks) == "function" then return GetPreciseTicks() end
				return 0
			end
			local cam_t0 = cam_ticks()
			local function cam_log(text)
				if #cam_lines >= 4000 then return end
				cam_lines[#cam_lines + 1] = string.format(
					"[%7dms][%s] %s", cam_ticks() - cam_t0,
					tostring(rawget(_G, "g_ParityStatus")), tostring(text))
			end
			g_ParityCamLines = cam_lines
			g_ParityCamProbeStatus = "running"

			local function cam_map_of(obj)
				if type(obj) ~= "table" or type(obj.GetMap) ~= "function" then return nil end
				local ok, m = pcall(obj.GetMap, obj)
				if ok then return m end
				return nil
			end
			local function cam_key(map)
				if not map then return "nomap" end
				local env = map.mapdata and map.mapdata.Environment or "?"
				return tostring(env) .. "#" .. tostring(map.slot)
			end
			local function cam_pos(obj)
				local ok, pos = pcall(obj.GetPos, obj)
				if not ok or not pos then return "nopos" end
				local ok_a, angle = pcall(obj.GetAngle, obj)
				return string.format("%s angle=%s", tostring(pos), ok_a and tostring(angle) or "?")
			end

			local cam_class = rawget(_G, "g_Classes") and g_Classes.CameraObj
			local created = 0
			if cam_class then
				local original_init = cam_class.Init
				cam_class.Init = function(self, ...)
					local a, b
					if type(original_init) == "function" then a, b = original_init(self, ...) end
					created = created + 1
					cam_log(string.format("CameraObj Init #%d obj=%s map=%s\\n%s",
						created, tostring(self), cam_key(cam_map_of(self)),
						debug.traceback("", 2)))
					return a, b
				end
				cam_log("wrapped CameraObj:Init")
			else
				cam_log("CameraObj class unavailable - creation not instrumented")
			end

			local original_done = rawget(_G, "DoneObject")
			if type(original_done) == "function" then
				local destroyed = 0
				DoneObject = function(obj, ...)
					if type(obj) == "table" and obj.class == "CameraObj" then
						destroyed = destroyed + 1
						cam_log(string.format("DoneObject CameraObj #%d obj=%s map=%s %s\\n%s",
							destroyed, tostring(obj), cam_key(cam_map_of(obj)), cam_pos(obj),
							debug.traceback("", 2)))
					end
					return original_done(obj, ...)
				end
				cam_log("wrapped DoneObject")
			end

			-- MapGet on a map whose native map is not mounted yet trips the engine's
			-- luaQuery.cpp ASSERT(m_pMap); Map.changing is "loading" from ChangeMapInSlot until
			-- Map:Load finishes (CommonLua/Core/map.lua:339/376) and "destroying" during
			-- teardown, so skip those windows entirely.
			local function cam_queryable(m)
				return m and type(m.MapGet) == "function" and not m.changing
			end

			CreateRealTimeThread(function()
				local last = {}
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					for i = 1, #(rawget(_G, "Maps") or {}) do
						local m = Maps[i]
						if cam_queryable(m) then
							local ok_c, cams = pcall(m.MapGet, m, "map", "CameraObj")
							local n = ok_c and #(cams or {}) or -1
							local key = cam_key(m)
							local cur = string.format("%d/%s", n, tostring(m.g_CameraObj))
							if last[key] ~= cur then
								cam_log(string.format("census %s cameras=%d g_CameraObj=%s",
									key, n, tostring(m.g_CameraObj)))
								last[key] = cur
							end
						end
					end
					if status == "complete" or status == "error" then break end
					Sleep(400)
				end
				cam_log(string.format("SUMMARY constructions=%d", created))
				for i = 1, #(rawget(_G, "Maps") or {}) do
					local m = Maps[i]
					if cam_queryable(m) then
						local ok_c, cams = pcall(m.MapGet, m, "map", "CameraObj")
						cams = ok_c and cams or {}
						cam_log(string.format("postmortem %s cameras=%d live_g_CameraObj=%s",
							cam_key(m), #cams, tostring(m.g_CameraObj)))
						for j = 1, #cams do
							local obj = cams[j]
							local perm, vis = "?", "?"
							if type(const) == "table" and type(obj.GetGameFlags) == "function" then
								local ok_p, v = pcall(obj.GetGameFlags, obj, const.gofPermanent)
								perm = ok_p and tostring(v) or "err"
							end
							if type(const) == "table" and type(obj.GetEnumFlags) == "function" then
								local ok_v, v = pcall(obj.GetEnumFlags, obj, const.efVisible)
								vis = ok_v and tostring(v) or "err"
							end
							cam_log(string.format(
								"  [%d] obj=%s %s is_live=%s valid=%s stamped=%s permanent=%s visible=%s",
								j, tostring(obj), cam_pos(obj), tostring(obj == m.g_CameraObj),
								tostring(IsValid(obj)), tostring(obj.SuperBigMapNativeSourceX),
								perm, vis))
						end
					end
				end
				local werr = AsyncStringToFile("__CAM_OUT__", table.concat(cam_lines, "\\n"))
				g_ParityCamProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "fxprobe" argument.  The remaining surface content residue is
# 5 ParSystem (5 vanilla unclaimed vs 5 expanded unstamped).  Offline row algebra on iteration
# 028's dumps shows they are unattached `Revealed` ActionFXParticles (Data/FXPreset/
# ActionFXParticles.lua `Particles_1LtXWp8i`: Action "Revealed", Moment "true", Offset
# point(0,0,100), Target "ignore", no Actor filter), played from SubsurfaceDeposit:SetRevealed
# (Lua/Buildings/SubsurfaceDeposit.lua:132), and that the two expanded surface ones belonging to
# entrance #1 sit at the expanded UNDERGROUND anchor's XY (549000/554000, 322152) rather than at
# their own expanded surface anchor (553000/558000, 329080).  Two candidate mechanisms remain:
# the surface actor was at that XY when the FX fired and moved afterwards, or the FX of an
# underground actor landed in the surface map.  This block separates them: it wraps PlayFX
# (filtered to "Revealed") to record the actor's class, map and pose AT CALL TIME, wraps
# PlaceParticles to bind each created ParSystem to that actor plus a creation traceback, samples
# a change-only position timeline of every passage/tunnel/deposit anchor per map, and enumerates
# every surviving ParSystem at the end (pose, scale, angle, particle name, parent, stamps).  It
# creates no object, consumes no map RNG and changes no generation input.
FX_PROBE_BLOCK = """		do
			local fx_lines = {}
			local function fx_ticks()
				if type(GetPreciseTicks) == "function" then return GetPreciseTicks() end
				return 0
			end
			local fx_t0 = fx_ticks()
			local function fx_log(text)
				if #fx_lines >= 6000 then return end
				fx_lines[#fx_lines + 1] = string.format(
					"[%7dms][%s] %s", fx_ticks() - fx_t0,
					tostring(rawget(_G, "g_ParityStatus")), tostring(text))
			end
			g_ParityFxLines = fx_lines
			g_ParityFxProbeStatus = "running"

			local TRACKED = {
				"UndergroundPassage", "UndergroundTunnelMarker", "SurfaceUndergroundTunnelSign",
				"SurfacePassage", "SurfaceTunnelMarker", "SubsurfaceDepositMetals",
				"SubsurfaceDepositMarker", "BottomlessPit",
			}

			local function fx_map_key(m)
				if not m then return "nomap" end
				local env = m.mapdata and m.mapdata.Environment or "?"
				return tostring(env) .. "#" .. tostring(m.slot)
			end
			local function fx_map_of(obj)
				if type(obj) ~= "table" or type(obj.GetMap) ~= "function" then return nil end
				local ok, m = pcall(obj.GetMap, obj)
				if ok then return m end
				return nil
			end
			local function fx_desc(obj)
				if type(obj) ~= "table" then return tostring(obj) end
				local cls = rawget(obj, "class") or (obj.class) or "?"
				local pos, angle = "nopos", "?"
				if type(obj.GetPos) == "function" then
					local ok, p = pcall(obj.GetPos, obj)
					if ok then pos = tostring(p) end
				end
				if type(obj.GetAngle) == "function" then
					local ok, a = pcall(obj.GetAngle, obj)
					if ok then angle = tostring(a) end
				end
				return string.format("%s[%s] map=%s pos=%s angle=%s", tostring(cls), tostring(obj),
					fx_map_key(fx_map_of(obj)), pos, angle)
			end

			-- Binds a ParSystem created inside a Revealed FX to the actor that played it.
			local fx_current_actor, fx_current_moment = nil, nil
			local revealed_calls, par_creations = 0, 0
			local par_records = {}

			local original_playfx = rawget(_G, "PlayFX")
			if type(original_playfx) == "function" then
				_G.PlayFX = function(cls, moment, actor, target, action_pos, action_dir, ...)
					if cls == "Revealed" then
						revealed_calls = revealed_calls + 1
						local desc = fx_desc(actor)
						if revealed_calls <= 40 then
							fx_log(string.format(
								"PlayFX Revealed #%d moment=%s action_pos=%s\\n    actor=%s\\n    target=%s\\n%s",
								revealed_calls, tostring(moment), tostring(action_pos), desc,
								fx_desc(target), debug.traceback("", 2)))
						end
						local prev_actor, prev_moment = fx_current_actor, fx_current_moment
						fx_current_actor, fx_current_moment = desc, tostring(moment)
						local a, b, c = original_playfx(cls, moment, actor, target, action_pos, action_dir, ...)
						fx_current_actor, fx_current_moment = prev_actor, prev_moment
						return a, b, c
					end
					return original_playfx(cls, moment, actor, target, action_pos, action_dir, ...)
				end
				fx_log("wrapped PlayFX")
			else
				fx_log("PlayFX unavailable - reveal actors not instrumented")
			end

			local original_place_particles = rawget(_G, "PlaceParticles")
			if type(original_place_particles) == "function" then
				_G.PlaceParticles = function(map, name, class, components)
					local o = original_place_particles(map, name, class, components)
					par_creations = par_creations + 1
					if #par_records < 300 then
						par_records[#par_records + 1] = {
							index = par_creations, obj = o, name = tostring(name),
							map_key = fx_map_key(map), actor = fx_current_actor,
							moment = fx_current_moment,
							traceback = par_creations <= 40 and debug.traceback("", 2) or nil,
						}
					end
					return o
				end
				fx_log("wrapped PlaceParticles")
			else
				fx_log("PlaceParticles unavailable - particle creation not instrumented")
			end

			-- MapGet before the native map is mounted trips luaQuery.cpp ASSERT(m_pMap) (iter 011).
			local function fx_queryable(m)
				return m and type(m.MapGet) == "function" and not m.changing
			end

			CreateRealTimeThread(function()
				local last = {}
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					for i = 1, #(rawget(_G, "Maps") or {}) do
						local m = Maps[i]
						if fx_queryable(m) then
							local key = fx_map_key(m)
							for _, cls in ipairs(TRACKED) do
								local ok, objs = pcall(m.MapGet, m, "map", cls)
								objs = ok and objs or {}
								if #objs > 0 then
									local parts = {}
									for j = 1, #objs do
										local ok_p, p = pcall(objs[j].GetPos, objs[j])
										parts[#parts + 1] = ok_p and tostring(p) or "nopos"
									end
									table.sort(parts)
									local sig = table.concat(parts, " ")
									local slot = key .. "/" .. cls
									if last[slot] ~= sig then
										fx_log(string.format("timeline %s n=%d %s", slot, #objs, sig))
										last[slot] = sig
									end
								end
							end
						end
					end
					if status == "complete" or status == "error" then break end
					Sleep(400)
				end
				fx_log(string.format("SUMMARY Revealed PlayFX calls=%d PlaceParticles calls=%d recorded=%d",
					revealed_calls, par_creations, #par_records))
				for i = 1, #(rawget(_G, "Maps") or {}) do
					local m = Maps[i]
					if fx_queryable(m) then
						local ok, pars = pcall(m.MapGet, m, "map", "ParSystem")
						pars = ok and pars or {}
						fx_log(string.format("postmortem %s ParSystem=%d", fx_map_key(m), #pars))
						for j = 1, #pars do
							local obj = pars[j]
							local name, parent, scale = "?", "?", "?"
							if type(obj.GetProperty) == "function" then
								local ok_n, v = pcall(obj.GetProperty, obj, "ParticlesName")
								name = ok_n and tostring(v) or "err"
							end
							if type(obj.GetParent) == "function" then
								local ok_p, v = pcall(obj.GetParent, obj)
								parent = ok_p and fx_desc(v) or "err"
							end
							if type(obj.GetScale) == "function" then
								local ok_s, v = pcall(obj.GetScale, obj)
								scale = ok_s and tostring(v) or "err"
							end
							fx_log(string.format(
								"  [%d] %s scale=%s particles=%s native=%s,%s prov=%s,%s parent=%s",
								j, fx_desc(obj), scale, name,
								tostring(obj.SuperBigMapNativeSourceX),
								tostring(obj.SuperBigMapNativeSourceY),
								tostring(obj.SuperBigMapProvenanceSourceX),
								tostring(obj.SuperBigMapProvenanceSourceY), parent))
						end
					end
				end
				for i = 1, #par_records do
					local rec = par_records[i]
					local obj = rec.obj
					local live = "gone"
					if type(obj) == "table" and IsValid(obj) then live = fx_desc(obj) end
					fx_log(string.format("creation #%d map=%s particles=%s moment=%s\\n    now=%s\\n    actor=%s%s",
						rec.index, rec.map_key, rec.name, tostring(rec.moment), live,
						tostring(rec.actor), rec.traceback and ("\\n" .. rec.traceback) or ""))
				end
				local werr = AsyncStringToFile("__FX_OUT__", table.concat(fx_lines, "\\n"))
				g_ParityFxProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "pitprobe" argument.  The remaining underground content
# residue includes 3 vanilla `ParSystem` with NO expanded counterpart.  Offline row algebra on
# iteration 030's dumps identifies them exactly: they are the stock `Particles_XTkn7htB`
# (Data/FXPreset/ActionFXParticles.lua: Action "Spawn", Actor "BottomlessPit", Attach = true,
# Spot "Fog", SpotsPercent 100), i.e. three ATTACHED fog emitters created when
# SpawnFXObject/Building GameInit plays PlayFX("Spawn", "start", pit).  The expanded twin does
# carry the pit itself at the exact transform image (397333,401824 = 4/3 x 298000,301368,
# native stamp), so the actor exists and only its attached FX is gone.  Three mechanisms are
# still possible: the FX never played on the expanded twin, it played and the attaches were lost
# when TransferToMap moved the pit off the temporary vanilla backing, or something destroyed
# them afterwards (the mod reseats underground wonders after materialization).  This block
# separates them: it wraps PlayFX (filtered to "Spawn") to record actor class/map/pose and a
# traceback AT CALL TIME, wraps PlaceParticles to bind every created emitter to that actor,
# wraps DoneObject/DoneObjects to catch the destruction of any ParSystem with a traceback, and
# samples a change-only timeline of every watched wonder actor (map, pose, attach list) plus the
# per-map ParSystem count and the live map set.  It creates no object, consumes no map RNG and
# changes no generation input.
PIT_PROBE_BLOCK = """		do
			local pit_lines = {}
			local function pit_ticks()
				if type(GetPreciseTicks) == "function" then return GetPreciseTicks() end
				return 0
			end
			local pit_t0 = pit_ticks()
			local function pit_log(text)
				if #pit_lines >= 8000 then return end
				pit_lines[#pit_lines + 1] = string.format(
					"[%7dms][%s] %s", pit_ticks() - pit_t0,
					tostring(rawget(_G, "g_ParityStatus")), tostring(text))
			end
			g_ParityPitLines = pit_lines
			g_ParityPitProbeStatus = "running"

			local WATCHED = { BottomlessPit = true, JumboCave = true }

			local function pit_map_key(m)
				if not m then return "nomap" end
				local env = m.mapdata and m.mapdata.Environment or "?"
				return tostring(env) .. "#" .. tostring(m.slot)
			end
			local function pit_map_of(obj)
				if type(obj) ~= "table" or type(obj.GetMap) ~= "function" then return nil end
				local ok, m = pcall(obj.GetMap, obj)
				if ok then return m end
				return nil
			end
			local function pit_class(obj)
				if type(obj) ~= "table" then return tostring(obj) end
				return tostring(rawget(obj, "class") or obj.class or "?")
			end
			local function pit_desc(obj)
				if type(obj) ~= "table" then return tostring(obj) end
				local pos, angle, scale = "nopos", "?", "?"
				if type(obj.GetPos) == "function" then
					local ok, p = pcall(obj.GetPos, obj)
					if ok then pos = tostring(p) end
				end
				if type(obj.GetAngle) == "function" then
					local ok, a = pcall(obj.GetAngle, obj)
					if ok then angle = tostring(a) end
				end
				if type(obj.GetScale) == "function" then
					local ok, s = pcall(obj.GetScale, obj)
					if ok then scale = tostring(s) end
				end
				return string.format("%s[%s] map=%s pos=%s angle=%s scale=%s", pit_class(obj),
					tostring(obj), pit_map_key(pit_map_of(obj)), pos, angle, scale)
			end
			local function pit_attaches(obj)
				if type(obj) ~= "table" or type(obj.GetAttaches) ~= "function" then
					return "no GetAttaches"
				end
				local ok, list = pcall(obj.GetAttaches, obj)
				if not ok then return "GetAttaches error" end
				list = list or {}
				local parts = {}
				for i = 1, #list do
					local a = list[i]
					local apos = "nopos"
					if type(a) == "table" and type(a.GetPos) == "function" then
						local ok_p, p = pcall(a.GetPos, a)
						if ok_p then apos = tostring(p) end
					end
					parts[#parts + 1] = pit_class(a) .. "@" .. apos
				end
				table.sort(parts)
				return string.format("n=%d [%s]", #list, table.concat(parts, " "))
			end

			-- Binds a ParSystem created inside a Spawn FX to the actor that played it.
			local pit_current_actor, pit_current_moment = nil, nil
			local spawn_calls, watched_calls, par_creations = 0, 0, 0
			local par_records, par_by_obj = {}, {}

			local original_playfx = rawget(_G, "PlayFX")
			if type(original_playfx) == "function" then
				_G.PlayFX = function(cls, moment, actor, target, action_pos, action_dir, ...)
					if cls == "Spawn" then
						spawn_calls = spawn_calls + 1
						local watched = WATCHED[pit_class(actor)] == true
						if watched then
							watched_calls = watched_calls + 1
							pit_log(string.format(
								"PlayFX Spawn (WATCHED #%d of %d) moment=%s\\n    actor=%s\\n    attaches=%s\\n%s",
								watched_calls, spawn_calls, tostring(moment), pit_desc(actor),
								pit_attaches(actor), debug.traceback("", 2)))
						end
						local prev_actor, prev_moment = pit_current_actor, pit_current_moment
						pit_current_actor = watched and pit_desc(actor) or ("unwatched:" .. pit_class(actor))
						pit_current_moment = tostring(moment)
						local a, b, c = original_playfx(cls, moment, actor, target, action_pos, action_dir, ...)
						if watched then
							pit_log(string.format("  after PlayFX Spawn moment=%s attaches=%s",
								tostring(moment), pit_attaches(actor)))
						end
						pit_current_actor, pit_current_moment = prev_actor, prev_moment
						return a, b, c
					end
					return original_playfx(cls, moment, actor, target, action_pos, action_dir, ...)
				end
				pit_log("wrapped PlayFX")
			else
				pit_log("PlayFX unavailable - Spawn actors not instrumented")
			end

			local original_place_particles = rawget(_G, "PlaceParticles")
			if type(original_place_particles) == "function" then
				_G.PlaceParticles = function(map, name, class, components)
					local o = original_place_particles(map, name, class, components)
					par_creations = par_creations + 1
					if #par_records < 400 then
						local rec = {
							index = par_creations, obj = o, name = tostring(name),
							map_key = pit_map_key(map), actor = pit_current_actor,
							moment = pit_current_moment,
							traceback = (pit_current_actor and par_creations <= 60)
								and debug.traceback("", 2) or nil,
						}
						par_records[#par_records + 1] = rec
						if type(o) == "table" then par_by_obj[o] = rec end
					end
					return o
				end
				pit_log("wrapped PlaceParticles")
			else
				pit_log("PlaceParticles unavailable - particle creation not instrumented")
			end

			-- Destruction side: any ParSystem death is logged, whether or not this probe saw it born.
			local destroyed = 0
			local function pit_note_destroy(obj, via)
				if type(obj) ~= "table" or pit_class(obj) ~= "ParSystem" then return end
				destroyed = destroyed + 1
				local rec = par_by_obj[obj]
				if destroyed <= 60 then
					pit_log(string.format("DESTROY ParSystem via %s creation=#%s particles=%s\\n    %s\\n%s",
						tostring(via), rec and tostring(rec.index) or "unseen",
						rec and rec.name or "?", pit_desc(obj), debug.traceback("", 2)))
				end
			end
			local original_done_object = rawget(_G, "DoneObject")
			if type(original_done_object) == "function" then
				_G.DoneObject = function(obj, ...)
					pit_note_destroy(obj, "DoneObject")
					return original_done_object(obj, ...)
				end
				pit_log("wrapped DoneObject")
			end
			local original_done_objects = rawget(_G, "DoneObjects")
			if type(original_done_objects) == "function" then
				_G.DoneObjects = function(objs, ...)
					if type(objs) == "table" then
						for i = 1, #objs do pit_note_destroy(objs[i], "DoneObjects") end
					end
					return original_done_objects(objs, ...)
				end
				pit_log("wrapped DoneObjects")
			end

			-- MapGet before the native map is mounted trips luaQuery.cpp ASSERT(m_pMap) (iter 011).
			local function pit_queryable(m)
				return m and type(m.MapGet) == "function" and not m.changing
			end

			CreateRealTimeThread(function()
				local last, last_maps = {}, ""
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					local map_keys = {}
					for i = 1, #(rawget(_G, "Maps") or {}) do
						local m = Maps[i]
						map_keys[#map_keys + 1] = pit_map_key(m) .. (m and m.changing and "*" or "")
						if pit_queryable(m) then
							local key = pit_map_key(m)
							for cls in pairs(WATCHED) do
								local ok, objs = pcall(m.MapGet, m, "map", cls)
								objs = ok and objs or {}
								for j = 1, #objs do
									local sig = pit_desc(objs[j]) .. " attaches=" .. pit_attaches(objs[j])
									local slot = key .. "/" .. cls .. "/" .. tostring(objs[j])
									if last[slot] ~= sig then
										pit_log("timeline " .. sig)
										last[slot] = sig
									end
								end
							end
							local ok_p, pars = pcall(m.MapGet, m, "map", "ParSystem")
							pars = ok_p and pars or {}
							local slot = key .. "/ParSystem#"
							local sig = tostring(#pars)
							if last[slot] ~= sig then
								pit_log(string.format("timeline %s ParSystem count=%s", key, sig))
								last[slot] = sig
							end
						end
					end
					local maps_sig = table.concat(map_keys, " ")
					if maps_sig ~= last_maps then
						pit_log("maps: " .. maps_sig)
						last_maps = maps_sig
					end
					if status == "complete" or status == "error" then break end
					Sleep(400)
				end
				pit_log(string.format(
					"SUMMARY Spawn PlayFX calls=%d (watched %d) PlaceParticles=%d recorded=%d ParSystem destroyed=%d",
					spawn_calls, watched_calls, par_creations, #par_records, destroyed))
				for i = 1, #(rawget(_G, "Maps") or {}) do
					local m = Maps[i]
					if pit_queryable(m) then
						local ok, pars = pcall(m.MapGet, m, "map", "ParSystem")
						pars = ok and pars or {}
						pit_log(string.format("postmortem %s ParSystem=%d", pit_map_key(m), #pars))
						for j = 1, #pars do
							local obj = pars[j]
							local name, parent = "?", "?"
							if type(obj.GetProperty) == "function" then
								local ok_n, v = pcall(obj.GetProperty, obj, "ParticlesName")
								name = ok_n and tostring(v) or "err"
							end
							if type(obj.GetParent) == "function" then
								local ok_p, v = pcall(obj.GetParent, obj)
								parent = ok_p and pit_desc(v) or "err"
							end
							pit_log(string.format("  [%d] %s particles=%s parent=%s", j,
								pit_desc(obj), name, parent))
						end
						for cls in pairs(WATCHED) do
							local ok_w, objs = pcall(m.MapGet, m, "map", cls)
							objs = ok_w and objs or {}
							for j = 1, #objs do
								pit_log(string.format("postmortem %s %s attaches=%s native=%s,%s",
									pit_map_key(m), pit_desc(objs[j]), pit_attaches(objs[j]),
									tostring(objs[j].SuperBigMapNativeSourceX),
									tostring(objs[j].SuperBigMapNativeSourceY)))
							end
						end
					end
				end
				for i = 1, #par_records do
					local rec = par_records[i]
					if rec.actor then
						local obj = rec.obj
						local live = "gone"
						if type(obj) == "table" and IsValid(obj) then live = pit_desc(obj) end
						pit_log(string.format(
							"creation #%d map=%s particles=%s moment=%s\\n    now=%s\\n    actor=%s%s",
							rec.index, rec.map_key, rec.name, tostring(rec.moment), live,
							tostring(rec.actor), rec.traceback and ("\\n" .. rec.traceback) or ""))
					end
				end
				local werr = AsyncStringToFile("__PIT_OUT__", table.concat(pit_lines, "\\n"))
				g_ParityPitProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "decorprobe" argument.  The last underground content residue
# is ten deterministic one-object sites (iteration 034): five prefab decor objects the expanded
# twin has and vanilla does not, five vanilla has and the expanded twin does not, spread over
# RemovableRocks_01/02, Rocks_04 and SoundSource.  Every stock pass that can add or drop exactly
# one prefab object funnels through DoneObject - PlaceZonePrefab's IsOutsider cull
# (RandomMapGenerator.lua:2306), remove_overlapping_object and delete_on_steep_slope (both through
# `local remove_object = DoneObject`, :2686, bound when Generate runs, so a wrapper installed
# before generation is captured), and the end-of-generation PrefabObj sweep (:2910).  This block
# therefore wraps DoneObject/DoneObjects and logs class, map, position and a full traceback for
# every watched-class destruction near one of the ten sites, wraps PlacePrefab (plus
# PlaceObject/PlaceObjectIn) so the creation side of each site is visible independently of who
# culls it, samples a change-only per-map census of the four classes, and ends with a per-site
# post-mortem that reports the nearest surviving watched object to both the source coordinate and
# its 4/3 stretch image.  Identical Lua runs on BOTH twins.  It creates no object, consumes no map
# RNG and changes no generation input; inertness is proven by a byte-identical dump.
DECOR_PROBE_BLOCK = """		do
			local decor_lines = {}
			local decor_dropped = 0
			local decor_tracebacks = 0
			local function decor_ticks()
				if type(GetPreciseTicks) == "function" then return GetPreciseTicks() end
				return 0
			end
			local decor_t0 = decor_ticks()
			local function decor_log(text)
				if #decor_lines >= 40000 then
					decor_dropped = decor_dropped + 1
					return
				end
				decor_lines[#decor_lines + 1] = string.format(
					"[%7dms][%s] %s", decor_ticks() - decor_t0,
					tostring(rawget(_G, "g_ParityStatus")), tostring(text))
			end
			g_ParityDecorLines = decor_lines
			g_ParityDecorProbeStatus = "running"

			local WATCHED = {
				RemovableRocks_01 = true, RemovableRocks_02 = true,
				Rocks_04 = true, SoundSource = true,
			}
			-- The ten residue sites, in SOURCE (vanilla) coordinates.  "E" = present on the
			-- expanded twin only, "V" = present on the vanilla twin only (iteration 034).
			local SITES = {
				{"E", "Rocks_04", 169118, 305372},
				{"E", "SoundSource", 401972, 340705},
				{"E", "RemovableRocks_02", 271913, 343717},
				{"E", "RemovableRocks_02", 272833, 373485},
				{"E", "RemovableRocks_02", 288823, 385739},
				{"V", "SoundSource", 154540, 196242},
				{"V", "SoundSource", 336786, 397864},
				{"V", "RemovableRocks_02", 346164, 337898},
				{"V", "RemovableRocks_02", 164909, 387965},
				{"V", "RemovableRocks_01", 144912, 386496},
			}
			local SITE_R = 600

			local function decor_map_of(obj)
				if type(obj) ~= "table" or type(obj.GetMap) ~= "function" then return nil end
				local ok, m = pcall(obj.GetMap, obj)
				if ok then return m end
				return nil
			end
			local function decor_env(map)
				if not map then return "nomap" end
				local md = map.mapdata
				return string.format("%s#%s/%s", tostring(md and md.Environment or "?"),
					tostring(map.slot), tostring(md and md.Width or "?"))
			end
			local function decor_xy(obj)
				if type(obj) ~= "table" or type(obj.GetPos) ~= "function" then return nil end
				local ok, x, y = pcall(function()
					local p = obj:GetPos()
					return p:x(), p:y()
				end)
				if ok and type(x) == "number" then return x, y end
				return nil
			end
			-- Position-only (never class-filtered): a site whose object changed class would
			-- otherwise go unseen.  The expected class travels in the tag instead.
			local function decor_site(x, y)
				if type(x) ~= "number" or type(y) ~= "number" then return nil end
				for i = 1, #SITES do
					local s = SITES[i]
					local dx, dy = x - s[3], y - s[4]
					if dx < 0 then dx = -dx end
					if dy < 0 then dy = -dy end
					if dx <= SITE_R and dy <= SITE_R then
						return string.format("%s%02d:%s(%d,%d)", s[1], i, s[2], s[3], s[4])
					end
				end
				return nil
			end

			-- Creation side.
			local place_calls, place_watched = 0, 0
			local created_by_class, created_samples = {}, {}
			local function decor_note_create(obj, via, extra)
				local cls = type(obj) == "table" and obj.class
				if not cls or not WATCHED[cls] then return end
				local key = decor_env(decor_map_of(obj)) .. "/" .. tostring(cls)
				created_by_class[key] = (created_by_class[key] or 0) + 1
				local x, y = decor_xy(obj)
				local site = decor_site(x, y)
				local sample = (created_samples[key] or 0) < 2
				if sample then created_samples[key] = (created_samples[key] or 0) + 1 end
				local want_tb = (site ~= nil or sample) and decor_tracebacks < 160
				if want_tb then decor_tracebacks = decor_tracebacks + 1 end
				decor_log(string.format("PLACE %s %s (%s,%s) via=%s%s n=%d%s%s",
					key, tostring(cls), tostring(x), tostring(y), tostring(via),
					extra and (" " .. extra) or "", created_by_class[key],
					site and (" SITE=" .. site) or "",
					want_tb and ("\\n" .. debug.traceback("", 3)) or ""))
			end

			local original_place_prefab = rawget(_G, "PlacePrefab")
			if type(original_place_prefab) == "function" then
				_G.PlacePrefab = function(map, name, ...)
					local a, b, c = original_place_prefab(map, name, ...)
					place_calls = place_calls + 1
					if type(b) == "table" then
						for i = 1, #b do
							local obj = b[i]
							local cls = type(obj) == "table" and obj.class
							if cls and WATCHED[cls] then
								place_watched = place_watched + 1
								decor_note_create(obj, "PlacePrefab",
									"prefab=" .. tostring(name) .. " call=" .. tostring(place_calls))
							end
						end
					end
					return a, b, c
				end
				decor_log("wrapped PlacePrefab")
			else
				decor_log("PlacePrefab unavailable - prefab creation not instrumented")
			end

			local original_place_in = rawget(_G, "PlaceObjectIn")
			if type(original_place_in) == "function" then
				_G.PlaceObjectIn = function(class, target, ...)
					local obj = original_place_in(class, target, ...)
					if WATCHED[class] then decor_note_create(obj, "PlaceObjectIn") end
					return obj
				end
				decor_log("wrapped PlaceObjectIn")
			end
			local original_place_object = rawget(_G, "PlaceObject")
			if type(original_place_object) == "function" then
				_G.PlaceObject = function(class, ...)
					local obj = original_place_object(class, ...)
					if WATCHED[class] then decor_note_create(obj, "PlaceObject") end
					return obj
				end
				decor_log("wrapped PlaceObject")
			end

			-- Destruction side: the pass that decides each site.
			local destroyed_by_class, destroyed_samples = {}, {}
			local destroyed_total = 0
			local function decor_note_destroy(obj, via)
				local cls = type(obj) == "table" and obj.class
				if not cls or not WATCHED[cls] then return end
				destroyed_total = destroyed_total + 1
				local key = decor_env(decor_map_of(obj)) .. "/" .. tostring(cls)
				destroyed_by_class[key] = (destroyed_by_class[key] or 0) + 1
				local x, y = decor_xy(obj)
				local site = decor_site(x, y)
				local sample = (destroyed_samples[key] or 0) < 3
				if sample then destroyed_samples[key] = (destroyed_samples[key] or 0) + 1 end
				-- Site hits ALWAYS carry a traceback; they are the point of the probe.
				local want_tb = site ~= nil or (sample and decor_tracebacks < 160)
				if want_tb then decor_tracebacks = decor_tracebacks + 1 end
				decor_log(string.format("DONE %s %s (%s,%s) via=%s n=%d%s%s",
					key, tostring(cls), tostring(x), tostring(y), tostring(via),
					destroyed_by_class[key], site and (" SITE=" .. site) or "",
					want_tb and ("\\n" .. debug.traceback("", 3)) or ""))
			end

			local our_done_wrapper, our_done_objects_wrapper
			local function decor_wrap_done()
				local original = rawget(_G, "DoneObject")
				if type(original) ~= "function" or original == our_done_wrapper then return false end
				our_done_wrapper = function(obj, ...)
					decor_note_destroy(obj, "DoneObject")
					return original(obj, ...)
				end
				_G.DoneObject = our_done_wrapper
				return true
			end
			local function decor_wrap_done_objects()
				local original = rawget(_G, "DoneObjects")
				if type(original) ~= "function" or original == our_done_objects_wrapper then
					return false
				end
				our_done_objects_wrapper = function(objs, ...)
					if type(objs) == "table" then
						for i = 1, #objs do decor_note_destroy(objs[i], "DoneObjects") end
					end
					return original(objs, ...)
				end
				_G.DoneObjects = our_done_objects_wrapper
				return true
			end
			decor_log(decor_wrap_done() and "wrapped DoneObject" or "DoneObject unavailable")
			decor_log(decor_wrap_done_objects() and "wrapped DoneObjects" or "DoneObjects unavailable")

			-- MapGet before the native map is mounted trips luaQuery.cpp ASSERT(m_pMap) (iter 011).
			local function decor_queryable(m)
				return m and type(m.MapGet) == "function" and not m.changing
			end
			local function decor_count(m, cls)
				local ok, objs = pcall(m.MapGet, m, "map", cls)
				return ok and #(objs or {}) or -1
			end

			CreateRealTimeThread(function()
				local last = {}
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					-- A load-time wrapper can be orphaned by a later global swap; re-assert.
					if decor_wrap_done() then decor_log("DoneObject was REPLACED; re-wrapped") end
					if decor_wrap_done_objects() then
						decor_log("DoneObjects was REPLACED; re-wrapped")
					end
					for i = 1, #(rawget(_G, "Maps") or {}) do
						local m = Maps[i]
						if decor_queryable(m) then
							local key = decor_env(m)
							local parts = {}
							for cls in pairs(WATCHED) do
								parts[#parts + 1] = cls .. "=" .. tostring(decor_count(m, cls))
							end
							table.sort(parts)
							local cur = table.concat(parts, " ")
							if last[key] ~= cur then
								decor_log(string.format("census %s %s", key, cur))
								last[key] = cur
							end
						end
					end
					if status == "complete" or status == "error" then break end
					Sleep(400)
				end

				local function decor_summary(name, tbl)
					local parts = {}
					for key, value in pairs(tbl or {}) do
						parts[#parts + 1] = string.format("%s=%s", tostring(key), tostring(value))
					end
					table.sort(parts)
					decor_log(string.format("SUMMARY %s: %s", name,
						#parts > 0 and table.concat(parts, " ") or "(none)"))
				end
				decor_log(string.format(
					"SUMMARY PlacePrefab calls=%d watched_objects=%d destroyed_watched=%d dropped_lines=%d",
					place_calls, place_watched, destroyed_total, decor_dropped))
				decor_summary("created", created_by_class)
				decor_summary("destroyed", destroyed_by_class)

				-- Per-site post-mortem: nearest surviving watched object to the source coordinate
				-- and to its 4/3 stretch image (the expanded twin's objects are stretched by then).
				for i = 1, #(rawget(_G, "Maps") or {}) do
					local m = Maps[i]
					if decor_queryable(m) then
						local key = decor_env(m)
						local objs = {}
						for cls in pairs(WATCHED) do
							local ok, list = pcall(m.MapGet, m, "map", cls)
							list = ok and list or {}
							for j = 1, #list do objs[#objs + 1] = list[j] end
						end
						decor_log(string.format("postmortem %s watched_objects=%d", key, #objs))
						for s_i = 1, #SITES do
							local s = SITES[s_i]
							-- math.floor keeps these integers: Lua 5.3's "/" yields a float and
							-- string.format("%d", float) then raises.
							local targets = {
								{"src", s[3], s[4]},
								{"x4/3", math.floor((s[3] * 4) / 3), math.floor((s[4] * 4) / 3)},
							}
							for t = 1, #targets do
								local tgt = targets[t]
								local best, best_d2, best_dx, best_dy = nil, nil, nil, nil
								for j = 1, #objs do
									local x, y = decor_xy(objs[j])
									if x then
										local dx, dy = x - tgt[2], y - tgt[3]
										local d2 = dx * dx + dy * dy
										if not best_d2 or d2 < best_d2 then
											best, best_d2, best_dx, best_dy = objs[j], d2, dx, dy
										end
									end
								end
								decor_log(string.format(
									"  site %s%02d %s %s target=(%d,%d) nearest=%s delta=(%s,%s)",
									s[1], s_i, s[2], tgt[1], tgt[2], tgt[3],
									best and tostring(best.class) or "none",
									tostring(best_dx), tostring(best_dy)))
							end
						end
					end
				end
				local werr = AsyncStringToFile("__DECOR_OUT__", table.concat(decor_lines, "\\n"))
				g_ParityDecorProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "markprobe" argument.  Iteration 035 named the pass that
# decides the ten underground residue sites: `remove_overlapping_object`
# (RandomMapGenerator.lua:2708-2721) inside `Proc_RemoveOverlappedObjects`, on BOTH twins.  Its
# whole decision is `GridGetMark(mark_grid, obj) ~= obj_can_rem[obj] and obj_to_mark[obj]`, gated
# by `placed_objects[obj]` - all locals/upvalues of that closure.  This block reaches them from
# the DoneObject wrapper with debug.getinfo + debug.getupvalue at the first watched destruction on
# each map (the mark grid is freed only at :2894) and then, in that one moment, reports:
#   * every size the generator's grid sizing can key off (map:GetMapSize, mapdata.Width/Height,
#     map.Width/hex_width and the mod's SuperBigMapExpanded* backing extents), work_step, and the
#     mark grid's own dimensions;
#   * whether the NATIVE reader GridGetMark agrees with a Lua-side sample of the same grid taken
#     in the generator's source view (pos / work_step) or in the physical backing's view
#     (pos * grid_w / backing_world_w), counted over up to 3000 placed objects - the expanded
#     underground generates on the physically 8192-wide backing while every Lua-facing size reads
#     6144 (Code/sbm_map_generation.lua:9604-9628), so a native reader keyed off the backing size
#     quantizes marks 4/3 coarser and flips exactly the marginal objects;
#   * the nonzero-mark bounding box (stride scan), which shows directly whether the rasterizer
#     wrote marks across the whole grid or only its lower 3/4;
#   * per residue site, every decision input for each object within SITE_R plus the 3x3
#     mark neighbourhood around its cell.
# Identical Lua runs on BOTH twins.  It is read-only: no object is created or destroyed, no map
# RNG is consumed, no generation input changes; inertness is proven by a byte-identical dump.
MARK_PROBE_BLOCK = """		do
			local mark_lines = {}
			local mark_dropped = 0
			local function mark_ticks()
				if type(GetPreciseTicks) == "function" then return GetPreciseTicks() end
				return 0
			end
			local mark_t0 = mark_ticks()
			local function mark_log(text)
				if #mark_lines >= 40000 then
					mark_dropped = mark_dropped + 1
					return
				end
				mark_lines[#mark_lines + 1] = string.format(
					"[%7sms][%s] %s", tostring(mark_ticks() - mark_t0),
					tostring(rawget(_G, "g_ParityStatus")), tostring(text))
			end
			g_ParityMarkLines = mark_lines
			g_ParityMarkProbeStatus = "running"

			local WATCHED = {
				RemovableRocks_01 = true, RemovableRocks_02 = true,
				Rocks_04 = true, SoundSource = true,
			}
			-- The ten residue sites in SOURCE (vanilla) coordinates; generation-time positions are
			-- pre-stretch on both twins (iteration 035).  "E" = kept by the expanded twin only,
			-- "V" = kept by the vanilla twin only.
			local SITES = {
				{"E", "Rocks_04", 169118, 305372},
				{"E", "SoundSource", 401972, 340705},
				{"E", "RemovableRocks_02", 271913, 343717},
				{"E", "RemovableRocks_02", 272833, 373485},
				{"E", "RemovableRocks_02", 288823, 385739},
				{"V", "SoundSource", 154540, 196242},
				{"V", "SoundSource", 336786, 397864},
				{"V", "RemovableRocks_02", 346164, 337898},
				{"V", "RemovableRocks_02", 164909, 387965},
				{"V", "RemovableRocks_01", 144912, 386496},
			}
			local SITE_R = 600

			local function mark_map_of(obj)
				if type(obj) ~= "table" or type(obj.GetMap) ~= "function" then return nil end
				local ok, m = pcall(obj.GetMap, obj)
				if ok then return m end
				return nil
			end
			local function mark_env(map)
				if not map then return "nomap" end
				local md = map.mapdata
				return string.format("%s#%s/%s", tostring(md and md.Environment or "?"),
					tostring(map.slot), tostring(md and md.Width or "?"))
			end
			-- `placed_objects` keeps entries the removal pass has already destroyed; calling GetPos
			-- or GridGetMark on one raises a NATIVE "Expected luaGameObject" error that the Lua
			-- pcall cannot suppress from the game log, so validity is checked first.
			local function mark_live(obj)
				if type(obj) ~= "table" then return false end
				local isv = rawget(_G, "IsValid")
				if type(isv) == "function" then
					local ok, live = pcall(isv, obj)
					if not ok or live ~= true then return false end
				end
				return true
			end
			local function mark_xy(obj)
				if not mark_live(obj) or type(obj.GetPos) ~= "function" then return nil end
				local ok, x, y = pcall(function()
					local p = obj:GetPos()
					return p:x(), p:y()
				end)
				if ok and type(x) == "number" and type(y) == "number" then return x, y end
				return nil
			end
			local function mark_grid_size(grid)
				if grid == nil or grid == false then return nil end
				local ok, w, h = pcall(function() return grid:size() end)
				if ok and type(w) == "number" and type(h) == "number" then return w, h end
				return nil
			end
			local function mark_cell(v, step)
				if type(v) ~= "number" or type(step) ~= "number" or step <= 0 then return nil end
				return math.floor(v / step)
			end

			-- Walk the Lua stack for the frame that owns `mark_grid` (remove_overlapping_object is
			-- a closure inside DoGenerate, so the grid arrives as an upvalue).  Requires a USABLE
			-- grid: the IsOutsider cull also calls DoneObject, long before apply_terrain creates it.
			local function mark_find_upvalues()
				for level = 2, 8 do
					local ok, info = pcall(debug.getinfo, level, "fn")
					if not ok or type(info) ~= "table" then break end
					local f = info.func
					if type(f) == "function" then
						local ups, names, i = {}, {}, 1
						while true do
							local ok2, name, value = pcall(debug.getupvalue, f, i)
							if not ok2 or type(name) ~= "string" then break end
							ups[name] = value
							names[#names + 1] = name
							i = i + 1
						end
						if mark_grid_size(ups.mark_grid) then
							return ups, level, tostring(info.name), table.concat(names, ",")
						end
					end
				end
				return nil
			end

			local captured = {}
			local captures = 0
			local function mark_evaluate(ups, level, fname, upnames, obj_map, trigger)
				local grid = ups.mark_grid
				local gw, gh = mark_grid_size(grid)
				local const_t = rawget(_G, "const")
				local terrain_t = rawget(_G, "terrain")
				local type_tile
				if terrain_t and type(terrain_t.TypeTileSize) == "function" then
					local ok, v = pcall(terrain_t.TypeTileSize)
					type_tile = ok and v or nil
				end
				local work_ratio = const_t and const_t.PrefabWorkRatio or nil
				local work_step = (type(type_tile) == "number" and type(work_ratio) == "number")
					and (work_ratio * type_tile) or nil
				local md = obj_map and obj_map.mapdata
				local get_w, get_h
				if obj_map and type(obj_map.GetMapSize) == "function" then
					local ok, a, b = pcall(obj_map.GetMapSize, obj_map)
					if ok then get_w, get_h = a, b end
				end
				local backing_w = obj_map and obj_map.SuperBigMapExpandedWorldWidth or nil
				local backing_h = obj_map and obj_map.SuperBigMapExpandedWorldHeight or nil

				mark_log(string.format("CAPTURE #%d map=%s trigger=%s level=%s caller=%s",
					captures, mark_env(obj_map), tostring(trigger), tostring(level), tostring(fname)))
				mark_log("  upvalues: " .. tostring(upnames))
				mark_log(string.format(
					"  grid=%sx%s work_ratio=%s type_tile=%s work_step=%s lua_view_world=%s",
					tostring(gw), tostring(gh), tostring(work_ratio), tostring(type_tile),
					tostring(work_step),
					(gw and work_step) and tostring(gw * work_step) or "?"))
				mark_log(string.format(
					"  GetMapSize=%s,%s mapdata=%sx%s map.Width=%s,%s hex=%s,%s backing=%s,%s hexbacking=%s,%s",
					tostring(get_w), tostring(get_h),
					tostring(md and md.Width), tostring(md and md.Height),
					tostring(obj_map and obj_map.Width), tostring(obj_map and obj_map.Height),
					tostring(obj_map and obj_map.hex_width), tostring(obj_map and obj_map.hex_height),
					tostring(backing_w), tostring(backing_h),
					tostring(obj_map and obj_map.SuperBigMapExpandedHexWidth),
					tostring(obj_map and obj_map.SuperBigMapExpandedHexHeight)))

				local grid_get = function(cx, cy)
					if not gw or type(cx) ~= "number" or type(cy) ~= "number" then return nil end
					if cx < 0 or cy < 0 or cx >= gw or cy >= gh then return nil end
					local ok, v = pcall(function() return grid:get(cx, cy) end)
					if ok and type(v) == "number" then return v end
					return nil
				end
				local native_mark = function(obj)
					local getter = rawget(_G, "GridGetMark")
					if type(getter) ~= "function" or not mark_live(obj) then return nil end
					local ok, v = pcall(getter, grid, obj)
					if ok and type(v) == "number" then return v end
					return nil
				end

				-- Whole-grid nonzero extent: shows whether the rasterizer wrote across the entire
				-- grid or only the part the physical backing's scale would reach.
				local stride = 8
				local ok_scan, sx0, sy0, sx1, sy1, hits, scanned, gmax = pcall(function()
					local x0, y0, x1, y1, n, total, mx = nil, nil, nil, nil, 0, 0, 0
					for cy = 0, (gh or 1) - 1, stride do
						for cx = 0, (gw or 1) - 1, stride do
							total = total + 1
							local v = grid:get(cx, cy)
							if type(v) == "number" and v ~= 0 then
								n = n + 1
								if v > mx then mx = v end
								if not x0 or cx < x0 then x0 = cx end
								if not x1 or cx > x1 then x1 = cx end
								if not y0 or cy < y0 then y0 = cy end
								if not y1 or cy > y1 then y1 = cy end
							end
						end
					end
					return x0, y0, x1, y1, n, total, mx
				end)
				if ok_scan then
					mark_log(string.format(
						"  nonzero stride=%d cells=%s/%s bbox=(%s,%s)-(%s,%s) max_mark=%s frac_x=%s",
						stride, tostring(hits), tostring(scanned), tostring(sx0), tostring(sy0),
						tostring(sx1), tostring(sy1), tostring(gmax),
						(sx1 and gw) and tostring(math.floor(1000 * (sx1 + 1) / gw)) or "?"))
				else
					mark_log("  nonzero scan failed: " .. tostring(sx0))
				end

				-- Which view does the NATIVE reader use?  Counted over the pass's own object list.
				-- The cell offset is swept because the Lua grid accessor's index base is not
				-- documented here: a wrong base would make BOTH views disagree and prove nothing.
				local placed = ups.placed_objects
				local back_step = (backing_w and gw) and (backing_w / gw) or nil
				local function count_view(offset, budget)
					local agree_src, agree_back, agree_both, agree_none, sampled = 0, 0, 0, 0, 0
					if type(placed) ~= "table" then return sampled end
					for i = 1, #placed do
						if sampled >= budget then break end
						local o = placed[i]
						local x, y = mark_xy(o)
						if x then
							local nm = native_mark(o)
							if nm then
								sampled = sampled + 1
								local cx, cy = mark_cell(x, work_step), mark_cell(y, work_step)
								local src = (cx and grid_get(cx + offset, cy + offset)) or nil
								local bck = nil
								if back_step then
									local bx, by = mark_cell(x, back_step), mark_cell(y, back_step)
									bck = bx and grid_get(bx + offset, by + offset) or nil
								end
								local a = (src ~= nil and src == nm)
								local b = (bck ~= nil and bck == nm)
								if a and b then agree_both = agree_both + 1
								elseif a then agree_src = agree_src + 1
								elseif b then agree_back = agree_back + 1
								else agree_none = agree_none + 1 end
							end
						end
					end
					mark_log(string.format(
						"  reader view offset=%+d: sampled=%d src_only=%d backing_only=%d both=%d "
						.. "neither=%d", offset, sampled, agree_src, agree_back, agree_both,
						agree_none))
					return sampled
				end
				mark_log(string.format("  steps: src_step=%s backing_step=%s placed=%s",
					tostring(work_step), tostring(back_step),
					tostring(type(placed) == "table" and #placed or "?")))
				count_view(0, 3000)
				count_view(1, 600)
				count_view(-1, 600)

				-- Per-site decision inputs, evaluated for every object still near the site.
				local obj_to_mark, obj_can_rem = ups.obj_to_mark, ups.obj_can_rem
				for s_i = 1, #SITES do
					local s = SITES[s_i]
					local found = 0
					if type(placed) == "table" then
						for i = 1, #placed do
							local o = placed[i]
							local x, y = mark_xy(o)
							if x then
								local dx, dy = x - s[3], y - s[4]
								if dx < 0 then dx = -dx end
								if dy < 0 then dy = -dy end
								if dx <= SITE_R and dy <= SITE_R then
									found = found + 1
									local nm = native_mark(o)
									local csx, csy = mark_cell(x, work_step), mark_cell(y, work_step)
									local cbx, cby = nil, nil
									if back_step then
										cbx, cby = mark_cell(x, back_step), mark_cell(y, back_step)
									end
									local valid = rawget(_G, "IsValid")
									local is_valid = type(valid) == "function" and valid(o) or "?"
									mark_log(string.format(
										"  SITE %s%02d %s (%d,%d) obj=%s pos=(%s,%s) valid=%s "
										.. "placed=%s can_rem=%s obj_to_mark=%s native_mark=%s "
										.. "src_cell=(%s,%s)=%s backing_cell=(%s,%s)=%s",
										s[1], s_i, s[2], s[3], s[4], tostring(o.class),
										tostring(x), tostring(y), tostring(is_valid),
										tostring(type(placed) == "table" and placed[o] or "?"),
										tostring(obj_can_rem and obj_can_rem[o]),
										tostring(obj_to_mark and obj_to_mark[o]), tostring(nm),
										tostring(csx), tostring(csy), tostring(grid_get(csx, csy)),
										tostring(cbx), tostring(cby),
										cbx and tostring(grid_get(cbx, cby)) or "-"))
									local rows = {}
									for oy = -1, 1 do
										local row = {}
										for ox = -1, 1 do
											row[#row + 1] = tostring(grid_get(
												csx and (csx + ox), csy and (csy + oy)))
										end
										rows[#rows + 1] = table.concat(row, ",")
									end
									mark_log("      src 3x3 marks: " .. table.concat(rows, " | "))
								end
							end
						end
					end
					if found == 0 then
						mark_log(string.format("  SITE %s%02d %s (%d,%d) no placed object within %d",
							s[1], s_i, s[2], s[3], s[4], SITE_R))
					end
				end
			end

			local function mark_site(x, y)
				if type(x) ~= "number" or type(y) ~= "number" then return nil end
				for i = 1, #SITES do
					local s = SITES[i]
					local dx, dy = x - s[3], y - s[4]
					if dx < 0 then dx = -dx end
					if dy < 0 then dy = -dy end
					if dx <= SITE_R and dy <= SITE_R then
						return string.format("%s%02d:%s(%d,%d)", s[1], i, s[2], s[3], s[4])
					end
				end
				return nil
			end

			local site_hits = 0
			local function mark_note_destroy(obj)
				local cls = type(obj) == "table" and obj.class
				if not cls or not WATCHED[cls] then return end
				local obj_map = mark_map_of(obj)
				local key = mark_env(obj_map)
				-- Re-read the upvalues on EVERY call: apply_terrain reassigns `mark_grid` for the
				-- second (non-mark-only) pass and :2894 sets it false, so a cached grid handle
				-- could be stale by the time delete_on_steep_slope runs.
				local ups, level, fname, upnames = mark_find_upvalues()
				if not ups then return end
				if not captured[key] then
					captured[key] = true
					captures = captures + 1
					local x, y = mark_xy(obj)
					local okv, err = pcall(mark_evaluate, ups, level, fname, upnames, obj_map,
						string.format("%s at (%s,%s)", tostring(cls), tostring(x), tostring(y)))
					if not okv then mark_log("EVALUATION FAILED: " .. tostring(err)) end
				end
				-- Per-destruction record for the residue sites: the two numbers the pass compares.
				local x, y = mark_xy(obj)
				local site = mark_site(x, y)
				if not site then return end
				site_hits = site_hits + 1
				local getter = rawget(_G, "GridGetMark")
				local nm
				if type(getter) == "function" and mark_live(obj) then
					local okm, v = pcall(getter, ups.mark_grid, obj)
					nm = okm and v or nil
				end
				mark_log(string.format(
					"DESTROY %s %s pos=(%s,%s) caller=%s native_mark=%s obj_to_mark=%s can_rem=%s SITE=%s",
					key, tostring(cls), tostring(x), tostring(y), tostring(fname), tostring(nm),
					tostring(ups.obj_to_mark and ups.obj_to_mark[obj]),
					tostring(ups.obj_can_rem and ups.obj_can_rem[obj]), site))
			end

			local our_wrapper
			local function mark_wrap_done()
				local original = rawget(_G, "DoneObject")
				if type(original) ~= "function" or original == our_wrapper then return false end
				our_wrapper = function(obj, ...)
					pcall(mark_note_destroy, obj)
					return original(obj, ...)
				end
				_G.DoneObject = our_wrapper
				return true
			end
			mark_log(mark_wrap_done() and "wrapped DoneObject" or "DoneObject unavailable")

			CreateRealTimeThread(function()
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					if mark_wrap_done() then mark_log("DoneObject was REPLACED; re-wrapped") end
					if status == "complete" or status == "error" then break end
					Sleep(300)
				end
				mark_log(string.format("SUMMARY captures=%d site_hits=%d dropped_lines=%d",
					captures, site_hits, mark_dropped))
				local werr = AsyncStringToFile("__MARK_OUT__", table.concat(mark_lines, "\\n"))
				g_ParityMarkProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "passprobe" argument.  The surface generator is proven
# deterministic (iter-001b: identical at all 49 procedure boundaries) and every seed the harness
# controls is pinned, yet controls still land on two variants that differ only by the SECOND
# underground passage's site and the decor its ClearObjObstructions destroys.  The site is chosen
# by FindPassageSpawnPos (Lua/Buildings/SurfacePassage.lua:67-124), whose retry loop falls back to
# GetRandomPassableAroundOnMap / GetRandomPassable (Lua/Pathfinding.lua:163-170, :1-6) - both of
# which draw from SessionRandom, a session-wide stream, NOT from the map generator's rand.  The
# seed of that stream is already pinned (gen_template.lua:54-57), so what can still differ is the
# stream's POSITION at the moment of the call, or whether the fallback is reached at all.
# This block wraps the four globals on that path and records, per call, the arguments, the result
# and the SessionRandom cursor (rand_state:Last()) before and after; a sampler thread additionally
# logs every cursor movement it observes during generation, which names any OTHER consumer that
# shifts the stream.  Diffing a variant-A log against a variant-B log therefore names the first
# call that diverges.  The wrappers are pass-through: they consume no rand, create and destroy
# nothing, and change no generation input.
PASSAGE_PROBE_BLOCK = """		do
			local pass_lines = {}
			local pass_dropped = 0
			local function pass_log(text)
				if #pass_lines >= 40000 then
					pass_dropped = pass_dropped + 1
					return
				end
				pass_lines[#pass_lines + 1] = tostring(text)
			end
			g_ParityPassProbeStatus = "running"

			-- The session stream's cursor.  GameRandom keeps its state in rand_state
			-- (Lua/GameRandom.lua:1-12); rand_state:Last() is the same accessor the procedure
			-- trace uses on the generator's rand, and reading it consumes nothing.
			local function sr_last()
				local sr = rawget(_G, "SessionRandom")
				local v = "unavailable"
				pcall(function() v = tostring(sr.rand_state:Last()) end)
				return v
			end

			local function pass_pt(p)
				if p == nil then return "nil" end
				local ok, text = pcall(function()
					local x, y, z = p:xyz()
					return string.format("(%s,%s,%s)", tostring(x), tostring(y), tostring(z))
				end)
				if ok then return text end
				local ok2, text2 = pcall(function()
					local x, y = p:xy()
					return string.format("(%s,%s)", tostring(x), tostring(y))
				end)
				if ok2 then return text2 end
				return tostring(p)
			end

			local calls = 0
			local function pass_wrap(name, describe)
				local original = rawget(_G, name)
				if type(original) ~= "function" then
					pass_log("MISSING " .. name)
					return
				end
				_G[name] = function(...)
					calls = calls + 1
					local n = calls
					local before = sr_last()
					-- `...` cannot cross into the pcall closure, so pack once and reuse the
					-- same argument list for the description and for the real call.
					local argv = table.pack(...)
					local args = "?"
					pcall(function() args = describe(table.unpack(argv, 1, argv.n)) end)
					pass_log(string.format("CALL #%04d %-30s sr=%s %s", n, name, before, args))
					-- table.pack/unpack with an explicit count so a nil first result (the
					-- "no site found" case, which is exactly what we are hunting) still returns
					-- the same arity the caller would have seen without the wrapper.
					local results = table.pack(original(table.unpack(argv, 1, argv.n)))
					pass_log(string.format("RET  #%04d %-30s sr=%s -> %s", n, name, sr_last(),
						pass_pt(results[1])))
					return table.unpack(results, 1, results.n)
				end
			end

			pass_wrap("SpawnUndergroundPassage", function(map, pos, angle, min_dist, passages)
				return string.format("pos=%s angle=%s min_dist=%s placed=%d", pass_pt(pos),
					tostring(angle), tostring(min_dist), #(passages or ""))
			end)
			pass_wrap("FindPassageSpawnPos", function(map, ohg, buildable, pos, angle, shape, min_dist, passages)
				return string.format("pos=%s angle=%s min_dist=%s placed=%d", pass_pt(pos),
					tostring(angle), tostring(min_dist), #(passages or ""))
			end)
			pass_wrap("GetRandomPassableAroundOnMap", function(map, center, max_radius, min_radius, random)
				return string.format("center=%s max_r=%s min_r=%s own_random=%s", pass_pt(center),
					tostring(max_radius), tostring(min_radius), tostring(random ~= nil))
			end)
			pass_wrap("GetRandomPassable", function(map)
				return "map=" .. tostring(map and map.mapdata and map.mapdata.Environment)
			end)

			-- Any cursor movement NOT bracketed by the wrappers above is another consumer of the
			-- session stream, which is the mechanism that would defeat a seed-only pin.
			CreateRealTimeThread(function()
				local seen = sr_last()
				pass_log(string.format("START g_SessionSeed=%s sr=%s",
					tostring(rawget(_G, "g_SessionSeed")), seen))
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					local now = sr_last()
					if now ~= seen then
						pass_log(string.format("MOVE  sr %s -> %s (status=%s)", seen, now, status))
						seen = now
					end
					if status == "complete" or status == "error" then break end
					Sleep(50)
				end
				pass_log(string.format("SUMMARY calls=%d final_sr=%s dropped_lines=%d",
					calls, sr_last(), pass_dropped))
				local werr = AsyncStringToFile("__PASS_OUT__", table.concat(pass_lines, "\\n"))
				g_ParityPassProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "drawprobe" argument.  The passage probe (passprobe,
# artifacts/passage_probe_verdict.md) proved the 45S82E variant split is ONE SessionRandom draw
# made during generation, before any passage call: all runs start at the pinned cursor, take the
# same first draw, then land on different values on the NEXT move, after which the passage
# fallback (FindPassageSpawnPos L119) merely converts the shifted cursor into a different site.
# Wrapping the CALLERS therefore cannot name the culprit; this block wraps the DRAW.  It replaces
# the SessionRandom instance's Random with a pass-through that logs, per call, the arguments, the
# cursor before/after, the returned value and a one-line stack traceback naming the consumer
# (GameRandom:TableRand routes through Random, so a single wrap covers both entry points).
# A 50 ms thread additionally re-installs the wrapper whenever the instance is replaced (it is
# rebuilt from the pinned seed at map change) and reports any cursor movement NOT attributable to
# a wrapped draw, which is exactly the signature of a consumer reaching rand_state directly.
# It is pass-through: it consumes no rand, creates and destroys nothing, changes no input.
DRAW_PROBE_BLOCK = """		do
			local draw_lines = {}
			local draw_dropped = 0
			local function draw_log(text)
				if #draw_lines >= 40000 then
					draw_dropped = draw_dropped + 1
					return
				end
				draw_lines[#draw_lines + 1] = tostring(text)
			end
			g_ParityDrawProbeStatus = "running"

			-- rand_state:Last() is the cursor accessor the procedure and passage probes already
			-- use; reading it consumes nothing.
			local function draw_last(sr)
				local v = "unavailable"
				pcall(function() v = tostring(sr.rand_state:Last()) end)
				return v
			end

			-- One line per traceback: the consumer's identity is the frame list, and a
			-- multi-line dump would make the variant-A vs variant-B diff unreadable.
			-- Level 3 starts the trace at the CALLER of the wrapper (1 = this function,
			-- 2 = the wrapper itself).
			local function draw_where()
				if type(debug) ~= "table" or type(debug.traceback) ~= "function" then
					return "no debug.traceback"
				end
				local tb = tostring(debug.traceback("", 3))
				tb = tb:gsub("stack traceback:", "")
				tb = tb:gsub("%s+", " ")
				if #tb > 600 then tb = tb:sub(1, 600) .. " ..." end
				return tb
			end

			local draws = 0
			local installs = 0
			local last_known = false

			local function draw_install()
				local sr = rawget(_G, "SessionRandom")
				if type(sr) ~= "table" then return false end
				if rawget(sr, "ParityDrawWrapped") then return false end
				-- Resolves to GameRandom.Random through the instance metatable; taking it per
				-- install keeps a re-wrap after the map change correct.
				local original = sr.Random
				if type(original) ~= "function" then return false end
				rawset(sr, "ParityDrawWrapped", true)
				rawset(sr, "Random", function(self, min, max)
					draws = draws + 1
					local n = draws
					local before = draw_last(self)
					local value = original(self, min, max)
					local after = draw_last(self)
					last_known = after
					draw_log(string.format("DRAW #%05d %-20s min=%s max=%s sr %s -> %s = %s",
						n, tostring(rawget(_G, "g_ParityStatus")), tostring(min), tostring(max),
						before, after, tostring(value)))
					draw_log("   at " .. draw_where())
					return value
				end)
				installs = installs + 1
				last_known = draw_last(sr)
				draw_log(string.format("INSTALL #%d g_SessionSeed=%s sr=%s status=%s",
					installs, tostring(rawget(_G, "g_SessionSeed")), last_known,
					tostring(rawget(_G, "g_ParityStatus"))))
				return true
			end

			if not draw_install() then
				draw_log("INSTALL failed: SessionRandom unavailable or already wrapped")
			end

			CreateRealTimeThread(function()
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					draw_install()
					local sr = rawget(_G, "SessionRandom")
					if type(sr) == "table" then
						local now = draw_last(sr)
						if now ~= last_known then
							draw_log(string.format("UNWRAPPED sr %s -> %s (status=%s)",
								tostring(last_known), now, status))
							last_known = now
						end
					end
					if status == "complete" or status == "error" then break end
					Sleep(50)
				end
				draw_log(string.format("SUMMARY draws=%d installs=%d dropped_lines=%d",
					draws, installs, draw_dropped))
				local werr = AsyncStringToFile("__DRAW_OUT__", table.concat(draw_lines, "\\n"))
				g_ParityDrawProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "proctrace" argument.  Localizes vanilla's residual draw
# race (two identical serial vanilla runs at 45S82E differ by 34 rows) to ONE generator
# procedure.  RandomMapGenerator brackets every procedure with the public ProcStart/ProcEnd
# pair (Lua/RandomMap/RandomMapGenerator.lua:948-994, invoked from ProcInvoke:1109) and each
# procedure re-seeds the shared rand_state from xxhash(Seed, tag), so a divergence is confined
# to the procedure that produced it.  This block wraps those two class methods plus DoGenerate
# (to learn which map is generating, and to skip the underground one), and at every procedure
# END records for the surface map:
#   * the full per-class census and total object count;
#   * the shared rand_state cursor (rand_state:Last()), which shows a differing number of
#     consumed rands even when the object census still agrees;
#   * every object inside a box around the contested slate cluster at (211056,169078)
#     (class|x|y|z|scale|angle, sorted), which is the population that flips between variants.
# Diffing two runs' logs by ordinal therefore names the FIRST procedure whose output differs.
# It is read-only: no object is created or destroyed, no map RNG is consumed, no generation
# input changes.  It does allocate, so it can perturb timing - which is itself informative if
# two instrumented runs stop wobbling.
PROC_TRACE_BLOCK = """		do
			local trace_lines = {}
			local trace_dropped = 0
			local function trace_log(text)
				if #trace_lines >= 60000 then
					trace_dropped = trace_dropped + 1
					return
				end
				trace_lines[#trace_lines + 1] = tostring(text)
			end
			g_ParityProcTraceStatus = "running"

			local SITE_X, SITE_Y, SITE_HALF = 211056, 169078, 4000
			local trace_map = false
			local ordinal = 0

			-- One capture walks every object on the map, so this stays allocation-free: it
			-- pcalls the methods directly instead of building a closure per object.
			local function trace_xy(obj)
				local getter = type(obj) == "table" and obj.GetPos
				if type(getter) ~= "function" then return nil, nil end
				local ok, pos = pcall(getter, obj)
				if not ok or not pos then return nil, nil end
				local okxy, x, y = pcall(pos.xy, pos)
				if not okxy then return nil, nil end
				return x, y
			end

			local function trace_tuple(obj, cls, x, y)
				local ok, text = pcall(function()
					local z = "novalidz"
					pcall(function() z = tostring(obj:GetPos():z()) end)
					return string.format("%s|%d|%d|%s|%s|%s", tostring(cls), x, y, z,
						tostring(obj:GetScale()), tostring(obj:GetAngle()))
				end)
				if ok then return text end
				return string.format("%s|%d|%d|error", tostring(cls), x, y)
			end

			local function trace_capture(tag, phase, gen)
				local map = trace_map
				if not map then return end
				local objs = map:MapGet("map") or {}
				local counts, site = {}, {}
				for i = 1, #objs do
					local obj = objs[i]
					local cls = obj and obj.class or "?"
					counts[cls] = (counts[cls] or 0) + 1
					local x, y = trace_xy(obj)
					if x and y and x >= SITE_X - SITE_HALF and x <= SITE_X + SITE_HALF
						and y >= SITE_Y - SITE_HALF and y <= SITE_Y + SITE_HALF then
						site[#site + 1] = trace_tuple(obj, cls, x, y)
					end
				end
				local names = {}
				for cls in pairs(counts) do names[#names + 1] = cls end
				table.sort(names)
				local census = {}
				for _, cls in ipairs(names) do
					census[#census + 1] = tostring(cls) .. "=" .. tostring(counts[cls])
				end
				table.sort(site)
				local rs = "unavailable"
				pcall(function() rs = tostring(gen.rand_state:Last()) end)
				trace_log(string.format("#%04d %-5s %-46s objs=%6d classes=%4d rand_last=%s site=%d",
					ordinal, tostring(phase), tostring(tag), #objs, #names, rs, #site))
				trace_log("  census " .. table.concat(census, " "))
				for i = 1, #site do trace_log("  site " .. site[i]) end
			end

			local gen_class = rawget(_G, "RandomMapGenerator")
			if type(gen_class) ~= "table" then
				error("RandomMapGenerator class unavailable for the procedure trace")
			end
			local saved_start, saved_end = gen_class.ProcStart, gen_class.ProcEnd
			local saved_do = gen_class.DoGenerate
			if type(saved_start) ~= "function" or type(saved_end) ~= "function"
				or type(saved_do) ~= "function" then
				error("generator procedure boundary API unavailable for the procedure trace")
			end

			gen_class.ProcStart = function(self, tag, ...)
				if trace_map and ordinal == 0 then
					ordinal = 1
					pcall(trace_capture, "<baseline>", "begin", self)
				end
				return saved_start(self, tag, ...)
			end
			gen_class.ProcEnd = function(self, tag, ...)
				local a, b, c = saved_end(self, tag, ...)
				if trace_map then
					ordinal = ordinal + 1
					pcall(trace_capture, tag, "end", self)
				end
				return a, b, c
			end
			gen_class.DoGenerate = function(self, map, ...)
				local mapdata = type(map) == "table" and map.mapdata or nil
				local env = type(mapdata) == "table" and mapdata.Environment or "?"
				if env ~= "Underground" then
					trace_map = map
					trace_log(string.format("DOGENERATE env=%s seed=%s width=%s",
						tostring(env), tostring(type(self) == "table" and self.Seed or "?"),
						tostring(mapdata and mapdata.Width or "?")))
				end
				local a, b, c = saved_do(self, map, ...)
				trace_map = false
				trace_log("DOGENERATE returned, boundaries=" .. tostring(ordinal))
				return a, b, c
			end

			CreateRealTimeThread(function()
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					if status == "complete" or status == "error" then break end
					Sleep(300)
				end
				gen_class.ProcStart, gen_class.ProcEnd = saved_start, saved_end
				gen_class.DoGenerate = saved_do
				trace_log(string.format("SUMMARY boundaries=%d dropped_lines=%d",
					ordinal, trace_dropped))
				local werr = AsyncStringToFile("__PROC_OUT__", table.concat(trace_lines, "\\n"))
				g_ParityProcTraceStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "playprobe" argument.  Iteration 008 localized b2-01's control
# race to ONE generator procedure: two identical vanilla processes agree on every boundary up to
# and including #0004 `FindPrefabPos_Border` (same `rand_state:Last()`) and first disagree at
# #0005 `FindPrefabPos_Playable`, i.e. they consume a DIFFERENT NUMBER OF DRAWS inside
# `Proc_FindPrefabPos_Playable` (Lua/RandomMap/RandomMapGenerator.lua:1639-1760) while no object
# exists yet.  This block names the varying input by tracing that procedure's whole call sequence.
#
# It arms only between `ProcStart("FindPrefabPos_Playable")` and its `ProcEnd` on the SURFACE map
# (both are public class methods; `DoGenerate` tells which map is generating), and records:
#   * at arm time: `#PrefabMarkers`, `AssetsRevision`, and an ordered digest of every marker's
#     name/type/radii/weight/revision/version/group tags - which decides outright whether the
#     prefab set itself differs between the two processes (contract lead 3, async asset load);
#   * one ordinal-numbered line per call to the globals the procedure uses, with an xxhash
#     fingerprint of every grid argument taken AFTER the call plus the scalar returns.  The
#     wrapped set covers the three ways this procedure can diverge:
#       - grid CONTENT arriving from earlier procedures (equal draw counts do NOT prove equal
#         grids): `GridDistanceMars`, `GridMinMax`, `GridEquals`, `GridMask`, `GridAnd/Or/Not`;
#       - prefab list content: `PrefabFilter`;
#       - the draws themselves: `table.weighted_rand` (trand), `GridStableRandomPosSimple` /
#         `GridStableRandomPos` (grand), logged with the seed they were handed and the index or
#         position they returned;
#       - composition ORDER inside `similar_apply`, which folds one `similar_grids[tag]` per
#         `pairs(prefab.group_tags)` into the candidate zone with `GridMulDivAdd`: integer
#         rounding makes that fold order-sensitive, so the same set of sgrid hashes appearing in
#         a different ORDER between the two runs is a direct signature of hash-order variation.
#         `Proc_FindPrefabPos_Border` (#0004, which agrees) never calls `similar_apply`.
# Read-only: it creates nothing, destroys nothing and consumes no map RNG - it only hashes grids
# and returns every wrapped call's own results unchanged.  Like every wrapper it costs time, so
# two probed runs landing on the same variant is itself informative rather than a result.
PLAY_PROBE_BLOCK = """		do
			local play_lines = {}
			local play_dropped = 0
			local function play_log(text)
				if #play_lines >= 60000 then
					play_dropped = play_dropped + 1
					return
				end
				play_lines[#play_lines + 1] = tostring(text)
			end
			g_ParityPlayProbeStatus = "running"

			local PLAY_PROC = "FindPrefabPos_Playable"
			local armed = false
			local ordinal = 0
			local play_surface = false

			local function ghash(v)
				if not IsComputeGrid(v) then return nil end
				local ok, h = pcall(xxhash, v)
				if ok then return tostring(h) end
				return "hasherr"
			end

			local function vdesc(v)
				local h = ghash(v)
				if h then return "grid:" .. h end
				local t = type(v)
				if t == "table" then
					local ok, n = pcall(function() return #v end)
					return "table#" .. (ok and tostring(n) or "?")
				end
				if t == "userdata" then
					-- Points print as point(x,y[,z]); anything whose text carries an address is
					-- process-varying noise and must never reach the diff.
					local ok, s = pcall(tostring, v)
					if ok and not string.find(s, "0x", 1, true) then return s end
					return "userdata"
				end
				if t == "function" or t == "thread" then return t end
				return tostring(v)
			end

			-- Grid arguments are hashed AFTER the call, so an in-place op's result is what lands
			-- in the log; that is the point - the fingerprint of what the procedure actually saw.
			local function argdesc(n, ...)
				local parts = {}
				for i = 1, n do
					parts[#parts + 1] = string.format("a%d=%s", i, vdesc((select(i, ...))))
				end
				return table.concat(parts, " ")
			end

			local function marker_digest()
				local list = rawget(_G, "PrefabMarkers")
				if type(list) ~= "table" then return "nomarkers", -1 end
				local parts = {}
				for i = 1, #list do
					local m = list[i]
					local tags = {}
					local gt = type(m) == "table" and rawget(m, "group_tags")
					if type(gt) == "table" then
						for tag in pairs(gt) do tags[#tags + 1] = tostring(tag) end
						table.sort(tags)
					end
					parts[#parts + 1] = string.format("%s|%s|%s|%s|%s|%s|%s|%s",
						tostring(list[m]), tostring(m.type), tostring(m.max_radius),
						tostring(m.min_radius), tostring(m.weight), tostring(m.revision),
						tostring(m.version), table.concat(tags, ","))
				end
				local ok, h = pcall(xxhash, table.concat(parts, ";"))
				return ok and tostring(h) or "hasherr", #list
			end

			local function list_digest(res)
				if type(res) ~= "table" then return tostring(res), -1 end
				local list = rawget(_G, "PrefabMarkers")
				local parts = {}
				for i = 1, #res do
					local m = res[i]
					local name = type(list) == "table" and list[m] or nil
					parts[#parts + 1] = tostring(name or (type(m) == "table" and m.type) or m)
				end
				local ok, h = pcall(xxhash, table.concat(parts, ";"))
				return ok and tostring(h) or "hasherr", #res
			end

			local wrapped = {}
			local function wrap_global(name)
				local saved = rawget(_G, name)
				if type(saved) ~= "function" then
					play_log("MISSING global " .. name)
					return
				end
				wrapped[#wrapped + 1] = {name = name, fn = saved}
				_G[name] = function(...)
					if not armed then return saved(...) end
					local n = select("#", ...)
					local r1, r2, r3, r4 = saved(...)
					ordinal = ordinal + 1
					play_log(string.format("#%05d %-26s %s -> %s %s %s %s", ordinal, name,
						argdesc(n, ...), vdesc(r1), vdesc(r2), vdesc(r3), vdesc(r4)))
					return r1, r2, r3, r4
				end
			end

			for _, name in ipairs{
				"GridDistanceMars", "GridMinMax", "GridEquals", "GridMask", "GridAnd", "GridOr",
				"GridNot", "GridMulDivAdd", "GridMulAddScaled", "GridCircleSet", "GridCircleMax",
				"GridStableRandomPosSimple", "GridStableRandomPos",
			} do
				wrap_global(name)
			end

			-- PrefabFilter returns the candidate list itself; log its digest, not its address.
			local saved_filter = rawget(_G, "PrefabFilter")
			if type(saved_filter) ~= "function" then
				play_log("MISSING global PrefabFilter")
			else
				wrapped[#wrapped + 1] = {name = "PrefabFilter", fn = saved_filter}
				_G.PrefabFilter = function(...)
					if not armed then return saved_filter(...) end
					local res = saved_filter(...)
					local h, n = list_digest(res)
					ordinal = ordinal + 1
					play_log(string.format("#%05d %-26s n=%s digest=%s", ordinal,
						"PrefabFilter:result", tostring(n), h))
					return res
				end
			end

			-- trand's weighted pick: the seed it was handed and the index it returned decide the
			-- whole loop, so a divergence here with an equal candidate digest is a rand-stream
			-- shift, and one with a differing digest is a list-content difference.
			local saved_wrand = table.weighted_rand
			if type(saved_wrand) == "function" then
				table.weighted_rand = function(tbl, calc_weight, seed, ...)
					if not armed then return saved_wrand(tbl, calc_weight, seed, ...) end
					local res, idx = saved_wrand(tbl, calc_weight, seed, ...)
					local h, n = list_digest(tbl)
					local list = rawget(_G, "PrefabMarkers")
					local picked = type(list) == "table" and list[res] or nil
					ordinal = ordinal + 1
					play_log(string.format("#%05d %-26s n=%s digest=%s seed=%s -> idx=%s name=%s",
						ordinal, "table.weighted_rand", tostring(n), h, tostring(seed),
						tostring(idx), tostring(picked)))
					return res, idx
				end
			else
				play_log("MISSING table.weighted_rand")
			end

			local gen_class = rawget(_G, "RandomMapGenerator")
			if type(gen_class) ~= "table" then
				error("RandomMapGenerator class unavailable for the playable-procedure probe")
			end
			local saved_start, saved_end = gen_class.ProcStart, gen_class.ProcEnd
			local saved_do = gen_class.DoGenerate
			if type(saved_start) ~= "function" or type(saved_end) ~= "function"
				or type(saved_do) ~= "function" then
				error("generator procedure boundary API unavailable for the playable-procedure probe")
			end

			gen_class.ProcStart = function(self, tag, ...)
				if play_surface and tag == PLAY_PROC then
					local digest, count = marker_digest()
					local rs = "unavailable"
					pcall(function() rs = tostring(self.rand_state:Last()) end)
					play_log(string.format(
						"ARM proc=%s prefab_markers=%s assets_revision=%s marker_digest=%s rand_last=%s",
						tag, tostring(count), tostring(rawget(_G, "AssetsRevision")), digest, rs))
					armed = true
				end
				return saved_start(self, tag, ...)
			end
			gen_class.ProcEnd = function(self, tag, ...)
				if armed and tag == PLAY_PROC then
					armed = false
					local rs = "unavailable"
					pcall(function() rs = tostring(self.rand_state:Last()) end)
					play_log(string.format("DISARM proc=%s calls=%d rand_last=%s",
						tag, ordinal, rs))
				end
				return saved_end(self, tag, ...)
			end
			gen_class.DoGenerate = function(self, map, ...)
				local mapdata = type(map) == "table" and map.mapdata or nil
				local env = type(mapdata) == "table" and mapdata.Environment or "?"
				play_surface = env ~= "Underground"
				play_log(string.format("DOGENERATE env=%s surface=%s seed=%s", tostring(env),
					tostring(play_surface), tostring(type(self) == "table" and self.Seed or "?")))
				local a, b, c = saved_do(self, map, ...)
				play_surface = false
				armed = false
				return a, b, c
			end

			CreateRealTimeThread(function()
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					if status == "complete" or status == "error" then break end
					Sleep(300)
				end
				armed = false
				gen_class.ProcStart, gen_class.ProcEnd = saved_start, saved_end
				gen_class.DoGenerate = saved_do
				for i = 1, #wrapped do _G[wrapped[i].name] = wrapped[i].fn end
				if type(saved_wrand) == "function" then table.weighted_rand = saved_wrand end
				play_log(string.format("SUMMARY calls=%d dropped_lines=%d", ordinal, play_dropped))
				local werr = AsyncStringToFile("__PLAY_OUT__", table.concat(play_lines, "\\n"))
				g_ParityPlayProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


# Diagnostic only, opt-in with the "anomprobe" argument.  Iteration 017 left ONE sweep-01 residue
# cause unproven: vanilla keeps a `SubsurfaceAnomalyMarker` the expanded twin culls and vice versa,
# with the same final count on both maps.  Suspected mechanism: `City:InitBreakThroughAnomalies`
# (`Lua/Buildings/Anomaly.lua:652-682`) shuffles the `MapGet("map","SubsurfaceAnomalyMarker", ...)`
# list with a deterministic research rand and then `DoneObject()`s the tail, so an INPUT list whose
# enumeration order differs between the twins culls a different marker.  This block records, on both
# twins, the ordered marker list the initializer sees and the identities it destroys.
#
# Two call sites have to be covered because the mod DEFERS this one initializer on the expanded
# surface (`Code/sbm_map_generation.lua:8819-8905`): the class method fires at
# GenerateRandomMapsFinishing (pre-stretch, SOURCE coordinates, deferred to a no-op on the expanded
# twin) and `SuperBigMap.State.original_city_init_breakthrough_anomalies` fires later from
# `FinalizeDeferredBreakthroughAnomalyInitialization` (post-stretch, DESTINATION coordinates =
# source * 4/3).  The class wrap also claims the mod's `State.breakthrough_init_wrapper` identity so
# a later re-install of the mod patch takes its early-out instead of re-saving the probe as the
# "original" (which would defer forever).  Read-only otherwise: MapGet, IsValid and GetPos only, no
# object created or destroyed and no RNG consumed, so a probed run's dump must stay byte-identical
# to the same tag's unprobed dump.
# Opt-in with the "stretchdump" argument.  Turns on the mod's test-only height-grid dump seam
# (config `StretchHeightGridDumpPath`, empty and inert by default) for this run only, by writing
# the mod's own live config table before generation starts.  The seam writes the DESTINATION height
# grid twice - "<prefix>-<environment>-pre.raw" straight out of GridResample and "-post.raw" right
# after the Z transform - which is the only way to score `post == floor(pre*4/3) + shift` cell by
# cell offline: the engine's resample arithmetic is not reproducible outside the game, and by the
# end of generation the mod's later terrain edits (flatten pads, landing pit) have legitimately
# overwritten transformed ground.  It changes no transform, consumes no RNG and creates no object;
# it only writes files.
STRETCH_DUMP_BLOCK = """		do
			if type(SBM.Config) ~= "table" then
				error("SuperBigMap.Config unavailable; cannot arm the height grid dump seam")
			end
			SBM.Config.STRETCH_HEIGHT_GRID_DUMP_PATH = "__STRETCH_DUMP__"
		end"""

# Diagnostic only, opt-in with the "flattenprobe" argument.  iter-006 located, to the cell, a
# SECOND hexagonal Elevator-shape pad per underground passage, carved at the passage's
# UNTRANSFORMED vanilla pose and flattened to a SOURCE-space level (9.7 m and 33.0 m craters at
# 30S146E), absent from the post-Z-transform dump and therefore written by a later caller.
# Reading the mod's Lua could not name that caller (`prepare_passage_pad` verifies the anchor is
# already at the destination pose), so this block names it from the call itself.
#
# `FlattenTerrainInBuildShape` (Lua/Construction/Construction.lua:1842) is a plain global that
# forwards to the global `FlattenTerrainInShape` (:1870); wrapping BOTH records the outer call and
# the inner one it delegates to.  The flatten LEVEL is not an argument: the C op reads it from the
# buildable z_grid at the object's own hexes (the reference implementation kept in the comment at
# :1850 does exactly `buildable:GetZ(q+x, r+y)`), so the per-call facts that identify a stale pad
# are the object's pose, the identity of `map.buildable.z_grid`, the z that grid reports at the
# anchor hex, and whether the mod's source-space passage bridge
# (`map.SuperBigMapPendingNativeSurfacePassageBuildable`, sbm_map_generation.lua:5721-5789, which
# swaps a SOURCE-space buildable grid in for the native passage selection window) is installed at
# that moment.  A one-line traceback names the call site.
# The wrappers are pass-through: they forward every argument and result with an explicit arity,
# consume no rand, and create, destroy and move nothing; only reads (GetPos/GetAngle/GetMap/GetZ)
# are added.
FLATTEN_PROBE_BLOCK = """		do
			local fl_lines = {}
			local fl_dropped = 0
			local fl_calls = 0
			local function fl_log(text)
				if #fl_lines >= 20000 then
					fl_dropped = fl_dropped + 1
					return
				end
				fl_lines[#fl_lines + 1] = tostring(text)
			end
			local function fl_flush()
				local werr = AsyncStringToFile("__FLATTEN_OUT__", table.concat(fl_lines, "\\n"))
				g_ParityFlattenProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end
			g_ParityFlattenProbeStatus = "running"
			g_ParityFlattenProbeCalls = 0

			-- Level 3 starts the trace at the CALLER of the wrapper (1 = this function,
			-- 2 = the wrapper itself).  One line per call keeps the log diffable.
			local function fl_where()
				if type(debug) ~= "table" or type(debug.traceback) ~= "function" then
					return "no debug.traceback"
				end
				local tb = tostring(debug.traceback("", 3))
				tb = tb:gsub("stack traceback:", "")
				tb = tb:gsub("%s+", " ")
				if #tb > 700 then tb = tb:sub(1, 700) .. " ..." end
				return tb
			end

			local function fl_desc(obj)
				local out = { "obj=?" }
				pcall(function() out[1] = "obj=" .. tostring(obj.class) end)
				pcall(function()
					local p = obj:GetPos()
					local px, py, pz = p:xyz()
					out[#out + 1] = string.format("pos=%s,%s,%s",
						tostring(px), tostring(py), tostring(pz))
					local q, r = WorldToHex(p)
					out[#out + 1] = string.format("hex=%s,%s", tostring(q), tostring(r))
					local map = obj:GetMap()
					out[#out + 1] = "env=" .. tostring(map and map.mapdata and map.mapdata.Environment)
					out[#out + 1] = "mapw=" .. tostring(map and map.mapdata and map.mapdata.Width)
					out[#out + 1] = "zgrid=" .. tostring(map and map.buildable and map.buildable.z_grid)
					local bz = "?"
					pcall(function() bz = tostring(map.buildable:GetZ(q, r)) end)
					out[#out + 1] = "buildable_z=" .. bz
					out[#out + 1] = "bridge="
						.. tostring(map and map.SuperBigMapPendingNativeSurfacePassageBuildable ~= nil)
					out[#out + 1] = "angle=" .. tostring(obj:GetAngle())
				end)
				return table.concat(out, " ")
			end

			local function fl_wrap(name)
				local original = rawget(_G, name)
				if type(original) ~= "function" then
					fl_log("MISSING " .. name)
					return
				end
				_G[name] = function(...)
					fl_calls = fl_calls + 1
					g_ParityFlattenProbeCalls = fl_calls
					local n = fl_calls
					-- `...` cannot cross into a pcall closure, so pack once and reuse the same
					-- argument list for the description and for the real call.
					local argv = table.pack(...)
					local hexes = "?"
					pcall(function() hexes = tostring(#(argv[1] or "")) end)
					local desc = "?"
					pcall(function() desc = fl_desc(argv[2]) end)
					fl_log(string.format("CALL #%04d %-26s status=%s hexes=%s %s",
						n, name, tostring(rawget(_G, "g_ParityStatus")), hexes, desc))
					fl_log("   at " .. fl_where())
					local results = table.pack(original(table.unpack(argv, 1, argv.n)))
					local ret = "?"
					pcall(function() ret = tostring(results[1]) end)
					fl_log(string.format("RET  #%04d %-26s -> %s", n, name, ret))
					-- Flushing per call keeps the evidence on disk if the run dies mid-generation;
					-- a long tail of routine construction flattens throttles to every 50th.
					if n <= 200 or n % 50 == 0 then fl_flush() end
					return table.unpack(results, 1, results.n)
				end
			end

			fl_wrap("FlattenTerrainInBuildShape")
			fl_wrap("FlattenTerrainInShape")

			CreateRealTimeThread(function()
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					if status == "complete" or status == "error" then break end
					Sleep(100)
				end
				fl_log(string.format("SUMMARY calls=%d dropped_lines=%d", fl_calls, fl_dropped))
				fl_flush()
			end)
		end"""

# Diagnostic only, opt-in with the "passtrace" argument.  Iteration 035 proved that the mod's
# authoritative final underground pass rebuild RUNS (branch/cost stamps, digest moves) and that the
# map handed over at the end of generation nevertheless carries mod 808's exact passability digest
# and mask, so a LATER actor re-derives the grid.  Reading Lua cannot name that actor (the workspace
# lesson "probe the call, never read Lua to find a terrain writer"), so this block names it from the
# calls themselves.
#
# It is installed in the CONSOLE `_G` before generation, which matters twice:
#   * the mod indexes `terrain` at call time (`Engine.Global("terrain")` -> `rawget(_G, "terrain")`
#     resolves to the engine's own table), so wrapping the table entries catches mod and engine-Lua
#     callers alike;
#   * `Core/map.lua:49-63` COPIES `terrain.RebuildPassability/InvalidateHeight/InvalidateType/
#     Suspend/ResumePassEdits` and the global `RebuildGrids` into the `Map` class at definition
#     time, so `map:RebuildGrids(box)` would bypass a terrain-table-only wrap.  Both holders are
#     wrapped.  Native C callers stay invisible - which the sampler below turns into evidence.
#
# Two independent instruments, so an untraced writer cannot hide:
#   (1) per-call log: ordinal, name, the g_ParityStatus phase, the argument summary (map environment
#       and box) and a one-line traceback naming the call site;
#   (2) digest watch: `terrain.HashPassability` per live map after every write-class call AND from a
#       real-time sampler thread.  A change reported by a wrapper names its caller; a change the
#       SAMPLER sees first means no traced Lua call did it (native or an early-captured local), and
#       that is itself the answer to "who runs last".
# Pass-through only: every argument and result is forwarded with an explicit arity, no RNG is
# consumed, nothing is created, moved or destroyed, and the added work is reads (HashPassability)
# plus logging.
#
# Iteration 037 (C1n) closes the one hole iteration 036 left.  Suspend/ResumePassEdits were logged
# compactly, CAPPED at 60 and never hashed, so the six calls that follow the mod's final rebuild -
# the window in which the underground digest was seen to move - were invisible.  They are now
# UNCAPPED (about 13,000 single-line entries against a 60,000-line buffer), and the RESUME side is
# hashed AROUND (only a resume can flush deferred edits):
#   * the BEFORE hash catches a move that happened since the previous hash, i.e. with NO traced
#     call running - the signature of a native or early-bound writer;
#   * the AFTER hash catches a move the call itself made, and only then is a traceback taken.
# Hashing is per-call-map (a method's first argument is its map), which halves the cost, and it is
# abandoned if the cumulative hash time passes PT_HASH_BUDGET_MS so a slow build cannot hang a run.
# Every bracket and write-class call also records `IsPassEditSuspended` and the outstanding
# SuspendPassEditsReasons, because the engine's suspend lifts only when the LAST reason clears
# (Core/map.lua:734-770): a rebuild issued while a reason is outstanding is a candidate for being
# discarded by that final resume.
# The flush - which rewrites the whole buffer - relaxes to every 250 calls after the first 400.
PASSTRACE_BLOCK = """		do
			local PT_HASH_BUDGET_MS = 300000
			local pt_lines, pt_dropped, pt_calls, pt_changes = {}, 0, 0, 0
			local pt_hash_ms, pt_hash_total, pt_hash_calls = 0, 0, 0
			local pt_last_hash_call, pt_budget_noted = 0, false
			local pt_label_calls = {}
			local function pt_log(text)
				if #pt_lines >= 60000 then
					pt_dropped = pt_dropped + 1
					return
				end
				pt_lines[#pt_lines + 1] = tostring(text)
			end
			local function pt_flush()
				local werr = AsyncStringToFile("__PASSTRACE_OUT__", table.concat(pt_lines, "\\n"))
				g_ParityPassTraceStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end
			g_ParityPassTraceStatus = "running"
			g_ParityPassTraceCalls = 0
			g_ParityPassTraceChanges = 0

			local terrain_tbl = rawget(_G, "terrain")
			local hash_fn = (type(terrain_tbl) == "table" and terrain_tbl.HashPassability) or false

			local function pt_env(m)
				local ok, env = pcall(function() return m.mapdata.Environment end)
				return (ok and tostring(env)) or "?"
			end

			-- Weak keys: a destroyed map must not be kept alive by the watch table.
			local pt_last = setmetatable({}, { __mode = "k" })
			-- Returns true when THIS map's digest moved, so the caller can decide to pay for a
			-- traceback only where it is evidence.
			local function pt_hash_map(m, who)
				if type(hash_fn) ~= "function" then return false end
				if not (m and m.mapdata) then return false end
				local t0 = GetPreciseTicks()
				local ok, h = pcall(hash_fn, m)
				pt_hash_ms = GetPreciseTicks() - t0
				pt_hash_total = pt_hash_total + pt_hash_ms
				pt_hash_calls = pt_hash_calls + 1
				if not ok then return false end
				local prev = pt_last[m]
				pt_last[m] = h
				if prev == nil then
					pt_log(string.format("DIGEST %-11s INIT   %s  (%s, status=%s, %d ms)",
						pt_env(m), tostring(h), who,
						tostring(rawget(_G, "g_ParityStatus")), pt_hash_ms))
					return false
				end
				if prev == h then return false end
				pt_changes = pt_changes + 1
				g_ParityPassTraceChanges = pt_changes
				pt_log(string.format("DIGEST %-11s CHANGE#%03d %s -> %s  (%s, status=%s)",
					pt_env(m), pt_changes, tostring(prev), tostring(h), who,
					tostring(rawget(_G, "g_ParityStatus"))))
				return true
			end
			local function pt_check(who)
				if type(hash_fn) ~= "function" then return false end
				local maps = rawget(_G, "Maps") or {}
				local moved = false
				for i = 1, #maps do
					if pt_hash_map(maps[i], who) then moved = true end
				end
				return moved
			end

			-- Level 3 starts the trace at the CALLER of the wrapper (1 = this function,
			-- 2 = the wrapper itself).
			local function pt_where()
				if type(debug) ~= "table" or type(debug.traceback) ~= "function" then
					return "no debug.traceback"
				end
				local tb = tostring(debug.traceback("", 3))
				tb = tb:gsub("stack traceback:", "")
				tb = tb:gsub("%s+", " ")
				if #tb > 700 then tb = tb:sub(1, 700) .. " ..." end
				return tb
			end

			-- Maps and boxes are the only argument shapes that identify a pass write; everything
			-- else is reported by value or by type, and every read is protected.
			local function pt_arg(v)
				if v == nil then return "nil" end
				local tv = type(v)
				if tv == "number" or tv == "boolean" or tv == "string" then return tostring(v) end
				local ok, s = pcall(function()
					if type(v) == "table" and type(v.mapdata) == "table" then
						return "map<" .. tostring(v.mapdata.Environment) .. "/" .. tostring(v.slot) .. ">"
					end
					if type(v.sizex) == "function" then
						return string.format("box<%dx%d@%d,%d>", v:sizex(), v:sizey(), v:minx(), v:miny())
					end
					return tostring(v)
				end)
				return (ok and tostring(s)) or tv
			end

			-- A method's first argument is its own map; hashing only that map is what makes
			-- hashing around 13,000 bracketing calls affordable.
			local function pt_own_map(v)
				if type(v) ~= "table" then return nil end
				local ok, is_map = pcall(function() return type(v.mapdata) == "table" end)
				return (ok and is_map) and v or nil
			end

			-- `Map:SuspendPassEdits` counts by REASON and the engine's own suspend only lifts when
			-- the LAST reason clears (Core/map.lua:734-770), so a rebuild that runs with any reason
			-- outstanding can be discarded by that final resume.  Every hashed call records the
			-- state as it found it.
			local function pt_susp(m)
				if type(m) ~= "table" then return "susp=? reasons=?" end
				local ok, s = pcall(function()
					local flag = "?"
					if type(m.IsPassEditSuspended) == "function" then
						flag = tostring(m:IsPassEditSuspended())
					end
					local t = m.SuspendPassEditsReasons
					if type(t) ~= "table" then return "susp=" .. flag .. " reasons=?" end
					local names = {}
					for k in pairs(t) do
						if type(k) == "table" then
							names[#names + 1] = tostring(rawget(k, "class") or "table")
						else
							names[#names + 1] = tostring(k)
						end
					end
					table.sort(names)
					return string.format("susp=%s reasons=%d[%s]", flag, #names,
						table.concat(names, "+"))
				end)
				return (ok and s) or "susp=? reasons=?"
			end
			-- opts: hash = "none" | "after" | "around", trace, cap, own_map
			local function pt_wrap(holder, key, label, opts)
				opts = opts or {}
				local hash, trace, cap = opts.hash or "none", opts.trace, opts.cap
				if type(holder) ~= "table" then
					pt_log("MISSING holder for " .. label)
					return
				end
				local original = rawget(holder, key)
				if type(original) ~= "function" then
					pt_log("MISSING " .. label)
					return
				end
				local wrapper
				wrapper = function(...)
					local argv = table.pack(...)
					pt_calls = pt_calls + 1
					g_ParityPassTraceCalls = pt_calls
					local n = pt_calls
					local seen = (pt_label_calls[label] or 0) + 1
					pt_label_calls[label] = seen
					local own = pt_own_map(argv[1])
					if not cap or seen <= cap then
						local a = {}
						for i = 1, math.min(argv.n, 4) do a[#a + 1] = pt_arg(argv[i]) end
						pt_log(string.format("CALL #%05d %-30s status=%-22s %s args=%s", n, label,
							tostring(rawget(_G, "g_ParityStatus")),
							opts.susp and pt_susp(own) or "", table.concat(a, " ")))
						if trace then pt_log("   at " .. pt_where()) end
					end
					local scope = opts.own_map and own or nil
					local do_hash = hash ~= "none"
					if do_hash and pt_hash_total > PT_HASH_BUDGET_MS then
						do_hash = false
						if not pt_budget_noted then
							pt_budget_noted = true
							pt_log(string.format("HASH BUDGET EXHAUSTED at #%05d (%d ms, %d hashes)",
								n, pt_hash_total, pt_hash_calls))
						end
					end
					-- BEFORE: a move seen here happened with no traced call running, i.e. between
					-- call #pt_last_hash_call and this one.
					if do_hash and hash == "around" then
						local who = string.format("BEFORE #%05d %s (nothing traced since #%05d)",
							n, label, pt_last_hash_call)
						-- `scope and f() or g()` would call g() whenever f() returns false, which
						-- is the common case; the branch must be explicit.
						local moved
						if scope then moved = pt_hash_map(scope, who) else moved = pt_check(who) end
						if moved then
							pt_log(string.format("   UNTRACED WRITER: digest moved between #%05d and #%05d",
								pt_last_hash_call, n))
						end
						pt_last_hash_call = n
					end
					local results = table.pack(original(table.unpack(argv, 1, argv.n)))
					if do_hash then
						local who = string.format("#%05d %s", n, label)
						local moved
						if scope then moved = pt_hash_map(scope, who) else moved = pt_check(who) end
						if moved then
							pt_log(string.format("   WRITER #%05d %s moved the digest; %s; call site:",
								n, label, pt_susp(own)))
							pt_log("   at " .. pt_where())
						end
						pt_last_hash_call = n
					end
					-- Each flush rewrites the whole buffer, so it relaxes once the interesting
					-- early ordering is on disk.
					if n <= 400 or n % 250 == 0 then pt_flush() end
					return table.unpack(results, 1, results.n)
				end
				-- A protected table would otherwise kill the whole run at setup; and an
				-- assignment that silently does not stick must be reported, not assumed.
				local set_ok, set_err = pcall(function() holder[key] = wrapper end)
				if not set_ok then
					pt_log("UNWRAPPABLE " .. label .. ": " .. tostring(set_err))
				elseif rawget(holder, key) ~= wrapper then
					pt_log("UNWRAPPABLE " .. label .. ": assignment did not stick")
				else
					pt_log("WRAPPED " .. label)
				end
			end

			-- Write-class entry points: hashed AROUND every call, full traceback.  All maps are
			-- hashed here (these are few) so a write to a map other than the argument's shows up.
			local WRITE = { hash = "around", trace = true, susp = true }
			pt_wrap(terrain_tbl, "RebuildPassability", "terrain.RebuildPassability", WRITE)
			pt_wrap(terrain_tbl, "ClearPassabilityBox", "terrain.ClearPassabilityBox", WRITE)
			pt_wrap(terrain_tbl, "SetPassability", "terrain.SetPassability", WRITE)
			pt_wrap(terrain_tbl, "SetPassableHeight", "terrain.SetPassableHeight", WRITE)
			pt_wrap(terrain_tbl, "SetForcedImpassableBox", "terrain.SetForcedImpassableBox", WRITE)
			pt_wrap(_G, "RebuildGrids", "_G.RebuildGrids", WRITE)
			pt_wrap(_G, "RebuildBuildableGrid", "_G.RebuildBuildableGrid", WRITE)
			-- Invalidations decide whether a later rebuild recomputes anything (iteration 034), so
			-- they are traced for ordering but not hashed - they write no bits themselves.
			local INVAL = { hash = "none", trace = true, cap = 400 }
			pt_wrap(terrain_tbl, "InvalidateHeight", "terrain.InvalidateHeight", INVAL)
			pt_wrap(terrain_tbl, "InvalidateType", "terrain.InvalidateType", INVAL)
			-- The Map class holds its OWN copies taken at class-definition time (Core/map.lua:49-63).
			local map_class = rawget(_G, "Map")
			pt_wrap(map_class, "RebuildGrids", "Map:RebuildGrids", WRITE)
			pt_wrap(map_class, "RebuildPassability", "Map:RebuildPassability", WRITE)
			pt_wrap(map_class, "InvalidateHeight", "Map:InvalidateHeight", INVAL)
			pt_wrap(map_class, "InvalidateType", "Map:InvalidateType", INVAL)
			-- Bracketing helpers (iteration 037): UNCAPPED, and the RESUME side is hashed around
			-- its OWN map - only a resume can flush deferred edits, so hashing the suspend side
			-- doubled the cost for nothing (run 1 spent its whole budget by call #05138).  A
			-- ResumePassEdits that flushes a rebuild is named by its AFTER hash; a move that
			-- appears in a BEFORE hash belongs to no traced call at all.  Both sides record the
			-- outstanding suspend reasons, because the engine's suspend only lifts on the last one.
			local SUSPEND = { hash = "none", trace = false, own_map = true, susp = true }
			local RESUME = { hash = "around", trace = false, own_map = true, susp = true }
			pt_wrap(map_class, "SuspendPassEdits", "Map:SuspendPassEdits", SUSPEND)
			pt_wrap(map_class, "ResumePassEdits", "Map:ResumePassEdits", RESUME)
			pt_wrap(terrain_tbl, "SuspendPassEdits", "terrain.SuspendPassEdits", SUSPEND)
			pt_wrap(terrain_tbl, "ResumePassEdits", "terrain.ResumePassEdits", RESUME)

			pt_log("INSTALLED passtrace")
			pt_flush()

			CreateRealTimeThread(function()
				pt_check("sampler-start")
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					pt_check("sampler")
					if status == "complete" or status == "error" then break end
					-- Adaptive: never spend more than ~1/6 of wall time hashing.
					Sleep(math.max(250, pt_hash_ms * 6))
				end
				pt_log(string.format(
					"SUMMARY calls=%d digest_changes=%d hashes=%d hash_ms_total=%d dropped_lines=%d",
					pt_calls, pt_changes, pt_hash_calls, pt_hash_total, pt_dropped))
				pt_flush()
			end)
		end"""

ANOM_PROBE_BLOCK = """		do
			local anom_lines = {}
			local anom_dropped = 0
			local function anom_log(text)
				if #anom_lines >= 20000 then
					anom_dropped = anom_dropped + 1
					return
				end
				anom_lines[#anom_lines + 1] = tostring(text)
			end
			local function anom_flush()
				local werr = AsyncStringToFile("__ANOM_OUT__", table.concat(anom_lines, "\\n"))
				g_ParityAnomProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end
			g_ParityAnomProbeStatus = "running"
			g_ParityAnomProbeCalls = 0

			local function anom_live(obj)
				if type(obj) ~= "table" then return false end
				local isv = rawget(_G, "IsValid")
				if type(isv) ~= "function" then return true end
				local ok, live = pcall(isv, obj)
				return ok and live == true
			end
			local function anom_xy(obj)
				if not anom_live(obj) or type(obj.GetPos) ~= "function" then return nil end
				local ok, x, y = pcall(function()
					local p = obj:GetPos()
					return p:x(), p:y()
				end)
				if ok and type(x) == "number" then return x, y end
				return nil
			end

			-- The census + cull record shared by both call sites.  `phase` names which one fired.
			local function anom_observe(phase, self, invoke)
				local n = (rawget(_G, "g_ParityAnomProbeCalls") or 0) + 1
				g_ParityAnomProbeCalls = n
				local env, width, slot = "?", "?", "?"
				pcall(function() env = tostring(GetEnvironment(self)) end)
				pcall(function()
					local m = self:GetMap()
					width = tostring(m and m.mapdata and m.mapdata.Width)
					slot = tostring(m and m.slot)
				end)
				local markers, all = {}, {}
				pcall(function()
					markers = self:MapGet("map", "SubsurfaceAnomalyMarker",
						function(a) return a.tech_action == "breakthrough" end) or {}
				end)
				pcall(function()
					all = self:MapGet("map", "SubsurfaceAnomalyMarker") or {}
				end)
				local consts = rawget(_G, "g_Consts")
				anom_log(string.format(
					"PRE  call=%d phase=%s env=%s width=%s slot=%s status=%s breakthrough=%d all=%d reserved=%s",
					n, phase, env, width, slot, tostring(rawget(_G, "g_ParityStatus")),
					#markers, #all,
					tostring(consts and consts.PlanetaryBreakthroughCount)))
				local rec = {}
				for i = 1, #markers do
					local m = markers[i]
					local x, y = anom_xy(m)
					local handle, class, action = "?", "?", "?"
					pcall(function()
						handle = tostring(m.handle)
						class = tostring(m.class)
						action = tostring(m.tech_action)
					end)
					rec[i] = { m, tostring(x), tostring(y), handle, class }
					anom_log(string.format("IN   call=%d #%03d pos=%s,%s handle=%s class=%s act=%s",
						n, i, tostring(x), tostring(y), handle, class, action))
				end
				local results = table.pack(invoke())
				local culled = 0
				for i = 1, #rec do
					local r = rec[i]
					if not anom_live(r[1]) then
						culled = culled + 1
						anom_log(string.format("CULL call=%d #%03d pos=%s,%s handle=%s class=%s",
							n, i, r[2], r[3], r[4], r[5]))
					end
				end
				local order = "?"
				pcall(function() order = tostring(#(rawget(_G, "BreakthroughOrder") or {})) end)
				anom_log(string.format(
					"POST call=%d phase=%s culled=%d remaining=%d breakthrough_order=%s dropped=%d",
					n, phase, culled, #rec - culled, order, anom_dropped))
				anom_flush()
				return results
			end

			local city_class = rawget(_G, "City")
			local state = type(SBM) == "table" and SBM.State or nil
			if type(city_class) ~= "table"
				or type(city_class.InitBreakThroughAnomalies) ~= "function" then
				anom_log("MISSING City.InitBreakThroughAnomalies")
				anom_flush()
			else
				local previous = city_class.InitBreakThroughAnomalies
				local mod_wrapper = type(state) == "table" and state.breakthrough_init_wrapper
				local deferred_original = type(state) == "table"
					and state.original_city_init_breakthrough_anomalies
				anom_log(string.format(
					"INSTALL state=%s class_is_mod_wrapper=%s deferred_original=%s",
					tostring(type(state) == "table"),
					tostring(mod_wrapper == previous),
					tostring(type(deferred_original) == "function")))

				local class_wrapper = function(self, ...)
					local argv = table.pack(...)
					local results = anom_observe("class", self, function()
						return previous(self, table.unpack(argv, 1, argv.n))
					end)
					return table.unpack(results, 1, results.n)
				end
				city_class.InitBreakThroughAnomalies = class_wrapper
				-- Keep the mod patch's identity check satisfied so a re-install early-outs instead
				-- of saving this probe as the vanilla "original" it defers to.
				if type(state) == "table" and mod_wrapper == previous then
					state.breakthrough_init_wrapper = class_wrapper
				end

				if type(state) == "table" and type(deferred_original) == "function" then
					state.original_city_init_breakthrough_anomalies = function(self, ...)
						local argv = table.pack(...)
						local results = anom_observe("deferred", self, function()
							return deferred_original(self, table.unpack(argv, 1, argv.n))
						end)
						return table.unpack(results, 1, results.n)
					end
				end
			end

			-- A twin where the initializer never fires would otherwise leave no file at all.
			CreateRealTimeThread(function()
				while true do
					local status = tostring(rawget(_G, "g_ParityStatus"))
					if status == "complete" or status == "error" then break end
					Sleep(300)
				end
				anom_log(string.format("SUMMARY calls=%s dropped_lines=%d",
					tostring(rawget(_G, "g_ParityAnomProbeCalls")), anom_dropped))
				anom_flush()
			end)
		end"""


def dump_and_census(client, tag, hexgrid, wonder_probe=False, ring_scale=1.0,
                    pass_probe_all=False, zones_probe=False, pass_real_probe=False,
                    pass_lattice_probe=False, pass_rebuild_probe=False,
                    pass_mask_probe=False, pass_forced_probe=False,
                    pass_writer_probe=False, pass_own_probe=False, pass_ablate_probe=False,
                    pass_imprint_probe=False, pass_move_probe=False, pass_class_probe=False,
                    pass_vis_probe=False, pass_fix_probe=False, build_probe=False,
                    property_probe=False, perimeter_probe=False,
                    perimeter_full_probe=False):
    """Dump every object on both maps, then (optionally) the read-only hexgrid census.

    Shared by the generated twins and by the save-roundtrip loader so a post-load recount is
    produced by exactly the same code path as the pre-save dump - a recount scored against a
    dump made by different logic would prove nothing.
    """
    csv_path = OUT / f"objects-{tag}.csv"
    dump_src = DUMP_TEMPLATE.read_text(encoding="utf-8")
    dump_src = dump_src.replace("__OUT_PATH__", cli.lua_path(csv_path))
    dump_path = OUT / f"dump-{tag}.lua"
    dump_path.write_text(dump_src, encoding="utf-8")

    if zones_probe:
        probe_src = (HERE / "height_dump_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__OUT_BASE__", cli.lua_path(OUT / f"height-{tag}"))
        probe_path = OUT / f"zonesprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  zones probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityZonesStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityZonesInfo", timeout=60.0)
                        log(f"  zones probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityZonesError", timeout=60.0)
                        log(f"  zones probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if property_probe:
        # Exhaustive passability/buildability verdicts on the common property lattice.
        # This probe snapshots shipped state first, then performs and sensitivity-controls
        # stock rebuilds before restoring the exact final terrain. Run it before every other
        # mutating probe. It subsumes buildable staleness verdicts, so combining the two would
        # make buildableprobe's "shipped" snapshot observe propertyprobe's fresh rebuild.
        if build_probe:
            raise RuntimeError("propertyprobe and buildableprobe are mutually exclusive")
        probe_src = (HERE / "property_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__OUT_BASE__", cli.lua_path(OUT / f"property-{tag}"))
        probe_path = OUT / f"propertyprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  property probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPropertyStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPropertyInfo", timeout=60.0)
                        log(f"  property probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPropertyError", timeout=60.0)
                        log(f"  property probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if build_probe:
        # Buildable grid, both maps. Runs here - immediately after the height dump and BEFORE
        # every pass probe - so the grids it saves come from untouched final terrain: passreal
        # and the passablate/passmove family edit terrain or objects later in this same window.
        # It rebuilds map.buildable at the end (step 6's staleness check), which touches nothing
        # else, but never combine it with a probe that reads the buildable grid afterwards.
        probe_src = (HERE / "buildable_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__OUT_BASE__", cli.lua_path(OUT / f"height-{tag}"))
        probe_src = probe_src.replace("__DISC_R__", "2")
        probe_path = OUT / f"buildableprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  buildable probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityBuildStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityBuildInfo", timeout=60.0)
                        log(f"  buildable probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityBuildError", timeout=60.0)
                        log(f"  buildable probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if perimeter_probe:
        # MUTATING, SELF-RESTORING, and intended to run alone. It derives a
        # two-box union from each live map, compares direct ClearPassabilityBox
        # with the stock ForcedImpassableMarker rebuild hook, repeats, and cleans up.
        probe_src = (HERE / "perimeter_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace(
            "__OUT_PATH__", cli.lua_path(OUT / f"perimeter-{tag}.csv"))
        probe_path = OUT / f"perimeterprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  perimeter probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPerimeterStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(
                            client, "g_ParityPerimeterInfo", timeout=60.0)
                        log(f"  perimeter probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(
                            client, "g_ParityPerimeterError", timeout=60.0)
                        log(f"  perimeter probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if perimeter_full_probe:
        # MUTATING, SELF-RESTORING full replay of perimetercheck.py's compact union.
        # The preserved report path is explicit host-side test input; no coordinate,
        # seed, or box list enters payload code.
        report_value = os.environ.get("SMR_PARITY_PERIMETER_REPORT", "")
        if not report_value:
            raise RuntimeError("perimeterfull requires SMR_PARITY_PERIMETER_REPORT")
        report_path = Path(report_value)
        import perimeterfullcheck
        boxes, source_sha, engine_sha = perimeterfullcheck.load_engine_boxes(report_path)
        probe_src = (HERE / "perimeter_full_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__OUT_BASE__", cli.lua_path(OUT / f"perimeterfull-{tag}"))
        probe_src = probe_src.replace("__SOURCE_BOX_SHA__", source_sha)
        probe_src = probe_src.replace("__ENGINE_BOX_SHA__", engine_sha)
        probe_src = probe_src.replace("__BOXES__", perimeterfullcheck.lua_boxes(boxes))
        probe_path = OUT / f"perimeterfullprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  perimeter full probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(
                        client, "g_ParityPerimeterFullStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(
                            client, "g_ParityPerimeterFullInfo", timeout=60.0)
                        log(f"  perimeter full probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(
                            client, "g_ParityPerimeterFullError", timeout=60.0)
                        log(f"  perimeter full probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_probe_all:
        probe_src = (HERE / "pass_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__RING_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"pass-{tag}.csv"))
        probe_path = OUT / f"passprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  pass probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassInfo", timeout=60.0)
                        log(f"  pass probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassError", timeout=60.0)
                        log(f"  pass probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_lattice_probe:
        # Object-free lattice: runs BEFORE passreal, whose spike control edits the terrain.
        probe_src = (HERE / "passlattice_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__STRIDE__", "12")
        probe_src = probe_src.replace("__MIN_DIST__", "2400")
        probe_src = probe_src.replace("__BUCKET__", "4800")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passlat-{tag}.csv"))
        probe_path = OUT / f"passlatprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passlattice probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassLatStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassLatInfo", timeout=60.0)
                        log(f"  passlattice probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassLatError", timeout=60.0)
                        log(f"  passlattice probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_real_probe:
        # LAST of the terrain-reading probes: its spike control edits the height grid on purpose,
        # so the zones probe's raw dump and the pass probe's samples must already be written.
        probe_src = (HERE / "passreal_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__ZONE_TARGET__", "400")
        probe_src = probe_src.replace("__OUTSIDE_TARGET__", "5000")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passreal-{tag}.csv"))
        probe_path = OUT / f"passrealprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passreal probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassRealStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassRealInfo", timeout=60.0)
                        log(f"  passreal probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassRealError", timeout=60.0)
                        log(f"  passreal probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_forced_probe:
        # READ-ONLY (no rebuild, no pass edit), so it runs BEFORE the two mutating pass probes.
        # Same lattice and same 20 forensic source cells as the mask probe (iter 023), so its
        # forced-impassability / pass-type columns join that measurement cell for cell.
        probe_src = (HERE / "passforced_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "20000")
        probe_src = probe_src.replace("__STRIDE__", "200")
        probe_src = probe_src.replace("__CELLS__", PASS_FORENSIC_CELLS)
        probe_src = probe_src.replace("__DUMP_GRID__", "true")
        probe_src = probe_src.replace("__GRID_PREFIX__", cli.lua_path(OUT / "passgrid"))
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passforced-{tag}.csv"))
        probe_path = OUT / f"passforcedprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passforced probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassForcedStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassForcedInfo", timeout=60.0)
                        log(f"  passforced probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassForcedError", timeout=60.0)
                        log(f"  passforced probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_rebuild_probe:
        # LAST of all: it forces full-map passability rebuilds, so every probe that reads the
        # as-generated pass data must already have run.
        probe_src = (HERE / "passrebuild_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "30000")
        probe_src = probe_src.replace("__STRIDE__", "300")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passrb-{tag}.csv"))
        probe_path = OUT / f"passrbprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passrebuild probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassRbStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassRbInfo", timeout=60.0)
                        log(f"  passrebuild probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassRbError", timeout=60.0)
                        log(f"  passrebuild probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_mask_probe:
        # LAST of all, with the rebuild probe: step (4) calls `map:RebuildGrids(box)`, which edits
        # passability, so every probe that reads the as-generated pass data must already have run.
        # The forensic cells are fixed SOURCE cells chosen offline from the iter-022 twin lattices
        # (`out/passrb-t6{b,y}.csv`, picker `_ralph/tmp/.tmp_fzp_pickcells.py`) so both twins
        # interrogate the same ground: 12 that vanilla blocks and the expanded map does not, 4
        # passable on both, 4 blocked on both.
        cells = PASS_FORENSIC_CELLS
        probe_src = (HERE / "passmask_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "20000")
        probe_src = probe_src.replace("__STRIDE__", "200")
        probe_src = probe_src.replace("__CELLS__", cells)
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passmask-{tag}.csv"))
        probe_path = OUT / f"passmaskprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passmask probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassMaskStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassMaskInfo", timeout=60.0)
                        log(f"  passmask probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassMaskError", timeout=60.0)
                        log(f"  passmask probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_writer_probe:
        # LAST of all, and meant to run ALONE: it invalidates and rebuilds passability and forces a
        # control box impassable.  Same window and stride as the mask/forced probes (iters 023/024),
        # so its per-cell columns join those measurements cell for cell.
        probe_src = (HERE / "passwriter_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "20000")
        probe_src = probe_src.replace("__STRIDE__", "200")
        probe_src = probe_src.replace("__CTRL_OFF__", "12000")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passwriter-{tag}.csv"))
        probe_path = OUT / f"passwriterprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passwriter probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassWriterStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassWriterInfo", timeout=60.0)
                        log(f"  passwriter probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassWriterError", timeout=60.0)
                        log(f"  passwriter probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_own_probe:
        # LAST of all, and meant to run ALONE: it WRITES passability with terrain.SetPassability
        # and then invalidates and rebuilds.  Same window and stride as the mask/forced/writer
        # probes (023/024/026), so its per-cell columns join those measurements cell for cell.
        probe_src = (HERE / "passown_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "20000")
        probe_src = probe_src.replace("__STRIDE__", "200")
        probe_src = probe_src.replace("__BOXHALF__", "600")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passown-{tag}.csv"))
        probe_path = OUT / f"passownprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passown probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassOwnStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassOwnInfo", timeout=60.0)
                        log(f"  passown probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassOwnError", timeout=60.0)
                        log(f"  passown probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_ablate_probe:
        # LAST of all, and meant to run ALONE: it MUTATES the map's own `BottomlessPit` object
        # (scale, z mode, efApplyToGrids, then deletes it) and rebuilds passability over the whole
        # map after every stage.  Same window and stride as the mask/forced/writer/own probes
        # (023/024/026/027b), so its per-cell columns join those measurements cell for cell.
        probe_src = (HERE / "passablate_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "20000")
        probe_src = probe_src.replace("__STRIDE__", "200")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passabl-{tag}.csv"))
        probe_path = OUT / f"passablprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passablate probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassAblStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassAblInfo", timeout=60.0)
                        log(f"  passablate probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassAblError", timeout=60.0)
                        log(f"  passablate probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_imprint_probe:
        # READ-ONLY object footprint-imprint census (028's follow-up, widened): for every object
        # that carries efApplyToGrids and whose entity has ApplyToGrids surfaces, the blocked rate
        # INSIDE its own world bbox against the blocked rate in a ring just outside it.  Answers
        # whether object surfaces imprint impassability at all on the expanded map, rather than
        # re-registering the one wonder 028 caught.
        probe_src = (HERE / "passimprint_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__GRID_K__", "5")
        probe_src = probe_src.replace("__RING__", "2.0")
        probe_src = probe_src.replace("__MAX_OBJECTS__", "4000")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passimp-{tag}.csv"))
        probe_path = OUT / f"passimpprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passimprint probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassImpStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassImpInfo", timeout=60.0)
                        log(f"  passimprint probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassImpError", timeout=60.0)
                        log(f"  passimprint probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_move_probe:
        # MUTATING pose ablation (C1f): moves the `BottomlessPit` 120,000 SOURCE wu away, rebuilds
        # passability over the whole map, and samples BOTH the origin window (the same 201x201 /
        # 200 src-wu window as 023/024/026/027b/028) and a destination window on fresh ground, with
        # a rebuild-only control before the move and a restore control after it.  Runs alone.
        probe_src = (HERE / "passmove_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "20000")
        probe_src = probe_src.replace("__STRIDE__", "200")
        probe_src = probe_src.replace("__DEST_OFFSET__", "120000")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passmove-{tag}.csv"))
        probe_path = OUT / f"passmoveprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passmove probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassMoveStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassMoveInfo", timeout=60.0)
                        log(f"  passmove probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassMoveError", timeout=60.0)
                        log(f"  passmove probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_class_probe:
        # MUTATING class-vs-instance test (C1g): places a FRESH object carrying the wonder's entity
        # (and then one of its own class) on the destination ground where vanilla's moved pit
        # imprinted in 030, rebuilds passability over the whole map, and samples the same origin and
        # destination windows, with a rebuild-only control before each placement and a DoneObject
        # restore after it.  Dumps every instance's full property set for a named twin diff.  Runs
        # alone.
        probe_src = (HERE / "passclass_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__ENTITY__", "WonderBottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "20000")
        probe_src = probe_src.replace("__STRIDE__", "200")
        probe_src = probe_src.replace("__DEST_OFFSET__", "120000")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passclass-{tag}.csv"))
        probe_path = OUT / f"passclassprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passclass probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassClassStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassClassInfo", timeout=60.0)
                        log(f"  passclass probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassClassError", timeout=60.0)
                        log(f"  passclass probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_vis_probe:
        # MUTATING visibility ablation (C1h): flips the wonder's `efVisible` bit - first the raw
        # enum flag, then the object's own `SetVisible` API - away from this twin's baseline and
        # back, rebuilding passability over the whole map at every stage and sampling the same
        # 201x201 / 200 src-wu origin window as 023/024/026/027b/028/030/031.  The same probe is
        # vanilla's positive control (true -> false) and the expanded map's test (false -> true).
        # Runs alone.
        probe_src = (HERE / "passvis_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "20000")
        probe_src = probe_src.replace("__STRIDE__", "200")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passvis-{tag}.csv"))
        probe_path = OUT / f"passvisprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passvis probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassVisStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassVisInfo", timeout=60.0)
                        log(f"  passvis probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassVisError", timeout=60.0)
                        log(f"  passvis probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if pass_fix_probe:
        # READ-ONLY verification of the C1i concealment fix (mod 808): samples the same
        # 201x201 / 200 src-wu origin window as 023/024/026/027b/028/030/031/032 once, and dumps
        # the wonder's live state (efVisible, opacity, the mod's concealment stamps) plus its
        # attach tree.  No flag write, no rebuild, no move - so its window may be joined with any
        # other reading probe's.
        probe_src = (HERE / "passfix_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__POS_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__CENTRE_CLASS__", "BottomlessPit")
        probe_src = probe_src.replace("__RADIUS__", "20000")
        probe_src = probe_src.replace("__STRIDE__", "200")
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"passfix-{tag}.csv"))
        probe_path = OUT / f"passfixprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, _ = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  passfix probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 1800
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityPassFixStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityPassFixInfo", timeout=60.0)
                        log(f"  passfix probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityPassFixError", timeout=60.0)
                        log(f"  passfix probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    if wonder_probe:
        # Runs in the same post-generation window as the dump, with the game alive.
        probe_src = (HERE / "wonder_probe.lua").read_text(encoding="utf-8")
        probe_src = probe_src.replace("__RING_SCALE__", repr(float(ring_scale)))
        probe_src = probe_src.replace("__OUT_PATH__", cli.lua_path(OUT / f"rings-{tag}.csv"))
        probe_src = probe_src.replace("__SHOT_PATH__", cli.lua_path(OUT / f"wonder-{tag}.png"))
        probe_path = OUT / f"wonderprobe-{tag}.lua"
        probe_path.write_text(probe_src, encoding="utf-8")
        perr, pprose = cli.load_lua_file(client, probe_path, timeout=120.0)
        if perr:
            log(f"  wonder probe failed to load: {perr[2]}")
        else:
            deadline = time.time() + 900
            while time.time() < deadline:
                try:
                    _, st = cli.marshal_value(client, "g_ParityWonderStatus", timeout=60.0)
                    if st == "ready":
                        _, inf = cli.marshal_value(client, "g_ParityWonderInfo", timeout=60.0)
                        log(f"  wonder probe: {inf}")
                        break
                    if st == "error":
                        _, e = cli.marshal_value(client, "g_ParityWonderError", timeout=60.0)
                        log(f"  wonder probe error: {e}")
                        break
                except dap.DapTimeout:
                    pass
                time.sleep(5)

    load_err, prose = cli.load_lua_file(client, dump_path, timeout=60.0)
    if load_err:
        raise RuntimeError(f"dump script failed to load: {load_err[2]}")
    status = poll_status(
        client, "g_ParityDumpStatus", {"complete"}, {"error"}, 900, f"dump-{tag}"
    )
    if status != "complete":
        _, detail = cli.marshal_value(client, "g_ParityDumpError", timeout=60.0)
        raise RuntimeError(f"dump failed ({tag}): {detail}")
    _, rows = cli.marshal_value(client, "g_ParityDumpRows", timeout=60.0)
    log(f"dump complete ({tag}): {rows} objects -> {csv_path}")

    hex_path = OUT / f"hexgrid-{tag}.txt"
    if hexgrid:
        # Read-only, and deliberately AFTER the object dump so the dump stays
        # byte-comparable with runs that did not ask for the census.
        if hex_path.exists():
            hex_path.unlink()
        hex_src = HEXGRID_TEMPLATE.read_text(encoding="utf-8")
        hex_src = hex_src.replace("__OUT_PATH__", cli.lua_path(hex_path))
        hex_script = OUT / f"hexgrid-{tag}.lua"
        hex_script.write_text(hex_src, encoding="utf-8")
        load_err, prose = cli.load_lua_file(client, hex_script, timeout=60.0)
        if load_err:
            raise RuntimeError(f"hexgrid census failed to load: {load_err[2]}")
        status = poll_status(
            client, "g_ParityHexStatus", {"complete"}, {"error"}, 900, f"hexgrid-{tag}"
        )
        if status != "complete":
            _, detail = cli.marshal_value(client, "g_ParityHexError", timeout=60.0)
            raise RuntimeError(f"hexgrid census failed ({tag}): {detail}")
        _, buckets = cli.marshal_value(client, "g_ParityHexBuckets", timeout=60.0)
        log(f"hexgrid census complete ({tag}): {buckets} buckets -> {hex_path}")
    return rows, csv_path, hex_path


def save_session(client, tag, display_name):
    """Save the live session through the engine's own SaveGame path; return its metadata.

    Runs AFTER the dump and the census, so neither is affected by the save.
    """
    info_path = OUT / f"savegame-{tag}.txt"
    if info_path.exists():
        info_path.unlink()
    save_src = SAVE_TEMPLATE.read_text(encoding="utf-8")
    save_src = save_src.replace("__SAVE_DISPLAY__", display_name)
    save_src = save_src.replace("__SAVE_INFO__", cli.lua_path(info_path))
    save_script = OUT / f"save-{tag}.lua"
    save_script.write_text(save_src, encoding="utf-8")
    load_err, prose = cli.load_lua_file(client, save_script, timeout=60.0)
    if load_err:
        raise RuntimeError(f"save script failed to load: {load_err[2]}")
    status = poll_status(
        client, "g_ParitySaveStatus", {"complete"}, {"error"}, 900, f"save-{tag}"
    )
    if status != "complete":
        _, detail = cli.marshal_value(client, "g_ParitySaveError", timeout=60.0)
        raise RuntimeError(f"save failed ({tag}): {detail}")
    _, savename = cli.marshal_value(client, "g_ParitySaveName", timeout=60.0)
    _, folder = cli.marshal_value(client, "g_ParitySaveFolder", timeout=60.0)
    _, os_path = cli.marshal_value(client, "g_ParitySaveOSPath", timeout=60.0)
    _, save_map = cli.marshal_value(client, "g_ParitySaveMap", timeout=60.0)
    if not isinstance(savename, str) or not savename:
        raise RuntimeError(f"save reported no savename ({tag}): {savename!r}")
    log(f"savegame written ({tag}): {savename}  folder={folder}  os_path={os_path}  "
        f"map={save_map}")
    return {"savename": savename, "folder": folder, "os_path": os_path, "map": save_map,
            "display": display_name, "info": str(info_path)}


def run_load(tag, savename, hexgrid=False, max_wait=1800):
    """Boot a FRESH game, load `savename`, then recount both maps with the same dump.

    Nothing is generated here: the expanded map must come back out of the engine's own
    persistence.  Used by the save-roundtrip acceptance condition.
    """
    csv_path = OUT / f"objects-{tag}.csv"
    if csv_path.exists():
        csv_path.unlink()

    load_src = LOAD_TEMPLATE.read_text(encoding="utf-8")
    load_src = load_src.replace("__SAVE_NAME__", savename)
    load_script = OUT / f"load-{tag}.lua"
    load_script.write_text(load_src, encoding="utf-8")

    proc, lf = spawn_game(tag)
    try:
        log(f"connecting DAP ({tag})...")
        client = dap.connect(retry_timeout=180.0)
        err = cli.ensure_harness(client)
        if err:
            raise RuntimeError(f"harness injection failed: {err[2]}")
        log(f"harness ready ({tag})")

        load_err, prose = cli.load_lua_file(client, load_script, timeout=60.0)
        if load_err:
            raise RuntimeError(f"load script failed to load: {load_err[2]}")
        log(f"savegame load started ({tag}): {prose}")
        status = poll_status(
            client, "g_ParityLoadStatus", {"complete"}, {"error"}, max_wait, f"load-{tag}"
        )
        if status != "complete":
            _, detail = cli.marshal_value(client, "g_ParityLoadError", timeout=60.0)
            raise RuntimeError(f"savegame load failed ({tag}): {detail}")
        readback = {}
        for var, key in (("g_ParityLoadSurfaceSeed", "surface_seed"),
                         ("g_ParityLoadUndergroundSeed", "underground_seed"),
                         ("g_ParityLoadMap", "map"),
                         ("g_ParityLoadMapCount", "map_count"),
                         ("g_ParityLoadSwitched", "switched_to_underground"),
                         ("g_ParityLoadExpanded", "surface_expanded")):
            _, readback[key] = cli.marshal_value(client, var, timeout=60.0)
        log(f"savegame loaded ({tag}): {json.dumps(readback)}")

        rows, csv_path, hex_path = dump_and_census(client, tag, hexgrid)
        try:
            client.evaluate("quit()", timeout=5.0)
        except Exception:
            pass
        info = {"tag": tag, "loaded_savename": savename, "rows": rows,
                "csv": str(csv_path), "hexgrid": str(hex_path) if hexgrid else None}
        info.update(readback)
        return info
    finally:
        time.sleep(2)
        try:
            proc.terminate()
            proc.wait(timeout=20)
        except Exception:
            try:
                proc.kill()
            except Exception:
                pass
        lf.close()


def run_twin(tag, expand, twin_seed, serial_raster=False, max_wait=1800, lat=1800, lon=8760,
             pin_seed=None, decal_probe=False, hexgrid=False, camera_probe=False,
             fx_probe=False, pit_probe=False, decor_probe=False, mark_probe=False,
             entrance_audit=False, proc_trace=False, pass_probe=False, draw_probe=False,
             passage_pin=False, point_probe=False, field_probe=False, slot_probe=False,
             anom_probe=False, place_probe=False, play_probe=False, tag_order_pin=False,
             save_as=None, keep_alive=False, wonder_probe=False, pass_probe_all=False, zones_probe=False,
             stretch_dump=False, flatten_probe=False, pass_trace=False, pass_real_probe=False,
             pass_lattice_probe=False, pass_rebuild_probe=False, pass_mask_probe=False,
             pass_forced_probe=False, pass_writer_probe=False, pass_own_probe=False,
             pass_ablate_probe=False, pass_imprint_probe=False, pass_move_probe=False,
             pass_class_probe=False, pass_vis_probe=False, pass_fix_probe=False,
             build_probe=False, property_probe=False, perimeter_probe=False,
             perimeter_full_probe=False):
    """Boot a fresh game, generate the twin, dump all objects.  Returns metadata.

    `pin_seed` applies only to a vanilla control and forces its underground holder seed to
    that fixed value; the expanded twin receives the same value through the mod's
    SetTwinUndergroundSeedForTest seam (`twin_seed`).
    """
    csv_path = OUT / f"objects-{tag}.csv"
    if csv_path.exists():
        csv_path.unlink()

    gen_src = GEN_TEMPLATE.read_text(encoding="utf-8")
    gen_src = gen_src.replace("__EXPAND__", "true" if expand else "false")
    gen_src = gen_src.replace("__LAT__", str(int(lat)))
    gen_src = gen_src.replace("__LON__", str(int(lon)))
    if expand:
        if twin_seed is None:
            raise RuntimeError("expanded twin requires the vanilla underground seed")
        gen_src = gen_src.replace(
            "__TWIN_SEED_BLOCK__", TWIN_SEED_BLOCK.format(seed=int(twin_seed))
        )
    else:
        gen_src = gen_src.replace("__TWIN_SEED_BLOCK__", "")
    if expand or pin_seed is None:
        gen_src = gen_src.replace("__UNDERGROUND_PIN_BLOCK__", "")
    else:
        gen_src = gen_src.replace(
            "__UNDERGROUND_PIN_BLOCK__", UNDERGROUND_PIN_BLOCK.format(seed=int(pin_seed))
        )
    extras = []
    if serial_raster:
        extras.append(SERIAL_RASTER_BLOCK)
    # Before every probe and before the passage pin: it shadows `pairs` and DoGenerate, and a
    # probe that shadows DoGenerate too must wrap the pinned one, not the other way round.
    if tag_order_pin:
        extras.append(TAG_ORDER_PIN_BLOCK)
    if place_probe:
        extras.append(PLACE_PROBE_BLOCK)
    # Before the probes, so a probe that wraps the same globals observes the pinned call.
    if passage_pin:
        extras.append(
            PASSAGE_PIN_BLOCK.replace("__PIN_SEED__", str(int(PASSAGE_FALLBACK_PIN_SEED)))
        )
    # After the pin, so the probe wraps the pinned wrapper and observes the redirected call.
    if point_probe:
        extras.append(
            POINT_PROBE_BLOCK.replace(
                "__PROBE_SEEDS__", ", ".join(str(int(s)) for s in PROBE_POINT_SEEDS)
            )
        )
    if field_probe:
        field_points = ", ".join(
            "{%d, %d, \"%s\"}" % (x, y, label) for x, y, label in PROBE_FIELD_POINTS
        )
        extras.append(
            FIELD_PROBE_BLOCK
            .replace("__FIELD_POINTS__", field_points)
            .replace("__FIELD_RADII__", ", ".join(str(int(r)) for r in PROBE_FIELD_RADII))
            .replace("__FIELD_RADIUS_SEEDS__",
                     ", ".join(str(int(s)) for s in PROBE_FIELD_RADIUS_SEEDS))
            .replace("__FIELD_STEP__", str(int(PROBE_FIELD_LATTICE_STEP)))
            .replace("__FIELD_SPAN__", str(int(PROBE_FIELD_LATTICE_SPAN)))
        )
    if slot_probe:
        extras.append(
            SLOT_PROBE_BLOCK.replace(
                "__SLOT_SEEDS__", ", ".join(str(int(s)) for s in SLOT_PROBE_SEEDS)
            )
        )
    if entrance_audit:
        extras.append(ENTRANCE_AUDIT_BLOCK)
    probe_path = OUT / f"probe-{tag}.log"
    if decal_probe:
        if probe_path.exists():
            probe_path.unlink()
        extras.append(DECAL_PROBE_BLOCK.replace("__PROBE_OUT__", cli.lua_path(probe_path)))
    cam_path = OUT / f"cameraprobe-{tag}.log"
    if camera_probe:
        if cam_path.exists():
            cam_path.unlink()
        extras.append(CAMERA_PROBE_BLOCK.replace("__CAM_OUT__", cli.lua_path(cam_path)))
    fx_path = OUT / f"fxprobe-{tag}.log"
    if fx_probe:
        if fx_path.exists():
            fx_path.unlink()
        extras.append(FX_PROBE_BLOCK.replace("__FX_OUT__", cli.lua_path(fx_path)))
    pit_path = OUT / f"pitprobe-{tag}.log"
    if pit_probe:
        if pit_path.exists():
            pit_path.unlink()
        extras.append(PIT_PROBE_BLOCK.replace("__PIT_OUT__", cli.lua_path(pit_path)))
    decor_path = OUT / f"decorprobe-{tag}.log"
    if decor_probe:
        if decor_path.exists():
            decor_path.unlink()
        extras.append(DECOR_PROBE_BLOCK.replace("__DECOR_OUT__", cli.lua_path(decor_path)))
    mark_path = OUT / f"markprobe-{tag}.log"
    if mark_probe:
        if mark_path.exists():
            mark_path.unlink()
        extras.append(MARK_PROBE_BLOCK.replace("__MARK_OUT__", cli.lua_path(mark_path)))
    play_path = OUT / f"playprobe-{tag}.log"
    if play_probe:
        if play_path.exists():
            play_path.unlink()
        extras.append(PLAY_PROBE_BLOCK.replace("__PLAY_OUT__", cli.lua_path(play_path)))
    proc_path = OUT / f"proctrace-{tag}.log"
    if proc_trace:
        if proc_path.exists():
            proc_path.unlink()
        extras.append(PROC_TRACE_BLOCK.replace("__PROC_OUT__", cli.lua_path(proc_path)))
    pass_path = OUT / f"passprobe-{tag}.log"
    if pass_probe:
        if pass_path.exists():
            pass_path.unlink()
        extras.append(PASSAGE_PROBE_BLOCK.replace("__PASS_OUT__", cli.lua_path(pass_path)))
    draw_path = OUT / f"drawprobe-{tag}.log"
    if draw_probe:
        if draw_path.exists():
            draw_path.unlink()
        extras.append(DRAW_PROBE_BLOCK.replace("__DRAW_OUT__", cli.lua_path(draw_path)))
    anom_path = OUT / f"anomprobe-{tag}.log"
    if anom_probe:
        if anom_path.exists():
            anom_path.unlink()
        extras.append(ANOM_PROBE_BLOCK.replace("__ANOM_OUT__", cli.lua_path(anom_path)))
    flatten_path = OUT / f"flattenprobe-{tag}.log"
    if flatten_probe:
        if flatten_path.exists():
            flatten_path.unlink()
        extras.append(FLATTEN_PROBE_BLOCK.replace("__FLATTEN_OUT__", cli.lua_path(flatten_path)))
    passtrace_path = OUT / f"passtrace-{tag}.log"
    if pass_trace:
        # A stale log from an earlier run would be indistinguishable from a tracer that never
        # installed, so remove it first.
        if passtrace_path.exists():
            passtrace_path.unlink()
        extras.append(PASSTRACE_BLOCK.replace("__PASSTRACE_OUT__", cli.lua_path(passtrace_path)))
    if stretch_dump:
        # Stale grids from an earlier run would be indistinguishable from a seam that never fired.
        for env in ("surface", "underground"):
            for stage in ("pre", "post"):
                stale = OUT / f"stretch-{tag}-{env}-{stage}.raw"
                if stale.exists():
                    stale.unlink()
        extras.append(STRETCH_DUMP_BLOCK.replace(
            "__STRETCH_DUMP__", cli.lua_path(OUT / f"stretch-{tag}")))
    gen_src = gen_src.replace("__EXTRA_SETUP__", "\n\n".join(extras))
    gen_path = OUT / f"gen-{tag}.lua"
    gen_path.write_text(gen_src, encoding="utf-8")

    proc, lf = spawn_game(tag)
    try:
        log(f"connecting DAP ({tag})...")
        client = dap.connect(retry_timeout=180.0)
        err = cli.ensure_harness(client)
        if err:
            raise RuntimeError(f"harness injection failed: {err[2]}")
        log(f"harness ready ({tag})")

        load_err, prose = cli.load_lua_file(client, gen_path, timeout=60.0)
        if load_err:
            raise RuntimeError(f"gen script failed to load: {load_err[2]}")
        log(f"generation started ({tag}): {prose}")

        status = poll_status(
            client, "g_ParityStatus", {"complete"}, {"error"}, max_wait, f"gen-{tag}"
        )
        if status != "complete":
            _, detail = cli.marshal_value(client, "g_ParityError", timeout=60.0)
            raise RuntimeError(f"generation failed ({tag}): {detail}")
        log(f"generation complete ({tag})")

        _, surface_seed = cli.marshal_value(client, "g_ParitySurfaceSeed", timeout=60.0)
        _, underground_seed = cli.marshal_value(client, "g_ParityUndergroundSeed", timeout=60.0)
        log(f"  surface seed={surface_seed}  underground seed={underground_seed}")
        if pin_seed is not None and not expand and underground_seed != int(pin_seed):
            raise RuntimeError(
                f"vanilla underground pin not honoured ({tag}): holder seed "
                f"{underground_seed} != pin {int(pin_seed)}"
            )

        tag_order = None
        if tag_order_pin:
            # A silently inert canonicalization would produce a racing control that still looks
            # pinned, so read the counters back and fail the twin unless the pin installed and
            # actually snapshotted tag sets.
            _, to_status = cli.marshal_value(client, "g_ParityTagOrderPin", timeout=60.0)
            _, to_tables = cli.marshal_value(client, "g_ParityTagOrderTables", timeout=60.0)
            _, to_multi = cli.marshal_value(client, "g_ParityTagOrderMulti", timeout=60.0)
            _, to_hits = cli.marshal_value(client, "g_ParityTagOrderHits", timeout=60.0)
            _, to_refresh = cli.marshal_value(client, "g_ParityTagOrderRefresh", timeout=60.0)
            _, to_envs = cli.marshal_value(client, "g_ParityTagOrderEnvs", timeout=60.0)
            tag_order = {
                "status": to_status, "tables": to_tables, "multi_tag": to_multi,
                "hits": to_hits, "refreshes": to_refresh, "envs": to_envs,
            }
            if to_status != "installed" or not to_tables:
                raise RuntimeError(
                    f"group-tag order pin not established ({tag}): {tag_order}"
                )
            log(f"  group-tag order pin: tables={to_tables} multi_tag={to_multi} "
                f"iterations={to_hits} refreshes={to_refresh} envs={to_envs}")
            # Zero hits means no prefab tag set was walked through the pinned `pairs` at all, i.e.
            # nothing was canonicalized - the run is NOT pinned against this input.  Loud, but not
            # fatal: a preset with prefab grouping disabled legitimately never reaches the fold.
            if not to_hits:
                log(f"  TAGORDER WARNING ({tag}): the pinned pairs was never used by a prefab "
                    f"group-tag walk; this run is not canonicalized")

        pin_around, pin_passable, pin_calls = None, None, None
        if passage_pin:
            # A silently uninstalled pin would produce a racing control that still looks like a
            # pinned run, so read the counters back and fail the twin when the block did not run.
            _, pin_applied = cli.marshal_value(client, "g_ParityPassagePin", timeout=60.0)
            _, pin_around = cli.marshal_value(client, "g_ParityPassagePinAround", timeout=60.0)
            _, pin_passable = cli.marshal_value(client, "g_ParityPassagePinPassable", timeout=60.0)
            if pin_applied != int(PASSAGE_FALLBACK_PIN_SEED):
                raise RuntimeError(
                    f"passage-fallback pin never installed ({tag}): g_ParityPassagePin="
                    f"{pin_applied!r}"
                )
            # Zero is legitimate at a coordinate where the buildable search never fails.
            log(f"  passage-fallback pin seed={pin_applied} redirected_around={pin_around} "
                f"redirected_passable={pin_passable}")
            # iter-007: the per-redirect record (arguments + returned point), so the control's
            # and the expanded twin's fallback calls can be compared line by line.
            _, pin_calls = cli.marshal_value(client, "g_ParityPassagePinCalls", timeout=60.0)
            if isinstance(pin_calls, list) and pin_calls:
                pin_calls_path = OUT / f"passagepincalls-{tag}.log"
                pin_calls_path.write_text(
                    "\n".join(str(line) for line in pin_calls) + "\n", encoding="utf-8"
                )
                for line in pin_calls:
                    log(f"  pin call {line}")
                log(f"  passage-fallback pin calls -> {pin_calls_path}")

        if point_probe:
            # The seed sweep at the fallback call site.  A silent zero-call sweep would look
            # like agreement, so fail the twin when the probe never saw the redirected call.
            _, probe_calls = cli.marshal_value(client, "g_ParityPointProbeCalls", timeout=60.0)
            _, probe_rows = cli.marshal_value(client, "g_ParityPointProbe", timeout=60.0)
            if not probe_calls:
                raise RuntimeError(
                    f"point probe never saw a caller-less fallback call ({tag}): "
                    f"g_ParityPointProbeCalls={probe_calls!r}"
                )
            point_path = OUT / f"pointprobe-{tag}.log"
            point_path.write_text(
                "\n".join(str(line) for line in (probe_rows or [])) + "\n", encoding="utf-8"
            )
            log(f"point probe: {probe_calls} call(s), {len(probe_rows or [])} records "
                f"-> {point_path}")

        if field_probe:
            # Same contract as the point probe: a sweep that never saw the redirected call would
            # look like agreement, so fail the twin instead of writing an empty log.
            _, field_calls = cli.marshal_value(client, "g_ParityFieldProbeCalls", timeout=60.0)
            _, field_rows = cli.marshal_value(client, "g_ParityFieldProbe", timeout=120.0)
            if not field_calls:
                raise RuntimeError(
                    f"field probe never saw a caller-less fallback call ({tag}): "
                    f"g_ParityFieldProbeCalls={field_calls!r}"
                )
            field_path = OUT / f"fieldprobe-{tag}.log"
            field_path.write_text(
                "\n".join(str(line) for line in (field_rows or [])) + "\n", encoding="utf-8"
            )
            log(f"field probe: {field_calls} call(s), {len(field_rows or [])} records "
                f"-> {field_path}")

        if slot_probe:
            # Same contract as the point/field probes: a probe that never saw the redirected call
            # would produce an empty slot picture that reads like a measurement, so fail the twin.
            _, slot_calls = cli.marshal_value(client, "g_ParitySlotProbeCalls", timeout=60.0)
            _, slot_rows = cli.marshal_value(client, "g_ParitySlotProbe", timeout=120.0)
            if not slot_calls:
                raise RuntimeError(
                    f"slot probe never saw a caller-less fallback call ({tag}): "
                    f"g_ParitySlotProbeCalls={slot_calls!r}"
                )
            slot_path = OUT / f"slotprobe-{tag}.log"
            slot_path.write_text(
                "\n".join(str(line) for line in (slot_rows or [])) + "\n", encoding="utf-8"
            )
            log(f"slot probe: {slot_calls} call(s), {len(slot_rows or [])} records "
                f"-> {slot_path}")

        if decal_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                probe_status = poll_status(
                    client, "g_ParityProbeStatus", {"complete"}, set(), 120, f"probe-{tag}"
                )
            except RuntimeError as exc:
                probe_status = f"unavailable ({exc})"
            log(f"decal probe: {probe_status} -> {probe_path}")

        if camera_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                cam_status = poll_status(
                    client, "g_ParityCamProbeStatus", {"complete"}, set(), 120, f"camera-{tag}"
                )
            except RuntimeError as exc:
                cam_status = f"unavailable ({exc})"
            log(f"camera probe: {cam_status} -> {cam_path}")

        if pit_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                pit_status = poll_status(
                    client, "g_ParityPitProbeStatus", {"complete"}, set(), 120, f"pit-{tag}"
                )
            except RuntimeError as exc:
                pit_status = f"unavailable ({exc})"
            log(f"pit probe: {pit_status} -> {pit_path}")

        if decor_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                decor_status = poll_status(
                    client, "g_ParityDecorProbeStatus", {"complete"}, set(), 180, f"decor-{tag}"
                )
            except RuntimeError as exc:
                decor_status = f"unavailable ({exc})"
            log(f"decor probe: {decor_status} -> {decor_path}")

        if mark_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                mark_status = poll_status(
                    client, "g_ParityMarkProbeStatus", {"complete"}, set(), 180, f"mark-{tag}"
                )
            except RuntimeError as exc:
                mark_status = f"unavailable ({exc})"
            log(f"mark probe: {mark_status} -> {mark_path}")

        if play_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                play_status = poll_status(
                    client, "g_ParityPlayProbeStatus", {"complete"}, set(), 180, f"playprobe-{tag}"
                )
            except RuntimeError as exc:
                play_status = f"unavailable ({exc})"
            log(f"playable-procedure probe: {play_status} -> {play_path}")

        if proc_trace:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                proc_status = poll_status(
                    client, "g_ParityProcTraceStatus", {"complete"}, set(), 180, f"proctrace-{tag}"
                )
            except RuntimeError as exc:
                proc_status = f"unavailable ({exc})"
            log(f"procedure trace: {proc_status} -> {proc_path}")

        if pass_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                pass_status = poll_status(
                    client, "g_ParityPassProbeStatus", {"complete"}, set(), 180, f"passprobe-{tag}"
                )
            except RuntimeError as exc:
                pass_status = f"unavailable ({exc})"
            log(f"passage probe: {pass_status} -> {pass_path}")

        if draw_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                draw_status = poll_status(
                    client, "g_ParityDrawProbeStatus", {"complete"}, set(), 180, f"drawprobe-{tag}"
                )
            except RuntimeError as exc:
                draw_status = f"unavailable ({exc})"
            log(f"draw probe: {draw_status} -> {draw_path}")

        if anom_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                anom_status = poll_status(
                    client, "g_ParityAnomProbeStatus", {"complete"}, set(), 180, f"anomprobe-{tag}"
                )
            except RuntimeError as exc:
                anom_status = f"unavailable ({exc})"
            _, anom_calls = cli.marshal_value(client, "g_ParityAnomProbeCalls", timeout=60.0)
            log(f"anomaly probe: {anom_status}, {anom_calls} initializer call(s) -> {anom_path}")

        if flatten_probe:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                flatten_status = poll_status(
                    client, "g_ParityFlattenProbeStatus", {"complete"}, set(), 180,
                    f"flattenprobe-{tag}"
                )
            except RuntimeError as exc:
                flatten_status = f"unavailable ({exc})"
            _, flatten_calls = cli.marshal_value(client, "g_ParityFlattenProbeCalls", timeout=60.0)
            log(f"flatten probe: {flatten_status}, {flatten_calls} flatten call(s) -> {flatten_path}")

        if pass_trace:
            # Diagnostic only: never fail the twin because the tracer's file lagged.
            try:
                trace_status = poll_status(
                    client, "g_ParityPassTraceStatus", {"complete"}, set(), 180,
                    f"passtrace-{tag}"
                )
            except RuntimeError as exc:
                trace_status = f"unavailable ({exc})"
            _, trace_calls = cli.marshal_value(client, "g_ParityPassTraceCalls", timeout=60.0)
            _, trace_changes = cli.marshal_value(client, "g_ParityPassTraceChanges", timeout=60.0)
            log(f"pass trace: {trace_status}, {trace_calls} traced call(s), "
                f"{trace_changes} digest change(s) -> {passtrace_path}")

        # Temporary determinism diagnostics: prove the serial pin reached the table the
        # generator's own compiled body reads, instead of a shadowed ambient `const`.
        rows, csv_path, hex_path = dump_and_census(
            client, tag, hexgrid, wonder_probe=wonder_probe,
            ring_scale=(8192.0 / 6144.0) if expand else 1.0,
            pass_probe_all=pass_probe_all, zones_probe=zones_probe,
            pass_real_probe=pass_real_probe, pass_lattice_probe=pass_lattice_probe,
            pass_rebuild_probe=pass_rebuild_probe, pass_mask_probe=pass_mask_probe,
            pass_forced_probe=pass_forced_probe, pass_writer_probe=pass_writer_probe,
            pass_own_probe=pass_own_probe, pass_ablate_probe=pass_ablate_probe,
            pass_imprint_probe=pass_imprint_probe, pass_move_probe=pass_move_probe,
            pass_class_probe=pass_class_probe, pass_vis_probe=pass_vis_probe,
            pass_fix_probe=pass_fix_probe, build_probe=build_probe,
            property_probe=property_probe, perimeter_probe=perimeter_probe,
            perimeter_full_probe=perimeter_full_probe)
        for var, label in (("g_ParityRasterTables", "raster const tables patched"),
                           ("g_ParityRasterDivBefore", "raster div before"),
                           ("g_ParityRasterDivAfter", "raster div seen by generator")):
            try:
                _, v = cli.marshal_value(client, var, timeout=30.0)
                if v is not None:
                    log(f"  {label}: {v}")
            except Exception:
                pass

        savegame = None
        if save_as:
            # AFTER the dump and the census, so this twin's dump stays byte-comparable with a
            # run that never saved.
            savegame = save_session(client, tag, save_as)

        try:
            client.evaluate("quit()", timeout=5.0)
        except Exception:
            pass
        return {
            "tag": tag,
            "expand": expand,
            "surface_seed": surface_seed,
            "underground_seed": underground_seed,
            "underground_pin": None if (expand or pin_seed is None) else int(pin_seed),
            "passage_pin": int(PASSAGE_FALLBACK_PIN_SEED) if passage_pin else None,
            "passage_pin_around": pin_around,
            "passage_pin_passable": pin_passable,
            "passage_pin_calls": pin_calls,
            "tag_order_pin": tag_order,
            "rows": rows,
            "csv": str(csv_path),
            "hexgrid": str(hex_path) if hexgrid else None,
            "savegame": savegame,
        }
    finally:
        time.sleep(2)
        if keep_alive:
            # Leave the finished game running so a follow-up probe can attach to the
            # generated map. The CALLER owns teardown from here.
            log(f"keepalive: leaving MarsDebug pid={proc.pid} running for the probe")
            lf.close()
        else:
            try:
                proc.terminate()
                proc.wait(timeout=20)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
            lf.close()


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    # Generic mode: "twin <tag> <expand 0|1> [twin_seed] [serial]"
    if len(sys.argv) >= 4 and sys.argv[1] == "twin":
        tag = sys.argv[2]
        expand = sys.argv[3] == "1"
        seed = int(sys.argv[4]) if len(sys.argv) > 4 and sys.argv[4] not in ("-", "") else None
        serial = "serial" in sys.argv[5:]
        probe = "probe" in sys.argv[5:]
        camera = "cameraprobe" in sys.argv[5:]
        fxprobe = "fxprobe" in sys.argv[5:]
        pitprobe = "pitprobe" in sys.argv[5:]
        decorprobe = "decorprobe" in sys.argv[5:]
        markprobe = "markprobe" in sys.argv[5:]
        entranceaudit = "entranceaudit" in sys.argv[5:]
        proctrace = "proctrace" in sys.argv[5:]
        playprobe = "playprobe" in sys.argv[5:]
        passprobe = "passprobe" in sys.argv[5:]
        drawprobe = "drawprobe" in sys.argv[5:]
        passagepin = "passagepin" in sys.argv[5:]
        tagorder = "tagorder" in sys.argv[5:]
        pointprobe = "pointprobe" in sys.argv[5:]
        fieldprobe = "fieldprobe" in sys.argv[5:]
        slotprobe = "slotprobe" in sys.argv[5:]
        anomprobe = "anomprobe" in sys.argv[5:]
        placeprobe = "placeprobe" in sys.argv[5:]
        keepalive = "keepalive" in sys.argv[5:]
        wonderprobe = "wonderprobe" in sys.argv[5:]
        passall = "passall" in sys.argv[5:]
        zonesprobe = "zonesprobe" in sys.argv[5:]
        stretchdump = "stretchdump" in sys.argv[5:]
        flattenprobe = "flattenprobe" in sys.argv[5:]
        passtrace = "passtrace" in sys.argv[5:]
        passreal = "passreal" in sys.argv[5:]
        passlattice = "passlattice" in sys.argv[5:]
        passrebuild = "passrebuild" in sys.argv[5:]
        passmask = "passmask" in sys.argv[5:]
        passforced = "passforced" in sys.argv[5:]
        passwriter = "passwriter" in sys.argv[5:]
        passown = "passown" in sys.argv[5:]
        passablate = "passablate" in sys.argv[5:]
        passimprint = "passimprint" in sys.argv[5:]
        passmove = "passmove" in sys.argv[5:]
        passclass = "passclass" in sys.argv[5:]
        passvis = "passvis" in sys.argv[5:]
        passfix = "passfix" in sys.argv[5:]
        buildableprobe = "buildableprobe" in sys.argv[5:]
        propertyprobe = "propertyprobe" in sys.argv[5:]
        perimeterprobe = "perimeterprobe" in sys.argv[5:]
        perimeterfull = "perimeterfull" in sys.argv[5:]
        hexgrid = "hexgrid" in sys.argv[5:]
        # "saveas=<display>" saves the finished session through the engine's own SaveGame path
        # after the dump and the census, for the save-roundtrip acceptance condition.
        save_as = None
        for extra in sys.argv[5:]:
            if extra.startswith("saveas="):
                save_as = extra[7:]
        # A vanilla control is pinned to the reference underground unless "nopin" is passed;
        # an explicit seed argument overrides which underground it is pinned to.
        pin = None if expand or "nopin" in sys.argv[5:] else (seed or REFERENCE_UNDERGROUND_SEED)
        lat, lon = 1800, 8760
        for extra in sys.argv[5:]:
            if extra.startswith("lat="): lat = int(extra[4:])
            if extra.startswith("lon="): lon = int(extra[4:])
        log(f"=== twin '{tag}' expand={expand} seed={seed} pin={pin} "
            f"serial_raster={serial} decal_probe={probe} camera_probe={camera} "
            f"fx_probe={fxprobe} pit_probe={pitprobe} decor_probe={decorprobe} "
            f"mark_probe={markprobe} entrance_audit={entranceaudit} proc_trace={proctrace} "
            f"pass_probe={passprobe} draw_probe={drawprobe} passage_pin={passagepin} "
            f"tag_order_pin={tagorder} "
            f"point_probe={pointprobe} field_probe={fieldprobe} slot_probe={slotprobe} "
            f"anom_probe={anomprobe} play_probe={playprobe} hexgrid={hexgrid} "
            f"stretch_dump={stretchdump} flatten_probe={flattenprobe} "
            f"pass_trace={passtrace} "
            f"pass_real_probe={passreal} pass_lattice_probe={passlattice} "
            f"pass_rebuild_probe={passrebuild} pass_mask_probe={passmask} "
            f"pass_forced_probe={passforced} pass_writer_probe={passwriter} "
            f"pass_own_probe={passown} pass_ablate_probe={passablate} "
            f"pass_imprint_probe={passimprint} pass_move_probe={passmove} "
            f"pass_class_probe={passclass} pass_vis_probe={passvis} "
            f"pass_fix_probe={passfix} build_probe={buildableprobe} "
            f"property_probe={propertyprobe} perimeter_probe={perimeterprobe} "
            f"perimeter_full_probe={perimeterfull} "
            f"save_as={save_as} lat={lat} lon={lon} ===")
        info = run_twin(tag, expand=expand, twin_seed=seed, serial_raster=serial, lat=lat, lon=lon,
                        pin_seed=pin, decal_probe=probe, hexgrid=hexgrid, camera_probe=camera,
                        fx_probe=fxprobe, pit_probe=pitprobe, decor_probe=decorprobe,
                        mark_probe=markprobe, entrance_audit=entranceaudit, proc_trace=proctrace,
                        pass_probe=passprobe, draw_probe=drawprobe, passage_pin=passagepin,
                        point_probe=pointprobe, field_probe=fieldprobe, slot_probe=slotprobe,
                        anom_probe=anomprobe, place_probe=placeprobe, play_probe=playprobe,
                        tag_order_pin=tagorder, save_as=save_as,
                        keep_alive=keepalive, wonder_probe=wonderprobe,
                        pass_probe_all=passall, zones_probe=zonesprobe,
                        stretch_dump=stretchdump, flatten_probe=flattenprobe,
                        pass_trace=passtrace,
                        pass_real_probe=passreal, pass_lattice_probe=passlattice,
                        pass_rebuild_probe=passrebuild, pass_mask_probe=passmask,
                        pass_forced_probe=passforced,
                        pass_writer_probe=passwriter, pass_own_probe=passown,
                        pass_ablate_probe=passablate, pass_imprint_probe=passimprint,
                        pass_move_probe=passmove, pass_class_probe=passclass,
                        pass_vis_probe=passvis, pass_fix_probe=passfix,
                        build_probe=buildableprobe, property_probe=propertyprobe,
                        perimeter_probe=perimeterprobe,
                        perimeter_full_probe=perimeterfull)
        log(f"result: {json.dumps(info)}")
        return

    # Save-roundtrip mode: "load <tag> <savename> [hexgrid]" boots a FRESH game, loads that
    # savegame and recounts both maps with the twins' own dump.  No generation happens.
    if len(sys.argv) >= 4 and sys.argv[1] == "load":
        tag, savename = sys.argv[2], sys.argv[3]
        hexgrid = "hexgrid" in sys.argv[4:]
        log(f"=== load '{tag}' savename={savename} hexgrid={hexgrid} ===")
        info = run_load(tag, savename, hexgrid=hexgrid)
        log(f"result: {json.dumps(info)}")
        return

    # Resume mode: "expanded <vanilla_underground_seed>" reuses an existing vanilla dump.
    if len(sys.argv) >= 3 and sys.argv[1] == "expanded":
        seed = int(sys.argv[2])
        log(f"=== resume: EXPANDED twin only (twin seed {seed}) ===")
        expanded = run_twin("expanded", expand=True, twin_seed=seed)
        meta_path = OUT / "run_metadata.json"
        report = json.loads(meta_path.read_text(encoding="utf-8")) if meta_path.exists() else {}
        report["expanded"] = expanded
        meta_path.write_text(json.dumps(report, indent=2), encoding="utf-8")
        log(f"metadata -> {meta_path}")
        return

    # The hex-grid census is REQUIRED in the default pair mode: compare.py only grants
    # `GridObjectList` its derived-cardinality exemption when this run proves the rule
    # (section E), so a censusless pair would leave ~880 records unexplained for no
    # reason.  It is read-only and proven inert (byte-identical dumps, iterations 005-009),
    # and it runs after the object dump.  "nohexgrid" opts out deliberately.
    hexgrid = "nohexgrid" not in sys.argv[1:]
    log(f"=== 30S146E parity run: VANILLA twin (underground pinned to "
        f"{REFERENCE_UNDERGROUND_SEED}, hexgrid={hexgrid}) ===")
    vanilla = run_twin("vanilla", expand=False, twin_seed=None,
                       pin_seed=REFERENCE_UNDERGROUND_SEED, hexgrid=hexgrid)

    if not isinstance(vanilla["underground_seed"], (int, float)):
        raise RuntimeError(
            f"vanilla underground seed unusable: {vanilla['underground_seed']!r}"
        )

    log("=== 30S146E parity run: EXPANDED twin ===")
    expanded = run_twin("expanded", expand=True, twin_seed=int(vanilla["underground_seed"]),
                        hexgrid=hexgrid)

    report = {"vanilla": vanilla, "expanded": expanded}
    (OUT / "run_metadata.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    log(f"metadata -> {OUT / 'run_metadata.json'}")
    log("surface seed match:     "
        f"{vanilla['surface_seed'] == expanded['surface_seed']} "
        f"({vanilla['surface_seed']} vs {expanded['surface_seed']})")
    log("underground seed match: "
        f"{vanilla['underground_seed'] == expanded['underground_seed']} "
        f"({vanilla['underground_seed']} vs {expanded['underground_seed']})")


if __name__ == "__main__":
    main()
