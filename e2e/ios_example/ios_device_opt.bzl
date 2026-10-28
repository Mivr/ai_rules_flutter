"""Transition an iOS framework dependency to a device, optimized build.

A physical iPhone runs the release or profile AOT engine, so either proof must
build the framework with `-c opt --ios_multi_cpus=arm64` on the iOS device
platform. Release is the default; setting `//flutter:profile` selects the
profile engine and gen_snapshot instead. `flutter_application` reads the target
platform's constraints to decide between iOS and macOS, and nothing else here
moves the build off the host platform (an `ios_application` would do that
through rules_apple's own split transition), so the transition sets
`//command_line_option:platforms` to `@apple_support//platforms:ios_arm64` as
well. Applying all of that via a transition on just the framework, its
application and its engine keeps the surrounding `dart_test` runner in the
default configuration.

The rule also forwards the application's `debug_info` output group (the
`.symbols` file `split_debug_info` writes) from that same transitioned build,
so the test reads the symbols of the very build it inspects. When `engine` is
set it forwards that configuration's Flutter framework files too, and writes a
unique symlink to the engine binary the framework would load so a test can
hash exactly the linked engine.
"""

load("@rules_apple//apple:providers.bzl", "AppleDynamicFrameworkInfo")

def _ios_device_opt_transition_impl(_settings, attr):
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:ios_multi_cpus": ["arm64"],
        "//command_line_option:platforms": [
            Label("@apple_support//platforms:ios_arm64"),
        ],
        "@rules_flutter//flutter:profile": attr.profile,
    }

_ios_device_opt_transition = transition(
    implementation = _ios_device_opt_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:ios_multi_cpus",
        "//command_line_option:platforms",
        "@rules_flutter//flutter:profile",
    ],
)

def _ios_device_opt_bundle_impl(ctx):
    # A 1:1 transition makes each labelled dependency a single-element list.
    # apple_dynamic_framework_import carries no DefaultInfo files: the
    # assembled framework travels in AppleDynamicFrameworkInfo.framework_files.
    files = [
        ctx.attr.framework[0][AppleDynamicFrameworkInfo].framework_files,
        getattr(ctx.attr.application[0][OutputGroupInfo], "debug_info", depset()),
    ]
    if ctx.attr.engine:
        engine = ctx.attr.engine[0][AppleDynamicFrameworkInfo]
        linked_engine = ctx.actions.declare_file(ctx.label.name + ".linked_engine")
        ctx.actions.symlink(output = linked_engine, target_file = engine.binary)
        files.extend([engine.framework_files, depset([linked_engine])])
    return [DefaultInfo(files = depset(transitive = files))]

ios_device_opt_bundle = rule(
    implementation = _ios_device_opt_bundle_impl,
    attrs = {
        "application": attr.label(
            cfg = _ios_device_opt_transition,
            mandatory = True,
            doc = "The flutter_application to rebuild for the device in release or profile.",
        ),
        "engine": attr.label(
            cfg = _ios_device_opt_transition,
            providers = [AppleDynamicFrameworkInfo],
            doc = "Optional flutter_ios_engine to rebuild for the device and forward, with a symlink to the linked engine binary.",
        ),
        "framework": attr.label(
            cfg = _ios_device_opt_transition,
            mandatory = True,
            providers = [AppleDynamicFrameworkInfo],
            doc = "The flutter_ios_framework_gen to rebuild for the device in release or profile.",
        ),
        "profile": attr.bool(
            default = False,
            doc = "Set the //flutter:profile build setting for every target this transition reaches.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    doc = "Re-exposes a release or profile App.framework and its .symbols built for the device (AOT), plus the linked engine.",
)
