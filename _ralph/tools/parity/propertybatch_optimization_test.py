"""Regression tests for propertybatch's bounded process scheduler and output safety."""

from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import propertybatch


class PropertybatchOptimizationTests(unittest.TestCase):
    def test_default_parallelism_is_cpu_bounded_and_never_zero(self) -> None:
        with mock.patch.object(os, "cpu_count", return_value=20):
            self.assertEqual(propertybatch.default_parallel_jobs(), 4)
        with mock.patch.object(os, "cpu_count", return_value=2):
            self.assertEqual(propertybatch.default_parallel_jobs(), 1)
        with mock.patch.object(os, "cpu_count", return_value=None):
            self.assertEqual(propertybatch.default_parallel_jobs(), 1)

    def test_output_aliases_are_rejected_before_work_starts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            jobs = [
                {"vanilla": "v1", "expanded": "e1", "out": root / "same.json"},
                {"vanilla": "v2", "expanded": "e2", "out": root / "same.json"},
            ]
            with self.assertRaisesRegex(SystemExit, "output path collision"):
                propertybatch.validate_outputs(
                    {"differences_mode": "count"}, jobs, root / "batch.json")

    def test_full_mode_requires_unique_difference_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            jobs = [{"vanilla": "v", "expanded": "e", "out": root / "case.json"}]
            with self.assertRaisesRegex(SystemExit, "needs a differences path"):
                propertybatch.validate_outputs({}, jobs, root / "batch.json")

            jobs[0]["differences"] = root / "batch.json"
            with self.assertRaisesRegex(SystemExit, "output path collision"):
                propertybatch.validate_outputs({}, jobs, root / "batch.json")


if __name__ == "__main__":
    unittest.main()
