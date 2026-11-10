#!/usr/bin/env python3
"""Unit tests for attribution.py on checked-in fake profile and log."""

import gzip
import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import attribution
import sol
import sol_summary

DATA = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "testdata", "attribution")


def make_record(bazel=100.0):
    """Minimal record.json content for a summarizable repeat."""
    return {"flow": "f", "config": "c", "scenario": "s", "identical": True,
            "reason": "ok", "bazel": {"cpu_s": bazel, "real_s": 1.0},
            "sol": {"cpu_s": 90.0, "real_s": 0.9}, "n_sol_actions": 1,
            "chain": {}}


def put_rep(root, config, scenario, rep, with_log=True, with_trace=True,
            bazel=100.0):
    """Rep dir holding record.json plus the gzipped fixture files."""
    rep_dir = os.path.join(root, "sol", config, scenario, "rep%d" % rep)
    os.makedirs(rep_dir)
    with open(os.path.join(rep_dir, "record.json"), "w") as fh:
        json.dump(make_record(bazel), fh)
    for present, name in ((with_trace, "trace"), (with_log, "execlog")):
        if present:
            with open(os.path.join(DATA, name + ".json"), "rb") as fin:
                with open(os.path.join(rep_dir, name + ".json.gz"),
                          "wb") as fout:
                    fout.write(gzip.compress(fin.read()))
    return rep_dir


class AttributionTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.root)

    def test_each_part_is_computed(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        result = attribution.attribute_flow([rep], 100.0)
        parts = result["parts"]
        self.assertEqual(parts["fetch_extract"], 10.0)
        self.assertEqual(parts["module_resolution"], 5.0)
        # 8s package creation (nested Starlark counted once) + 10s analysis
        self.assertEqual(parts["loading_analysis"], 18.0)
        self.assertEqual(parts["sandbox"], 2.0)
        self.assertEqual(parts["target_actions"], 20.0)
        self.assertAlmostEqual(parts["host_tools"]["total"], 42.0)
        self.assertAlmostEqual(parts["unattributed"], 3.0)
        self.assertAlmostEqual(result["gap_s"], 3.0)
        self.assertTrue(result["ok"])

    def test_host_tools_top_ten_and_other(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        host = attribution.attribute_flow([rep], 100.0)["parts"][
            "host_tools"]
        for key in ("by_mnemonic", "by_repo"):
            self.assertEqual(len(host[key]), 11)
            self.assertAlmostEqual(host[key]["other"], 2.0)
            self.assertNotIn("M01", host[key])
        self.assertAlmostEqual(host["by_mnemonic"]["M12"], 6.25)
        self.assertAlmostEqual(host["by_repo"]["repo12"], 6.25)

    def test_gap_beyond_five_percent_is_not_ok(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1)
        result = attribution.attribute_flow([rep], 150.0)
        self.assertFalse(result["ok"])
        self.assertAlmostEqual(result["gap_s"], 53.0)
        self.assertAlmostEqual(result["parts"]["unattributed"], 53.0)
        over = attribution.attribute_flow([rep], 90.0)
        self.assertFalse(over["ok"])
        self.assertAlmostEqual(over["gap_s"], -7.0)

    def test_missing_file_is_an_error(self):
        rep = put_rep(self.root, "sim_debug", "clean", 1, with_log=False)
        result = attribution.attribute_flow([rep], 100.0)
        self.assertFalse(result["ok"])
        self.assertIn("execlog.json.gz", result["error"])

    def test_medians_over_reps(self):
        reps = [put_rep(self.root, "sim_debug", "clean", n)
                for n in (1, 2)]
        result = attribution.attribute_flow(reps, 100.0)
        self.assertEqual(result["parts"]["fetch_extract"], 10.0)

    def test_summarize_flows_carry_split(self):
        for config, scenario in (("sim_debug", "clean"),
                                 ("sim_debug", "core_edit"),
                                 ("sim_debug", "app_edit"),
                                 ("android_debug", "core_edit"),
                                 ("android_debug", "clean")):
            put_rep(self.root, config, scenario, 1)
        flows = sol_summary.summarize_configs(
            self.root, {"sha": "x", "repeats": 1, "target_loc": 1,
                        "seed": 1},
            ["sim_debug", "android_debug"])["flows"]
        for flow in ("ios-debug-clean", "ios-debug-body",
                     "android-debug-body"):
            self.assertIn("attribution", flows[flow])
            self.assertIn("profile", flows[flow])
        for flow in ("ios-debug-app", "android-debug-clean"):
            self.assertNotIn("attribution", flows[flow])

    def _run_summarize(self, strict, bazel):
        shutil.rmtree(os.path.join(self.root, "sol"), ignore_errors=True)
        put_rep(self.root, "sim_debug", "clean", 1, bazel=bazel)
        out = os.path.join(self.root, "ios-sol.json")
        argv = ["summarize", "--results", self.root, "--sha", "x",
                "--repeats", "1", "--target-loc", "1", "--seed", "1",
                "--out", out]
        if strict:
            argv.append("--strict-attribution")
        with mock.patch("builtins.print"):
            return sol.main(argv)

    def test_strict_fails_only_when_not_ok(self):
        self.assertEqual(self._run_summarize(False, 500.0), 0)
        self.assertEqual(self._run_summarize(True, 500.0), 1)
        with open(os.path.join(self.root, "ios-sol.json")) as fh:
            flow = json.load(fh)["flows"]["ios-debug-clean"]
        self.assertFalse(flow["attribution"]["ok"])

    def test_strict_passes_when_ok(self):
        self.assertEqual(self._run_summarize(True, 100.0), 0)
        summaries = {"ios": {"flows": {"f": {"attribution": {"ok": True}},
                                       "g": {}}}}
        self.assertEqual(attribution.strict_attribution_exit(
            summaries, True), 0)


if __name__ == "__main__":
    unittest.main()
