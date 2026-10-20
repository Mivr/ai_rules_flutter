#!/usr/bin/env python3
"""Replay iOS-only build actions under /usr/bin/time for the iOS perf bench.

For each executed spawn in a Bazel JSON execution log whose mnemonic is in
the iOS set, re-runs its command line under ``/usr/bin/time -l`` with the
logged environment overlaid, in the build's execroot (so the same inputs are
visible), and records "instructions retired" per action. macOS ``time -l``
reports that counter; other platforms leave it null.

Default iOS mnemonic set (gen_snapshot for iOS, assembler/clang and linker
steps, framework/bundle tools):

- Verified in this repo's ``flutter/`` rules: ``FlutterAotMacho``
  (gen_snapshot Mach-O for iOS), ``FlutterIOSNativeAssetFramework``,
  ``FlutterIOSRetagDylib``, ``FlutterIOSCopyAssets``,
  ``FlutterIOSStubDylib``, ``FlutterIOSDebugAssets``,
  ``FlutterStripEngine``, ``FlutterPlistMerge``,
  ``FlutterMachOVerifyProbe``.
- Apple/Clang toolchain steps (best effort; extend with ``--mnemonic`` after
  a dispatch reveals the executed-by-mnemonic table): ``CppCompile``,
  ``CppLink``, ``ObjcCompile``, ``ObjcLink``, ``SwiftCompile``, ``Lipo``.

Platform-agnostic kernel actions (``FlutterKernelCompile``,
``FlutterToolKernel``, ``FlutterAssetBundle``) are deliberately excluded:
the Linux referee bench already measures them, and replaying them would
blow the job time budget. They stay opt-in via ``--mnemonic``.

Only successful (exit 0), non-cached spawns are replayed. Each replay runs
with stdin closed and a per-action timeout, under a whole-log time budget
(``--budget-seconds``); on exhaustion the report records ``truncated=true``
plus the skipped count. The report always includes the
executed-but-not-replayed table and per-mnemonic failure counts so a broken
replay can never look like a cost drop.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from execlog import load_spawns  # noqa: E402

DEFAULT_IOS_MNEMONICS = frozenset([
    "FlutterAotMacho",
    "FlutterIOSNativeAssetFramework",
    "FlutterIOSRetagDylib",
    "FlutterIOSCopyAssets",
    "FlutterIOSStubDylib",
    "FlutterIOSDebugAssets",
    "FlutterStripEngine",
    "FlutterPlistMerge",
    "FlutterMachOVerifyProbe",
    "CppCompile",
    "CppLink",
    "ObjcCompile",
    "ObjcLink",
    "SwiftCompile",
    "Lipo",
])

TIME_BIN = "/usr/bin/time"

INSTRUCTIONS_RE = re.compile(r"^\s*([\d,]+)\s+instructions retired\s*$",
                             re.MULTILINE)
REAL_RE = re.compile(r"^\s*([\d.]+)\s+real\b", re.MULTILINE)


def parse_time_l_output(text):
    """Extracts instructions-retired and wall seconds from time -l output."""
    instructions = None
    match = INSTRUCTIONS_RE.search(text or "")
    if match:
        instructions = int(match.group(1).replace(",", ""))
    real_s = None
    match = REAL_RE.search(text or "")
    if match:
        real_s = float(match.group(1))
    return (instructions, real_s)


def select_spawns(spawns, mnemonics):
    """Splits spawns into (replayable, skipped) by mnemonic and status."""
    replayable = []
    skipped = {}
    for spawn in spawns:
        mnemonic = spawn.get("mnemonic", "")
        if mnemonic not in mnemonics:
            skipped[mnemonic] = skipped.get(mnemonic, 0) + 1
            continue
        if spawn.get("exitCode", 0) != 0:
            skipped["%s (exit %s)" % (mnemonic, spawn.get("exitCode"))] = \
                skipped.get("%s (exit %s)" % (mnemonic, spawn.get("exitCode")), 0) + 1
            continue
        if spawn.get("cacheHit"):
            skipped["%s (cached)" % mnemonic] = \
                skipped.get("%s (cached)" % mnemonic, 0) + 1
            continue
        if not spawn.get("commandArgs"):
            skipped["%s (no command)" % mnemonic] = \
                skipped.get("%s (no command)" % mnemonic, 0) + 1
            continue
        replayable.append(spawn)
    return (replayable, skipped)


def replay_env(spawn):
    """Logged environment overlay for a spawn ({name: value})."""
    env = {}
    for entry in spawn.get("environmentVariables") or []:
        if isinstance(entry, dict) and "name" in entry:
            env[entry["name"]] = entry.get("value", "")
    return env


def replay_argv(spawn):
    return [TIME_BIN, "-l"] + list(spawn["commandArgs"])


def run_replay(spawn, execroot, timeout):
    """Replays one spawn; returns its record dict."""
    env = dict(os.environ)
    env.update(replay_env(spawn))
    try:
        proc = subprocess.run(
            replay_argv(spawn),
            cwd=execroot,
            env=env,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
            text=True,
        )
    except subprocess.TimeoutExpired:
        return {
            "mnemonic": spawn.get("mnemonic", ""),
            "target": spawn.get("targetLabel", ""),
            "instructions": None,
            "real_s": None,
            "exit_code": "timeout",
            "command": spawn.get("commandArgs", []),
        }
    instructions, real_s = parse_time_l_output(proc.stderr)
    return {
        "mnemonic": spawn.get("mnemonic", ""),
        "target": spawn.get("targetLabel", ""),
        "instructions": instructions,
        "real_s": real_s,
        "exit_code": proc.returncode,
        "command": spawn.get("commandArgs", []),
    }


def is_failure(record):
    return record.get("exit_code") != 0


def aggregate_replays(records):
    by_mnemonic = {}
    for record in records:
        entry = by_mnemonic.setdefault(record["mnemonic"], {
            "count": 0,
            "failures": 0,
            "instructions_total": 0,
            "instructions_missing": 0,
            "real_s_total": 0.0,
        })
        entry["count"] += 1
        if is_failure(record):
            entry["failures"] += 1
        if record["instructions"] is None:
            entry["instructions_missing"] += 1
        else:
            entry["instructions_total"] += record["instructions"]
        if record["real_s"] is not None:
            entry["real_s_total"] += record["real_s"]
    return by_mnemonic


def replay_all(spawns, mnemonics, execroot, timeout, budget_seconds=None,
               runner=None, clock=None):
    """Selects and replays spawns under a whole-log time budget.

    Stops starting new replays once budget_seconds elapse; the report then
    carries truncated=true and the un-run actions land in
    skipped_by_mnemonic as "<mnemonic> (budget-exhausted)".
    """
    now = clock or time.monotonic
    replayable, skipped = select_spawns(spawns, mnemonics)
    skipped = dict(skipped)
    run = runner or (lambda spawn: run_replay(spawn, execroot, timeout))
    records = []
    truncated = False
    start = now()
    for spawn in replayable:
        if budget_seconds is not None and now() - start >= budget_seconds:
            truncated = True
            break
        records.append(run(spawn))
    if truncated:
        for spawn in replayable[len(records):]:
            key = "%s (budget-exhausted)" % spawn.get("mnemonic", "")
            skipped[key] = skipped.get(key, 0) + 1
    return {
        "n_replayed": len(records),
        "by_mnemonic": aggregate_replays(records),
        "skipped_by_mnemonic": skipped,
        "actions": records,
        "truncated": truncated,
        "budget_seconds": budget_seconds,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Replay iOS actions under /usr/bin/time -l.")
    parser.add_argument("--log", required=True, help="execution log path")
    parser.add_argument("--execroot", required=True,
                        help="build execroot to replay in")
    parser.add_argument("--out", required=True, help="replay JSON path")
    parser.add_argument("--mnemonic", action="append", default=[],
                        help="extra mnemonic to replay (repeatable)")
    parser.add_argument("--only-mnemonic", action="append", default=[],
                        help="replay only these mnemonics (repeatable)")
    parser.add_argument("--timeout", type=float, default=600.0,
                        help="per-action replay timeout in seconds")
    parser.add_argument("--budget-seconds", type=float, default=1800.0,
                        help="whole-log replay time budget in seconds")
    parser.add_argument("--dry-run", action="store_true",
                        help="print replay commands without running them")
    args = parser.parse_args(argv)
    mnemonics = set(args.only_mnemonic) if args.only_mnemonic \
        else set(DEFAULT_IOS_MNEMONICS) | set(args.mnemonic)
    spawns = load_spawns(args.log)
    if args.dry_run:
        replayable, skipped = select_spawns(spawns, mnemonics)
        for spawn in replayable:
            print("$ %s" % " ".join(replay_argv(spawn)))
        print("replayable=%d skipped=%s" % (len(replayable), skipped))
        return 0
    report = replay_all(spawns, mnemonics, args.execroot, args.timeout,
                        budget_seconds=args.budget_seconds)
    with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print("replayed=%d skipped=%s" % (report["n_replayed"],
                                      report["skipped_by_mnemonic"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
