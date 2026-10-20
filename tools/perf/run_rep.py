#!/usr/bin/env python3
"""One bench repeat for the iOS perf workflow: builds, then replays.

Ordering is the point. Per repeat, with a fresh workspace copy and a fresh
output base, this driver runs all three scenario builds first (clean, then
the top-layer app edit, then the layer-0 core edit, keeping each scenario's
execution log), then makes the execroot's bazel-out user-writable (replays
re-run actions in place and must not fail on read-only outputs), then
summarizes and replays all three logs, then shuts the server down. No Bazel
build follows a replay in the same output base, so a replay can never
perturb the next incremental build's action cache.

Results land in <results-ref-dir>/<scenario>/rep<N>/{execlog.json,
replay.json}, the layout summarize.py reads.
"""

import argparse
import os
import stat
import subprocess
import sys

SCENARIOS = [
    ("clean", None),
    ("app_edit", "apply-app-edit"),
    ("core_edit", "apply-body-edit"),
]

DEFAULT_TARGET = "//app:app_ios"


def real_run(argv, cwd=None, capture_output=False):
    return subprocess.run(
        argv,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture_output else None,
        stderr=subprocess.STDOUT if capture_output else None,
        text=True,
        check=False,
    )


def bazel_build(run, work, out_base, target, log_path):
    proc = run(
        ["bazel", "--output_base=" + out_base, "build", target,
         "--execution_log_json_file=" + log_path,
         "--materialize_param_files"],
        cwd=work)
    if proc.returncode != 0:
        raise RuntimeError("bazel build %s failed (exit %s)"
                           % (target, proc.returncode))
    return proc


def apply_edit(run, tools_dir, work, edit_command):
    gen = os.path.join(tools_dir, "gen_monorepo.py")
    proc = run([sys.executable, gen, edit_command, "--workspace", work],
               cwd=work)
    if proc.returncode != 0:
        raise RuntimeError("%s failed (exit %s)"
                           % (edit_command, proc.returncode))
    return proc


def get_execroot(run, work, out_base):
    proc = run(["bazel", "--output_base=" + out_base, "info",
                "execution_root"], cwd=work, capture_output=True)
    if proc.returncode != 0:
        raise RuntimeError("bazel info execution_root failed (exit %s)"
                           % proc.returncode)
    return proc.stdout.strip()


def make_writable_tree(root):
    """Adds u+w (u+wx on dirs) under root; returns the changed count."""
    changed = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        for name in dirnames + filenames:
            path = os.path.join(dirpath, name)
            if os.path.islink(path):
                continue
            try:
                mode = os.stat(path).st_mode
                extra = stat.S_IWUSR
                if os.path.isdir(path) and not mode & stat.S_IXUSR:
                    extra |= stat.S_IXUSR
                if mode & extra != extra:
                    os.chmod(path, mode | extra)
                    changed += 1
            except OSError:
                continue
    return changed


def summarize_log(run, tools_dir, log_path, out_path):
    proc = run([sys.executable, os.path.join(tools_dir, "execlog.py"),
                "--log", log_path, "--out", out_path])
    if proc.returncode != 0:
        raise RuntimeError("execlog.py failed (exit %s)" % proc.returncode)
    return proc


def replay_log(run, tools_dir, log_path, execroot, out_path, timeout,
               budget_seconds):
    proc = run([sys.executable, os.path.join(tools_dir, "replay.py"),
                "--log", log_path, "--execroot", execroot,
                "--out", out_path, "--timeout", str(timeout),
                "--budget-seconds", str(budget_seconds)])
    if proc.returncode != 0:
        raise RuntimeError("replay.py failed (exit %s)" % proc.returncode)
    return proc


def shutdown(run, work, out_base):
    proc = run(["bazel", "--output_base=" + out_base, "shutdown"], cwd=work)
    if proc.returncode != 0:
        raise RuntimeError("bazel shutdown failed (exit %s)"
                           % proc.returncode)
    return proc


def run_rep(tools_dir, work, out_base, results_ref_dir, rep,
            target=DEFAULT_TARGET, replay_timeout=600.0,
            replay_budget=1800.0, run=None, chmod=None):
    """Runs one full repeat: three builds, chmod, three replay passes."""
    run = run or real_run
    chmod = chmod or make_writable_tree
    logs = {}
    for scenario, edit_command in SCENARIOS:
        if edit_command is not None:
            apply_edit(run, tools_dir, work, edit_command)
        log_path = os.path.join(work, "execlog-%s.json" % scenario)
        bazel_build(run, work, out_base, target, log_path)
        logs[scenario] = log_path
    execroot = get_execroot(run, work, out_base)
    bazel_out = os.path.join(execroot, "bazel-out")
    made_writable = chmod(bazel_out) if os.path.isdir(bazel_out) else 0
    for scenario, _ in SCENARIOS:
        rep_dir = os.path.join(results_ref_dir, scenario, "rep%d" % rep)
        os.makedirs(rep_dir, exist_ok=True)
        summarize_log(run, tools_dir, logs[scenario],
                      os.path.join(rep_dir, "execlog.json"))
        replay_log(run, tools_dir, logs[scenario], execroot,
                   os.path.join(rep_dir, "replay.json"),
                   replay_timeout, replay_budget)
    shutdown(run, work, out_base)
    return {"execroot": execroot, "logs": logs,
            "made_writable": made_writable}


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Run one iOS bench repeat (builds first, replays last).")
    parser.add_argument("--tools", required=True)
    parser.add_argument("--work", required=True)
    parser.add_argument("--out-base", required=True)
    parser.add_argument("--results-ref-dir", required=True)
    parser.add_argument("--rep", type=int, required=True)
    parser.add_argument("--target", default=DEFAULT_TARGET)
    parser.add_argument("--replay-timeout", type=float, default=600.0)
    parser.add_argument("--replay-budget", type=float, default=1800.0)
    args = parser.parse_args(argv)
    record = run_rep(args.tools, args.work, args.out_base,
                     args.results_ref_dir, args.rep, target=args.target,
                     replay_timeout=args.replay_timeout,
                     replay_budget=args.replay_budget)
    print("rep=%d execroot=%s made_writable=%d"
          % (args.rep, record["execroot"], record["made_writable"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
