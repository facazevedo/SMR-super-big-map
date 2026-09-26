import unittest

from judge_cold_matrix import GATES, PARITY_FIELDS, compare_pair, judge_run, number, truth


def run(rules=None, status="complete", log="", snapshot=None):
    return {"report": {"status": status, "rules": {} if rules is None else rules, "error": False},
            "snapshot": {"optimization_failures": []} if snapshot is None else snapshot,
            "log": log, "identity": None}


class EvidenceJudgeTests(unittest.TestCase):
    def test_underground_rocks_require_positive_coverage_without_native_exemptions(self):
        census = dict(boundary="underground after ready, before buttons", eligible=100,
                      direct_terrain_witness=80, support_graph_valid=20,
                      native_composition_preserved=0, inconclusive=0, incomplete=0, defect=0, findings=[])
        def verdict(value):
            evidence=run()
            evidence["observations"]={"report": {"underground_support_census": value}}
            return judge_run(evidence)["underground-rock-support"]["verdict"]
        self.assertEqual(verdict(census), "pass")
        self.assertEqual(verdict(None), "pending")
        for key, value in (("boundary", "wrong"), ("inconclusive", 1), ("incomplete", 1),
                           ("defect", 1), ("native_composition_preserved", 1),
                           ("eligible", 101), ("findings", [{}]), ("support_graph_valid", None)):
            self.assertEqual(verdict(dict(census, **{key: value})), "fail")

    def test_all_three_temporary_buttons_require_exercised_handlers(self):
        buttons = dict(status="complete", surface_sectors=400, surface_deep_scanned=400,
                       underground_objects=110, underground_revealed=110, darkness=0,
                       elevator_mode="construction", elevator_template="Elevator")
        def verdict(value):
            evidence=run()
            evidence["observations"]={"report": {"buttons": value}}
            return judge_run(evidence)["temporary-buttons"]["verdict"]
        self.assertEqual(verdict(buttons), "pass")
        self.assertEqual(verdict(None), "pending")
        for key, value in (("status", "failed"), ("surface_deep_scanned", 399),
                           ("underground_revealed", 109), ("darkness", 1),
                           ("elevator_template", "WrongBuilding")):
            self.assertEqual(verdict(dict(buttons, **{key: value})), "fail")

    def test_rock_census_accounts_for_every_eligible_instance(self):
        census = dict(boundary="T1 before player actions", eligible=100, direct_terrain_witness=80, support_graph_valid=20,
                      native_composition_preserved=0, inconclusive=0, incomplete=0, defect=0, findings=[])
        def verdict(value):
            evidence=run()
            evidence["observations"]={"report": {"support_census": value}}
            return judge_run(evidence)["rock-support"]["verdict"]
        self.assertEqual(verdict(census), "pass")
        # Owner ruling 2026-09-25: surface vanilla-authored compositions count as support.
        self.assertEqual(verdict(dict(census, support_graph_valid=15, native_composition_preserved=5)), "pass")
        for key, value in (("inconclusive", 1), ("incomplete", 1), ("defect", 1),
                           ("native_composition_preserved", None), ("native_composition_preserved", 1),
                           ("eligible", 101), ("eligible", 0), ("support_graph_valid", None),
                           ("findings", [{}]), ("findings", None)):
            self.assertEqual(verdict(dict(census, **{key: value})), "fail")
        self.assertEqual(verdict(None), "pending")
        self.assertEqual(verdict(dict(census, boundary="after access")), "pending")
        self.assertEqual(judge_run(run())["rock-support"]["verdict"], "pending")

    def test_surface_loading_includes_successful_seating_and_strict_limit(self):
        rules = dict(t0_to_t1_ms=74999, seating_before_t1=True, seating={"rejected": 0})
        self.assertEqual(judge_run(run(rules))["surface-loading"]["verdict"], "pass")
        for field, value in (("t0_to_t1_ms", 75000), ("t0_to_t1_ms", 0),
                             ("seating_before_t1", False), ("seating", None),
                             ("seating", {"rejected": 1}), ("seating", {"rejected": 0, "error": "failed"})):
            self.assertEqual(judge_run(run(dict(rules, **{field: value})))["surface-loading"]["verdict"], "fail")
        self.assertEqual(judge_run(run())["surface-loading"]["verdict"], "pending")

    def test_underground_loading_strict_boundary_and_readiness(self):
        rules = dict(ug_loading_ms=59999, ug_loading_ready=True,
                     ug_loading_boundary="first-access-phase through prepared and covers closed")
        self.assertEqual(judge_run(run(rules))["underground-loading"]["verdict"], "pass")
        for value in (60000, 60001, 0, -1, None, "invalid"):
            self.assertEqual(judge_run(run(dict(rules, ug_loading_ms=value)))["underground-loading"]["verdict"], "fail")
        for field, value in (("ug_loading_ready", False), ("ug_loading_boundary", "switch-only")):
            self.assertEqual(judge_run(run(dict(rules, **{field: value})))["underground-loading"]["verdict"], "fail")
        self.assertEqual(judge_run(run())["underground-loading"]["verdict"], "pending")

    def test_cluster_range_uses_completed_plans_not_search_target(self):
        rules = {'ring_audit_resource_clusters': 8, 'ring_audit_rocket_pads': 8,
                 'ring_plan_placed_clusters': 8, 'ring_plan_desired_clusters': 10,
                 'ring_plan_cluster_count_stream': 'deposits:1:seed=123',
                 'full_map_playable': True, 'enrichment_in_ring': 1,
                 'apron_report': 'error= ring_sectors=2', 'ring_cluster_badge_repeats': '0'}
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
                             ('ring_plan_desired_clusters', None), ('ring_plan_cluster_count_stream', 'engine'),
                             ('ring_cluster_badge_repeats', '1'), ('ring_cluster_badge_repeats', None),
                             ('ring_cluster_badge_repeats', 'no outer resource census on map')):
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
