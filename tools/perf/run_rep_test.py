#!/usr/bin/env python3
"""Unit tests for run_rep.py (ordering: builds first, replays last)."""

import json
import os
import shutil
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import run_rep
from run_rep import make_writable_tree, run_rep


class Proc:
    def __init__(self, returncode=0, stdout=""):
        self.returncode = returncode
        self.stdout = stdout


class FakeRun:
    """Records argv; emulates bazel build/info/shutdown and the tools."""

    def __init__(self, execroot="/fake/execroot"):
        self.calls = []
        self.execroot = execroot

    def __call__(self, argv, cwd=None, capture_output=False):
        self.calls.append(list(argv))
        if argv[:2] == ["bazel", "--output_base=/fake/out"]:
            if argv[2:4] == ["info", "execution_root"]:
                return Proc(stdout=self.execroot + "\n")
            return Proc()
        if argv[0] == "bazel":
            return Proc()
        # Tool invocations: pretend to write their outputs.
        if "execlog.py" in argv[1]:
            out = argv[argv.index("--out") + 1]
            with open(out, "w", encoding="utf-8",
                      newline="\n") as fh:
                fh.write(json.dumps({"n_spawns": 1}) + "\n")
        if "replay.py" in argv[1]:
            out = argv[argv.index("--out") + 1]
            with open(out, "w", encoding="utf-8",
                      newline="\n") as fh:
                fh.write(json.dumps({"n_replayed": 1}) + "\n")
        return Proc()

    def kinds(self):
        kinds = []
        for argv in self.calls:
            if argv[0] == "bazel" and "build" in argv:
                kinds.append("build")
            elif "apply-" in (argv[2] if len(argv) > 2 else ""):
                kinds.append("edit")
            elif argv[0] == "bazel" and "shutdown" in argv:
                kinds.append("shutdown")
            elif len(argv) > 1 and "execlog.py" in argv[1]:
                kinds.append("summarize")
            elif len(argv) > 1 and "replay.py" in argv[1]:
                kinds.append("replay")
            elif "info" in argv:
                kinds.append("info")
            else:
                kinds.append("other:" + " ".join(argv))
        return kinds


class OrderingTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run-rep-test-")
        self.work = os.path.join(self.tmp, "work")
        self.dest = os.path.join(self.tmp, "results", "base")
        os.makedirs(self.work)
        self.execroot = os.path.join(self.tmp, "execroot")
        os.makedirs(os.path.join(self.execroot, "bazel-out"))
        self.chmods = []

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def drive(self):
        fake = FakeRun(execroot=self.execroot)
        record = run_rep(
            "/tools", self.work, "/fake/out", self.dest, 2,
            run=fake, chmod=lambda path: self.chmods.append(path) or 0)
        return (fake, record)

    def test_builds_before_replays_and_shutdown_last(self):
        fake, record = self.drive()
        kinds = fake.kinds()
        self.assertEqual(kinds.count("build"), 3)
        self.assertEqual(kinds.count("replay"), 3)
        self.assertEqual(kinds[-1], "shutdown")
        first_replay = kinds.index("replay")
        self.assertNotIn("build", kinds[first_replay:])
        self.assertNotIn("shutdown", kinds[:first_replay])
        # Edit order: clean builds unedited, app edit before 2nd build,
        # body edit before 3rd build.
        self.assertEqual(kinds[:2], ["build", "edit"])
        self.assertEqual(record["execroot"], self.execroot)
        self.assertEqual(sorted(record["logs"]),
                         ["app_edit", "clean", "core_edit"])

    def test_chmod_between_last_build_and_first_replay(self):
        fake, _ = self.drive()
        kinds = fake.kinds()
        last_build = len(kinds) - 1 - kinds[::-1].index("build")
        first_replay = kinds.index("replay")
        self.assertLess(last_build, first_replay)
        self.assertEqual(self.chmods,
                         [self.execroot + "/bazel-out"])

    def test_results_layout(self):
        self.drive()
        for scenario in ["clean", "app_edit", "core_edit"]:
            for name in ["execlog.json", "replay.json"]:
                path = os.path.join(self.dest, scenario, "rep2", name)
                self.assertTrue(os.path.isfile(path), path)

    def test_replay_flags_forwarded(self):
        fake = FakeRun()
        run_rep("/tools", self.work, "/fake/out", self.dest, 1,
                replay_timeout=11.0, replay_budget=22.0,
                run=fake, chmod=lambda path: 0)
        replays = [c for c in fake.calls
                   if len(c) > 1 and "replay.py" in c[1]]
        self.assertEqual(len(replays), 3)
        for argv in replays:
            self.assertIn("11.0", argv[argv.index("--timeout") + 1])
            self.assertIn("22.0", argv[argv.index("--budget-seconds") + 1])

    def test_build_failure_aborts_before_replay(self):
        class FailBuild(FakeRun):
            def __call__(self, argv, cwd=None, capture_output=False):
                if argv[0] == "bazel" and "build" in argv:
                    self.calls.append(list(argv))
                    return Proc(returncode=1)
                return super().__call__(argv, cwd, capture_output)

        fake = FailBuild()
        with self.assertRaises(RuntimeError):
            run_rep("/tools", self.work, "/fake/out", self.dest, 1,
                    run=fake, chmod=lambda path: 0)
        self.assertNotIn("replay", fake.kinds())


class ChmodTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="run-rep-chmod-")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_readonly_tree_becomes_writable(self):
        sub = os.path.join(self.tmp, "bazel-out", "d")
        os.makedirs(sub)
        target = os.path.join(sub, "out.o")
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("x")
        os.chmod(target, stat.S_IRUSR)
        os.chmod(sub, stat.S_IRUSR | stat.S_IXUSR)
        changed = make_writable_tree(os.path.join(self.tmp, "bazel-out"))
        self.assertGreaterEqual(changed, 1)
        mode = os.stat(target).st_mode
        self.assertTrue(mode & stat.S_IWUSR)
        with open(target, "w", encoding="utf-8") as fh:
            fh.write("y")

    def test_missing_root_is_zero(self):
        self.assertEqual(
            make_writable_tree(os.path.join(self.tmp, "absent")), 0)


if __name__ == "__main__":
    unittest.main()
