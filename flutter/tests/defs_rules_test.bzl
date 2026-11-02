"""Direct `rules_testing` analysis tests for `//flutter:defs.bzl` rules."""

load("@rules_testing//lib:analysis_test.bzl", "analysis_test", "test_suite")
load("//flutter:defs.bzl", "flutter_native_library")
load("//flutter:providers.bzl", "FlutterNativeLibraryInfo")
load(":rule_coverage.bzl", "expect_default_outputs", "expect_no_actions")

def _flutter_native_library_analysis_test_impl(env, target):
    env.expect.that_target(target).has_provider(FlutterNativeLibraryInfo)
    expect_default_outputs(env, target, ["libasset_fixture.so"])
    expect_no_actions(env, target)

def _flutter_native_library_analysis_test(name):
    flutter_native_library(
        name = name + "_subject",
        library = "//flutter/tests/dart_asset_fixture:asset_fixture_shared",
        binding_contract = ["asset_keys_own.txt"],
        tags = ["manual"],
    )
    analysis_test(
        name = name,
        impl = _flutter_native_library_analysis_test_impl,
        target = name + "_subject",
    )

def defs_rules_test_suite(name):
    """Direct analysis tests for `flutter_native_library`.

    Args:
        name: The test suite name.
    """
    test_suite(
        name = name,
        tests = [
            _flutter_native_library_analysis_test,
        ],
    )
