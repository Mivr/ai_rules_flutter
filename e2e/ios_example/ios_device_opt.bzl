"""Transition an iOS framework dependency to a device, optimized build.

A physical iPhone runs the release or profile AOT engine, so either proof must
build the framework with `-c opt --ios_multi_cpus=arm64` on the iOS device
platform. Release is the default (`ios_device_opt_bundle`); setting
`//flutter:profile` (`ios_device_profile_bundle`) selects the profile engine
and gen_snapshot instead. `flutter_application` reads the target platform's
constraints to decide between iOS and macOS, and nothing else here moves the
build off the host platform (an `ios_application` would do that through
rules_apple's own split transition), so each transition sets
`//command_line_option:platforms` to `@apple_support//platforms:ios_arm64` as
well. Applying all of that via a transition on just the framework, its
application and its engine keeps the surrounding `dart_test` runner in the
default configuration.

`ios_device_opt_bundle` forwards the application's `debug_info` output group
(the `.symbols` file `split_debug_info` writes) from that same transitioned
build, so the release test reads the symbols of the very build it inspects.
`ios_device_profile_bundle` also forwards the `Flutter.framework` slice chosen
by `flutter_ios_engine` in that profile configuration and stages it under the
bundle target's own directory so the profile test can hash the exact engine
binary that configuration selected.
"""

load(
    "@rules_apple//apple:providers.bzl",
    "AppleDynamicFrameworkInfo",
    "AppleFrameworkImportInfo",
)

_PROFILE_FLAG = str(Label("@rules_flutter//flutter:profile"))

def _ios_device_opt_transition_impl(_settings, _attr):
    """Transitions a dependency to an optimized arm64 iOS device release build."""
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:ios_multi_cpus": ["arm64"],
        "//command_line_option:platforms": [
            Label("@apple_support//platforms:ios_arm64"),
        ],
    }

_ios_device_opt_transition = transition(
    implementation = _ios_device_opt_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:ios_multi_cpus",
        "//command_line_option:platforms",
    ],
)

def _ios_device_profile_transition_impl(_settings, _attr):
    """Transitions a dependency to an optimized arm64 iOS device profile build."""
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:ios_multi_cpus": ["arm64"],
        "//command_line_option:platforms": [
            Label("@apple_support//platforms:ios_arm64"),
        ],
        _PROFILE_FLAG: True,
    }

_ios_device_profile_transition = transition(
    implementation = _ios_device_profile_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:ios_multi_cpus",
        "//command_line_option:platforms",
        _PROFILE_FLAG,
    ],
)

def _ios_device_opt_bundle_impl(ctx):
    """Re-exposes a release App.framework and its split debug symbols."""

    # A 1:1 transition makes each labelled dependency a single-element list.
    # apple_dynamic_framework_import carries no DefaultInfo files: the
    # assembled framework travels in AppleDynamicFrameworkInfo.framework_files.
    return [DefaultInfo(files = depset(transitive = [
        ctx.attr.framework[0][AppleDynamicFrameworkInfo].framework_files,
        getattr(ctx.attr.application[0][OutputGroupInfo], "debug_info", depset()),
    ]))]

def _stage_engine_framework(ctx, engine_files):
    """Stages the selected Flutter.framework slice under this target's directory."""
    marker = "/Flutter.framework/"
    staged = []
    saw_binary = False
    for src in engine_files.to_list():
        if marker not in src.path:
            continue
        rel = src.path.split(marker, 1)[1]
        if rel == "Flutter":
            saw_binary = True
        out = ctx.actions.declare_file("%s/Flutter.framework/%s" % (ctx.label.name, rel))
        ctx.actions.symlink(output = out, target_file = src)
        staged.append(out)
    if not saw_binary:
        fail("expected Flutter.framework/Flutter in engine imports for %s" % ctx.label)
    return depset(staged)

def _ios_device_profile_bundle_impl(ctx):
    """Re-exposes a profile App.framework and the Flutter.framework slice it links."""
    engine_files = ctx.attr.engine[0][AppleFrameworkImportInfo].framework_imports
    staged_engine = _stage_engine_framework(ctx, engine_files)
    return [DefaultInfo(files = depset(transitive = [
        ctx.attr.framework[0][AppleDynamicFrameworkInfo].framework_files,
        engine_files,
        staged_engine,
        getattr(ctx.attr.application[0][OutputGroupInfo], "debug_info", depset()),
    ]))]

ios_device_opt_bundle = rule(
    implementation = _ios_device_opt_bundle_impl,
    attrs = {
        "application": attr.label(
            cfg = _ios_device_opt_transition,
            mandatory = True,
            doc = "The flutter_application to rebuild for the device in release.",
        ),
        "framework": attr.label(
            cfg = _ios_device_opt_transition,
            mandatory = True,
            providers = [AppleDynamicFrameworkInfo],
            doc = "The flutter_ios_framework_gen to rebuild for the device in release.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
            doc = "Allowlist required by Bazel for rules using Starlark transitions.",
        ),
    },
    doc = "Re-exposes a release App.framework and its .symbols built for the device (AOT).",
)

ios_device_profile_bundle = rule(
    implementation = _ios_device_profile_bundle_impl,
    attrs = {
        "application": attr.label(
            cfg = _ios_device_profile_transition,
            mandatory = True,
            doc = "The flutter_application to rebuild for the device in profile mode.",
        ),
        "engine": attr.label(
            cfg = _ios_device_profile_transition,
            mandatory = True,
            providers = [AppleFrameworkImportInfo],
            doc = "The flutter_ios_engine whose selected Flutter.framework slice is forwarded.",
        ),
        "framework": attr.label(
            cfg = _ios_device_profile_transition,
            mandatory = True,
            providers = [AppleDynamicFrameworkInfo],
            doc = "The flutter_ios_framework_gen to rebuild for the device in profile mode.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
            doc = "Allowlist required by Bazel for rules using Starlark transitions.",
        ),
    },
    doc = "Re-exposes a profile App.framework and its selected Flutter.framework built for an arm64 iOS device.",
)
