#!/usr/bin/env python3
"""Checks that perf-ios.yaml retries a failed artifact upload once.

Each first upload may fail without failing the job; one retry follows after a
pause, and a closing step names every artifact whose retry failed too.
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from perf_linux_workflow_test import steps

_ARTIFACTS = {
    "ios-sol": ("Upload ios-sol", "Retry upload ios-sol"),
    "ios-ab": ("Upload ios-ab", "Retry upload ios-ab"),
    "ios-profile": ("Upload ios-profile", "Retry upload ios-profile"),
}


def load():
    """Every step of the iOS bench job, parsed."""
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "..", "..", ".github", "workflows",
                        "perf-ios.yaml")
    with open(path, encoding="utf-8") as fh:
        return steps(fh.read().splitlines())


def by_name(all_steps, name):
    """The step called `name`, failing the test when it is missing."""
    found = [s for s in all_steps if s.get("name") == name]
    assert len(found) == 1, "expected one step named %r" % name
    return found[0]


def position(all_steps, name):
    """Index of the step called `name`."""
    return all_steps.index(by_name(all_steps, name))


class PerfIosUploadTest(unittest.TestCase):
    """The upload retry steps and the failure report."""

    def test_first_uploads_continue_on_error_with_id(self):
        all_steps = load()
        for first, _ in _ARTIFACTS.values():
            step = by_name(all_steps, first)
            self.assertEqual(step.get("continue-on-error"), "true", first)
            self.assertTrue(step.get("id"), first)

    def test_retries_mirror_first_uploads(self):
        all_steps = load()
        for first, retry in _ARTIFACTS.values():
            one = by_name(all_steps, first)
            two = by_name(all_steps, retry)
            self.assertEqual(two.get("uses"), one.get("uses"), retry)
            self.assertEqual(two.get("with"), one.get("with"), retry)
            self.assertTrue(two.get("id"), retry)
            self.assertNotIn("continue-on-error", two, retry)
            self.assertIn("steps.%s.outcome == 'failure'" % one["id"],
                          two.get("if", ""), retry)

    def test_retry_keeps_first_upload_condition(self):
        all_steps = load()
        for first, retry in _ARTIFACTS.values():
            cond = by_name(all_steps, first)["if"]
            body = cond.replace("${{", "").replace("}}", "").strip()
            self.assertIn(body, by_name(all_steps, retry)["if"], retry)

    def test_order_wait_retries_report(self):
        all_steps = load()
        wait = position(all_steps, "Wait before upload retry")
        self.assertEqual(by_name(all_steps, "Wait before upload retry")["run"]
                         .strip(), "sleep 60")
        for first, retry in _ARTIFACTS.values():
            self.assertLess(position(all_steps, first), wait)
            self.assertGreater(position(all_steps, retry), wait)
        self.assertEqual(all_steps[-1]["name"], "Report failed uploads")

    def test_report_uses_env_only(self):
        report = by_name(load(), "Report failed uploads")
        env = report.get("env", {})
        for _, retry in _ARTIFACTS.values():
            rid = by_name(load(), retry)["id"]
            self.assertTrue(
                any("steps.%s.outcome" % rid in v for v in env.values()),
                retry)
        self.assertEqual(len(env), 3)
        self.assertNotIn("${{", report["run"])


if __name__ == "__main__":
    unittest.main()
