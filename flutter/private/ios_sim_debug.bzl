"""Transition an iOS app dependency to a debug, simulator build.

Flutter runs the JIT (debug) engine on the iOS simulator — the release/AOT
engine is device-only — so a runtime simulator test must build the app with
`-c dbg --ios_multi_cpus=sim_arm64`. Applying that via a transition on just
the app keeps the surrounding test runner in the default configuration.

A debug build is never a profile build, so the transition also clears the
`//flutter:profile` build setting. That lets `bazel test --config=profile`
analyse this app in debug mode instead of failing in `flutter_build_mode`,
which rejects profile mode outside `-c opt`.
"""

_PROFILE_FLAG = str(Label("//flutter:profile"))

def ios_sim_debug_transition_impl(_settings, _attr):
    return {
        "//command_line_option:compilation_mode": "dbg",
        "//command_line_option:ios_multi_cpus": ["sim_arm64"],
        _PROFILE_FLAG: False,
    }

_ios_sim_debug_transition = transition(
    implementation = ios_sim_debug_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:ios_multi_cpus",
        _PROFILE_FLAG,
    ],
)

def _ios_sim_debug_app_impl(ctx):
    # A 1:1 transition makes `app` a single-element list.
    return [DefaultInfo(files = ctx.attr.app[0][DefaultInfo].files)]

ios_sim_debug_app = rule(
    implementation = _ios_sim_debug_app_impl,
    attrs = {
        "app": attr.label(
            cfg = _ios_sim_debug_transition,
            mandatory = True,
            doc = "The ios_application to rebuild for the simulator in debug.",
        ),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
            doc = "Allowlist for the function transition on `app`.",
        ),
    },
    doc = "Re-exposes an iOS app built for the simulator in debug (JIT) mode, with the profile build setting cleared.",
)
