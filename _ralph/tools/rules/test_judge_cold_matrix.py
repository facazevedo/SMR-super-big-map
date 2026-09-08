import unittest

from judge_cold_matrix import GATES, PARITY_FIELDS, compare_pair, judge_run, number, truth


def run(rules=None, status="complete", log="", snapshot=None):
    return {"report": {"status": status, "rules": {} if rules is None else rules, "error": False},
            "snapshot": {"optimization_failures": []} if snapshot is None else snapshot,
            "log": log, "identity": None}


class EvidenceJudgeTests(unittest.TestCase):
    def test_absent_run_never_green(self):
        verdicts = judge_run({"report": None})
        self.assertEqual(set(verdicts), set(GATES))
        self.assertTrue(all(v["verdict"] == "pending" for v in verdicts.values()))

    def test_failed_before_census_is_red(self):
        result = judge_run(run(False, status="engine_error"))
        self.assertEqual(result["no-errors"]["verdict"], "fail")
        self.assertTrue(all(v["verdict"] != "pass" for v in result.values()))

    def test_missing_pair_is_not_pass(self):
        self.assertEqual(compare_pair({"report": None}, run())["verdict"], "pending")

    def test_failed_pair_is_red(self):
        self.assertEqual(compare_pair(run(False), run())["verdict"], "fail")

    def test_missing_fields_on_both_sides_are_not_equal_evidence(self):
        result = compare_pair(run(), run())
        self.assertEqual(result["verdict"], "fail")
        self.assertEqual(set(result["differences"]), set(PARITY_FIELDS))

    def test_complete_equal_pair(self):
        fields = dict.fromkeys(PARITY_FIELDS, "fixture")
        self.assertEqual(compare_pair(run(fields), run(fields.copy()))["verdict"], "pass")

    def test_single_field_difference_is_red(self):
        a = dict.fromkeys(PARITY_FIELDS, "fixture")
        b = dict(a, ug_enrichment_digest="changed")
        self.assertEqual(compare_pair(run(a), run(b))["differences"], ["ug_enrichment_digest"])

    def test_missing_flushed_log_is_pending(self):
        self.assertEqual(judge_run(run(log=None))["no-errors"]["verdict"], "pending")

    def test_error_signatures_are_red(self):
        for line in ("[LUA ERROR] failure", "[ASSERT] failure", "Assertion failed",
                     "Exception code c0000005", "[Super Big Map][OptimizationFailure] raster"):
            with self.subTest(line=line):
                self.assertEqual(judge_run(run(log=line))["no-errors"]["verdict"], "fail")

    def test_engine_banners_are_not_errors(self):
        result = judge_run(run(log="Command line: -no_interactive_asserts\nPlatform: asserts, cheats"))
        self.assertEqual(result["no-errors"]["verdict"], "pass")
        self.assertEqual(result["process"]["verdict"], "pending")
        self.assertEqual(result["seed-parity"]["verdict"], "pending")

    def test_recorded_optimization_failure_is_red(self):
        result = judge_run(run(snapshot={"optimization_failures": [{"unit": "raster"}]}))
        self.assertEqual(result["no-errors"]["verdict"], "fail")

    def test_lua_value_conversion_is_conservative(self):
        self.assertTrue(truth("true"))
        self.assertFalse(truth("false"))
        self.assertFalse(truth("nil"))
        self.assertIsNone(number("nil"))
        self.assertEqual(number("0"), 0)


if __name__ == "__main__":
    unittest.main()
