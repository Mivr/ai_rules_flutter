#!/usr/bin/env python3
"""Text checks for the manual Android/Web perf workflow.

The workflow runs on GitHub's free Linux runners, so the things that keep
it cheap and dispatchable are part of its contract: a manual-only trigger,
the exact dispatch inputs, no caches, a small artifact that is still
uploaded after a failed configuration, and a timeout under five hours.
These checks read `.github/workflows/perf-linux.yaml` as text; they never
run the workflow and never touch the network.
"""

import os
import re
import unittest

_KEY = re.compile(
    r"^(?:\"([^\"]+)\"|'([^']+)'|([A-Za-z0-9_.-]+)):(.*)$")
_ITEM = re.compile(r"^(\s*)-(?:\s+(.*))?$")

_STRING_INPUTS = ("head_ref", "target_loc", "seed", "repeats")
_EXPECTED_INPUTS = {
    "head_ref": {"type": "string", "required": "true",
                 "default": None, "options": []},
    "platform": {"type": "choice", "required": None,
                 "default": None, "options": ["android", "web"]},
    "target_loc": {"type": "string", "required": None,
                   "default": '"500000"', "options": []},
    "seed": {"type": "string", "required": None,
             "default": '"1"', "options": []},
    "repeats": {"type": "string", "required": None,
                "default": '"3"', "options": []},
    "lockfile": {"type": "choice", "required": None,
                 "default": "committed",
                 "options": ["none", "committed"]},
}
_CONFIGS = {
    "android": ("android_release", "android_debug"),
    "web": ("web_release", "web_debug"),
}


def workflow_path():
    """The perf-linux workflow beside this checkout's tools/perf."""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "..", ".github", "workflows",
                        "perf-linux.yaml")


def key_line(line):
    """(indent, key, rest) for one mapping line, or None."""
    text = line.strip()
    if not text or text.startswith("#"):
        return None
    match = _KEY.match(text)
    if match is None:
        return None
    key = next(group for group in match.groups()[:3] if group is not None)
    return len(line) - len(line.lstrip(" ")), key, match.group(4)


def keys_under(lines, start, parent_indent):
    """(index, indent, key, rest) for mapping lines below a parent key."""
    found = []
    for index in range(start + 1, len(lines)):
        line = lines[index]
        parsed = key_line(line)
        if parsed is not None:
            if parsed[0] <= parent_indent:
                break
            found.append((index,) + parsed)
            continue
        if not line.strip():
            continue
        if len(line) - len(line.lstrip(" ")) <= parent_indent:
            break
    return found


def direct_keys(lines, start, parent_indent):
    """Mapping entries at the first level below a parent key."""
    found = keys_under(lines, start, parent_indent)
    if not found:
        return []
    child_indent = min(entry[1] for entry in found)
    return [entry for entry in found if entry[1] == child_indent]


def child(lines, start, parent_indent, name):
    """The first direct child entry named name, or None."""
    for entry in direct_keys(lines, start, parent_indent):
        if entry[2] == name:
            return entry
    return None


def top_level(lines):
    """(index, indent, key, rest) for every top-level mapping line."""
    found = []
    for index, line in enumerate(lines):
        parsed = key_line(line)
        if parsed is not None and parsed[0] == 0:
            found.append((index,) + parsed)
    return found


def block_items(lines, start, parent_indent):
    """Virtual mapping lines for each `- ` item below a parent key."""
    items = []
    item_indent = None
    current = None
    for line in lines[start + 1:]:
        stripped = line.strip()
        if not stripped:
            if current is not None:
                current.append("")
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= parent_indent:
            break
        match = _ITEM.match(line)
        if match is not None:
            here = len(match.group(1))
            if item_indent is None or here < item_indent:
                item_indent = here
            if here == item_indent:
                if current is not None:
                    items.append(current)
                current = [" " * (here + 2) + (match.group(2) or "")]
                continue
        if current is not None:
            current.append(line)
    if current is not None:
        items.append(current)
    return items


def text_under(block, start, parent_indent):
    """The dedented block scalar that follows a `key: |` line."""
    body = []
    for line in block[start + 1:]:
        if not line.strip():
            body.append("")
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= parent_indent:
            break
        body.append(line)
    indents = [len(line) - len(line.lstrip(" "))
               for line in body if line.strip()]
    cut = min(indents) if indents else 0
    return "\n".join(line[cut:] if line.strip() else "" for line in body)


def mapping_entries(lines):
    """(index, indent, key, rest) for every mapping line in a block."""
    found = []
    for index, line in enumerate(lines):
        parsed = key_line(line)
        if parsed is not None:
            found.append((index,) + parsed)
    return found


def parse_step(block):
    """One workflow step as a dict, with `with:` fields nested."""
    entries = mapping_entries(block)
    if not entries:
        return {}
    base = min(entry[1] for entry in entries)
    step = {}
    with_entry = None
    for index, indent, key, rest in entries:
        if indent != base:
            continue
        value = rest.strip()
        if key == "with":
            with_entry = (index, indent)
        elif value in ("|", ">", "|-", ">-"):
            step[key] = text_under(block, index, indent)
        else:
            step[key] = value
    if with_entry is not None:
        step["with"] = parse_fields(block, with_entry[0],
                                    with_entry[1])
    return step


def parse_fields(lines, start, parent_indent):
    """Mapping fields at the first level below a parent key."""
    end = start + 1
    while end < len(lines):
        line = lines[end]
        if line.strip() and (len(line) - len(line.lstrip(" "))
                             <= parent_indent):
            break
        end += 1
    region = lines[start + 1:end]
    entries = [entry for entry in mapping_entries(region)
               if entry[1] > parent_indent]
    if not entries:
        return {}
    child_indent = min(entry[1] for entry in entries)
    return {key: rest.strip()
            for _, indent, key, rest in entries if indent == child_indent}


def steps(lines):
    """Every job step as a parsed dict."""
    jobs = None
    for entry in top_level(lines):
        if entry[2] == "jobs":
            jobs = entry
            break
    if jobs is None:
        return []
    bench = child(lines, jobs[0], jobs[1], "bench")
    if bench is None:
        return []
    steps_entry = child(lines, bench[0], bench[1], "steps")
    if steps_entry is None:
        return []
    return [parse_step(block)
            for block in block_items(lines, steps_entry[0], steps_entry[1])]


def inputs(lines):
    """The workflow_dispatch inputs as name -> fields."""
    dispatch = None
    for entry in top_level(lines):
        if entry[2] != "on" or entry[3].strip():
            continue
        for trigger in direct_keys(lines, entry[0], entry[1]):
            if trigger[2] == "workflow_dispatch":
                dispatch = trigger
                break
    if dispatch is None:
        return {}
    inputs_entry = child(lines, dispatch[0], dispatch[1], "inputs")
    if inputs_entry is None:
        return {}
    result = {}
    for index, indent, name, _ in direct_keys(lines, inputs_entry[0],
                                              inputs_entry[1]):
        result[name] = parse_fields(lines, index, indent)
    return result


class PerfLinuxWorkflowTest(unittest.TestCase):
    """The Linux bench stays manual, cheap and able to explain a failure."""

    @classmethod
    def setUpClass(cls):
        with open(workflow_path(), encoding="utf-8") as handle:
            cls.text = handle.read()
        cls.lines = cls.text.splitlines()

    def test_trigger_is_workflow_dispatch_only(self):
        on_entries = [entry for entry in top_level(self.lines)
                      if entry[2] == "on"]
        self.assertEqual(len(on_entries), 1)
        on_entry = on_entries[0]
        self.assertEqual(on_entry[3].strip(), "",
                         "on: must be a block, not an inline trigger")
        triggers = [entry[2] for entry in
                    direct_keys(self.lines, on_entry[0], on_entry[1])]
        self.assertEqual(triggers, ["workflow_dispatch"])
        self.assertNotIn("push", self.text)
        self.assertNotIn("pull_request", self.text)
        self.assertNotIn("schedule", self.text)
        self.assertNotIn("workflow_run", self.text)

    def test_dispatch_inputs_types_and_defaults(self):
        found = inputs(self.lines)
        self.assertEqual(sorted(found), sorted(_EXPECTED_INPUTS))
        for name, expected in _EXPECTED_INPUTS.items():
            with self.subTest(input=name):
                fields = found[name]
                if name == "head_ref":
                    self.assertEqual(fields.get("required"), "true")
                else:
                    self.assertNotIn("required", fields)
                if name in _STRING_INPUTS:
                    self.assertEqual(fields.get("type"), "string")
                else:
                    self.assertEqual(fields.get("type"), "choice")
                self.assertEqual(fields.get("default"), expected["default"])
                if expected["options"]:
                    self.assertEqual(options(fields), expected["options"])
                else:
                    self.assertNotIn("options", fields)

    def test_runner_timeout_and_no_cache(self):
        runs_on = [entry[3].strip() for entry in self.mapping_entries()
                   if entry[2] == "runs-on"]
        self.assertEqual(runs_on, ["ubuntu-latest"])
        timeouts = [int(entry[3].strip()) for entry in self.mapping_entries()
                    if entry[2] == "timeout-minutes"]
        self.assertTrue(timeouts)
        for timeout in timeouts:
            self.assertLessEqual(timeout, 300)
        self.assertNotIn("actions/cache", self.text)
        for entry in self.mapping_entries():
            if "cache" in entry[2].lower():
                self.fail("cache input %r must not be set" % entry[2])

    def test_upload_is_one_small_result_even_after_failure(self):
        uploads = [step for step in steps(self.lines)
                   if step.get("uses", "").startswith(
                       "actions/upload-artifact")]
        self.assertEqual(len(uploads), 1)
        upload = uploads[0]
        fields = upload["with"]
        self.assertEqual(fields.get("name"), "${{ inputs.platform }}-sol")
        self.assertEqual(fields.get("path"),
                         "${{ inputs.platform }}-sol.json")
        self.assertEqual(fields.get("retention-days"), "3")
        condition = upload.get("if", "")
        self.assertIn("!cancelled()", condition)
        self.assertNotIn("success()", condition)

    def test_measurement_runs_both_configurations_per_platform(self):
        measure = [step.get("run", "") for step in steps(self.lines)
                   if re.search(r"sol\.py[^\n]*\srun(?:\s|$)",
                                step.get("run", ""))]
        self.assertEqual(len(measure), 1)
        script = measure[0]
        for platform, (release, debug) in _CONFIGS.items():
            with self.subTest(platform=platform):
                pair = "--config %s --config %s" % (release, debug)
                self.assertIn(pair, script)

    def test_generates_head_and_summarizes_to_platform_file(self):
        scripts = [step.get("run", "") for step in steps(self.lines)
                   if step.get("run")]
        generate = [script for script in scripts
                    if "gen_monorepo.py" in script]
        self.assertEqual(len(generate), 1)
        self.assertIn("--rules-flutter", generate[0])
        self.assertIn("rules-head", generate[0])
        summarize = [script for script in scripts
                     if re.search(r"sol\.py[^\n]*\s+summarize\b", script)]
        self.assertEqual(len(summarize), 1)
        self.assertIn(
            '--out "$GITHUB_WORKSPACE/${{ inputs.platform }}-sol.json"',
            summarize[0])

    def mapping_entries(self):
        """Every mapping line in the workflow, nested ones included."""
        entries = []
        for index, line in enumerate(self.lines):
            parsed = key_line(line)
            if parsed is not None:
                entries.append((index,) + parsed)
        return entries


def options(fields):
    """The option list of one input, inline or block form."""
    value = fields.get("options", "")
    if value.startswith("[") and value.endswith("]"):
        inner = value[1:-1].strip()
        return [item.strip() for item in inner.split(",")] if inner else []
    return []


if __name__ == "__main__":
    unittest.main()
