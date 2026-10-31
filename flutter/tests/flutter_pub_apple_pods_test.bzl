"""Unit tests for CocoaPods resolution order, hub precomputation, and spoke resolution."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "detect_apple_swiftpm_deps",
)
load(
    "//flutter/private:flutter_pub_apple_pods.bzl",
    "detect_apple_cocoapods_deps",
    "format_message_11",
    "format_message_9",
    "precompute_hub_apple_pods",
    "read_ios_pod_native_deps",
    "resolve_pod",
)
load("//flutter/private:podfile_lock.bzl", "read_podfile_lock")
load("//flutter/private:swiftpm_resolved.bzl", "read_ios_native_deps")

_FIXTURE_LOCK = """PODS:
  - Flutter (1.0.0)
  - FlutterMacOS (1.0.0)
  - Firebase/Auth (10.0.0):
    - Firebase/Core (= 10.0.0)
    - FirebaseAuthPlatform (= 1.0.0)
  - Firebase/Core (10.0.0)
  - FirebaseAuthPlatform (1.0.0)
  - path_provider_foundation (0.0.1):
    - Flutter
    - FlutterMacOS
    - path_provider_foundation/Core (= 0.0.1)
  - path_provider_foundation/Core (0.0.1)
  - url_launcher_ios (0.0.1):
    - Flutter
    - url_launcher_platform_interface (= 1.0.0)
  - url_launcher_platform_interface (1.0.0)
  - custom_checkout_pod (1.2.0)
  - unmapped_pod (2.0.0)

DEPENDENCIES:
  - Firebase/Auth (from `~> 10.0.0`)
  - path_provider_foundation (from `.symlinks/plugins/path_provider_foundation/darwin`)
  - url_launcher_ios (from `.symlinks/plugins/url_launcher_ios/ios`)

EXTERNAL SOURCES:
  custom_checkout_pod:
    :git: https://github.com/example/custom.git
  path_provider_foundation:
    :path: .symlinks/plugins/path_provider_foundation/darwin
  url_launcher_ios:
    :path: .symlinks/plugins/url_launcher_ios/ios

SPEC CHECKSUMS:
  Flutter: 1111111111111111111111111111111111111111
  FlutterMacOS: 2222222222222222222222222222222222222222
  Firebase: 3333333333333333333333333333333333333333
  FirebaseAuthPlatform: 4444444444444444444444444444444444444444
  path_provider_foundation: 5555555555555555555555555555555555555555
  url_launcher_ios: 6666666666666666666666666666666666666666
  url_launcher_platform_interface: 7777777777777777777777777777777777777777
  custom_checkout_pod: 8888888888888888888888888888888888888888
  unmapped_pod: 9999999999999999999999999999999999999999

COCOAPODS: 1.14.3
"""

def _make_mock_spoke_ctx(files, attr):
    """Create a mock repository context for spoke tests.

    Args:
        files: Dict of file paths to content strings.
        attr: Dict of attributes for ctx.attr.

    Returns:
        A struct mimicking repository_ctx.
    """

    def _path(path_str):
        return struct(exists = (path_str in files))

    def _read(path_str):
        p = str(path_str)
        if p not in files:
            fail("mock ctx.read on missing file: " + p)
        return files[p]

    return struct(
        attr = struct(**attr),
        path = _path,
        read = _read,
    )

def _engine_pods_test_impl(ctx):
    env = unittest.begin(ctx)
    for pod in ["Flutter", "FlutterMacOS", "Flutter/Engine", "FlutterMacOS/Engine"]:
        res = resolve_pod(
            pod = pod,
            hub_name = "deps",
            all_package_names = [],
            podfile = None,
            lock_label = "//ios:Podfile.lock",
            ios_pod_deps = {},
            ios_pod_ignore = [],
        )
        asserts.equals(env, "skip", res.kind)
        asserts.equals(env, "", res.label)
    return unittest.end(env)

def _ios_pod_deps_test_impl(ctx):
    env = unittest.begin(ctx)
    pod_deps = {
        "Firebase/Auth": "//third_party:auth",
        "Firebase": "//third_party:firebase_core",
    }

    # Exact subspec wins over root key
    res_auth = resolve_pod("Firebase/Auth", "deps", [], None, "//:lock", pod_deps, [])
    asserts.equals(env, "label", res_auth.kind)
    asserts.equals(env, "//third_party:auth", res_auth.label)

    # Root key matches other subspecs and bare pod
    res_db = resolve_pod("Firebase/Firestore", "deps", [], None, "//:lock", pod_deps, [])
    asserts.equals(env, "label", res_db.kind)
    asserts.equals(env, "//third_party:firebase_core", res_db.label)

    res_core = resolve_pod("Firebase", "deps", [], None, "//:lock", pod_deps, [])
    asserts.equals(env, "label", res_core.kind)
    asserts.equals(env, "//third_party:firebase_core", res_core.label)
    return unittest.end(env)

def _flutter_plugin_pod_test_impl(ctx):
    env = unittest.begin(ctx)
    podfile = struct(
        plugin_pods = {"path_provider_foundation": "path_provider_foundation"},
        pods = {},
    )

    # Present in all_package_names resolves to platform spoke
    res_ios = resolve_pod(
        pod = "path_provider_foundation",
        hub_name = "deps",
        all_package_names = ["path_provider_foundation"],
        podfile = podfile,
        lock_label = "//:lock",
        ios_pod_deps = {},
        ios_pod_ignore = [],
        platform = "ios",
    )
    asserts.equals(env, "plugin", res_ios.kind)
    asserts.equals(env, "@deps__path_provider_foundation//:path_provider_foundation_apple_ios", res_ios.label)

    res_macos = resolve_pod(
        pod = "path_provider_foundation",
        hub_name = "deps",
        all_package_names = ["path_provider_foundation"],
        podfile = podfile,
        lock_label = "//:lock",
        ios_pod_deps = {},
        ios_pod_ignore = [],
        platform = "macos",
    )
    asserts.equals(env, "plugin", res_macos.kind)
    asserts.equals(env, "@deps__path_provider_foundation//:path_provider_foundation_apple_macos", res_macos.label)

    # Absent from all_package_names falls through to step 7
    res_absent = resolve_pod(
        pod = "path_provider_foundation",
        hub_name = "deps",
        all_package_names = ["other_pkg"],
        podfile = podfile,
        lock_label = "//:lock",
        ios_pod_deps = {},
        ios_pod_ignore = [],
    )
    asserts.equals(env, "unresolved", res_absent.kind)
    return unittest.end(env)

def _divergent_podspec_name_test_impl(ctx):
    env = unittest.begin(ctx)

    # Divergent podspec name: CocoaPods name is "Pigeon", pub package is "pigeon"
    podfile = struct(plugin_pods = {"Pigeon": "pigeon"}, pods = {})
    res = resolve_pod(
        pod = "Pigeon",
        hub_name = "deps",
        all_package_names = ["pigeon"],
        podfile = podfile,
        lock_label = "//:lock",
        ios_pod_deps = {},
        ios_pod_ignore = [],
        platform = "ios",
    )
    asserts.equals(env, "plugin", res.kind)
    asserts.equals(env, "@deps__pigeon//:pigeon_apple_ios", res.label)
    return unittest.end(env)

def _ios_pod_ignore_test_impl(ctx):
    env = unittest.begin(ctx)
    ignore = ["IgnoredPod", "RootPod/IgnoredSubspec"]

    # Bare pod dropped
    res_bare = resolve_pod("IgnoredPod", "deps", [], None, "//:lock", {}, ignore)
    asserts.equals(env, "drop", res_bare.kind)

    # Subspec of ignored root dropped
    res_sub = resolve_pod("IgnoredPod/Core", "deps", [], None, "//:lock", {}, ignore)
    asserts.equals(env, "drop", res_sub.kind)

    # Specific ignored subspec dropped
    res_spec = resolve_pod("RootPod/IgnoredSubspec", "deps", [], None, "//:lock", {}, ignore)
    asserts.equals(env, "drop", res_spec.kind)
    return unittest.end(env)

def _unresolved_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    pods = {"UnknownPod": struct(version = "1.2.3", deps = [], line = 10)}
    res = resolve_pod("UnknownPod", "deps", [], struct(pods = pods), "//ios:Podfile.lock", {}, [])
    asserts.equals(env, "unresolved", res.kind)
    asserts.equals(env, "1.2.3", res.version)
    asserts.equals(env, "//ios:Podfile.lock", res.lock_label)

    # Format Message 9
    msg9 = format_message_9("my_pkg", "//ios:Podfile.lock")
    asserts.true(env, "Plugin my_pkg has iOS native code but no entry in //ios:Podfile.lock" in msg9)

    # Format Message 11 with version and without reason
    msg1 = format_message_11("my_pkg", "UnknownPod", "1.2.3", "//ios:Podfile.lock", "")
    asserts.true(env, "Plugin my_pkg depends on CocoaPods pod UnknownPod 1.2.3 locked by //ios:Podfile.lock" in msg1)
    asserts.true(env, "which has no Bazel target. Map it in `flutter.pub(ios_pod_deps = ...)`" in msg1)

    # Format Message 11 without version and without reason
    msg2 = format_message_11("my_pkg", "UnknownPod", "", "//ios:Podfile.lock", "")
    asserts.true(env, "Plugin my_pkg depends on CocoaPods pod UnknownPod locked by //ios:Podfile.lock" in msg2)

    # Format Message 11 with version and reason
    msg3 = format_message_11("my_pkg", "UnknownPod", "1.2.3", "//ios:Podfile.lock", "Binary pod unsupported.")
    asserts.true(env, "which has no Bazel target. Binary pod unsupported. Map it in" in msg3)
    return unittest.end(env)

def _checkout_pods_order_test_impl(ctx):
    env = unittest.begin(ctx)

    # Checkout pod mapped in ios_pod_deps -> step 2
    res_map = resolve_pod("custom_checkout_pod", "deps", [], None, "//:lock", {"custom_checkout_pod": "//:cust"}, [])
    asserts.equals(env, "label", res_map.kind)
    asserts.equals(env, "//:cust", res_map.label)

    # Checkout pod dropped in ios_pod_ignore -> step 4
    res_ign = resolve_pod("custom_checkout_pod", "deps", [], None, "//:lock", {}, ["custom_checkout_pod"])
    asserts.equals(env, "drop", res_ign.kind)

    # Otherwise refused at step 7
    res_unres = resolve_pod("custom_checkout_pod", "deps", [], None, "//:lock", {}, [])
    asserts.equals(env, "unresolved", res_unres.kind)
    return unittest.end(env)

def _hub_precomputation_and_reader_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = read_podfile_lock(_FIXTURE_LOCK, "//ios:Podfile.lock")
    asserts.true(env, parsed.ok)

    all_pkgs = ["path_provider_foundation", "url_launcher_ios"]
    pod_deps = {"Firebase/Auth": "//third_party:auth"}
    pod_ignore = ["custom_checkout_pod"]

    precomputed = precompute_hub_apple_pods(
        hub_name = "deps",
        all_package_names = all_pkgs,
        podfile = parsed,
        lock_label = "//ios:Podfile.lock",
        ios_pod_deps = pod_deps,
        ios_pod_ignore = pod_ignore,
    )

    # Check precomputed results
    asserts.equals(env, "skip", precomputed["Flutter"]["kind"])
    asserts.equals(env, "label", precomputed["Firebase/Auth"]["kind"])
    asserts.equals(env, "plugin", precomputed["path_provider_foundation"]["kind"])
    asserts.equals(env, "drop", precomputed["custom_checkout_pod"]["kind"])
    asserts.equals(env, "unresolved", precomputed["unmapped_pod"]["kind"])

    # Simulate ios_native_deps.json content
    hub_json = json.encode({
        "ios_pod_deps": pod_deps,
        "ios_pod_ignore": pod_ignore,
        "ios_pods": precomputed,
        "swift_package_product_deps": {"ident:prod": "//:prod_label"},
        "version": 1,
    })

    # Verify read_ios_native_deps still works
    swiftpm_read = read_ios_native_deps(hub_json, "//:ios_native_deps.json", "deps")
    asserts.true(env, swiftpm_read.ok)
    asserts.equals(env, "//:prod_label", swiftpm_read.product_deps["ident:prod"])

    # Verify read_ios_pod_native_deps works
    cocoa_read = read_ios_pod_native_deps(hub_json, "//:ios_native_deps.json", "deps")
    asserts.true(env, cocoa_read.ok)
    asserts.equals(env, "skip", cocoa_read.ios_pods["Flutter"].kind)
    asserts.equals(env, "//third_party:auth", cocoa_read.ios_pods["Firebase/Auth"].label)
    asserts.equals(env, "drop", cocoa_read.ios_pods["custom_checkout_pod"].kind)

    # Reader validation errors
    bad_ver = read_ios_pod_native_deps(json.encode({"version": 2}), "//:file", "deps")
    asserts.false(env, bad_ver.ok)
    asserts.true(env, "unsupported version" in bad_ver.error)

    bad_deps = read_ios_pod_native_deps(json.encode({"version": 1, "ios_pod_deps": 123}), "//:file", "deps")
    asserts.false(env, bad_deps.ok)
    asserts.true(env, "has no `ios_pod_deps` object" in bad_deps.error)

    bad_ign = read_ios_pod_native_deps(
        json.encode({"version": 1, "ios_pod_deps": {}, "ios_pod_ignore": "str"}),
        "//:file",
        "deps",
    )
    asserts.false(env, bad_ign.ok)
    asserts.true(env, "has no `ios_pod_ignore` list" in bad_ign.error)

    bad_pods = read_ios_pod_native_deps(
        json.encode({"version": 1, "ios_pod_deps": {}, "ios_pod_ignore": [], "ios_pods": [1]}),
        "//:file",
        "deps",
    )
    asserts.false(env, bad_pods.ok)
    asserts.true(env, "has no `ios_pods` object" in bad_pods.error)
    return unittest.end(env)

def _spoke_dart_laziness_test_impl(ctx):
    env = unittest.begin(ctx)
    files_dart = {}
    mock_dart = _make_mock_spoke_ctx(files_dart, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:Podfile.lock",
    })
    res_dart = detect_apple_cocoapods_deps(
        mock_dart,
        "my_dart_pkg",
        struct(macos_srcs = [], ios_srcs = []),
        None,
    )
    asserts.equals(env, [], res_dart.macos)
    asserts.equals(env, [], res_dart.ios)
    return unittest.end(env)

def _spoke_matching_lock_entries_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = read_podfile_lock(_FIXTURE_LOCK, "//ios:Podfile.lock")
    precomputed = precompute_hub_apple_pods(
        hub_name = "deps",
        all_package_names = ["path_provider_foundation", "url_launcher_ios"],
        podfile = parsed,
        lock_label = "//ios:Podfile.lock",
        ios_pod_deps = {"url_launcher_platform_interface": "//third_party:url_interface"},
        ios_pod_ignore = [],
    )
    hub_json = json.encode({
        "ios_pod_deps": {"url_launcher_platform_interface": "//third_party:url_interface"},
        "ios_pod_ignore": [],
        "ios_pods": precomputed,
        "swift_package_product_deps": {},
        "version": 1,
    })
    files_url = {
        "//:Podfile.lock": _FIXTURE_LOCK,
        "//:ios_native_deps.json": hub_json,
    }
    mock_url = _make_mock_spoke_ctx(files_url, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:Podfile.lock",
    })
    res_url = detect_apple_cocoapods_deps(
        mock_url,
        "url_launcher_ios",
        struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
        None,
    )
    asserts.equals(env, ["//third_party:url_interface"], res_url.ios)
    return unittest.end(env)

def _spoke_zero_external_deps_test_impl(ctx):
    env = unittest.begin(ctx)
    files_path = {"//:Podfile.lock": _FIXTURE_LOCK}
    mock_path = _make_mock_spoke_ctx(files_path, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:Podfile.lock",
    })
    res_path = detect_apple_cocoapods_deps(
        mock_path,
        "path_provider_foundation",
        struct(macos_srcs = ["darwin/Classes"], ios_srcs = ["darwin/Classes"]),
        None,
    )
    asserts.equals(env, [], res_path.macos)
    asserts.equals(env, [], res_path.ios)
    return unittest.end(env)

def _spoke_missing_from_lock_no_spm_test_impl(ctx):
    env = unittest.begin(ctx)
    files_missing = {"//:Podfile.lock": _FIXTURE_LOCK}
    mock_missing = _make_mock_spoke_ctx(files_missing, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:Podfile.lock",
    })
    errors_m9 = []
    detect_apple_cocoapods_deps(
        mock_missing,
        "missing_plugin",
        struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
        None,
        fail_fn = errors_m9.append,
    )
    asserts.equals(env, 1, len(errors_m9))
    asserts.true(env, "Plugin missing_plugin has iOS native code but no entry in //:Podfile.lock" in errors_m9[0])
    return unittest.end(env)

def _spoke_missing_from_lock_with_spm_test_impl(ctx):
    env = unittest.begin(ctx)
    files_spm = {
        "//:Podfile.lock": _FIXTURE_LOCK,
        "ios/spm_plugin/Package.swift": "// manifest",
    }
    mock_spm = _make_mock_spoke_ctx(files_spm, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:Podfile.lock",
        "package_resolved": None,
        "package_sha256": None,
    })
    fallback_called = []

    def _mock_swiftpm(_c, pkg, plat, _srcs, _res_l, _chk_l, _nat_l, _hub):
        fallback_called.append((pkg, plat))
        return ["@spm//:target"]

    res_spm = detect_apple_cocoapods_deps(
        mock_spm,
        "spm_plugin",
        struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
        _mock_swiftpm,
    )
    asserts.equals(env, [("spm_plugin", "ios")], fallback_called)
    asserts.equals(env, ["@spm//:target"], res_spm.ios)
    return unittest.end(env)

def _spoke_unresolved_dep_fails_test_impl(ctx):
    env = unittest.begin(ctx)
    lock_with_unres = """PODS:
  - bad_plugin (1.0.0):
    - unmapped_pod (= 2.0.0)
  - unmapped_pod (2.0.0)
DEPENDENCIES:
  - bad_plugin (from `.symlinks/plugins/bad_plugin/ios`)
EXTERNAL SOURCES:
  bad_plugin:
    :path: .symlinks/plugins/bad_plugin/ios
"""
    parsed_bad = read_podfile_lock(lock_with_unres, "//:bad.lock")
    precomputed_bad = precompute_hub_apple_pods("deps", ["bad_plugin"], parsed_bad, "//:bad.lock", {}, [])
    hub_json_bad = json.encode({
        "ios_pod_deps": {},
        "ios_pod_ignore": [],
        "ios_pods": precomputed_bad,
        "swift_package_product_deps": {},
        "version": 1,
    })
    files_bad = {
        "//:bad.lock": lock_with_unres,
        "//:ios_native_deps.json": hub_json_bad,
    }
    mock_bad = _make_mock_spoke_ctx(files_bad, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:bad.lock",
    })
    errors_m11 = []
    detect_apple_cocoapods_deps(
        mock_bad,
        "bad_plugin",
        struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
        None,
        fail_fn = errors_m11.append,
    )
    asserts.equals(env, 1, len(errors_m11))
    asserts.true(env, "Plugin bad_plugin depends on CocoaPods pod unmapped_pod 2.0.0" in errors_m11[0])
    return unittest.end(env)

def _spoke_ios_plugin_deps_precedence_test_impl(ctx):
    env = unittest.begin(ctx)
    fake_ctx_pod7 = struct(attr = struct(
        plugin_native_deps = "@custom_mapped//:all",
        podfile_lock = "//:Podfile.lock",
    ))
    res_pod7 = detect_apple_swiftpm_deps(
        fake_ctx_pod7,
        "any_plugin",
        struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
    )
    asserts.equals(env, ["@custom_mapped//:all"], res_pod7.ios)
    return unittest.end(env)

def _golden_resolution_test_impl(ctx):
    env = unittest.begin(ctx)
    parsed = read_podfile_lock(_FIXTURE_LOCK, "//fixture:Podfile.lock")
    asserts.true(env, parsed.ok)
    all_pkgs = ["path_provider_foundation", "url_launcher_ios"]
    pod_deps = {
        "Firebase/Auth": "//vendor:firebase_auth",
        "custom_checkout_pod": "//vendor:custom_checkout",
    }
    pod_ignore = ["FirebaseAuthPlatform"]

    precomputed = precompute_hub_apple_pods(
        hub_name = "hub",
        all_package_names = all_pkgs,
        podfile = parsed,
        lock_label = "//fixture:Podfile.lock",
        ios_pod_deps = pod_deps,
        ios_pod_ignore = pod_ignore,
    )

    expected_kinds = {
        "Firebase/Auth": "label",
        "Firebase/Core": "unresolved",
        "FirebaseAuthPlatform": "drop",
        "Flutter": "skip",
        "FlutterMacOS": "skip",
        "custom_checkout_pod": "label",
        "path_provider_foundation": "plugin",
        "path_provider_foundation/Core": "plugin",
        "unmapped_pod": "unresolved",
        "url_launcher_ios": "plugin",
        "url_launcher_platform_interface": "unresolved",
    }

    for pod_name, expected_kind in expected_kinds.items():
        asserts.true(env, pod_name in precomputed, "missing pod " + pod_name)
        asserts.equals(env, expected_kind, precomputed[pod_name]["kind"])

    asserts.equals(env, "//vendor:firebase_auth", precomputed["Firebase/Auth"]["label"])
    asserts.equals(env, "//vendor:custom_checkout", precomputed["custom_checkout_pod"]["label"])
    asserts.equals(env, "path_provider_foundation", precomputed["path_provider_foundation"]["package"])
    asserts.equals(env, "url_launcher_ios", precomputed["url_launcher_ios"]["package"])
    asserts.equals(env, "2.0.0", precomputed["unmapped_pod"]["version"])
    return unittest.end(env)

_engine_pods_test = unittest.make(_engine_pods_test_impl)
_ios_pod_deps_test = unittest.make(_ios_pod_deps_test_impl)
_flutter_plugin_pod_test = unittest.make(_flutter_plugin_pod_test_impl)
_divergent_podspec_name_test = unittest.make(_divergent_podspec_name_test_impl)
_ios_pod_ignore_test = unittest.make(_ios_pod_ignore_test_impl)
_unresolved_refusal_test = unittest.make(_unresolved_refusal_test_impl)
_checkout_pods_order_test = unittest.make(_checkout_pods_order_test_impl)
_hub_precomputation_and_reader_test = unittest.make(_hub_precomputation_and_reader_test_impl)
_spoke_dart_laziness_test = unittest.make(_spoke_dart_laziness_test_impl)
_spoke_matching_lock_entries_test = unittest.make(_spoke_matching_lock_entries_test_impl)
_spoke_zero_external_deps_test = unittest.make(_spoke_zero_external_deps_test_impl)
_spoke_missing_from_lock_no_spm_test = unittest.make(_spoke_missing_from_lock_no_spm_test_impl)
_spoke_missing_from_lock_with_spm_test = unittest.make(_spoke_missing_from_lock_with_spm_test_impl)
_spoke_unresolved_dep_fails_test = unittest.make(_spoke_unresolved_dep_fails_test_impl)
_spoke_ios_plugin_deps_precedence_test = unittest.make(_spoke_ios_plugin_deps_precedence_test_impl)
_golden_resolution_test = unittest.make(_golden_resolution_test_impl)

def flutter_pub_apple_pods_test_suite(name):
    """Test suite for CocoaPods dependency resolution in rules_flutter."""
    unittest.suite(
        name + "_unit",
        _engine_pods_test,
        _ios_pod_deps_test,
        _flutter_plugin_pod_test,
        _divergent_podspec_name_test,
        _ios_pod_ignore_test,
        _unresolved_refusal_test,
        _checkout_pods_order_test,
        _hub_precomputation_and_reader_test,
        _spoke_dart_laziness_test,
        _spoke_matching_lock_entries_test,
        _spoke_zero_external_deps_test,
        _spoke_missing_from_lock_no_spm_test,
        _spoke_missing_from_lock_with_spm_test,
        _spoke_unresolved_dep_fails_test,
        _spoke_ios_plugin_deps_precedence_test,
        _golden_resolution_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )
