"""A debug kernel target compiles the agent files under constant URIs, in per-package modules."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:app_entrypoint.bzl", "app_scheme_rel_path")
load("//flutter/private:flutter_kernel_target.bzl", "flutter_kernel_target")

visibility(["//flutter/tests/..."])

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}
_OPT = {
    "//command_line_option:compilation_mode": "opt",
    str(Label("//flutter:profile")): False,
}
_DEFINE = "-Dflutter.dart_plugin_registrant="

def _compile_argv(env):
    """Returns the single `FlutterKernelCompile` action's argv."""
    kernels = [a for a in analysistest.target_actions(env) if a.mnemonic == "FlutterKernelCompile"]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    return kernels[0].argv if kernels else []

def _actions(env, mnemonic):
    """Returns target actions with `mnemonic`."""
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _out(action):
    """Returns the `.kmod` basename produced by `action`."""
    return [f.basename for f in action.outputs.to_list() if f.basename.endswith(".kmod")][0]

def _paths(action):
    """Returns the input paths of `action`."""
    return [f.path for f in action.inputs.to_list()]

def _entry(env):
    """Returns the single `.flutter_entry.kmod` `DartKernel` action."""
    entries = [a for a in _actions(env, "DartKernel") if _out(a).endswith("flutter_entry.kmod")]
    asserts.equals(env, 1, len(entries), "expected one entry module")
    return entries[0] if entries else None

def _constant_uris_impl(ctx):
    """The entry module compiles the agent, native agent and registrant under constant URIs."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _actions(env, "FlutterKernelCompile"), "no whole-program compile")
    asserts.equals(env, 1, len(_actions(env, "DartKernelLink")), "one DartKernelLink")
    entry = _entry(env)
    argv = " ".join(entry.argv) if entry else ""
    paths = _paths(entry) if entry else []
    for name in ["agent_extensions", "native_agent_extensions", "plugin_registrant"]:
        uri = "org-dartlang-app:///_flutter_debug_agent/%s.dart" % name
        asserts.true(env, uri in argv, "the entry module compiles %s" % uri)
        asserts.true(
            env,
            any([p.endswith("/_flutter_debug_agent/%s.dart" % name) for p in paths]),
            "%s must be staged in one directory: %r" % (name, paths[:3]),
        )
    return analysistest.end(env)

def _twin_link_impl(ctx):
    """The link takes the registrant twin of the SDK `flutter` module, not the plain one."""
    env = analysistest.begin(ctx)
    link = _actions(env, "DartKernelLink")
    asserts.equals(env, 1, len(link), "one DartKernelLink")
    paths = _paths(link[0]) if link else []
    asserts.true(env, any([".flutter_registrant.kmod" in p for p in paths]), "the twin is linked")
    asserts.equals(env, [], [p for p in paths if "/flutter.flutter.kmod" in p], "the plain module is swapped out")
    return analysistest.end(env)

def _one_module_impl(ctx):
    """A module reads its own sources only, and the entry reads no dependency source: a body edit re-runs one."""
    env = analysistest.begin(ctx)
    for a in _actions(env, "DartKernel"):
        mod = _out(a)
        sources = [p for p in _paths(a) if p.endswith(".dart") and "/registrant_twin_fixture/" in p]
        for pkg in ["flutter", "app", "other"]:
            owned = mod.startswith(pkg + ".flutter")
            foreign = [p for p in sources if "/registrant_twin_fixture/%s/" % pkg in p]
            asserts.true(env, owned or not foreign, "%s must not read %s sources: %r" % (mod, pkg, foreign))
    return analysistest.end(env)

def _whole_program_impl(ctx):
    """A define still selects the whole-program kernel."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _actions(env, "DartKernelLink"), "no module link")
    _compile_argv(env)
    return analysistest.end(env)

def _no_constant_layout_impl(ctx):
    """Release and AOT builds do not stage the constant debug-agent layout."""
    env = analysistest.begin(ctx)
    argv = _compile_argv(env)
    asserts.equals(env, [], [a for a in argv if a.startswith(_DEFINE)], "no constant registrant outside debug")
    for a in argv:
        asserts.false(env, "_flutter_debug_agent" in a, "constant layout leaked into %r" % a)
    return analysistest.end(env)

_constant_uris_test = analysistest.make(_constant_uris_impl, config_settings = _DBG)
_twin_link_test = analysistest.make(_twin_link_impl, config_settings = _DBG)
_one_module_test = analysistest.make(_one_module_impl, config_settings = _DBG)
_whole_program_test = analysistest.make(_whole_program_impl, config_settings = _DBG)
_global_define_test = analysistest.make(
    _whole_program_impl,
    config_settings = _DBG | {str(Label("//flutter:extra_dart_defines")): ["FOO=1"]},
)
_release_test = analysistest.make(_no_constant_layout_impl, config_settings = _OPT)
_aot_dbg_test = analysistest.make(_no_constant_layout_impl, config_settings = _DBG)

def _rel_path_impl(ctx):
    """`app_scheme_rel_path` collapses paths under `_flutter_debug_agent/` across labels."""
    env = unittest.begin(ctx)
    gen = struct(short_path = "pkg/app.debug_agent/_flutter_debug_agent/plugin_registrant.dart")
    other = struct(short_path = "a/b/other.debug_agent/_flutter_debug_agent/plugin_registrant.dart")
    asserts.equals(env, "_flutter_debug_agent/plugin_registrant.dart", app_scheme_rel_path(gen))
    asserts.equals(env, app_scheme_rel_path(gen), app_scheme_rel_path(other))
    label_named = struct(short_path = "pkg/app_plugin_registrant.dart")
    asserts.equals(env, "pkg/app_plugin_registrant.dart", app_scheme_rel_path(label_named))
    asserts.equals(env, "external/r/x.dart", app_scheme_rel_path(struct(short_path = "../r/x.dart")))
    return unittest.end(env)

_rel_path_test = unittest.make(_rel_path_impl)

def agent_uris_test_suite(name):
    """Tests that the debug agent, native agent and registrant sit at constant URIs.

    Args:
        name: The test suite name.
    """
    flutter_kernel_target(
        name = "_agent_uris_kernel",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_agent_uris_kernel_aot",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        aot = True,
        tags = ["manual"],
    )
    flutter_kernel_target(
        name = "_agent_uris_kernel_deps",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        tags = ["manual"],
        deps = [
            "//flutter/tests/registrant_twin_fixture/app",
            "//flutter/tests/registrant_twin_fixture/other",
        ],
    )
    flutter_kernel_target(
        name = "_agent_uris_kernel_defines",
        package_name = "inputs_fixture",
        main = "lib/language_version_main.dart",
        defines = ["FOO=1"],
        tags = ["manual"],
    )
    _twin_link_test(name = name + "_twin_link", target_under_test = ":_agent_uris_kernel_deps")
    _one_module_test(name = name + "_one_module", target_under_test = ":_agent_uris_kernel_deps")
    _whole_program_test(name = name + "_own_defines", target_under_test = ":_agent_uris_kernel_defines")
    _global_define_test(name = name + "_global_define", target_under_test = ":_agent_uris_kernel")
    _global_define_test(name = name + "_global_define_deps", target_under_test = ":_agent_uris_kernel_deps")
    _constant_uris_test(name = name + "_bare_package", target_under_test = ":_agent_uris_kernel")
    _constant_uris_test(name = name + "_own_package", target_under_test = ":_agent_uris_kernel_deps")
    _constant_uris_test(
        name = name + "_other_package",
        target_under_test = "//flutter/tests/agent_uris_other:other_label_kernel",
    )
    _release_test(name = name + "_release", target_under_test = ":_agent_uris_kernel")
    _aot_dbg_test(name = name + "_aot_dbg", target_under_test = ":_agent_uris_kernel_aot")
    _rel_path_test(name = name + "_rel_path")
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_bare_package",
            ":" + name + "_own_package",
            ":" + name + "_other_package",
            ":" + name + "_twin_link",
            ":" + name + "_one_module",
            ":" + name + "_own_defines",
            ":" + name + "_global_define",
            ":" + name + "_global_define_deps",
            ":" + name + "_release",
            ":" + name + "_aot_dbg",
            ":" + name + "_rel_path",
        ],
    )
