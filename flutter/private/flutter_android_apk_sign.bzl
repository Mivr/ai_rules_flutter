"""Zipalign and apksigner steps shared by the full APK and its debug splits.

`flutter_android_apk_overlay` aligns and signs the injected APK with these
helpers; the debug base and payload splits (see `flutter_android_apk_split.bzl`)
reuse them so every APK of one app is signed with the same configuration.
"""

_ANDROID_SDK_TOOLCHAIN_TYPE = Label("@rules_android//toolchains/android_sdk:toolchain_type")

def release_execution_requirements(release):
    """Execution requirements for the `ApkSignerTool` action.

    Public (no leading underscore) so the analysis suite can pin it:
    `analysistest` actions expose argv, inputs, env and outputs but not
    execution requirements.

    The release signer reads the keystore and the password files. Under a
    remote executor Bazel would upload those secrets, and under any remote or
    disk cache their digests would land in the shared action cache — an
    offline brute-force oracle for a human-chosen password. Release signing
    therefore always runs locally. The debug keystore is public, so debug
    signing keeps the default requirements.

    Args:
      release: The resolved release-signing struct, or None for debug signing.

    Returns:
      `{"no-remote": "1"}` when the signer reads release secrets, else `{}`.
    """
    if release == None:
        return {}
    return {"no-remote": "1"}

def run_zipalign(ctx, sdk, overlay_unsigned, suffix = ""):
    """Aligns the overlaid APK, exactly as android_binary does (`-P 16`).

    Args:
      ctx: Rule context.
      sdk: The Android SDK info, for `zip_align`.
      overlay_unsigned: The unsigned APK to align.
      suffix: Appended to the output name, to tell the debug splits apart.

    Returns:
      The aligned APK.
    """
    aligned = ctx.actions.declare_file("zipaligned_" + ctx.label.name + suffix + ".apk")
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
        toolchain = _ANDROID_SDK_TOOLCHAIN_TYPE,
    )
    return aligned

def _release_sign_args(sign_args, release):
    """Adds the caller's keystore to the apksigner arguments.

    Both passwords travel as `file:` references to password-file inputs, so
    their text never appears on the command line. Without a key password
    file `--key-pass` is omitted and apksigner unlocks the key with the
    keystore password.
    """
    sign_args.add("--ks", release.keystore)
    sign_args.add("--ks-key-alias", release.alias)
    sign_args.add("--ks-pass", "file:" + release.ks_pass.path)
    if release.key_pass:
        sign_args.add("--key-pass", "file:" + release.key_pass.path)

def run_apksign(ctx, sdk, aligned, signing_keys, lineage, rotation_min_sdk, release, suffix = ""):
    """Signs the aligned APK with the keystore and scheme android_binary would use.

    `lineage` is the File passed with `--lineage`, or None: the caller drops
    the debug lineage under release signing, so a release APK never carries
    it. `signing` mirrors `@rules_android//flags:apk_signing_method` (wired by
    the macro via select); v4 (fs-verity) stays with android_binary — route
    it there. With `release` set, apksigner signs with the caller's keystore
    instead of the debug keys; without it every argument below is exactly the
    debug invocation.

    Args:
      ctx: Rule context.
      sdk: The Android SDK info, for `apk_signer`.
      aligned: The aligned APK to sign.
      signing_keys: The debug keystores.
      lineage: The `--lineage` File, or None.
      rotation_min_sdk: The rotation minimum SDK, or empty.
      release: The resolved release-signing struct, or None for debug signing.
      suffix: Appended to the output name, to tell the debug splits apart.

    Returns:
      The signed APK.
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

    signed = ctx.actions.declare_file(ctx.label.name + suffix + ".apk")
    sign_args = ctx.actions.args()
    sign_args.add("sign")
    sign_args.add("--alignment-preserved", "true")
    if lineage:
        sign_args.add("--lineage", lineage)
    if release:
        _release_sign_args(sign_args, release)
    else:
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
    if release:
        sign_inputs = [aligned, release.keystore, release.ks_pass]
        if release.key_pass:
            sign_inputs.append(release.key_pass)
    else:
        sign_inputs = [aligned] + signing_keys
    ctx.actions.run(
        executable = sdk.apk_signer,
        arguments = [sign_args],
        inputs = sign_inputs + ([lineage] if lineage else []),
        outputs = [signed],
        mnemonic = "ApkSignerTool",
        progress_message = "Signing APK with Flutter payload %s" % ctx.label,
        execution_requirements = release_execution_requirements(release),
        toolchain = _ANDROID_SDK_TOOLCHAIN_TYPE,
    )
    return signed
