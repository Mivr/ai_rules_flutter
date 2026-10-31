"""CocoaPods native dependency resolution for rules_flutter.

Implements the 7-step CocoaPods resolution order for Apple plugin native
dependencies, hub-level precomputation into `ios_native_deps.json`, and spoke
resolution in CocoaPods mode with mixed-mode `Package.swift` fallback and
fail-closed refusals.
"""

load("//flutter/private:podfile_lock.bzl", "read_podfile_lock")
load("//flutter/private:swiftpm_resolved.bzl", "swiftpm_check_json")

def format_message_9(package, lock_label):
    """Format Message 9 when a plugin has iOS code but no lock entry and no Package.swift.

    Args:
        package: The Flutter plugin package name.
        lock_label: The string label of Podfile.lock.

    Returns:
        The formatted refusal error message string.
    """
    return (
        "Plugin {package} has iOS native code but no entry in {lock_label} " +
        "and no `Package.swift`. If it is used on iOS, run `pod install` in " +
        "the app's iOS directory to record it in `Podfile.lock`, or map its " +
        "native dependencies with `flutter.pub(ios_plugin_deps = ...)`. If " +
        "it is not used on iOS, remove it from pubspec.yaml."
    ).format(package = package, lock_label = lock_label)

def format_message_11(package, pod, version, lock_label, reason):
    """Format Message 11 when a CocoaPods pod dependency cannot be resolved.

    Args:
        package: The Flutter plugin package name.
        pod: The pod name.
        version: The locked version string, or "".
        lock_label: The string label of Podfile.lock.
        reason: Optional refusal reason, or "".

    Returns:
        The formatted refusal error message string.
    """
    version_clause = (" " + version) if version else ""
    reason_clause = (" " + reason) if reason else ""
    return (
        "Plugin {package} depends on CocoaPods pod {pod}{version_clause} " +
        "locked by {lock_label}, which has no Bazel target.{reason_clause} " +
        "Map it in `flutter.pub(ios_pod_deps = ...)` (with the Bazel target " +
        "that provides it) or add it to `flutter.pub(ios_pod_ignore = ...)` " +
        "if it needs no Bazel target."
    ).format(
        package = package,
        pod = pod,
        version_clause = version_clause,
        lock_label = lock_label,
        reason_clause = reason_clause,
    )

def resolve_binary_pod_stub(_pod, _root, _version):
    """Pure stub for binary pod resolution (filled in by POD-21).

    Args:
        _pod: The pod name.
        _root: The root pod name.
        _version: The locked version string.

    Returns:
        None.
    """
    return None

def resolve_swiftpm_pod_stub(_pod, _root, _version):
    """Pure stub for pod-to-SwiftPM table resolution (filled in by POD-18).

    Args:
        _pod: The pod name.
        _root: The root pod name.
        _version: The locked version string.

    Returns:
        None.
    """
    return None

def make_pod_resolution(
        kind,
        label = "",
        package = "",
        hub = "",
        pod = "",
        version = "",
        lock_label = "",
        reason = ""):
    """Create a pod resolution result struct.

    Args:
        kind: One of "skip", "label", "plugin", "drop", "unresolved".
        label: Resolved Bazel target label string, or "".
        package: Flutter plugin pub package name, or "".
        hub: Hub name, or "".
        pod: CocoaPods pod name, or "".
        version: Locked version string, or "".
        lock_label: Label string of the Podfile.lock, or "".
        reason: Refusal reason string, or "".

    Returns:
        A struct with the resolution fields.
    """
    return struct(
        kind = kind,
        label = label,
        package = package,
        hub = hub,
        pod = pod,
        version = version,
        lock_label = lock_label,
        reason = reason,
    )

def pod_resolution_to_dict(res):
    """Convert a pod resolution struct to a deterministic JSON dict.

    Args:
        res: The resolution struct from `make_pod_resolution`.

    Returns:
        A dict with sorted keys suitable for JSON encoding.
    """
    return {
        "hub": res.hub,
        "kind": res.kind,
        "label": res.label,
        "lock_label": res.lock_label,
        "package": res.package,
        "pod": res.pod,
        "reason": res.reason,
        "version": res.version,
    }

def _pod_resolution_from_dict(d):
    """Convert a JSON dict to a pod resolution struct.

    Args:
        d: The resolution dict.

    Returns:
        A struct with the resolution fields.
    """
    return struct(
        hub = d.get("hub", ""),
        kind = d.get("kind", ""),
        label = d.get("label", ""),
        lock_label = d.get("lock_label", ""),
        package = d.get("package", ""),
        pod = d.get("pod", ""),
        reason = d.get("reason", ""),
        version = d.get("version", ""),
    )

def _pod_version(pods_map, key):
    """Extract version string from pods_map for key.

    Args:
        pods_map: Map of pod names to entry structs or dicts.
        key: Pod name string.

    Returns:
        Version string or "".
    """
    entry = pods_map.get(key)
    if entry == None:
        return ""
    if hasattr(entry, "version"):
        return entry.version
    if type(entry) == "dict":
        return entry.get("version", "")
    return ""

def resolve_pod(
        pod,
        hub_name,
        all_package_names,
        podfile,
        lock_label,
        ios_pod_deps,
        ios_pod_ignore,
        platform = ""):
    """Resolve one CocoaPods pod according to the 7-step resolution order.

    1. Engine pods (Flutter, FlutterMacOS) -> skip.
    2. ios_pod_deps: exact pod key wins over root key.
    3. Flutter plugin pod: root in plugin_pods and pkg in all_package_names.
    4. ios_pod_ignore: pod or root in ios_pod_ignore -> drop.
    5. Binary pod stub (POD-21) -> None.
    6. Pod-to-SwiftPM table stub (POD-18) -> None.
    7. Refusal: unresolved pod at locked version.

    Args:
        pod: Pod name (e.g. "Firebase/Auth" or "path_provider_foundation").
        hub_name: The flutter.pub hub name.
        all_package_names: List or dict of packages in pubspec.lock.
        podfile: Parsed Podfile.lock struct or None.
        lock_label: String label of the Podfile.lock.
        ios_pod_deps: Dict mapping pod name to canonical Bazel label string.
        ios_pod_ignore: List or dict of pod names to drop.
        platform: Optional platform string ("ios" or "macos").

    Returns:
        A pod resolution struct created with make_pod_resolution.
    """
    root = pod.partition("/")[0]

    # Step 1: Engine pods
    if pod in ("Flutter", "FlutterMacOS") or root in ("Flutter", "FlutterMacOS"):
        return make_pod_resolution(kind = "skip", pod = pod)

    # Step 2: ios_pod_deps
    if pod in ios_pod_deps:
        return make_pod_resolution(kind = "label", label = ios_pod_deps[pod], pod = pod)
    if root in ios_pod_deps:
        return make_pod_resolution(kind = "label", label = ios_pod_deps[root], pod = pod)

    # Step 3: Flutter plugin pod
    plugin_pods = {}
    pods_map = {}
    if podfile != None:
        if hasattr(podfile, "plugin_pods"):
            plugin_pods = podfile.plugin_pods
        elif type(podfile) == "dict":
            plugin_pods = podfile.get("plugin_pods", {})
        if hasattr(podfile, "pods"):
            pods_map = podfile.pods
        elif type(podfile) == "dict":
            pods_map = podfile.get("pods", {})

    pkg = plugin_pods.get(root)
    pkg_in_pubspec = (pkg in all_package_names) if pkg else False
    if pkg and pkg_in_pubspec:
        plugin_label = (
            "@{hub}__{pkg}//:{pkg}_apple_{plat}".format(hub = hub_name, pkg = pkg, plat = platform)
        ) if platform else ""
        return make_pod_resolution(
            kind = "plugin",
            label = plugin_label,
            package = pkg,
            hub = hub_name,
            pod = pod,
        )

    # Step 4: ios_pod_ignore
    ignore_set = {p: True for p in ios_pod_ignore} if type(ios_pod_ignore) == "list" else ios_pod_ignore
    if pod in ignore_set or root in ignore_set:
        return make_pod_resolution(kind = "drop", pod = pod)

    # Version lookup for steps 5-7
    version = _pod_version(pods_map, pod)
    if not version:
        version = _pod_version(pods_map, root)

    # Step 5: Binary-pod stub
    binary_res = resolve_binary_pod_stub(pod, root, version)
    if binary_res != None:
        return binary_res

    # Step 6: Pod-to-SwiftPM table stub
    swiftpm_res = resolve_swiftpm_pod_stub(pod, root, version)
    if swiftpm_res != None:
        return swiftpm_res

    # Step 7: Refusal
    return make_pod_resolution(
        kind = "unresolved",
        pod = pod,
        version = version,
        lock_label = lock_label,
        reason = "",
    )

def precompute_hub_apple_pods(
        hub_name,
        all_package_names,
        podfile,
        lock_label,
        ios_pod_deps,
        ios_pod_ignore):
    """Precompute CocoaPods resolutions for all pods named in Podfile.lock.

    Resolves every pod in podfile.pods (keys and dep.name entries).
    Unresolvable pods are recorded as unresolved entries without failing.

    Args:
        hub_name: The flutter.pub hub name.
        all_package_names: List or dict of packages in pubspec.lock.
        podfile: Parsed Podfile.lock struct or None.
        lock_label: String label of the Podfile.lock.
        ios_pod_deps: Dict mapping pod name to canonical Bazel label string.
        ios_pod_ignore: List of pod names to drop.

    Returns:
        Dict mapping pod name to deterministic resolution dict for JSON.
    """
    if not podfile:
        return {}
    pods_map = podfile.pods if hasattr(podfile, "pods") else podfile.get("pods", {})

    all_pods = {}
    for name, entry in pods_map.items():
        all_pods[name] = True
        deps = entry.deps if hasattr(entry, "deps") else entry.get("deps", [])
        for dep in deps:
            dep_name = dep.name if hasattr(dep, "name") else dep.get("name", "")
            if dep_name:
                all_pods[dep_name] = True

    resolved = {}
    for pod in sorted(all_pods.keys()):
        res = resolve_pod(
            pod = pod,
            hub_name = hub_name,
            all_package_names = all_package_names,
            podfile = podfile,
            lock_label = lock_label,
            ios_pod_deps = ios_pod_deps,
            ios_pod_ignore = ios_pod_ignore,
            platform = "",
        )
        resolved[pod] = pod_resolution_to_dict(res)
    return resolved

def _validate_pod_deps(data, label, hub_name):
    """Validate and return the ios_pod_deps map.

    Args:
        data: The decoded JSON dict.
        label: The file label string.
        hub_name: The hub name string.

    Returns:
        struct(ok, error, pod_deps).
    """
    ios_pod_deps = data.get("ios_pod_deps", None)
    if type(ios_pod_deps) != "dict":
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {label} has no `ios_pod_deps` object.".format(
                hub = repr(hub_name),
                label = label,
            ),
            pod_deps = {},
        )
    for k in ios_pod_deps:
        if type(k) != "string" or type(ios_pod_deps[k]) != "string":
            return struct(
                ok = False,
                error = "flutter.pub hub {hub}: {label} maps a non-string key to a non-string label in `ios_pod_deps`.".format(
                    hub = repr(hub_name),
                    label = label,
                ),
                pod_deps = {},
            )
    return struct(ok = True, error = "", pod_deps = ios_pod_deps)

def _validate_pod_ignore(data, label, hub_name):
    """Validate and return the ios_pod_ignore list.

    Args:
        data: The decoded JSON dict.
        label: The file label string.
        hub_name: The hub name string.

    Returns:
        struct(ok, error, pod_ignore).
    """
    ios_pod_ignore = data.get("ios_pod_ignore", None)
    if type(ios_pod_ignore) != "list":
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {label} has no `ios_pod_ignore` list.".format(
                hub = repr(hub_name),
                label = label,
            ),
            pod_ignore = [],
        )
    for item in ios_pod_ignore:
        if type(item) != "string":
            return struct(
                ok = False,
                error = "flutter.pub hub {hub}: {label} contains a non-string element in `ios_pod_ignore`.".format(
                    hub = repr(hub_name),
                    label = label,
                ),
                pod_ignore = [],
            )
    return struct(ok = True, error = "", pod_ignore = ios_pod_ignore)

def _parse_ios_pods(data, label, hub_name):
    """Validate and parse the ios_pods dictionary.

    Args:
        data: The decoded JSON dict.
        label: The file label string.
        hub_name: The hub name string.

    Returns:
        struct(ok, error, ios_pods).
    """
    ios_pods_raw = data.get("ios_pods", None)
    if type(ios_pods_raw) != "dict":
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {label} has no `ios_pods` object.".format(
                hub = repr(hub_name),
                label = label,
            ),
            ios_pods = {},
        )
    ios_pods = {}
    for pod_name in ios_pods_raw:
        if type(pod_name) != "string" or type(ios_pods_raw[pod_name]) != "dict":
            return struct(
                ok = False,
                error = "flutter.pub hub {hub}: {label} contains an invalid entry in `ios_pods`.".format(
                    hub = repr(hub_name),
                    label = label,
                ),
                ios_pods = {},
            )
        ios_pods[pod_name] = _pod_resolution_from_dict(ios_pods_raw[pod_name])
    return struct(ok = True, error = "", ios_pods = ios_pods)

def read_ios_pod_native_deps(content, label, hub_name):
    """Read a hub's `ios_native_deps.json` CocoaPods entries.

    Validates that the file contains version 1 and valid `ios_pod_deps`,
    `ios_pod_ignore`, and `ios_pods` structures.

    Args:
        content: The file text.
        label: The file label string, for error reporting.
        hub_name: The flutter.pub hub name, for error reporting.

    Returns:
        `struct(ok, error, ios_pods, ios_pod_deps, ios_pod_ignore)`.
    """
    bad = swiftpm_check_json(content, label)
    if bad:
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {bad}".format(hub = repr(hub_name), bad = bad),
            ios_pods = {},
            ios_pod_deps = {},
            ios_pod_ignore = [],
        )
    data = json.decode(content)
    if type(data) != "dict":
        return struct(
            ok = False,
            error = "flutter.pub hub {hub}: {label} must hold a JSON object.".format(
                hub = repr(hub_name),
                label = label,
            ),
            ios_pods = {},
            ios_pod_deps = {},
            ios_pod_ignore = [],
        )
    if data.get("version", 0) != 1:
        return struct(
            ok = False,
            error = (
                "flutter.pub hub {hub}: {label} has an unsupported version " +
                "({version}): only version 1 parses."
            ).format(hub = repr(hub_name), label = label, version = repr(data.get("version", 0))),
            ios_pods = {},
            ios_pod_deps = {},
            ios_pod_ignore = [],
        )
    pod_deps_res = _validate_pod_deps(data, label, hub_name)
    if not pod_deps_res.ok:
        return struct(
            ok = False,
            error = pod_deps_res.error,
            ios_pods = {},
            ios_pod_deps = {},
            ios_pod_ignore = [],
        )
    pod_ignore_res = _validate_pod_ignore(data, label, hub_name)
    if not pod_ignore_res.ok:
        return struct(
            ok = False,
            error = pod_ignore_res.error,
            ios_pods = {},
            ios_pod_deps = {},
            ios_pod_ignore = [],
        )
    pods_res = _parse_ios_pods(data, label, hub_name)
    if not pods_res.ok:
        return struct(
            ok = False,
            error = pods_res.error,
            ios_pods = {},
            ios_pod_deps = {},
            ios_pod_ignore = [],
        )
    return struct(
        ok = True,
        error = "",
        ios_pods = pods_res.ios_pods,
        ios_pod_deps = pod_deps_res.pod_deps,
        ios_pod_ignore = pod_ignore_res.pod_ignore,
    )

def _collect_matching_lock_entries(podfile, package_name):
    """Find all PODS entries belonging to package_name, sorted by line number.

    Args:
        podfile: The parsed podfile struct.
        package_name: Flutter plugin package name.

    Returns:
        List of pod entries sorted by entry.line.
    """
    matched = []
    for pod_name, entry in podfile.pods.items():
        root = pod_name.partition("/")[0]
        if podfile.plugin_pods.get(root) == package_name:
            matched.append((entry.line, pod_name, entry))
    return [item[2] for item in sorted(matched)]

def _filter_kept_deps(matching_entries, podfile, package_name):
    """Collect kept dependencies in lock order, skipping engine and self edges.

    Args:
        matching_entries: List of matching pod entries.
        podfile: The parsed podfile struct.
        package_name: Flutter plugin package name.

    Returns:
        List of pod dependency names.
    """
    kept = []
    for entry in matching_entries:
        for dep in entry.deps:
            dep_name = dep.name
            dep_root = dep_name.partition("/")[0]
            if dep_name in ("Flutter", "FlutterMacOS") or dep_root in ("Flutter", "FlutterMacOS"):
                continue
            if podfile.plugin_pods.get(dep_root) == package_name:
                continue
            kept.append(dep_name)
    return kept

def _resolve_spoke_deps_for_platform(
        kept_deps,
        platform,
        hub_data,
        package_name,
        lock_label,
        fail_fn):
    """Resolve kept dependencies for one platform through precomputed hub data.

    Args:
        kept_deps: List of pod names.
        platform: Platform string ("ios" or "macos").
        hub_data: Hub data struct from read_ios_pod_native_deps.
        package_name: Flutter plugin package name.
        lock_label: String label of Podfile.lock.
        fail_fn: Failure function to call on unresolved pod.

    Returns:
        List of deduplicated target labels preserving first-seen order.
    """
    seen = {}
    labels = []
    for dep in kept_deps:
        pod_res = hub_data.ios_pods.get(dep)
        if pod_res == None:
            fail_fn(format_message_11(package_name, dep, "", lock_label, ""))
            return labels
        if pod_res.kind in ("skip", "drop"):
            continue
        if pod_res.kind == "label":
            target = pod_res.label
            if target not in seen:
                seen[target] = True
                labels.append(target)
        elif pod_res.kind == "plugin":
            target = "@{hub}__{pkg}//:{pkg}_apple_{plat}".format(
                hub = pod_res.hub,
                pkg = pod_res.package,
                plat = platform,
            )
            if target not in seen:
                seen[target] = True
                labels.append(target)
        elif pod_res.kind == "unresolved":
            fail_fn(format_message_11(
                package_name,
                dep,
                pod_res.version,
                lock_label,
                pod_res.reason,
            ))
            return labels
    return labels

def _resolve_spoke_from_lock(
        ctx,
        matching_entries,
        podfile,
        package_name,
        lock_label,
        apple,
        fail_fn):
    """Resolve Apple dependencies from matching Podfile.lock entries.

    Args:
        ctx: Spoke repository context.
        matching_entries: List of matching pod entries.
        podfile: The parsed podfile struct.
        package_name: Flutter plugin package name.
        lock_label: String label of Podfile.lock.
        apple: Struct with macos_srcs and ios_srcs.
        fail_fn: Function to invoke on error.

    Returns:
        `struct(macos, ios)`.
    """
    kept_deps = _filter_kept_deps(matching_entries, podfile, package_name)
    if not kept_deps:
        return struct(macos = [], ios = [])

    native_deps_label = ctx.attr.ios_native_deps
    hub_name = ctx.attr.hub_name
    native_content = ctx.read(native_deps_label)
    hub_data = read_ios_pod_native_deps(native_content, str(native_deps_label), hub_name)
    if not hub_data.ok:
        fail_fn(hub_data.error)
        return struct(macos = [], ios = [])

    macos_labels = []
    if apple.macos_srcs:
        macos_labels = _resolve_spoke_deps_for_platform(
            kept_deps,
            "macos",
            hub_data,
            package_name,
            lock_label,
            fail_fn,
        )

    ios_labels = []
    if apple.ios_srcs:
        ios_labels = _resolve_spoke_deps_for_platform(
            kept_deps,
            "ios",
            hub_data,
            package_name,
            lock_label,
            fail_fn,
        )

    return struct(macos = macos_labels, ios = ios_labels)

def _mixed_mode_swiftpm_fallback(
        ctx,
        package_name,
        apple,
        detect_swiftpm_platform,
        manifest_presence):
    """Run SwiftPM fallback for platforms that ship a Package.swift.

    Args:
        ctx: Spoke repository context.
        package_name: Pub plugin package name.
        apple: Struct with macos_srcs and ios_srcs.
        detect_swiftpm_platform: Fallback function for mixed-mode SwiftPM.
        manifest_presence: Struct with ios, darwin, macos booleans.

    Returns:
        `struct(macos, ios)`.
    """
    resolved_label = ctx.attr.package_resolved
    checksums_label = ctx.attr.package_sha256
    native_deps_label = ctx.attr.ios_native_deps
    hub_name = ctx.attr.hub_name

    macos_labels = []
    if apple.macos_srcs and (manifest_presence.macos or manifest_presence.darwin):
        macos_labels = detect_swiftpm_platform(
            ctx,
            package_name,
            "macos",
            apple.macos_srcs,
            resolved_label,
            checksums_label,
            native_deps_label,
            hub_name,
        )

    ios_labels = []
    if apple.ios_srcs and (manifest_presence.ios or manifest_presence.darwin):
        ios_labels = detect_swiftpm_platform(
            ctx,
            package_name,
            "ios",
            apple.ios_srcs,
            resolved_label,
            checksums_label,
            native_deps_label,
            hub_name,
        )

    return struct(macos = macos_labels, ios = ios_labels)

def detect_apple_cocoapods_deps(
        ctx,
        package_name,
        apple,
        detect_swiftpm_platform,
        fail_fn = fail):
    """Resolve Apple dependencies in CocoaPods mode.

    Args:
        ctx: Spoke repository context.
        package_name: Pub plugin package name.
        apple: Struct with macos_srcs and ios_srcs.
        detect_swiftpm_platform: Fallback function for mixed-mode SwiftPM.
        fail_fn: Function to invoke on error, defaults to `fail`.

    Returns:
        `struct(macos, ios)` with resolved target label lists.
    """
    if not apple.macos_srcs and not apple.ios_srcs:
        return struct(macos = [], ios = [])

    lock_label = str(ctx.attr.podfile_lock)
    lock_content = ctx.read(ctx.attr.podfile_lock)
    podfile = read_podfile_lock(lock_content, lock_label)
    if not podfile.ok:
        fail_fn(podfile.error)
        return struct(macos = [], ios = [])

    matching_entries = _collect_matching_lock_entries(podfile, package_name)
    if matching_entries:
        return _resolve_spoke_from_lock(
            ctx,
            matching_entries,
            podfile,
            package_name,
            lock_label,
            apple,
            fail_fn,
        )

    # No matching lock entry: check for pure-CocoaPods refusal or mixed-mode fallback.
    manifest_presence = struct(
        ios = ctx.path("ios/" + package_name + "/Package.swift").exists,
        darwin = ctx.path("darwin/" + package_name + "/Package.swift").exists,
        macos = ctx.path("macos/" + package_name + "/Package.swift").exists,
    )

    if apple.ios_srcs and not manifest_presence.ios and not manifest_presence.darwin:
        fail_fn(format_message_9(package_name, lock_label))
        return struct(macos = [], ios = [])

    return _mixed_mode_swiftpm_fallback(
        ctx,
        package_name,
        apple,
        detect_swiftpm_platform,
        manifest_presence,
    )
