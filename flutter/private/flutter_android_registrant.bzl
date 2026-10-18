"""Android native plugin registrant rule.

Generates `io/flutter/plugins/GeneratedPluginRegistrant.java` from
FlutterApplicationInfo plugin metadata. The Java file calls
`flutterEngine.getPlugins().add(new <FullyQualified.PluginClass>())`
for each plugin whose `flutter.plugin.platforms.android.pluginClass`
is set, mirroring `flutter pub get`'s registrant.

The `flutter_android_application.bzl` machinery (or the `flutter_android_app`
Tier-1 macro) compiles the registrant + every transitive plugin's
`kt_android_library` / `android_library` into the final `android_binary`.
"""

load("@rules_android//providers:providers.bzl", "AndroidLibraryResourceClassJarProvider")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "ANDROID_ABIS")
load("//flutter/private:flutter_android_application.bzl", "android_platform_transition")
load("//flutter/private:plugin_registrant.bzl", "generate_native_plugin_registrant")

FlutterAndroidPluginManifestsInfo = provider(
    doc = "Exported AndroidManifest.xml files from transitive flutter_plugin(android_libs = ...) targets.",
    fields = {
        "manifests": "depset[File]: Exported library manifests.",
    },
)

def _flutter_android_registrant_impl(ctx):
    plugins = ctx.attr.application[FlutterApplicationInfo].plugins
    registrant = generate_native_plugin_registrant(ctx, plugins, "android")
    return [DefaultInfo(files = depset([registrant]))]

flutter_android_registrant = rule(
    implementation = _flutter_android_registrant_impl,
    cfg = android_platform_transition,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo with plugin metadata.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "android_abi": attr.string(
            doc = """Android ABI to build for ("arm64-v8a" or "x86_64").

Transitions `application` to the matching Android platform and configuration so
it shares the exact same configuration as `flutter_android_bundle` instead of
re-analyzing `application` in the outer/host configuration.""",
            default = "arm64-v8a",
            values = ANDROID_ABIS.keys(),
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Generates the Java native plugin registrant for Android (GeneratedPluginRegistrant.java).",
)

def _flutter_android_plugins_aggregator_impl(ctx):
    app_info = ctx.attr.application[FlutterApplicationInfo]
    plugin_libs = getattr(app_info, "android_plugin_libraries", None)
    entries = plugin_libs.to_list() if plugin_libs else []
    java_infos = [entry.java_info for entry in entries if getattr(entry, "java_info", None)]
    resource_node_depsets = []
    resource_class_jar_depsets = []
    for entry in entries:
        res_info = getattr(entry, "resources_info", None)
        if res_info:
            resource_node_depsets.append(res_info.direct_resources_nodes)
            resource_node_depsets.append(res_info.transitive_resources_nodes)
        res_jars = getattr(entry, "resource_class_jars", None)
        if res_jars:
            resource_class_jar_depsets.append(res_jars)
    resource_class_jars = depset(transitive = resource_class_jar_depsets, order = "preorder")
    resource_class_jars_set = {jar: True for jar in resource_class_jars.to_list()}
    direct_output_jars_set = {
        jar: True
        for ji in java_infos
        for jar in ji.runtime_output_jars
    }
    transitive_runtime_jars = depset(
        transitive = [ji.transitive_runtime_jars for ji in java_infos],
    ).to_list()
    extra_runtime_java_infos = [
        JavaInfo(output_jar = jar, compile_jar = jar)
        for jar in transitive_runtime_jars
        if jar not in direct_output_jars_set and jar not in resource_class_jars_set
    ]
    all_nodes = depset(transitive = resource_node_depsets).to_list()
    exported_manifests = [node.manifest for node in all_nodes if node.exports_manifest]
    return [
        DefaultInfo(),
        java_common.merge(java_infos + extra_runtime_java_infos),
        AndroidLibraryResourceClassJarProvider(jars = resource_class_jars),
        FlutterAndroidPluginManifestsInfo(manifests = depset(exported_manifests)),
    ]

flutter_android_plugins_aggregator = rule(
    implementation = _flutter_android_plugins_aggregator_impl,
    cfg = android_platform_transition,
    attrs = {
        "application": attr.label(
            doc = "A flutter_application target providing FlutterApplicationInfo with android_plugin_libraries.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
        ),
        "android_abi": attr.string(
            doc = "Android ABI to build for (\"arm64-v8a\" or \"x86_64\").",
            default = "arm64-v8a",
            values = ANDROID_ABIS.keys(),
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Aggregates JavaInfo and exported manifests from transitive flutter_plugin(android_libs = ...) targets.",
)
