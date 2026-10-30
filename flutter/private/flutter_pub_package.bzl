"""flutter_pub_package — the `flutter pub get` analog for a single hosted
Flutter pub.dev package.

For each package in a Flutter app's pubspec.lock this rule:
  1. Downloads the same `pub.dev/api/packages/<name>/versions/<version>.tar.gz`
     archive that rules_dart's `pub_lock_package` would.
  2. Reads the package's pubspec.yaml.
  3. Parses `flutter.plugin.platforms` via `parse_flutter_plugin_block`.
  4. Scans the extracted package tree for per-platform Apple source layouts
     (modern SwiftPM `<platform>/<pkg>/Sources/<pkg>/`, shared-darwin
     `darwin/Classes/`, legacy `<platform>/Classes/`).
  5. Branches on whether a `flutter.plugin` block is present:
       - Absent → emit a plain `dart_library` via rules_dart's
         `make_dart_library_build_content`. Pure-Dart pub packages reach
         consumers exactly as they do under `pub.pub()`.
       - Present → emit a `flutter_plugin` whose `plugin_platforms_json`
         carries the parsed metadata, plus per-platform sub-targets:
         `:<pkg>_apple_macos` / `:<pkg>_apple_ios` `flutter_apple_plugin_library`
         when Apple sources are detected for the corresponding
         `flutter.plugin.platforms.<plat>` entry.

This is the rules_flutter sibling of rules_dart's `pub_lock_package`. The
two rules never run for the same package: `flutter.pub()` always invokes
this one for hosted pub packages; `pub.pub()` (in non-Flutter modules)
keeps using `pub_lock_package`. Both share the same archive download +
extract pattern (replicated, not abstracted, to keep the cross-repo
surface small).
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version", "make_dart_library_build_content")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint", "pubspec_sdk_constraint_error")
load("//flutter/private:flutter_pub_cycle_breaks.bzl", "apply_cycle_breaks", "spoke_dep_labels")
load("//flutter/private:flutter_pub_plugin_defines.bzl", "check_plugin_defines", "plugin_defines_attr")
load("//flutter/private:flutter_pub_plugin_deps.bzl", "check_plugin_native_deps")
load("//flutter/private:flutter_pub_scan.bzl", "fetch_hosted_archive", "scan_hosted_archive", "walk_hosted_package")
load("//flutter/private:flutter_pubspec.bzl", "asset_flavor_error", "parse_flutter_assets_block", "parse_flutter_plugin_block", "parse_pubspec")
load(":asset_uri.bzl", "normalize_spoke_asset_block", "normalize_spoke_assets", "normalize_spoke_fonts", "normalize_spoke_shaders")
load(
    ":flutter_pub_android_package.bzl",
    "android_package_repo_name",
    "android_spoke_alias_content",
    "path_package_root",
    _android_make_subpackage_build_content = "make_android_subpackage_build_content",
)
load(
    ":flutter_pub_apple.bzl",
    _detect_apple_plugin_sources = "detect_apple_plugin_sources",
    _has_files_under = "has_files_under",
    _plugin_apple_libs_arg = "plugin_apple_libs_arg",
    _plugin_extra_loads = "plugin_extra_loads",
    _plugin_extra_targets = "plugin_extra_targets",
    _plugin_privacy_files_arg = "plugin_privacy_files_arg",
)
load(":flutter_pub_apple_local.bzl", "apply_apple_native_deps")
load(
    ":flutter_pub_assets.bzl",
    "check_asset_entry_problems",
    "ctx_package_lister",
    "expand_pub_asset_entries",
)
load(":flutter_pub_cover.bzl", "covering_entry", "covering_entry_lookup")
load(":flutter_pub_maven.bzl", _maven_deps_attr = "maven_deps_attr", _maven_ignore_attr = "maven_ignore_attr")
load(
    ":flutter_pub_mirror.bzl",
    "link_scoped_file_entry",
    "link_spoke_contents",
    "make_link_scope",
    "mirror_tree_bounded",
)
load(":flutter_pub_semver.bzl", "parse_pub_version", "pub_version_text")
load(
    ":flutter_pub_walk.bzl",
    "PUB_WALK_BOUND",
    "heredoc_blocks_bound_error",
)
load(
    ":gradle.bzl",
    _gradle_is_java_package_name = "is_java_package_name",
    _gradle_is_maven_dep_label = "is_maven_dep_label",
    _gradle_maven_labels_for_gradle = "maven_labels_for_gradle",
    _gradle_parse_android_manifest_package = "parse_android_manifest_package",
    _gradle_parse_gradle_android_namespace = "parse_gradle_android_namespace",
)
load(":starlark_literal.bzl", "check_spoke_file_name", "decode_starlark_escapes", "starlark_string_literal")
load(":swiftpm_resolved.bzl", "pub_spoke_swiftpm_rule_attrs")

def parse_gradle_android_namespace(content, language = "groovy"):
    """Extract `android.namespace` from a Gradle build script.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_parse_gradle_android_namespace(content, language)

def parse_android_manifest_package(content):
    """Extract the `package` attribute from an AndroidManifest.xml.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_parse_android_manifest_package(content)

def maven_labels_for_gradle(content, mapping, ignore, read_script = None, language = "groovy"):
    """Translate a Gradle build file's runtime deps to Bazel labels.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_maven_labels_for_gradle(content, mapping, ignore, read_script, language)

def is_java_package_name(value):
    """True when `value` is a well-formed Java package name.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_is_java_package_name(value)

def is_maven_dep_label(value):
    """True when `value` is a plausible Bazel label for `android_maven_deps`.

    Moved to `//flutter/private:gradle.bzl`; kept here with the same
    signature so existing loads keep working.
    """
    return _gradle_is_maven_dep_label(value)

def make_android_subpackage_build_content(
        android_src_dir,
        java_package,
        extra_maven_labels,
        android_manifest = "",
        consumer_proguard_specs = [],
        has_resources = False):
    """Generate `android/BUILD.bazel` content for a Flutter plugin.

    Moved to `//flutter/private:flutter_pub_android_package.bzl`, where the
    lazy Android repository uses it; kept here with the same signature so
    existing loads keep working.

    Args:
        android_src_dir: Source dir under the repository root, or empty.
        java_package: The plugin's Android namespace, or empty.
        extra_maven_labels: Translated `@rules_android_maven` labels.
        android_manifest: Repository-relative manifest path, or empty.
        consumer_proguard_specs: Android-subpackage-relative keep-rule paths.
        has_resources: True when `android/src/main/res/` holds files.

    Returns:
        Generated BUILD content as a string.
    """
    return _android_make_subpackage_build_content(
        android_src_dir = android_src_dir,
        java_package = java_package,
        extra_maven_labels = extra_maven_labels,
        android_manifest = android_manifest,
        consumer_proguard_specs = consumer_proguard_specs,
        has_resources = has_resources,
    )

# C/C++ source extensions for Linux/Windows plugin libraries.
_DESKTOP_SRC_EXTENSIONS = ("cc", "cpp", "c", "h", "hh", "hpp")

def _detect_desktop_source_dir(ctx, package_name, platform):
    """Return the Linux/Windows source dir if it contains C/C++ files.

    Pub plugins put Linux sources at `linux/` and Windows sources at
    `windows/`. We surface a single source dir per platform (the
    plugin's own conventions); subdirectories like `linux/include/` are
    swept by the resulting glob.

    Args:
        ctx: The spoke repository context.
        package_name: The pub package the sources belong to.
        platform: `linux` or `windows`.

    Returns:
        The platform directory when it holds C/C++ files, else `""`.
    """
    if _has_files_under(ctx, platform, _DESKTOP_SRC_EXTENSIONS, package_name):
        return platform
    return ""

def encode_spoke_fonts(parsed_fonts):
    """The spoke's font attrs from normalized `flutter.fonts` entries.

    One loop builds both shapes `build_pub_contributions` matches by key:
    the `fonts_json` payload carrying each font's encoded bundle key, and
    the `font_files` label dict whose decoded labels name the files. Each
    font arrives normalized (`struct(asset, key, weight, style)` from
    `normalize_spoke_fonts`); a spelling flutter_tools would not bundle
    already failed the fetch there.

    Args:
        parsed_fonts: Normalized entries from `normalize_spoke_fonts`.

    Returns:
        `struct(fonts_json_str, font_files)`: the JSON payload ("" when
        there are no fonts) and the label-to-path dict.
    """
    fonts_for_json = []
    font_files = {}
    for entry in parsed_fonts:
        fonts_list = []
        for font in entry.fonts:
            d = {"asset": font.key}
            if font.weight != None:
                d["weight"] = font.weight
            if font.style != None:
                d["style"] = font.style
            fonts_list.append(d)
            font_files[":" + font.asset] = font.key
        fonts_for_json.append({"family": entry.family, "fonts": fonts_list})
    return struct(
        fonts_json_str = json.encode(fonts_for_json) if fonts_for_json else "",
        font_files = font_files,
    )

def build_pkg_assets_dict(expanded):
    """Build the `pkg_assets` dict from expanded per-file entries.

    Flutter's `flutter.assets:` accepts paths and trailing-slash directory
    prefixes. Bazel needs an explicit label per file, so each directory is
    walked at repo-rule time and emits one entry per discovered file. The
    label names the decoded file (`":" + path`); the value is the
    percent-encoded bundle key, as flutter_tools keys it
    (`asset.dart:1425-1428`).
    """
    return {":" + entry.path: entry.key for entry in expanded}

def _sorted_flavor_set(flavors):
    """The deduplicated, sorted flavor names, for order-insensitive comparison."""
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
        (same shapes `_build_pkg_asset_conditions` returns) and the fetch
        failure naming the package, the file and both flavor lists, or `""`
        when the entries agree. A file with one entry keeps its declared
        order, so single-entry spokes render byte-identically to before.
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
            if _sorted_flavor_set(other.flavors) != _sorted_flavor_set(first.flavors):
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

def _build_pkg_asset_conditions(expanded, package_name):
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

def build_pkg_shaders_dict(parsed_shaders):
    """Build the `pkg_shaders` dict from normalized shader entries.

    Same shape as pkg_assets, no directories: decoded labels naming the
    files, encoded bundle keys as values (`asset.dart:1425-1428`).
    """
    return {":" + entry.path: entry.key for entry in parsed_shaders}

def _format_label_dict_literal(d, indent = "        "):
    """Render `{":foo": "foo", ":bar": "bar"}` as a multi-line BUILD source dict."""
    if not d:
        return "{}"
    keys = sorted(d.keys())

    # Keys and values are asset, font and shader paths from the pubspec and
    # the file-system walk: attacker-controlled for hosted packages. Each
    # renders through the escaping helper, so the dict parses back exactly.
    lines = ["{indent}{k}: {v},".format(indent = indent, k = starlark_string_literal(k), v = starlark_string_literal(d[k])) for k in keys]
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

def _format_string_list_dict_literal(d, indent = "        "):
    """Render `{":foo": ["a", "b"]}` as a multi-line BUILD source dict."""
    if not d:
        return "{}"
    lines = []
    for k in sorted(d.keys()):
        # Keys are walked asset paths (see above); values are flavor and
        # platform names from the pubspec, helper-rendered for the same
        # reason: a flavor name may hold any string the pubspec declares.
        values = ", ".join([starlark_string_literal(v) for v in d[k]])
        lines.append("{indent}{k}: [{values}],".format(indent = indent, k = starlark_string_literal(k), values = values))
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

# File extensions a shader may `#include`: the spoke links them beside a
# top-level declared shader so its scoped include glob resolves.
_PATH_SPOKE_SHADER_INCLUDE_EXTS = ("glsl", "frag", "vert")

def scoped_shader_includes_block(shader_paths):
    """Render `shader_includes` covering only the declared shaders' own directories.

    Each non-empty dirname contributes `<dir>/**/*.glsl|frag|vert`; a
    top-level shader contributes root `*.ext`. Sorted for determinism, so
    `example/build/` output can never become an include through a
    package-wide `**` glob.

    Args:
        shader_paths: Declared shader paths (the `pkg_shaders` values).

    Returns:
        The `shader_includes = glob(...)` BUILD block.
    """
    dirs = {}
    for path in shader_paths:
        dirs[path.rpartition("/")[0]] = True
    lines = []
    for d in sorted(dirs.keys()):
        for ext in _PATH_SPOKE_SHADER_INCLUDE_EXTS:
            pattern = d + "/**/*." + ext if d else "*." + ext

            # `d` is a declared shader's own directory, read from the
            # pubspec; the pattern renders through the escaping helper.
            lines.append("        " + starlark_string_literal(pattern) + ",")
    return "    shader_includes = glob(\n        [\n{}\n        ],\n        allow_empty = True,\n    ),".format("\n".join(lines))

def _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders, pkg_asset_platforms = {}, pkg_asset_flavors = {}):
    """Render the pub-asset attrs as BUILD source, omitting empty ones."""
    parts = []
    if fonts_json_str:
        parts.append("    fonts_json = " + starlark_string_literal(fonts_json_str) + ",")
    if font_files:
        parts.append("    font_files = {},".format(_format_label_dict_literal(font_files)))
    if pkg_assets:
        parts.append("    pkg_assets = {},".format(_format_label_dict_literal(pkg_assets)))
    if pkg_asset_platforms:
        parts.append("    pkg_asset_platforms = {},".format(_format_string_list_dict_literal(pkg_asset_platforms)))
    if pkg_asset_flavors:
        parts.append("    pkg_asset_flavors = {},".format(_format_string_list_dict_literal(pkg_asset_flavors)))
    if pkg_shaders:
        parts.append("    pkg_shaders = {},".format(_format_label_dict_literal(pkg_shaders)))

        # What the shaders may `#include`: GLSL beside a declared shader, so
        # only the declared shaders' own directories resolve — never the
        # whole package, where `example/build/` output would become includes.
        parts.append(scoped_shader_includes_block(sorted(pkg_shaders.values())))
    return ("\n".join(parts) + "\n") if parts else ""

def _format_code_asset_attrs(code_assets, has_unreplaced_hook):
    """Render the `code_assets` / `has_unreplaced_hook` attrs for a spoke.

    Shared by the `flutter_library` and `flutter_plugin` generators so the two
    emit an identical shape; the `dart_library` branch gets the equivalent from
    rules_dart's own `make_dart_library_build_content`.
    """
    block = ""
    if code_assets:
        # Labels arrive from the curated registry; the hook path is one of
        # two fixed entrypoints. Both still render through the helper.
        lines = ["        " + starlark_string_literal(a) + "," for a in code_assets]
        block += "    code_assets = [\n{}\n    ],\n".format("\n".join(lines))
    if has_unreplaced_hook:
        block += "    has_unreplaced_hook = " + starlark_string_literal(has_unreplaced_hook) + ",\n"
    return block

# The non-Dart remainder of `lib/`, emitted verbatim by both spoke
# generators below — the same partition rules_dart's
# `make_dart_library_build_content` uses, so `srcs + resources = lib/**`
# holds for every spoke whichever generator ran. A published package's
# `lib/` is addressable as `package:<name>/<path>` whatever the extension;
# a spoke that keeps only `*.dart` is a package with pieces missing.
# `resources` is orthogonal to the declared-asset attrs (`pkg_assets` /
# `pkg_shaders` / `font_files`): those name what is transformed and bundled
# into flutter_assets, while `resources` names membership in the staged
# package tree. A shader under `lib/` is legitimately both.
_RESOURCES_GLOB_BLOCK = """    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
"""

def _format_version_attr(version):
    """The `version` attr line for a spoke, or nothing when it is unknown.

    Omitted rather than written empty, matching
    `make_dart_library_build_content`. The attribute's only use is agreement
    checking between two records for one package name, and an unstated version
    never conflicts — so a spoke with nothing to say says nothing.

    Args:
        version: The resolved package version, or "".

    Returns:
        A BUILD attribute line, or "".
    """

    # The lock's version string renders through the helper like the rest.
    return "    version = " + starlark_string_literal(version) + ",\n" if version else ""

def make_flutter_library_build_content(
        name,
        deps,
        language_version,
        code_assets,
        has_unreplaced_hook,
        fonts_json_str,
        font_files,
        pkg_assets,
        pkg_shaders,
        pkg_asset_platforms = {},
        pkg_asset_flavors = {},
        version = ""):
    """Generate BUILD content for a non-plugin Flutter spoke shipping fonts/assets/shaders.

    Counterpart to `make_dart_library_build_content` — used when the spoke
    declares anything under `flutter:` other than `plugin:` (e.g.
    cupertino_icons declaring `flutter.fonts`). The same shape a user
    would write by hand: `flutter_library` with the new pub-asset attrs,
    plus the non-Dart `lib/` remainder as `resources`.

    Args:
        name: Target name (also the `package_name`).
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.4"`).
        code_assets: `dart_code_asset` label strings replacing this
            package's build hook output.
        has_unreplaced_hook: Path of a build hook nothing replaces, or "".
        fonts_json_str: JSON-encoded `flutter.fonts` declarations, or "".
        font_files: Dict of font file label -> package-relative path.
        pkg_assets: Dict of asset file label -> package-relative path.
        pkg_shaders: Dict of shader file label -> package-relative path.
        pkg_asset_platforms: Dict of asset label -> platform list, only for
            restricted entries. Empty (the common case) emits no attr, so
            unconditional spokes are byte-identical to before.
        pkg_asset_flavors: Dict of asset label -> flavor list, same shape.
        version: The resolved package version this spoke was fetched at, or
            empty. Emitted only when known, matching
            `make_dart_library_build_content`: its sole use is agreement
            checking when one package name arrives from two hubs, and an
            unstated version never conflicts with a stated one.

    Returns:
        BUILD.bazel content as a string.

    Escaping: `name` is a lock package name (refused quotable at hub
    classification) and `language_version` is a derived `X.Y`; every walked
    or declared path below renders through the escaping helper.
    """
    deps_block = _spoke_deps_block(deps)

    pub_attrs = _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders, pkg_asset_platforms, pkg_asset_flavors)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}{deps}    package_name = "{name}",
    language_version = "{language_version}",
{version}{asset_attrs}{pub_attrs}    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        resources = _RESOURCES_GLOB_BLOCK,
        deps = deps_block,
        language_version = language_version,
        version = _format_version_attr(version),
        asset_attrs = _format_code_asset_attrs(code_assets, has_unreplaced_hook),
        pub_attrs = pub_attrs,
    )

def _spoke_deps_block(deps):
    """The `deps` attribute block for a spoke, or nothing when it has none."""
    if not deps:
        return ""

    # Labels are built from the hub name and lock package names, which hub
    # classification already refused when quotable; each still renders
    # through the escaping helper, so a hostile label lands inert.
    dep_lines = ["        " + starlark_string_literal(dep) + "," for dep in deps]
    return "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

def make_flutter_plugin_build_content(
        name,
        deps,
        language_version,
        code_assets,
        has_unreplaced_hook,
        plugin_platforms_json,
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        apple_macos_include_dirs,
        apple_ios_include_dirs,
        apple_macos_privacy_manifests,
        apple_ios_privacy_manifests,
        linux_src_dir,
        windows_src_dir,
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {},
        pkg_asset_platforms = {},
        pkg_asset_flavors = {},
        version = "",
        plugin_defines = []):
    """Generate BUILD content for a Flutter plugin spoke.

    Emits a `flutter_plugin` plus optional per-platform
    `flutter_apple_plugin_library` (Apple) /
    `flutter_linux_plugin_library` /
    `flutter_windows_plugin_library` sub-targets.

    Android Kotlin/Java sources are exposed via a sibling `android/`
    sub-package (see `make_android_subpackage_build_content`). The
    sub-package is loaded only when something queries
    `@<spoke>//android:lib` — non-Android workspaces don't pay the
    `@rules_android` / `@rules_kotlin` cost.

    Args:
        name: Target name (also the `package_name`).
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.4"`).
        code_assets: `dart_code_asset` label strings replacing this
            package's build hook output.
        has_unreplaced_hook: Path of a build hook nothing replaces, or "".
        plugin_platforms_json: JSON-encoded `flutter.plugin.platforms` dict.
        apple_macos_srcs_dirs: Detected macOS Apple source dirs.
        apple_ios_srcs_dirs: Detected iOS Apple source dirs.
        apple_macos_include_dirs: SwiftPM-style public-header dirs (macOS).
        apple_ios_include_dirs: SwiftPM-style public-header dirs (iOS).
        apple_macos_privacy_manifests: `PrivacyInfo.xcprivacy` paths (macOS).
        apple_ios_privacy_manifests: `PrivacyInfo.xcprivacy` paths (iOS).
        linux_src_dir: Linux C/C++ source dir, or "".
        windows_src_dir: Windows C/C++ source dir, or "".
        fonts_json_str: JSON-encoded `flutter.fonts` declarations, or "".
        font_files: Dict of font file label -> package-relative path.
        pkg_assets: Dict of asset file label -> package-relative path.
        pkg_shaders: Dict of shader file label -> package-relative path.
        pkg_asset_platforms: Dict of asset label -> platform list, only for
            restricted entries. Empty (the common case) emits no attr, so
            unconditional spokes are byte-identical to before.
        pkg_asset_flavors: Dict of asset label -> flavor list, same shape.
        version: The resolved package version this spoke was fetched at, or
            empty. Emitted only when known, matching
            `make_dart_library_build_content`: its sole use is agreement
            checking when one package name arrives from two hubs, and an
            unstated version never conflicts with a stated one.
        plugin_defines: Preprocessor defines for this plugin's Apple
            libraries, in the order given. Empty emits no attribute.

    Returns:
        BUILD.bazel content as a string.

    Escaping: `name` is a lock package name (refused quotable at hub
    classification) and `language_version` is a derived `X.Y`; the plugin
    JSON and every walked or declared path render through the helper.
    """
    deps_block = _spoke_deps_block(deps)

    extra_loads = _plugin_extra_loads(apple_macos_srcs_dirs, apple_ios_srcs_dirs, linux_src_dir, windows_src_dir)
    extra_targets = _plugin_extra_targets(
        name,
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        apple_macos_include_dirs,
        apple_ios_include_dirs,
        linux_src_dir,
        windows_src_dir,
        plugin_defines,
    )

    # NB: Android sources are no longer surfaced via a top-level filegroup.
    # See `make_android_subpackage_build_content` — the spoke's `android/`
    # sub-package wraps them in a kt_android_library that the hub's
    # aggregator (`@<hub>//android:all_android_plugin_libs`) depends on.

    apple_libs_arg = _plugin_apple_libs_arg(name, apple_macos_srcs_dirs, apple_ios_srcs_dirs)

    # Branch labels compose the classified package name with fixed
    # suffixes; nothing walked or declared reaches them unquoted.
    linux_libs_arg = ""
    if linux_src_dir:
        linux_libs_arg = '    linux_libs = [":{name}_linux"],\n'.format(name = name)

    windows_libs_arg = ""
    if windows_src_dir:
        windows_libs_arg = '    windows_libs = [":{name}_windows"],\n'.format(name = name)

    # Android sources travel through a sibling `android/` sub-package, which
    # the hub's `all_android_plugin_libs` deps on and the application macro
    # adds to `binary_deps`. See `make_android_subpackage_build_content`.
    # Nothing rides a provider: the wiring happens at macro-load time, where
    # providers cannot be read.

    # Apple PrivacyInfo.xcprivacy files: thread through `apple_privacy_files`
    # on the flutter_plugin so they propagate via FlutterInfo to the platform
    # application rule, which bundles them via Resources/.
    apple_privacy_files_arg = _plugin_privacy_files_arg(
        apple_macos_privacy_manifests,
        apple_ios_privacy_manifests,
    )

    pub_attrs = _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders, pkg_asset_platforms, pkg_asset_flavors)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")
{extra_loads}
flutter_plugin(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}{deps}    package_name = "{name}",
    plugin_platforms_json = {plugin_platforms_json_literal},
    language_version = "{language_version}",
{version}{apple_libs_arg}{linux_libs_arg}{windows_libs_arg}{apple_privacy_files_arg}{asset_attrs}{pub_attrs}    visibility = ["//visibility:public"],
)
{extra_targets}
""".format(
        name = name,
        version = _format_version_attr(version),
        asset_attrs = _format_code_asset_attrs(code_assets, has_unreplaced_hook),
        resources = _RESOURCES_GLOB_BLOCK,
        deps = deps_block,
        language_version = language_version,
        plugin_platforms_json_literal = starlark_string_literal(plugin_platforms_json),
        extra_loads = extra_loads,
        extra_targets = extra_targets,
        apple_libs_arg = apple_libs_arg,
        linux_libs_arg = linux_libs_arg,
        windows_libs_arg = windows_libs_arg,
        apple_privacy_files_arg = apple_privacy_files_arg,
        pub_attrs = pub_attrs,
    )

# The hook entrypoints upstream Dart defines (`package:hooks` — `build` and
# `link`). A package shipping one produces native libraries by running Dart at
# build time, which Bazel cannot do hermetically; something must stand in for it.
_DART_BUILD_HOOKS = ["hook/build.dart", "hook/link.dart"]

def _detect_unreplaced_hook(ctx):
    """Return the path of a build hook nothing replaces, or "".

    Recording rather than failing here is deliberate, and matches rules_dart:
    the whole lock is materialised, including packages nothing depends on, so
    failing at repo generation would break builds over packages never reached.
    The application that actually depends on one fails instead.
    """
    if ctx.attr.code_assets or ctx.attr.ignore_hook:
        return ""
    for candidate in _DART_BUILD_HOOKS:
        if ctx.path(candidate).exists:
            return candidate
    return ""

_LANGUAGE_VERSION_PLACEHOLDER = "{LANGUAGE_VERSION}"
_DEPS_PLACEHOLDER = "{DEPS}"

# The prefix a spoke label takes in an overlay template before substitution.
# Finding one means the template names a sibling package by hand.
_HUB_DEP_PREFIX = "@{HUB_NAME}__"

def find_hardcoded_language_version(content):
    """Return the literal language version an overlay spells out, or `""`.

    A package's `environment.sdk` is the only place its language version is
    declared; the spoke derives from it and substitutes
    `{LANGUAGE_VERSION}`. A template that writes the version out instead is a
    second declaration of the same fact, and the one that wins — the overlay
    replaces generated content wholesale. The two then drift silently,
    because the overlay ladder is version-ranged: `ext/objective_c/9/` serves
    every 9.x, so a release that raises the SDK floor keeps the old literal.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending literal (e.g. `"3.3"`), or `""` when the template
        either uses the placeholder or declares no language version.
    """
    marker = "language_version"
    idx = content.find(marker)
    for _ in range(len(content)):
        if idx == -1:
            return ""
        rest = content[idx + len(marker):].lstrip(" ")
        if rest.startswith("="):
            value = rest[1:].lstrip(" ")
            if value.startswith('"'):
                end = value.find('"', 1)
                if end > 0:
                    literal = value[1:end]
                    if literal != _LANGUAGE_VERSION_PLACEHOLDER:
                        return literal
        idx = content.find(marker, idx + len(marker))
    return ""

def find_hardcoded_hub_dep(content):
    """Return the first hand-written sibling-spoke label an overlay names, or `""`.

    A package's dependencies are declared once, by its own pubspec, and the
    spoke derives the Bazel labels from it — intersected with the lock, so a
    generated spoke can never name a repo the hub did not create. An overlay
    that spells the list out instead declares the same fact twice, and this
    copy wins, because an overlay replaces generated content wholesale.

    The two then drift on the package's next release, and the drift is not
    a stale-but-working list: `objective_c` 9.5.0 dropped `native_toolchain_c`
    from `dependencies` (its build hook stopped using it), so the lock stopped
    carrying that package, while `ext/objective_c/9/` — one directory for the
    whole major — kept asking for `@<hub>__native_toolchain_c`. The build died
    on an unknown repo naming neither `objective_c` nor the overlay.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending label (e.g. `"@{HUB_NAME}__ffi//:ffi"`), or `""`.
    """
    idx = content.find(_HUB_DEP_PREFIX)
    if idx == -1:
        return ""
    end = content.find('"', idx)
    return content[idx:end] if end > 0 else content[idx:]

def render_overlay_deps(dep_labels):
    """Render `dep_labels` as the body of an overlay's `deps = [...]`.

    Emits one quoted, comma-terminated label per line at the eight-space
    indent a template's `deps = [` block sits at, so the substituted BUILD
    file comes out buildifier-clean.

    Args:
        dep_labels: Fully-qualified labels, in the order they should appear.

    Returns:
        The list body, without the enclosing brackets.
    """

    # Labels derive from the package's own pubspec intersected with the
    # lock (names refused quotable at classification); each still renders
    # through the escaping helper before substitution into the template.
    return "\n        ".join([starlark_string_literal(label) + "," for label in dep_labels])

_WRITE_FILE_LOAD = 'load("@bazel_skylib//rules:write_file.bzl", "write_file")\n'
_CAT_HEREDOC_PREFIX = "    cmd = \"cat > $@ <<'EOF'\\n"
_CAT_HEREDOC_SUFFIX = "\\nEOF\\n\",\n)"

def _decode_heredoc_field(source, package_name, template, genrule_name, field):
    """Decode one source-encoded heredoc field, failing the fetch closed.

    Args:
        source: The still-encoded field text cut out of the template.
        package_name: The pub package the overlay belongs to, for the failure.
        template: The overlay template path, for the failure.
        genrule_name: The raw `name` line, naming the genrule in the failure.
        field: Which field failed to decode (`name`, `outs`, or the body).

    Returns:
        The decoded text; fails the fetch naming the package, the template
        and the genrule when the field holds an undecodable escape.
    """
    decoded = decode_starlark_escapes(source)
    if decoded.error != "":
        fail((
            "flutter.pub overlay for \"{pkg}\" ({tpl}): genrule {name} holds " +
            "{error} in its {field}; refusing it rather than emitting " +
            "bytes the heredoc `cat` never wrote."
        ).format(
            pkg = package_name,
            tpl = template,
            name = repr(genrule_name),
            error = decoded.error,
            field = field,
        ))
    return decoded.text

def _peek_heredoc_block(rest):
    """Classify the next `genrule(` block in `rest` without consuming it.

    Shared by the bounded rewrite and its bound check, so the check sees
    exactly what the rewrite would do next: a convertible block left over
    after the bound means the template would otherwise emit partially.

    Args:
        rest: The not-yet-rewritten template tail.

    Returns:
        A `struct(kind, idx, end, body, name_val, out_val)`: `kind` is
        `"none"` (no block, or no heredoc terminator, left), `"plain"`
        (the next block is not a convertible heredoc genrule and stays
        untouched), or `"convert"` (the next block is a heredoc `cat`
        genrule the rewrite replaces; `end` is just past its terminator).
    """
    no_block = struct(kind = "none", idx = -1, end = -1, body = "", name_val = "", out_val = "")
    idx = rest.find("genrule(\n")
    if idx < 0:
        return no_block
    end_idx = rest.find(_CAT_HEREDOC_SUFFIX, idx)
    if end_idx < 0:
        return no_block
    end = end_idx + len(_CAT_HEREDOC_SUFFIX)
    block = rest[idx:end]
    cmd_idx = block.find(_CAT_HEREDOC_PREFIX)
    if cmd_idx < 0:
        return struct(kind = "plain", idx = idx, end = -1, body = "", name_val = "", out_val = "")
    header = block[:cmd_idx]
    body = block[cmd_idx + len(_CAT_HEREDOC_PREFIX):len(block) - len(_CAT_HEREDOC_SUFFIX)]
    name_val = ""
    out_val = ""
    for hline in header.split("\n"):
        s = hline.strip()
        if s.startswith('name = "') and s.endswith('",'):
            name_val = s[len('name = "'):-2]
        elif s.startswith('outs = ["') and s.endswith('"],'):
            out_val = s[len('outs = ["'):-3]
    if not name_val or not out_val:
        return struct(kind = "plain", idx = idx, end = -1, body = "", name_val = "", out_val = "")
    return struct(kind = "convert", idx = idx, end = end, body = body, name_val = name_val, out_val = out_val)

def rewrite_cat_genrules_bounded(content, package_name, template, bound):
    """Rewrite at most `bound` heredoc blocks, reporting leftovers purely.

    Pure core of `_rewrite_cat_genrules`: unit tests drive it with a small
    bound and count blocks. An undecodable escape still fails the fetch
    (see `_decode_heredoc_field`); a bound reached with a convertible block
    left over is reported in `leftover`, and the caller fails the fetch.

    Args:
        content: The substituted overlay template text.
        package_name: The pub package the overlay belongs to, for failures.
        template: The overlay template path, for failures.
        bound: Maximum heredoc blocks to rewrite; tests drive this small.

    Returns:
        A `struct(text, leftover)`: `text` holds the template with each
        rewritten block replaced (plus the untouched tail); `leftover` is
        True when a convertible heredoc block remains.
    """
    out_chunks = []
    rest = content
    for _ in range(bound):
        scanned = _peek_heredoc_block(rest)
        if scanned.kind == "none":
            break
        if scanned.kind == "plain":
            out_chunks.append(rest[:scanned.idx + len("genrule(\n")])
            rest = rest[scanned.idx + len("genrule(\n"):]
            continue

        # The cut-out body (and the parsed `name`/`outs` lines) is Starlark
        # source text: its escapes are still encoded. Decode each to the
        # actual text first, or the escaping helper below escapes the
        # already-escaped text a second time.
        name = _decode_heredoc_field(scanned.name_val, package_name, template, scanned.name_val, "name")
        out = _decode_heredoc_field(scanned.out_val, package_name, template, scanned.name_val, "outs")
        body_text = _decode_heredoc_field(scanned.body, package_name, template, scanned.name_val, "heredoc body")
        body_lines = body_text.split("\n") + [""]

        # Decoded lines are plain values now; every line still renders
        # through the escaping helper on its way into `content`.
        content_entries = "\n".join(["        " + starlark_string_literal(line) + "," for line in body_lines])
        replacement = (
            "write_file(\n" +
            "    name = " + starlark_string_literal(name) + ",\n" +
            "    out = " + starlark_string_literal(out) + ",\n" +
            "    content = [\n" +
            content_entries + "\n" +
            "    ],\n" +
            '    newline = "unix",\n' +
            # Public so consumers can read the output through runfiles: the
            # e2e BuildConfig verifier holds a `data` dependency on it, and
            # `bazel build` of the label needs no visibility at all.
            '    visibility = ["//visibility:public"],\n' +
            ")"
        )
        out_chunks.append(rest[:scanned.idx])
        out_chunks.append(replacement)
        rest = rest[scanned.end:]
    out_chunks.append(rest)
    leftover = _peek_heredoc_block(rest).kind == "convert"
    return struct(text = "".join(out_chunks), leftover = leftover)

def _rewrite_cat_genrules(content, package_name = "", template = "", bound = PUB_WALK_BOUND):
    """Rewrite heredoc `cat` `genrule` targets in overlay templates to `write_file`.

    The cut-out heredoc body (and the parsed `name`/`outs` lines) is
    Starlark source text: its escapes are still encoded. Each decodes to
    the actual text before rendering, so the `write_file` output equals the
    bytes the original genrule's `cat` heredoc would have written. An
    undecodable escape fails the fetch, naming the package and the
    template. Every decoded line still renders through
    `starlark_string_literal`; the build-escape fix stays intact. At most
    `bound` blocks are rewritten; a template with more convertible blocks
    fails the fetch naming the package, the template, and the bound,
    instead of emitting part of the template.

    Args:
        content: The substituted overlay template text.
        package_name: The pub package the overlay belongs to, for failures.
        template: The overlay template path, for failures.
        bound: Maximum heredoc blocks to rewrite.

    Returns:
        The template with each heredoc `cat` genrule replaced by an
        equivalent `write_file`, plus the `write_file` load when missing.
    """
    if _CAT_HEREDOC_PREFIX not in content:
        return content
    rewritten = rewrite_cat_genrules_bounded(content, package_name, template, bound)
    if rewritten.leftover:
        fail(heredoc_blocks_bound_error(package_name, template, bound))
    text = rewritten.text
    if _WRITE_FILE_LOAD not in text:
        load_idx = text.find("load(")
        if load_idx >= 0:
            text = text[:load_idx] + _WRITE_FILE_LOAD + text[load_idx:]
        else:
            text = _WRITE_FILE_LOAD + text
    return text

def apply_overlay_substitutions(content, hub_name, package_name, version, language_version, deps, template = ""):
    """Fill an overlay template's placeholders.

    Args:
        content: Raw template text.
        hub_name: Value for `{HUB_NAME}`.
        package_name: Value for `{PKG}`.
        version: Value for `{VERSION}`.
        language_version: Value for `{LANGUAGE_VERSION}`, derived from the
            package's own pubspec.
        deps: Rendered list body for `{DEPS}` (see `render_overlay_deps`),
            derived from the same pubspec-and-lock intersection a generated
            spoke uses.
        template: The overlay template path, naming it in heredoc decode
            failures (see `_rewrite_cat_genrules`).

    Returns:
        The substituted content.
    """
    substituted = content.replace(
        "{HUB_NAME}",
        hub_name,
    ).replace(
        "{PKG}",
        package_name,
    ).replace(
        "{VERSION}",
        version,
    ).replace(
        _LANGUAGE_VERSION_PLACEHOLDER,
        language_version,
    ).replace(
        _DEPS_PLACEHOLDER,
        deps,
    )
    return _rewrite_cat_genrules(substituted, package_name, template)

def _resolve_overlay_template(ctx, overlay_root_label, package_name, version, language_version, dep_labels, relpath, guard_hub_deps = False):
    """Look up an overlay template at `<root>/<package>/<version-ladder>/<relpath>`.

    Walks the version-specificity ladder
    `<major>.<minor>.<patch>/`, `<major>.<minor>/`, `<major>/`, bare
    `<package>/`, and returns the templated content (with `{HUB_NAME}`,
    `{PKG}`, `{VERSION}`, `{LANGUAGE_VERSION}` and `{DEPS}` substitutions
    applied) on first match. Returns empty string when no template is found.

    `dep_labels` are the spoke labels the package's own pubspec resolves to,
    which `{DEPS}` expands into. `guard_hub_deps` rejects a template that
    hand-writes those labels instead — see `find_hardcoded_hub_dep`. Only the
    top-level BUILD sets it: `{DEPS}` is a Dart dependency list, so it is not
    the right substitute for a sibling label in an `android/` sub-package.

    Currently called for two relpaths:

    * `BUILD.bazel.tpl` — the spoke's top-level BUILD that fully
      replaces the auto-generated content.
    * `android/BUILD.bazel.tpl` — the Android sub-package BUILD,
      replacing the empty-stub `kt_android_library(srcs=[])` that
      otherwise fires when a top-level overlay short-circuits the
      regular auto-gen path. Plugins whose Android side needs real
      sources / extra maven labels (e.g. ones whose Java references
      transitive deps not in the curated `_MAVEN_COORD_TO_LABEL`)
      ship this alongside the top-level overlay.
    """
    anchor = ctx.path(overlay_root_label)
    ctx.watch(anchor)
    root = anchor.dirname
    ctx.watch(root)
    pkg_dir = root.get_child(package_name)
    ctx.watch(pkg_dir)

    # Build the version ladder.
    parts = version.split(".")
    candidates = []
    if len(parts) >= 3:
        candidates.append("{}.{}.{}".format(parts[0], parts[1], parts[2]))
    if len(parts) >= 2:
        candidates.append("{}.{}".format(parts[0], parts[1]))
    if len(parts) >= 1 and parts[0]:
        candidates.append(parts[0])
    candidates.append("")  # bare <pkg>/<relpath>

    relpath_parts = relpath.split("/")
    for candidate in candidates:
        cand_dir = pkg_dir.get_child(candidate) if candidate else pkg_dir
        if candidate:
            ctx.watch(cand_dir)
        tpl = cand_dir
        for part in relpath_parts:
            tpl = tpl.get_child(part)
            ctx.watch(tpl)
        if tpl.exists:
            content = ctx.read(tpl)
            hardcoded_dep = find_hardcoded_hub_dep(content) if guard_hub_deps else ""
            if hardcoded_dep:
                fail((
                    "overlay template {tpl} hand-writes the dependency " +
                    "`{dep}`.\n" +
                    "A package's dependencies are declared once, by its own " +
                    "pubspec; the spoke derives the labels from it — " +
                    "intersected with the lock, so it can never name a repo " +
                    "the hub did not create. Listing them here declares the " +
                    "same fact twice, and this copy wins, because an overlay " +
                    "replaces generated content wholesale. Because the " +
                    "overlay ladder is version-ranged, a release that changes " +
                    "the package's dependencies then fails on an unknown " +
                    "repo that names neither the package nor this file.\n" +
                    "Write `deps = [\n        {placeholder}\n    ],` instead."
                ).format(
                    tpl = str(tpl),
                    dep = hardcoded_dep,
                    placeholder = _DEPS_PLACEHOLDER,
                ))
            hardcoded = find_hardcoded_language_version(content)
            if hardcoded:
                fail((
                    "overlay template {tpl} sets language_version = \"{value}\".\n" +
                    "A package's language version is declared once, by its own " +
                    "pubspec `environment.sdk`; the spoke derives it and fills in " +
                    "{placeholder}. Spelling it out here declares the same fact " +
                    "twice, and this copy wins — an overlay replaces generated " +
                    "content wholesale. Because the overlay ladder is " +
                    "version-ranged, the two then drift without a build error.\n" +
                    "Write `language_version = \"{placeholder}\"` instead."
                ).format(
                    tpl = str(tpl),
                    value = hardcoded,
                    placeholder = _LANGUAGE_VERSION_PLACEHOLDER,
                ))
            return apply_overlay_substitutions(
                content = content,
                hub_name = ctx.attr.hub_name,
                package_name = package_name,
                version = version,
                language_version = language_version,
                deps = render_overlay_deps(dep_labels),
                template = str(tpl),
            )
    return ""

resolve_overlay_template = _resolve_overlay_template

def _resolve_overlay(ctx, overlay_root_label, package_name, version, language_version, dep_labels):
    """Resolve the top-level BUILD.bazel.tpl overlay.

    Equivalent to `_resolve_overlay_template(..., "BUILD.bazel.tpl")`.
    Kept as a separate helper because the top-level lookup is the most
    common call shape; consumers wanting the Android sub-package
    template call `_resolve_overlay_template` directly.
    """
    return _resolve_overlay_template(
        ctx,
        overlay_root_label,
        package_name,
        version,
        language_version,
        dep_labels,
        "BUILD.bazel.tpl",
        guard_hub_deps = True,
    )

resolve_overlay = _resolve_overlay

def resolve_overlay_roots(ctx, overlay_roots, package_name, version, language_version, dep_labels):
    """Resolve `(overlay_content, overlay_android_content)` across `overlay_roots`.

    Walks `overlay_roots` in order and stops on the first root that supplies a
    top-level `BUILD.bazel.tpl` for `package_name` at `version`, then looks up
    the matching `android/BUILD.bazel.tpl` from that same root.

    Args:
        ctx: The repository rule context (`repository_ctx`).
        overlay_roots: Anchor labels for candidate overlay trees, ordered by precedence.
        package_name: The pub package name to look up.
        version: The resolved package version string.
        language_version: The Dart language version derived from the package's pubspec.
        dep_labels: Sibling spoke label strings for `{DEPS}` substitution.

    Returns:
        A `(overlay_content, overlay_android_content)` tuple of substituted
        BUILD contents (each `""` when no matching template was found).
    """
    overlay_content = ""
    overlay_android_content = ""
    for overlay_label in overlay_roots:
        overlay_content = _resolve_overlay(
            ctx,
            overlay_label,
            package_name,
            version,
            language_version,
            dep_labels,
        )
        if overlay_content:
            # Look up the matching `android/BUILD.bazel.tpl` from the same
            # overlay root. Plugins whose Android side has real sources
            # ship one alongside the top-level BUILD; plugins that don't
            # leave it absent and the empty-stub fallback fires below.
            overlay_android_content = _resolve_overlay_template(
                ctx,
                overlay_label,
                package_name,
                version,
                language_version,
                dep_labels,
                "android/BUILD.bazel.tpl",
            )
            break
    return overlay_content, overlay_android_content

def _fetch_pub_archive(ctx):
    """Downloads and extracts the package archive, like `pub_lock_package`.

    Delegates to `fetch_hosted_archive`: a sha256-verified download, the
    gzip trailer trim, rules_dart's header scan over the trimmed bytes
    before `ctx.extract`, and its symlink walk over the extracted tree
    before anything reads it. A refused archive fails the fetch with
    rules_dart's diagnostic naming the package and the entry.
    """
    refusal = fetch_hosted_archive(ctx, scan_hosted_archive, walk_hosted_package)
    if refusal:
        fail(refusal)

def _read_spoke_pubspec(ctx):
    """Parses the extracted `pubspec.yaml` into spoke inputs.

    Returns `struct(bazel_deps, language_version, plugin_block,
    asset_block)`: the lock-filtered dependency names, the derived language
    version, and the parsed `flutter.plugin` / `flutter` asset blocks
    (absent-pubspec defaults when no pubspec was extracted).
    """
    bazel_deps, language_version = [], ""
    plugin_block = struct(
        present = False,
        platforms = {},
        implements = "",
        ffi_plugin = False,
    )
    asset_block = struct(
        fonts = [],
        assets = [],
        shaders = [],
        uses_material_design = False,
        asset_errors = [],
    )
    pubspec_path = ctx.path("pubspec.yaml")
    if pubspec_path.exists:
        pubspec_content = ctx.read(pubspec_path)
        sdk_err = pubspec_sdk_constraint_error(pubspec_content, ctx.attr.package_name + "/pubspec.yaml")
        if sdk_err:
            fail(sdk_err)
        all_deps = parse_pubspec_deps(pubspec_content)
        available = {p: True for p in ctx.attr.lock_packages}
        bazel_deps = sorted([d for d in all_deps if d in available])
        language_version = derive_language_version(parse_pubspec_sdk_constraint(pubspec_content))
        plugin_block = parse_flutter_plugin_block(pubspec_content)
        asset_block = parse_flutter_assets_block(pubspec_content)
    return struct(
        bazel_deps = bazel_deps,
        language_version = language_version,
        plugin_block = plugin_block,
        asset_block = asset_block,
    )

def check_spoke_file_names(package_name, asset_block, expanded):
    """Fail the spoke fetch on declared or walked names no target can name.

    Every refused class (see `check_spoke_file_name`) fails here, naming
    the package, the declaring entry and the file rather than emitting a
    spoke that cannot name them. Trailing-slash directory declarations are
    covering entries, never emitted target names, so only the files walked
    out of them are checked (with the declaration in the message).

    Args:
        package_name: The pub package the entries come from.
        asset_block: The parsed `flutter` block (assets, fonts, shaders).
        expanded: The walked asset files, each with a `path` field.

    Returns:
        None; fails the fetch on the first unemittable name.
    """
    for entry in asset_block.assets:
        if not entry.path.endswith("/"):
            check_spoke_file_name(package_name, entry.path, entry.path)
    lookup = covering_entry_lookup(asset_block.assets)
    for item in expanded:
        check_spoke_file_name(package_name, covering_entry(lookup, item.path), item.path)
    for family in asset_block.fonts:
        for font in family.fonts:
            check_spoke_file_name(package_name, "flutter.fonts[" + family.family + "]", font.asset)
    for shader in asset_block.shaders:
        check_spoke_file_name(package_name, shader.path, shader.path)

def _spoke_asset_inputs(ctx, package_name, asset_block):
    """Pre-computes the pub-asset generator inputs, used by either branch.

    Every entry is normalized through `asset_uri.bzl` first (see
    `normalize_asset_uri`): labels name the decoded files while every dict
    carries the encoded bundle keys flutter_tools bundles
    (`asset.dart:1425-1428`). A spelling flutter_tools would not bundle
    fails the fetch naming the package, its pubspec.yaml and the entry.

    Returns `struct(fonts_json_str, font_files, pkg_assets,
    pkg_asset_platforms, pkg_asset_flavors, pkg_shaders,
    has_contributions)`.
    """
    check_asset_entry_problems(package_name, asset_block.asset_errors)
    assets = normalize_spoke_assets(package_name, asset_block.assets)
    fonts = normalize_spoke_fonts(package_name, asset_block.fonts)
    shaders = normalize_spoke_shaders(package_name, asset_block.shaders)
    spoke_fonts = encode_spoke_fonts(fonts)
    expansion = expand_pub_asset_entries(
        assets,
        ctx_package_lister(ctx, package_name),
        package_name,
    )
    if expansion.error:
        fail(expansion.error)
    expanded = expansion.expanded
    check_spoke_file_names(package_name, struct(assets = assets, fonts = fonts, shaders = shaders), expanded)
    pkg_assets_dict = build_pkg_assets_dict(expanded)
    pkg_asset_platforms, pkg_asset_flavors = _build_pkg_asset_conditions(expanded, package_name)
    pkg_shaders_dict = build_pkg_shaders_dict(shaders)
    return struct(
        fonts_json_str = spoke_fonts.fonts_json_str,
        font_files = spoke_fonts.font_files,
        pkg_assets = pkg_assets_dict,
        pkg_asset_platforms = pkg_asset_platforms,
        pkg_asset_flavors = pkg_asset_flavors,
        pkg_shaders = pkg_shaders_dict,
        has_contributions = (
            bool(asset_block.fonts) or bool(asset_block.assets) or bool(asset_block.shaders)
        ),
    )

def _write_overlay_spoke(ctx, overlay_content, overlay_android_content):
    """Emits an overlay's BUILD content, replacing auto-generation entirely.

    When the overlay ships an `android/BUILD.bazel.tpl`, it is used
    verbatim. Otherwise an empty stub is emitted so the hub's
    `android/all_android_plugin_libs` aggregator can depend on
    `@<spoke>//android:lib` uniformly across overlay-and-no-Android
    plugins (audio_session declares Android sources and ships the full
    sub-package; objective_c is pure Apple and gets the stub).
    """
    ctx.file("BUILD.bazel", overlay_content)
    if overlay_android_content:
        ctx.file("android/BUILD.bazel", overlay_android_content)
    else:
        ctx.file(
            "android/BUILD.bazel",
            make_android_subpackage_build_content(
                android_src_dir = "",
                java_package = "",
                extra_maven_labels = [],
            ),
        )

def _detect_desktop_plugin_sources(ctx, package_name, plugin_block):
    """Detects Linux/Windows sources when pluginClass is set on that platform.

    The plugin's own `linux/`/`windows/` directory is the canonical
    location. Returns `struct(linux, windows)`.
    """
    linux_info = plugin_block.platforms.get("linux", {})
    windows_info = plugin_block.platforms.get("windows", {})
    linux_src_dir, windows_src_dir = "", ""
    if linux_info and linux_info.get("pluginClass", ""):
        linux_src_dir = _detect_desktop_source_dir(ctx, package_name, "linux")
    if windows_info and windows_info.get("pluginClass", ""):
        windows_src_dir = _detect_desktop_source_dir(ctx, package_name, "windows")
    return struct(linux = linux_src_dir, windows = windows_src_dir)

def _build_plugin_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook):
    """Builds a `flutter_plugin` spoke and its Android sub-package inputs."""
    package_name = ctx.attr.package_name
    apple = _detect_apple_plugin_sources(ctx, package_name, pubspec.plugin_block)
    desktop = _detect_desktop_plugin_sources(ctx, package_name, pubspec.plugin_block)
    plugin_platforms_json = json.encode(pubspec.plugin_block.platforms)
    build_content = make_flutter_plugin_build_content(
        name = package_name,
        deps = dep_labels,
        language_version = pubspec.language_version,
        version = ctx.attr.version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = unreplaced_hook,
        plugin_platforms_json = plugin_platforms_json,
        apple_macos_srcs_dirs = apple.macos_srcs,
        apple_ios_srcs_dirs = apple.ios_srcs,
        apple_macos_include_dirs = apple.macos_includes,
        apple_ios_include_dirs = apple.ios_includes,
        apple_macos_privacy_manifests = apple.macos_manifests,
        apple_ios_privacy_manifests = apple.ios_manifests,
        linux_src_dir = desktop.linux,
        windows_src_dir = desktop.windows,
        fonts_json_str = assets.fonts_json_str,
        font_files = assets.font_files,
        pkg_assets = assets.pkg_assets,
        pkg_asset_platforms = assets.pkg_asset_platforms,
        pkg_asset_flavors = assets.pkg_asset_flavors,
        pkg_shaders = assets.pkg_shaders,
        plugin_defines = ctx.attr.plugin_defines,
    )
    build_content = apply_apple_native_deps(ctx, package_name, apple, build_content)
    return struct(
        build_content = build_content,
        android_plugin = bool(pubspec.plugin_block.platforms.get("android", {})),
    )

def _build_library_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook):
    """Builds a `flutter_library` spoke for asset/font/shader contributions.

    No plugin block, but the pubspec has flutter.fonts/assets/shaders:
    a `flutter_library` (rather than `dart_library`) so the metadata
    propagates via FlutterInfo.pub_fonts/pub_assets/pub_shaders to the
    consuming app's bundle aggregator.
    """
    build_content = make_flutter_library_build_content(
        name = ctx.attr.package_name,
        deps = dep_labels,
        language_version = pubspec.language_version,
        version = ctx.attr.version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = unreplaced_hook,
        fonts_json_str = assets.fonts_json_str,
        font_files = assets.font_files,
        pkg_assets = assets.pkg_assets,
        pkg_asset_platforms = assets.pkg_asset_platforms,
        pkg_asset_flavors = assets.pkg_asset_flavors,
        pkg_shaders = assets.pkg_shaders,
    )
    return struct(build_content = build_content, android_plugin = False)

def _build_dart_spoke_content(ctx, pubspec, dep_labels, unreplaced_hook):
    """Builds a plain `dart_library` spoke via rules_dart's generator."""
    build_content = make_dart_library_build_content(
        name = ctx.attr.package_name,
        deps = dep_labels,
        language_version = pubspec.language_version,
        code_assets = ctx.attr.code_assets,
        has_unreplaced_hook = unreplaced_hook,
        version = ctx.attr.version,
    )
    if ctx.attr.package_name == "test":
        ctx.file("flutter_test_package.bzl", _FLUTTER_TEST_PACKAGE_BZL_CONTENT)
        build_content = build_content.replace(
            '    "dart_test_package",\n',
            "",
        ).replace(
            "dart_test_package(",
            'load(":flutter_test_package.bzl", "flutter_test_package")\n\nflutter_test_package(',
        )
    return struct(build_content = build_content, android_plugin = False)

def _build_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook):
    """Builds the spoke BUILD content for whichever branch the pubspec selects.

    Returns `struct(build_content, android_plugin)`: `android_plugin` says
    whether the package declares an `android` platform, so the follow-up
    `android/BUILD.bazel` aliases its lazy Android repository instead of an
    empty stub.
    """
    if pubspec.plugin_block.present:
        return _build_plugin_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook)
    if assets.has_contributions:
        return _build_library_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook)
    return _build_dart_spoke_content(ctx, pubspec, dep_labels, unreplaced_hook)

def _flutter_pub_package_impl(ctx):
    _fetch_pub_archive(ctx)
    _generate_spoke(ctx)

def link_scoped_tree_bounded(ctx, node, repo_rel, package_name, package_realpath, workspace_realpath, linked, bound):
    """Mirror one real source directory into the spoke, reporting leftovers.

    Traversal core of the path-package link walk (the `ctx.symlink` /
    `ctx.watch` calls are the only effects): unit tests drive it with a
    small bound and a fake directory listing. Returns True when
    directories are left unvisited, and the caller fails the fetch.

    This is the case-sensitive entry point the walk tests pin; the fetch
    itself builds a link scope (see `make_link_scope`) and runs
    `mirror_tree_bounded` directly.

    Args:
        ctx: The path-package spoke's repository context.
        node: The workspace-side source directory node.
        repo_rel: The spoke-relative path the directory mirrors to.
        package_name: The pub package linked, for refusals.
        package_realpath: The resolved package directory, for cycle checks.
        workspace_realpath: The resolved workspace root, for confinement.
        linked: Dict of already-linked spoke paths, updated in place.
        bound: Maximum directory pops; tests drive this small.

    Returns:
        True when directories are left unvisited at the bound.
    """
    scope = make_link_scope(package_name, package_realpath, workspace_realpath, False, linked)
    seed = (str(node.realpath),)
    result = mirror_tree_bounded(ctx, [(node, repo_rel, seed, repo_rel)], scope, bound)
    if result.error:
        fail(result.error)
    return result.leftover

def path_spoke_platform_dirs(plugin_block):
    """The platform directories the spoke generator reads for a plugin.

    Pure testable core of the link plan: a declared platform's directory
    is where the generator probes for manifests, Gradle files, and native
    sources, so only declared platforms get linked.

    Args:
        plugin_block: The parsed plugin block (or `_EMPTY_PLUGIN`).

    Returns:
        The sorted platform directory names to link, possibly empty.
    """
    platforms = plugin_block.platforms
    dirs = []
    if "android" in platforms:
        dirs.append("android")
    if "ios" in platforms or "macos" in platforms:
        dirs.extend(["darwin", "ios", "macos"])
    if "linux" in platforms:
        dirs.append("linux")
    if "windows" in platforms:
        dirs.append("windows")
    return sorted(dirs)

def parse_pubspec_identity(content):
    """The `(name, version)` identity a path spoke verifies against its lock entry.

    A path package's overlays and curated code assets are selected by the
    lock key and the lock's version, so the spoke must check that the
    package's own pubspec.yaml agrees — otherwise a directory whose
    pubspec names another package, or whose version moved since the lock
    was resolved, gets another package's overlay and native code assets.

    A pubspec with no `version:` field (or an empty one) reads as
    `"0.0.0"` — exactly how `pub get` locks it (pub's `Version.none`), so
    unversioned `publish_to: none` packages agree with the lock. The
    comparison itself is semantic (see `parse_pub_version`): quoting,
    surrounding whitespace and the YAML scalar type do not matter.

    Args:
        content: Full pubspec.yaml content as a string.

    Returns:
        A `struct(name, version)` of strings; the name is `""` when
        absent, unparsable, or not a scalar, and the version is `"0.0.0"`
        when unstated. A missing pubspec therefore never matches a lock
        key and fails closed at the caller's comparison.
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

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub and the lock key.
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

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub, the lock key, and both values.
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

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub, the lock key, and both values.
    A pubspec with no `version:` field reads as `0.0.0` (the way `pub get`
    locks it), so an unversioned package shows `0.0.0` on the pubspec side
    here when the lock moved on.
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

    Either side can be bad: the lock entry or the package's own pubspec.
    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the hub, the lock key, and the bad value.
    """
    return (
        "flutter.pub hub \"" + hub_name + "\": path dependency \"" +
        package_name + "\" has malformed version \"" + bad_value + "\" " +
        "in its pubspec.yaml or the lock entry. Versions are " +
        "major.minor.patch with optional -pre-release and +build (a " +
        "pubspec with no `version:` field reads as \"0.0.0\"); fix the " +
        "version or re-resolve the lock."
    )

def _fail_on_pubspec_identity_mismatch(hub_name, package_name, lock_version, pubspec_text):
    """Fail when the package's pubspec name or version disagrees with the lock.

    Overlays and curated code assets are selected by the lock key and the
    lock's version, so a directory whose pubspec names another package, or
    whose version moved since the lock was resolved, must not silently get
    another package's overlay and native code assets. Each mismatch fails
    naming the hub, the lock key, and both values, telling the user to
    re-resolve. The two versions compare as parsed semantic versions (a
    missing pubspec version reads as `0.0.0`, like `pub get` locks it); an
    unparsable version on either side fails naming the bad value.
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

def link_path_package(ctx):
    """Symlinks a workspace-local `path:` package into the spoke, hermetically.

    The link plan parses the package's own `pubspec.yaml` from the spoke:
    `lib/`, the pubspec, hook scripts, declared assets/fonts/shaders (plus
    each shader's own directory), and the plugin's platform directories are
    mirrored one file at a time into real repository directories — never
    whole-directory symlinks, not even for a directory that arrives as a
    symlink (linked directories resolve, confine, cycle-check, and mirror
    file by file with watched entries) — so the generator's `ctx.file`
    writes land in the spoke, never in the user tree. `example/`, `build/`,
    `.dart_tool/`, dot-directories, undeclared files, and user BUILD files
    stay unlinked (skipped top-level subtrees are not even watched, while
    every declared path is watched before testing whether it exists, so
    creating it later refetches the spoke). Refused, naming the package
    and the offending node, because each would break the hermetic fetch:
    source links resolving to the package or an ancestor (fetch-time walk
    cycles), a symlink cycle anywhere in the mirrored tree, and the package
    directory itself, any of its parent components, or any replicated
    symlink resolving outside the workspace's real root (host bytes in the
    bundle). Path comparisons fold case exactly when the fetch host proves
    case-insensitive. The pubspec's own `name` and `version` must match the
    lock entry, since overlays and code assets are selected by lock name
    and version (a pubspec with no `version:` field reads as `0.0.0`, the
    way `pub get` locks it, and the two versions compare as parsed semantic
    versions). Fails closed: an absolute path, a `..` escape, or a missing
    directory fails the fetch rather than emitting an empty spoke or
    reaching outside the workspace.

    Args:
        ctx: The path-package spoke's repository context. Reads `path`,
            `package_name`, `version`, and `hub_name` from its attrs.

    Returns:
        None.
    """
    root = path_package_root(ctx)
    src = root.src
    package_name = ctx.attr.package_name
    scope = make_link_scope(
        package_name,
        root.package_realpath,
        root.workspace_realpath,
        root.case_insensitive,
        {},
    )

    # The pubspec leads: link it first, then parse the spoke-side copy for
    # the link plan, so the spoke links only what the generator reads or
    # exposes. A missing pubspec parses as empty rather than failing: the
    # spoke pipeline reports the real problem.
    link_scoped_file_entry(ctx, src, "pubspec.yaml", scope)
    pubspec_node = ctx.path("pubspec.yaml")
    pubspec_text = ctx.read(pubspec_node) if pubspec_node.exists else ""
    _fail_on_pubspec_identity_mismatch(ctx.attr.hub_name, package_name, ctx.attr.version, pubspec_text)
    link_spoke_contents(
        ctx,
        src,
        normalize_spoke_asset_block(package_name, parse_flutter_assets_block(pubspec_text)),
        path_spoke_platform_dirs(parse_flutter_plugin_block(pubspec_text)),
        scope,
    )
    ctx.watch(src)

def _flutter_pub_path_package_impl(ctx):
    link_path_package(ctx)
    _generate_spoke(ctx)

def _generate_spoke(ctx):
    """Runs the shared spoke pipeline: pubspec in, BUILD content out.

    The Android half is never read here. An Android plugin's
    `android/BUILD.bazel` is only an alias to its Lazily fetched Android
    repository; every other package keeps the empty stub the hub aggregator
    depends on. Overlays that ship `android/BUILD.bazel.tpl` keep replacing
    both exactly as before.
    """
    pubspec = _read_spoke_pubspec(ctx)
    cycle_result = apply_cycle_breaks(ctx.attr.package_name, pubspec.bazel_deps, ctx.attr.cycle_breaks)
    if cycle_result.error:
        fail(cycle_result.error)

    # Build full label strings for sibling spoke repos.
    dep_labels = spoke_dep_labels(ctx, cycle_result.dependencies, pubspec.asset_block)

    # Pre-compute the pub-asset attr inputs once. Used by either branch
    # below (plugin vs library).
    assets = _spoke_asset_inputs(ctx, ctx.attr.package_name, pubspec.asset_block)

    # Computed once, before the branch: which generator runs depends on the
    # pubspec, but a build hook is a property of the package either way.
    unreplaced_hook = _detect_unreplaced_hook(ctx)

    # Try overlays first (user-supplied roots win over the bundled
    # `@rules_flutter//ext/` tree). On match, the overlay replaces
    # auto-generation entirely; the user takes responsibility for the
    # spoke's BUILD content.
    overlay_content, overlay_android_content = resolve_overlay_roots(
        ctx,
        ctx.attr.overlay_roots,
        ctx.attr.package_name,
        ctx.attr.version,
        pubspec.language_version,
        dep_labels,
    )

    has_deps = bool(ctx.attr.plugin_native_deps) and not overlay_content
    apple = _detect_apple_plugin_sources(ctx, ctx.attr.package_name, pubspec.plugin_block) if has_deps else None
    check_plugin_defines(ctx, ctx.attr.package_name, pubspec.plugin_block, bool(overlay_content))
    check_plugin_native_deps(ctx, ctx.attr.package_name, apple, bool(overlay_content))

    if overlay_content:
        _write_overlay_spoke(ctx, overlay_content, overlay_android_content)
        return

    spoke = _build_spoke_content(ctx, pubspec, dep_labels, assets, unreplaced_hook)
    ctx.file("BUILD.bazel", spoke.build_content)

    # Always emit `android/BUILD.bazel`. An Android plugin gets only an alias
    # to its own Android repository, so this fetch never reads the package's
    # Android directory or its Gradle build; Bazel fetches and analyses that
    # repository only when an Android target analyses the alias. Every other
    # package keeps the empty stub the hub aggregator depends on.
    if spoke.android_plugin:
        android_build_content = android_spoke_alias_content(
            android_package_repo_name(ctx.attr.hub_name, ctx.attr.package_name),
        )
    else:
        android_build_content = make_android_subpackage_build_content(
            android_src_dir = "",
            java_package = "",
            extra_maven_labels = [],
        )
    ctx.file("android/BUILD.bazel", android_build_content)

_FLUTTER_TEST_PACKAGE_BZL_CONTENT = """\
load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart/private:dart_test_runner.bzl",
    "DartTestRunnerInfo",
    "DartTestRunnerSnapshotInfo",
)

def _flutter_test_package_impl(ctx):
    library = ctx.attr.library
    dills = [f for f in ctx.attr.runner[DefaultInfo].files.to_list() if f.extension == "dill"]
    if len(dills) != 1:
        fail("%s: `runner` must produce exactly one `.dill`, got %s" % (ctx.label, dills))
    runner = dills[0]
    if ctx.attr.snapshot != None:
        snapshot = ctx.attr.snapshot[DartTestRunnerSnapshotInfo].snapshot
        if snapshot != None:
            runner = snapshot
    return [
        library[DefaultInfo],
        library[DartInfo],
        DartTestRunnerInfo(runner = runner),
    ]

flutter_test_package = rule(
    implementation = _flutter_test_package_impl,
    attrs = {
        "library": attr.label(
            doc = "The `package:test` `dart_library`.",
            mandatory = True,
            providers = [DartInfo],
        ),
        "runner": attr.label(
            doc = "A kernel-mode `dart_binary` built from `library`.",
            mandatory = True,
        ),
        "snapshot": attr.label(
            doc = "A `dart_test_runner_snapshot` of `runner`. Its snapshot runs in place of the kernel when one was built.",
            providers = [DartTestRunnerSnapshotInfo],
        ),
    },
    doc = "`package:test` as a dependency, carrying the runner built from it.",
)
"""

flutter_pub_package = repository_rule(
    implementation = _flutter_pub_package_impl,
    attrs = dict(pub_spoke_swiftpm_rule_attrs({
        "package_name": attr.string(
            doc = "The pub.dev package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive. Taken from the hosted lock entry; an empty value fails the fetch.",
            default = "",
        ),
        "base_url": attr.string(
            doc = "Base URL for the pub repository.",
            default = "https://pub.dev",
        ),
        "hub_name": attr.string(
            doc = "Name of the hub repo (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All hosted package names in the lock file (for dep filtering).",
            default = [],
        ),
        "cycle_breaks": attr.string_list(doc = "Dependency names whose spoke-to-spoke edge is left out of this package's `deps`; each must be a dependency its own pubspec declares. Empty drops nothing.", default = []),
        "plugin_defines": plugin_defines_attr,
        "code_assets": attr.string_list(
            doc = "Labels of `dart_code_asset` targets standing in for this " +
                  "package's build hook. Resolved by the extension from " +
                  "rules_dart's curated registry, so a user depending on, say, " +
                  "`drift` never names `sqlite3`. Attached to the generated " +
                  "package target rather than to the application, which is what " +
                  "makes them propagate the way pub's own assets do.",
            default = [],
        ),
        "ignore_hook": attr.bool(
            doc = "Treat this package's build hook as irrelevant. Without it, a " +
                  "package shipping a hook that nothing replaces is recorded and " +
                  "the application that reaches it fails, rather than building " +
                  "cleanly and dying at runtime on an unresolved native symbol.",
            default = False,
        ),
        "android_maven_deps": _maven_deps_attr,
        "android_maven_ignore": _maven_ignore_attr,
        "overlay_roots": attr.label_list(
            doc = "BUILD.bazel anchors for overlay trees. Each label points at " +
                  "an `ext/BUILD.bazel` (or equivalent) that anchors a directory " +
                  "tree of `<package>/<version>/BUILD.bazel.tpl` overrides. The " +
                  "rule walks the roots in order and uses the first match. " +
                  "User-supplied roots come before the bundled " +
                  "`@rules_flutter//ext:BUILD.bazel`.",
            allow_files = True,
            default = [],
        ),
    }), pubspec_lock = attr.label(doc = "Hub `pubspec.lock` label.", allow_single_file = True, default = None)),
    doc = "Downloads a single Flutter pub package and emits a `flutter_plugin` (when `flutter.plugin` is present) or a plain `dart_library` (otherwise). When Apple sources are detected, also emits per-platform `flutter_apple_plugin_library` sub-targets. Honors per-package overlay BUILD.bazel.tpl overrides under `overlay_roots`. The `flutter pub get` analog of `pub_lock_package`.",
)

flutter_pub_path_package = repository_rule(
    implementation = _flutter_pub_path_package_impl,
    attrs = dict(pub_spoke_swiftpm_rule_attrs({
        "package_name": attr.string(
            doc = "The pub package name.",
            mandatory = True,
        ),
        "path": attr.string(
            doc = "Workspace-relative directory of the package (the lock's `path:` value, relative to the lock file). Symlinked in; absolute paths and `..` escapes fail the fetch, as does anything — the package directory, its parent components, or a replicated symlink — resolving outside the workspace's real root.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version, when the lock states one. Empty stays " +
                  "unstated and never conflicts, matching the hosted rule.",
            default = "",
        ),
        "hub_name": attr.string(
            doc = "Name of the hub repo (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All package names in the lock file (for dep filtering).",
            default = [],
        ),
        "cycle_breaks": attr.string_list(doc = "Dependency names whose spoke-to-spoke edge is left out of this package's `deps`, same as `flutter_pub_package`.", default = []),
        "plugin_defines": plugin_defines_attr,
        "code_assets": attr.string_list(
            doc = "Labels of `dart_code_asset` targets standing in for this " +
                  "package's build hook, same as `flutter_pub_package`.",
            default = [],
        ),
        "ignore_hook": attr.bool(
            doc = "Treat this package's build hook as irrelevant, same as " +
                  "`flutter_pub_package`.",
            default = False,
        ),
        "android_maven_deps": _maven_deps_attr,
        "android_maven_ignore": _maven_ignore_attr,
        "overlay_roots": attr.label_list(
            doc = "BUILD.bazel anchors for overlay trees, same as " +
                  "`flutter_pub_package`.",
            allow_files = True,
            default = [],
        ),
    }), pubspec_lock = attr.label(doc = "Hub `pubspec.lock` label.", allow_single_file = True, default = None)),
    doc = "Symlinks a workspace-local `path:` pub package into a spoke and emits the same `flutter_plugin` / `flutter_library` / `dart_library` the hosted rule would. The `flutter pub get` analog for path dependencies: hermetic (workspace-relative only, watched for changes) and fail-closed on anything resolving outside the workspace's real root; the package's pubspec `name` and `version` must match the lock entry, since overlays and code assets are selected by lock name and version.",
)
