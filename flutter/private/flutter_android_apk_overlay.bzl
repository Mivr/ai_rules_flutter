"""Post-link APK assembly for `flutter_android_app`.

`android_binary` feeds its `assets` through aapt2 resource linking and its
Java deps through desugaring and the dex/multidex chain. The Flutter payload —
`libapp.so` (or `kernel_blob.bin` inside `flutter_assets/` in debug builds) —
therefore re-runs resource linking (~78.5 G per debug edit at M), the dex
chain and the second resource link on every Dart edit, even though none of
those steps' outputs change.

`flutter_android_app` instead builds its `android_binary` without the Flutter
payload and finishes the APK here, the way the flutter tool adds Flutter files
after resource linking:

1. `apk-overlay` (the `apk-overlay` subcommand of
   `//flutter/private/tools:android_bundle`) splices the payload — the
   bundle's `native_libs.jar` entries plus its `flutter_assets/` tree — into a
   copy of the base unsigned APK, preserving every pre-existing entry
   byte-for-byte. Native libraries are stored uncompressed so `zipalign` can
   page-align them.
2. The Android SDK `zipalign` (`-P 16`, same as `android_binary`) aligns the
   result.
3. The Android SDK `apksigner` signs it with the same keystore and the same
   v1/v2 scheme selection `android_binary` would have used.

A Dart edit then re-runs only the overlay, align and sign steps (~7 G); the
aapt2 link, desugar, dex, shard and merge steps re-run only when Android
resources, the manifest or Java/Kotlin inputs change. The final APK is
identical in entry content, native-library alignment and signature validity to
an `android_binary` that packaged the payload itself (entry order differs:
payload entries come last).
"""

load("@rules_android//providers:providers.bzl", "AndroidFeatureFlagSet", "AndroidInstrumentationInfo", "ApkInfo", "StarlarkApkInfo")
load("@rules_java//java/common:java_info.bzl", "JavaInfo")
load("//flutter/private:common.bzl", "resolve_exec_dart_vm")

_ANDROID_SDK_TOOLCHAIN_TYPE = Label("@rules_android//toolchains/android_sdk:toolchain_type")
_ANDROID_TOOLCHAIN_TYPE = Label("@rules_android//toolchains/android:toolchain_type")

def _overlay_merged_manifest(ctx, base):
    """Recovers the merged manifest from the base binary's deploy-info group.

    ApkInfo carries no merged manifest; the base binary's android_deploy_info
    output group pairs the base deploy_info.pb with the merged manifest (see
    rules_android's apk_packaging).

    Returns:
      A `(merged_manifest, base_groups)` tuple.
    """
    base_groups = base[OutputGroupInfo] if OutputGroupInfo in base else None
    base_deploy_files = []
    if base_groups:
        base_deploy_group = getattr(base_groups, "android_deploy_info", None)
        if type(base_deploy_group) == "depset":
            base_deploy_files = base_deploy_group.to_list()
    merged_manifests = [
        f
        for f in base_deploy_files
        if not f.basename.endswith(".pb")
    ]
    if len(merged_manifests) != 1:
        fail(
            "flutter_android_apk_overlay %s: expected exactly one merged " % ctx.label +
            "manifest in the base android_deploy_info group, got %s" %
            [f.path for f in base_deploy_files],
        )
    return merged_manifests[0], base_groups

def _run_apk_overlay(ctx, dart_exe, dart_vm_files, base_unsigned, native_libs_jar, flutter_assets):
    """Splices the Flutter payload into a copy of the base unsigned APK."""
    overlay_unsigned = ctx.actions.declare_file(ctx.label.name + "_overlay_unsigned.apk")
    overlay_args = ctx.actions.args()
    overlay_args.add(ctx.executable._overlay_tool.path)
    overlay_args.add("apk-overlay")
    overlay_args.add("--base", base_unsigned.path)
    overlay_args.add("--native-libs-jar", native_libs_jar.path)
    overlay_args.add("--flutter-assets", flutter_assets.path)
    overlay_args.add("--output", overlay_unsigned.path)
    if ctx.attr.nocompress_extensions:
        overlay_args.add_joined("--nocompress-extensions", ctx.attr.nocompress_extensions, join_with = ",")
    ctx.actions.run(
        executable = dart_exe,
        arguments = [overlay_args],
        inputs = depset(
            direct = [ctx.executable._overlay_tool, base_unsigned, native_libs_jar, flutter_assets],
            transitive = [dart_vm_files],
        ),
        outputs = [overlay_unsigned],
        mnemonic = "FlutterApkOverlay",
        progress_message = "Injecting Flutter payload into base APK %s" % ctx.label,
    )
    return overlay_unsigned

def _run_zipalign(ctx, sdk, overlay_unsigned):
    """Aligns the overlaid APK, exactly as android_binary does (`-P 16`)."""
    aligned = ctx.actions.declare_file("zipaligned_" + ctx.label.name + ".apk")
    align_args = ctx.actions.args()
    align_args.add("-P", "16")
    align_args.add(str(ctx.attr.zipalign_alignment))
    align_args.add(overlay_unsigned)
    align_args.add(aligned)
    ctx.actions.run(
        executable = sdk.zip_align,
        arguments = [align_args],
        inputs = [overlay_unsigned],
        outputs = [aligned],
        mnemonic = "AndroidZipAlign",
        progress_message = "Zipaligning APK with Flutter payload %s" % ctx.label,
    )
    return aligned

def _overlay_signing_keys(ctx):
    """Collects the debug signing keys, falling back to the debug keystore."""
    signing_keys = list(ctx.files.debug_signing_keys)
    if not signing_keys and ctx.file.debug_key:
        signing_keys.append(ctx.file.debug_key)
    return signing_keys

def _run_apksign(ctx, sdk, aligned, signing_keys, lineage, rotation_min_sdk):
    """Signs the aligned APK with the keystore and scheme android_binary would use.

    `signing` mirrors `@rules_android//flags:apk_signing_method` (wired by
    the macro via select); v4 (fs-verity) stays with android_binary — route
    it there.
    """
    signing = ctx.attr.signing
    if signing == "v4":
        fail(
            "flutter_android_apk_overlay %s: apk_signing_method=v4 is not " % ctx.label +
            "supported for apps whose Flutter payload is injected after " +
            "resource linking. Sign the android_binary directly (Tier 2) instead.",
        )
    v1_enabled = signing in ("v1", "v1_v2")
    v2_enabled = signing in ("v2", "v1_v2")

    signed = ctx.actions.declare_file(ctx.label.name + ".apk")
    sign_args = ctx.actions.args()
    sign_args.add("sign")
    sign_args.add("--alignment-preserved", "true")
    if lineage:
        sign_args.add("--lineage", lineage)
    for i, key in enumerate(signing_keys):
        if i > 0:
            sign_args.add("--next-signer")
        sign_args.add("--ks", key)
        sign_args.add("--ks-pass", "pass:android")
    sign_args.add("--v1-signing-enabled", v1_enabled)
    sign_args.add("--v1-signer-name", "CERT")
    sign_args.add("--v2-signing-enabled", v2_enabled)

    # L-4: pass --v4-signing-enabled explicitly so apksigner never writes an
    # undeclared .idsig sidecar next to the APK output. V4 stays unsupported
    # (see the fail() above); the value here is always false.
    sign_args.add("--v4-signing-enabled", False)
    if rotation_min_sdk:
        sign_args.add("--rotation-min-sdk-version", rotation_min_sdk)
    sign_args.add("--out", signed)
    sign_args.add(aligned)
    ctx.actions.run(
        executable = sdk.apk_signer,
        arguments = [sign_args],
        inputs = [aligned] + signing_keys + ([lineage] if lineage else []),
        outputs = [signed],
        mnemonic = "ApkSignerTool",
        progress_message = "Signing APK with Flutter payload %s" % ctx.label,
    )
    return signed

def _run_overlay_deploy_info(ctx, android_toolchain, merged_manifest, signed):
    """Regenerates deploy info against the overlay's own signed APK and manifest.

    Exactly as android_binary's WriteDeployInfo action does (deploy_info_writer
    from the android toolchain, --manifest/--apk/--deploy_info form), so
    mobile-install/deploy tooling sees the APK this rule actually produced.
    """
    deploy_info = ctx.actions.declare_file(ctx.label.name + ".deploy_info.pb")
    ctx.actions.run(
        executable = android_toolchain.deploy_info_writer.files_to_run,
        arguments = [
            "--manifest",
            merged_manifest.path,
            "--apk",
            signed.path,
            "--deploy_info",
            deploy_info.path,
        ],
        inputs = depset(direct = [merged_manifest, signed]),
        outputs = [deploy_info],
        mnemonic = "WriteDeployInfo",
        progress_message = "Writing deploy info for overlay APK %s" % ctx.label,
    )
    return deploy_info

def _overlay_output_groups(base_groups, deploy_info, merged_manifest):
    """Forwards the base output groups, replacing android_deploy_info.

    The fresh group is overlay-owned: the freshly written deploy_info pointing
    at the overlay signed APK, paired with the merged manifest.
    """
    group_kwargs = {}
    if base_groups:
        for name in dir(base_groups):
            if name in ("android_deploy_info", "to_json", "to_proto"):
                continue
            artifacts = getattr(base_groups, name, None)

            # dir() may also surface non-field members; only depsets can be
            # output group values.
            if type(artifacts) == "depset":
                group_kwargs[name] = artifacts
    group_kwargs["android_deploy_info"] = depset([deploy_info, merged_manifest])
    return group_kwargs

def _flutter_android_apk_overlay_impl(ctx):
    base = ctx.attr.binary
    base_apk_info = base[ApkInfo]
    base_unsigned = base_apk_info.unsigned_apk
    sdk = ctx.toolchains[_ANDROID_SDK_TOOLCHAIN_TYPE].android_sdk_info
    android_toolchain = ctx.toolchains[_ANDROID_TOOLCHAIN_TYPE]

    merged_manifest, base_groups = _overlay_merged_manifest(ctx, base)

    native_libs_jar = ctx.file.native_libs_jar
    flutter_assets = ctx.file.flutter_assets

    # 1. Splice the Flutter payload into a copy of the base unsigned APK.
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    overlay_unsigned = _run_apk_overlay(ctx, dart_exe, dart_vm_files, base_unsigned, native_libs_jar, flutter_assets)

    # 2. Align, exactly as android_binary does (`-P 16`, same alignment).
    aligned = _run_zipalign(ctx, sdk, overlay_unsigned)

    # 3. Sign with the same keystore and scheme selection android_binary
    # would have used.
    signing_keys = _overlay_signing_keys(ctx)
    lineage = ctx.file.debug_signing_lineage_file
    rotation_min_sdk = ctx.attr.key_rotation_min_sdk
    signed = _run_apksign(ctx, sdk, aligned, signing_keys, lineage, rotation_min_sdk)

    # 4. Regenerate deploy info against the overlay's own signed APK and
    # merged manifest.
    deploy_info = _run_overlay_deploy_info(ctx, android_toolchain, merged_manifest, signed)

    # Forward the base output groups verbatim EXCEPT android_deploy_info.
    group_kwargs = _overlay_output_groups(base_groups, deploy_info, merged_manifest)

    keystore = signing_keys[0] if signing_keys else None
    providers = [
        DefaultInfo(files = depset([signed])),
        ApkInfo(
            signed_apk = signed,
            unsigned_apk = overlay_unsigned,
            deploy_jar = base_apk_info.deploy_jar,
            coverage_metadata = base_apk_info.coverage_metadata,
            signing_keys = signing_keys,
            signing_lineage = base_apk_info.signing_lineage,
            signing_min_v3_rotation_api_version = base_apk_info.signing_min_v3_rotation_api_version,
            keystore = keystore,
        ),
        StarlarkApkInfo(
            keystore = keystore,
            signing_keys = signing_keys,
            signing_lineage = base_apk_info.signing_lineage,
            signed_apk = signed,
            unsigned_apk = overlay_unsigned,
        ),
        base[JavaInfo],
        OutputGroupInfo(**group_kwargs),
    ]
    if AndroidFeatureFlagSet in base:
        providers.append(base[AndroidFeatureFlagSet])
    if AndroidInstrumentationInfo in base:
        providers.append(base[AndroidInstrumentationInfo])
    return providers

flutter_android_apk_overlay = rule(
    implementation = _flutter_android_apk_overlay_impl,
    attrs = {
        "binary": attr.label(
            doc = "The payload-free android_binary whose unsigned APK is the overlay base.",
            mandatory = True,
            providers = [ApkInfo],
        ),
        "native_libs_jar": attr.label(
            doc = "The bundle's native_libs.jar; its lib/<abi>/*.so entries are stored into the APK.",
            mandatory = True,
            allow_single_file = True,
        ),
        "flutter_assets": attr.label(
            doc = "The bundle's flutter_assets directory; archived as assets/flutter_assets/ in the APK.",
            mandatory = True,
            allow_single_file = True,
        ),
        "signing": attr.string(
            doc = "APK signature schemes, mirroring @rules_android//flags:apk_signing_method. One of v1, v1_v2, v2.",
            default = "v1_v2",
            values = ["v1", "v1_v2", "v2", "v4"],
        ),
        "zipalign_alignment": attr.int(
            doc = "Alignment in bytes, matching android_binary's zipalign_alignment.",
            default = 4,
        ),
        "nocompress_extensions": attr.string_list(
            doc = "Extra asset extensions stored uncompressed in the overlaid APK, " +
                  "on top of the aapt2 defaults, matching android_binary's " +
                  "nocompress_extensions. Matched case-sensitively by suffix.",
        ),
        "debug_key": attr.label(
            doc = "Debug keystore, matching android_binary's debug_key.",
            cfg = "exec",
            default = Label("@rules_android//tools/android:debug_keystore"),
            allow_single_file = True,
        ),
        "debug_signing_keys": attr.label_list(
            doc = "Debug keystores, matching android_binary's debug_signing_keys.",
            allow_files = True,
        ),
        "debug_signing_lineage_file": attr.label(
            doc = "Signing lineage, matching android_binary's debug_signing_lineage_file.",
            allow_single_file = True,
        ),
        "key_rotation_min_sdk": attr.string(
            doc = "Rotation minimum SDK, matching android_binary's key_rotation_min_sdk.",
            default = "",
        ),
        "_overlay_tool": attr.label(
            default = Label("//flutter/private/tools:android_bundle"),
            executable = True,
            cfg = "exec",
        ),
    },
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
        "@rules_android//toolchains/android_sdk:toolchain_type",
        "@rules_android//toolchains/android:toolchain_type",
    ],
    doc = """Finishes a payload-free android_binary into a signed APK by injecting the Flutter payload after resource linking.

Takes the base unsigned APK, splices the bundle's native libraries and
flutter_assets into it, then zipaligns and signs with the Android SDK tools —
the same steps android_binary would have run. Created by the
`flutter_android_app` macro; use directly only when assembling an
`android_binary` by hand without the macro.
""",
)
