"""Run the pinned 10-coordinate parity sweep headlessly.

For each manifest case: one fresh-process vanilla twin, then one fresh-process
expanded twin with the vanilla underground seed injected, then compare.py.
Per-case verdict + the wonder-class census are written to sweep_results.json.

Usage:  python run_sweep.py [first_case] [last_case]
"""
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
PARITY = HERE.parent
RUN = PARITY / "run_parity.py"
COMPARE = PARITY / "compare.py"
OUT = PARITY / "out"
MANIFEST_NAME = next((a.split("=",1)[1] for a in sys.argv[1:] if a.startswith("manifest=")),
                     "sweep_manifest.json")
MANIFEST = json.loads((HERE / MANIFEST_NAME).read_text(encoding="utf-8"))
RESULTS = HERE / MANIFEST_NAME.replace("manifest", "results")
WONDERS = ("AncientArtifact", "CaveOfWonders", "BottomlessPit", "JumboCave")


def log(m):
    print(f"[{time.strftime('%H:%M:%S')}] {m}", flush=True)


def wait_port_free(port=8165, timeout=120):
    """Block until nothing is listening on the debug port.

    run_parity.py terminates its game in a finally block, but the port can stay
    bound for a few seconds afterwards.  Launching the next twin into a still-bound
    port makes the new game die in Debug::Init() without ever opening the adapter,
    which is what killed sweep-01 and sweep-05.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        s = socket.socket()
        s.settimeout(0.5)
        try:
            s.connect(("127.0.0.1", port))
        except OSError:
            s.close()
            time.sleep(3)          # settle margin after the port goes quiet
            return True
        s.close()
        time.sleep(2)
    return False


def run(args, timeout=3600):
    r = subprocess.run([sys.executable, *args], cwd=str(PARITY),
                       capture_output=True, text=True, timeout=timeout)
    return r.returncode, (r.stdout or "") + (r.stderr or "")


def run_twin_retrying(args, attempts=3):
    """Run one twin, retrying a debug-adapter startup failure.

    Roughly one game launch in three reaches `Render` and then dies in
    Debug::Init() without ever opening port 8165, so the harness cannot attach.
    It is intermittent, not coordinate-specific, and not the port race the
    wait above fixes - a fresh launch usually succeeds.  Only that failure is
    retried; a real generation error is returned to the caller unchanged.
    """
    for attempt in range(1, attempts + 1):
        wait_port_free()
        rc, outp = run(args)
        if rc == 0:
            return rc, outp, attempt
        if "could not connect+handshake" not in outp:
            return rc, outp, attempt          # genuine failure, do not mask it
        log(f"    attach failed (attempt {attempt}/{attempts}); relaunching")
        kill_stray_games()
        time.sleep(10)
    return rc, outp, attempts


def kill_stray_games():
    """No hung game may survive a failed attempt (task contract rule)."""
    subprocess.run(["taskkill", "/F", "/IM", "MarsDebug.exe"],
                   capture_output=True, text=True)


def census(csv_path):
    """Per-map class -> {scale: count}, for wonder coverage and scale checks."""
    out = {}
    if not csv_path.exists():
        return out
    for line in csv_path.read_text(encoding="utf-8", errors="replace").splitlines():
        if line.startswith("#") or not line:
            continue
        f = line.split(",")
        if len(f) < 14:
            continue
        out.setdefault(f[0], {}).setdefault(f[1], {}).setdefault(f[5], 0)
        out[f[0]][f[1]][f[5]] += 1
    return out


def main():
    cases = MANIFEST["cases"]
    lo = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    hi = int(sys.argv[2]) if len(sys.argv) > 2 else len(cases)
    results = json.loads(RESULTS.read_text(encoding="utf-8")) if RESULTS.exists() else {}

    for idx, c in enumerate(cases, start=1):
        n = idx
        if n < lo or n > hi:
            continue
        if "--redo" not in sys.argv and results.get(c["case"], {}).get("verdict") == "COMPARED":
            log(f"{c['case']} {c['label']}: already COMPARED, skipping")
            continue
        slug = c["case"].replace("-", "")
        tag_v, tag_e = f"f{slug}v", f"f{slug}e"
        log(f"=== {c['case']} {c['label']} lat={c['lat']} lon={c['lon']} ===")
        rec = {"case": c["case"], "label": c["label"], "lat": c["lat"], "lon": c["lon"]}

        rc, outp, tries = run_twin_retrying([str(RUN), "twin", tag_v, "0", "-",
                                             f"lat={c['lat']}", f"lon={c['lon']}", "nopin", "serial", "passagepin"])
        rec["vanilla_attempts"] = tries
        if rc != 0:
            rec["verdict"] = "VANILLA_FAILED"
            rec["error"] = outp[-1500:]
            log(f"  vanilla FAILED rc={rc}")
            results[c["case"]] = rec
            RESULTS.write_text(json.dumps(results, indent=2), encoding="utf-8")
            continue

        seed = None
        for line in outp.splitlines():
            if "underground seed=" in line:
                try:
                    seed = int(line.split("underground seed=")[1].split()[0])
                except Exception:
                    pass
        rec["vanilla_underground_seed"] = seed
        if seed is None:
            rec["verdict"] = "NO_SEED"
            results[c["case"]] = rec
            RESULTS.write_text(json.dumps(results, indent=2), encoding="utf-8")
            continue
        log(f"  vanilla ok, ug seed {seed}")

        rc, outp, tries = run_twin_retrying([str(RUN), "twin", tag_e, "1", str(seed),
                                             f"lat={c['lat']}", f"lon={c['lon']}", "serial", "passagepin"])
        rec["expanded_attempts"] = tries
        if rc != 0:
            rec["verdict"] = "EXPANDED_FAILED"
            rec["error"] = outp[-1500:]
            log(f"  expanded FAILED rc={rc}")
            results[c["case"]] = rec
            RESULTS.write_text(json.dumps(results, indent=2), encoding="utf-8")
            continue
        log("  expanded ok")

        # normalize dump names for compare.py, then compare
        for src, dst in ((f"objects-{tag_v}.csv", "objects-vanilla.csv"),
                         (f"objects-{tag_e}.csv", "objects-expanded.csv")):
            s, d = OUT / src, OUT / dst
            if s.exists():
                d.write_bytes(s.read_bytes())
        rc, outp = run([str(COMPARE), str(OUT)])
        rec["compare_rc"] = rc

        summ = OUT / "parity_summary.json"
        if summ.exists():
            data = json.loads(summ.read_text(encoding="utf-8"))
            rec["summary"] = {m: {k: v for k, v in data.get(m, {}).items()
                                  if k in ("seed_equal", "hash_equal",
                                           "content_bijection_ok", "content_matched",
                                           "content_vanilla_objects", "content_expanded_objects",
                                           "content_unmatched_expanded",
                                           "content_unstamped_expanded",
                                           "content_unconsumed_vanilla",
                                           "content_classes_differing", "content_class_diffs")}
                              for m in ("surface", "underground") if m in data}
            (HERE / f"parity_summary_{c['case']}.json").write_bytes(summ.read_bytes())
        rep = OUT / "parity_report.txt"
        if rep.exists():
            (HERE / f"parity_report_{c['case']}.txt").write_bytes(rep.read_bytes())

        cen = census(OUT / "objects-expanded.csv")
        cenv = census(OUT / "objects-vanilla.csv")
        found = sorted({w for m in cen for w in WONDERS if w in cen.get(m, {})})
        rec["wonders_present"] = found
        rec["wonder_scales"] = {w: {"vanilla": cenv.get("underground", {}).get(w),
                                    "expanded": cen.get("underground", {}).get(w)}
                                for w in found}
        rec["verdict"] = "COMPARED"
        log(f"  compared; wonders: {found or 'none'}")
        results[c["case"]] = rec
        RESULTS.write_text(json.dumps(results, indent=2), encoding="utf-8")

    cov = sorted({w for r in results.values() for w in r.get("wonders_present", [])})
    log(f"wonder classes seen so far: {cov}  missing: {sorted(set(WONDERS) - set(cov))}")
    log(f"results -> {RESULTS}")


if __name__ == "__main__":
    main()
