"""Plugin-local SwiftPM targets of a Flutter plugin's own `Package.swift`.

A Flutter plugin may split its native code over several same-package
targets: `image_picker_ios` keeps its pigeon types in an
`image_picker_ios_objc` target, and `video_player_avfoundation` has one
target per Apple platform. CocoaPods builds every target SwiftPM resolves;
the pub spoke used to build only the one target whose directory matched
`Sources/<pkg>`, so the others were never compiled.

This file walks the plugin manifest's library products and same-package
target dependencies, then renders one library per reached target. The
primary library depends on those libraries on the `rules_apple` backend;
on `xtool` their files join the one xtool library, matching xtool's
single-module compile. The walk keeps the manifest's target settings so
`.headerSearchPath`, `.define`, `exclude:` and `publicHeadersPath:` reach
the generated libraries exactly as they do for a hub SwiftPM package.
"""

load(
    ":flutter_pub_apple.bzl",
    "detect_apple_swiftpm_deps",
    "with_apple_swiftpm_deps",
)
load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "has_files_bound_error")
load(":starlark_literal.bzl", "starlark_string_literal")
load(":swiftpm_manifest.bzl", "parse_swiftpm_package")
load(":swiftpm_manifest_lex.bzl", "lex_swiftpm_manifest", "swiftpm_first_content_line")
load(":swiftpm_package.bzl", "swiftpm_is_code_file", "swiftpm_select_target_files")
load(":swiftpm_settings.bzl", "swiftpm_render_list_attr", "swiftpm_target_setting_entries")
load(":swiftpm_translate.bzl", "swiftpm_c99name")

_LOCAL_OBJC_MACRO_LOAD = (
    'load("@rules_flutter//flutter/private:flutter_apple_plugin_library.bzl", ' +
    '"flutter_apple_plugin_objc_library", "flutter_apple_plugin_objc_settings")'
)

_LOCAL_SPECIAL_KINDS = ["executableTarget", "binaryTarget", "systemLibrary", "plugin", "macro"]

_LOCAL_SKIPPED_ARGS = ["resources", "plugins", "defaultLocalization", "pkgConfig", "providers", "packageAccess"]

def _local_missing_dir_error(plugin, target_name, target_dir):
    """The refusal naming a target whose directory does not exist.

    Args:
        plugin: The pub plugin name.
        target_name: The manifest target name.
        target_dir: The directory that is missing on disk.

    Returns:
        The failure string, naming all three verbatim.
    """
    msg = "Flutter plugin %r: local target %r directory %r does not exist."
    return msg % (plugin, target_name, target_dir)

def _local_special_error(plugin, target):
    """Refuse reached targets whose kind rules_apple cannot build.

    Args:
        plugin: The pub plugin name, for messages.
        target: The reached target struct.

    Returns:
        The refusal string.
    """
    kind = getattr(target, "kind", "target")
    if kind == "binaryTarget":
        return "binary targets in plugin manifests land in POD-10"
    msg = "Flutter plugin %r: target %r has unsupported kind `%s`."
    return msg % (plugin, getattr(target, "name", ""), kind)

def _local_target_dir(manifest_dir, target):
    """The package-relative directory one manifest target lives in.

    Args:
        manifest_dir: The manifest's package-relative directory.
        target: The parsed target struct (`path`, `name`).

    Returns:
        The target directory.
    """
    path = getattr(target, "path", "")
    suffix = path if path else "Sources/" + getattr(target, "name", "")
    return manifest_dir + "/" + suffix

def _local_target_by_name(targets, name):
    """Find one target in the parsed manifest by its case-insensitive name.

    Args:
        targets: The parsed target list.
        name: The target name to search for.

    Returns:
        The target struct, or None when missing.
    """
    lower = name.lower()
    for target in targets:
        target_name = getattr(target, "name", "")
        if target_name == name or target_name.lower() == lower:
            return target
    return None

def _local_primary_target(model, manifest_dir, primary_dir):
    """Pick the manifest target matching the primary globbed directory.

    Args:
        model: The parsed plugin manifest model.
        manifest_dir: The manifest's package-relative directory.
        primary_dir: The package-relative directory the spoke globs.

    Returns:
        The primary target struct, or None when nothing matches.
    """
    for target in getattr(model, "targets", []):
        if getattr(target, "kind", "target") != "target":
            continue
        if _local_target_dir(manifest_dir, target) == primary_dir:
            return target
    return None

def _local_append_reached(plugin, target, reached, stack):
    """Mark one target reached and queue it for the same-dependency walk.

    Args:
        plugin: The pub plugin name, for messages.
        target: The target struct to visit.
        reached: The reached-name dict (mutated in place).
        stack: The pending-name list (mutated in place).

    Returns:
        "" or the refusal naming an untranslatable special target.
    """
    name = getattr(target, "name", "")
    if not name:
        return "Flutter plugin %r: a manifest target has no name." % plugin
    if name in reached:
        return ""
    kind = getattr(target, "kind", "target")
    if kind in _LOCAL_SPECIAL_KINDS:
        return _local_special_error(plugin, target)
    if kind == "testTarget":
        return "Flutter plugin %r: target %r depends on test target %r, which is ignored." % (plugin, plugin, name)
    reached[name] = name
    reached[name.lower()] = name
    stack.append(name)
    return ""

def _local_seed_products(plugin, model, reached, stack):
    """Seed reachability from every `.library` product's targets.

    Args:
        plugin: The pub plugin name, for messages.
        model: The parsed plugin manifest model.
        reached: The reached-name dict (mutated in place).
        stack: The pending-name list (mutated in place).

    Returns:
        "" or the refusal for an unknown or untranslatable target.
    """
    for product in getattr(model, "products", []):
        if getattr(product, "kind", "") != "library":
            continue
        for name in getattr(product, "targets", []):
            target = _local_target_by_name(getattr(model, "targets", []), name)
            if target == None:
                return "Flutter plugin %r: product %r names unknown target %r." % (plugin, getattr(product, "name", ""), name)
            refused = _local_append_reached(plugin, target, reached, stack)
            if refused:
                return refused
    return ""

def _local_dep_applies(dep, platform):
    """Whether one same-package dependency applies on a platform.

    Args:
        dep: The parsed dependency reference.
        platform: `"ios"` or `"macos"`.

    Returns:
        True when the dependency is built on the platform.
    """
    condition = getattr(dep, "condition", None)
    if condition == None:
        return True
    return platform in getattr(condition, "platforms", [])

def _local_follow_dependencies(plugin, model, reached, stack, platform):
    """Follow the queued targets' same-package dependencies.

    Args:
        plugin: The pub plugin name, for messages.
        model: The parsed plugin manifest model.
        reached: The reached-name dict (mutated in place).
        stack: The pending-name list (mutated in place).
        platform: `"ios"` or `"macos"`.

    Returns:
        "" or the refusal for an unknown or untranslatable target.
    """
    targets = getattr(model, "targets", [])
    for _ in range(len(targets) + 1):
        if not stack:
            break
        current = _local_target_by_name(targets, stack.pop())
        for dep in getattr(current, "deps", []):
            if getattr(dep, "kind", "") != "same" or not _local_dep_applies(dep, platform):
                continue
            name = getattr(dep, "name", "")
            target = _local_target_by_name(targets, name)
            if target == None:
                return "Flutter plugin %r: target %r depends on unknown target %r." % (plugin, getattr(current, "name", ""), name)
            refused = _local_append_reached(plugin, target, reached, stack)
            if refused:
                return refused
    return ""

def _local_walk_reachable(plugin, model, primary, platform):
    """Collect the library products and same-target dependencies reached.

    Args:
        plugin: The pub plugin name, for messages.
        model: The parsed plugin manifest model.
        primary: The primary target struct.
        platform: `"ios"` or `"macos"`.

    Returns:
        `struct(ok, error, reached)`: `reached` maps target names to True.
    """
    reached = {}
    stack = []
    error = _local_seed_products(plugin, model, reached, stack)
    if error:
        return struct(ok = False, error = error, reached = {})
    refused = _local_append_reached(plugin, primary, reached, stack)
    if refused:
        return struct(ok = False, error = refused, reached = {})
    error = _local_follow_dependencies(plugin, model, reached, stack, platform)
    if error:
        return struct(ok = False, error = error, reached = {})
    return struct(ok = True, error = "", reached = reached)

def _local_edges(plugin, platform, target, reached, primary_name):
    """The rendered same-package library labels one local target needs.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        target: The parsed target struct.
        reached: The reached-name dict.
        primary_name: The primary target's manifest name.

    Returns:
        The `struct(text, platforms)` dependency entries.
    """
    edges = []
    for dep in getattr(target, "deps", []):
        if getattr(dep, "kind", "") != "same":
            continue
        name = getattr(dep, "name", "")
        if name not in reached and name.lower() not in reached:
            continue
        condition = getattr(dep, "condition", None)
        platforms = getattr(condition, "platforms", None) if condition else None
        if platforms and platform not in platforms:
            continue
        if name == primary_name:
            label = ":%s_apple_%s" % (plugin, platform)
        else:
            label = ":%s" % _local_library_name(plugin, platform, name)
        edges.append(struct(text = label, platforms = platforms))
    return edges

def _local_library_name(plugin, platform, target_name):
    """The emitted Bazel library target name of one plugin-local target.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        target_name: The manifest target name.

    Returns:
        `<pkg>_apple_<plat>__<c99name>`.
    """
    return "%s_apple_%s__%s" % (plugin, platform, swiftpm_c99name(target_name))

def _apple_local_normalize_path(target_dir, name):
    """Resolve one `.headerSearchPath` against the target directory.

    Args:
        target_dir: The package-relative target directory.
        name: The manifest's search path.

    Returns:
        `struct(ok, path)`: `path` is package-relative when `ok`.
    """
    out = []
    for s in (target_dir + "/" + name).split("/"):
        if s and s != ".":
            if s == "..":
                if not out:
                    return struct(ok = False, path = "")
                out.pop()
            else:
                out.append(s)
    return struct(ok = True, path = "/".join(out))

def _apple_local_setting_entry(setting, target_dir):
    """Translate one C-family setting, folding a sibling search path.

    Args:
        setting: The parsed setting struct.
        target_dir: The package-relative target directory.

    Returns:
        `struct(ok, error, text, private_include, platforms)`.
    """
    cond = getattr(setting, "condition", None)
    plat = getattr(cond, "platforms", None) if cond else None
    if getattr(setting, "kind", "") == "headerSearchPath":
        p = _apple_local_normalize_path(target_dir, setting.name)
        if not p.ok:
            return struct(
                ok = False,
                error = "headerSearchPath(%r) escapes the repository" % setting.name,
                text = "",
                private_include = False,
                platforms = None,
            )
        return struct(
            ok = True,
            error = "",
            text = p.path,
            private_include = True,
            platforms = plat,
        )
    val = getattr(setting, "value", "")
    def_val = ("=" + val) if val else ""
    return struct(
        ok = True,
        error = "",
        text = "-D" + setting.name + def_val,
        private_include = False,
        platforms = plat,
    )

def _apple_local_setting_entries(settings, target_dir):
    """Translate a C-family setting list, allowing a sibling search path.

    Args:
        settings: The parsed `cSettings` or `cxxSettings` list.
        target_dir: The package-relative target directory.

    Returns:
        `struct(ok, error, flags, private_includes)`.
    """
    flags = []
    p_inc = []
    for s in settings:
        e = _apple_local_setting_entry(s, target_dir)
        if not e.ok:
            return struct(ok = False, error = e.error, flags = [], private_includes = [])
        bucket = p_inc if e.private_include else flags
        bucket.append(struct(text = e.text, platforms = e.platforms))
    return struct(ok = True, error = "", flags = flags, private_includes = p_inc)

def _apple_local_linkopts(settings):
    """Translate one target's `linkerSettings` list.

    Args:
        settings: The parsed `linkerSettings` list.

    Returns:
        The `struct(text, platforms)` link option entries.
    """
    linkopts = []
    for s in settings:
        cond = getattr(s, "condition", None)
        plat = getattr(cond, "platforms", None) if cond else None
        pfx = "-framework" if getattr(s, "kind", "") == "linkedFramework" else "-l"
        for v in ([pfx, s.name] if pfx == "-framework" else [pfx + s.name]):
            linkopts.append(struct(text = v, platforms = plat))
    return linkopts

def _apple_local_clang_settings(target, target_dir):
    """Translate a C-family local target whose search path leaves its dir.

    Args:
        target: The parsed target struct.
        target_dir: The package-relative target directory.

    Returns:
        `struct(ok, detail, c_only, cxx, copts, linkopts, private_includes)`.
    """
    c_fold = _apple_local_setting_entries(getattr(target, "c_settings", []), target_dir)
    cxx_fold = _apple_local_setting_entries(getattr(target, "cxx_settings", []), target_dir)
    if not c_fold.ok or not cxx_fold.ok:
        err = c_fold.error if not c_fold.ok else cxx_fold.error
        return struct(
            ok = False,
            detail = err,
            c_only = [],
            cxx = [],
            copts = [],
            linkopts = [],
            private_includes = [],
        )
    return struct(
        ok = True,
        detail = "",
        c_only = c_fold.flags,
        cxx = cxx_fold.flags,
        copts = [],
        linkopts = _apple_local_linkopts(getattr(target, "linker_settings", [])),
        private_includes = c_fold.private_includes + cxx_fold.private_includes,
    )

def _apple_local_target_settings(target, target_dir, kind):
    """Translate one local target's settings, reusing the shared translator.

    Args:
        target: The parsed target struct.
        target_dir: The package-relative target directory.
        kind: `"swift"` or `"clang"`.

    Returns:
        The shared translator's settings struct.
    """
    translated = swiftpm_target_setting_entries(target, target_dir, kind)
    if translated.ok or kind == "swift" or "escapes the target directory" not in translated.detail:
        return translated
    return _apple_local_clang_settings(target, target_dir)

def _local_settings_bundle(target, target_dir):
    """Translate both views of one local target's settings.

    Args:
        target: The parsed target struct.
        target_dir: The package-relative target directory.

    Returns:
        `struct(settings, clang_settings, swift_settings)`.
    """
    swift = _apple_local_target_settings(target, target_dir, "swift")
    clang = _apple_local_target_settings(target, target_dir, "clang")
    selected = clang
    c_settings = getattr(target, "c_settings", []) + getattr(target, "cxx_settings", [])
    if (not clang.ok and swift.ok) or (swift.ok and getattr(target, "swift_settings", []) and not c_settings):
        selected = swift
    return struct(settings = selected, clang_settings = clang, swift_settings = swift)

def plugin_local_targets(plugin, model, manifest_dir, primary_dir, platform):
    """Collect the reached same-package targets of one plugin manifest.

    Args:
        plugin: The pub plugin name, for messages.
        model: The parsed plugin manifest model.
        manifest_dir: The manifest's package-relative directory.
        primary_dir: The primary target's package-relative directory.
        platform: `"ios"` or `"macos"`.

    Returns:
        `struct(ok, error, targets, primary)`: `targets` holds the
        reached sibling targets in manifest order.
    """
    primary = _local_primary_target(model, manifest_dir, primary_dir)
    if primary == None:
        return struct(ok = True, error = "", targets = [], primary = None)
    primary_name = getattr(primary, "name", "")
    walked = _local_walk_reachable(plugin, model, primary, platform)
    if not walked.ok:
        return struct(ok = False, error = walked.error, targets = [], primary = primary)
    out = []
    for target in getattr(model, "targets", []):
        name = getattr(target, "name", "")
        if walked.reached.get(name) == None or name == primary_name:
            continue
        target_dir = _local_target_dir(manifest_dir, target)
        if getattr(target, "kind", "target") != "target":
            return struct(
                ok = False,
                error = _local_special_error(plugin, target),
                targets = [],
                primary = primary,
            )
        settings = _local_settings_bundle(target, target_dir)
        out.append(struct(
            name = name,
            dir = target_dir,
            directory = target_dir,
            path = target_dir,
            module_name = swiftpm_c99name(name),
            kind = getattr(target, "kind", "target"),
            target = target,
            settings = settings.settings,
            clang_settings = settings.clang_settings,
            swift_settings = settings.swift_settings,
            edges = _local_edges(plugin, platform, target, walked.reached, primary_name),
        ))
    return struct(ok = True, error = "", targets = out, primary = primary)

def _render_src_list(name, paths):
    """Render one `name = [...]` source attribute.

    Args:
        name: The attribute name.
        paths: The repo-relative file paths.

    Returns:
        The attribute text, empty when there is no path.
    """
    if not paths:
        return ""
    items = ["        %s," % starlark_string_literal(p) for p in paths]
    return "    %s = [\n%s\n    ]," % (name, "\n".join(items))

def _render_swift_local(plugin, platform, target, selected, settings):
    """Render one reached Swift target as a `flutter_apple_plugin_library`.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        target: The local target struct from `plugin_local_targets`.
        selected: The selector's `struct(srcs, ...)` for the target.
        settings: The Swift setting entries.

    Returns:
        The rule text.
    """
    lines = [
        "flutter_apple_plugin_library(",
        "    name = %s," % starlark_string_literal(_local_library_name(plugin, platform, target.name)),
        _render_src_list("srcs", getattr(selected, "srcs", [])),
        "    module_name = %s," % starlark_string_literal(target.module_name),
        "    platform = %s," % starlark_string_literal(platform),
    ]
    spec = (
        ("deps", target.edges),
        ("copts", getattr(settings, "copts", [])),
        ("linkopts", getattr(settings, "linkopts", [])),
    )
    for attr, entries in spec:
        rendered = swiftpm_render_list_attr(attr, [], entries)
        if rendered:
            lines.append(rendered)
    lines.extend(['    visibility = ["//visibility:public"],', ")"])
    return "\n".join([line for line in lines if line])

def _render_settings_struct(public_includes, settings):
    """Render the nested settings struct of one ObjC-only local library.

    Args:
        public_includes: The target's public header search directories.
        settings: The clang setting entries.

    Returns:
        The `settings = flutter_apple_plugin_objc_settings(...)` attribute text.
    """
    lines = ["    settings = flutter_apple_plugin_objc_settings("]
    entries = [
        ("includes", [struct(text = p, platforms = None) for p in public_includes]),
        ("conlyopts", getattr(settings, "c_only", [])),
        ("cxxopts", getattr(settings, "cxx", [])),
        ("linkopts", getattr(settings, "linkopts", [])),
        ("private_includes", getattr(settings, "private_includes", [])),
    ]
    for attr, values in entries:
        rendered = swiftpm_render_list_attr(attr, [], values)
        if rendered:
            lines.extend(["    " + line for line in rendered.split("\n")])
    lines.append("    ),")
    return "\n".join(lines)

def _local_public_includes(target, selected):
    """The public header search directory of one C-family local target.

    Args:
        target: The local target struct.
        selected: The selector's file struct.

    Returns:
        A one-element list when the target has public headers, else [].
    """
    if not getattr(selected, "public_hdrs", []):
        return []
    public_path = getattr(target.target, "public_headers_path", "")
    return [target.dir + "/" + (public_path if public_path else "include")]

def _render_objc_local(plugin, platform, target, selected, settings):
    """Render one reached C-family target as an ObjC-only library.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        target: The local target struct from `plugin_local_targets`.
        selected: The selector's file struct.
        settings: The clang setting entries.

    Returns:
        The macro-call text.
    """
    srcs = getattr(selected, "c_srcs", []) + getattr(selected, "private_hdrs", [])
    lines = [
        "flutter_apple_plugin_objc_library(",
        "    name = %s," % starlark_string_literal(_local_library_name(plugin, platform, target.name)),
        _render_src_list("srcs", srcs) or "    srcs = [],",
        _render_src_list("hdrs", getattr(selected, "public_hdrs", [])) or "    hdrs = [],",
        "    module_name = %s," % starlark_string_literal(target.module_name),
        "    platform = %s," % starlark_string_literal(platform),
    ]
    deps = swiftpm_render_list_attr("deps", [], target.edges)
    if deps:
        lines.append(deps)
    lines.extend([
        _render_settings_struct(_local_public_includes(target, selected), settings),
        '    visibility = ["//visibility:public"],',
        ")",
    ])
    return "\n".join(lines)

def _selected_xtool_files(selected):
    """Collect the compilable files a local target contributes to xtool.

    Args:
        selected: The selector's file struct.

    Returns:
        The file path list.
    """
    return (
        getattr(selected, "srcs", []) +
        getattr(selected, "c_srcs", []) +
        getattr(selected, "public_hdrs", []) +
        getattr(selected, "private_hdrs", [])
    )

def _settings_for(target, selected):
    """Pick the translated settings matching a target's source language.

    Args:
        target: The local target struct.
        selected: The selector's file struct.

    Returns:
        `struct(ok, detail, ...)`: the Swift or clang setting translation.
    """
    if getattr(selected, "srcs", []):
        s = getattr(target, "swift_settings", None)
        return s if s != None else _apple_local_target_settings(target.target, target.dir, "swift")
    s = getattr(target, "clang_settings", None)
    return s if s != None else _apple_local_target_settings(target.target, target.dir, "clang")

def _render_target_library(plugin, platform, target, selected):
    """Render one reached target by its selected source language.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        target: The local target struct.
        selected: The selector's file struct.

    Returns:
        `struct(ok, error, text)`.
    """
    settings = _settings_for(target, selected)
    if not getattr(settings, "ok", False):
        return struct(
            ok = False,
            error = "Flutter plugin %r: %s." % (plugin, getattr(settings, "detail", "unknown setting")),
            text = "",
        )
    if getattr(selected, "srcs", []):
        rendered_swift = _render_swift_local(plugin, platform, target, selected, settings)
        return struct(ok = True, error = "", text = rendered_swift)
    rendered_objc = _render_objc_local(plugin, platform, target, selected, settings)
    return struct(ok = True, error = "", text = rendered_objc)

def render_local_target_blocks(plugin, platform, targets, files_by_target):
    """Render one library per reached plugin-local target.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        targets: The `plugin_local_targets(...).targets` list.
        files_by_target: Dict of target name to the selector's result.

    Returns:
        `struct(ok, error, text, labels, xtool_files)`.
    """
    blocks = []
    labels = []
    xtool_files = []
    for target in targets:
        selected = files_by_target.get(target.name, files_by_target.get(target.name.lower()))
        if selected == None:
            err = _local_missing_dir_error(plugin, target.name, target.dir)
            return struct(ok = False, error = err, text = "", labels = [], xtool_files = [])
        if not getattr(selected, "ok", True):
            err = getattr(selected, "error", "unknown selector failure")
            return struct(ok = False, error = err, text = "", labels = [], xtool_files = [])
        if getattr(selected, "srcs", []) and getattr(selected, "c_srcs", []):
            err = "Flutter plugin %r: local target %r mixes Swift and C-family sources." % (plugin, target.name)
            return struct(ok = False, error = err, text = "", labels = [], xtool_files = [])
        rendered = _render_target_library(plugin, platform, target, selected)
        if not rendered.ok:
            return rendered
        blocks.append(rendered.text)
        labels.append(":" + _local_library_name(plugin, platform, target.name))
        xtool_files.extend(_selected_xtool_files(selected))
    return struct(
        ok = True,
        error = "",
        text = "\n\n".join(blocks),
        labels = labels,
        xtool_files = sorted(xtool_files),
    )

def _apple_local_read_tree(ctx, root, plugin):
    """Read a target directory into the selector's file and dir dicts.

    Args:
        ctx: The spoke's repository context.
        root: The package-relative target directory.
        plugin: The pub plugin name, for the bound failure.

    Returns:
        `struct(files, dirs)`: path dicts rooted at the repository.
    """
    files = {}
    dirs = {}
    stack = [root]
    for _ in range(PUB_WALK_BOUND):
        if not stack:
            break
        current = stack.pop()
        for child in ctx.path(current).readdir():
            full = current + "/" + child.basename
            if child.is_dir:
                dirs[full] = True
                stack.append(full)
            else:
                files[full] = True
    if stack:
        fail(has_files_bound_error(plugin, root, PUB_WALK_BOUND))
    return struct(files = files, dirs = dirs)

def _apple_local_code_files(files):
    """Keep the code and header files the selector translates.

    Args:
        files: The target tree's repo-relative file dict.

    Returns:
        The filtered path dict.
    """
    kept = {}
    for p in files:
        base = p[p.rfind("/") + 1:]
        if base.endswith(".swift") or swiftpm_is_code_file(base):
            kept[p] = True
    return kept

def local_target_files(ctx, plugin, targets):
    """Select each local target's sources from the spoke checkout.

    Args:
        ctx: The spoke's repository context.
        plugin: The pub plugin name.
        targets: The `plugin_local_targets(...).targets` list.

    Returns:
        `struct(ok, error, files)`: `files` maps target name to the
        selector's result, or `error` names the missing directory.
    """
    selected = {}
    for target in targets:
        root = ctx.path(target.dir)
        if not root.exists or not root.is_dir:
            err = _local_missing_dir_error(plugin, target.name, target.dir)
            return struct(ok = False, error = err, files = {})
        tree = _apple_local_read_tree(ctx, target.dir, plugin)
        result = swiftpm_select_target_files(
            plugin,
            target.target,
            target.dir,
            _apple_local_code_files(tree.files),
            tree.dirs,
        )
        if not result.ok:
            return struct(ok = False, error = result.error, files = {})
        selected[target.name] = result
    return struct(ok = True, error = "", files = selected)

def _token_depths(tokens):
    """The paren/bracket depth before each token.

    Args:
        tokens: The lexed manifest token list.

    Returns:
        The depth list, one entry per token.
    """
    depths = []
    depth = 0
    for token in tokens:
        depths.append(depth)
        if token.kind == "punct" and token.text in ("(", "["):
            depth += 1
        elif token.kind == "punct" and token.text in (")", "]"):
            depth -= 1
    return depths

def _is_keyword_argument(tokens, index, keywords):
    """True when token `index` opens a `keyword:` argument to drop.

    Args:
        tokens: The lexed manifest token list.
        index: The token to inspect.
        keywords: The argument names to drop.

    Returns:
        True for a matching word followed by a colon.
    """
    if tokens[index].kind != "word" or tokens[index].text not in keywords:
        return False
    return index + 1 < len(tokens) and tokens[index + 1].kind == "punct" and tokens[index + 1].text == ":"

def _skip_keyword_argument(tokens, depths, start):
    """Return the index one past one keyword argument's value.

    Args:
        tokens: The lexed manifest token list.
        depths: The per-token depth list from `_token_depths`.
        start: The keyword token's index.

    Returns:
        The index after the value's comma, or at its closing bracket.
    """
    target_depth = depths[start]
    i = start + 1
    for _ in range(len(tokens) + 1):
        if i >= len(tokens):
            break
        if depths[i] == target_depth and tokens[i].kind == "punct":
            if tokens[i].text == ",":
                return i + 1
            if tokens[i].text in (")", "]"):
                return i
        i += 1
    return i

def _strip_tokens(tokens, keywords):
    """Drop the skipped keyword arguments from a token list.

    Args:
        tokens: The lexed manifest token list.
        keywords: The argument names to drop.

    Returns:
        The token list without those arguments and their values.
    """
    depths = _token_depths(tokens)
    out = []
    i = 0
    for _ in range(len(tokens) + 1):
        if i >= len(tokens):
            break
        if _is_keyword_argument(tokens, i, keywords):
            i = _skip_keyword_argument(tokens, depths, i)
            continue
        out.append(tokens[i])
        i += 1
    return out

def _render_tokens(tokens):
    """Render a token list as manifest text the parser accepts.

    Args:
        tokens: The token list to render.

    Returns:
        The manifest body text.
    """
    parts = []
    for t in tokens:
        item = "\n" if t.kind == "nl" else ('"""' + t.text + '""" ' if t.kind == "str" else t.text + " ")
        parts.append(item)
    return "".join(parts)

def parse_plugin_local_package(plugin, text):
    """Parse a plugin manifest with target settings kept.

    Args:
        plugin: The pub plugin name, for messages.
        text: The `Package.swift` text.

    Returns:
        The strict parser's `struct(ok, error, model)`.
    """
    lexed = lex_swiftpm_manifest(text, plugin)
    if not lexed.ok:
        return struct(ok = False, error = lexed.error, model = None)
    first = swiftpm_first_content_line(text)
    if not first.ok:
        return struct(ok = False, error = first.error, model = None)
    stripped = _strip_tokens(lexed.tokens, _LOCAL_SKIPPED_ARGS)
    rendered = first.line + "\n" + _render_tokens(stripped)
    return parse_swiftpm_package(plugin, rendered)

def _local_primary_dir(manifest_dir, srcs_dirs):
    """Find the primary source directory belonging to one manifest.

    Args:
        manifest_dir: The manifest's package-relative directory.
        srcs_dirs: The platform's detected source directories.

    Returns:
        The first source directory under the manifest, or "".
    """
    for src_dir in srcs_dirs:
        if src_dir == manifest_dir or src_dir.startswith(manifest_dir + "/"):
            return src_dir
    return ""

def _detect_platform_local_targets(ctx, plugin, platform, srcs_dirs):
    """Read and render one platform's plugin-local targets.

    Args:
        ctx: The spoke's repository context.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        srcs_dirs: The platform's detected source directories.

    Returns:
        `struct(ok, error, text, labels, xtool_files)`.
    """
    empty = struct(ok = True, error = "", text = "", labels = [], xtool_files = [])
    if not srcs_dirs:
        return empty
    for manifest_dir in [platform + "/" + plugin, "darwin/" + plugin]:
        manifest = manifest_dir + "/Package.swift"
        primary_dir = _local_primary_dir(manifest_dir, srcs_dirs)
        if not primary_dir or not ctx.path(manifest).exists:
            continue
        parsed = parse_plugin_local_package(plugin, ctx.read(manifest))
        if not parsed.ok:
            continue
        locals = plugin_local_targets(plugin, parsed.model, manifest_dir, primary_dir, platform)
        if not locals.ok:
            fail(locals.error)
        if not locals.targets:
            continue
        files = local_target_files(ctx, plugin, locals.targets)
        if not files.ok:
            fail(files.error)
        rendered = render_local_target_blocks(plugin, platform, locals.targets, files.files)
        if not rendered.ok:
            fail(rendered.error)
        return rendered
    return empty

def detect_apple_local_targets(ctx, plugin, apple):
    """Detect and render the plugin-local targets of both Apple platforms.

    Args:
        ctx: The spoke's repository context.
        plugin: The pub plugin name.
        apple: The `detect_apple_plugin_sources` struct.

    Returns:
        `struct(macos, ios)`: each platform's rendered local targets.
    """
    return struct(
        macos = _detect_platform_local_targets(ctx, plugin, "macos", apple.macos_srcs),
        ios = _detect_platform_local_targets(ctx, plugin, "ios", apple.ios_srcs),
    )

def apply_apple_native_deps(ctx, plugin, apple, content):
    """Wire a plugin's SwiftPM products and local targets into its BUILD.

    Args:
        ctx: The spoke's repository context.
        plugin: The pub plugin name.
        apple: The `detect_apple_plugin_sources` struct.
        content: The rendered spoke BUILD content.

    Returns:
        The BUILD content with both kinds of Apple dependency wired in.
    """
    swiftpm = detect_apple_swiftpm_deps(ctx, plugin, apple)
    content = with_apple_swiftpm_deps(content, plugin, swiftpm.macos, swiftpm.ios)
    local = detect_apple_local_targets(ctx, plugin, apple)
    content = with_apple_local_targets(content, plugin, "macos", local.macos)
    return with_apple_local_targets(content, plugin, "ios", local.ios)

def _local_deps_block(labels):
    """Render one `deps = [...]` block for the primary library.

    Args:
        labels: The local library labels.

    Returns:
        The attribute text, ending in a newline.
    """
    items = ["        %s," % starlark_string_literal(label) for label in labels]
    return "    deps = [\n%s\n    ],\n" % "\n".join(items)

def _local_target_block(content, plugin, platform, suffix):
    """Split the rendered BUILD around one primary library target.

    Args:
        content: The rendered spoke BUILD content.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        suffix: `""` for the rules_apple library, `"_xtool"` for xtool.

    Returns:
        `struct(found, head, block, tail)`.
    """
    marker = '    name = "%s_apple_%s%s",\n' % (plugin, platform, suffix)
    head, sep, tail = content.partition(marker)
    if not sep:
        return struct(found = False, head = "", block = "", tail = "")
    block, vis_sep, vis_tail = tail.partition("\n    visibility = ")
    if not vis_sep:
        return struct(found = False, head = "", block = "", tail = "")
    return struct(found = True, head = head + sep, block = block, tail = vis_sep + vis_tail)

def _local_insert_into_list(block, attr, labels):
    """Add labels to an existing Bazel list attribute in one target block.

    Args:
        block: The target's attribute text.
        attr: The attribute name (`deps`, `srcs`).
        labels: The item strings to add.

    Returns:
        `struct(found, block)`.
    """
    marker = "    %s = " % attr
    start = block.find(marker)
    if start < 0:
        return struct(found = False, block = block)
    value_start = start + len(marker)
    rest = block[value_start:]
    additions = "\n".join(["        %s," % item for item in labels])
    if rest.startswith("[]"):
        return struct(found = True, block = block[:value_start] + "[\n" + additions + "\n    ]" + rest[2:])
    if rest.startswith("["):
        close = rest.find("\n    ]")
        if close < 0:
            return struct(found = False, block = block)
        patched_rest = rest[:close] + "\n" + additions + rest[close:]
        return struct(found = True, block = block[:value_start] + patched_rest)
    if rest.startswith("select("):
        return struct(found = True, block = block[:value_start] + "[\n" + additions + "\n    ] + " + rest)
    return struct(found = False, block = block)

def _patch_device_deps(content, plugin, platform, labels):
    """Add the local labels to the primary rules_apple library's deps.

    Args:
        content: The rendered spoke BUILD content.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        labels: The local library labels.

    Returns:
        The patched BUILD content.
    """
    parts = _local_target_block(content, plugin, platform, "")
    if not parts.found:
        fail("Flutter plugin %r: expected a `%s_apple_%s` library target for its local targets." % (plugin, plugin, platform))
    items = [starlark_string_literal(label) for label in labels]
    patched = _local_insert_into_list(parts.block, "deps", items)
    block = patched.block if patched.found else parts.block + "\n" + _local_deps_block(labels)
    return parts.head + block + parts.tail

def _patch_xtool_srcs(content, plugin, platform, files):
    """Append the local targets' files to the primary xtool library's srcs.

    Args:
        content: The rendered spoke BUILD content.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        files: The local target file paths.

    Returns:
        The patched BUILD content.
    """
    parts = _local_target_block(content, plugin, platform, "_xtool")
    if not parts.found:
        fail("Flutter plugin %r: expected a `%s_apple_%s_xtool` library target for its local targets." % (plugin, plugin, platform))
    items = [starlark_string_literal(path) for path in files]
    marker = "    srcs = "
    start = parts.block.find(marker)
    if start < 0:
        fail("Flutter plugin %r: expected `srcs` on `%s_apple_%s_xtool`." % (plugin, plugin, platform))
    value_start = start + len(marker)
    rest = parts.block[value_start:]
    additions = "\n".join(["        %s," % item for item in items])
    is_glob = rest.startswith("glob(")
    close_marker = "\n    )," if is_glob else "\n    ]"
    close = rest.find(close_marker)
    if close < 0:
        fail("Flutter plugin %r: malformed `srcs` on `%s_apple_%s_xtool`." % (plugin, plugin, platform))
    if is_glob:
        split_pos = close + len("\n    )")
        patched_rest = rest[:split_pos] + " + [\n" + additions + "\n    ]" + rest[split_pos:]
    elif rest.startswith("["):
        patched_rest = rest[:close] + "\n" + additions + rest[close:]
    else:
        fail("Flutter plugin %r: unsupported `srcs` on `%s_apple_%s_xtool`." % (plugin, plugin, platform))
    return parts.head + parts.block[:value_start] + patched_rest + parts.tail

def with_apple_local_targets(content, plugin, platform, rendered):
    """Splice one platform's local libraries into the rendered spoke BUILD.

    Args:
        content: The rendered spoke BUILD content.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        rendered: The platform's `render_local_target_blocks` result.

    Returns:
        The patched BUILD content.
    """
    if not rendered.text:
        return content
    content = content + "\n" + rendered.text
    content = _patch_device_deps(content, plugin, platform, rendered.labels)
    if rendered.xtool_files:
        content = _patch_xtool_srcs(content, plugin, platform, rendered.xtool_files)
    if "flutter_apple_plugin_objc_library(" in rendered.text and _LOCAL_OBJC_MACRO_LOAD not in content:
        content = _LOCAL_OBJC_MACRO_LOAD + "\n" + content
    return content
