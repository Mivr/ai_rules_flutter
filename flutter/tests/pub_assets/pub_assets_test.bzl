"""Tests for variant-aware pub asset expansion.

Covers the flutter_tools parity rules (`flutter_pub_assets.bzl`): file
entries bundle their main file plus resolution variants (variant-only
entries are accepted; missing mains fail), directory entries bundle their
own files plus variants (no recursion), and walks fail loudly at their
bound.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_assets.bzl",
    "expand_pub_asset_entries",
    "is_asset_variant_dir",
    "list_files_recursive",
)

# -- variant directory names ------------------------------------------------------

def _variant_dir_names_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in ["2x", "2.0x", "3.0x", "1.5x", "10x", "4x"]:
        asserts.true(env, is_asset_variant_dir(name), "%s is a variant dir" % name)
    for name in ["sub", "icons", "x", "foo", "2xx", "2xyz"]:
        asserts.false(env, is_asset_variant_dir(name), "%s is not a variant dir" % name)
    return unittest.end(env)

# -- bounded walk -------------------------------------------------------------------

_WALK_TREE = {
    "img": [
        struct(name = "logo.png", is_dir = False),
        struct(name = "2.0x", is_dir = True),
        struct(name = "sub", is_dir = True),
    ],
    "img/2.0x": [struct(name = "logo.png", is_dir = False)],
    "img/sub": [struct(name = "deep.png", is_dir = False)],
}

def _fake_readdir(directory):
    return _WALK_TREE.get(directory, [])

def _walk_lists_all_files_test_impl(ctx):
    env = unittest.begin(ctx)
    result = list_files_recursive(_fake_readdir, "img", "walk_pkg", 100)
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["img/2.0x/logo.png", "img/logo.png", "img/sub/deep.png"],
        sorted(result.files),
    )
    return unittest.end(env)

def _walk_bound_fails_loudly_test_impl(ctx):
    """A walk that reaches its bound reports the package and directory."""
    env = unittest.begin(ctx)
    result = list_files_recursive(_fake_readdir, "img", "walk_pkg", 1)
    asserts.equals(env, [], result.files)
    asserts.true(env, "walk_pkg" in result.error, result.error)
    asserts.true(env, "img" in result.error, result.error)
    return unittest.end(env)

# -- expansion ------------------------------------------------------------------------

_FAKE_FILES = {
    "img": [
        "img/logo.png",
        "img/banner.png",
        "img/2.0x/logo.png",
        "img/3.0x/logo.png",
        "img/2.0x/banner.png",
        "img/sub/deep.png",
    ],
    "lonely": ["lonely/2.0x/ghost.png"],
}

def _fake_list_dir(directory):
    return struct(files = _FAKE_FILES.get(directory, []), error = "")

def _file_entry_bundles_main_and_variants_test_impl(ctx):
    """The main file plus every variant, each with the entry's conditions."""
    env = unittest.begin(ctx)
    entries = [
        struct(path = "img/logo.png", flavors = ["paid"], platforms = ["ios"]),
    ]
    result = expand_pub_asset_entries(entries, _fake_list_dir, "variant_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["img/logo.png", "img/2.0x/logo.png", "img/3.0x/logo.png"],
        [e.path for e in result.expanded],
    )
    for entry in result.expanded:
        asserts.equals(env, ["paid"], entry.flavors)
        asserts.equals(env, ["ios"], entry.platforms)
    return unittest.end(env)

def _variant_only_entry_accepted_test_impl(ctx):
    """A missing main with variants bundles the variants, no error."""
    env = unittest.begin(ctx)
    entries = [struct(path = "lonely/ghost.png", flavors = [], platforms = [])]
    result = expand_pub_asset_entries(entries, _fake_list_dir, "variant_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(env, ["lonely/2.0x/ghost.png"], [e.path for e in result.expanded])
    return unittest.end(env)

def _missing_entry_fails_test_impl(ctx):
    """Neither main nor variant fails naming the package and the entry."""
    env = unittest.begin(ctx)
    entries = [struct(path = "img/absent.png", flavors = [], platforms = [])]
    result = expand_pub_asset_entries(entries, _fake_list_dir, "variant_pkg")
    asserts.equals(env, [], result.expanded)
    asserts.true(env, "variant_pkg" in result.error, result.error)
    asserts.true(env, "img/absent.png" in result.error, result.error)
    return unittest.end(env)

def _directory_entry_skips_nested_test_impl(ctx):
    """Own files plus their variants bundle; nested subdirectories do not."""
    env = unittest.begin(ctx)
    entries = [struct(path = "img/", flavors = [], platforms = ["android"])]
    result = expand_pub_asset_entries(entries, _fake_list_dir, "variant_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        [
            "img/banner.png",
            "img/2.0x/banner.png",
            "img/logo.png",
            "img/2.0x/logo.png",
            "img/3.0x/logo.png",
        ],
        [e.path for e in result.expanded],
    )
    for entry in result.expanded:
        asserts.equals(env, ["android"], entry.platforms)
    return unittest.end(env)

def _directory_bound_error_propagates_test_impl(ctx):
    """A listing failure reaches the caller instead of truncating silently."""
    env = unittest.begin(ctx)

    def _failing_list_dir(directory):
        return struct(files = [], error = "walk refused for " + directory)

    result = expand_pub_asset_entries(
        [struct(path = "img/", flavors = [], platforms = [])],
        _failing_list_dir,
        "variant_pkg",
    )
    asserts.equals(env, [], result.expanded)
    asserts.true(env, "img" in result.error, result.error)
    return unittest.end(env)

_t0_test = unittest.make(_variant_dir_names_test_impl)
_t1_test = unittest.make(_walk_lists_all_files_test_impl)
_t2_test = unittest.make(_walk_bound_fails_loudly_test_impl)
_t3_test = unittest.make(_file_entry_bundles_main_and_variants_test_impl)
_t4_test = unittest.make(_variant_only_entry_accepted_test_impl)
_t5_test = unittest.make(_missing_entry_fails_test_impl)
_t6_test = unittest.make(_directory_entry_skips_nested_test_impl)
_t7_test = unittest.make(_directory_bound_error_propagates_test_impl)

def pub_assets_test_suite(name):
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
    )
