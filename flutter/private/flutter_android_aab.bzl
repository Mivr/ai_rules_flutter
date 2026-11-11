"""Android App Bundle (`.aab`) emission for `flutter_android_aab`.

The bundle is built by rules_android 0.8.0's public `android_application`
macro (loaded from `@rules_android//android:rules.bzl`): with a
`bundle_config_file` it emits `<name>_unsigned.aab`, running the proto-format
resource link, the module conversion and `bundletool build-bundle` as its own
actions with the bundletool of its toolchain. That bundletool is the Maven
artifact `com.android.tools.build:bundletool` that `rules_android_maven`
locks by version and sha256, so a missing or wrong checksum fails the build.

The Flutter payload rides the base module as `android_binary` inputs: the
bundle's `native_libs` java_import carries `lib/<abi>/libapp.so`, and
`flutter_assets` is an `assets` input of the base module.
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//android:rules.bzl", "android_application")

# The bundle config `bundletool build-bundle` is given: every setting at its
# default. The ".pb.json" suffix is what rules_android's attribute requires.
_BUNDLE_CONFIG = "{}\n"

def _aab_assets_impl(ctx):
    """Passes through only the `flutter_assets` tree of the bundle's mobile-install group."""
    trees = [
        f
        for f in ctx.attr.bundle[OutputGroupInfo].mobile_install.to_list()
        if f.is_directory and f.basename == "flutter_assets"
    ]
    if len(trees) != 1:
        fail("%s: expected one flutter_assets tree in the bundle, got %d" % (ctx.label, len(trees)))
    return [DefaultInfo(files = depset(trees))]

_aab_assets = rule(
    implementation = _aab_assets_impl,
    attrs = {
        "bundle": attr.label(
            doc = "The `flutter_android_bundle` target whose flutter_assets tree is passed through.",
            mandatory = True,
        ),
    },
    doc = "Selects the `flutter_assets/` tree of a `flutter_android_bundle`, for an `assets` attribute.",
)

def _aab_file_impl(ctx):
    """Exposes the unsigned `.aab` of the wrapped `android_application` as `<name>.aab`."""
    out = ctx.outputs.aab
    ctx.actions.symlink(output = out, target_file = ctx.file.unsigned_aab)
    return [DefaultInfo(files = depset([out]))]

_aab_file = rule(
    implementation = _aab_file_impl,
    attrs = {
        "unsigned_aab": attr.label(
            doc = "The `<name>_unsigned.aab` output of an `android_application`.",
            allow_single_file = [".aab"],
            mandatory = True,
        ),
    },
    outputs = {"aab": "%{name}.aab"},
    doc = "Exposes an unsigned `.aab` under the user-facing `<name>.aab` name.",
)

def flutter_android_aab_emit(name, aab):
    """Emits the base-module inputs, the `android_application` and the `<name>.aab` rule.

    Args:
        name: The `flutter_android_aab` name; internal targets derive from it.
        aab: Struct with `package_name`, `min_sdk_version`, `target_sdk_version`,
            `actual_manifest`, `resources`, `binary_deps`, `deps`, `tags`,
            `internal_tags` and `visibility`.
    """
    _aab_assets(
        name = "__%s_aab_assets" % name,
        bundle = "__%s_bundle" % name,
        tags = aab.internal_tags,
    )
    write_file(
        name = "__%s_bundle_config" % name,
        out = "__%s_bundle_config.pb.json" % name,
        content = [_BUNDLE_CONFIG],
        tags = aab.internal_tags,
    )
    android_application(
        name = "__%s_application" % name,
        manifest = aab.actual_manifest,
        manifest_values = {
            "applicationId": aab.package_name,
            "minSdkVersion": aab.min_sdk_version,
            "targetSdkVersion": aab.target_sdk_version,
        },
        resource_files = aab.resources if aab.resources else None,
        assets = ["__%s_aab_assets" % name],
        assets_dir = "__%s_bundle_mi/assets" % name,
        bundle_config_file = "__%s_bundle_config.pb.json" % name,
        deps = ["__%s_native_libs" % name] + aab.binary_deps + aab.deps,
        tags = aab.internal_tags,
        target_compatible_with = select({
            Label("@platforms//os:ios"): [Label("@platforms//:incompatible")],
            "//conditions:default": [],
        }),
    )
    _aab_file(
        name = name,
        unsigned_aab = "__%s_application_unsigned.aab" % name,
        tags = aab.tags,
        visibility = aab.visibility,
    )
