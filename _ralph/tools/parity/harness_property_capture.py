"""Capture deterministic property twins through the smr harness only.

The legacy ``run_parity.py`` owns the proven deterministic generation templates and
probe sources, but it starts MarsDebug directly.  This binder renders those same Lua
inputs and performs every live action through ``smr.cmd``.  Generated Lua belongs in
the shared Ralph temporary root; game-written evidence belongs in the current run's
artifact tree.

Typical workflow::

  python harness_property_capture.py prepare --case p1 --lat 1800 --lon 8760 \
    --vanilla-tag p1_v823a --expanded-tag p1_v823x --out manifest.json
  python harness_property_capture.py capture-pair --manifest manifest.json \
    --out capture_report.json

``capture-pair`` is fail-closed: each cold launch requires a clean Git worktree, the
expected commit, harness deployment mode ``missing``, and a green authoritative
external-payload audit.  Any failed harness command or game-side error captures the
tracked log and stops the tracked process in ``finally``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import py_compile
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import run_parity


PROJECT = Path(__file__).resolve().parents[3]
RUN_ROOT = PROJECT / "_ralph" / "runs" / "full-z-parity"
ARTIFACT_ROOT = RUN_ROOT / "artifacts"
TMP_ROOT = PROJECT / "_ralph" / "tmp"
SMR = Path(r"D:\PROJS\SMR\smr-harness\smr.cmd")
DEPLOY = PROJECT / "_ralph" / "tools" / "deploy.py"
DEFAULT_LUAC = Path(r"C:\Users\fazevedo\.claude\tools\lua-5.4.8\bin\luac.exe")
REFERENCE_UNDERGROUND_SEED = run_parity.REFERENCE_UNDERGROUND_SEED
PLACEHOLDER_PREFIX = "__"
STATUS_POLL_QUERY_SHA256 = "9f0a562cf2b897a575547d675bf06f4cdacd7b35ed143b78f78ad11f50128960"


class CaptureError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def lua_path(path: Path) -> str:
    return str(path.resolve()).replace("\\", "/")


def git(*args: str) -> str:
    proc = subprocess.run(
        ["git", *args], cwd=PROJECT, capture_output=True, text=True, timeout=30
    )
    if proc.returncode:
        raise CaptureError(proc.stderr.strip() or proc.stdout.strip() or "git failed")
    return proc.stdout.strip()


def unresolved(text: str) -> list[str]:
    tokens: set[str] = set()
    start = 0
    while True:
        left = text.find(PLACEHOLDER_PREFIX, start)
        if left < 0:
            break
        right = text.find(PLACEHOLDER_PREFIX, left + 2)
        if right < 0:
            break
        token = text[left : right + 2]
        body = token[2:-2]
        if body and all(ch == "_" or ch.isdigit() or "A" <= ch <= "Z" for ch in body):
            tokens.add(token)
        start = right + 2
    return sorted(tokens)


def render_generation(
    *, expand: bool, lat: int, lon: int, seed: int, stretch_base: Path
) -> str:
    text = run_parity.GEN_TEMPLATE.read_text(encoding="utf-8")
    text = text.replace(
        "__FLIGHT_SANITATION__",
        run_parity.FLIGHT_SANITATION.read_text(encoding="utf-8").rstrip(),
    )
    text = text.replace("__EXPAND__", "true" if expand else "false")
    text = text.replace("__LAT__", str(lat)).replace("__LON__", str(lon))
    if expand:
        text = text.replace(
            "__TWIN_SEED_BLOCK__", run_parity.TWIN_SEED_BLOCK.format(seed=seed)
        )
        text = text.replace("__UNDERGROUND_PIN_BLOCK__", "")
        extra = run_parity.STRETCH_DUMP_BLOCK.replace(
            "__STRETCH_DUMP__", lua_path(stretch_base)
        )
    else:
        text = text.replace("__TWIN_SEED_BLOCK__", "")
        text = text.replace(
            "__UNDERGROUND_PIN_BLOCK__",
            run_parity.UNDERGROUND_PIN_BLOCK.format(seed=seed),
        )
        extra = ""
    text = text.replace("__EXTRA_SETUP__", extra)
    missing = unresolved(text)
    if missing:
        raise CaptureError(f"generation template has unresolved placeholders: {missing}")
    return text


def render_probe(name: str, placeholder: str, output_base: Path) -> str:
    path = Path(__file__).resolve().parent / name
    text = path.read_text(encoding="utf-8").replace(placeholder, lua_path(output_base))
    missing = unresolved(text)
    if missing:
        raise CaptureError(f"{name} has unresolved placeholders: {missing}")
    return text


def compile_lua(luac: Path, paths: list[Path]) -> None:
    if not luac.is_file():
        raise CaptureError(f"Lua compiler missing: {luac}")
    for path in paths:
        proc = subprocess.run(
            [str(luac), "-p", str(path)], capture_output=True, text=True, timeout=30
        )
        if proc.returncode:
            raise CaptureError(
                f"Lua parse failed for {path}: {proc.stderr.strip() or proc.stdout.strip()}"
            )


def render_case(
    staging: Path,
    capture_dir: Path,
    *,
    lat: int,
    lon: int,
    vanilla_tag: str,
    expanded_tag: str,
    seed: int,
    luac: Path,
) -> dict[str, object]:
    staging.mkdir(parents=True, exist_ok=False)
    capture_dir.mkdir(parents=True, exist_ok=False)
    twins: dict[str, dict[str, object]] = {}
    lua_files: list[Path] = []
    for kind, expand, tag in (
        ("vanilla", False, vanilla_tag),
        ("expanded", True, expanded_tag),
    ):
        generation = staging / f"gen-{tag}.lua"
        height_probe = staging / f"zonesprobe-{tag}.lua"
        property_probe = staging / f"propertyprobe-{tag}.lua"
        stretch_base = capture_dir / f"stretch-{tag}"
        generation.write_text(
            render_generation(
                expand=expand, lat=lat, lon=lon, seed=seed, stretch_base=stretch_base
            ),
            encoding="utf-8",
        )
        height_probe.write_text(
            render_probe(
                "height_dump_probe.lua", "__OUT_BASE__", capture_dir / f"height-{tag}"
            ),
            encoding="utf-8",
        )
        property_probe.write_text(
            render_probe(
                "property_probe.lua", "__OUT_BASE__", capture_dir / f"property-{tag}"
            ),
            encoding="utf-8",
        )
        paths = [generation, height_probe, property_probe]
        lua_files.extend(paths)
        twins[kind] = {
            "tag": tag,
            "expand": expand,
            "generation": str(generation),
            "height_probe": str(height_probe),
            "property_probe": str(property_probe),
        }
    compile_lua(luac, lua_files)
    return {
        "schema": "smr.ralph.harness-property-capture-manifest.v1",
        "project": str(PROJECT),
        "git_head": git("rev-parse", "HEAD"),
        "coordinate": {"lat": lat, "lon": lon},
        "reference_underground_seed": seed,
        "staging": str(staging),
        "capture_dir": str(capture_dir),
        "luac": str(luac),
        "twins": twins,
        "lua": [
            {"path": str(path), "bytes": path.stat().st_size, "sha256": sha256_file(path)}
            for path in lua_files
        ],
    }


def smr(args: list[str], events: list[dict[str, object]], timeout: float) -> dict:
    command = [str(SMR), *args, "--json"]
    started = time.time()
    proc = subprocess.run(
        command, cwd=PROJECT, capture_output=True, text=True, timeout=timeout
    )
    try:
        envelope = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise CaptureError(
            f"smr produced non-JSON output for {args}: {proc.stdout!r} {proc.stderr!r}"
        ) from exc
    events.append(
        {
            "args": args,
            "returncode": proc.returncode,
            "elapsed_s": round(time.time() - started, 3),
            "envelope": envelope,
            "stderr": proc.stderr.strip(),
        }
    )
    if proc.returncode or envelope.get("ok") is not True:
        raise CaptureError(f"smr command failed ({proc.returncode}): {' '.join(args)}")
    return envelope


def state_value(query: str, events: list[dict[str, object]], timeout: float = 90) -> object:
    envelope = smr(["state", query, "--timeout", str(timeout)], events, timeout + 30)
    return envelope.get("data", {}).get("value")


def status_query(status_name: str, error_name: str) -> str:
    """Read persisted globals through the DAP proxy metatable.

    Each harness ``state`` evaluation receives a fresh proxy ``_G``.  A bare
    global lookup follows that proxy's verified ``__index`` route to the real
    global table; ``rawget(_G, ...)`` only reads the transient proxy itself.
    """
    return f"{{status={status_name},error={error_name}}}"


def poll_status(
    status_name: str,
    error_name: str,
    success: str,
    events: list[dict[str, object]],
    timeout: float,
) -> object:
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = state_value(
            status_query(status_name, error_name),
            events,
        )
        if isinstance(value, dict):
            if value.get("status") == success:
                return value
            if value.get("status") == "error":
                raise CaptureError(f"{status_name} reported error: {value.get('error')}")
        time.sleep(5)
    raise CaptureError(f"timeout waiting for {status_name}={success}")


def authoritative_audit(events: list[dict[str, object]]) -> dict[str, object]:
    status = smr(
        ["deployment", "status", "--project", str(PROJECT)], events, timeout=60
    )
    mode = status.get("data", {}).get("mode")
    if mode != "missing":
        raise CaptureError(f"canonical deployment mode changed: {mode!r}; expected 'missing'")
    proc = subprocess.run(
        [sys.executable, str(DEPLOY), "audit"],
        cwd=PROJECT,
        capture_output=True,
        text=True,
        timeout=120,
    )
    try:
        audit = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise CaptureError(f"authoritative audit returned non-JSON: {proc.stdout!r}") from exc
    events.append(
        {
            "args": ["python", str(DEPLOY), "audit"],
            "returncode": proc.returncode,
            "envelope": audit,
            "stderr": proc.stderr.strip(),
        }
    )
    if proc.returncode or audit.get("ok") is not True:
        raise CaptureError("authoritative external payload audit failed")
    return audit


def expected_outputs(capture_dir: Path, tag: str, expand: bool) -> list[Path]:
    paths = [
        capture_dir / f"height-{tag}-surface.raw",
        capture_dir / f"height-{tag}-underground.raw",
        capture_dir / f"height-{tag}-zones.txt",
        capture_dir / f"property-{tag}-property.txt",
    ]
    for env in ("surface", "underground"):
        for stage in ("shipped", "fresh", "repeat"):
            paths.append(capture_dir / f"property-{tag}-{env}-property-{stage}.raw")
    paths.append(capture_dir / f"property-{tag}-surface-property-restored.raw")
    for control_id in range(1, 13):
        for suffix in ("raw", "csv"):
            paths.append(
                capture_dir
                / f"property-{tag}-surface-property-control-{control_id:02d}.{suffix}"
            )
    if expand:
        paths.extend(
            (
                capture_dir / f"stretch-{tag}-surface-pre.raw",
                capture_dir / f"stretch-{tag}-surface-post.raw",
            )
        )
    return paths


def verify_outputs(capture_dir: Path, tag: str, expand: bool) -> list[dict[str, object]]:
    paths = expected_outputs(capture_dir, tag, expand)
    missing = [str(path) for path in paths if not path.is_file()]
    empty = [str(path) for path in paths if path.is_file() and path.stat().st_size == 0]
    if missing or empty:
        raise CaptureError(f"capture outputs incomplete; missing={missing} empty={empty}")
    return [
        {"path": str(path), "bytes": path.stat().st_size, "sha256": sha256_file(path)}
        for path in paths
    ]


def capture_twin(
    manifest: dict[str, object], kind: str, events: list[dict[str, object]]
) -> dict[str, object]:
    twin = manifest["twins"][kind]
    capture_dir = Path(manifest["capture_dir"])
    if git("status", "--porcelain"):
        raise CaptureError("worktree is dirty; refusing live launch")
    head = git("rev-parse", "HEAD")
    if head != manifest["git_head"]:
        raise CaptureError(f"manifest commit {manifest['git_head']} != current {head}")
    audit = authoritative_audit(events)
    started = False
    try:
        smr(["daemon", "start", "--hidden", "--timeout", "300"], events, timeout=360)
        started = True
        smr(["run-file", twin["generation"], "--timeout", "120"], events, timeout=180)
        poll_status("g_ParityStatus", "g_ParityError", "complete", events, timeout=1800)
        seeds = state_value(
            "{surface=g_ParitySurfaceSeed,underground=g_ParityUndergroundSeed,"
            "pin=g_ParityUndergroundPin,pin_applied=g_ParityUndergroundPinApplied}",
            events,
        )
        if not isinstance(seeds, dict) or seeds.get("underground") != manifest["reference_underground_seed"]:
            raise CaptureError(f"underground seed mismatch: {seeds}")
        if kind == "vanilla" and seeds.get("pin_applied") is not True:
            raise CaptureError(f"vanilla underground pin was not applied: {seeds}")
        smr(["run-file", twin["height_probe"], "--timeout", "120"], events, timeout=180)
        poll_status("g_ParityZonesStatus", "g_ParityZonesError", "ready", events, timeout=1800)
        smr(["run-file", twin["property_probe"], "--timeout", "120"], events, timeout=180)
        property_state = poll_status(
            "g_ParityPropertyStatus", "g_ParityPropertyError", "ready", events, timeout=1800
        )
        outputs = verify_outputs(capture_dir, twin["tag"], twin["expand"])
        return {
            "tag": twin["tag"],
            "expand": twin["expand"],
            "seeds": seeds,
            "property_state": property_state,
            "payload_audit": audit,
            "outputs": outputs,
        }
    except Exception:
        if started:
            try:
                smr(["logs", "--tail", "400"], events, timeout=60)
            except Exception:
                pass
        raise
    finally:
        try:
            smr(["daemon", "stop"], events, timeout=120)
        except Exception:
            pass


def command_prepare(args: argparse.Namespace) -> int:
    manifest = render_case(
        args.staging.resolve(),
        args.capture_dir.resolve(),
        lat=args.lat,
        lon=args.lon,
        vanilla_tag=args.vanilla_tag,
        expanded_tag=args.expanded_tag,
        seed=args.seed,
        luac=args.luac.resolve(),
    )
    manifest["case"] = args.case
    write_json(args.out.resolve(), manifest)
    print(json.dumps(manifest, indent=2))
    return 0


def command_capture_pair(args: argparse.Namespace) -> int:
    manifest_path = args.manifest.resolve()
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    report: dict[str, object] = {
        "schema": "smr.ralph.harness-property-capture-report.v1",
        "manifest": str(manifest_path),
        "manifest_sha256": sha256_file(manifest_path),
        "started_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "events": [],
        "twins": {},
        "ok": False,
    }
    try:
        for kind in ("vanilla", "expanded"):
            report["twins"][kind] = capture_twin(manifest, kind, report["events"])
        report["ok"] = True
        return 0
    except Exception as exc:
        report["error"] = f"{type(exc).__name__}: {exc}"
        return 1
    finally:
        report["ended_utc"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        write_json(args.out.resolve(), report)
        print(json.dumps(report, indent=2))


def command_self_test(args: argparse.Namespace) -> int:
    py_compile.compile(str(Path(__file__).resolve()), doraise=True)
    poll_query = status_query("g_ParityStatus", "g_ParityError")
    poll_query_sha256 = hashlib.sha256(poll_query.encode("utf-8")).hexdigest()
    if poll_query_sha256 != STATUS_POLL_QUERY_SHA256 or "rawget" in poll_query:
        raise CaptureError("status poll query is not the proven proxy-aware lookup")
    for cli_args in (
        ["daemon", "start", "--help"],
        ["run-file", "--help"],
        ["state", "--help"],
        ["deployment", "status", "--help"],
    ):
        proc = subprocess.run([str(SMR), *cli_args], capture_output=True, text=True, timeout=30)
        if proc.returncode:
            raise CaptureError(f"smr surface missing: {' '.join(cli_args)}")
    TMP_ROOT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="full_z_parity_binder_", dir=TMP_ROOT) as tmp:
        root = Path(tmp)
        manifest = render_case(
            root / "stage",
            root / "capture",
            lat=1800,
            lon=8760,
            vanilla_tag="selftest_v",
            expanded_tag="selftest_x",
            seed=REFERENCE_UNDERGROUND_SEED,
            luac=args.luac.resolve(),
        )
        result = {
            "schema": "smr.ralph.harness-property-capture-selftest.v1",
            "ok": True,
            "python_compile": True,
            "smr_surfaces": ["daemon start", "run-file", "state", "deployment status"],
            "luac": str(args.luac.resolve()),
            "rendered_lua": manifest["lua"],
            "placeholder_free": True,
            "status_poll": {
                "mode": "proxy_plain_global_v1",
                "query": poll_query,
                "query_sha256": poll_query_sha256,
                "expected_query_sha256": STATUS_POLL_QUERY_SHA256,
            },
            "temp_root": str(TMP_ROOT),
        }
    write_json(args.out.resolve(), result)
    print(json.dumps(result, indent=2))
    return 0


def parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    prepare = sub.add_parser("prepare")
    prepare.add_argument("--case", required=True)
    prepare.add_argument("--lat", type=int, required=True)
    prepare.add_argument("--lon", type=int, required=True)
    prepare.add_argument("--vanilla-tag", required=True)
    prepare.add_argument("--expanded-tag", required=True)
    prepare.add_argument("--staging", type=Path, required=True)
    prepare.add_argument("--capture-dir", type=Path, required=True)
    prepare.add_argument("--out", type=Path, required=True)
    prepare.add_argument("--seed", type=int, default=REFERENCE_UNDERGROUND_SEED)
    prepare.add_argument("--luac", type=Path, default=DEFAULT_LUAC)
    prepare.set_defaults(func=command_prepare)
    capture = sub.add_parser("capture-pair")
    capture.add_argument("--manifest", type=Path, required=True)
    capture.add_argument("--out", type=Path, required=True)
    capture.set_defaults(func=command_capture_pair)
    self_test = sub.add_parser("self-test")
    self_test.add_argument("--out", type=Path, required=True)
    self_test.add_argument("--luac", type=Path, default=DEFAULT_LUAC)
    self_test.set_defaults(func=command_self_test)
    return ap


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except (CaptureError, OSError, subprocess.SubprocessError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
