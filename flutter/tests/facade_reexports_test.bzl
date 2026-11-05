"""Unit tests for the symbols the public facades re-export.

Generated repositories, `e2e/` workspaces and `tests/rules_testing` load these
from `@rules_flutter//flutter:*.bzl` rather than from `flutter/private`, so a
facade that drops one breaks them at load time. Each symbol is loaded here
and asserted non-None.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("@rules_dart//dart:providers.bzl", "DartTestRunnerInfo", "DartTestRunnerSnapshotInfo")
load("//flutter:android.bzl", "flutter_android_engine", "flutter_android_engine_jar")
load("//flutter:ios.bzl", "flutter_ios_framework")
load("//flutter:macos.bzl", "flutter_apple_plugin_objc_library", "flutter_apple_plugin_objc_settings")
load("//flutter:providers.bzl", "FlutterLinuxPluginInfo", "FlutterWindowsPluginInfo")
load("//flutter:repositories.bzl", "flutter_sky_engine_repo")
load(
    "//flutter:toolchain.bzl",
    "flutter_sdk_binary",
    "xtool_darwin_cc_toolchain_config",
    "xtool_darwin_sdk_status",
    "xtool_darwin_sdk_target",
)
load(
    "//flutter:utils.bzl",
    "flutter_pub_scc_member_target",
    "pinned_download",
    "pinned_download_and_extract",
)
load("//flutter/private:flutter_pub_package_helpers.bzl", "make_flutter_test_package_bzl_content")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

visibility(["//flutter/tests/..."])

def _android_facade_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, flutter_android_engine != None)
    asserts.true(env, flutter_android_engine_jar != None)
    return unittest.end(env)

def _apple_facades_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, flutter_ios_framework != None)
    asserts.true(env, flutter_apple_plugin_objc_library != None)
    asserts.true(env, flutter_apple_plugin_objc_settings != None)
    return unittest.end(env)

def _toolchain_facade_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, flutter_sdk_binary != None)
    asserts.true(env, xtool_darwin_cc_toolchain_config != None)
    asserts.true(env, xtool_darwin_sdk_status != None)
    asserts.true(env, xtool_darwin_sdk_target != None)
    return unittest.end(env)

def _utils_and_repositories_facade_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, flutter_sky_engine_repo != None)
    asserts.true(env, flutter_pub_scc_member_target != None)
    asserts.true(env, pinned_download != None)
    asserts.true(env, pinned_download_and_extract != None)
    return unittest.end(env)

def _providers_facade_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, FlutterLinuxPluginInfo != None)
    asserts.true(env, FlutterWindowsPluginInfo != None)
    asserts.true(env, DartTestRunnerInfo != None)
    asserts.true(env, DartTestRunnerSnapshotInfo != None)
    return unittest.end(env)

def _generated_test_package_loads_test_impl(ctx):
    env = unittest.begin(ctx)
    for forward in (False, True):
        content = make_flutter_test_package_bzl_content(forward_flutter_providers = forward)
        asserts.true(env, "@rules_dart//dart:providers.bzl" in content, content)
        asserts.true(env, "DartTestRunnerSnapshotInfo" in content, content)
        asserts.true(env, "dart/private" not in content, content)
    return unittest.end(env)

_android_facade_test = unittest.make(_android_facade_test_impl)
_apple_facades_test = unittest.make(_apple_facades_test_impl)
_toolchain_facade_test = unittest.make(_toolchain_facade_test_impl)
_utils_and_repositories_facade_test = unittest.make(_utils_and_repositories_facade_test_impl)
_providers_facade_test = unittest.make(_providers_facade_test_impl)
_generated_test_package_loads_test = unittest.make(_generated_test_package_loads_test_impl)

def facade_reexports_test_suite(name):
    """Defines the facade re-export tests.

    Args:
      name: The `test_suite` target name.
    """
    small_unittest_suite(
        name,
        _android_facade_test,
        _apple_facades_test,
        _toolchain_facade_test,
        _utils_and_repositories_facade_test,
        _providers_facade_test,
        _generated_test_package_loads_test,
    )
