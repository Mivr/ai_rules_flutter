"""Builds Android targets in a mode the command line did not ask for.

Profile mode is `-c opt` plus the `//flutter:profile` build setting, and the
arm64 Android platform selects the profile engine. Release mode is `-c opt`
with the profile setting off; debug mode is `-c dbg` with the profile setting
off. Each transition wraps only the targets under test, so the surrounding
`dart_test` stays in the default configuration.
"""

_ANDROID_ARM64 = Label("@rules_flutter//flutter/platforms:android_arm64")
_PROFILE_FLAG = str(Label("@rules_flutter//flutter:profile"))

def _profile_transition_impl(_settings, _attr):
    """Transitions targets to an arm64 Android build in Flutter profile mode."""
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:platforms": [_ANDROID_ARM64],
        _PROFILE_FLAG: True,
    }

_profile_transition = transition(
    implementation = _profile_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        _PROFILE_FLAG,
    ],
)

def _release_transition_impl(_settings, _attr):
    """Transitions targets to an arm64 Android build in Flutter release mode."""
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:platforms": [_ANDROID_ARM64],
        _PROFILE_FLAG: False,
    }

_release_transition = transition(
    implementation = _release_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        _PROFILE_FLAG,
    ],
)

def _debug_transition_impl(_settings, _attr):
    """Transitions targets to an arm64 Android build in Flutter debug mode."""
    return {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:platforms": [_ANDROID_ARM64],
        _PROFILE_FLAG: False,
    }

_debug_transition = transition(
    implementation = _debug_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        _PROFILE_FLAG,
    ],
)

def _forward_files_impl(ctx):
    """Re-exposes every configured target's DefaultInfo files."""
    return [DefaultInfo(files = depset(transitive = [
        target[DefaultInfo].files
        for target in ctx.attr.targets
    ]))]

profile_build = rule(
    implementation = _forward_files_impl,
    attrs = {
        "targets": attr.label_list(
            cfg = _profile_transition,
            mandatory = True,
            doc = "Targets to build with -c opt, the arm64 Android platform and //flutter:profile.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
            doc = "Allowlist required by Bazel for rules using Starlark transitions.",
        ),
    },
    doc = "Forwards the files of `targets` built in Flutter profile mode.",
)

release_build = rule(
    implementation = _forward_files_impl,
    attrs = {
        "targets": attr.label_list(
            cfg = _release_transition,
            mandatory = True,
            doc = "Targets to build with -c opt, the arm64 Android platform and profile off.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
            doc = "Allowlist required by Bazel for rules using Starlark transitions.",
        ),
    },
    doc = "Forwards the files of `targets` built in Flutter release mode.",
)

debug_build = rule(
    implementation = _forward_files_impl,
    attrs = {
        "targets": attr.label_list(
            cfg = _debug_transition,
            mandatory = True,
            doc = "Targets to build with -c dbg and the arm64 Android platform.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
            doc = "Allowlist required by Bazel for rules using Starlark transitions.",
        ),
    },
    doc = "Forwards the files of `targets` built in Flutter debug mode.",
)
