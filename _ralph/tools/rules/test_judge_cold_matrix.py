import unittest

from judge_cold_matrix import GATES, PARITY_FIELDS, compare_pair, judge_run, number, truth


def run(rules=None, status="complete", log="", snapshot=None):
    return {"report": {"status": status, "rules": {} if rules is None else rules, "error": False},
            "snapshot": {"optimization_failures": []} if snapshot is None else snapshot,
            "log": log, "identity": None}


class EvidenceJudgeTests(unittest.TestCase):
    def test_cluster_range_uses_completed_plans_not_search_target(self):
        rules = {'ring_audit_resource_clusters': 8, 'ring_audit_rocket_pads': 8,
                 'ring_plan_placed_clusters': 8, 'ring_plan_desired_clusters': 10,
                 'ring_plan_cluster_count_stream': 'deposits:1:seed=123',
                 'full_map_playable': True, 'enrichment_in_ring': 1,
                 'apron_report': 'error= ring_sectors=2'}
        audit = dict.fromkeys(('resource_failures', 'rocket_failures', 'cluster_anchor_failures',
                              'cluster_shortfall', 'cluster_excess', 'cluster_premium_excess',
                              'cluster_extractor_shortfall', 'cluster_extractor_excess',
                              'cluster_resource_shortfall', 'cluster_resource_excess',
                              'cluster_weighted_composition_failures'), 0)
        snapshot = {'optimization_failures': [], 'maps': {'Surface': {'audit': audit}}}
        self.assertEqual(judge_run(run(rules, snapshot=snapshot))['ring-content']['verdict'], 'pass')
        accepted_v936_counts = dict(rules, ring_audit_resource_clusters=9,
                                   ring_audit_rocket_pads=9, ring_plan_placed_clusters=9)
        self.assertEqual(judge_run(run(accepted_v936_counts, snapshot=snapshot))['ring-content']['verdict'], 'pass')
        for field, value in (('ring_audit_resource_clusters', 7), ('ring_audit_resource_clusters', 13),
                             ('ring_audit_rocket_pads', 9), ('ring_plan_placed_clusters', 9),
                             ('ring_plan_desired_clusters', 7), ('ring_plan_desired_clusters', 13),
                             ('ring_plan_desired_clusters', None), ('ring_plan_cluster_count_stream', 'engine')):
            with self.subTest(field=field, value=value):
                changed = dict(rules, **{field: value})
                self.assertEqual(judge_run(run(changed, snapshot=snapshot))['ring-content']['verdict'], 'fail')
        for field in audit:
            changed_audit = dict(audit, **{field: 1})
            bad = {'optimization_failures': [], 'maps': {'Surface': {'audit': changed_audit}}}
            self.assertEqual(judge_run(run(rules, snapshot=bad))['ring-content']['verdict'], 'fail')

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
