"""Tests for platform- and flavor-conditional pub assets.

Mirrors `flutter_tools` (`packages/flutter_tools/lib/src/asset.dart`):
`matchesFlavor` is checked first — a flavor-restricted entry bundles only
when a flavor is selected (rules_flutter selects none yet, so never) — then
`matchesPlatform`, where an empty list or the `tester` platform keeps the
asset and anything else must name the target's `osName`.

Covers the pure filter (`pub_asset_matches_target`), the fetch-time
validation helpers (`VALID_ASSET_PLATFORMS`, `invalid_asset_platforms`,
`asset_platform_error`), directory expansion (`expand_pub_asset_entries`),
and the rule-level plumbing: `pkg_asset_platforms` / `pkg_asset_flavors`
reach `FlutterInfo.pub_assets`, and `aggregate_pub_contributions` filters
them per platform.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:providers.bzl", "FlutterInfo")
load(
    "//flutter/private:flutter_library.bzl",
    "aggregate_pub_contributions",
    "flutter_library",
    "pub_asset_matches_target",
)
load("//flutter/private:flutter_plugin.bzl", "flutter_plugin")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "expand_pub_asset_entries",
)
load(
    "//flutter/private:flutter_pubspec.bzl",
    "VALID_ASSET_PLATFORMS",
    "asset_platform_error",
    "invalid_asset_platforms",
)

# -- pub_asset_matches_target ---------------------------------------------------

def _matches_unconditional_everywhere_test_impl(ctx):
    env = unittest.begin(ctx)
    for platform in ["android", "ios", "macos", "linux", "windows", "web", "tester"]:
        asserts.true(
            env,
            pub_asset_matches_target([], [], platform),
            "unconditional asset must bundle on %s" % platform,
        )
    return unittest.end(env)

def _matches_android_only_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, pub_asset_matches_target([], ["android"], "android"))
    asserts.false(env, pub_asset_matches_target([], ["android"], "web"))
    asserts.false(env, pub_asset_matches_target([], ["android"], "ios"))
    return unittest.end(env)

def _matches_tester_keeps_platform_entries_test_impl(ctx):
    """`tester` is the flutter_tools exception: every platform entry bundles."""
    env = unittest.begin(ctx)
    asserts.true(env, pub_asset_matches_target([], ["android"], "tester"))
    asserts.true(env, pub_asset_matches_target([], ["web"], "tester"))
    asserts.true(env, pub_asset_matches_target([], ["ios"], "tester"))
    return unittest.end(env)

def _matches_flavor_dropped_without_selection_test_impl(ctx):
    """No flavor is ever selected, so flavor-restricted entries bundle nowhere."""
    env = unittest.begin(ctx)
    for platform in ["android", "web", "tester"]:
        asserts.false(
            env,
            pub_asset_matches_target(["paid"], [], platform),
            "flavor-restricted asset must not bundle on %s without a flavor" % platform,
        )
    return unittest.end(env)

def _matches_flavor_checked_before_platform_test_impl(ctx):
    """Flavor runs first: a paid android-only asset stays out of android builds."""
    env = unittest.begin(ctx)
    asserts.false(
        env,
        pub_asset_matches_target(["paid"], ["android"], "android"),
        "flavor mismatch drops the asset even when the platform matches",
    )
    return unittest.end(env)

def _matches_selected_flavor_test_impl(ctx):
    """A selected flavor matching the entry bundles (flutter_tools parity)."""
    env = unittest.begin(ctx)
    asserts.true(
        env,
        pub_asset_matches_target(["paid"], ["android"], "android", flavor = "paid"),
    )
    asserts.false(
        env,
        pub_asset_matches_target(["paid"], ["android"], "android", flavor = "free"),
    )
    return unittest.end(env)

# -- validation helpers ----------------------------------------------------------

def _valid_platforms_cover_flutter_tools_set_test_impl(ctx):
    env = unittest.begin(ctx)
    for platform in ["android", "ios", "web", "windows", "linux", "macos"]:
        asserts.true(
            env,
            platform in VALID_ASSET_PLATFORMS,
            "%s must be a valid asset platform" % platform,
        )
    return unittest.end(env)

def _invalid_asset_platforms_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, [], invalid_asset_platforms(["android", "web"]))
    asserts.equals(env, [], invalid_asset_platforms([]))
    asserts.equals(
        env,
        ["fuchsia"],
        invalid_asset_platforms(["android", "fuchsia"]),
    )
    return unittest.end(env)

def _asset_platform_error_names_package_entry_valid_test_impl(ctx):
    env = unittest.begin(ctx)
    message = asset_platform_error("my_pkg", "assets/odd.txt", ["fuchsia"])
    asserts.true(env, "my_pkg" in message, "error must name the package")
    asserts.true(env, "assets/odd.txt" in message, "error must name the asset entry")
    for platform in ["android", "ios", "web", "windows", "linux", "macos"]:
        asserts.true(env, platform in message, "error must list valid names")
    return unittest.end(env)

# -- directory expansion ----------------------------------------------------------

def _fake_list_dir(directory):
    if directory == "assets/icons":
        return ["assets/icons/a.png", "assets/icons/b.png"]
    return []

def _expand_files_pass_through_test_impl(ctx):
    env = unittest.begin(ctx)
    entries = [
        struct(path = "assets/any.txt", flavors = [], platforms = []),
        struct(path = "assets/android_only.txt", flavors = [], platforms = ["android"]),
    ]
    expanded = expand_pub_asset_entries(entries, _fake_list_dir)
    asserts.equals(env, 2, len(expanded))
    asserts.equals(env, "assets/any.txt", expanded[0].path)
    asserts.equals(env, [], expanded[0].platforms)
    asserts.equals(env, ["android"], expanded[1].platforms)
    return unittest.end(env)

def _expand_directory_inherits_conditions_test_impl(ctx):
    """Every file under a conditioned directory inherits its conditions."""
    env = unittest.begin(ctx)
    entries = [
        struct(path = "assets/icons/", flavors = [], platforms = ["android"]),
    ]
    expanded = expand_pub_asset_entries(entries, _fake_list_dir)
    asserts.equals(env, 2, len(expanded))
    paths = sorted([e.path for e in expanded])
    asserts.equals(env, ["assets/icons/a.png", "assets/icons/b.png"], paths)
    for entry in expanded:
        asserts.equals(env, ["android"], entry.platforms)
        asserts.equals(env, [], entry.flavors)
    return unittest.end(env)

def _expand_unconditional_directory_stays_unconditional_test_impl(ctx):
    env = unittest.begin(ctx)
    entries = [
        struct(path = "assets/icons/", flavors = [], platforms = []),
    ]
    expanded = expand_pub_asset_entries(entries, _fake_list_dir)
    asserts.equals(env, 2, len(expanded))
    for entry in expanded:
        asserts.equals(env, [], entry.platforms)
        asserts.equals(env, [], entry.flavors)
    return unittest.end(env)

# -- rule-level plumbing ------------------------------------------------------------

def _pub_assets_plumbing_test_impl(ctx):
    """`pkg_asset_platforms`/`pkg_asset_flavors` reach `FlutterInfo.pub_assets`."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    by_path = {
        entry.asset_path: entry
        for entry in target[FlutterInfo].pub_assets.to_list()
    }
    asserts.equals(
        env,
        ["android"],
        list(by_path["assets/android_only.txt"].platforms),
    )
    asserts.equals(
        env,
        ["web"],
        list(by_path["assets/web_only.txt"].platforms),
    )
    asserts.equals(
        env,
        ["paid"],
        list(by_path["assets/paid_only.txt"].flavors),
    )
    asserts.equals(env, [], list(by_path["assets/any.txt"].platforms))
    asserts.equals(env, [], list(by_path["assets/any.txt"].flavors))
    return analysistest.end(env)

def _bundle_filter_test_impl(ctx):
    """`aggregate_pub_contributions` keeps exactly the platform's entries."""
    env = analysistest.begin(ctx)
    _, copies = aggregate_pub_contributions(
        ctx.attr.probe_deps,
        ctx.attr.platform,
    )
    for key in ctx.attr.expected_present:
        asserts.true(
            env,
            key in copies,
            "%s must bundle on %s" % (key, ctx.attr.platform),
        )
    for key in ctx.attr.expected_absent:
        asserts.false(
            env,
            key in copies,
            "%s must not bundle on %s" % (key, ctx.attr.platform),
        )
    return analysistest.end(env)

_t0_test = unittest.make(_matches_unconditional_everywhere_test_impl)
_t1_test = unittest.make(_matches_android_only_test_impl)
_t2_test = unittest.make(_matches_tester_keeps_platform_entries_test_impl)
_t3_test = unittest.make(_matches_flavor_dropped_without_selection_test_impl)
_t4_test = unittest.make(_matches_flavor_checked_before_platform_test_impl)
_t5_test = unittest.make(_matches_selected_flavor_test_impl)
_t6_test = unittest.make(_valid_platforms_cover_flutter_tools_set_test_impl)
_t7_test = unittest.make(_invalid_asset_platforms_test_impl)
_t8_test = unittest.make(_asset_platform_error_names_package_entry_valid_test_impl)
_t9_test = unittest.make(_expand_files_pass_through_test_impl)
_t10_test = unittest.make(_expand_directory_inherits_conditions_test_impl)
_t11_test = unittest.make(_expand_unconditional_directory_stays_unconditional_test_impl)

_pub_assets_plumbing_test = analysistest.make(_pub_assets_plumbing_test_impl)

_bundle_filter_test = analysistest.make(
    _bundle_filter_test_impl,
    attrs = {
        "platform": attr.string(mandatory = True),
        "probe_deps": attr.label_list(mandatory = True),
        "expected_present": attr.string_list(mandatory = True),
        "expected_absent": attr.string_list(mandatory = True),
    },
)

def asset_platforms_test_suite(name):
    native.genrule(
        name = name + "_files",
        outs = [
            name + "_any.txt",
            name + "_android_only.txt",
            name + "_web_only.txt",
            name + "_paid_only.txt",
        ],
        cmd = "touch $(OUTS)",
    )

    flutter_library(
        name = name + "_probe_lib",
        srcs = ["app_entrypoint_sibling.dart"],
        package_name = "platform_probe",
        pkg_assets = {
            ":" + name + "_any.txt": "assets/any.txt",
            ":" + name + "_android_only.txt": "assets/android_only.txt",
            ":" + name + "_web_only.txt": "assets/web_only.txt",
            ":" + name + "_paid_only.txt": "assets/paid_only.txt",
        },
        pkg_asset_platforms = {
            ":" + name + "_android_only.txt": ["android"],
            ":" + name + "_web_only.txt": ["web"],
        },
        pkg_asset_flavors = {
            ":" + name + "_paid_only.txt": ["paid"],
        },
        tags = ["manual"],
    )

    flutter_plugin(
        name = name + "_probe_plugin",
        package_name = "platform_probe_plugin",
        pkg_assets = {
            ":" + name + "_android_only.txt": "assets/android_only.txt",
        },
        pkg_asset_platforms = {
            ":" + name + "_android_only.txt": ["android"],
        },
        tags = ["manual"],
    )

    _pub_assets_plumbing_test(
        name = name + "_plumbing",
        target_under_test = ":" + name + "_probe_lib",
    )

    _pub_assets_plumbing_test(
        name = name + "_plugin_plumbing",
        target_under_test = ":" + name + "_probe_plugin",
    )

    _bundle_filter_test(
        name = name + "_filter_android",
        target_under_test = ":" + name + "_probe_lib",
        platform = "android",
        probe_deps = [":" + name + "_probe_lib"],
        expected_present = [
            "packages/platform_probe/assets/any.txt",
            "packages/platform_probe/assets/android_only.txt",
        ],
        expected_absent = [
            "packages/platform_probe/assets/web_only.txt",
            "packages/platform_probe/assets/paid_only.txt",
        ],
    )

    _bundle_filter_test(
        name = name + "_filter_web",
        target_under_test = ":" + name + "_probe_lib",
        platform = "web",
        probe_deps = [":" + name + "_probe_lib"],
        expected_present = [
            "packages/platform_probe/assets/any.txt",
            "packages/platform_probe/assets/web_only.txt",
        ],
        expected_absent = [
            "packages/platform_probe/assets/android_only.txt",
            "packages/platform_probe/assets/paid_only.txt",
        ],
    )

    _bundle_filter_test(
        name = name + "_filter_tester",
        target_under_test = ":" + name + "_probe_lib",
        platform = "tester",
        probe_deps = [":" + name + "_probe_lib"],
        expected_present = [
            "packages/platform_probe/assets/any.txt",
            "packages/platform_probe/assets/android_only.txt",
            "packages/platform_probe/assets/web_only.txt",
        ],
        expected_absent = [
            "packages/platform_probe/assets/paid_only.txt",
        ],
    )

    unittest.suite(
        name + "_unit",
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
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_plumbing",
            ":" + name + "_plugin_plumbing",
            ":" + name + "_filter_android",
            ":" + name + "_filter_web",
            ":" + name + "_filter_tester",
        ],
    )
