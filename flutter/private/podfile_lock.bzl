"""CocoaPods `Podfile.lock` reader and validator for rules_flutter.

Reads the evaluated CocoaPods lockfile committed by Flutter iOS/macOS apps
to discover plugin native pod dependencies and versions without running Ruby.
"""

load(
    "//flutter/private:podfile_lock_scan.bzl",
    "count_indent",
    "has_flow_or_anchor",
    "has_indent_tab",
    "make_refusal",
    "parse_mapping_line",
    "parse_pods_dep",
    "parse_pods_entry",
    "unquote",
)

_ALLOWED_TOP_LEVEL = {
    "CHECKOUT OPTIONS": True,
    "COCOAPODS": True,
    "DEPENDENCIES": True,
    "EXTERNAL SOURCES": True,
    "PODFILE CHECKSUM": True,
    "PODS": True,
    "SPEC CHECKSUMS": True,
    "SPEC REPOS": True,
}

_CHECKOUT_KINDS = {
    "git": True,
    "hg": True,
    "http": True,
    "svn": True,
}

def _make_failure(error):
    """Build a failure struct with empty maps."""
    return struct(
        ok = False,
        error = error,
        pods = {},
        plugin_pods = {},
        spec_repos = {},
        checksums = {},
        checkout = {},
    )

def _handle_pods(state, stripped, indent, line_num, label):
    """Handle a line inside the PODS section."""
    if indent == 2:
        entry = parse_pods_entry(stripped)
        if not entry.ok:
            return make_refusal(
                label,
                line_num,
                '"{text}" is not a "<name> (<version>):" PODS entry'.format(text = stripped),
            )
        if entry.name in state.pods:
            return make_refusal(
                label,
                line_num,
                'PODS lists "{pod}" twice'.format(pod = entry.name),
            )
        state.pods[entry.name] = struct(version = entry.version, line = line_num)
        state.pod_deps[entry.name] = []
        state.current["pod"] = entry.name
        state.current["has_colon"] = entry.has_colon
        state.current["entry_line"] = line_num
        state.current["entry_text"] = stripped
        return ""

    if state.current["pod"] and not state.current["has_colon"]:
        return make_refusal(
            label,
            state.current["entry_line"],
            '"{text}" is not a "<name> (<version>):" PODS entry'.format(text = state.current["entry_text"]),
        )

    if indent == 4 and state.current["pod"]:
        dep = parse_pods_dep(stripped)
        if not dep.ok:
            return make_refusal(
                label,
                line_num,
                '"{text}" is not a "<name> (<requirement>)" PODS dependency'.format(text = stripped),
            )
        state.pod_deps[state.current["pod"]].append(
            struct(name = dep.name, requirement = dep.requirement),
        )
        return ""

    if not state.current["pod"] or stripped.endswith(":") or indent < 2:
        return make_refusal(
            label,
            line_num,
            '"{text}" is not a "<name> (<version>):" PODS entry'.format(text = stripped),
        )
    return make_refusal(
        label,
        line_num,
        '"{text}" is not a "<name> (<requirement>)" PODS dependency'.format(text = stripped),
    )

def _handle_spec_repos(state, stripped, indent):
    """Handle a line inside the SPEC REPOS section."""
    if indent == 2:
        kv = parse_mapping_line(stripped)
        state.current["repo"] = kv.key
    elif indent > 2:
        pod = stripped[2:].strip() if stripped.startswith("- ") else stripped
        pod = unquote(pod)
        repo = state.current["repo"]
        if repo and pod:
            state.spec_repos[pod] = repo

def _handle_external_sources(state, stripped, indent):
    """Handle a line inside the EXTERNAL SOURCES section."""
    if indent == 2:
        kv = parse_mapping_line(stripped)
        state.current["ext_pod"] = kv.key
    elif indent > 2:
        pod = state.current["ext_pod"]
        if not pod:
            return
        kv = parse_mapping_line(stripped)
        if kv.kind == "path":
            prefix = ".symlinks/plugins/"
            if kv.value.startswith(prefix):
                sub = kv.value[len(prefix):]
                parts = sub.split("/")
                if len(parts) == 2 and parts[1] in ("ios", "darwin", "macos") and len(parts[0]) > 0:
                    state.plugin_pods[pod] = parts[0]
        elif kv.kind in _CHECKOUT_KINDS:
            if pod not in state.checkout:
                state.checkout[pod] = kv.kind

def _handle_checkout_options(state, stripped, indent):
    """Handle a line inside the CHECKOUT OPTIONS section."""
    if indent == 2:
        kv = parse_mapping_line(stripped)
        state.current["checkout_pod"] = kv.key
    elif indent > 2:
        pod = state.current["checkout_pod"]
        if not pod:
            return
        kv = parse_mapping_line(stripped)
        if kv.kind in _CHECKOUT_KINDS:
            if pod not in state.checkout:
                state.checkout[pod] = kv.kind

def _handle_spec_checksums(state, stripped, indent):
    """Handle a line inside the SPEC CHECKSUMS section."""
    if indent == 2:
        kv = parse_mapping_line(stripped)
        if kv.key and kv.value:
            state.checksums[kv.key] = kv.value

def _handle_top_level(state, stripped, line_num, label):
    """Handle a top-level section header."""
    kv = parse_mapping_line(stripped)
    top_key = kv.key
    if top_key not in _ALLOWED_TOP_LEVEL:
        return make_refusal(
            label,
            line_num,
            '"{key}" is not a Podfile.lock top-level key rules_flutter reads'.format(key = top_key),
        )
    state.current["section"] = top_key
    state.current["pod"] = ""
    state.current["has_colon"] = False
    state.current["entry_line"] = 0
    state.current["entry_text"] = ""
    state.current["repo"] = ""
    state.current["ext_pod"] = ""
    state.current["checkout_pod"] = ""
    return ""

def _dispatch_section(state, stripped, indent, line_num, label):
    """Dispatch a content line to the active section handler."""
    section = state.current["section"]
    if section == "PODS":
        return _handle_pods(state, stripped, indent, line_num, label)
    if section == "SPEC REPOS":
        _handle_spec_repos(state, stripped, indent)
        return ""
    if section == "EXTERNAL SOURCES":
        _handle_external_sources(state, stripped, indent)
        return ""
    if section == "CHECKOUT OPTIONS":
        _handle_checkout_options(state, stripped, indent)
        return ""
    if section == "SPEC CHECKSUMS":
        _handle_spec_checksums(state, stripped, indent)
        return ""
    if section in ("DEPENDENCIES", "PODFILE CHECKSUM", "COCOAPODS"):
        return ""
    kv = parse_mapping_line(stripped)
    return make_refusal(
        label,
        line_num,
        '"{key}" is not a Podfile.lock top-level key rules_flutter reads'.format(key = kv.key),
    )

def _build_pods_map(state):
    """Convert state pods and deps into final structs."""
    pods = {}
    for name, entry in state.pods.items():
        pods[name] = struct(
            version = entry.version,
            deps = list(state.pod_deps.get(name, [])),
            line = entry.line,
        )
    return pods

def read_podfile_lock(text, label):
    """Parse CocoaPods `Podfile.lock` text into structured pod data.

    Args:
        text: The file content string.
        label: The file label string, for error reporting.

    Returns:
        `struct(ok, error, pods, plugin_pods, spec_repos, checksums, checkout)`:
        on success, `ok` is True and `error` is `""`. On failure, `ok` is False,
        `error` holds the refusal message, and all maps are empty.
    """
    lines = text.split("\n")
    state = struct(
        pods = {},
        pod_deps = {},
        plugin_pods = {},
        spec_repos = {},
        checksums = {},
        checkout = {},
        current = {
            "section": "",
            "pod": "",
            "has_colon": False,
            "entry_line": 0,
            "entry_text": "",
            "repo": "",
            "ext_pod": "",
            "checkout_pod": "",
        },
    )

    for line_idx in range(len(lines)):
        line_num = line_idx + 1
        raw_line = lines[line_idx]
        if raw_line.endswith("\r"):
            raw_line = raw_line[:-1]

        if has_indent_tab(raw_line):
            return _make_failure(make_refusal(
                label,
                line_num,
                "an indentation tab is not part of the Podfile.lock YAML subset rules_flutter reads",
            ))

        stripped = raw_line.strip()
        if not stripped:
            continue

        if has_flow_or_anchor(stripped):
            return _make_failure(make_refusal(
                label,
                line_num,
                "flow syntax and anchors are not part of the Podfile.lock YAML subset rules_flutter reads",
            ))

        indent = count_indent(raw_line)
        if indent == 0 and not (state.current["section"] == "PODS" and stripped.startswith("- ")):
            err = _handle_top_level(state, stripped, line_num, label)
            if err:
                return _make_failure(err)
            continue

        err = _dispatch_section(state, stripped, indent, line_num, label)
        if err:
            return _make_failure(err)

    return struct(
        ok = True,
        error = "",
        pods = _build_pods_map(state),
        plugin_pods = dict(state.plugin_pods),
        spec_repos = dict(state.spec_repos),
        checksums = dict(state.checksums),
        checkout = dict(state.checkout),
    )
