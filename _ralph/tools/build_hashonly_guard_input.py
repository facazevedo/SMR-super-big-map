#!/usr/bin/env python3
"""Stage and audit the pinned load-neutral direct-guard HashOnly input."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
from pathlib import Path


GENERATOR_SHA256 = "E39D4696DB8D7FF9F6E6C21A3842590BBA22E4F94EA25F2CB2561A5520B113DF"
PROBE_SHA256 = "F8F34F3474D5D60B9FB96F923341229F3563CE294AEA409FEC30DC15B61A0A7D"
DIRECT_SHA256 = "0B0BBA344E1078E27592390DCCA4E48B68DFFBE60F594AB9BAEE7C1C5E8E4895"
TRANSPORT_AUDIT_SHA256 = "40831ADF10A8071D15FCC41F7EC5045E85B17EBCA86722D932B337F405ED623F"
REFERENCE_SHA256 = "C751FA5D068D2DE23076C4CC2D789E5A0553700BCCCDBFD3E06136A61782793C"
REFERENCE_AGGREGATE = "BA68EAB4FB1BA0884DF16D31AFFA6A67C894AB64C79B67EDBF87730BF3552131"
TASK_SHA256 = "8895B153700EF709186DEE426241748BEBEC96604B7A43047CFABB450CAECD8D"
INCORPORATED_TASK_LF_SHA256 = "606CA5A6F5F8E75112D9B25AA1DB32A9669E1FB944399B3D5D9A82DF193BA64E"
ACCEPTED_PRODUCTION_COMMIT = "ab8f455"
VERSION = 906

CAPTURE_BASE = Path(
    "D:/PROJS/SMR/super-big-map/_ralph/runs/surface-loading-under-60s-rough/"
    "artifacts/run_iter104_direct_guard_input/candidate_14N134W_rough_v906_directguard"
)
GUARD_BASE = Path(
    "D:/PROJS/SMR/super-big-map/_ralph/runs/surface-loading-under-60s-rough/"
    "artifacts/run_iter104_direct_guard_input/guard_prepare_input_v906"
)
STABLE_SENTINEL = Path(
    "D:/PROJS/SMR/super-big-map/_ralph/runs/surface-loading-under-60s-rough/"
    "artifacts/run_iter104_direct_guard_input/surface_t1_stable.txt"
)
FINAL_SENTINEL = Path(
    "D:/PROJS/SMR/super-big-map/_ralph/runs/surface-loading-under-60s-rough/"
    "artifacts/run_iter104_direct_guard_input/capture_final.txt"
)


class AuditError(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest().upper()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def run(args: list[str], cwd: Path) -> str:
    result = subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True)
    return result.stdout.strip()


def parse_lua(luac: Path, path: Path) -> bool:
    result = subprocess.run(
        [str(luac), "-p", str(path)], check=False, capture_output=True, text=True
    )
    return result.returncode == 0


def lf_sha256(path: Path) -> str:
    text = path.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    return sha256_bytes(text.encode("utf-8"))


def files_with_prefix(base: Path) -> list[str]:
    if not base.parent.exists():
        return []
    return sorted(str(path) for path in base.parent.glob(base.name + "*"))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--generator", type=Path, required=True)
    parser.add_argument("--probe", type=Path, required=True)
    parser.add_argument("--direct", type=Path, required=True)
    parser.add_argument("--transport-audit", type=Path, required=True)
    parser.add_argument("--reference-manifest", type=Path, required=True)
    parser.add_argument("--rough-task", type=Path, required=True)
    parser.add_argument("--incorporated-task", type=Path, required=True)
    parser.add_argument("--luac", type=Path, required=True)
    parser.add_argument("--stage-dir", type=Path, required=True)
    parser.add_argument("--out-dir", type=Path, required=True)
    args = parser.parse_args()

    project = args.project.resolve()
    generator = args.generator.resolve()
    probe = args.probe.resolve()
    direct = args.direct.resolve()
    transport_path = args.transport_audit.resolve()
    reference_path = args.reference_manifest.resolve()
    stage_dir = args.stage_dir.resolve()
    out_dir = args.out_dir.resolve()
    if stage_dir.exists() or out_dir.exists():
        raise AuditError("stage and artifact directories must both be fresh")

    generator_bytes = generator.read_bytes()
    probe_bytes = probe.read_bytes()
    direct_bytes = direct.read_bytes()
    transport = json.loads(transport_path.read_text(encoding="utf-8"))
    reference = json.loads(reference_path.read_text(encoding="utf-8"))
    head = run(["git", "rev-parse", "HEAD"], project)
    tree = run(["git", "rev-parse", "HEAD^{tree}"], project)
    status = run(["git", "status", "--porcelain"], project)
    production_diff = run(
        ["git", "diff", "--name-only", ACCEPTED_PRODUCTION_COMMIT, "--", "Code", "metadata.lua"],
        project,
    )
    metadata = (project / "metadata.lua").read_text(encoding="utf-8")
    version_match = re.search(r"'version',\s*(\d+)", metadata)

    candidate_matches = files_with_prefix(CAPTURE_BASE)
    guard_matches = [path for path in files_with_prefix(GUARD_BASE) if Path(path) != direct]
    stable_matches = files_with_prefix(STABLE_SENTINEL)
    final_matches = files_with_prefix(FINAL_SENTINEL)

    stage_dir.mkdir(parents=True)
    out_dir.mkdir(parents=True)
    staged_generator = stage_dir / "generate_14N134W_rough_hashonly.luac"
    shutil.copyfile(generator, staged_generator)

    verdict = out_dir / "hash_verdict.json"
    abort_sentinel = out_dir / "watcher_abort.json"
    ready_sentinel = out_dir / "watcher_ready.json"
    manifest_path = out_dir / "hashonly_input_manifest.json"
    audit_path = out_dir / "integration_audit.json"

    manifest = {
        "schema": "smr.ralph.iter105.load_neutral_hashonly_input.v1",
        "mode": "HashOnly",
        "coordinate": "14N134W",
        "expanded": True,
        "rough_terrain_required": True,
        "selected_random_map_preset_required": "RoughTerrain",
        "source_head": head,
        "source_tree": tree,
        "source_version": VERSION,
        "generation_input": str(staged_generator),
        "generation_input_bytes": len(generator_bytes),
        "generation_input_sha256": GENERATOR_SHA256,
        "probe": str(probe),
        "probe_sha256": PROBE_SHA256,
        "direct_chunk": str(direct),
        "direct_chunk_sha256": DIRECT_SHA256,
        "candidate_base": str(CAPTURE_BASE),
        "guard_capture_base": str(GUARD_BASE),
        "stable_sentinel": str(STABLE_SENTINEL),
        "final_sentinel": str(FINAL_SENTINEL),
        "reference_manifest": str(reference_path),
        "reference_manifest_sha256": REFERENCE_SHA256,
        "reference_aggregate_sha256": REFERENCE_AGGREGATE,
        "watcher": {
            "script": str((project / "_ralph/tools/watch_checkpoints.ps1").resolve()),
            "mode": "HashOnly",
            "timeout_seconds": 1800,
            "verdict": str(verdict),
            "abort_sentinel": str(abort_sentinel),
            "ready_sentinel": str(ready_sentinel),
        },
    }
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")

    checks = {
        "rough_task_hash_exact": sha256_file(args.rough_task.resolve()) == TASK_SHA256,
        "incorporated_task_lf_hash_exact": lf_sha256(args.incorporated_task.resolve())
        == INCORPORATED_TASK_LF_SHA256,
        "worktree_clean": status == "",
        "production_exact_to_accepted_ab8f455": production_diff == "",
        "version_906": version_match is not None and int(version_match.group(1)) == VERSION,
        "transport_audit_hash_pinned": sha256_file(transport_path) == TRANSPORT_AUDIT_SHA256,
        "transport_audit_green_20_of_20": transport.get("ok") is True
        and transport.get("passed") == 20
        and transport.get("total") == 20,
        "generator_hash_pinned": sha256_bytes(generator_bytes) == GENERATOR_SHA256,
        "probe_hash_pinned": sha256_bytes(probe_bytes) == PROBE_SHA256,
        "direct_hash_pinned": sha256_bytes(direct_bytes) == DIRECT_SHA256,
        "staged_generator_byte_exact": staged_generator.read_bytes() == generator_bytes,
        "generator_lua_parse": parse_lua(args.luac.resolve(), staged_generator),
        "probe_lua_parse": parse_lua(args.luac.resolve(), probe),
        "direct_lua_parse": parse_lua(args.luac.resolve(), direct),
        "reference_manifest_hash_pinned": sha256_file(reference_path) == REFERENCE_SHA256,
        "reference_green_36_of_36": reference.get("ok") is True
        and reference.get("checkpoint_count") == 36
        and reference.get("checkpoint_aggregate_sha256") == REFERENCE_AGGREGATE,
        "candidate_checkpoint_outputs_fresh": candidate_matches == [],
        "guard_capture_outputs_fresh": guard_matches == [],
        "completion_sentinels_fresh": stable_matches == [] and final_matches == [],
        "watcher_outputs_fresh": not verdict.exists()
        and not abort_sentinel.exists()
        and not ready_sentinel.exists(),
        "manifest_pins_hashonly_watcher": manifest["watcher"]["mode"] == "HashOnly"
        and manifest["watcher"]["timeout_seconds"] == 1800,
        "manifest_pins_roughterrain_before_acceptance": manifest["rough_terrain_required"] is True
        and manifest["selected_random_map_preset_required"] == "RoughTerrain",
        "manifest_pins_all_three_chunks": manifest["generation_input_sha256"] == GENERATOR_SHA256
        and manifest["probe_sha256"] == PROBE_SHA256
        and manifest["direct_chunk_sha256"] == DIRECT_SHA256,
        "manifest_is_fresh_and_exact": manifest_path.exists()
        and json.loads(manifest_path.read_text(encoding="utf-8")) == manifest,
    }
    failed = sorted(name for name, passed in checks.items() if not passed)
    report = {
        "schema": "smr.ralph.iter105.load_neutral_hashonly_input_audit.v1",
        "ok": not failed,
        "checks": checks,
        "passed": sum(checks.values()),
        "total": len(checks),
        "failed": failed,
        "game_launched": False,
        "identity": {
            "head": head,
            "tree": tree,
            "version": VERSION,
            "generator_sha256": sha256_bytes(generator_bytes),
            "probe_sha256": sha256_bytes(probe_bytes),
            "direct_sha256": sha256_bytes(direct_bytes),
            "transport_audit_sha256": sha256_file(transport_path),
            "reference_manifest_sha256": sha256_file(reference_path),
            "manifest_sha256": sha256_file(manifest_path),
        },
        "paths": {
            "staged_generator": str(staged_generator),
            "manifest": str(manifest_path),
            "candidate_base": str(CAPTURE_BASE),
            "guard_base": str(GUARD_BASE),
        },
        "freshness": {
            "candidate_matches": candidate_matches,
            "guard_matches_excluding_direct_chunk": guard_matches,
            "stable_matches": stable_matches,
            "final_matches": final_matches,
        },
        "conclusion": (
            "The complete pinned load-neutral HashOnly input is ready for a separate prelaunch gate."
            if not failed
            else "The offline HashOnly integration gate failed; no launch is permitted."
        ),
    }
    audit_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    return 0 if not failed else 1


if __name__ == "__main__":
    raise SystemExit(main())
