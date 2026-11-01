#!/usr/bin/env python3
"""The real-plugin CocoaPods iOS fetch and build matrix (POD-11).

Fetch mode reads ``expected_pods.json`` and runs one ``bazel query`` per
pinned plugin against the ``deps_pods`` hub, comparing the result with the
recorded expectation. Build mode reads the plugins ``expected_pods.json``
records as ``ok`` and builds each spoke's iOS device library using
``--platforms=@rules_flutter//flutter/platforms:ios_arm64``;
``build_expected_pods.json`` names the builds that are gated today.

The runner holds no plugin names: both modes are driven entirely by the JSON
data files beside it.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

ROOT = Path(__file__).resolve().parent
EXPECTED_PODS_PATH = ROOT / "expected_pods.json"
BUILD_EXPECTED_PODS_PATH = ROOT / "build_expected_pods.json"
BAZEL = ("bazel", "--max_idle_secs=60")
FETCH_TARGET = "@deps_pods__{plugin}//:all"
BUILD_TARGET = "@deps_pods__{plugin}//:{plugin}_apple_ios"
IOS_PLATFORM = "--platforms=@rules_flutter//flutter/platforms:ios_arm64"


@dataclass(frozen=True)
class Outcome:
    """One command's exit code and combined standard output and error."""

    returncode: int
    output: str


@dataclass(frozen=True)
class Result:
    """One PASS, FAIL or RECORD line in a mode's report."""

    name: str
    status: str
    detail: str = ""


Runner = Callable[[list[str]], Outcome]


def run_bazel(args: list[str]) -> Outcome:
    """Run one Bazel command in this workspace and return its combined output."""
    try:
        completed = subprocess.run(
            [*BAZEL, *args],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError as error:
        raise SystemExit(f"run_pods_matrix: cannot run bazel: {error}") from error
    return Outcome(completed.returncode, (completed.stdout or "") + (completed.stderr or ""))


def load_json(path: Path, what: str, allow_empty: bool = True) -> dict[str, str]:
    """Read a JSON object of string values, naming the file on every failure."""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise SystemExit(f"run_pods_matrix: cannot read {what} {path}: {error}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"run_pods_matrix: {what} {path} is not valid JSON: {error}") from error
    if not isinstance(data, dict):
        raise SystemExit(f"run_pods_matrix: {what} {path} must be a JSON object")
    if not allow_empty and not data:
        raise SystemExit(f"run_pods_matrix: {what} {path} must be a non-empty JSON object")
    for key, value in data.items():
        if not isinstance(key, str) or not key:
            raise SystemExit(f"run_pods_matrix: {what} {path} has an empty or non-string key")
        if not isinstance(value, str) or not value:
            raise SystemExit(f"run_pods_matrix: {what} {path} entry {key!r} must be a non-empty string")
    return data


def compare(expected: str, outcome: Outcome) -> tuple[bool, str]:
    """Whether one outcome satisfies one expectation, with a reason when it does not.

    ``ok`` requires exit 0. ``fail`` requires non-zero exit. Anything else is a
    refusal substring (or multi-part substring separated by ``...``): the command
    must exit non-zero and contain each required part in its combined output.
    """
    if expected == "ok":
        if outcome.returncode == 0:
            return True, ""
        return False, f"expected exit 0, got {outcome.returncode}"
    if not expected:
        return False, "the expected refusal substring is empty"
    if outcome.returncode == 0:
        return False, f"expected a refusal containing {expected!r}, but the command exited 0"
    if expected == "fail":
        return True, ""
    parts = [part.strip() for part in expected.split("...") if part.strip()]
    for part in parts:
        if part not in outcome.output:
            return False, f"refusal substring {part!r} is missing from the output"
    return True, ""


def run_fetch(expected: dict[str, str], runner: Runner) -> list[Result]:
    """Query every pinned plugin spoke in deps_pods and compare with expectation."""
    results = []
    for plugin, want in expected.items():
        outcome = runner(["query", FETCH_TARGET.format(plugin=plugin)])
        ok, detail = compare(want, outcome)
        results.append(Result(plugin, "PASS" if ok else "FAIL", detail))
    return results


def run_build(expected: dict[str, str], gated: dict[str, str], runner: Runner) -> list[Result]:
    """Build every expected-ok plugin spoke, gating only entries in build_expected_pods.json."""
    plugins = [name for name, value in expected.items() if value == "ok"]
    results = []
    for plugin in plugins:
        target = BUILD_TARGET.format(plugin=plugin)
        outcome = runner(["build", IOS_PLATFORM, target])
        if plugin not in gated:
            actual = "ok" if outcome.returncode == 0 else "fail"
            results.append(Result(plugin, "RECORD", f"build {actual}"))
            continue
        want = gated[plugin]
        ok, detail = compare(want, outcome)
        results.append(Result(plugin, "PASS" if ok else "FAIL", detail))
    for plugin in gated:
        if plugin not in plugins:
            results.append(Result(plugin, "FAIL", "gated build plugin is not an expected-ok plugin"))
    return results


def report(results: list[Result], mode: str) -> int:
    """Print one line per result, then the summary; return 1 when one failed."""
    for result in results:
        line = f"{result.status} {result.name}"
        if result.detail:
            line += f": {result.detail}"
        print(line)
    failed = sum(1 for result in results if result.status == "FAIL")
    print(f"\n{mode}: {len(results) - failed} passed, {failed} failed, {len(results)} total")
    return 1 if failed else 0


def _test_compare_cases() -> list[str]:
    """Run comparator unit test cases and return failure messages."""
    cases = [
        ("matching ok", "ok", Outcome(0, ""), True),
        ("false ok", "ok", Outcome(1, "fetch refused"), False),
        ("passing refusal", "pod missing", Outcome(1, "Error: pod missing"), True),
        ("wrong exit for refusal", "pod missing", Outcome(0, "Error: pod missing"), False),
        ("missing refusal substring", "pod missing", Outcome(1, "other error"), False),
        ("wrong-case refusal substring", "Pod Missing", Outcome(1, "pod missing"), False),
        ("empty refusal substring", "", Outcome(1, ""), False),
        ("passing fail keyword", "fail", Outcome(1, "any error"), True),
        ("false fail keyword", "fail", Outcome(0, ""), False),
        (
            "multi-part substring match",
            "pod \"Core\" (1.0.0...which no Bazel target provides",
            Outcome(1, "pod \"Core\" (1.0.0 in @@//:Podfile.lock), which no Bazel target provides"),
            True,
        ),
        (
            "multi-part substring missing part",
            "pod \"Core\" (1.0.0...which no Bazel target provides",
            Outcome(1, "pod \"Core\" (2.0.0 in @@//:Podfile.lock), which no Bazel target provides"),
            False,
        ),
    ]
    failures = []
    for name, expected, outcome, want in cases:
        got, detail = compare(expected, outcome)
        if got != want:
            failures.append(f"{name}: expected {want}, got {got} ({detail})")
    return failures


def _test_fetch_cases() -> list[str]:
    """Verify fetch mode logic: queries spoke and applies compare."""
    failures = []
    commands_run: list[list[str]] = []

    def mock_runner(args: list[str]) -> Outcome:
        commands_run.append(args)
        return Outcome(0, "")

    expected = {"plugin_a": "ok", "plugin_b": "missing pod"}
    results = run_fetch(expected, mock_runner)
    if len(results) != 2:
        failures.append(f"fetch: expected 2 results, got {len(results)}")
    if results[0].status != "PASS":
        failures.append(f"fetch plugin_a: expected PASS, got {results[0]}")
    if results[1].status != "FAIL":
        failures.append(f"fetch plugin_b: expected FAIL, got {results[1]}")
    if commands_run and commands_run[0] != ["query", "@deps_pods__plugin_a//:all"]:
        failures.append(f"fetch query target mismatch: {commands_run[0]}")
    return failures


def _test_build_cases() -> list[str]:
    """Verify build mode logic: gating, RECORD, and iOS platform flags."""
    failures = []
    commands_run: list[list[str]] = []

    def mock_runner(args: list[str]) -> Outcome:
        commands_run.append(args)
        return Outcome(0, "")

    expected = {"plugin_ok": "ok", "plugin_fail": "refusal"}
    gated: dict[str, str] = {}
    results = run_build(expected, gated, mock_runner)
    if len(results) != 1 or results[0].status != "RECORD":
        failures.append(f"ungated build: expected 1 RECORD result, got {results}")
    if sum(1 for r in results if r.status == "FAIL") != 0:
        failures.append("ungated RECORD results counted as FAIL")
    if not commands_run:
        failures.append("no commands executed during run_build")
    else:
        cmd = commands_run[0]
        if IOS_PLATFORM not in cmd:
            failures.append(f"build command missing {IOS_PLATFORM}: {cmd}")
        expected_target = "@deps_pods__plugin_ok//:plugin_ok_apple_ios"
        if expected_target not in cmd:
            failures.append(f"build command missing target {expected_target}: {cmd}")

    gated_with_invalid = {"unlisted_plugin": "ok"}
    invalid_results = run_build(expected, gated_with_invalid, mock_runner)
    if not any(r.status == "FAIL" for r in invalid_results):
        failures.append("gated plugin not in expected-ok did not fail")

    # Test gated ok passing and failing
    gated_ok = {"plugin_ok": "ok"}
    if run_build(expected, gated_ok, lambda _: Outcome(0, ""))[0].status != "PASS":
        failures.append("gated ok build on exit 0 did not PASS")
    if run_build(expected, gated_ok, lambda _: Outcome(1, "error"))[0].status != "FAIL":
        failures.append("gated ok build on exit 1 did not FAIL")

    # Test gated refusal substring passing and failing
    gated_refusal = {"plugin_ok": "missing symbol"}
    ref_pass = run_build(expected, gated_refusal, lambda _: Outcome(1, "Error: missing symbol"))
    if ref_pass[0].status != "PASS":
        failures.append("gated refusal build with matching output did not PASS")
    ref_fail = run_build(expected, gated_refusal, lambda _: Outcome(1, "other error"))
    if ref_fail[0].status != "FAIL":
        failures.append("gated refusal build with missing substring did not FAIL")

    return failures


def self_test() -> int:
    """Exercise comparator and build logic; no Bazel, network or workspace needed."""
    failures = _test_compare_cases() + _test_fetch_cases() + _test_build_cases()
    if failures:
        for failure in failures:
            print(f"SELF-TEST FAIL: {failure}")
        return 1
    print("SELF-TEST OK")
    return 0


def parse_args(argv: list[str]) -> argparse.Namespace:
    """Parse the matrix mode and the offline self-test flag."""
    parser = argparse.ArgumentParser(description="Run the CocoaPods iOS plugin matrix")
    parser.add_argument("--mode", choices=("fetch", "build"), default="fetch")
    parser.add_argument("--self-test", action="store_true", dest="self_test")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    """Run the selected mode and return its exit status."""
    args = parse_args(sys.argv[1:] if argv is None else argv)
    if args.self_test:
        return self_test()
    expected = load_json(EXPECTED_PODS_PATH, "expected_pods.json")
    if args.mode == "fetch":
        return report(run_fetch(expected, run_bazel), "fetch")
    gated = load_json(BUILD_EXPECTED_PODS_PATH, "build_expected_pods.json", allow_empty=True)
    return report(run_build(expected, gated, run_bazel), "build")


if __name__ == "__main__":
    sys.exit(main())
