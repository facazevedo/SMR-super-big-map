#!/usr/bin/env python3
"""Prepare and statically verify the player-visible surface-loading profiler.

The generated Lua only arms default-off production instrumentation on an already
open colony-site screen. It never presses START or controls the game; live actions
remain the exclusive responsibility of ``smr.cmd``.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import py_compile
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path


PROJECT = Path(__file__).resolve().parents[2]
TMP_ROOT = PROJECT / "_ralph" / "tmp"
DEFAULT_LUAC = Path(r"C:\Users\fazevedo\.claude\tools\lua-5.4.8\bin\luac.exe")
GAME_SRC = Path(r"C:\Games\Surviving Mars Relaunched\ModTools\Src")
COORDINATE = "14N134W"
LATITUDE = -840
LONGITUDE = -8040
INPUT_HASH = hashlib.sha256(json.dumps({
    "coordinate": COORDINATE, "latitude": LATITUDE, "longitude": LONGITUDE,
    "expand_map": True, "game_rule": "RoughTerrain",
}, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest().upper()


class ProfileError(RuntimeError):
    pass


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest().upper()


def lua_path(path: Path) -> str:
    return str(path.resolve()).replace("\\", "/")


def lua_string(value: str) -> str:
    if any(ch in value for ch in "\r\n\0"):
        raise ProfileError("Lua string contains an unsupported control character")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_arm(start: Path, final: Path, token: str, commit: str = "SELF_TEST", mod_version: int = 889) -> str:
    return f'''-- Generated Ralph player-visible loading-profile arm.
CreateRealTimeThread(function()
\tlocal ok, err = xpcall(function()
\t\tif type(Game) ~= "table" or type(Game.AddGameRule) ~= "function" then
\t\t\terror("Rough Terrain benchmark rule requested but Game:AddGameRule is unavailable")
\t\tend
\t\tGame:AddGameRule("RoughTerrain")
\t\tif not IsGameRuleActive("RoughTerrain") then
\t\t\terror("Rough Terrain benchmark rule did not activate")
\t\tend
\t\tif type(g_CurrentMapParams) ~= "table" then
\t\t\terror("colony-site map parameters are unavailable")
\t\tend
\t\tGetOverlayValues({LATITUDE}, {LONGITUDE}, nil, g_CurrentMapParams)
\t\tg_CurrentMapParams.map = ""
\t\tg_CurrentMapParams.SuperBigMapRalphProfileEnabled = true
\t\tg_CurrentMapParams.SuperBigMapRalphProfileToken = {lua_string(token)}
\t\tg_CurrentMapParams.SuperBigMapRalphProfileCommit = {lua_string(commit)}
\t\tg_CurrentMapParams.SuperBigMapRalphProfileModVersion = {mod_version}
\t\tg_CurrentMapParams.SuperBigMapRalphProfileInputHash = "{INPUT_HASH}"
\t\tg_CurrentMapParams.SuperBigMapRalphProfileCoordinate = "{COORDINATE}"
\t\tg_CurrentMapParams.SuperBigMapRalphProfileStartSentinel = {lua_string(lua_path(start))}
\t\tg_CurrentMapParams.SuperBigMapRalphProfileFinalSentinel = {lua_string(lua_path(final))}
\t\tlocal mod
\t\tfor _, candidate in ipairs(ModsLoaded or empty_table) do
\t\t\tif candidate.id == "SuperBigMap" then mod = candidate break end
\t\tend
\t\tlocal SBM = mod and mod.env and mod.env.SuperBigMap or rawget(_G, "SuperBigMap")
\t\tif type(SBM) ~= "table" or type(SBM.PregameToggle) ~= "table" then
\t\t\terror("SuperBigMap pregame toggle unavailable")
\t\tend
\t\tSBM.PregameToggle.SetSelected(true, "ralph_surface_loading_profile")
\t\tif SBM.PregameToggle.IsSelected() ~= true then
\t\t\terror("EXPAND MAP did not select")
\t\tend
\t\tg_CurrentMapParams.SuperBigMapExpandMap = true
\t\trawset(_G, "g_SmrRalphSurfaceProfileArmStatus", "armed")
\tend, debug.traceback)
\tif not ok then
\t\trawset(_G, "g_SmrRalphSurfaceProfileArmStatus", "error")
\t\trawset(_G, "g_SmrRalphSurfaceProfileArmError", tostring(err))
\tend
end)
return "surface_loading_profile_arm_started"
'''


def static_checks(
    text: str, *, diagnostics_override: str | None = None, pregame_override: str | None = None
) -> dict[str, bool]:
    diagnostics = diagnostics_override or (PROJECT / "Code" / "sbm_diagnostics.lua").read_text(encoding="utf-8")
    pregame = pregame_override or (PROJECT / "Code" / "sbm_pregame_toggle.lua").read_text(encoding="utf-8")
    landing = (GAME_SRC / "Lua" / "XDef" / "PGMissionLandingSpotRemastered.generated.lua").read_text(encoding="utf-8")
    mission = (GAME_SRC / "Lua" / "PreGameMission.lua").read_text(encoding="utf-8")
    popup = (GAME_SRC / "Data" / "PopupNotifications" / "PopupNotificationPreset-System.lua").read_text(encoding="utf-8")
    return {
        "arm_adds_and_verifies_roughterrain": (
            'Game:AddGameRule("RoughTerrain")' in text
            and 'IsGameRuleActive("RoughTerrain")' in text
        ),
        "arm_pins_14n134w": (
            f"GetOverlayValues({LATITUDE}, {LONGITUDE}" in text
            and f'SuperBigMapRalphProfileCoordinate = "{COORDINATE}"' in text
        ),
        "arm_pins_identity": (
            "SuperBigMapRalphProfileCommit" in text
            and "SuperBigMapRalphProfileModVersion" in text
            and f'SuperBigMapRalphProfileInputHash = "{INPUT_HASH}"' in text
        ),
        "arm_selects_expand_without_pressing_start": (
            "SetSelected(true" in text and "OnAction(" not in text
            and "GenerateCurrentRandomMap" not in text
        ),
        "runtime_profile_default_off": (
            "SuperBigMapRalphProfileEnabled == true" in diagnostics
            and "SuperBigMapRalphProfileEnabled = true" not in diagnostics
        ),
        "real_start_wrapper_is_instrumented": (
            'ActionById(dialog, "start")' in pregame
            and "diagnostics.RalphProfileStart" in pregame
            and pregame.index("diagnostics.RalphProfileStart")
            < pregame.index("original_on_action(action, host, source", pregame.index("diagnostics.RalphProfileStart"))
        ),
        "surface_preset_is_fail_closed": (
            "RalphProfileRecordPreset" in pregame
            and 'preset ~= "RoughTerrain"' in diagnostics
        ),
        "final_waits_first_render_frame": (
            'context.id ~= "WelcomeGameInfo"' in diagnostics
            and "wait_frame()" in diagnostics
            and 'dialog:ActionById("idChoice1")' in diagnostics
        ),
        "final_requires_stable_surface": all(
            token in diagnostics
            for token in (
                "SuperBigMapSurfaceStretchDone ~= true",
                "SuperBigMapExpansionPending == true",
                "SuperBigMapStretchPipelinePending == true",
                "SuperBigMapSurfacePostPipelineRevalidationComplete ~= true",
                "ExpansionLoadingVisible",
            )
        ),
        "loading_timings_runtime_only": (
            "or RalphProfileParams() ~= nil" in diagnostics
        ),
        "installed_start_source_anchor": (
            'ActionId = "start"' in landing
            and "GenerateCurrentRandomMap()" in landing
        ),
        "installed_final_call_source_anchor": (
            'WaitPopupNotification("WelcomeGameInfo"' in mission
        ),
        "installed_final_close_source_anchor": (
            'id = "WelcomeGameInfo"' in popup
            and 'choice1 = T(1011' in popup
            and '"Close"' in popup
        ),
    }


def parse_sentinel(path: Path) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or "=" not in line:
            raise ProfileError(f"malformed sentinel row in {path}: {line!r}")
        key, value = line.split("=", 1)
        if not key or key in fields:
            raise ProfileError(f"duplicate/empty sentinel key in {path}: {key!r}")
        fields[key] = value
    return fields


def score_values(start: dict[str, str], final: dict[str, str], log_text: str, duration_ms: float) -> dict[str, object]:
    required_start = {
        "schema": "smr.ralph.surface_loading_profile.v1",
        "event": "start_action_accepted",
        "coordinate": COORDINATE,
        "expand_map": "true",
        "rough_terrain": "true",
        "source": "PGMissionLandingSpotRemastered.ActionId.start",
    }
    required_final = {
        "schema": "smr.ralph.surface_loading_profile.v1",
        "event": "welcome_close_display_first_visible_frame",
        "coordinate": COORDINATE,
        "rough_terrain": "true",
        "selected_random_map_preset": "RoughTerrain",
        "dialog_class": "PopupNotification",
        "dialog_context_id": "WelcomeGameInfo",
        "close_action_id": "idChoice1",
        "surface_stretch_done": "true",
        "surface_expansion_pending": "false",
        "stretch_pipeline_pending": "false",
        "post_pipeline_revalidation_complete": "true",
        "expansion_loading_visible": "false",
    }
    boundary_checks = {
        **{f"start_{key}": start.get(key) == value for key, value in required_start.items()},
        **{f"final_{key}": final.get(key) == value for key, value in required_final.items()},
        "token_present_and_equal": bool(start.get("token")) and start.get("token") == final.get("token"),
        "surface_seed_present_and_equal": bool(start.get("surface_seed")) and start.get("surface_seed") == final.get("surface_seed"),
        "input_hash_pinned_and_equal": start.get("input_hash") == INPUT_HASH and final.get("input_hash") == INPUT_HASH,
        "commit_present_and_equal": bool(start.get("commit")) and start.get("commit") == final.get("commit"),
        "mod_version_889_and_equal": start.get("mod_version") == "889" and final.get("mod_version") == "889",
        "roughterrain_listed_at_start": "RoughTerrain" in start.get("active_rule_ids", "").split(","),
        "roughterrain_listed_at_final": "RoughTerrain" in final.get("active_rule_ids", "").split(","),
        "positive_external_duration": duration_ms > 0,
    }
    phase_rows: list[tuple[str, float]] = []
    for line in log_text.splitlines():
        match = re.search(r"\[LoadingTiming\] PHASE_END (.*?) \{([^}]*)\}", line)
        if not match:
            continue
        duration_match = re.search(r"(?:^|, )duration_ms=([0-9]+(?:\.[0-9]+)?)", match.group(2))
        if not duration_match:
            raise ProfileError(f"PHASE_END lacks duration_ms: {line}")
        phase_rows.append((match.group(1), float(duration_match.group(1))))
    session_begin_count = log_text.count("[LoadingTiming] SESSION_BEGIN")
    session_end_matches = re.findall(
        r"\[LoadingTiming\] SESSION_END \{([^}]*)\}", log_text
    )
    session_duration_ms = None
    if len(session_end_matches) == 1:
        match = re.search(
            r"(?:^|, )session_duration_ms=([0-9]+(?:\.[0-9]+)?)",
            session_end_matches[0],
        )
        if match:
            session_duration_ms = float(match.group(1))
    totals: defaultdict[str, float] = defaultdict(float)
    for name, value in phase_rows:
        totals[name] += value
    phase_total_ms = sum(value for _, value in phase_rows)
    coverage = phase_total_ms / duration_ms if duration_ms > 0 else 0.0
    ranked = [
        {"rank": index, "name": name, "total_ms": value, "external_share": value / duration_ms}
        for index, (name, value) in enumerate(
            sorted(totals.items(), key=lambda item: (-item[1], item[0])), 1
        )
    ]
    profile_checks = {
        "one_loading_session_begin": session_begin_count == 1,
        "one_loading_session_end": len(session_end_matches) == 1,
        "session_duration_present": session_duration_ms is not None,
        "phase_rows_present": bool(phase_rows),
        "phase_total_within_external_duration": phase_total_ms <= duration_ms * 1.01,
        "session_within_external_duration": session_duration_ms is not None and session_duration_ms <= duration_ms * 1.01,
        "at_least_90_percent_attributed": coverage >= 0.90,
    }
    ok = all(boundary_checks.values()) and all(profile_checks.values())
    return {
        "schema": "smr.ralph.surface_loading_profile_score.v1",
        "ok": ok,
        "external_duration_ms": duration_ms,
        "phase_total_ms": phase_total_ms,
        "phase_coverage": coverage,
        "session_duration_ms": session_duration_ms,
        "boundary_checks": boundary_checks,
        "profile_checks": profile_checks,
        "ranked_phases": ranked,
    }


def score(args: argparse.Namespace) -> int:
    report = score_values(
        parse_sentinel(Path(args.start_sentinel)),
        parse_sentinel(Path(args.final_sentinel)),
        Path(args.log).read_text(encoding="utf-8", errors="replace"),
        float(args.duration_ms),
    )
    if args.json_out:
        path = Path(args.json_out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


def prepare(args: argparse.Namespace) -> int:
    out = Path(args.out).resolve()
    try:
        out.relative_to(TMP_ROOT.resolve())
    except ValueError as exc:
        raise ProfileError(f"staging path must be under {TMP_ROOT}") from exc
    out.mkdir(parents=True, exist_ok=False)
    start = Path(args.start_sentinel).resolve()
    final = Path(args.final_sentinel).resolve()
    porcelain = subprocess.run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        cwd=PROJECT, check=True, text=True, capture_output=True,
    ).stdout.strip()
    if porcelain:
        raise ProfileError("profile staging requires a clean committed worktree")
    commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=PROJECT, check=True, text=True, capture_output=True,
    ).stdout.strip()
    metadata = (PROJECT / "metadata.lua").read_text(encoding="utf-8")
    version_match = re.search(r"'version',\s*(\d+)", metadata)
    if not version_match:
        raise ProfileError("metadata version unavailable")
    mod_version = int(version_match.group(1))
    text = render_arm(start, final, args.token, commit, mod_version)
    arm = out / "arm_surface_loading_profile.lua"
    arm.write_text(text, encoding="utf-8", newline="\n")
    subprocess.run([str(Path(args.luac)), "-p", str(arm)], check=True)
    checks = static_checks(text)
    if not all(checks.values()):
        raise ProfileError("static checks failed: " + ", ".join(k for k, v in checks.items() if not v))
    manifest = {
        "schema": "smr.ralph.surface_loading_profile_manifest.v1",
        "coordinate": COORDINATE,
        "latitude": LATITUDE,
        "longitude": LONGITUDE,
        "token": args.token,
        "commit": commit,
        "mod_version": mod_version,
        "input_hash": INPUT_HASH,
        "arm": str(arm),
        "arm_sha256": sha256_file(arm),
        "start_sentinel": str(start),
        "final_sentinel": str(final),
        "checks": checks,
    }
    print(json.dumps(manifest, indent=2, sort_keys=True))
    return 0


def self_test(args: argparse.Namespace) -> int:
    py_compile.compile(__file__, doraise=True)
    root = TMP_ROOT / ".tmp_surface_loading_profile_self_test"
    root.mkdir(parents=True, exist_ok=True)
    text = render_arm(root / "start.txt", root / "final.txt", "self_test_token")
    arm = root / "arm.lua"
    arm.write_text(text, encoding="utf-8", newline="\n")
    subprocess.run([str(Path(args.luac)), "-p", str(arm)], check=True)
    checks = static_checks(text)
    wrong_rule = text.replace('Game:AddGameRule("RoughTerrain")', 'Game:AddGameRule("FastScan")', 1)
    wrong_final = (PROJECT / "Code" / "sbm_diagnostics.lua").read_text(encoding="utf-8").replace(
        'context.id ~= "WelcomeGameInfo"', 'context.id ~= "UnrelatedPopup"', 1
    )
    mutation_checks = {
        "wrong_rule_mutation_rejected": not static_checks(wrong_rule)["arm_adds_and_verifies_roughterrain"],
        "wrong_final_mutation_rejected": not static_checks(
            text, diagnostics_override=wrong_final
        )["final_waits_first_render_frame"],
    }
    start_fixture = {
        "schema": "smr.ralph.surface_loading_profile.v1",
        "event": "start_action_accepted", "token": "self_test_token",
        "coordinate": COORDINATE, "expand_map": "true", "rough_terrain": "true",
        "active_rule_ids": "RoughTerrain",
        "source": "PGMissionLandingSpotRemastered.ActionId.start",
        "surface_seed": "123", "input_hash": INPUT_HASH,
        "commit": "deadbeef", "mod_version": "889",
    }
    final_fixture = {
        "schema": "smr.ralph.surface_loading_profile.v1",
        "event": "welcome_close_display_first_visible_frame", "token": "self_test_token",
        "coordinate": COORDINATE, "rough_terrain": "true", "active_rule_ids": "RoughTerrain",
        "selected_random_map_preset": "RoughTerrain", "dialog_class": "PopupNotification",
        "dialog_context_id": "WelcomeGameInfo", "close_action_id": "idChoice1",
        "surface_stretch_done": "true", "surface_expansion_pending": "false",
        "stretch_pipeline_pending": "false", "post_pipeline_revalidation_complete": "true",
        "expansion_loading_visible": "false",
        "surface_seed": "123", "input_hash": INPUT_HASH,
        "commit": "deadbeef", "mod_version": "889",
    }
    log_fixture = "\n".join((
        "[Super Big Map][LoadingTiming] SESSION_BEGIN {session=1}",
        "[Super Big Map][LoadingTiming] PHASE_END terrain {duration_ms=60000, session=1}",
        "[Super Big Map][LoadingTiming] PHASE_END objects {duration_ms=35000, session=1}",
        "[Super Big Map][LoadingTiming] SESSION_END {session=1, session_duration_ms=98000}",
    ))
    scorer_green = score_values(start_fixture, final_fixture, log_fixture, 100000)
    scorer_red = score_values(start_fixture, final_fixture, log_fixture, 106000)
    scorer_checks = {
        "ninety_percent_profile_passes": scorer_green["ok"] is True,
        "sub_ninety_percent_profile_fails": (
            scorer_red["ok"] is False
            and scorer_red["profile_checks"]["at_least_90_percent_attributed"] is False
        ),
    }
    report = {
        "schema": "smr.ralph.surface_loading_profile_static_self_test.v1",
        "ok": all(checks.values()) and all(mutation_checks.values()) and all(scorer_checks.values()),
        "checks": checks,
        "mutation_checks": mutation_checks,
        "scorer_checks": scorer_checks,
        "arm_sha256": sha256_file(arm),
    }
    if args.json_out:
        path = Path(args.json_out)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0 if report["ok"] else 1


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    sub = result.add_subparsers(dest="command", required=True)
    prep = sub.add_parser("prepare")
    prep.add_argument("--out", required=True)
    prep.add_argument("--start-sentinel", required=True)
    prep.add_argument("--final-sentinel", required=True)
    prep.add_argument("--token", required=True)
    prep.add_argument("--luac", default=str(DEFAULT_LUAC))
    prep.set_defaults(func=prepare)
    scoring = sub.add_parser("score")
    scoring.add_argument("--start-sentinel", required=True)
    scoring.add_argument("--final-sentinel", required=True)
    scoring.add_argument("--log", required=True)
    scoring.add_argument("--duration-ms", required=True, type=float)
    scoring.add_argument("--json-out")
    scoring.set_defaults(func=score)
    test = sub.add_parser("self-test")
    test.add_argument("--luac", default=str(DEFAULT_LUAC))
    test.add_argument("--json-out")
    test.set_defaults(func=self_test)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        return args.func(args)
    except (ProfileError, OSError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
