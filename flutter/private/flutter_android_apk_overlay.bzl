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

def _flutter_android_apk_overlay_impl(ctx):
    base = ctx.attr.binary
    base_apk_info = base[ApkInfo]
    base_unsigned = base_apk_info.unsigned_apk
    sdk = ctx.toolchains[_ANDROID_SDK_TOOLCHAIN_TYPE].android_sdk_info

    native_libs_jar = ctx.file.native_libs_jar
    flutter_assets = ctx.file.flutter_assets

    # 1. Splice the Flutter payload into a copy of the base unsigned APK.
    overlay_unsigned = ctx.actions.declare_file(ctx.label.name + "_overlay_unsigned.apk")
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    overlay_args = ctx.actions.args()
    overlay_args.add(ctx.executable._overlay_tool.path)
    overlay_args.add("apk-overlay")
    overlay_args.add("--base", base_unsigned.path)
    overlay_args.add("--native-libs-jar", native_libs_jar.path)
    overlay_args.add("--flutter-assets", flutter_assets.path)
    overlay_args.add("--output", overlay_unsigned.path)
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

    # 2. Align, exactly as android_binary does (`-P 16`, same alignment).
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

    # 3. Sign with the same keystore and scheme selection android_binary
    # would have used. `signing` mirrors
    # `@rules_android//flags:apk_signing_method` (wired by the macro via
    # select); v4 (fs-verity) stays with android_binary — route it there.
    signing = ctx.attr.signing
    if signing == "v4":
        fail(
            "flutter_android_apk_overlay %s: apk_signing_method=v4 is not " % ctx.label +
            "supported for apps whose Flutter payload is injected after " +
            "resource linking. Sign the android_binary directly (Tier 2) instead.",
        )
    v1_enabled = signing in ("v1", "v1_v2")
    v2_enabled = signing in ("v2", "v1_v2")

    signing_keys = list(ctx.files.debug_signing_keys)
    if not signing_keys and ctx.file.debug_key:
        signing_keys.append(ctx.file.debug_key)
    lineage = ctx.file.debug_signing_lineage_file
    rotation_min_sdk = ctx.attr.key_rotation_min_sdk

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
    ]
    if OutputGroupInfo in base:
        providers.append(base[OutputGroupInfo])
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
    ],
    doc = """Finishes a payload-free android_binary into a signed APK by injecting the Flutter payload after resource linking.

Takes the base unsigned APK, splices the bundle's native libraries and
flutter_assets into it, then zipaligns and signs with the Android SDK tools —
the same steps android_binary would have run. Created by the
`flutter_android_app` macro; use directly only when assembling an
`android_binary` by hand without the macro.
""",
)
