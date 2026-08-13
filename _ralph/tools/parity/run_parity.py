"""Generate the 30S146E vanilla and expanded twins headlessly and dump every object.

Each twin runs in its OWN fresh MarsDebug.exe process so the vanilla control can
never be contaminated by mod state left behind by an expanded run (the failure mode
behind iterations 67-69).  The vanilla underground seed is carried across processes
through a JSON file and injected into the expanded twin with
SuperBigMap.MapGeneration.SetTwinUndergroundSeedForTest.

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


def run_twin(tag, expand, twin_seed, serial_raster=False, max_wait=1800, lat=1800, lon=8760):
    """Boot a fresh game, generate the twin, dump all objects.  Returns metadata."""
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
    gen_src = gen_src.replace(
        "__EXTRA_SETUP__", SERIAL_RASTER_BLOCK if serial_raster else ""
    )
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
        lat, lon = 1800, 8760
        for extra in sys.argv[5:]:
            if extra.startswith("lat="): lat = int(extra[4:])
            if extra.startswith("lon="): lon = int(extra[4:])
        log(f"=== twin '{tag}' expand={expand} seed={seed} serial_raster={serial} lat={lat} lon={lon} ===")
        info = run_twin(tag, expand=expand, twin_seed=seed, serial_raster=serial, lat=lat, lon=lon)
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

    log("=== 30S146E parity run: VANILLA twin ===")
    vanilla = run_twin("vanilla", expand=False, twin_seed=None)

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
