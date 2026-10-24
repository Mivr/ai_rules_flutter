"""Tests for variant-aware pub asset expansion and strict asset conditions.

Covers the flutter_tools parity rules (`flutter_pub_assets.bzl`): file
entries bundle their main file plus resolution variants (variant-only
entries are accepted; missing mains fail), directory entries bundle their
own files plus variants (no recursion), walks fail loudly at their bound,
and the entry parser refuses non-list `platforms` / `flavors` and
`transformers` while ignoring other unknown keys.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_assets.bzl",
    "asset_entry_problem_error",
    "expand_pub_asset_entries",
    "is_asset_variant_dir",
    "list_files_recursive",
)
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block")

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

# -- strict entry conditions ------------------------------------------------------------

_SCALAR_PLATFORMS_PUBSPEC = """\
name: scalar_platforms
flutter:
  assets:
    - path: assets/pic.png
      platforms: web
"""

_SCALAR_FLAVORS_PUBSPEC = """\
name: scalar_flavors
flutter:
  assets:
    - path: assets/pic.png
      flavors: paid
"""

_MIXED_ELEMENTS_PUBSPEC = """\
name: mixed_elements
flutter:
  assets:
    - path: assets/pic.png
      platforms:
        - ios
        - 5
"""

_TRANSFORMERS_PUBSPEC = """\
name: transformed
flutter:
  assets:
    - path: assets/pic.png
      transformers:
        - package: weave
"""

_UNKNOWN_KEYS_PUBSPEC = """\
name: unknown_keys
flutter:
  assets:
    - path: assets/kept.png
      platforms:
        - ios
      extra_key: ignored
    - path: assets/plain.png
      transformers:
"""

def _scalar_platforms_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_SCALAR_PLATFORMS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "assets/pic.png", problem.path)
    asserts.equals(env, "platforms", problem.key)
    message = asset_entry_problem_error("scalar_pkg", problem)
    for want in ["scalar_pkg", "assets/pic.png", "platforms"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

def _scalar_flavors_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_SCALAR_FLAVORS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "assets/pic.png", problem.path)
    asserts.equals(env, "flavors", problem.key)
    message = asset_entry_problem_error("scalar_pkg", problem)
    for want in ["scalar_pkg", "assets/pic.png", "flavors"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

def _non_string_element_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_MIXED_ELEMENTS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "platforms", problem.key)
    message = asset_entry_problem_error("mixed_pkg", problem)
    for want in ["mixed_pkg", "assets/pic.png", "platforms"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

def _transformers_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_TRANSFORMERS_PUBSPEC)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, "transformers", problem.key)
    message = asset_entry_problem_error("weave_pkg", problem)
    for want in ["weave_pkg", "assets/pic.png"]:
        asserts.true(env, want in message, message)
    asserts.true(
        env,
        "asset transformers are not supported by rules_flutter" in message,
        message,
    )
    return unittest.end(env)

def _unknown_keys_ignored_test_impl(ctx):
    """Keys flutter_tools ignores (and a null `transformers:`) stay accepted."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_UNKNOWN_KEYS_PUBSPEC)
    asserts.equals(env, [], result.asset_errors)
    asserts.equals(env, 2, len(result.assets))
    asserts.equals(env, "assets/kept.png", result.assets[0].path)
    asserts.equals(env, ["ios"], result.assets[0].platforms)
    return unittest.end(env)

_t0_test = unittest.make(_variant_dir_names_test_impl)
_t1_test = unittest.make(_walk_lists_all_files_test_impl)
_t2_test = unittest.make(_walk_bound_fails_loudly_test_impl)
_t3_test = unittest.make(_file_entry_bundles_main_and_variants_test_impl)
_t4_test = unittest.make(_variant_only_entry_accepted_test_impl)
_t5_test = unittest.make(_missing_entry_fails_test_impl)
_t6_test = unittest.make(_directory_entry_skips_nested_test_impl)
_t7_test = unittest.make(_directory_bound_error_propagates_test_impl)
_t8_test = unittest.make(_scalar_platforms_refused_test_impl)
_t9_test = unittest.make(_scalar_flavors_refused_test_impl)
_t10_test = unittest.make(_non_string_element_refused_test_impl)
_t11_test = unittest.make(_transformers_refused_test_impl)
_t12_test = unittest.make(_unknown_keys_ignored_test_impl)

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
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
    )
