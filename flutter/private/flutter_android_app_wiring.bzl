"""Internal wiring helpers shared by the Android app macros.

`flutter_android_app` and `flutter_android_aab` assemble the same payload-free
inputs (runner, registrant, variant manifests); the pieces that need no public
Android macro live here.
"""

load("@bazel_skylib//rules:expand_template.bzl", "expand_template")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load("//flutter/private:constants.bzl", "ANDROID_ABI_FOR_ARCH")
load(
    "//flutter/private:flutter_android_registrant.bzl",
    "flutter_android_plugins_aggregator",
    "flutter_android_registrant",
)

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
