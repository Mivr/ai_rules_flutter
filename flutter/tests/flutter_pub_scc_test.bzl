"""Unit tests for flutter_pub SCC spoke and lock hub generation.

Covers:
1. Hub root BUILD.bazel and android/BUILD.bazel rendering with empty and populated scc_targets.
2. Cross-spoke spoke_dep_labels routing to scc_targets vs singletons.
3. cycle_breaks applied before SCC computation: broken 2-cycle, unbroken 2-cycle/3-cycle,
   3-cycle with one edge broken, and sub-cycle retention.
4. Merged spoke root BUILD.bazel and member <m>/BUILD.bazel + <m>/android/BUILD.bazel generation.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_cycle_breaks.bzl",
    "spoke_dep_labels",
)
load(
    "//flutter/private:flutter_pub_lock_hub.bzl",
    "make_flutter_pub_hub_android_build_content",
    "make_flutter_pub_hub_build_content",
)
load(
    "//flutter/private:flutter_pub_scc.bzl",
    "plan_flutter_pub_sccs",
)
load(
    "//flutter/private:flutter_pub_scc_build.bzl",
    "make_scc_member_android_build_content",
    "make_scc_member_build_content",
    "make_scc_merged_spoke_build_content",
)

def _hub_build_content_empty_scc_test_impl(ctx):
    """Hub BUILD and android/BUILD are byte-identical when scc_targets is empty."""
    env = unittest.begin(ctx)

    base_root = make_flutter_pub_hub_build_content(["bar", "foo"], "deps")
    explicit_root = make_flutter_pub_hub_build_content(["bar", "foo"], "deps", scc_targets = {})
    asserts.equals(env, base_root, explicit_root)

    base_android = make_flutter_pub_hub_android_build_content(["bar", "foo"], "deps")
    explicit_android = make_flutter_pub_hub_android_build_content(["bar", "foo"], "deps", scc_targets = {})
    asserts.equals(env, base_android, explicit_android)

    return unittest.end(env)

def _hub_build_content_with_sccs_test_impl(ctx):
    """Hub BUILD and android/BUILD route cycle members to the merged SCC spoke."""
    env = unittest.begin(ctx)

    scc_targets = {
        "cycle_a": "@deps__scc__cycle_a__cycle_b//:cycle_a",
        "cycle_b": "@deps__scc__cycle_a__cycle_b//:cycle_b",
    }
    packages = ["cycle_a", "cycle_b", "singleton_pkg"]

    root_content = make_flutter_pub_hub_build_content(packages, "deps", scc_targets = scc_targets)
    asserts.true(
        env,
        'actual = "@deps__scc__cycle_a__cycle_b//:cycle_a"' in root_content,
        root_content,
    )
    asserts.true(
        env,
        'actual = "@deps__scc__cycle_a__cycle_b//:cycle_b"' in root_content,
        root_content,
    )
    asserts.true(
        env,
        'actual = "@deps__singleton_pkg//:singleton_pkg"' in root_content,
        root_content,
    )

    android_content = make_flutter_pub_hub_android_build_content(packages, "deps", scc_targets = scc_targets)
    asserts.true(
        env,
        '"@deps__scc__cycle_a__cycle_b//cycle_a/android:lib"' in android_content,
        android_content,
    )
    asserts.true(
        env,
        '"@deps__scc__cycle_a__cycle_b//cycle_b/android:lib"' in android_content,
        android_content,
    )
    asserts.true(
        env,
        '"@deps__singleton_pkg//android:lib"' in android_content,
        android_content,
    )

    return unittest.end(env)

def _spoke_dep_labels_routing_test_impl(ctx):
    """Cross-spoke dep labels resolve via scc_targets when in a cycle."""
    env = unittest.begin(ctx)

    mock_ctx = struct(attr = struct(hub_name = "hub", scc_targets = {}))
    scc_targets = {
        "cycle_a": "@hub__scc__cycle_a__cycle_b//:cycle_a",
        "cycle_b": "@hub__scc__cycle_a__cycle_b//:cycle_b",
    }
    routed = spoke_dep_labels(mock_ctx, ["cycle_a", "other"], None, scc_targets = scc_targets)
    asserts.equals(env, ["@hub__scc__cycle_a__cycle_b//:cycle_a", "@hub__other//:other"], routed)

    unrouted = spoke_dep_labels(mock_ctx, ["cycle_a", "other"], None, scc_targets = {})
    asserts.equals(env, ["@hub__cycle_a//:cycle_a", "@hub__other//:other"], unrouted)

    mock_with_attr = struct(attr = struct(hub_name = "hub", scc_targets = scc_targets))
    attr_routed = spoke_dep_labels(mock_with_attr, ["cycle_a", "other"], None)
    asserts.equals(env, ["@hub__scc__cycle_a__cycle_b//:cycle_a", "@hub__other//:other"], attr_routed)

    return unittest.end(env)

def _cycle_breaks_before_scc_2cycle_test_impl(ctx):
    """Broken 2-cycle yields singletons; unbroken yields a merged SCC spoke."""
    env = unittest.begin(ctx)

    deps = {"a": ["b"], "b": ["a"]}

    unbroken = plan_flutter_pub_sccs(["a", "b"], "hub", deps, {})
    asserts.equals(env, [["a", "b"]], unbroken.sccs)
    asserts.equals(env, [], unbroken.singletons)
    asserts.equals(env, "@hub__scc__a__b//:a", unbroken.scc_targets.get("a"))
    asserts.equals(env, "@hub__scc__a__b//:b", unbroken.scc_targets.get("b"))

    broken = plan_flutter_pub_sccs(["a", "b"], "hub", deps, {"a": ["b"]})
    asserts.equals(env, [], broken.sccs)
    asserts.equals(env, ["a", "b"], sorted(broken.singletons))
    asserts.equals(env, {}, broken.scc_targets)

    return unittest.end(env)

def _cycle_breaks_before_scc_3cycle_test_impl(ctx):
    """Unbroken 3-cycle merges; one break dissolves the 3-cycle; sub-cycle persists."""
    env = unittest.begin(ctx)

    # Simple 3-cycle: a -> b -> c -> a
    deps_3 = {"a": ["b"], "b": ["c"], "c": ["a"]}

    unbroken = plan_flutter_pub_sccs(["a", "b", "c"], "hub", deps_3, {})
    asserts.equals(env, [["a", "b", "c"]], unbroken.sccs)
    asserts.equals(env, "@hub__scc__a__b__c//:a", unbroken.scc_targets.get("a"))
    asserts.equals(env, "@hub__scc__a__b__c//:b", unbroken.scc_targets.get("b"))
    asserts.equals(env, "@hub__scc__a__b__c//:c", unbroken.scc_targets.get("c"))

    broken_one = plan_flutter_pub_sccs(["a", "b", "c"], "hub", deps_3, {"a": ["b"]})
    asserts.equals(env, [], broken_one.sccs)
    asserts.equals(env, ["a", "b", "c"], sorted(broken_one.singletons))
    asserts.equals(env, {}, broken_one.scc_targets)

    # 3 packages where a <-> b form a 2-cycle and b -> c -> a
    deps_sub = {"a": ["b"], "b": ["a", "c"], "c": ["a"]}
    broken_sub = plan_flutter_pub_sccs(["a", "b", "c"], "hub", deps_sub, {"c": ["a"]})
    asserts.equals(env, [["a", "b"]], broken_sub.sccs)
    asserts.equals(env, ["c"], sorted(broken_sub.singletons))
    asserts.equals(env, "@hub__scc__a__b//:a", broken_sub.scc_targets.get("a"))
    asserts.equals(env, "@hub__scc__a__b//:b", broken_sub.scc_targets.get("b"))
    asserts.true(env, "c" not in broken_sub.scc_targets)

    return unittest.end(env)

def _merged_spoke_build_2cycle_test_impl(ctx):
    """Merged spoke BUILD and member BUILD files for a 2-cycle with assets and plugins."""
    env = unittest.begin(ctx)

    members = ["cycle_a", "cycle_b"]
    dep_labels = ["@hub__outside_dep//:outside_dep"]

    root_build = make_scc_merged_spoke_build_content("hub__scc__cycle_a__cycle_b", members, dep_labels)
    asserts.true(env, 'dart_library(\n    name = "merged",' in root_content_snippet(root_build), root_build)
    asserts.true(env, '"//cycle_a:cycle_a"' in root_build, root_build)
    asserts.true(env, '"//cycle_b:cycle_b"' in root_build, root_build)
    asserts.true(env, '"@hub__outside_dep//:outside_dep"' in root_build, root_build)
    asserts.true(env, 'flutter_pub_scc_member_target(\n    name = "cycle_a",' in root_build, root_build)
    asserts.true(env, 'flutter_pub_scc_member_target(\n    name = "cycle_b",' in root_build, root_build)
    asserts.true(env, '"//cycle_a:_flutter_info"' in root_build, root_build)
    asserts.true(env, '"//cycle_b:_flutter_info"' in root_build, root_build)

    mock_assets = struct(
        fonts_json_str = '[{"family": "CustomFont"}]',
        font_files = {":font.ttf": "fonts/font.ttf"},
        pkg_assets = {":asset.png": "assets/asset.png"},
        pkg_shaders = {":shader.frag": "shaders/shader.frag"},
        pkg_asset_platforms = None,
        pkg_asset_flavors = None,
    )
    mock_apple = struct(
        macos_srcs = ["macos/Classes/CycleAPlugin.swift"],
        ios_srcs = ["ios/Classes/CycleAPlugin.m"],
        macos_includes = [],
        ios_includes = [],
        macos_privacy = [],
        ios_privacy = [],
    )
    mock_plugin = struct(
        defines = ["CYCLE_A_DEFINE=1"],
        platforms_json = '{"ios":{"pluginClass":"CycleAPlugin"}}',
    )

    member_build = make_scc_member_build_content(
        "cycle_a",
        "3.4",
        version = "1.0.0",
        plugin = mock_plugin,
        assets = mock_assets,
        apple = mock_apple,
    )
    asserts.true(env, 'dart_package_member(\n    name = "cycle_a",' in member_build, member_build)
    asserts.true(env, 'flutter_pub_scc_member_info(\n    name = "_flutter_info",' in member_build, member_build)
    asserts.true(env, "CustomFont" in member_build, member_build)
    asserts.true(env, "shaders/shader.frag" in member_build, member_build)
    asserts.true(env, "assets/asset.png" in member_build, member_build)
    asserts.true(env, "cycle_a_apple_macos" in member_build, member_build)
    asserts.true(env, "cycle_a_apple_ios" in member_build, member_build)

    mock_android = struct(
        src_dir = "src/main/kotlin",
        java_package = "dev.example.cycle_a",
        extra_maven_labels = [],
        manifest = "src/main/AndroidManifest.xml",
        consumer_proguard_specs = [],
        has_resources = True,
    )
    android_build = make_scc_member_android_build_content("cycle_a", version = "1.0.0", android = mock_android)
    asserts.true(env, "kt_android_library" in android_build, android_build)
    asserts.true(env, 'custom_package = "dev.example.cycle_a"' in android_build, android_build)

    empty_android_build = make_scc_member_android_build_content("cycle_b", version = "1.0.0", android = None)
    asserts.true(env, "java_library" in empty_android_build, empty_android_build)
    asserts.true(env, "srcs = []" in empty_android_build, empty_android_build)

    return unittest.end(env)

def _merged_spoke_build_3cycle_test_impl(ctx):
    """Merged spoke BUILD for a 3-cycle includes all 3 members."""
    env = unittest.begin(ctx)

    members = ["tri_a", "tri_b", "tri_c"]
    root_build = make_scc_merged_spoke_build_content("hub__scc__tri_a__tri_b__tri_c", members, [])
    for m in members:
        asserts.true(env, '"//%s:%s"' % (m, m) in root_build, root_build)
        asserts.true(env, 'flutter_pub_scc_member_target(\n    name = "%s",' % m in root_build, root_build)
        asserts.true(env, '"//%s:_flutter_info"' % m in root_build, root_build)

    return unittest.end(env)

def root_content_snippet(content):
    """Helper to return content stripped of leading/trailing space for sub-checks."""
    return content.strip()

_hub_build_content_empty_scc_test = unittest.make(_hub_build_content_empty_scc_test_impl)
_hub_build_content_with_sccs_test = unittest.make(_hub_build_content_with_sccs_test_impl)
_spoke_dep_labels_routing_test = unittest.make(_spoke_dep_labels_routing_test_impl)
_cycle_breaks_before_scc_2cycle_test = unittest.make(_cycle_breaks_before_scc_2cycle_test_impl)
_cycle_breaks_before_scc_3cycle_test = unittest.make(_cycle_breaks_before_scc_3cycle_test_impl)
_merged_spoke_build_2cycle_test = unittest.make(_merged_spoke_build_2cycle_test_impl)
_merged_spoke_build_3cycle_test = unittest.make(_merged_spoke_build_3cycle_test_impl)

def flutter_pub_scc_test_suite(name):
    """Defines the flutter.pub SCC planner and spoke test suite."""
    unittest.suite(
        name,
        _hub_build_content_empty_scc_test,
        _hub_build_content_with_sccs_test,
        _spoke_dep_labels_routing_test,
        _cycle_breaks_before_scc_2cycle_test,
        _cycle_breaks_before_scc_3cycle_test,
        _merged_spoke_build_2cycle_test,
        _merged_spoke_build_3cycle_test,
    )
