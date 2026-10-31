"""Helper functions for flutter.pub package and spoke generation.

Extracted helpers for pubspec identity validation, asset condition merging,
and unsupported native build stubs.
"""

load(
    "//flutter/private:flutter_pub_semver.bzl",
    "parse_pub_version",
    "pub_version_text",
)
load(
    "//flutter/private:flutter_pubspec.bzl",
    "asset_flavor_error",
    "parse_pubspec",
)
load("//flutter/private:starlark_literal.bzl", "starlark_string_literal")

def make_android_native_build_unsupported_content(package_name, version):
    """Generate an `android/BUILD.bazel` that fails at load time.

    Emitted for plugins whose Gradle build compiles native code for Android
    (externalNativeBuild) when no overlay provides a Bazel translation.
    Android builds load this file through the hub's
    `android/all_android_plugin_libs` aggregator and fail with a clear
    message; non-Android platforms never load it and are unaffected.

    Args:
        package_name: Name of the plugin package.
        version: Package version string.

    Returns:
        Content string failing with an informative message.
    """
    message = (
        "package:{pkg} {version} compiles native code for Android via " +
        "Gradle's externalNativeBuild, which rules_flutter cannot " +
        "translate automatically. An APK built without that library would " +
        "crash at plugin registration, so this is a hard error. Provide a " +
        "plugin overlay for {pkg} (flutter.plugin_overlays in MODULE.bazel) " +
        "that compiles the package's native sources with cc_shared_library " +
        "and ships them through flutter_plugin.native_deps — see " +
        "@rules_flutter//ext/jni for the canonical example."
    ).format(pkg = package_name, version = version)

    return "fail(" + starlark_string_literal(message) + ")\n"

def sorted_flavor_set(flavors):
    """The deduplicated, sorted flavor names, for order-insensitive comparison.

    Args:
        flavors: Iterable of flavor name strings.

    Returns:
        Sorted list of unique flavor strings.
    """
    seen = {}
    for flavor in flavors:
        seen[flavor] = True
    return sorted(seen.keys())

def merge_pub_asset_conditions(expanded, package_name):
    """Merge per-file `flutter.assets` entries the way flutter_tools does.

    flutter_tools keeps one entry per declaration and bundles a file when ANY
    of its entries survives filtering, so every entry for one file merges:
    any entry without `platforms` makes the file unconditional, otherwise the
    file's platforms are the union of its entries' lists. Entries for one
    file whose flavor sets differ conflict (compared as sets, so order does
    not matter); the caller fails the fetch with the returned message.

    Args:
        expanded: Per-file entries from
            `expand_pub_asset_entries(...).expanded`.
        package_name: The pub package the entries come from, for the conflict
            message.

    Returns:
        A `struct(platforms, flavors, conflict)`: the merged condition dicts
        and the fetch failure naming the package, the file and both flavor
        lists, or `""` when the entries agree.
    """
    by_path = {}
    order = []
    for entry in expanded:
        key = ":" + entry.path
        if key not in by_path:
            by_path[key] = []
            order.append(key)
        by_path[key].append(entry)
    platforms = {}
    flavors = {}
    for key in order:
        entries = by_path[key]
        first = entries[0]
        for other in entries[1:]:
            if sorted_flavor_set(other.flavors) != sorted_flavor_set(first.flavors):
                return struct(
                    platforms = {},
                    flavors = {},
                    conflict = asset_flavor_error(
                        package_name,
                        first.path,
                        first.flavors,
                        other.flavors,
                    ),
                )
        if first.flavors:
            flavors[key] = list(first.flavors)
        union = {}
        unconditional = False
        for entry in entries:
            if not entry.platforms:
                unconditional = True
                break
            for platform in entry.platforms:
                union[platform] = True
        if unconditional:
            continue
        if len(entries) == 1:
            platforms[key] = list(first.platforms)
        else:
            platforms[key] = sorted(union.keys())
    return struct(platforms = platforms, flavors = flavors, conflict = "")

def build_pkg_asset_conditions(expanded, package_name):
    """Build the `pkg_asset_platforms` / `pkg_asset_flavors` dicts.

    Same keys as `pkg_assets` (`":" + path`), but only for entries that
    actually restrict: unconditional files stay out of both dicts, so the
    emitted attrs stay empty for packages without conditions. Entries for
    one file merge (see `merge_pub_asset_conditions`); conflicting flavors
    fail the spoke fetch.

    Args:
        expanded: Per-file entries from
            `expand_pub_asset_entries(...).expanded`.
        package_name: The pub package the entries come from.

    Returns:
        A `(platforms, flavors)` tuple of dicts.
    """
    merged = merge_pub_asset_conditions(expanded, package_name)
    if merged.conflict:
        fail(merged.conflict)
    return (merged.platforms, merged.flavors)

def format_label_dict_literal(d, indent = "        "):
    """Render `{":foo": "foo", ":bar": "bar"}` as a multi-line BUILD source dict.

    Args:
        d: Dict of label to target path mappings.
        indent: Indentation string for each line.

    Returns:
        Formatted multi-line dictionary string.
    """
    if not d:
        return "{}"
    keys = sorted(d.keys())
    lines = [
        "{indent}{k}: {v},".format(
            indent = indent,
            k = starlark_string_literal(k),
            v = starlark_string_literal(d[k]),
        )
        for k in keys
    ]
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

def format_string_list_dict_literal(d, indent = "        "):
    """Render `{":foo": ["a", "b"]}` as a multi-line BUILD source dict.

    Args:
        d: Dict of label to list of string values.
        indent: Indentation string for each line.

    Returns:
        Formatted multi-line dictionary string.
    """
    if not d:
        return "{}"
    lines = []
    for k in sorted(d.keys()):
        values = ", ".join([starlark_string_literal(v) for v in d[k]])
        lines.append(
            "{indent}{k}: [{values}],".format(
                indent = indent,
                k = starlark_string_literal(k),
                values = values,
            ),
        )
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

def format_pub_asset_attrs(
        fonts_json_str,
        font_files,
        pkg_assets,
        pkg_shaders,
        pkg_asset_platforms = {},
        pkg_asset_flavors = {}):
    """Render the pub-asset attrs as BUILD source, omitting empty ones.

    Args:
        fonts_json_str: JSON-encoded font definitions.
        font_files: Font file label map.
        pkg_assets: Package asset label map.
        pkg_shaders: Package shader label map.
        pkg_asset_platforms: Platform restriction map.
        pkg_asset_flavors: Flavor restriction map.

    Returns:
        Rendered attribute lines string.
    """
    parts = []
    if fonts_json_str:
        parts.append("    fonts_json = " + starlark_string_literal(fonts_json_str) + ",")
    if font_files:
        parts.append("    font_files = {},".format(format_label_dict_literal(font_files)))
    if pkg_assets:
        parts.append("    pkg_assets = {},".format(format_label_dict_literal(pkg_assets)))
    if pkg_asset_platforms:
        parts.append("    pkg_asset_platforms = {},".format(
            format_string_list_dict_literal(pkg_asset_platforms),
        ))
    if pkg_asset_flavors:
        parts.append("    pkg_asset_flavors = {},".format(
            format_string_list_dict_literal(pkg_asset_flavors),
        ))
    if pkg_shaders:
        parts.append("    pkg_shaders = {},".format(format_label_dict_literal(pkg_shaders)))
    return "\n".join(parts) + ("\n" if parts else "")

def parse_pubspec_identity(content):
    """The `(name, version)` identity a path spoke verifies against its lock entry.

    A path package's overlays and curated code assets are selected by the
    lock key and the lock's version, so the spoke must check that the
    package's own pubspec.yaml agrees.

    Args:
        content: Full pubspec.yaml content as a string.

    Returns:
        A `struct(name, version)` of strings.
    """
    pubspec = parse_pubspec(content)
    name = pubspec.get("name", "")
    version = pub_version_text(pubspec.get("version", ""))
    return struct(
        name = "" if name == None else str(name),
        version = "0.0.0" if version == "" else version,
    )

def missing_pubspec_refusal(hub_name, package_name):
    """The fetch refusal for a path package with no readable pubspec name.

    Args:
        hub_name: The name of the pub hub.
        package_name: The expected package name.

    Returns:
        The error message string.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" has no readable pubspec.yaml naming the " +
        "package. Overlays and code assets are selected by lock name; " +
        "re-resolve the lock so the package carries a pubspec that " +
        "agrees with it."
    )

def pubspec_name_refusal(hub_name, package_name, actual):
    """The fetch refusal for a path package whose pubspec names another package.

    Args:
        hub_name: The name of the pub hub.
        package_name: The expected package name.
        actual: The actual package name found in pubspec.yaml.

    Returns:
        The error message string.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" names itself \"" + actual + "\" in its " +
        "pubspec.yaml but the lock calls it \"" + package_name + "\". " +
        "Overlays and code assets are selected by lock name; re-resolve " +
        "the lock (or rename the package) so the two agree."
    )

def pubspec_version_refusal(hub_name, package_name, locked, actual):
    """The fetch refusal for a path package whose version moved since the lock.

    Args:
        hub_name: The name of the pub hub.
        package_name: The expected package name.
        locked: The locked version string.
        actual: The actual version string in pubspec.yaml.

    Returns:
        The error message string.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" locks version \"" + locked + "\" but its " +
        "pubspec.yaml says \"" + actual + "\" (a pubspec with no " +
        "`version:` field reads as \"0.0.0\", the way `pub get` locks " +
        "it). Overlays and code assets are selected by lock version; " +
        "re-resolve the lock so the two agree."
    )

def malformed_pub_version_refusal(hub_name, package_name, bad_value):
    """The fetch refusal for a path package with an unparsable version.

    Args:
        hub_name: The name of the pub hub.
        package_name: The expected package name.
        bad_value: The invalid version string.

    Returns:
        The error message string.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" has malformed version \"" + bad_value + "\" " +
        "in its pubspec.yaml or the lock entry. Versions are " +
        "major.minor.patch with optional -pre-release and +build (a " +
        "pubspec with no `version:` field reads as \"0.0.0\"); fix the " +
        "version or re-resolve the lock."
    )

def check_pubspec_identity_mismatch(hub_name, package_name, lock_version, pubspec_text):
    """Fail when the package's pubspec name or version disagrees with the lock.

    Args:
        hub_name: Name of the pub hub.
        package_name: Expected package name from lock.
        lock_version: Expected package version from lock.
        pubspec_text: Content of the package's pubspec.yaml.
    """
    identity = parse_pubspec_identity(pubspec_text)
    if not pubspec_text.strip() or not identity.name:
        fail(missing_pubspec_refusal(hub_name, package_name))
    if identity.name != package_name:
        fail(pubspec_name_refusal(hub_name, package_name, identity.name))
    locked = parse_pub_version(lock_version)
    if not locked.ok:
        fail(malformed_pub_version_refusal(hub_name, package_name, locked.text))
    actual = parse_pub_version(identity.version)
    if not actual.ok:
        fail(malformed_pub_version_refusal(hub_name, package_name, actual.text))
    if actual.canonical != locked.canonical:
        fail(pubspec_version_refusal(hub_name, package_name, locked.text, actual.text))
