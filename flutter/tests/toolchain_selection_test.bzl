"""Unit tests for the Flutter toolchain version selection in the `flutter` extension."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")

# buildifier: disable=bzl-visibility
load("//flutter/private:toolchain_selection.bzl", "select_toolchain_version")

def _req(version, is_root = False):
    return struct(version = version, is_root = is_root)

def _single_request_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.47.7", is_root = True)])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _latest_wins_numerically_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.0"), _req("3.47.7"), _req("3.44.8")])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _root_older_than_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.8", is_root = True), _req("3.47.7")])
    asserts.equals(env, "3.44.8", selection.version)
    asserts.true(env, selection.note != None)
    return unittest.end(env)

def _root_newer_than_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.47.7", is_root = True), _req("3.44.8")])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _root_equal_to_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.47.7", is_root = True), _req("3.47.7")])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _no_root_request_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.8"), _req("3.47.7")])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _several_root_tags_test_impl(ctx):
    env = unittest.begin(ctx)
    selection = select_toolchain_version("sdk", [_req("3.44.8", is_root = True), _req("3.47.7", is_root = True)])
    asserts.equals(env, "3.47.7", selection.version)
    asserts.equals(env, None, selection.note)
    return unittest.end(env)

def _several_toolchain_names_test_impl(ctx):
    env = unittest.begin(ctx)
    selection_sdk = select_toolchain_version("sdk", [_req("3.44.8", is_root = True)])
    selection_foo = select_toolchain_version("foo", [_req("3.41.2")])
    asserts.equals(env, "3.44.8", selection_sdk.version)
    asserts.equals(env, "3.41.2", selection_foo.version)
    return unittest.end(env)

_single_request_test = unittest.make(_single_request_test_impl)
_latest_wins_numerically_test = unittest.make(_latest_wins_numerically_test_impl)
_root_older_than_dep_test = unittest.make(_root_older_than_dep_test_impl)
_root_newer_than_dep_test = unittest.make(_root_newer_than_dep_test_impl)
_root_equal_to_dep_test = unittest.make(_root_equal_to_dep_test_impl)
_no_root_request_test = unittest.make(_no_root_request_test_impl)
_several_root_tags_test = unittest.make(_several_root_tags_test_impl)
_several_toolchain_names_test = unittest.make(_several_toolchain_names_test_impl)

def toolchain_selection_test_suite(name):
    """Unit tests for `select_toolchain_version` (root pin wins).

    Args:
      name: The test_suite target name.
    """
    unittest.suite(
        name,
        _single_request_test,
        _latest_wins_numerically_test,
        _root_older_than_dep_test,
        _root_newer_than_dep_test,
        _root_equal_to_dep_test,
        _no_root_request_test,
        _several_root_tags_test,
        _several_toolchain_names_test,
    )
