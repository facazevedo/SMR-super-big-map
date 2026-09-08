"""Offline-only strategy contract and immutable-workspace migration regression tests."""
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import strategy_sessions as strategy


class StrategySessionsTests(unittest.TestCase):
    def setUp(self):
        self.loop = strategy.load_harness()
        self.original = self.loop._workspace_loop_text
        temp_root = strategy.PROJECT / "_ralph/tmp"
        temp_root.mkdir(parents=True, exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="strategy_test_", dir=temp_root)
        self.addCleanup(self.temp.cleanup)
        self.project = Path(self.temp.name).resolve()
        self.task = self.project / "_ralph/tasks/reoptimize-under-70s.md"
        self.task.parent.mkdir(parents=True)
        self.task.write_text("# Immutable test task\nEvery rule stays mandatory.\n", encoding="utf-8")
        self.workspace = self.project / "_ralph/runs/reoptimize-under-70s"

    def prepare(self, **kwargs):
        return self.loop.prepare_workspace(self.project, self.task, self.workspace, **kwargs)

    def test_complete_strategy_replaces_tiny_session_exit(self):
        original = self.original(self.project, self.task, self.workspace)
        updated = strategy.strategy_contract(original)
        for old in (strategy.OLD_WORK, strategy.OLD_BOUND, strategy.OLD_MEMORY):
            self.assertNotIn(old, updated)
        for requirement in ("ONE optimization strategy", "IN_PROGRESS", "SAME strategy",
                            "n>=3", "Start button, never New Game", "reoptimize-ranking.md",
                            "Sol High -> Sol xhigh -> Astra High", "below 70 seconds"):
            self.assertIn(requirement, updated)
        # Session policy must not remove or weaken the unrelated safety/evidence text.
        for start, end in (("## Scope", "## Work"),
                           ("For every live-game action", "## Keep workspace memory summarized"),
                           ("## Stop signals", None)):
            section = original.split(start, 1)[1]
            if end:
                section = section.split(end, 1)[0]
            self.assertIn(start + section, updated)

    def test_template_drift_fails_closed(self):
        original = self.original(self.project, self.task, self.workspace)
        with self.assertRaisesRegex(ValueError, "template changed"):
            strategy.strategy_contract(original.replace("contract v7", "contract v8", 1))
        with self.assertRaises(ValueError):
            strategy.strategy_contract(original + strategy.OLD_BOUND)

    def test_dry_run_then_audited_migration_preserves_task_and_resume(self):
        self.assertEqual(self.prepare(dry_run=False), "initialized")
        marker = self.workspace / self.loop.WORKSPACE_METADATA
        prompt = self.workspace / "LOOP.md"
        old_marker, old_prompt = marker.read_bytes(), prompt.read_bytes()
        task_bytes = self.task.read_bytes()
        memory = {}
        for name in ("ATTEMPTS.md", "HANDOFF.md", "ITERATIONS.jsonl", "RESUME.json"):
            path = self.workspace / name
            path.write_text("preserved " + name, encoding="utf-8")
            memory[name] = path.read_bytes()
        strategy.install_contract(self.loop)
        self.assertEqual(self.prepare(dry_run=True, migrate_prompt=True), "migrated")
        self.assertEqual(marker.read_bytes(), old_marker)
        self.assertEqual(prompt.read_bytes(), old_prompt)
        self.assertEqual(self.prepare(dry_run=False, migrate_prompt=True), "migrated")
        after = json.loads(marker.read_text(encoding="utf-8"))
        before = json.loads(old_marker)
        self.assertEqual(after["task_sha256"], before["task_sha256"])
        self.assertEqual(self.task.read_bytes(), task_bytes)
        self.assertIn(before["loop_sha256"], after["loop_sha256_history"])
        self.assertEqual(after["loop_sha256"], hashlib.sha256(prompt.read_bytes()).hexdigest())
        for name, content in memory.items():
            self.assertEqual((self.workspace / name).read_bytes(), content)
        self.assertEqual(self.prepare(dry_run=False), "resumed")
        self.assertEqual(self.prepare(dry_run=False, migrate_prompt=True), "resumed")

    def test_migration_does_not_authorize_task_changes(self):
        self.prepare(dry_run=False)
        strategy.install_contract(self.loop)
        self.task.write_text("weakened rules", encoding="utf-8")
        with self.assertRaisesRegex(self.loop.RunnerConfigError, "task_sha256"):
            self.prepare(dry_run=False, migrate_prompt=True)

    def test_adapter_keeps_engine_model_ladder_and_default_template(self):
        engine = self.loop.run_sessions
        builder = self.loop.build_agent_command
        strategy.install_contract(self.loop)
        self.assertIs(self.loop.run_sessions, engine)
        self.assertIs(self.loop.build_agent_command, builder)
        vanilla = strategy.load_harness()
        self.assertEqual(vanilla._workspace_loop_text(self.project, self.task, self.workspace),
                         self.original(self.project, self.task, self.workspace))

    def test_migrate_only_never_starts_runner_or_agent(self):
        context = self.loop.RunContext(self.project, self.workspace / "LOOP.md", self.workspace, True)
        with patch.object(strategy, "load_harness", return_value=self.loop), \
                patch.object(self.loop, "make_context", return_value=(context, "migrated")) as prepare, \
                patch.object(self.loop, "main") as launch:
            self.assertEqual(strategy.main(["--agent", "codex", "--project", str(strategy.PROJECT),
                                            "--task-name", strategy.TASK_NAME, "--migrate-only"]), 0)
            launch.assert_not_called()
            self.assertTrue(prepare.call_args.kwargs["migrate_prompt"])

    def test_adapter_rejects_other_task(self):
        with self.assertRaisesRegex(ValueError, "scoped"):
            strategy.main(["--agent", "codex", "--project", str(strategy.PROJECT),
                           "--task-name", "other-job", "--migrate-only"])


if __name__ == "__main__":
    unittest.main()
