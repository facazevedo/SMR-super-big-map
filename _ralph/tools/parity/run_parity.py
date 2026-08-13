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

# The stock underground seed is drawn from AsyncRand inside FillRandomMapGen
# (ModTools PreGameMenus.lua:166, because MapData["BlankUnderground_0X"].map_randomizeseed
# is true), so three identical vanilla runs generated three different undergrounds
# (6504 / 6327 / 6560 objects) and no underground gate could be scored across runs.
# Pin the control to one fixed reference underground instead.  The value below is a real
# AsyncRand draw captured from the iteration-001 vanilla twin, which is the underground the
# ratchet baseline in artifacts/best.json was measured on, so pinned runs compare directly
# against it.
REFERENCE_UNDERGROUND_SEED = 6074387974731471656

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


SERIAL_RASTER_BLOCK = """		-- Match the mod's source-capture transaction: stock prefab rasterization launches
		-- PrefabRasterParallelDiv^2 real-time tasks that share the placement-mark grid used by
		-- Proc_RemoveOverlappedObjects, so task completion order can pick a different overlap
		-- winner run-to-run.  The mod forces 1 while generating its vanilla source
		-- (sbm_map_generation.lua:10144).  A control that does not do the same is not reproducible.
		if type(const) == "table" then
			g_ParityRasterDivBefore = const.PrefabRasterParallelDiv
			const.PrefabRasterParallelDiv = 1
			if const.PrefabRasterParallelDiv ~= 1 then
				error("could not serialize prefab rasterization for the control")
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


def run_twin(tag, expand, twin_seed, serial_raster=False, max_wait=1800, lat=1800, lon=8760,
             pin_seed=None, decal_probe=False, hexgrid=False, camera_probe=False,
             fx_probe=False, pit_probe=False, decor_probe=False, mark_probe=False,
             entrance_audit=False, proc_trace=False):
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
    proc_path = OUT / f"proctrace-{tag}.log"
    if proc_trace:
        if proc_path.exists():
            proc_path.unlink()
        extras.append(PROC_TRACE_BLOCK.replace("__PROC_OUT__", cli.lua_path(proc_path)))
    gen_src = gen_src.replace("__EXTRA_SETUP__", "\n\n".join(extras))
    gen_path = OUT / f"gen-{tag}.lua"
    gen_path.write_text(gen_src, encoding="utf-8")

    dump_src = DUMP_TEMPLATE.read_text(encoding="utf-8")
    dump_src = dump_src.replace("__OUT_PATH__", cli.lua_path(csv_path))
    dump_path = OUT / f"dump-{tag}.lua"
    dump_path.write_text(dump_src, encoding="utf-8")

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

        if proc_trace:
            # Diagnostic only: never fail the twin because the probe file lagged.
            try:
                proc_status = poll_status(
                    client, "g_ParityProcTraceStatus", {"complete"}, set(), 180, f"proctrace-{tag}"
                )
            except RuntimeError as exc:
                proc_status = f"unavailable ({exc})"
            log(f"procedure trace: {proc_status} -> {proc_path}")

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
            "rows": rows,
            "csv": str(csv_path),
            "hexgrid": str(hex_path) if hexgrid else None,
        }
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
        hexgrid = "hexgrid" in sys.argv[5:]
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
            f"hexgrid={hexgrid} lat={lat} lon={lon} ===")
        info = run_twin(tag, expand=expand, twin_seed=seed, serial_raster=serial, lat=lat, lon=lon,
                        pin_seed=pin, decal_probe=probe, hexgrid=hexgrid, camera_probe=camera,
                        fx_probe=fxprobe, pit_probe=pitprobe, decor_probe=decorprobe,
                        mark_probe=markprobe, entrance_audit=entranceaudit, proc_trace=proctrace)
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
