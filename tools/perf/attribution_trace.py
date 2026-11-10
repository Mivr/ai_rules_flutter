#!/usr/bin/env python3
"""Thread-time per Bazel activity from a JSON trace profile.

Complete events (``ph`` ``"X"``, ``dur`` in microseconds) are classified
by category into the attribution parts that the profile shows directly:
repository fetch and extract, module resolution, loading and analysis,
sandbox setup and teardown. Within one thread, nested events never count
twice: each instant goes to the most specific part active there (sandbox,
then fetch, then module resolution, then loading and analysis).
"""

from traceprofile import read_trace_events

# Most specific first; an instant covered by several goes to the first.
TRACE_PARTS = ("sandbox", "fetch_extract", "module_resolution",
               "loading_analysis")

_CATEGORY_WORDS = (
    ("sandbox", ("sandbox",)),
    ("fetch_extract", ("fetch", "repository", "vendor")),
    ("module_resolution", ("module", "bzlmod")),
    ("loading_analysis", ("package creation", "analysis", "loading",
                          "configured target", "starlark", "skyframe",
                          "skyfunction")),
)


def classify_event(event):
    """Attribution part of a complete event, or None."""
    if event.get("ph") != "X":
        return None
    category = event.get("cat")
    if not isinstance(category, str):
        return None
    text = category.lower()
    for part, words in _CATEGORY_WORDS:
        if any(word in text for word in words):
            return part
    return None


def _interval(event):
    """(tid, start, end) in microseconds, or None for unusable events."""
    ts, dur = event.get("ts"), event.get("dur")
    for value in (ts, dur):
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None
    if dur <= 0:
        return None
    return (event.get("tid"), float(ts), float(ts) + float(dur))


def _thread_seconds(spans):
    """{part: seconds} for one thread's (start, end, part) spans."""
    points = []
    for start, end, part in spans:
        points.append((start, 1, part))
        points.append((end, -1, part))
    points.sort()
    active = dict.fromkeys(TRACE_PARTS, 0)
    totals = dict.fromkeys(TRACE_PARTS, 0.0)
    previous = None
    for ts, delta, part in points:
        if previous is not None and ts > previous:
            for name in TRACE_PARTS:
                if active[name] > 0:
                    totals[name] += (ts - previous) / 1e6
                    break
        active[part] += delta
        previous = ts
    return totals


def trace_part_seconds(path):
    """{part: thread seconds} of a trace profile (raises like the reader)."""
    by_thread = {}
    for event in read_trace_events(path):
        part = classify_event(event)
        span = _interval(event) if part else None
        if span is not None:
            by_thread.setdefault(span[0], []).append(
                (span[1], span[2], part))
    totals = dict.fromkeys(TRACE_PARTS, 0.0)
    for spans in by_thread.values():
        for part, seconds in _thread_seconds(spans).items():
            totals[part] += seconds
    return totals
