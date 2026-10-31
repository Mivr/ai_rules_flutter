"""Repository rule for merged Flutter SCC spokes.

Materialises strongly connected components of pub packages into a single
repository with multi-package dart_library and per-member targets carrying
Flutter assets, fonts, shaders, and plugins.
"""

load("@rules_dart//dart/pub:pinned_sources.bzl", "pinned_source_error")
load(
    "@rules_dart//dart/pub:pub_lock_package.bzl",
    "derive_language_version",
    "trim_gzip_trailing_nulls",
)
load(
    "@rules_dart//dart/pub:pub_scan.bzl",
    "check_package_symlinks",
    "run_pub_archive_scan",
)
load(
    "@rules_dart//dart/pub:pub_scc.bzl",
    "scc_member_deps_error",
    "scc_members_connectivity_error",
    "scc_planned_deps_error",
)
load(
    "@rules_dart//dart/pub:yaml_parser.bzl",
    "parse_pubspec_deps",
    "parse_pubspec_sdk_constraint",
    "pubspec_sdk_constraint_error",
)
load(
    "//flutter/private:asset_uri.bzl",
    "normalize_spoke_asset_block",
    "normalize_spoke_assets",
    "normalize_spoke_fonts",
    "normalize_spoke_shaders",
)
load("//flutter/private:download.bzl", "pinned_download")
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "has_files_under",
)
load(
    "//flutter/private:flutter_pub_assets.bzl",
    "asset_lister",
    "check_asset_entry_problems",
    "expand_pub_asset_entries",
)
load(
    "//flutter/private:flutter_pub_cycle_breaks.bzl",
    "apply_cycle_breaks",
)
load(
    "//flutter/private:flutter_pub_mirror.bzl",
    "detect_case_insensitive_host",
    "link_scoped_file_entry",
    "link_spoke_contents",
    "make_link_scope",
    "path_spoke_resolves_outside",
)
load(
    "//flutter/private:flutter_pub_package.bzl",
    "build_pkg_assets_dict",
    "build_pkg_shaders_dict",
    "check_spoke_file_names",
    "encode_spoke_fonts",
    "path_spoke_platform_dirs",
    "resolve_overlay_roots",
)
load(
    "//flutter/private:flutter_pub_package_helpers.bzl",
    "build_pkg_asset_conditions",
    "check_pubspec_identity_mismatch",
)
load(
    "//flutter/private:flutter_pub_scc_build.bzl",
    "make_scc_member_android_build_content",
    "make_scc_member_build_content",
    "make_scc_merged_spoke_build_content",
)
load(
    "//flutter/private:flutter_pubspec.bzl",
    "parse_flutter_assets_block",
    "parse_flutter_plugin_block",
)
load(
    "//flutter/private:gradle.bzl",
    "detect_android_namespace",
    "detect_android_native_build",
    "detect_consumer_proguard_specs",
    "resolve_plugin_maven_deps",
)

_APPLE_SRC_EXTENSIONS = ("swift", "m", "mm", "h")
_ANDROID_SRC_EXTENSIONS = ("kt", "java")

def _fetch_hosted_scc_member(ctx, member, name):
    err = pinned_source_error(
        "hosted",
        name,
        member.get("version", ""),
        sha256 = member.get("sha256", ""),
        rule = "flutter_pub_scc_package",
    )
    if err:
        fail(err)
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = member.get("url", "https://pub.dev"),
        name = name,
        version = member["version"],
    )
    archive = "_" + name + ".tar.gz"
    pinned_download(ctx, url = url, output = archive, sha256 = member["sha256"].strip())
    raw = ctx.read(archive, watch = "no")
    trimmed = trim_gzip_trailing_nulls(raw)
    if trimmed != raw:
        ctx.delete(archive)
        ctx.file(archive, trimmed, executable = False)
    run_pub_archive_scan(ctx, archive, name)
    ctx.extract(archive, output = name)
    ctx.delete(archive)
    check_package_symlinks(ctx, name, root = name)

def _link_path_scc_member(ctx, member, name):
    rel = member.get("path", "")
    if rel.startswith("/") or rel in ("", "."):
        fail("flutter.pub SCC member \"%s\": invalid path %r" % (name, rel))
    segments = rel.split("/")
    if ".." in segments or "." in segments or "" in segments:
        fail("flutter.pub SCC member \"%s\": path %r escapes workspace" % (name, rel))
    src = ctx.workspace_root.get_child(*segments)
    if not src.exists:
        fail("flutter.pub SCC member \"%s\": path %r does not exist" % (name, rel))
    ws_real = str(ctx.workspace_root.realpath)
    if path_spoke_resolves_outside(ws_real, str(src.realpath), False):
        fail("flutter.pub SCC member \"%s\": path %r resolves outside workspace" % (name, rel))
    case_insensitive = detect_case_insensitive_host(ctx, segments)
    scope = make_link_scope(name, str(src.realpath), ws_real, case_insensitive, {}, dest_prefix = name)
    link_scoped_file_entry(ctx, src, "pubspec.yaml", scope)
    pubspec_node = ctx.path(name + "/pubspec.yaml")
    pubspec_text = ctx.read(pubspec_node) if pubspec_node.exists else ""
    check_pubspec_identity_mismatch(ctx.attr.hub_name, name, member.get("version", ""), pubspec_text)
    link_spoke_contents(
        ctx,
        src,
        normalize_spoke_asset_block(name, parse_flutter_assets_block(pubspec_text)),
        path_spoke_platform_dirs(parse_flutter_plugin_block(pubspec_text)),
        scope,
    )
    ctx.watch(src)

def _detect_member_apple(ctx, name):
    macos_srcs = []
    ios_srcs = []
    for plat, srcs_list in [("macos", macos_srcs), ("ios", ios_srcs)]:
        sp_dir = "{name}/{plat}/{pkg}/Sources/{pkg}".format(name = name, plat = plat, pkg = name)
        if has_files_under(ctx, sp_dir, _APPLE_SRC_EXTENSIONS, name):
            srcs_list.append(sp_dir[len(name) + 1:])
        dw_dir = name + "/darwin/Classes"
        if has_files_under(ctx, dw_dir, _APPLE_SRC_EXTENSIONS, name):
            srcs_list.append("darwin/Classes")
        lg_dir = "{name}/{plat}/Classes".format(name = name, plat = plat)
        if has_files_under(ctx, lg_dir, _APPLE_SRC_EXTENSIONS, name):
            srcs_list.append(lg_dir[len(name) + 1:])
    macos_inc = [d + "/include" for d in macos_srcs if ctx.path(name + "/" + d + "/include").exists]
    ios_inc = [d + "/include" for d in ios_srcs if ctx.path(name + "/" + d + "/include").exists]
    macos_priv = [
        d + "/PrivacyInfo.xcprivacy"
        for d in macos_srcs
        if ctx.path(name + "/" + d + "/PrivacyInfo.xcprivacy").exists
    ]
    ios_priv = [
        d + "/PrivacyInfo.xcprivacy"
        for d in ios_srcs
        if ctx.path(name + "/" + d + "/PrivacyInfo.xcprivacy").exists
    ]
    return struct(
        macos_srcs = macos_srcs,
        ios_srcs = ios_srcs,
        macos_includes = macos_inc,
        ios_includes = ios_inc,
        macos_privacy = macos_priv,
        ios_privacy = ios_priv,
    )

def _detect_member_android(ctx, name, plugin_block):
    android_info = plugin_block.platforms.get("android", {})
    if not android_info or not android_info.get("pluginClass", ""):
        return struct(
            src_dir = "",
            java_package = "",
            extra_maven_labels = [],
            manifest = "",
            consumer_proguard_specs = [],
            has_resources = False,
            native_build = False,
        )
    src_dir = ""
    if has_files_under(ctx, name + "/android/src/main", _ANDROID_SRC_EXTENSIONS, name):
        src_dir = "android/src/main"
    has_res = has_files_under(ctx, name + "/android/src/main/res", None, name)
    manifest = ""
    if ctx.path(name + "/android/src/main/AndroidManifest.xml").exists:
        manifest = "android/src/main/AndroidManifest.xml"

    gradle_file = name + "/android/build.gradle"
    if not ctx.path(gradle_file).exists:
        gradle_file = name + "/android/build.gradle.kts"
    build_path = gradle_file if ctx.path(gradle_file).exists else ""
    build_content = ctx.read(build_path) if build_path else ""

    java_pkg = detect_android_namespace(ctx, build_path, build_content) or android_info.get("package", "")
    native_build = detect_android_native_build(ctx, build_path, build_content) if build_path else False
    proguard_specs = detect_consumer_proguard_specs(ctx, build_path, build_content) if build_path else []
    maven_labels = resolve_plugin_maven_deps(ctx, build_path, build_content) if build_path else []

    return struct(
        src_dir = src_dir,
        java_package = java_pkg,
        extra_maven_labels = maven_labels,
        manifest = manifest,
        consumer_proguard_specs = proguard_specs,
        has_resources = has_res,
        native_build = native_build,
    )

def _detect_member_desktop(ctx, name, plugin_block):
    linux_info = plugin_block.platforms.get("linux", {})
    windows_info = plugin_block.platforms.get("windows", {})
    linux_dir = ""
    if linux_info and linux_info.get("pluginClass", "") and ctx.path(name + "/linux").exists:
        linux_dir = "linux"
    windows_dir = ""
    if windows_info and windows_info.get("pluginClass", "") and ctx.path(name + "/windows").exists:
        windows_dir = "windows"
    return struct(linux = linux_dir, windows = windows_dir)

def _member_readdir(ctx, name):
    def readdir(rel_dir):
        path_str = name if rel_dir == "" else name + "/" + rel_dir
        node = ctx.path(path_str)
        if not node.exists:
            return []
        return [struct(name = child.basename, is_dir = child.is_dir) for child in node.readdir()]

    return readdir

def _member_asset_inputs(ctx, name, asset_block):
    if not (asset_block.assets or asset_block.fonts or asset_block.shaders):
        return struct(
            fonts_json_str = "",
            font_files = {},
            pkg_assets = {},
            pkg_shaders = {},
            pkg_asset_platforms = {},
            pkg_asset_flavors = {},
        )
    check_asset_entry_problems(name, asset_block.asset_errors)
    norm_assets = normalize_spoke_assets(name, asset_block.assets)
    fonts = normalize_spoke_fonts(name, asset_block.fonts)
    shaders = normalize_spoke_shaders(name, asset_block.shaders)
    spoke_fonts = encode_spoke_fonts(fonts)
    list_dir = asset_lister(_member_readdir(ctx, name), name)
    expansion = expand_pub_asset_entries(norm_assets, list_dir, name)
    if expansion.error:
        fail(expansion.error)
    expanded = expansion.expanded
    check_spoke_file_names(name, struct(assets = norm_assets, fonts = fonts, shaders = shaders), expanded)
    pkg_assets_dict = build_pkg_assets_dict(expanded)
    pkg_asset_platforms, pkg_asset_flavors = build_pkg_asset_conditions(expanded, name)
    pkg_shaders_dict = build_pkg_shaders_dict(shaders)
    return struct(
        fonts_json_str = spoke_fonts.fonts_json_str,
        font_files = spoke_fonts.font_files,
        pkg_assets = pkg_assets_dict,
        pkg_asset_platforms = pkg_asset_platforms,
        pkg_asset_flavors = pkg_asset_flavors,
        pkg_shaders = pkg_shaders_dict,
    )

def _stage_scc_members(ctx, members):
    for m in members:
        if m.get("source", "hosted") == "path":
            _link_path_scc_member(ctx, m, m["name"])
        else:
            _fetch_hosted_scc_member(ctx, m, m["name"])

def _parse_and_verify_scc_members(ctx, members):
    parsed = {}
    real_deps = {}
    for m in members:
        name = m["name"]
        pubspec_text = ctx.read(name + "/pubspec.yaml") if ctx.path(name + "/pubspec.yaml").exists else ""
        sdk_err = pubspec_sdk_constraint_error(pubspec_text, name + "/pubspec.yaml")
        if sdk_err:
            fail(sdk_err)
        planned = m.get("planned_deps", None)
        err = scc_planned_deps_error(ctx.attr.repo_name, name, planned)
        if err:
            fail(err)
        raw_deps = sorted(parse_pubspec_deps(pubspec_text))
        applied = apply_cycle_breaks(name, raw_deps, ctx.attr.cycle_breaks.get(name, []))
        if applied.error:
            fail(applied.error)
        real_deps[name] = applied.dependencies
        err = scc_member_deps_error(ctx.attr.repo_name, name, planned, real_deps[name])
        if err:
            fail(err)
        parsed[name] = struct(
            pubspec_text = pubspec_text,
            language_version = derive_language_version(parse_pubspec_sdk_constraint(pubspec_text)),
            version = m.get("version", ""),
            code_assets = m.get("code_assets", []),
        )

    err = scc_members_connectivity_error(ctx.attr.repo_name, real_deps)
    if err:
        fail(err)
    return parsed, real_deps

def _member_apple_aliases(name, apple, desktop):
    aliases = []
    if apple.macos_srcs:
        aliases.append(
            ('alias(name = "%s_apple_macos", ' +
             'actual = "//%s:%s_apple_macos", visibility = ["//visibility:public"])') % (
                name,
                name,
                name,
            ),
        )
        aliases.append(
            ('alias(name = "%s_apple_macos_xtool", ' +
             'actual = "//%s:%s_apple_macos_xtool", visibility = ["//visibility:public"])') % (
                name,
                name,
                name,
            ),
        )
    if apple.ios_srcs:
        aliases.append(
            ('alias(name = "%s_apple_ios", ' +
             'actual = "//%s:%s_apple_ios", visibility = ["//visibility:public"])') % (
                name,
                name,
                name,
            ),
        )
        aliases.append(
            ('alias(name = "%s_apple_ios_xtool", ' +
             'actual = "//%s:%s_apple_ios_xtool", visibility = ["//visibility:public"])') % (
                name,
                name,
                name,
            ),
        )
    if desktop.linux:
        aliases.append(
            ('alias(name = "%s_linux", ' +
             'actual = "//%s:%s_linux", visibility = ["//visibility:public"])') % (
                name,
                name,
                name,
            ),
        )
    if desktop.windows:
        aliases.append(
            ('alias(name = "%s_windows", ' +
             'actual = "//%s:%s_windows", visibility = ["//visibility:public"])') % (
                name,
                name,
                name,
            ),
        )
    return aliases

def _emit_single_member_build(
        ctx,
        name,
        p,
        plugin_block,
        asset_block,
        apple,
        desktop,
        android):
    assets = _member_asset_inputs(ctx, name, asset_block)
    plugin = struct(
        platforms_json = json.encode(plugin_block.platforms) if plugin_block.present else "",
        defines = ctx.attr.ios_plugin_defines.get(name, []),
    )

    member_build = make_scc_member_build_content(
        package_name = name,
        language_version = p.language_version,
        version = p.version,
        plugin = plugin,
        assets = assets,
        apple = apple,
        desktop = desktop,
    )
    ctx.file(name + "/BUILD.bazel", member_build)

    _, overlay_android_content = resolve_overlay_roots(
        ctx,
        ctx.attr.overlay_roots,
        name,
        p.version,
        p.language_version,
        [],
    )

    android_build = make_scc_member_android_build_content(
        package_name = name,
        version = p.version,
        android = android,
        native_build = android.native_build,
        overlay_content = overlay_android_content,
    )
    ctx.file(name + "/android/BUILD.bazel", android_build)

def _emit_scc_member_builds(ctx, member_names, parsed, real_deps):
    outside_deps = {}
    uses_material = False
    apple_aliases = []

    for name in member_names:
        p = parsed[name]
        asset_block = parse_flutter_assets_block(p.pubspec_text)
        if asset_block and getattr(asset_block, "uses_material_design", False):
            uses_material = True
        plugin_block = parse_flutter_plugin_block(p.pubspec_text)

        for dep in real_deps[name]:
            if dep not in parsed and dep in ctx.attr.lock_packages:
                fallback = "@{hub}__{dep}//:{dep}".format(hub = ctx.attr.hub_name, dep = dep)
                label = ctx.attr.scc_targets.get(dep, fallback)
                outside_deps[label] = True

        apple = _detect_member_apple(ctx, name)
        desktop = _detect_member_desktop(ctx, name, plugin_block)
        android = _detect_member_android(ctx, name, plugin_block)

        apple_aliases.extend(_member_apple_aliases(name, apple, desktop))
        _emit_single_member_build(ctx, name, p, plugin_block, asset_block, apple, desktop, android)

    return outside_deps, apple_aliases, uses_material

def _emit_scc_root_build(ctx, member_names, outside_deps, apple_aliases, uses_material, parsed):
    outside_list = sorted(outside_deps.keys())
    if uses_material:
        outside_list.append("@rules_flutter//flutter:material_icons")
    if "flutter" in ctx.attr.lock_packages and "flutter" not in parsed:
        flutter_label = "@" + ctx.attr.hub_name + "__flutter//:flutter"
        if flutter_label not in outside_list:
            outside_list.append(flutter_label)

    ctx.file("BUILD.bazel", make_scc_merged_spoke_build_content(
        repo_name = ctx.attr.repo_name,
        members = member_names,
        dep_labels = sorted(outside_list),
        apple_aliases = sorted(apple_aliases),
    ))

def _flutter_pub_scc_package_impl(ctx):
    members = json.decode(ctx.attr.members_json)
    _stage_scc_members(ctx, members)
    parsed, real_deps = _parse_and_verify_scc_members(ctx, members)
    member_names = sorted(parsed.keys())
    outside_deps, apple_aliases, uses_material = _emit_scc_member_builds(
        ctx,
        member_names,
        parsed,
        real_deps,
    )
    _emit_scc_root_build(
        ctx,
        member_names,
        outside_deps,
        apple_aliases,
        uses_material,
        parsed,
    )

flutter_pub_scc_package = repository_rule(
    implementation = _flutter_pub_scc_package_impl,
    attrs = {
        "repo_name": attr.string(
            mandatory = True,
            doc = "The merged repository name.",
        ),
        "package_name": attr.string(
            default = "",
            doc = "Package name; satisfies gradle helper call graph.",
        ),
        "hub_name": attr.string(
            mandatory = True,
            doc = "The flutter.pub hub name.",
        ),
        "members_json": attr.string(
            mandatory = True,
            doc = "JSON-encoded member specs.",
        ),
        "lock_packages": attr.string_list(
            default = [],
            doc = "All packages in the lock scope.",
        ),
        "scc_targets": attr.string_dict(
            default = {},
            doc = "Map of package name to merged target.",
        ),
        "cycle_breaks": attr.string_list_dict(
            default = {},
            doc = "Package dependency edges to drop.",
        ),
        "ios_plugin_defines": attr.string_list_dict(
            default = {},
            doc = "Preprocessor defines for Apple plugins.",
        ),
        "overlay_roots": attr.label_list(
            default = [],
            doc = "Plugin overlay roots.",
        ),
        "ignore_hooks": attr.string_list(
            default = [],
            doc = "Packages whose build hooks are ignored.",
        ),
        "android_maven_deps": attr.string_dict(
            default = {},
            doc = "Maven coordinates to label mapping.",
        ),
        "android_maven_ignore": attr.string_list(
            default = [],
            doc = "Maven coordinates to ignore.",
        ),
        "package_resolved": attr.label(
            allow_single_file = True,
            default = None,
            doc = "SwiftPM Package.resolved label.",
        ),
        "package_sha256": attr.label(
            allow_single_file = True,
            default = None,
            doc = "SwiftPM Package.resolved sha256 label.",
        ),
        "ios_native_deps": attr.label(
            allow_single_file = True,
            default = None,
            doc = "SwiftPM native deps mapping label.",
        ),
        "pubspec_lock": attr.label(
            allow_single_file = True,
            default = None,
            doc = "pubspec.lock label.",
        ),
    },
    doc = "Merged spoke repository rule for multi-package strongly connected components.",
)
