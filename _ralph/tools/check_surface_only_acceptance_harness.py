"""Offline fail-closed adversaries for the reusable Surface-only acceptance mode."""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from surface_loading_reference import (
    DEFAULT_LUAC,
    compile_lua,
    render_generation,
    static_verdict,
)


ROOT = Path(__file__).resolve().parents[2]
EXECUTOR = ROOT / "_ralph" / "tools" / "execute_surface_only_acceptance.ps1"
FORBIDDEN = (
    "ChangeCurrentMapSlot",
    "find_underground",
    "entering_underground",
    "no underground map was generated",
    "perform_tracked_underground_first_access.lua",
    "release_post_t1_abi_gate.lua",
)


def main() -> int:
    executor = EXECUTOR.read_text(encoding="utf-8")
    with tempfile.TemporaryDirectory(prefix="surface_only_acceptance_static_") as raw:
        root = Path(raw)
        generated = render_generation(
            root / "capture",
            root / "surface_t1_stable.txt",
            root / "capture_final.txt",
            scheduler_census_path=root / "surface_scheduler_census.txt",
            surface_only=True,
        )
        script = root / "generate_14N134W_rough_reference.lua"
        script.write_text(generated, encoding="utf-8")
        compile_lua(DEFAULT_LUAC, script)
        generated_verdict = static_verdict(generated, surface_only=True)
        injected = static_verdict(
            generated + "\nChangeCurrentMapSlot(2, true)\n", surface_only=True
        )

    checks = {
        "executor_has_only_daemon_and_generator_harness_calls": executor.count(
            "Invoke-Harness @("
        ) == 2,
        "executor_has_no_ug_route_token": not any(token in executor for token in FORBIDDEN),
        "generated_surface_only_static_green": generated_verdict["ok"],
        "generated_surface_only_has_no_ug_route": not any(
            token in generated for token in FORBIDDEN[:4]
        ),
        "generated_surface_only_census_is_forward_observer_only": (
            "mechanism=Engine.ChainOnMsg" in generated
            and 'census_chain("MapGenerated"' in generated
            and 'census_chain("CityInitialized"' in generated
            and "CurrentThread" not in generated
            and "surface_thread_rng_mode" not in generated
            and "dofile(" not in generated
        ),
        "injected_ug_route_rejected": not injected["ok"],
    }
    failed = sorted(name for name, ok in checks.items() if not ok)
    report = {
        "schema": "smr.ralph.surface-only-acceptance-static.v1",
        "ok": not failed,
        "checks": checks,
        "failed": failed,
        "generator_bytes": len(generated.encode("utf-8")),
        "generator_lua_parse": True,
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
