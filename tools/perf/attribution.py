#!/usr/bin/env python3
"""Per-flow CPU attribution of the clean and cold flows.

Splits a flow's ``bazel`` CPU into fetch/extract, module resolution,
loading/analysis, host-tool builds (by mnemonic and by repository),
target actions, sandbox and a shown remainder, from the saved
``trace.json.gz`` (activity by category, see attribution_trace) and
``execlog.json.gz`` (userTime + systemTime of each spawn). No Bazel run
and no command lines. The remainder is total minus parts 1 to 6, never
clamped; ``ok`` holds while it is within 5% of the total.
"""

import gzip
import os
import tempfile

from attribution_trace import TRACE_PARTS
from attribution_trace import trace_part_seconds
from execlog import load_spawns
from execlog import parse_duration
from replay import builds_host_tool
from summarize import summarize_values

ATTRIBUTED_FLOWS = frozenset([
    "ios-debug-clean", "ios-debug-body", "android-debug-body",
    "android-release-noop"])
TOLERANCE = 0.05
TOP_N = 10
SIMPLE_PARTS = ("fetch_extract", "module_resolution", "loading_analysis",
                "target_actions", "sandbox")
_TRACE = "trace.json.gz"
_EXECLOG = "execlog.json.gz"


def repo_of(label):
    """Repository name of a target label ("_main" for the main repo)."""
    text = label if isinstance(label, str) else ""
    if not text.startswith("@"):
        return "_main"
    name = text.lstrip("@").split("//", 1)[0]
    return name or "_main"


def spawn_cpu(spawn):
    """user + system CPU seconds of one executed spawn."""
    if spawn.get("cacheHit"):
        return 0.0
    metrics = spawn.get("metrics") or {}
    return (parse_duration(metrics.get("userTime"))
            + parse_duration(metrics.get("systemTime")))


def spawn_costs(spawns):
    """{"target_actions", "host": {"total","by_mnemonic","by_repo"}}."""
    host = {"total": 0.0, "by_mnemonic": {}, "by_repo": {}}
    target = 0.0
    for spawn in spawns:
        cpu = spawn_cpu(spawn)
        if not builds_host_tool(spawn):
            target += cpu
            continue
        host["total"] += cpu
        mnemonic = spawn.get("mnemonic") or ""
        repo = repo_of(spawn.get("targetLabel"))
        for key, name in (("by_mnemonic", mnemonic), ("by_repo", repo)):
            host[key][name] = host[key].get(name, 0.0) + cpu
    return {"target_actions": target, "host": host}


def top_with_other(values, limit=TOP_N):
    """The `limit` largest entries plus an "other" sum of the rest."""
    ranked = sorted(values.items(), key=lambda item: (-item[1], item[0]))
    named = dict(ranked[:limit])
    named["other"] = sum(value for _, value in ranked[limit:])
    return named


def _gunzip_to(src, dst):
    with open(src, "rb") as fin:
        data = fin.read()
    with open(dst, "wb") as fout:
        fout.write(gzip.decompress(data))


def rep_parts(rep_dir):
    """One repeat's raw parts; raises OSError/ValueError if unreadable."""
    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "execlog.json")
        _gunzip_to(os.path.join(rep_dir, _EXECLOG), log)
        costs = spawn_costs(load_spawns(log))
    seconds = trace_part_seconds(os.path.join(rep_dir, _TRACE))
    parts = {name: seconds[name] for name in TRACE_PARTS}
    parts["target_actions"] = costs["target_actions"]
    parts["host"] = costs["host"]
    return parts


def missing_input(rep_dirs):
    """Message naming the first absent file, or None."""
    for rep_dir in rep_dirs:
        for name in (_TRACE, _EXECLOG):
            if not os.path.isfile(os.path.join(rep_dir, name)):
                return "missing %s in %s" % (name, rep_dir)
    return None


def _median_map(maps):
    keys = set()
    for entry in maps:
        keys.update(entry)
    return {key: summarize_values(
        [entry.get(key, 0.0) for entry in maps])["median"] for key in keys}


def median_parts(reps):
    """Per-key median over the repeats' raw parts."""
    out = {name: summarize_values([r[name] for r in reps])["median"]
           for name in SIMPLE_PARTS}
    hosts = [r["host"] for r in reps]
    out["host_tools"] = {
        "total": summarize_values([h["total"] for h in hosts])["median"],
        "by_mnemonic": top_with_other(
            _median_map([h["by_mnemonic"] for h in hosts])),
        "by_repo": top_with_other(
            _median_map([h["by_repo"] for h in hosts]))}
    return out


def build_attribution(parts, total):
    """The attribution record; unattributed = total - parts 1..6."""
    summed = sum(parts[name] for name in SIMPLE_PARTS)
    summed += parts["host_tools"]["total"]
    gap = total - summed
    record = dict(parts)
    record["unattributed"] = gap
    return {"ok": abs(gap) <= TOLERANCE * total, "gap_s": gap,
            "total_s": total, "parts": record}


def attribute_flow(rep_dirs, total):
    """Attribution of one flow from its rep directories and bazel total."""
    if not rep_dirs:
        return {"ok": False, "error": "no repeat directories"}
    if total is None:
        return {"ok": False, "error": "flow has no bazel total"}
    absent = missing_input(rep_dirs)
    if absent:
        return {"ok": False, "error": absent}
    try:
        reps = [rep_parts(rep_dir) for rep_dir in rep_dirs]
    except (OSError, ValueError) as exc:
        return {"ok": False, "error": "unreadable input: %s" % (exc,)}
    return build_attribution(median_parts(reps), total)


def strict_attribution_exit(summaries, strict):
    """Exit code: 1 only in strict mode when some attribution.ok is false."""
    if not strict:
        return 0
    failed = []
    for summary in summaries.values():
        for flow, entry in sorted(summary["flows"].items()):
            attribution = entry.get("attribution")
            if attribution is not None and not attribution["ok"]:
                failed.append(flow)
    for flow in failed:
        print("flow=%s attribution not ok" % flow)
    return 1 if failed else 0
