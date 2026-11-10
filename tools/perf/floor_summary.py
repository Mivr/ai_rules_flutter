"""Summary keys of the toolchain floor, beside the replay's ``sol``.

A flow carries ``toolchain_floor`` (median CPU seconds over the repeats,
the same unit and rounding as ``sol``), ``floor_identical``,
``floor_reason``, ``spread.toolchain_floor`` and
``bazel_over_toolchain_floor`` (bazel / toolchain_floor). Records without
floor keys (``--floor=off``, web flows, the base writer) add nothing, so
the file is the base's.
"""

from summarize import summarize_values


def has_floor(records):
    """True when any repeat carries floor fields."""
    return any("floor_identical" in record for record in records)


def summarize_floor(records, bazel_median):
    """(flow keys, spread entry) for the floor of one flow's repeats."""
    ok = all(record.get("floor_identical") for record in records)
    values = [record["toolchain_floor"]["cpu_s"] for record in records
              if record.get("toolchain_floor")
              and record["toolchain_floor"].get("cpu_s") is not None]
    stats = summarize_values(values) if ok else summarize_values([])
    reasons = []
    for record in records:
        reason = record.get("floor_reason", "floor missing")
        if not record.get("floor_identical") and reason not in reasons:
            reasons.append(reason)
    median = stats["median"]
    ratio = None
    if median and bazel_median is not None:
        ratio = bazel_median / median
    flow = {"toolchain_floor": median, "floor_identical": ok,
            "floor_reason": "ok" if ok else "; ".join(reasons),
            "bazel_over_toolchain_floor": ratio}
    return flow, [stats["min"], stats["max"]] if ok else None
