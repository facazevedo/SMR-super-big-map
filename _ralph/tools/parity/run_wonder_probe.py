"""Measure the terrain pocket around each underground wonder on both twins, and
capture matched close-ups.

The wonder OBJECT is already proven exact (position = source*4/3, scale 133, angle equal),
so a visible gap can only be the carved pocket in the terrain. Each twin samples height /
passability / buildable on concentric rings expressed in SOURCE world units (the expanded
twin multiplies the radius by the stretch ratio), so ring N on one twin is the geometrically
corresponding circle on the other. If the pocket scaled correctly the two profiles coincide
after scaling heights by the same ratio; a flatten radius that stayed unscaled shows up as a
ring band where they diverge.

Usage: python run_wonder_probe.py <lat> <lon> <underground_seed> [outdir]
"""
import json
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, r"D:\PROJS\SMR\smr-harness")
import dap
import cli

RATIO = 8192 / 6144


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def run_twin(tag, expand, seed, lat, lon, extra):
    args = [sys.executable, str(HERE / "run_parity.py"), "twin", tag,
            "1" if expand else "0", str(seed), f"lat={lat}", f"lon={lon}"] + extra
    r = subprocess.run(args, cwd=str(HERE), capture_output=True, text=True, timeout=3600)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def probe_live_game(ring_scale, csv_path, shot_path):
    """Attach to the game the twin run left running and execute the probe."""
    src = (HERE / "wonder_probe.lua").read_text(encoding="utf-8")
    src = src.replace("__RING_SCALE__", repr(float(ring_scale)))
    src = src.replace("__OUT_PATH__", cli.lua_path(csv_path))
    src = src.replace("__SHOT_PATH__", cli.lua_path(shot_path))
    rendered = HERE / "out" / f"wonder_probe_{csv_path.stem}.lua"
    rendered.write_text(src, encoding="utf-8")

    c = dap.connect(retry_timeout=120.0)
    err = cli.ensure_harness(c)
    if err:
        raise RuntimeError(f"harness: {err[2]}")
    load_err, prose = cli.load_lua_file(c, rendered, timeout=120.0)
    if load_err:
        raise RuntimeError(f"probe load failed: {load_err[2]}")
    log(f"  probe started: {prose.strip()[:60]}")
    deadline = time.time() + 900
    while time.time() < deadline:
        try:
            _, st = cli.marshal_value(c, "g_ParityWonderStatus", timeout=60.0)
            if st == "ready":
                _, info = cli.marshal_value(c, "g_ParityWonderInfo", timeout=60.0)
                log(f"  {info}")
                return info
            if st == "error":
                _, e = cli.marshal_value(c, "g_ParityWonderError", timeout=60.0)
                raise RuntimeError(f"probe error: {e}")
        except dap.DapTimeout:
            log("  (engine busy)")
        time.sleep(5)
    raise RuntimeError("probe timed out")


def main():
    lat, lon, seed = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
    outdir = Path(sys.argv[4]) if len(sys.argv) > 4 else HERE / "wonder"
    outdir.mkdir(parents=True, exist_ok=True)

    results = {}
    for tag, expand, ring_scale in (("wonV", False, 1.0), ("wonX", True, RATIO)):
        label = "vanilla" if not expand else "expanded"
        log(f"=== {label} twin at lat={lat} lon={lon} ===")
        # keepalive leaves the game running so the probe can attach to the finished map
        rc, out = run_twin(tag, expand, seed, lat, lon,
                           ["serial", "passagepin", "keepalive"])
        if rc != 0:
            log(f"  twin failed rc={rc}")
            print(out[-1500:])
            return 1
        csv_path = outdir / f"rings_{label}.csv"
        shot_path = outdir / f"wonder_{label}.png"
        info = probe_live_game(ring_scale, csv_path, shot_path)
        results[label] = {"info": info, "csv": str(csv_path), "shot": str(shot_path)}
        subprocess.run(["taskkill", "/F", "/IM", "MarsDebug.exe"],
                       capture_output=True, text=True)
        time.sleep(6)

    (outdir / "wonder_probe_runs.json").write_text(json.dumps(results, indent=2),
                                                   encoding="utf-8")
    log(f"results -> {outdir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
