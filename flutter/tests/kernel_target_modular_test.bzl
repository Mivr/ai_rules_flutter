"""A debug `flutter_kernel_target` compiles per-package modules and links the SDK registrant twin.

The entry module carries the staged agent, native agent and registrant under constant URIs, and
the link swaps in the SDK `flutter` registrant twin when present. Defines, define files, frontend
flags, manifests, recorded uses, AOT, profile, release and web keep `FlutterKernelCompile`.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "MODULAR_KERNEL_ATTRS", "MODULAR_KERNEL_TOOLCHAINS")
load(
    "//flutter/private:common.bzl",
    "AGENT_EXTENSIONS_ATTR",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "DEFINES_FILES_APPLICATION_ATTRS",
    "KERNEL_COMPILE_ATTRS",
    "flutter_compile_kernel",
    "make_kernel_inputs",
    "make_kernel_target",
    "resolve_flutter_sdk_info",
)
load("//flutter/private:debug_build.bzl", "debug_build")
load("//flutter/private:flutter_kernel_module.bzl", "flutter_kernel_module_aspect")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")

visibility(["//flutter/tests/..."])

_DBG = {"//command_line_option:compilation_mode": "dbg", str(Label("//flutter:profile")): False}
_PROFILE = {"//command_line_option:compilation_mode": "opt", str(Label("//flutter:profile")): True}
_TWIN_DEPS = ["//flutter/tests/registrant_twin_fixture/app"]
_ENTRY_FILES = [
    "/_flutter_debug_agent/agent_extensions.dart",
    "/_flutter_debug_agent/native_agent_extensions.dart",
    "/_flutter_debug_agent/plugin_registrant.dart",
]

def _by_mnemonic(env, mnemonic):
    """Returns actions on the target under test matching `mnemonic`."""
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _paths(action):
    """Returns input file paths of `action`."""
    return [f.path for f in action.inputs.to_list()]

def _has_output(action, suffix):
    """Whether any output basename of `action` ends with `suffix`."""
    return any([f.basename.endswith(suffix) for f in action.outputs.to_list()])

def assert_kernel_target_dbg_modular(env):
    """Asserts a debug non-AOT `flutter_kernel_target` with the twin registers modules and one link.

    Args:
        env: The analysis test environment.
    """
    asserts.true(env, len(_by_mnemonic(env, "DartKernel")) > 0, "registers DartKernel modules")
    links = _by_mnemonic(env, "DartKernelLink")
    asserts.equals(env, 1, len(links), "one DartKernelLink")
    entry = [a for a in _by_mnemonic(env, "DartKernel") if _has_output(a, ".flutter_entry.kmod")]
    asserts.equals(env, 1, len(entry), "one entry module")
    if entry:
        paths = _paths(entry[0])
        for suffix in _ENTRY_FILES:
            asserts.true(env, any([p.endswith(suffix) for p in paths]), "entry compiles %s: %s" % (suffix, paths))
    if links:
        paths = _paths(links[0])
        asserts.true(env, any([".flutter_registrant.kmod" in p for p in paths]), "the link uses the twin: %s" % paths)
        asserts.false(env, any([".flutter.flutter.kmod" in p for p in paths]), "the link drops the plain SDK module")

def _modular_no_twin_impl(ctx):
    """A debug `flutter_kernel_target` without `package:flutter` in `deps` also links modularly."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _by_mnemonic(env, "FlutterKernelCompile"), "no whole-program compile")
    links = _by_mnemonic(env, "DartKernelLink")
    asserts.equals(env, 1, len(links), "one DartKernelLink")
    if links:
        paths = _paths(links[0])
        asserts.true(env, any(["other.flutter.kmod" in p for p in paths]), "links dep module: %s" % paths)
        asserts.false(env, any([".flutter_registrant.kmod" in p for p in paths]), "no twin without SDK flutter")
    return analysistest.end(env)

def _whole_program_impl(ctx):
    """Defines, frontend flags, manifests, recorded uses, profile, AOT and web keep `FlutterKernelCompile`."""
    env = analysistest.begin(ctx)
    asserts.equals(env, 1, len(_by_mnemonic(env, "FlutterKernelCompile")), "one whole-program compile")
    asserts.equals(env, [], _by_mnemonic(env, "DartKernelLink"), "no DartKernelLink")
    return analysistest.end(env)

_ActionsInfo = provider(
    doc = "The actions registered for a target and its `deps` closure.",
    fields = ["actions"],
)

def _inspect_impl(target, ctx):
    """Exposes the target's actions and its deps' (the kernel module aspect's among them)."""
    actions = list(target.actions)
    for dep in getattr(ctx.rule.attr, "deps", []):
        if _ActionsInfo in dep:
            actions += dep[_ActionsInfo].actions
    return [_ActionsInfo(actions = actions)]

_inspect_aspect = aspect(
    implementation = _inspect_impl,
    attr_aspects = ["deps"],
    requires = [flutter_kernel_module_aspect],
    doc = "Collects the actions of the target and of its dependency closure.",
)

def _source_reach_impl(ctx):
    """A body edit in one package reaches only that package's module, the entry and the link."""
    env = analysistest.begin(ctx)
    actions = analysistest.target_under_test(env)[_ActionsInfo].actions
    modules = [a for a in actions if a.mnemonic == "DartKernel" and not _has_output(a, "_product.kmod")]
    reading = [
        a
        for a in modules
        if any([p.endswith("registrant_twin_fixture/app/lib/app.dart") for p in _paths(a)])
    ]
    names = sorted([[f.basename for f in a.outputs.to_list() if f.basename.endswith(".kmod")][0] for a in reading])
    asserts.equals(env, ["app.flutter.kmod"], names, "only the edited package's module reads its sources")
    link = _by_mnemonic(env, "DartKernelLink")[0]
    asserts.false(env, any(["app.dart" in p for p in _paths(link)]), "the link reads modules, not sources")
    plain = [p for p in _paths(link) if p.endswith("flutter.flutter.kmod")]
    asserts.equals(env, [], plain, "the plain SDK module is not linked")
    return analysistest.end(env)

def _probe_kernel_impl(ctx):
    """Exercises `flutter_compile_kernel` with individual whole-program fallback selectors."""
    manifest = None
    if ctx.attr.with_manifest:
        manifest = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
        ctx.actions.write(manifest, "{}")
    recorded = ctx.actions.declare_file(ctx.label.name + ".recorded_uses.json") if ctx.attr.with_recorded_uses else None
    dill = flutter_compile_kernel(
        ctx = ctx,
        flutter_sdk_info = resolve_flutter_sdk_info(ctx),
        target = make_kernel_target(
            frontend_server_target = ctx.attr.frontend_target,
        ),
        inputs = make_kernel_inputs(
            native_assets_manifest = manifest,
            track_widget_creation = ctx.attr.track_widget_creation,
            recorded_uses = recorded,
        ),
    ).kernel_dill
    outs = [dill] + ([recorded] if recorded else [])
    return [DefaultInfo(files = depset(outs))]

_PROBE_TOOLCHAINS = [
    "@rules_flutter//flutter:toolchain_type",
    config_common.toolchain_type("@rules_flutter//flutter/private:product_tools_toolchain_type", mandatory = False),
] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS

_probe_kernel = rule(
    implementation = _probe_kernel_impl,
    attrs = KERNEL_COMPILE_ATTRS | DEFINES_FILES_APPLICATION_ATTRS | AGENT_EXTENSIONS_ATTR | MODULAR_KERNEL_ATTRS | {
        "deps": attr.label_list(providers = [DartInfo], aspects = [flutter_kernel_module_aspect]),
        "track_widget_creation": attr.bool(default = False),
        "with_manifest": attr.bool(default = False),
        "with_recorded_uses": attr.bool(default = False),
        "frontend_target": attr.string(default = "flutter"),
    },
    toolchains = _PROBE_TOOLCHAINS,
    doc = "Synthetic caller of `flutter_compile_kernel` for testing `_use_modular_kernel` selectors.",
)

def _dill_fixture_impl(ctx):
    """Compiles a modular debug `.dill` with stub agent, real native agent, plugin and SDK registrant."""
    dill = flutter_compile_kernel(
        ctx = ctx,
        flutter_sdk_info = resolve_flutter_sdk_info(ctx),
        target = make_kernel_target(target_platform = "linux"),
        inputs = make_kernel_inputs(),
    ).kernel_dill
    return [DefaultInfo(files = depset([dill]))]

_dill_fixture = rule(
    implementation = _dill_fixture_impl,
    attrs = KERNEL_COMPILE_ATTRS | AGENT_EXTENSIONS_ATTR | MODULAR_KERNEL_ATTRS | {
        "deps": attr.label_list(providers = [DartInfo], aspects = [flutter_kernel_module_aspect]),
        "_agent_extensions_src": attr.label(
            allow_single_file = True,
            default = Label("//flutter/tests/kernel_target_modular_fixture:stub_agent.dart"),
        ),
    },
    toolchains = _PROBE_TOOLCHAINS,
    doc = "Builds a debug modular `.dill` over `kernel_target_modular_fixture` for binary verification.",
)

_modular_no_twin_test = analysistest.make(_modular_no_twin_impl, config_settings = _DBG)
_whole_program_test = analysistest.make(_whole_program_impl, config_settings = _DBG)
_profile_whole_program_test = analysistest.make(_whole_program_impl, config_settings = _PROFILE)
_global_define_whole_program_test = analysistest.make(
    _whole_program_impl,
    config_settings = _DBG | {str(Label("//flutter:extra_dart_defines")): ["GLOBAL=1"]},
)
_source_reach_test = analysistest.make(
    _source_reach_impl,
    config_settings = _DBG,
    extra_target_under_test_aspects = [_inspect_aspect],
)

def _declare_fallback_probes(name):
    """Declares `_probe_kernel` fixtures and analysis tests for each whole-program selector."""
    _probe_kernel(
        name = "_probe_frontend_flag",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        track_widget_creation = True,
        tags = ["manual"],
        deps = _TWIN_DEPS,
    )
    _probe_kernel(
        name = "_probe_manifest",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        with_manifest = True,
        tags = ["manual"],
        deps = _TWIN_DEPS,
    )
    _probe_kernel(
        name = "_probe_recorded_uses",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        with_recorded_uses = True,
        tags = ["manual"],
        deps = _TWIN_DEPS,
    )
    _probe_kernel(
        name = "_probe_define_flagfile",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        define_flagfiles = ["//flutter/tests/kernel_target_modular_fixture:flagfile.txt"],
        tags = ["manual"],
        deps = _TWIN_DEPS,
    )
    _probe_kernel(
        name = "_probe_web_target",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        frontend_target = "dartdevc",
        tags = ["manual"],
        deps = _TWIN_DEPS,
    )
    tests = []
    for suffix in ["frontend_flag", "manifest", "recorded_uses", "define_flagfile", "web_target"]:
        tname = "%s_%s" % (name, suffix)
        _whole_program_test(name = tname, target_under_test = ":_probe_" + suffix)
        tests.append(tname)
    return tests

def kernel_target_modular_test_suite(name):
    """Declares the fixtures, the analysis tests and the debug `.dill` target.

    Args:
        name: The test_suite name.
    """
    flutter_kernel_target(
        name = "kernel_target_modular_twin",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
        deps = _TWIN_DEPS,
    )
    flutter_kernel_target(
        name = "_kernel_target_twin_define",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        defines = ["A=1"],
        tags = ["manual"],
        deps = _TWIN_DEPS,
    )
    flutter_kernel_target(
        name = "_kernel_target_no_twin",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
        deps = ["//flutter/tests/registrant_twin_fixture/other"],
    )
    _dill_fixture(
        name = "_kernel_target_modular_dill_raw",
        package_name = "modular_dill_app",
        main = "//flutter/tests/kernel_target_modular_fixture:main.dart",
        tags = ["manual"],
        deps = [
            "//flutter/tests/kernel_target_modular_fixture/flutter",
            "//flutter/tests/kernel_target_modular_fixture/plugin",
        ],
    )
    debug_build(
        name = "kernel_target_modular_dill",
        tags = ["manual"],
        targets = [":_kernel_target_modular_dill_raw"],
    )
    _whole_program_test(name = name + "_define", target_under_test = ":_kernel_target_twin_define")
    _global_define_whole_program_test(name = name + "_global_define", target_under_test = ":kernel_target_modular_twin")
    _profile_whole_program_test(name = name + "_profile", target_under_test = ":kernel_target_modular_twin")
    _modular_no_twin_test(name = name + "_no_twin", target_under_test = ":_kernel_target_no_twin")
    _source_reach_test(name = name + "_source_reach", target_under_test = ":kernel_target_modular_twin")
    probe_tests = _declare_fallback_probes(name)
    native.test_suite(
        name = name,
        tests = [
            name + "_define",
            name + "_global_define",
            name + "_profile",
            name + "_no_twin",
            name + "_source_reach",
        ] + probe_tests,
    )
