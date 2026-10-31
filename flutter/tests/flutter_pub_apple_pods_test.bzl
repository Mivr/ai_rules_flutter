"""Unit tests for CocoaPods resolution order, hub precomputation, and spoke resolution."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_apple.bzl",
    "detect_apple_swiftpm_deps",
    "with_apple_swiftpm_deps",
)
load(
    "//flutter/private:flutter_pub_apple_local.bzl",
    "apply_apple_native_deps",
)
load(
    "//flutter/private:flutter_pub_apple_pods.bzl",
    "detect_apple_cocoapods_deps",
    "format_message_11",
    "format_message_9",
    "precompute_hub_apple_pods",
    "read_ios_pod_native_deps",
    "resolve_binary_pod_stub",
    "resolve_pod",
    "resolve_swiftpm_pod_stub",
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

def _make_mock_spoke_ctx(files, attr, dirs = None):
    """Create a mock repository context for spoke tests.

    Args:
        files: Dict of file paths to content strings.
        attr: Dict of attributes for ctx.attr.
        dirs: Optional dict of directory paths to lists of child path strings.

    Returns:
        A struct mimicking repository_ctx.
    """
    dirs_dict = dirs if dirs != None else {}

    def _path(path_str):
        p = str(path_str)
        is_file = p in files
        is_dir = p in dirs_dict
        exists = is_file or is_dir
        base = p.rpartition("/")[2] if "/" in p else p

        def _readdir():
            children = dirs_dict.get(p, [])
            res = []
            for child in children:
                c_str = str(child)
                c_base = c_str.rpartition("/")[2] if "/" in c_str else c_str
                c_is_dir = c_str in dirs_dict
                res.append(struct(
                    basename = c_base,
                    is_dir = c_is_dir,
                ))
            return res

        return struct(
            exists = exists,
            is_dir = is_dir,
            basename = base,
            readdir = _readdir,
        )

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

def _step1_engine_pods_test_impl(ctx):
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

def _step2_ios_pod_deps_test_impl(ctx):
    env = unittest.begin(ctx)
    pod_deps = {
        "Firebase/Auth": "//third_party:auth",
        "Firebase": "//third_party:firebase_core",
    }

    # Subspec wins over root
    res_auth = resolve_pod("Firebase/Auth", "deps", [], None, "//:lock", pod_deps, [])
    asserts.equals(env, "label", res_auth.kind)
    asserts.equals(env, "//third_party:auth", res_auth.label)

    # Root fallback
    res_core_only = resolve_pod("Firebase/CoreOnly", "deps", [], None, "//:lock", pod_deps, [])
    asserts.equals(env, "label", res_core_only.kind)
    asserts.equals(env, "//third_party:firebase_core", res_core_only.label)

    res_bare = resolve_pod("Firebase", "deps", [], None, "//:lock", pod_deps, [])
    asserts.equals(env, "label", res_bare.kind)
    asserts.equals(env, "//third_party:firebase_core", res_bare.label)

    # ios_pod_deps wins over step 3 (sibling plugin pod)
    podfile = struct(plugin_pods = {"path_provider_foundation": "path_provider_foundation"}, pods = {})
    res_step3_override = resolve_pod(
        "path_provider_foundation",
        "deps",
        ["path_provider_foundation"],
        podfile,
        "//:lock",
        {"path_provider_foundation": "//custom:ppf"},
        [],
    )
    asserts.equals(env, "label", res_step3_override.kind)
    asserts.equals(env, "//custom:ppf", res_step3_override.label)

    # ios_pod_deps wins over step 4 (ios_pod_ignore)
    res_step4_override = resolve_pod(
        "GoogleMaps",
        "deps",
        [],
        None,
        "//:lock",
        {"GoogleMaps": "//maps:gm"},
        ["GoogleMaps"],
    )
    asserts.equals(env, "label", res_step4_override.kind)
    asserts.equals(env, "//maps:gm", res_step4_override.label)
    return unittest.end(env)

def _step3_flutter_plugin_pod_test_impl(ctx):
    env = unittest.begin(ctx)
    podfile = struct(
        plugin_pods = {"path_provider_foundation": "path_provider_foundation"},
        pods = {},
    )

    # Sibling plugin on iOS
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

    # Sibling plugin on macOS
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

    # Divergent podspec name: CocoaPods name "Pigeon", pub package "pigeon"
    podfile_divergent = struct(plugin_pods = {"Pigeon": "pigeon"}, pods = {})
    res_div = resolve_pod(
        pod = "Pigeon",
        hub_name = "deps",
        all_package_names = ["pigeon"],
        podfile = podfile_divergent,
        lock_label = "//:lock",
        ios_pod_deps = {},
        ios_pod_ignore = [],
        platform = "ios",
    )
    asserts.equals(env, "plugin", res_div.kind)
    asserts.equals(env, "@deps__pigeon//:pigeon_apple_ios", res_div.label)

    # Self-subspec edges skipped
    lock_self = """PODS:
  - my_plugin (1.0.0):
    - my_plugin/Core
  - my_plugin/Core (1.0.0):
    - ExternalPod (= 1.0.0)
    - Flutter
  - ExternalPod (1.0.0)
DEPENDENCIES:
  - my_plugin (from `.symlinks/plugins/my_plugin/ios`)
EXTERNAL SOURCES:
  my_plugin:
    :path: .symlinks/plugins/my_plugin/ios
"""
    parsed_self = read_podfile_lock(lock_self, "//:self.lock")
    pre_self = precompute_hub_apple_pods(
        "deps",
        ["my_plugin"],
        parsed_self,
        "//:self.lock",
        {"ExternalPod": "//ext:target"},
        [],
    )
    hub_json_self = json.encode({
        "ios_pod_deps": {"ExternalPod": "//ext:target"},
        "ios_pod_ignore": [],
        "ios_pods": pre_self,
        "swift_package_product_deps": {},
        "version": 1,
    })
    files_self = {
        "//:self.lock": lock_self,
        "//:ios_native_deps.json": hub_json_self,
    }
    mock_self = _make_mock_spoke_ctx(files_self, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:self.lock",
    })
    res_self = detect_apple_cocoapods_deps(
        mock_self,
        "my_plugin",
        struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
        None,
    )
    asserts.equals(env, ["//ext:target"], res_self.ios)

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

def _step4_ios_pod_ignore_test_impl(ctx):
    env = unittest.begin(ctx)
    ignore = ["GoogleMaps", "Firebase/Analytics"]

    # Root pod dropped
    res_root = resolve_pod("GoogleMaps", "deps", [], None, "//:lock", {}, ignore)
    asserts.equals(env, "drop", res_root.kind)

    # Subspec of ignored root dropped
    res_sub_root = resolve_pod("GoogleMaps/Utils", "deps", [], None, "//:lock", {}, ignore)
    asserts.equals(env, "drop", res_sub_root.kind)

    # Specific ignored subspec dropped
    res_sub = resolve_pod("Firebase/Analytics", "deps", [], None, "//:lock", {}, ignore)
    asserts.equals(env, "drop", res_sub.kind)

    # Step 3 wins over step 4: sibling plugin pod in ios_pod_ignore resolves as plugin
    podfile = struct(plugin_pods = {"url_launcher_ios": "url_launcher_ios"}, pods = {})
    res_win = resolve_pod(
        pod = "url_launcher_ios",
        hub_name = "deps",
        all_package_names = ["url_launcher_ios"],
        podfile = podfile,
        lock_label = "//:lock",
        ios_pod_deps = {},
        ios_pod_ignore = ["url_launcher_ios"],
        platform = "ios",
    )
    asserts.equals(env, "plugin", res_win.kind)
    asserts.equals(env, "@deps__url_launcher_ios//:url_launcher_ios_apple_ios", res_win.label)
    return unittest.end(env)

def _step5_6_stubs_and_checkout_test_impl(ctx):
    env = unittest.begin(ctx)

    # Step 5 stub
    asserts.equals(env, None, resolve_binary_pod_stub())

    # Step 6 stub
    asserts.equals(env, None, resolve_swiftpm_pod_stub())

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

def _deduplication_and_rendering_test_impl(ctx):
    env = unittest.begin(ctx)
    lock_dedup = """PODS:
  - sample_plugin (1.0.0):
    - DepA (= 1.0.0)
    - DepB (= 1.0.0)
  - DepA (1.0.0)
  - DepB (1.0.0)
DEPENDENCIES:
  - sample_plugin (from `.symlinks/plugins/sample_plugin/ios`)
EXTERNAL SOURCES:
  sample_plugin:
    :path: .symlinks/plugins/sample_plugin/ios
"""
    parsed_dedup = read_podfile_lock(lock_dedup, "//:dedup.lock")
    pod_deps = {"DepA": "//shared:umbrella", "DepB": "//shared:umbrella"}
    pre_dedup = precompute_hub_apple_pods("deps", ["sample_plugin"], parsed_dedup, "//:dedup.lock", pod_deps, [])
    hub_json = json.encode({
        "ios_pod_deps": pod_deps,
        "ios_pod_ignore": [],
        "ios_pods": pre_dedup,
        "swift_package_product_deps": {},
        "version": 1,
    })
    files = {
        "//:dedup.lock": lock_dedup,
        "//:ios_native_deps.json": hub_json,
    }
    mock_ctx = _make_mock_spoke_ctx(files, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:dedup.lock",
    })
    res = detect_apple_cocoapods_deps(
        mock_ctx,
        "sample_plugin",
        struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
        None,
    )
    # Deduplication in lock order: emitted once
    asserts.equals(env, ["//shared:umbrella"], res.ios)

    # with_apple_swiftpm_deps rendering into <pkg>_apple_<plat> and <pkg>_apple_<plat>_xtool
    initial_build = """
flutter_apple_plugin_library(
    name = "sample_plugin_apple_ios",
    srcs = ["ios/Classes/Plugin.m"],
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "sample_plugin_apple_ios_xtool",
    srcs = ["ios/Classes/Plugin.m"],
    visibility = ["//visibility:public"],
)
"""
    rendered = with_apple_swiftpm_deps(initial_build, "sample_plugin", [], res.ios)
    expected_deps_block = '    deps = [\n        "//shared:umbrella",\n    ],'
    asserts.true(env, expected_deps_block in rendered)
    # Both targets received the deps block
    ios_device_marker = 'name = "sample_plugin_apple_ios",'
    ios_xtool_marker = 'name = "sample_plugin_apple_ios_xtool",'
    part1 = rendered.partition(ios_device_marker)[2].partition("visibility = ")[0]
    part2 = rendered.partition(ios_xtool_marker)[2].partition("visibility = ")[0]
    asserts.true(env, '//shared:umbrella' in part1)
    asserts.true(env, '//shared:umbrella' in part2)
    return unittest.end(env)

def _exact_error_messages_wording_test_impl(ctx):
    env = unittest.begin(ctx)

    # Verbatim Message 9 check (E.1)
    msg9 = format_message_9("firebase_auth", "//app/ios:Podfile.lock")
    expected_m9 = (
        'Flutter plugin "firebase_auth" has iOS sources but //app/ios:Podfile.lock lists no pod for it ' +
        '(expected an EXTERNAL SOURCES entry ".symlinks/plugins/firebase_auth/ios"), and the ' +
        'plugin ships no Package.swift to fall back to. Run pod install for the app so the ' +
        'lock lists every plugin, or list the plugin\'s dependencies with ' +
        'flutter.pub(ios_plugin_deps = {"firebase_auth": "<label>"}).'
    )
    asserts.equals(env, expected_m9, msg9)

    # Verbatim Message 11 check with reason = "" (E.2)
    msg11_empty = format_message_11(
        "flutter_sound",
        "flutter_sound_core",
        "9.30.0",
        "//app/ios:Podfile.lock",
        "",
    )
    expected_m11_empty = (
        'Flutter plugin "flutter_sound" depends on pod "flutter_sound_core" (9.30.0 in //app/ios:Podfile.lock), ' +
        'which no Bazel target provides. Map it with ' +
        'flutter.pub(ios_pod_deps = {"flutter_sound_core": "<label>"}) or ' +
        'declare it unneeded with flutter.pub(ios_pod_ignore = ["flutter_sound_core"]).'
    )
    asserts.equals(env, expected_m11_empty, msg11_empty)

    # Verbatim Message 11 check with non-empty reason (E.2)
    msg11_reason = format_message_11(
        "flutter_sound",
        "flutter_sound_core",
        "9.30.0",
        "//app/ios:Podfile.lock",
        "a source pod with no SwiftPM package in the built-in table",
    )
    expected_m11_reason = (
        'Flutter plugin "flutter_sound" depends on pod "flutter_sound_core" (9.30.0 in //app/ios:Podfile.lock), ' +
        'which no Bazel target provides: a source pod with no SwiftPM package in the built-in table. Map it with ' +
        'flutter.pub(ios_pod_deps = {"flutter_sound_core": "<label>"}) or ' +
        'declare it unneeded with flutter.pub(ios_pod_ignore = ["flutter_sound_core"]).'
    )
    asserts.equals(env, expected_m11_reason, msg11_reason)
    return unittest.end(env)

def _flutterfire_manifest_cocoapods_mode_test_impl(ctx):
    env = unittest.begin(ctx)
    lock_fb = """PODS:
  - firebase_auth (10.0.0):
    - Firebase/Auth (= 10.0.0)
  - Firebase/Auth (10.0.0)
DEPENDENCIES:
  - firebase_auth (from `.symlinks/plugins/firebase_auth/ios`)
EXTERNAL SOURCES:
  firebase_auth:
    :path: .symlinks/plugins/firebase_auth/ios
"""
    parsed_fb = read_podfile_lock(lock_fb, "//app/ios:Podfile.lock")
    pod_deps = {"Firebase/Auth": "//third_party:firebase_auth_umbrella"}
    pre_fb = precompute_hub_apple_pods("deps", ["firebase_auth"], parsed_fb, "//app/ios:Podfile.lock", pod_deps, [])
    hub_json_fb = json.encode({
        "ios_pod_deps": pod_deps,
        "ios_pod_ignore": [],
        "ios_pods": pre_fb,
        "swift_package_product_deps": {},
        "version": 1,
    })

    manifest_content = """// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "firebase_auth",
  platforms: [.iOS("15.0")],
  products: [
    .library(name: "firebase-auth", targets: ["firebase_auth"])
  ],
  dependencies: [
    .package(url: "https://github.com/firebase/firebase-ios-sdk", exact: "11.0.0"),
    .package(name: "firebase_core", path: "../firebase_core"),
  ],
  targets: [
    .target(
      name: "firebase_auth",
      dependencies: [
        .product(name: "FirebaseAuth", package: "firebase-ios-sdk"),
        .product(name: "firebase-core", package: "firebase_core"),
        "firebase_auth_local",
      ],
      path: "Sources/firebase_auth"
    ),
    .target(
      name: "firebase_auth_local",
      path: "Sources/firebase_auth_local"
    )
  ]
)
"""
    files_fb = {
        "//app/ios:Podfile.lock": lock_fb,
        "//:ios_native_deps.json": hub_json_fb,
        "ios/firebase_auth/Package.swift": manifest_content,
        "ios/firebase_auth/Sources/firebase_auth_local/local.m": "// objc code\n",
    }
    dirs_fb = {
        "ios/firebase_auth/Sources/firebase_auth_local": [
            "ios/firebase_auth/Sources/firebase_auth_local/local.m",
        ],
    }
    mock_fb = _make_mock_spoke_ctx(files_fb, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//app/ios:Podfile.lock",
        "package_resolved": None,
        "package_sha256": None,
    }, dirs = dirs_fb)

    initial_fb_build = """
flutter_apple_plugin_library(
    name = "firebase_auth_apple_ios",
    srcs = ["Sources/firebase_auth/dummy.m"],
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "firebase_auth_apple_ios_xtool",
    srcs = ["Sources/firebase_auth/dummy.m"],
    visibility = ["//visibility:public"],
)
"""
    apple = struct(macos_srcs = [], ios_srcs = ["ios/firebase_auth/Sources/firebase_auth"])
    result_content = apply_apple_native_deps(mock_fb, "firebase_auth", apple, initial_fb_build)

    # Raises no SwiftPM refusal, wires mapped Firebase/Auth label into both ios and xtool
    asserts.true(env, "//third_party:firebase_auth_umbrella" in result_content)
    asserts.false(env, "FirebaseAuth" in result_content)
    asserts.false(env, "firebase_core" in result_content)

    # Renders POD-1 local target and wires it into deps
    asserts.true(env, ":firebase_auth_apple_ios__firebase_auth_local" in result_content)
    asserts.true(env, 'name = "firebase_auth_apple_ios__firebase_auth_local"' in result_content)
    return unittest.end(env)

def _mixed_mode_fallback_test_impl(ctx):
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

def _pod7_precedence_test_impl(ctx):
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

def _laziness_tests_impl(ctx):
    env = unittest.begin(ctx)

    # Pure-Dart laziness: no Apple sources reads neither podfile_lock nor ios_native_deps
    mock_dart = _make_mock_spoke_ctx({}, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:Podfile.lock",
    })
    res_dart = detect_apple_cocoapods_deps(
        mock_dart,
        "pure_dart_pkg",
        struct(macos_srcs = [], ios_srcs = []),
        None,
    )
    asserts.equals(env, [], res_dart.macos)
    asserts.equals(env, [], res_dart.ios)

    # Engine-only plugin: locked plugin whose only PODS dep is Flutter returns empty lists
    # without reading ios_native_deps.json
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

    # Unreferenced unresolved pod in ios_native_deps.json does not fail a spoke whose
    # own lock entry does not depend on it
    parsed = read_podfile_lock(_FIXTURE_LOCK, "//ios:Podfile.lock")
    precomputed = precompute_hub_apple_pods(
        hub_name = "deps",
        all_package_names = ["path_provider_foundation", "url_launcher_ios"],
        podfile = parsed,
        lock_label = "//ios:Podfile.lock",
        ios_pod_deps = {"url_launcher_platform_interface": "//third_party:url_interface"},
        ios_pod_ignore = [],
    )
    # precomputed contains "unmapped_pod" with kind = "unresolved"
    asserts.equals(env, "unresolved", precomputed["unmapped_pod"]["kind"])
    hub_json_unref = json.encode({
        "ios_pod_deps": {"url_launcher_platform_interface": "//third_party:url_interface"},
        "ios_pod_ignore": [],
        "ios_pods": precomputed,
        "swift_package_product_deps": {},
        "version": 1,
    })
    files_url = {
        "//:Podfile.lock": _FIXTURE_LOCK,
        "//:ios_native_deps.json": hub_json_unref,
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

    # macOS-only federated plugin in app with iOS lock does not fail with Message 9
    files_macos_only = {"//:Podfile.lock": _FIXTURE_LOCK}
    mock_macos = _make_mock_spoke_ctx(files_macos_only, {
        "hub_name": "deps",
        "ios_native_deps": "//:ios_native_deps.json",
        "podfile_lock": "//:Podfile.lock",
    })
    res_macos = detect_apple_cocoapods_deps(
        mock_macos,
        "macos_only_plugin",
        struct(macos_srcs = ["macos/Classes"], ios_srcs = []),
        None,
    )
    asserts.equals(env, [], res_macos.macos)
    asserts.equals(env, [], res_macos.ios)

    # Missing plugin with iOS sources and no Package.swift fails with Message 9
    errors_m9 = []
    detect_apple_cocoapods_deps(
        mock_macos,
        "missing_plugin",
        struct(macos_srcs = [], ios_srcs = ["ios/Classes"]),
        None,
        fail_fn = errors_m9.append,
    )
    asserts.equals(env, 1, len(errors_m9))
    asserts.true(env, 'Flutter plugin "missing_plugin" has iOS sources but //:Podfile.lock' in errors_m9[0])

    # Unresolved pod fails with Message 11
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
    pre_bad = precompute_hub_apple_pods("deps", ["bad_plugin"], parsed_bad, "//:bad.lock", {}, [])
    hub_json_bad = json.encode({
        "ios_pod_deps": {},
        "ios_pod_ignore": [],
        "ios_pods": pre_bad,
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
    expected_dep_err = 'Flutter plugin "bad_plugin" depends on pod "unmapped_pod" (2.0.0 in //:bad.lock)'
    asserts.true(env, expected_dep_err in errors_m11[0])
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

_step1_engine_pods_test = unittest.make(_step1_engine_pods_test_impl)
_step2_ios_pod_deps_test = unittest.make(_step2_ios_pod_deps_test_impl)
_step3_flutter_plugin_pod_test = unittest.make(_step3_flutter_plugin_pod_test_impl)
_step4_ios_pod_ignore_test = unittest.make(_step4_ios_pod_ignore_test_impl)
_step5_6_stubs_and_checkout_test = unittest.make(_step5_6_stubs_and_checkout_test_impl)
_deduplication_and_rendering_test = unittest.make(_deduplication_and_rendering_test_impl)
_exact_error_messages_wording_test = unittest.make(_exact_error_messages_wording_test_impl)
_flutterfire_manifest_cocoapods_mode_test = unittest.make(_flutterfire_manifest_cocoapods_mode_test_impl)
_mixed_mode_fallback_test = unittest.make(_mixed_mode_fallback_test_impl)
_pod7_precedence_test = unittest.make(_pod7_precedence_test_impl)
_laziness_test = unittest.make(_laziness_tests_impl)
_hub_precomputation_and_reader_test = unittest.make(_hub_precomputation_and_reader_test_impl)
_golden_resolution_test = unittest.make(_golden_resolution_test_impl)

def flutter_pub_apple_pods_test_suite(name):
    """Test suite for CocoaPods dependency resolution in rules_flutter."""
    unittest.suite(
        name + "_unit",
        _step1_engine_pods_test,
        _step2_ios_pod_deps_test,
        _step3_flutter_plugin_pod_test,
        _step4_ios_pod_ignore_test,
        _step5_6_stubs_and_checkout_test,
        _deduplication_and_rendering_test,
        _exact_error_messages_wording_test,
        _flutterfire_manifest_cocoapods_mode_test,
        _mixed_mode_fallback_test,
        _pod7_precedence_test,
        _laziness_test,
        _hub_precomputation_and_reader_test,
        _golden_resolution_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )
