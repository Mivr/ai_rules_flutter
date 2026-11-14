"""Analysis tests: a debug `flutter_application` links per-package modules unless the private flag is off.

- default flag, a plain debug app: `DartKernel` modules, one `DartKernelLink`, no `FlutterKernelCompile`;
- each selector (define, global define, define file, flavor, native asset, widget-creation
  tracking) keeps the whole-program compile;
- flag off, and a release build: one `FlutterKernelCompile`, no link;
- an app and a `flutter_test` over one library in one debug configuration analyse without conflicting
  actions, with the flag at its default and off.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("//flutter:defs.bzl", "flutter_application", "flutter_test")
load("//flutter/private:common.bzl", "HOST_COMPATIBLE")
load(":kernel_target_modular_test.bzl", "assert_kernel_target_dbg_modular")

visibility(["//flutter/tests/..."])

_FLAG = str(Label("//flutter/private:debug_modular_app"))
_DBG = {"//command_line_option:compilation_mode": "dbg", str(Label("//flutter:profile")): False}
_DBG_ON = _DBG | {_FLAG: True}
_DBG_OFF = _DBG | {_FLAG: False}
_DBG_ON_GLOBAL_DEFINE = _DBG_ON | {str(Label("//flutter:extra_dart_defines")): ["GLOBAL=1"]}
_OPT_ON = {"//command_line_option:compilation_mode": "opt", str(Label("//flutter:profile")): False, _FLAG: True}
_DEPS = ["//flutter/tests/registrant_twin_fixture/app"]
_APP = {
    "package_name": "inputs_fixture",
    "main": "lib/language_version_main.dart",
    "tags": ["manual"],
    "target_compatible_with": HOST_COMPATIBLE,
}

def _mnemonics(env, mnemonic):
    """The target's actions with this mnemonic."""
    return [a for a in analysistest.target_actions(env) if a.mnemonic == mnemonic]

def _modular_impl(ctx):
    """Flag on, a plain debug app: modules and one link, no whole-program compile."""
    env = analysistest.begin(ctx)
    asserts.equals(env, [], _mnemonics(env, "FlutterKernelCompile"), "no FlutterKernelCompile")
    assert_kernel_target_dbg_modular(env)
    return analysistest.end(env)

def _whole_program_impl(ctx):
    """One whole-program compile, no module and no link."""
    env = analysistest.begin(ctx)
    asserts.equals(env, 1, len(_mnemonics(env, "FlutterKernelCompile")), "one FlutterKernelCompile")
    asserts.equals(env, [], _mnemonics(env, "DartKernelLink"), "no DartKernelLink")
    asserts.equals(env, [], _mnemonics(env, "DartKernel"), "no DartKernel")
    return analysistest.end(env)

_modular_test = analysistest.make(_modular_impl, config_settings = _DBG)
_modular_on_test = analysistest.make(_modular_impl, config_settings = _DBG_ON)
_selector_test = analysistest.make(_whole_program_impl, config_settings = _DBG_ON)
_global_define_test = analysistest.make(_whole_program_impl, config_settings = _DBG_ON_GLOBAL_DEFINE)
_flag_off_test = analysistest.make(_whole_program_impl, config_settings = _DBG_OFF)
_release_test = analysistest.make(_whole_program_impl, config_settings = _OPT_ON)

def _shared_lib_test_impl(ctx):
    """The test target analyses beside an app over the same library: no conflicting actions."""
    env = analysistest.begin(ctx)
    asserts.true(env, len(_mnemonics(env, "DartKernel")) > 0 or len(_mnemonics(env, "FlutterKernelCompile")) > 0)
    return analysistest.end(env)

_shared_lib_default_test = analysistest.make(_shared_lib_test_impl, config_settings = _DBG)
_shared_lib_off_test = analysistest.make(_shared_lib_test_impl, config_settings = _DBG_OFF)

def _shared_lib_cases(name):
    """Declares an app and a `flutter_test` over one library, each analysed in both flag states.

    Args:
        name: The test_suite name.

    Returns:
        The test names.
    """
    flutter_application(name = "_shared_lib_app", **(_APP | {"deps": _DEPS}))
    flutter_test(
        name = "_shared_lib_flutter_test",
        package_name = "shared_lib_test",
        main = "lib/web_fixture_main.dart",
        deps = _DEPS + ["//flutter/tests/flutter_test_analyze_fixture/fake_test_api"],
        tags = ["manual"],
    )
    tests = []
    for flag, make in {"default": _shared_lib_default_test, "off": _shared_lib_off_test}.items():
        for kind in ["app", "flutter_test"]:
            test = "%s_shared_lib_%s_%s" % (name, kind, flag)
            make(name = test, target_under_test = ":_shared_lib_" + kind)
            tests.append(test)
    return tests

def debug_modular_app_test_suite(name):
    """Declares the fixture applications and the analysis tests.

    Args:
        name: The test_suite name.
    """
    write_file(name = "_modular_app_defines_file", out = "_modular_app.defines", content = ["A=1"], tags = ["manual"])
    variants = {
        "plain": {},
        "define": {"defines": ["A=1"]},
        "flagfile": {"define_flagfiles": [":_modular_app_defines_file"]},
        "flavor": {"flavor": "prod"},
        "widget_tracking": {"track_widget_creation": True},
        "native_asset": {"deps": ["//flutter/tests/modular_app_native_fixture:plugin"]},
    }
    for variant, extra in variants.items():
        flutter_application(name = "_modular_app_" + variant, **(_APP | {"deps": _DEPS} | extra))
    _modular_test(name = name + "_modular", target_under_test = ":_modular_app_plain")
    _modular_on_test(name = name + "_modular_explicit_on", target_under_test = ":_modular_app_plain")
    _flag_off_test(name = name + "_flag_off", target_under_test = ":_modular_app_plain")
    _release_test(name = name + "_release", target_under_test = ":_modular_app_plain")
    _global_define_test(name = name + "_global_define", target_under_test = ":_modular_app_plain")
    tests = _shared_lib_cases(name) + [name + "_modular", name + "_modular_explicit_on", name + "_flag_off", name + "_release", name + "_global_define"]
    for variant in ["define", "flagfile", "flavor", "widget_tracking", "native_asset"]:
        _selector_test(name = "%s_%s" % (name, variant), target_under_test = ":_modular_app_" + variant)
        tests.append("%s_%s" % (name, variant))
    native.test_suite(name = name, tests = tests)
