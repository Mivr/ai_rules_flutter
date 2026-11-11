"""Debug split APKs for `flutter_android_app`: a signed base and a signed Dart payload.

In a debug build a Dart edit changes only `flutter_assets/` (the kernel blob
and snapshots). The base split carries everything else (the payload-free
base APK and the native libraries) and the payload split carries only
`flutter_assets/` behind a code-free manifest, so a Dart edit leaves the base
split's inputs, and therefore its signing action, unchanged.
"""

load(":flutter_android_apk_sign.bzl", "run_apksign", "run_zipalign")

_DART_EXEC_TOOLCHAIN_TYPE = Label("@rules_dart//dart:exec_tools_toolchain_type")

# The `split` name in the payload split's manifest.
_SPLIT_NAME = "flutter_payload"

def run_overlay_tool(ctx, output_name, tool_args, inputs, message):
    """Registers one `apk-overlay` invocation that writes `output_name`.

    `tool_args` is a list of `(flag, value)` pairs placed before `--output`;
    the caller's `nocompress_extensions` and, in debug builds, `--debug` follow.

    Args:
      ctx: Rule context of the overlay rule.
      output_name: Name of the unsigned APK to declare.
      tool_args: List of `(flag, value)` pairs; a File or string value, or None for a bare flag.
      inputs: The action's input Files, besides the tool.
      message: Progress message with one `%s` for the label.

    Returns:
      The unsigned APK.
    """
    unsigned = ctx.actions.declare_file(output_name)
    overlay_args = ctx.actions.args()
    overlay_args.add("apk-overlay")
    for flag, value in tool_args:
        if value == None:
            overlay_args.add(flag)
        else:
            overlay_args.add(flag, value if type(value) == "string" else value.path)
    overlay_args.add("--output", unsigned.path)
    if ctx.attr.nocompress_extensions:
        overlay_args.add_joined("--nocompress-extensions", ctx.attr.nocompress_extensions, join_with = ",")
    if ctx.var.get("COMPILATION_MODE", "") == "dbg":
        overlay_args.add("--debug")
    ctx.actions.run(
        executable = ctx.executable._overlay_tool,
        arguments = [overlay_args],
        inputs = depset(direct = [ctx.executable._overlay_tool] + inputs),
        outputs = [unsigned],
        mnemonic = "FlutterApkOverlay",
        progress_message = message % ctx.label,
        toolchain = _DART_EXEC_TOOLCHAIN_TYPE,
    )
    return unsigned

def split_apk_groups(ctx, sdk, inputs, signing):
    """Builds the debug-only base and payload split APKs, signed like the full APK.

    The base split is the payload-free base plus the native libraries; the payload
    split is a code-free manifest plus `flutter_assets/`. A Dart edit changes only
    the payload split's inputs, so the base split is neither re-aligned nor re-signed.
    Release configurations register nothing and report empty groups.

    Args:
      ctx: Rule context.
      sdk: The Android SDK info (zipalign, apksigner).
      inputs: Struct of `base_unsigned`, `native_libs_jar`, `flutter_assets`, `merged_manifest`.
      signing: Struct of `keys`, `lineage`, `rotation`, `release`, as the full APK signs.

    Returns:
      A dict of the `base_apk` and `payload_apk` output groups.
    """
    if ctx.var.get("COMPILATION_MODE", "") != "dbg":
        return {"base_apk": depset(), "payload_apk": depset()}
    base_unsigned = run_overlay_tool(
        ctx,
        ctx.label.name + "_base_unsigned.apk",
        [
            ("--base", inputs.base_unsigned),
            ("--native-libs-jar", inputs.native_libs_jar),
            ("--no-flutter-assets", None),
        ],
        [inputs.base_unsigned, inputs.native_libs_jar],
        "Assembling base split APK %s",
    )
    payload_unsigned = run_overlay_tool(
        ctx,
        ctx.label.name + "_payload_unsigned.apk",
        [
            ("--split-name", _SPLIT_NAME),
            ("--manifest", inputs.merged_manifest),
            ("--flutter-assets", inputs.flutter_assets),
        ],
        [inputs.merged_manifest, inputs.flutter_assets],
        "Assembling payload split APK %s",
    )
    groups = {}
    splits = (("base_apk", base_unsigned, "_base"), ("payload_apk", payload_unsigned, "_payload"))
    for group, unsigned, suffix in splits:
        aligned = run_zipalign(ctx, sdk, unsigned, suffix)
        signed = run_apksign(
            ctx,
            sdk,
            aligned,
            signing.keys,
            signing.lineage,
            signing.rotation,
            signing.release,
            suffix,
        )
        groups[group] = depset([signed])
    return groups
