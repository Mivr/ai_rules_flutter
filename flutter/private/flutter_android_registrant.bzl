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

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_android//providers:providers.bzl", "AndroidLibraryResourceClassJarProvider")
load("@rules_java//java/common:java_common.bzl", "java_common")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load("//flutter:providers.bzl", "FlutterApplicationInfo")
load("//flutter/private:common.bzl", "ANDROID_ABIS")
load("//flutter/private:constants.bzl", "ANDROID_ABI_FOR_ARCH")
load("//flutter/private:flutter_android_aab.bzl", _flutter_android_aab_emit = "flutter_android_aab_emit")
load("//flutter/private:flutter_android_application.bzl", "android_platform_transition")
load("//flutter/private:plugin_registrant.bzl", "generate_native_plugin_registrant")

visibility(["//flutter/..."])

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
            doc = """Optional Android ABI override ("arm64-v8a" or "x86_64").

When omitted, preserves the caller's configured Android platform/ABI (or
transitions to Android while keeping the caller's architecture and
`dynamic_mode`). When set (e.g. by `flutter_android_app`), transitions
`application` to the matching Android ABI platform.""",
            default = "",
            values = [""] + ANDROID_ABIS.keys(),
        ),
        "_allowlist_function_transition": attr.label(
            doc = "Function-transition allowlist the rule's platform transition requires.",
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
            doc = "Optional Android ABI override (\"arm64-v8a\" or \"x86_64\").",
            default = "",
            values = [""] + ANDROID_ABIS.keys(),
        ),
        "_allowlist_function_transition": attr.label(
            doc = "Function-transition allowlist the rule's platform transition requires.",
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Aggregates JavaInfo and exported manifests from transitive flutter_plugin(android_libs = ...) targets.",
)

# Wiring helpers shared by the Android app macros (`flutter_android_app`, `flutter_android_aab`).

flutter_android_aab_emit = _flutter_android_aab_emit

def variant_overlay(name, variant, manifest, base_manifest):
    """Resolves a `flutter create` variant manifest (`debug` or `profile`).

    Args:
        name: The flutter_android_app name, for error messages.
        variant: The build variant directory under android/app/src/.
        manifest: The macro argument: False, None (discover) or a label.
        base_manifest: The main manifest the variant merges into, or None.

    Returns:
        The overlay manifest, or None.
    """
    if manifest == False:
        return None
    if manifest == None:
        discovered = native.glob(
            ["android/app/src/%s/AndroidManifest.xml" % variant],
            allow_empty = True,
        )
        overlay = discovered[0] if discovered else None
    else:
        overlay = manifest
    if overlay != None and base_manifest == None:
        fail(
            ("flutter_android_app(name = %r): %s variant manifest %r has no main " +
             "manifest to merge into. Add android/app/src/main/AndroidManifest.xml " +
             "(flutter create output), pass `manifest`, or pass " +
             "`%s_manifest = False` to ignore the variant manifest.") %
            (name, variant, overlay, variant),
        )
    return overlay

# -- Convenience macro (Tier 1) -----------------------------------------------
def android_registrant(name, application, android_abi, pub_hub_name, deps, internal_tags):
    """Auto-wires the plugin registrant and returns its compile deps.

    Generates `GeneratedPluginRegistrant.java` from the flutter_application's
    transitive FlutterInfo plugin metadata, then wraps it in a
    kt_android_library so the registrant class is on the runtime
    classpath (called from the runner's MainActivity / FlutterActivity).

    The registrant references each plugin's `PluginClass` by fully
    qualified name, so its compile classpath must include every
    plugin's `kt_android_library`, the hub aggregator, the workspace
    `deps` (a workspace plugin reaches the app through them and the
    registrant names its class), and the engine.

    Args:
        name: The app name; internal targets derive from it.
        application: The flutter_application target.
        android_abi: Short ABI name, "arm64" or "x64".
        pub_hub_name: Name of the pub hub providing plugin spokes, or None.
        deps: The app's extra dependency labels.
        internal_tags: Tags for the internal targets.

    Returns:
        The registrant's compile dependency labels.
    """
    flutter_android_registrant(
        name = "__%s_registrant_src" % name,
        application = application,
        android_abi = short_abi_to_full(android_abi),
        tags = internal_tags,
    )

    flutter_android_plugins_aggregator(
        name = "__%s_android_plugins" % name,
        application = application,
        android_abi = short_abi_to_full(android_abi),
        tags = internal_tags,
    )

    registrant_deps = [
        "__%s_engine" % name,
        "__%s_android_plugins" % name,
    ]
    if pub_hub_name:
        registrant_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)
    return registrant_deps + deps

def android_discover_runner(name, package_name, resources, binary_deps, base_manifest, internal_tags):
    """Discovers flutter create output: manifest, resources, Kotlin sources.

    Args:
      name: The app name; internal targets derive from it.
      package_name: Android package name of the app.
      resources: The app's extra resource files.
      binary_deps: Binary dependency labels; gains the runner library when
        Kotlin sources are discovered.
      base_manifest: The manifest the caller passed, or None to discover one.
      internal_tags: Tags for the internal targets.

    Returns:
      The `(base_manifest, resources)` tuple.
    """
    if base_manifest:
        return base_manifest, resources

    # Try to discover flutter create output.
    discovered_manifests = native.glob(
        ["android/app/src/main/AndroidManifest.xml"],
        allow_empty = True,
    )
    if not discovered_manifests:
        return base_manifest, resources

    # Flutter create case — preprocess manifest for Gradle variables.
    # Same pattern as flutter_ios_app preprocessing Info.plist for Xcode
    # variables (ios.bzl).
    expand_template(
        name = "__%s_manifest" % name,
        template = discovered_manifests[0],
        out = "__%s_AndroidManifest.xml" % name,
        substitutions = {
            "${applicationName}": "android.app.Application",
        },
        tags = internal_tags,
    )

    # Discover resources from flutter create output.
    discovered_resources = native.glob(
        ["android/app/src/main/res/**"],
        allow_empty = True,
    )
    resources = list(resources) + discovered_resources

    # Discover and compile Kotlin sources from flutter create output.
    discovered_kotlin = native.glob(
        ["android/app/src/main/kotlin/**/*.kt"],
        allow_empty = True,
    )
    if discovered_kotlin:
        kt_android_library(
            name = "__%s_runner" % name,
            srcs = discovered_kotlin,
            custom_package = package_name,
            tags = internal_tags,
            deps = ["__%s_engine" % name],
        )
        binary_deps.append("__%s_runner" % name)
    return "__%s_manifest" % name, resources

def short_abi_to_full(abi):
    """Convert short ABI name to full ABI string for flutter_android_bundle."""
    if abi not in ANDROID_ABI_FOR_ARCH:
        fail("Unsupported android_abi '%s'. Use arm64 or x64." % abi)
    return ANDROID_ABI_FOR_ARCH[abi]
