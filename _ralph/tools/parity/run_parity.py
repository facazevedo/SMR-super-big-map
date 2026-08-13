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


# Diagnostic only, opt-in with the "probe" argument.  The expanded underground dumps zero
# SectorUnexplored overview decals while its surface dumps 399, and the raw dump cannot say
# whether they are never created or created and then destroyed.  This block wraps
# MapSector:UpdateDecal (creation outcome), DoneObject/DoneObjects (destruction, with a
# traceback for the first few sector decals) and samples a per-map census, then writes the
# timeline beside the run logs.  It changes no generation input and consumes no map RNG.
DECAL_PROBE_BLOCK = """		do
			local probe_lines = {}
			local probe_tracebacks = 0
			local function probe_ticks()
				if type(GetPreciseTicks) == "function" then return GetPreciseTicks() end
				return 0
			end
			local probe_t0 = probe_ticks()
			local function probe_log(text)
				if #probe_lines >= 4000 then return end
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

			local sector_class = rawget(_G, "g_Classes") and g_Classes.MapSector
			if sector_class and type(sector_class.UpdateDecal) == "function" then
				local original_update = sector_class.UpdateDecal
				local update_calls, update_with_decal = {}, {}
				g_ParityProbeUpdateCalls = update_calls
				sector_class.UpdateDecal = function(self, ...)
					local result = original_update(self, ...)
					local key = probe_env(probe_map_of(self))
					update_calls[key] = (update_calls[key] or 0) + 1
					if IsValid(self.decal) then
						update_with_decal[key] = (update_with_decal[key] or 0) + 1
					end
					if (update_calls[key] % 100) == 1 then
						probe_log(string.format("UpdateDecal %s calls=%d with_decal=%d status=%s",
							key, update_calls[key], update_with_decal[key] or 0,
							tostring(self.status)))
					end
					return result
				end
				probe_log("wrapped MapSector:UpdateDecal")
			else
				probe_log("MapSector:UpdateDecal unavailable - creation side not instrumented")
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
					for i = 1, #(rawget(_G, "Maps") or {}) do
						local m = Maps[i]
						if m and type(m.MapGet) == "function" then
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
				local werr = AsyncStringToFile("__PROBE_OUT__", table.concat(probe_lines, "\\n"))
				g_ParityProbeStatus = werr and ("error: " .. tostring(werr)) or "complete"
			end)
		end"""


def run_twin(tag, expand, twin_seed, serial_raster=False, max_wait=1800, lat=1800, lon=8760,
             pin_seed=None, decal_probe=False):
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
    probe_path = OUT / f"probe-{tag}.log"
    if decal_probe:
        if probe_path.exists():
            probe_path.unlink()
        extras.append(DECAL_PROBE_BLOCK.replace("__PROBE_OUT__", cli.lua_path(probe_path)))
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
        # A vanilla control is pinned to the reference underground unless "nopin" is passed;
        # an explicit seed argument overrides which underground it is pinned to.
        pin = None if expand or "nopin" in sys.argv[5:] else (seed or REFERENCE_UNDERGROUND_SEED)
        lat, lon = 1800, 8760
        for extra in sys.argv[5:]:
            if extra.startswith("lat="): lat = int(extra[4:])
            if extra.startswith("lon="): lon = int(extra[4:])
        log(f"=== twin '{tag}' expand={expand} seed={seed} pin={pin} "
            f"serial_raster={serial} decal_probe={probe} lat={lat} lon={lon} ===")
        info = run_twin(tag, expand=expand, twin_seed=seed, serial_raster=serial, lat=lat, lon=lon,
                        pin_seed=pin, decal_probe=probe)
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

    log(f"=== 30S146E parity run: VANILLA twin (underground pinned to "
        f"{REFERENCE_UNDERGROUND_SEED}) ===")
    vanilla = run_twin("vanilla", expand=False, twin_seed=None,
                       pin_seed=REFERENCE_UNDERGROUND_SEED)

    if not isinstance(vanilla["underground_seed"], (int, float)):
        raise RuntimeError(
            f"vanilla underground seed unusable: {vanilla['underground_seed']!r}"
        )

    log("=== 30S146E parity run: EXPANDED twin ===")
    expanded = run_twin("expanded", expand=True, twin_seed=int(vanilla["underground_seed"]))

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
