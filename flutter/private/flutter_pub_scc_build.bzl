"""BUILD file content generators for merged SCC spoke repositories.

Renders root spoke BUILD files, member BUILD files, and member android/BUILD.bazel
targets for strongly connected component (SCC) pub packages.
"""

load(
    "//flutter/private:flutter_pub_apple.bzl",
    "apple_plugin_targets",
    "desktop_plugin_target",
    "plugin_apple_libs_arg",
    "plugin_extra_loads",
    "plugin_privacy_files_arg",
)
load(
    "//flutter/private:flutter_pub_package.bzl",
    "make_android_subpackage_build_content",
)
load(
    "//flutter/private:flutter_pub_package_helpers.bzl",
    "make_android_native_build_unsupported_content",
)
load("//flutter/private:starlark_literal.bzl", "starlark_string_literal")

def make_scc_merged_spoke_build_content(repo_name, members, dep_labels, apple_aliases = []):
    """Generates the root BUILD.bazel content of a merged SCC spoke repository.

    Args:
        repo_name: The spoke repository name.
        members: Sorted list of member names in the SCC.
        dep_labels: Dependencies leaving the SCC.
        apple_aliases: Optional alias declarations for Apple/desktop targets.

    Returns:
        The content string for the root BUILD.bazel file.
    """
    member_lines = ['        "//{m}:{m}",'.format(m = m) for m in members]
    members_block = "    members = [\n{}\n    ],\n".format("\n".join(member_lines))

    deps_block = ""
    if dep_labels:
        dep_lines = ['        "{}",'.format(dep) for dep in dep_labels]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    scc_member_info_lines = ['        "//{m}:_flutter_info",'.format(m = m) for m in members]
    scc_members_block = "    scc_members = [\n{}\n    ],\n".format("\n".join(scc_member_info_lines))

    targets = []
    for m in members:
        targets.append("""flutter_pub_scc_member_target(
    name = "{m}",
    package_name = "{m}",
    library = ":merged",
{scc_members}{deps}    visibility = ["//visibility:public"],
)""".format(
            m = m,
            scc_members = scc_members_block,
            deps = deps_block,
        ))

    alias_lines = [
        """alias(
    name = "{repo_name}",
    actual = ":merged",
    visibility = ["//visibility:public"],
)""".format(repo_name = repo_name),
    ]
    for alias_target in apple_aliases:
        alias_lines.append(alias_target)

    return """load("@rules_dart//dart:defs.bzl", "dart_library")
load(
    "@rules_flutter//flutter/private:flutter_pub_scc_target.bzl",
    "flutter_pub_scc_member_target",
)

dart_library(
    name = "merged",
{members}{deps})

{targets}

{aliases}
""".format(
        members = members_block,
        deps = deps_block,
        targets = "\n\n".join(targets),
        aliases = "\n\n".join(alias_lines),
    )

def format_scc_pub_attrs(assets):
    """Formats pub asset attributes for flutter_pub_scc_member_info.

    Args:
        assets: Asset metadata struct or None.

    Returns:
        Formatted Starlark attribute arguments string.
    """
    if not assets:
        return ""
    lines = []
    if assets.fonts_json_str:
        lines.append("    fonts_json = %s,\n" % starlark_string_literal(assets.fonts_json_str))
    if assets.font_files:
        lines.append("    font_files = {\n")
        for lbl in sorted(assets.font_files.keys()):
            lines.append("        %s: %s,\n" % (
                starlark_string_literal(lbl),
                starlark_string_literal(assets.font_files[lbl]),
            ))
        lines.append("    },\n")
    if assets.pkg_assets:
        lines.append("    pkg_assets = {\n")
        for lbl in sorted(assets.pkg_assets.keys()):
            lines.append("        %s: %s,\n" % (
                starlark_string_literal(lbl),
                starlark_string_literal(assets.pkg_assets[lbl]),
            ))
        lines.append("    },\n")
    if assets.pkg_shaders:
        lines.append("    pkg_shaders = {\n")
        for lbl in sorted(assets.pkg_shaders.keys()):
            lines.append("        %s: %s,\n" % (
                starlark_string_literal(lbl),
                starlark_string_literal(assets.pkg_shaders[lbl]),
            ))
        lines.append("    },\n")
    if getattr(assets, "pkg_asset_platforms", None):
        lines.append("    pkg_asset_platforms = %r,\n" % assets.pkg_asset_platforms)
    if getattr(assets, "pkg_asset_flavors", None):
        lines.append("    pkg_asset_flavors = %r,\n" % assets.pkg_asset_flavors)
    return "".join(lines)

def make_scc_member_build_content(
        package_name,
        language_version,
        version = "",
        plugin = None,
        assets = None,
        apple = None,
        desktop = None):
    """Generates the BUILD.bazel content for one member of an SCC spoke.

    Args:
        package_name: The member package name.
        language_version: The Dart language version.
        version: Optional package version string.
        plugin: Optional plugin metadata struct.
        assets: Optional asset inputs struct.
        apple: Optional Apple sources detection struct.
        desktop: Optional desktop plugin detection struct.

    Returns:
        The content string for the member BUILD.bazel file.
    """
    macos_srcs = apple.macos_srcs if apple else []
    ios_srcs = apple.ios_srcs if apple else []
    macos_inc = apple.macos_includes if apple else []
    ios_inc = apple.ios_includes if apple else []
    macos_priv = apple.macos_privacy if apple else []
    ios_priv = apple.ios_privacy if apple else []
    linux_src = desktop.linux if desktop else ""
    windows_src = desktop.windows if desktop else ""
    defines = plugin.defines if plugin else []
    platforms_json = plugin.platforms_json if plugin else ""

    extra_loads = plugin_extra_loads(macos_srcs, ios_srcs, linux_src, windows_src)
    extra_targets = []
    if macos_srcs:
        extra_targets.append(apple_plugin_targets(package_name, macos_srcs, macos_inc, "macos", defines))
    if ios_srcs:
        extra_targets.append(apple_plugin_targets(package_name, ios_srcs, ios_inc, "ios", defines))
    if linux_src:
        extra_targets.append(desktop_plugin_target(package_name, linux_src, "linux"))
    if windows_src:
        extra_targets.append(desktop_plugin_target(package_name, windows_src, "windows"))

    apple_libs_arg = plugin_apple_libs_arg(package_name, macos_srcs, ios_srcs)
    linux_libs_arg = '    linux_libs = [":{name}_linux"],\n'.format(name = package_name) if linux_src else ""
    windows_libs_arg = '    windows_libs = [":{name}_windows"],\n'.format(name = package_name) if windows_src else ""
    privacy_arg = plugin_privacy_files_arg(macos_priv, ios_priv)
    pub_attrs = format_scc_pub_attrs(assets)
    platforms_arg = ""
    if platforms_json:
        platforms_arg = "    plugin_platforms_json = %s,\n" % starlark_string_literal(platforms_json)

    version_arg = '    version = "%s",\n' % version if version else ""
    info_attrs = (
        platforms_arg + apple_libs_arg + linux_libs_arg +
        windows_libs_arg + privacy_arg + pub_attrs
    )

    return """load("@rules_dart//dart:defs.bzl", "dart_package_member")
load(
    "@rules_flutter//flutter/private:flutter_pub_scc_target.bzl",
    "flutter_pub_scc_member_info",
)
{extra_loads}
dart_package_member(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{version_arg}    package_name = "{name}",
    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
    language_version = "{language_version}",
    visibility = ["//visibility:public"],
)

flutter_pub_scc_member_info(
    name = "_flutter_info",
    package_name = "{name}",
{member_info_attrs}    visibility = ["//visibility:public"],
)

{extra_targets}
exports_files(glob(["**/*"], exclude = ["BUILD*", "WORKSPACE*"]))
""".format(
        name = package_name,
        version_arg = version_arg,
        language_version = language_version,
        extra_loads = extra_loads,
        member_info_attrs = info_attrs,
        extra_targets = "\n".join(extra_targets) + ("\n" if extra_targets else ""),
    )

def make_scc_member_android_build_content(
        package_name,
        version = "",
        android = None,
        native_build = False,
        overlay_content = ""):
    """Generates <m>/android/BUILD.bazel content for one member of an SCC spoke.

    Args:
        package_name: The member package name.
        version: Optional package version string.
        android: Optional Android plugin metadata struct.
        native_build: Whether native build files were detected.
        overlay_content: Optional overlay content override.

    Returns:
        The content string for the member android/BUILD.bazel file.
    """
    if overlay_content:
        return overlay_content
    if native_build:
        return make_android_native_build_unsupported_content(package_name, version)
    if android and (android.src_dir or android.has_resources):
        return make_android_subpackage_build_content(
            android_src_dir = android.src_dir,
            java_package = android.java_package,
            extra_maven_labels = android.extra_maven_labels,
            android_manifest = android.manifest,
            consumer_proguard_specs = android.consumer_proguard_specs,
            has_resources = android.has_resources,
        )
    return """load("@rules_java//java:java_library.bzl", "java_library")

java_library(
    name = "lib",
    srcs = [],
    visibility = ["//visibility:public"],
)
"""
