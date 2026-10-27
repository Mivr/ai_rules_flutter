"""Unit tests for flutter_tools' resolution-variant rule in the manifest.

The manifest groups a variant under the key of the file in its own parent
directory (flutter_tools 3.47.7 `asset.dart:937-963`) and accepts any
`<number>x` variant directory name (`asset.dart:111`, `1626`). These tests
pin the decimal names the old seven-entry table missed, the parent-only
rule, and the seven names that already worked.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_asset_bundle.bzl", "build_asset_manifest", "detect_dpr")

def _decimal_variant_groups_test_impl(ctx):
    """`2.5x` and `0.75x` group under the main key with their dpr."""
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "assets/a.png",
        "assets/0.75x/a.png",
        "assets/2.5x/a.png",
    ])
    asserts.equals(env, ["assets/a.png"], sorted(manifest.keys()))
    variants = manifest["assets/a.png"]
    asserts.equals(
        env,
        ["assets/a.png", "assets/0.75x/a.png", "assets/2.5x/a.png"],
        [variant["asset"] for variant in variants],
    )
    asserts.equals(env, 0.75, variants[1]["dpr"])
    asserts.equals(env, 2.5, variants[2]["dpr"])
    return unittest.end(env)

def _detect_dpr_decimal_test_impl(ctx):
    """The ratio is the number in the file's immediate parent directory."""
    env = unittest.begin(ctx)
    asserts.equals(
        env,
        ("assets/a.png", 2.5),
        detect_dpr("assets/2.5x/a.png"),
    )
    asserts.equals(
        env,
        ("assets/a.png", 0.75),
        detect_dpr("assets/0.75x/a.png"),
    )
    asserts.equals(
        env,
        ("assets/a.png", 1.0),
        detect_dpr("assets/1.0x/a.png"),
    )
    asserts.equals(
        env,
        ("assets/a.png", 2.0),
        detect_dpr("assets/2.x/a.png"),
    )
    return unittest.end(env)

def _nested_variant_name_is_not_a_parent_test_impl(ctx):
    """A variant name higher in the path never folds into another key."""
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "assets/sub/a.png",
        "assets/2x/sub/a.png",
    ])
    asserts.equals(
        env,
        ["assets/2x/sub/a.png", "assets/sub/a.png"],
        sorted(manifest.keys()),
    )
    nested = manifest["assets/2x/sub/a.png"]
    asserts.equals(env, 1, len(nested))
    asserts.equals(env, "assets/2x/sub/a.png", nested[0]["asset"])
    asserts.false(env, "dpr" in nested[0], "nested variant has no dpr")
    main = manifest["assets/sub/a.png"]
    asserts.equals(env, 1, len(main))
    asserts.equals(env, "assets/sub/a.png", main[0]["asset"])
    return unittest.end(env)

def _seven_known_names_keep_keys_and_dpr_test_impl(ctx):
    """The seven names from the old table keep their keys and dpr.

    A `2.5x` variant rides along so this guard also fails on the old
    seven-name table: the seven entries must stay exactly as they were while
    the decimal name joins them.
    """
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "assets/a.png",
        "assets/1.5x/a.png",
        "assets/2x/a.png",
        "assets/2.0x/a.png",
        "assets/2.5x/a.png",
        "assets/3x/a.png",
        "assets/3.0x/a.png",
        "assets/4x/a.png",
        "assets/4.0x/a.png",
    ])
    asserts.equals(env, ["assets/a.png"], sorted(manifest.keys()))
    variants = manifest["assets/a.png"]
    asserts.equals(
        env,
        [
            "assets/a.png",
            "assets/1.5x/a.png",
            "assets/2.0x/a.png",
            "assets/2.5x/a.png",
            "assets/2x/a.png",
            "assets/3.0x/a.png",
            "assets/3x/a.png",
            "assets/4.0x/a.png",
            "assets/4x/a.png",
        ],
        [variant["asset"] for variant in variants],
    )
    asserts.false(env, "dpr" in variants[0], "the main entry has no dpr")
    asserts.equals(
        env,
        [1.5, 2.0, 2.5, 2.0, 3.0, 3.0, 4.0, 4.0],
        [variant["dpr"] for variant in variants[1:]],
    )
    return unittest.end(env)

def _pub_package_variants_group_test_impl(ctx):
    """Pub keys (`packages/<name>/...`) group exactly like app-own keys."""
    env = unittest.begin(ctx)
    manifest = build_asset_manifest([
        "packages/brand/assets/brand.png",
        "packages/brand/assets/2.0x/brand.png",
        "packages/brand/assets/2.5x/brand.png",
    ])
    asserts.equals(
        env,
        ["packages/brand/assets/brand.png"],
        sorted(manifest.keys()),
    )
    variants = manifest["packages/brand/assets/brand.png"]
    asserts.equals(env, 3, len(variants))
    asserts.equals(env, "packages/brand/assets/2.0x/brand.png", variants[1]["asset"])
    asserts.equals(env, 2.0, variants[1]["dpr"])
    asserts.equals(env, "packages/brand/assets/2.5x/brand.png", variants[2]["asset"])
    asserts.equals(env, 2.5, variants[2]["dpr"])
    return unittest.end(env)

_t0_test = unittest.make(_decimal_variant_groups_test_impl)
_t1_test = unittest.make(_detect_dpr_decimal_test_impl)
_t2_test = unittest.make(_nested_variant_name_is_not_a_parent_test_impl)
_t3_test = unittest.make(_seven_known_names_keep_keys_and_dpr_test_impl)
_t4_test = unittest.make(_pub_package_variants_group_test_impl)

def asset_variants_test_suite(name):
    """The resolution-variant manifest tests.

    Args:
        name: The generated `test_suite` name.
    """
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test)
