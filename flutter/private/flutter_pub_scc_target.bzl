"""Rules for member info and targets in merged SCC spoke repositories.

A merged spoke combines strongly connected components of pub packages into a
single repository. Member targets expose Flutter assets, plugins, and Dart
libraries while avoiding target-level dependency cycles.
"""

load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo", "DartKernelInfo")
load("@rules_dart//dart:utils.bzl", "dart_analyzable_info")
load("@rules_swift//swift:swift.bzl", "SwiftInfo")
load(
    "//flutter:providers.bzl",
    "FlutterApplePluginInfo",
    "FlutterInfo",
)
load(
    "//flutter/private:flutter_desktop_plugin_info.bzl",
    "FlutterLinuxPluginInfo",
    "FlutterWindowsPluginInfo",
)
load(
    "//flutter/private:flutter_info.bzl",
    "flutter_asset_channels",
    "flutter_info",
    "flutter_plugin_libraries",
    "flutter_pub_channels",
)
load(
    "//flutter/private:flutter_library.bzl",
    "SKY_ENGINE_ATTR",
    "build_pub_contributions",
)
load(
    "//flutter/private:flutter_plugin.bzl",
    "build_plugin_struct",
)

def _flutter_pub_scc_member_info_impl(ctx):
    plugins = []
    if ctx.attr.plugin_platforms_json:
        plugins = [build_plugin_struct(
            name = ctx.attr.package_name,
            plugin_platforms = json.decode(ctx.attr.plugin_platforms_json),
        )]

    extra_apple = []
    for lib in ctx.attr.apple_libs:
        info = lib[FlutterApplePluginInfo] if FlutterApplePluginInfo in lib else None
        platform_name = info.platform if info else ""
        extra_apple.append(struct(
            platform = platform_name,
            label = lib.label,
            cc_info = lib[CcInfo] if CcInfo in lib else None,
            swift_info = lib[SwiftInfo] if SwiftInfo in lib else None,
            files = lib[DefaultInfo].files,
            sdk_frameworks = tuple(info.sdk_frameworks) if info else (),
            sdk_dylibs = tuple(info.sdk_dylibs) if info else (),
            package = ctx.attr.package_name,
        ))

    extra_linux = [
        struct(
            label = lib.label,
            headers = lib[FlutterLinuxPluginInfo].headers,
            shared_libraries = lib[FlutterLinuxPluginInfo].shared_libraries,
            package = ctx.attr.package_name,
        )
        for lib in ctx.attr.linux_libs
    ]

    extra_windows = [
        struct(
            label = lib.label,
            headers = lib[FlutterWindowsPluginInfo].headers,
            shared_libraries = lib[FlutterWindowsPluginInfo].shared_libraries,
            package = ctx.attr.package_name,
        )
        for lib in ctx.attr.windows_libs
    ]

    extra_pub_fonts, extra_pub_assets, extra_pub_shaders = build_pub_contributions(
        ctx.attr.package_name,
        ctx.attr.fonts_json,
        ctx.attr.font_files,
        ctx.attr.pkg_assets,
        ctx.attr.pkg_shaders,
        ctx.files.shader_includes,
        ctx.attr.pkg_asset_platforms,
        ctx.attr.pkg_asset_flavors,
    )

    return [
        flutter_info(
            deps = [],
            plugins = plugins,
            asset_channels = flutter_asset_channels(
                apple_privacy_manifests = list(ctx.files.apple_privacy_files),
            ),
            plugin_libraries = flutter_plugin_libraries(
                apple_plugin_libraries = extra_apple,
                linux_plugin_libraries = extra_linux,
                windows_plugin_libraries = extra_windows,
            ),
            pub_channels = flutter_pub_channels(
                pub_fonts = extra_pub_fonts,
                pub_assets = extra_pub_assets,
                pub_shaders = extra_pub_shaders,
            ),
        ),
    ]

flutter_pub_scc_member_info = rule(
    implementation = _flutter_pub_scc_member_info_impl,
    attrs = {
        "package_name": attr.string(
            mandatory = True,
            doc = "The member package name.",
        ),
        "plugin_platforms_json": attr.string(
            default = "",
            doc = "JSON-encoded flutter.plugin.platforms metadata.",
        ),
        "apple_libs": attr.label_list(
            providers = [CcInfo],
            default = [],
            doc = "Apple plugin libraries for this member.",
        ),
        "apple_privacy_files": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Apple PrivacyInfo.xcprivacy manifests.",
        ),
        "linux_libs": attr.label_list(
            providers = [FlutterLinuxPluginInfo],
            default = [],
            doc = "Linux plugin libraries.",
        ),
        "windows_libs": attr.label_list(
            providers = [FlutterWindowsPluginInfo],
            default = [],
            doc = "Windows plugin libraries.",
        ),
        "fonts_json": attr.string(
            default = "",
            doc = "JSON-encoded font definitions.",
        ),
        "font_files": attr.label_keyed_string_dict(
            allow_files = True,
            default = {},
            doc = "Font file label to path map.",
        ),
        "pkg_assets": attr.label_keyed_string_dict(
            allow_files = True,
            default = {},
            doc = "Asset file label to path map.",
        ),
        "pkg_shaders": attr.label_keyed_string_dict(
            allow_files = True,
            default = {},
            doc = "Shader file label to path map.",
        ),
        "shader_includes": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Shader include files.",
        ),
        "pkg_asset_platforms": attr.string_list_dict(
            default = {},
            doc = "Platform restrictions for assets.",
        ),
        "pkg_asset_flavors": attr.string_list_dict(
            default = {},
            doc = "Flavor restrictions for assets.",
        ),
    },
    doc = "Collects FlutterInfo contributions for one member of a merged SCC spoke.",
)

def _flutter_pub_scc_member_target_impl(ctx):
    providers = [
        DefaultInfo(
            files = ctx.attr.library[DefaultInfo].files,
            runfiles = ctx.attr.library[DefaultInfo].default_runfiles,
        ),
        ctx.attr.library[DartInfo],
        dart_analyzable_info(deps = [ctx.attr.library, ctx.attr._sky_engine]),
        flutter_info(deps = ctx.attr.scc_members + ctx.attr.deps),
    ]
    if DartKernelInfo in ctx.attr.library:
        providers.append(ctx.attr.library[DartKernelInfo])
    return providers

flutter_pub_scc_member_target = rule(
    implementation = _flutter_pub_scc_member_target_impl,
    attrs = {
        "package_name": attr.string(
            mandatory = True,
            doc = "The member package name.",
        ),
        "library": attr.label(
            mandatory = True,
            providers = [DartInfo],
            doc = "The merged dart_library target.",
        ),
        "scc_members": attr.label_list(
            default = [],
            providers = [FlutterInfo],
            doc = "The member flutter info targets across the SCC.",
        ),
        "deps": attr.label_list(
            default = [],
            doc = "Dependencies leaving the SCC.",
        ),
        "_sky_engine": SKY_ENGINE_ATTR,
    },
    doc = "Per-member public target for a merged SCC spoke.",
)
