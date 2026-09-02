"""Build a timestamp-only phase-profiling variant of the accepted iter266b generator.

Every phase profile the campaign has relied on was taken on a cold or heavily
instrumented run (77-124 s totals) while the real optimization target is the warm
plateau at ~80.5 s. Warm-up is not spread evenly across phases -- roughly half of
it lives in `ChangeMap("PreGame")` alone -- so the cold phase ranking cannot be
trusted to rank warm work.

This inserts about ten `GetPreciseTicks()` reads and one file write. That is small
enough to keep the run a release-configuration measurement, unlike the
`OptimizationTrace` runs which add seconds of log I/O.

The partition produced:

    T0 (external) -> thread_start   harness dispatch
    newgame                         NewGame + InitNewGameMissionParams
    pregame                         ChangeMap("PreGame")            <- suspect
    coords_rule                     GetOverlayValues + AddGameRule
    generate                        GenerateCurrentRandomMap        <- stock
    generate_end -> t1              mod expansion pipeline + tail

Usage:  python _ralph/tools/build_warm_phase_profile_generator.py <out_stage_dir>
"""

from __future__ import annotations

import pathlib
import shutil
import sys

REPO = pathlib.Path(__file__).resolve().parents[2]
TEMPLATE_STAGE = REPO / "_ralph/tmp/.tmp_surface_release_v1011_apron_math_iter266b"
GENERATOR = "generate_14N134W_rough_reference.lua"
PATH_FRAGMENT = ("D:/PROJS/SMR/super-big-map/_ralph/runs/surface-loading-under-60s-rough/"
                 "artifacts/run_v1011_surface_release_apron_math_iter266b")

# Inserted once, before the worker thread starts. Uses rawset throughout: the debug
# build reports a first ordinary assignment to an unknown global as a Lua error.
PRELUDE = '''-- === warm phase profile instrumentation (timestamp only) ===
rawset(_G, "g_SbmPhaseMarks", {})
rawset(_G, "g_SbmPhaseOrder", {})
rawset(_G, "g_SbmPhaseMark", function(name)
	local clock = rawget(_G, "GetPreciseTicks") or rawget(_G, "RealTime")
	if type(clock) ~= "function" then return end
	local marks = rawget(_G, "g_SbmPhaseMarks")
	local order = rawget(_G, "g_SbmPhaseOrder")
	if marks[name] == nil then order[#order + 1] = name end
	marks[name] = clock()
end)
'''

MARK = 'if type(rawget(_G, "g_SbmPhaseMark")) == "function" then rawget(_G, "g_SbmPhaseMark")("%s") end'

# (anchor, replacement) applied in order; every anchor must appear exactly once.
EDITS = [
    # thread entry
    ('CreateRealTimeThread(function()\n\tlocal ok, err = xpcall(function()',
     'CreateRealTimeThread(function()\n\tlocal ok, err = xpcall(function()\n\t\t'
     + MARK % "thread_start"),
    # new game
    ('\t\tNewGame({ seed_text = "LOZL3FQr" })',
     '\t\t' + MARK % "newgame_begin" + '\n\t\tNewGame({ seed_text = "LOZL3FQr" })'),
    ('\t\tInitNewGameMissionParams()',
     '\t\tInitNewGameMissionParams()\n\t\t' + MARK % "newgame_end"),
    # the suspect: mission-setup planet map load
    ('\t\tChangeMap("PreGame")',
     '\t\t' + MARK % "pregame_begin" + '\n\t\tChangeMap("PreGame")\n\t\t'
     + MARK % "pregame_end"),
    ('\t\tGetOverlayValues(-840, -8040, nil, g_CurrentMapParams)',
     '\t\tGetOverlayValues(-840, -8040, nil, g_CurrentMapParams)\n\t\t'
     + MARK % "coords_end"),
    # game rule active
    ('\t\tif not IsGameRuleActive("RoughTerrain") then\n'
     '\t\t\terror("Rough Terrain harness rule did not activate")\n\t\tend',
     '\t\tif not IsGameRuleActive("RoughTerrain") then\n'
     '\t\t\terror("Rough Terrain harness rule did not activate")\n\t\tend\n\t\t'
     + MARK % "rule_end"),
    # stock generation
    ('\t\t\tlocal gen_ok, gen_err = pcall(GenerateCurrentRandomMap)',
     '\t\t\t' + MARK % "generate_begin"
     + '\n\t\t\tlocal gen_ok, gen_err = pcall(GenerateCurrentRandomMap)\n\t\t\t'
     + MARK % "generate_end"),
]


def build(out_stage: pathlib.Path) -> None:
    src = (TEMPLATE_STAGE / GENERATOR).read_text(encoding="utf-8")
    if src.count(PATH_FRAGMENT) != 5:
        raise SystemExit(f"template path premise changed: {src.count(PATH_FRAGMENT)} occurrences, expected 5")

    text = src
    for anchor, replacement in EDITS:
        n = text.count(anchor)
        if n != 1:
            raise SystemExit(f"anchor appeared {n} times, expected 1: {anchor[:70]!r}")
        text = text.replace(anchor, replacement, 1)

    # Prelude ahead of the worker thread.
    thread_anchor = "CreateRealTimeThread(function()"
    text = text.replace(thread_anchor, PRELUDE + thread_anchor, 1)

    # T1 mark plus the phase dump, immediately at the stable-sentinel write.
    t1_anchor = ('\t\t\t\tlocal write_error = AsyncStringToFile("' + PATH_FRAGMENT
                 + '/surface_t1_stable.txt", text)')
    if text.count(t1_anchor) != 1:
        raise SystemExit("T1 sentinel write anchor not found exactly once")
    t1_block = (
        '\t\t\t\t' + MARK % "t1" + '\n'
        '\t\t\t\tdo\n'
        '\t\t\t\t\tlocal marks = rawget(_G, "g_SbmPhaseMarks") or {}\n'
        '\t\t\t\t\tlocal order = rawget(_G, "g_SbmPhaseOrder") or {}\n'
        '\t\t\t\t\tlocal rows = { "schema=smr.ralph.warm-phase-profile.v1" }\n'
        '\t\t\t\t\tfor i = 1, #order do\n'
        '\t\t\t\t\t\trows[#rows + 1] = "mark_" .. tostring(order[i]) .. "="\n'
        '\t\t\t\t\t\t\t.. tostring(marks[order[i]])\n'
        '\t\t\t\t\tend\n'
        '\t\t\t\t\tlocal function span(a, b)\n'
        '\t\t\t\t\t\tif marks[a] and marks[b] then return tostring(marks[b] - marks[a]) end\n'
        '\t\t\t\t\t\treturn "unavailable"\n'
        '\t\t\t\t\tend\n'
        '\t\t\t\t\trows[#rows + 1] = "phase_newgame_ms=" .. span("newgame_begin", "newgame_end")\n'
        '\t\t\t\t\trows[#rows + 1] = "phase_pregame_ms=" .. span("pregame_begin", "pregame_end")\n'
        '\t\t\t\t\trows[#rows + 1] = "phase_coords_rule_ms=" .. span("pregame_end", "rule_end")\n'
        '\t\t\t\t\trows[#rows + 1] = "phase_pre_generate_ms=" .. span("rule_end", "generate_begin")\n'
        '\t\t\t\t\trows[#rows + 1] = "phase_generate_ms=" .. span("generate_begin", "generate_end")\n'
        '\t\t\t\t\trows[#rows + 1] = "phase_pipeline_and_tail_ms=" .. span("generate_end", "t1")\n'
        '\t\t\t\t\trows[#rows + 1] = "phase_thread_start_to_t1_ms=" .. span("thread_start", "t1")\n'
        '\t\t\t\t\tlocal perr = AsyncStringToFile("' + PATH_FRAGMENT + '/warm_phase_profile.txt",\n'
        '\t\t\t\t\t\ttable.concat(rows, "\\n") .. "\\n")\n'
        '\t\t\t\t\tif perr then error("phase profile write failed: " .. tostring(perr)) end\n'
        '\t\t\t\tend\n'
    )
    text = text.replace(t1_anchor, t1_block + t1_anchor, 1)

    if text.count(PATH_FRAGMENT) != 6:
        raise SystemExit(f"expected 6 path fragments after instrumentation, got {text.count(PATH_FRAGMENT)}")

    out_stage.mkdir(parents=True, exist_ok=True)
    (out_stage / GENERATOR).write_text(text, encoding="utf-8", newline="")
    for extra in ("sbm_config_flag_on.lua", "surface_reference_manifest.json"):
        shutil.copy2(TEMPLATE_STAGE / extra, out_stage / extra)

    added = len(text.splitlines()) - len(src.splitlines())
    print(f"instrumented generator written to {out_stage / GENERATOR}")
    print(f"  +{added} lines, {text.count(PATH_FRAGMENT)} path fragments, "
          f"{text.count('g_SbmPhaseMark')} mark references")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    build(pathlib.Path(sys.argv[1]))
