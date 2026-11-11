"""Exposes the Android-configured Dart plugin registrant of a `flutter_application`.

`flutter_application` writes `<name>_plugin_registrant.dart` via
`generate_dart_plugin_registrant` (`flutter/private/plugin_registrant.bzl`) and
passes its URI to `FlutterKernelCompile` (`flutter/private/common.bzl`) without
placing the `.dart` source in `DefaultInfo`. Attaching an aspect across
`flutter_android_registrant`'s `application` edge inspects the application in
the same Android platform configuration `flutter_android_registrant` transitions
to, verifies `FlutterKernelCompile` consumes `<name>_plugin_registrant.dart`
under `-Dflutter.dart_plugin_registrant=`, and exposes the file for testing.
"""

visibility("private")

_DartRegistrantInfo = provider(
    doc = "Carries the Dart plugin registrant generated for an Android-configured `flutter_application`.",
    fields = {
        "files": "depset[File]: Generated `<name>_plugin_registrant.dart` files.",
    },
)

def _verify_kernel_wiring(label, registrant_file, kernel_action):
    """Fails unless `kernel_action` consumes `registrant_file` via `-Dflutter.dart_plugin_registrant=`.

    Args:
        label: Label of the `flutter_application` target under inspection.
        registrant_file: The generated `<name>_plugin_registrant.dart` `File`.
        kernel_action: The `FlutterKernelCompile` action registered by `label`.
    """
    if registrant_file not in kernel_action.inputs.to_list():
        fail("%s generated %s, but FlutterKernelCompile did not declare it as an input" % (
            label,
            registrant_file.short_path,
        ))
    has_define = False
    for arg in kernel_action.argv:
        if arg.startswith("-Dflutter.dart_plugin_registrant=") and arg.endswith(registrant_file.basename):
            has_define = True
            break
    if not has_define:
        fail("%s did not pass -Dflutter.dart_plugin_registrant=.../%s to FlutterKernelCompile" % (
            label,
            registrant_file.basename,
        ))

def _dart_registrant_aspect_impl(target, ctx):
    """Collects `<name>_plugin_registrant.dart` from `target` or its `application` dep.

    Args:
        target: Configured target visited by the aspect.
        ctx: Aspect context.

    Returns:
        A one-element list holding `_DartRegistrantInfo`.
    """
    direct = []
    expected_name = target.label.name + "_plugin_registrant.dart"
    registrant_file = None
    kernel_action = None
    for action in target.actions:
        for out in action.outputs.to_list():
            if out.basename == expected_name:
                registrant_file = out
        if action.mnemonic == "FlutterKernelCompile":
            kernel_action = action
    if registrant_file != None:
        if kernel_action == None:
            fail("%s generated %s without a FlutterKernelCompile action" % (
                target.label,
                registrant_file.short_path,
            ))
        _verify_kernel_wiring(target.label, registrant_file, kernel_action)
        direct.append(registrant_file)

    transitive = []
    if hasattr(ctx.rule.attr, "application") and ctx.rule.attr.application != None:
        app = ctx.rule.attr.application
        if _DartRegistrantInfo in app:
            transitive.append(app[_DartRegistrantInfo].files)
    return [_DartRegistrantInfo(files = depset(direct, transitive = transitive))]

_dart_registrant_aspect = aspect(
    implementation = _dart_registrant_aspect_impl,
    attr_aspects = ["application"],
    doc = "Walks `application` to collect the Android-configured Dart plugin registrant.",
)

def _android_dart_registrant_impl(ctx):
    """Symlinks the single Android Dart plugin registrant to `<name>.dart`.

    Args:
        ctx: Rule context for `android_dart_registrant`.

    Returns:
        `DefaultInfo` exposing `<name>.dart`.
    """
    files = ctx.attr.registrant[_DartRegistrantInfo].files.to_list()
    if len(files) != 1:
        fail("expected 1 Dart plugin registrant from %s, got %d" % (
            ctx.attr.registrant.label,
            len(files),
        ))
    out = ctx.actions.declare_file(ctx.label.name + ".dart")
    ctx.actions.symlink(output = out, target_file = files[0])
    return [DefaultInfo(files = depset([out]))]

android_dart_registrant = rule(
    implementation = _android_dart_registrant_impl,
    attrs = {
        "registrant": attr.label(
            mandatory = True,
            aspects = [_dart_registrant_aspect],
            doc = (
                "A `flutter_android_registrant` target whose Android-transitioned " +
                "`application` owns the Dart plugin registrant."
            ),
        ),
    },
    doc = "Exposes `<name>.dart` pointing at the Android-configured `generate_dart_plugin_registrant` output.",
)
