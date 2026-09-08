"""Project-local Ralph adapter: one continuous session per optimization strategy.

Keep the shared harness, immutable task, engine, ledger, and model ladder intact.
Only the generated session contract changes, via the harness's audited migration.
--migrate-only updates that contract without launching a second runner or agent.
An already-running runner reads LOOP.md anew at its next session boundary.
"""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import sys

PROJECT = Path(__file__).resolve().parents[2]
HARNESS = PROJECT.parent / "smr-harness"
TASK_NAME = "reoptimize-under-70s"

OLD_WORK = """Take the smallest useful evidence-producing step toward the task's acceptance
conditions. Use fresh deterministic game state where the task requires it.
Read the `SMR_RALPH_SESSION_MODE` environment variable before choosing that
step; an absent value means `work`."""

NEW_WORK = """Carry ONE optimization strategy through its full lifecycle in this continuous
agent session: inspect and establish the baseline, implement, run offline tests,
commit/deploy candidate builds, measure cold START-to-T1 samples, check all required
rule/terrain/visual regressions, and reach an evidence-backed verdict. Keep working
within this session after each checkpoint; a passing unit test, one cold sample,
or a candidate commit is not a strategy verdict.

At entry, resume any unfinished strategy from HANDOFF.md before selecting another
from `_ralph/reoptimize-ranking.md`. Preserve its implementation and evidence;
do not restart completed checks without a reason. Record a stable strategy ID,
scope, baseline hash, stage, evidence paths, and next action in HANDOFF.md.
Use fresh deterministic game state where the task requires it; a continuous agent
session does not mean reusing a warm game across cold timing samples.
Read the `SMR_RALPH_SESSION_MODE` environment variable before choosing work;
an absent value means `work`."""

OLD_BOUND = """## Bound the session

Work one focused hypothesis, change, or verification per session. After its
checkpoint, prefer exiting - the runner immediately launches the next fresh
session - over beginning a second major work item. Exiting early after a
clean checkpoint is always acceptable; leaving work unrecorded never is.
Stop the tracked daemon cleanly before every session exit so the next fresh
session starts from known state. Your final checkpoint entry serves as the
session's exit entry; no separate summary is required.
"""

NEW_BOUND = """## Strategy verdict and Ralph transition

Owner workflow update, 2026-09-08: ONE continuous agent session PER STRATEGY,
with Ralph managing transitions between strategies. This explicitly supersedes
the older task wording 'one focused evidence-producing step per session' ONLY
for session granularity. Do not edit the pinned task. All acceptance conditions,
rules, safety constraints, timing definitions, and prior optimizations still apply.

- Keep the same agent session for implementation, testing, cold timing, regression
  review, and the final verdict of the selected strategy. Fix diagnosed failures
  and continue that strategy here while there is a concrete useful next action.
  Do not exit merely to delegate its next test, sample, review, or ranking update
  to a fresh session. Preserve checkpoints after every evidence-producing step.
- ACCEPTED requires all per-strategy gates in the task, real timing improvement,
  its own successful optimization commit, and an updated reoptimize-ranking.md
  with short hashes, individual before/after cold START-to-T1 samples (n>=3 at
  14N), medians, savings, rule/visual verdicts, and evidence paths. T0 starts at
  the Start button, never New Game. Candidate checkpoint commits are not successes.
- REJECTED requires a preserved evidence-backed reason and rollback of only this
  strategy's changes, followed by the required tests and authoritative deployment
  audit of the restored accepted baseline. Record the rejection in the ranking.
- At either completed verdict, record it plus the next ranked strategy in HANDOFF.md,
  stop the tracked daemon cleanly, and exit. Ralph launches the next fresh session
  and handles its existing Sol High -> Sol xhigh -> Astra High stall escalation.
  Do not begin a second optimization strategy in this session.
- A genuine context/session limit, interruption, or evidenced plateau needing model
  escalation may require an early checkpoint. Mark the strategy IN_PROGRESS,
  record the exact continuation and why this session could not finish, stop the
  tracked daemon, and let Ralph resume the SAME strategy before advancing. Never
  call an incomplete strategy accepted or rejected to manufacture a transition.
- A concrete external blocker is handled only under the original Blockers rules.
  Do not use a time/iteration cap, fake DONE/BLOCKED, or Pursuing Goal to stop work.

After the planned strategies, continue profiling-guided strategies if necessary.
DONE still requires the entire task's final all-rules/scenario matrix and actual
START-to-T1 below 70 seconds; one successful optimization alone is not DONE.
Your final checkpoint is the session exit entry; no duplicate summary is needed.
"""

OLD_MEMORY = """  scores that session `no progress` - this is expected housekeeping; do it
  in a dedicated session right after one that reported progress, never in
  the middle of an investigation."""

NEW_MEMORY = """  may score that session `no progress` - this is expected housekeeping.
  Consolidate at a safe checkpoint within the strategy session when needed,
  preserving the active hypothesis and exact continuation; do not exit merely
  for housekeeping or interrupt a live test. Record no fabricated progress."""


def strategy_contract(original: str) -> str:
    """Fail closed on template drift rather than silently leaving mixed policies."""
    replacements = (
        ("# Scoped Ralph loop session (contract v7)",
         "# Scoped Ralph strategy session (contract v7 + strategy lifecycle v1)"),
        (OLD_WORK, NEW_WORK),
        (OLD_MEMORY, NEW_MEMORY),
        (OLD_BOUND, NEW_BOUND),
    )
    for old, new in replacements:
        if original.count(old) != 1:
            raise ValueError("Harness session template changed; review the strategy adapter")
        original = original.replace(old, new, 1)
    return original


def load_harness():
    # Import dependencies from the existing harness without changing that repo.
    sys.path.insert(0, str(HARNESS))
    spec = importlib.util.spec_from_file_location("_sbm_strategy_loop", HARNESS / "loop.py")
    if spec is None or spec.loader is None:
        raise RuntimeError("Cannot load the verified local Ralph harness")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def install_contract(loop):
    original = loop._workspace_loop_text

    def generate(project, task, workspace):
        return strategy_contract(original(project, task, workspace))

    loop._workspace_loop_text = generate


def main(argv=None):
    arguments = list(sys.argv[1:] if argv is None else argv)
    migrate_only = "--migrate-only" in arguments
    if migrate_only:
        arguments.remove("--migrate-only")
    loop = load_harness()
    args = loop.parse_args(arguments)
    if (not args.project or Path(args.project).resolve() != PROJECT
            or args.task_name != TASK_NAME or args.task or args.workspace
            or args.ralph_root or args.agent != "codex"):
        raise ValueError("This adapter is scoped to this project's Codex reoptimize-under-70s task")
    install_contract(loop)
    if migrate_only:
        context, status = loop.make_context(
            args.project, None, None, task_name=TASK_NAME,
            dry_run=args.dry_run, migrate_prompt=True,
        )
        print(json.dumps({"status": status, "dry_run": args.dry_run,
                          "prompt": str(context.prompt_file), "agent_launched": False}))
        return 0
    return loop.main(arguments)


if __name__ == "__main__":
    sys.exit(main())
