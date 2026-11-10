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

load(":flutter_apple_plugin_defines.bzl", "dedupe_plugin_defines")
load(
    ":flutter_pub_apple.bzl",
    "apple_swiftpm_keeps_dep",
    "apple_swiftpm_labels_for_products",
    "apple_swiftpm_read_pins",
    "apple_swiftpm_read_product_deps",
    "detect_apple_swiftpm_deps",
    "with_apple_swiftpm_deps",
)
load(":flutter_pub_apple_byname.bzl", "apple_swiftpm_names_product")
load(
    ":flutter_pub_apple_local_refusal.bzl",
    "local_append_reached",
    "local_dep_applies",
    "local_manifest_decision",
    "local_primary_target",
    "local_seed_products",
    "local_special_error",
    "local_target_by_name",
    "local_target_dir",
    _parse_plugin_local_package = "parse_plugin_local_package",
)
load(
    ":flutter_pub_apple_local_targets.bzl",
    "local_library_name",
    "local_missing_dir_error",
    "local_settings_bundle",
    _render_local_target_blocks = "render_local_target_blocks",
    _with_apple_local_targets = "with_apple_local_targets",
)
load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "has_files_bound_error")
load(":podspec_read.bzl", "apply_apple_podspec_link_settings")
load(":podspec_read_xcconfig.bzl", "active_podspec_defines")
load(":swiftpm_package.bzl", "swiftpm_is_code_file", "swiftpm_select_target_files")
load(":swiftpm_translate.bzl", "swiftpm_c99name")

parse_plugin_local_package = _parse_plugin_local_package

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
    local = [getattr(other, "name", "").lower() for other in targets if getattr(other, "name", "")]
    for _ in range(len(targets) + 1):
        if not stack:
            break
        current = local_target_by_name(targets, stack.pop())
        for dep in getattr(current, "deps", []):
            if apple_swiftpm_names_product(dep, local):
                continue
            if getattr(dep, "kind", "") != "same" or not local_dep_applies(dep, platform):
                continue
            name = getattr(dep, "name", "")
            target = local_target_by_name(targets, name)
            if target == None:
                return "Flutter plugin %r: target %r depends on unknown target %r." % (plugin, getattr(current, "name", ""), name)
            refused = local_append_reached(plugin, target, reached, stack)
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
    error = local_seed_products(plugin, model, reached, stack)
    if error:
        return struct(ok = False, error = error, reached = {})
    refused = local_append_reached(plugin, primary, reached, stack)
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
            label = ":%s" % local_library_name(plugin, platform, name)
        edges.append(struct(text = label, platforms = platforms))
    return edges

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
    primary = local_primary_target(model, manifest_dir, primary_dir)
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
        target_dir = local_target_dir(manifest_dir, target)
        if getattr(target, "kind", "target") != "target":
            return struct(
                ok = False,
                error = local_special_error(plugin, target),
                targets = [],
                primary = primary,
            )
        settings = local_settings_bundle(target, target_dir)
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
            err = local_missing_dir_error(plugin, target.name, target.dir)
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

def render_local_target_blocks(plugin, platform, targets, files_by_target, plugin_defines = []):
    """Render one library per reached plugin-local target.

    Args:
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        targets: The `plugin_local_targets(...).targets` list.
        files_by_target: Dict of target name to the selector's result.
        plugin_defines: The plugin's `ios_plugin_defines` entries.

    Returns:
        `struct(ok, error, text, labels, xtool_files)`.
    """
    return _render_local_target_blocks(plugin, platform, targets, files_by_target, plugin_defines)

def _local_other_source_dirs(ctx, manifest_dir, primary_dir):
    """List the directories under a manifest's `Sources` besides the primary.

    Args:
        ctx: The spoke's repository context.
        manifest_dir: The manifest's package-relative directory.
        primary_dir: The primary source directory.

    Returns:
        The other directory paths, empty when `Sources` does not exist.
    """
    sources = ctx.path(manifest_dir + "/Sources")
    if not sources.exists:
        return []
    primary = str(ctx.path(primary_dir))
    return [str(e) for e in sources.readdir() if e.is_dir and str(e) != primary]

def _with_edges(target, labels):
    """Copy a local target struct with product labels added to its edges.

    Args:
        target: The `plugin_local_targets(...).targets` entry.
        labels: The product labels the target links.

    Returns:
        The same struct with one unconditional edge per label.
    """
    return struct(
        name = target.name,
        dir = target.dir,
        directory = target.directory,
        path = target.path,
        module_name = target.module_name,
        kind = target.kind,
        target = target.target,
        settings = target.settings,
        clang_settings = target.clang_settings,
        swift_settings = target.swift_settings,
        edges = target.edges + [struct(text = label, platforms = None) for label in labels],
    )

def _apple_local_product_links(ctx, plugin, platform, manifest_dir, model, targets):
    """Link the product dependencies of the reached non-primary targets.

    Args:
        ctx: The spoke's repository context, carrying the hub's resolved
            label, checksum-file label, native-deps label and name.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        manifest_dir: The manifest's package-relative directory.
        model: The parsed plugin manifest model.
        targets: The `plugin_local_targets(...).targets` list.

    Returns:
        `struct(ok, error, targets, labels)`: `targets` carry the product
        labels in their edges; `labels` lists every linked label once, for
        the primary library (the xtool backend compiles all targets as one).
    """
    local = [other.name.lower() for other in model.targets if other.name]
    pins = None
    product_deps = None
    out = []
    labels = []
    for target in targets:
        products = [
            dep
            for dep in target.target.deps
            if apple_swiftpm_names_product(dep, local) and apple_swiftpm_keeps_dep(dep, model.pkg_deps, platform)
        ]
        if not products:
            out.append(target)
            continue
        if pins == None:
            pins = apple_swiftpm_read_pins(ctx, ctx.attr.package_resolved, ctx.attr.package_sha256, ctx.attr.hub_name)
            product_deps = apple_swiftpm_read_product_deps(ctx, ctx.attr.ios_native_deps, ctx.attr.hub_name)
        prepared = struct(products = products, pkg_deps = model.pkg_deps, target = target.target)
        selected = apple_swiftpm_labels_for_products(
            plugin,
            manifest_dir,
            [target.dir],
            platform,
            pins,
            prepared,
            product_deps,
        )
        if not selected.ok:
            return struct(ok = False, error = selected.error, targets = [], labels = [])
        out.append(_with_edges(target, selected.labels))
        labels.extend([label for label in selected.labels if label not in labels])
    return struct(ok = True, error = "", targets = out, labels = labels)

def _detect_platform_local_targets(ctx, plugin, platform, srcs_dirs, podspec_defines):
    """Read and render one platform's plugin-local targets.

    Args:
        ctx: The spoke's repository context.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        srcs_dirs: The platform's detected source directories.
        podspec_defines: The platform podspec's static `GCC_PREPROCESSOR_DEFINITIONS`.

    Returns:
        `struct(ok, error, text, labels, xtool_files)`.
    """
    empty = struct(ok = True, error = "", text = "", labels = [], xtool_files = [])
    if not srcs_dirs:
        return empty
    user_defines = ctx.attr.plugin_defines if hasattr(ctx.attr, "plugin_defines") else []
    plugin_defines = dedupe_plugin_defines(podspec_defines + user_defines)
    for manifest_dir in [platform + "/" + plugin, "darwin/" + plugin]:
        manifest = manifest_dir + "/Package.swift"
        primary_dir = _local_primary_dir(manifest_dir, srcs_dirs)
        if not primary_dir or not ctx.path(manifest).exists:
            continue
        text = ctx.read(manifest)
        res = local_manifest_decision(
            plugin,
            text,
            parse_plugin_local_package(plugin, text),
            _local_other_source_dirs(ctx, manifest_dir, primary_dir),
        )
        if not res.ok:
            fail(res.error)
        parsed = res.parsed
        if not parsed.ok:
            continue
        locals = plugin_local_targets(plugin, parsed.model, manifest_dir, primary_dir, platform)
        if not locals.ok:
            fail(locals.error)
        if not locals.targets:
            continue
        linked = _apple_local_product_links(ctx, plugin, platform, manifest_dir, parsed.model, locals.targets)
        if not linked.ok:
            fail(linked.error)
        files = local_target_files(ctx, plugin, linked.targets)
        if not files.ok:
            fail(files.error)
        rendered = render_local_target_blocks(
            plugin,
            platform,
            linked.targets,
            files.files,
            plugin_defines = plugin_defines,
        )
        if not rendered.ok:
            fail(rendered.error)
        return struct(
            ok = True,
            error = "",
            text = rendered.text,
            labels = rendered.labels,
            xtool_files = rendered.xtool_files,
            product_labels = linked.labels,
        )
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
    if hasattr(ctx.attr, "plugin_native_deps") and ctx.attr.plugin_native_deps != None:
        empty = struct(ok = True, error = "", text = "", labels = [], xtool_files = [])
        return struct(macos = empty, ios = empty)
    return struct(
        macos = _detect_platform_local_targets(
            ctx,
            plugin,
            "macos",
            apple.macos_srcs,
            active_podspec_defines(apple, "macos"),
        ),
        ios = _detect_platform_local_targets(
            ctx,
            plugin,
            "ios",
            apple.ios_srcs,
            active_podspec_defines(apple, "ios"),
        ),
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
    content = apply_apple_podspec_link_settings(ctx, content, plugin, apple)
    swiftpm = detect_apple_swiftpm_deps(ctx, plugin, apple)
    local = detect_apple_local_targets(ctx, plugin, apple)
    macos_products = getattr(local.macos, "product_labels", [])
    ios_products = getattr(local.ios, "product_labels", [])
    content = with_apple_swiftpm_deps(
        content,
        plugin,
        swiftpm.macos + [label for label in macos_products if label not in swiftpm.macos],
        swiftpm.ios + [label for label in ios_products if label not in swiftpm.ios],
    )
    content = with_apple_local_targets(content, plugin, "macos", local.macos)
    return with_apple_local_targets(content, plugin, "ios", local.ios)

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
    return _with_apple_local_targets(content, plugin, platform, rendered)
