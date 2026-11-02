"""Tests for static CocoaPods .podspec field reading (POD-12)."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:ios.bzl", "flutter_apple_plugin_library")
load(
    "//flutter/private:flutter_apple_plugin_library.bzl",
    "weak_sdk_frameworks_xtool_refusal",
)
load(
    "//flutter/private:podspec_read.bzl",
    "podspec_unsupported_field_error",
    "read_plugin_podspec",
    "splice_apple_podspec_link_settings",
)

_WEBRTC_PODSPEC = """\
Pod::Spec.new do |s|
  s.name             = 'flutter_webrtc'
  s.version          = '0.9.24'
  s.summary          = 'Flutter WebRTC plugin'
  s.homepage         = 'https://github.com/flutter-webrtc/flutter-webrtc'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'CloudWebRtc' => 'danieldafen@live.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.platform         = :ios, '11.0'
  s.libraries        = 'c++', 'libsqlite3'
  s.frameworks       = ['AVFoundation', 'AudioToolbox']
  s.weak_frameworks  = 'MetricKit'
end
"""

_INAPPWEBVIEW_PODSPEC = """\
#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_inappwebview_ios.podspec` to validate before publishing.
#
#
Pod::Spec.new do |s|
  s.name             = 'flutter_inappwebview_ios'
  s.version          = '1.1.2'
  s.summary          = 'A Flutter plugin for iOS'
  s.description      = <<-DESC
A Flutter plugin that allows you to add an inline webview, to use a headless webview, and to open an in-app browser window.
                       DESC
  s.homepage         = 'https://github.com/pichillilorenzo/flutter_inappwebview'
  s.license          = { :type => 'Apache 2.0', :file => '../LICENSE' }
  s.author           = { 'Lorenzo Pichilli' => 'profile.pichillilorenzo@gmail.com' }
  s.source           = { :http => 'https://example.com/flutter_inappwebview_ios-1.1.2.zip' }
  s.resources = 'Storyboards/**/*.storyboard'
  s.resource_bundles = {
    'flutter_inappwebview_ios_privacy' => ['Resources/PrivacyInfo.xcprivacy']
  }
  s.libraries = 'swiftCoreGraphics'
end
"""

_VENDORED_FW_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'vendored_fw'
  s.vendored_frameworks = 'Frameworks/MyKit.xcframework'
end
"""

_VENDORED_LIB_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'vendored_lib'
  s.vendored_libraries = 'Libraries/libfoo.a'
end
"""

_NON_PRIVACY_BUNDLES_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'bad_bundles'
  s.resource_bundles = { 'my_bundle' => ['Resources/image.png'] }
end
"""

_SCOPING_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'scoping_test'
  s.frameworks = 'AVFoundation'
  s.test_spec 'Tests' do |test_spec|
    test_spec.resources = 'Tests/Resources/**/*.png'
    test_spec.vendored_frameworks = 'Tests/Frameworks/Mock.framework'
    test_spec.frameworks = 'XCTest'
  end
  s.app_spec 'App' do |app_spec|
    app_spec.resources = 'App/Resources/**/*.png'
    app_spec.vendored_libraries = 'App/libmock.a'
  end
  s.subspec 'Core' do |ss|
    ss.frameworks = 'CoreLocation'
  end
  if true
    s.frameworks = 'CoreBluetooth'
  else
    s.frameworks = 'CoreMotion'
  end
end
"""

_PLATFORM_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'platform_test'
  s.frameworks = 'SharedFramework'
  s.ios.frameworks = 'UIKit'
  s.osx.frameworks = 'AppKit'
  s.macos.weak_frameworks = 'MetricKit'
end
"""

_PRIVACY_PODSPEC = """\
Pod::Spec.new do |s|
  s.name = 'privacy_test'
  s.resource_bundles = {
    'legacy_privacy' => ['Resources/PrivacyInfo.xcprivacy'],
    "#{s.module_name}_Privacy" => 'Extra/PrivacyInfo.xcprivacy'
  }
  s.resources = 'Direct/PrivacyInfo.xcprivacy'
end
"""

def _webrtc_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    res = read_plugin_podspec(_WEBRTC_PODSPEC, "ios/flutter_webrtc.podspec", "flutter_webrtc", "ios")
    asserts.equals(env, ["AVFoundation", "AudioToolbox"], res.frameworks)
    asserts.equals(env, ["MetricKit"], res.weak_frameworks)
    asserts.equals(env, ["c++", "sqlite3"], res.libraries)
    asserts.equals(env, [], res.privacy_manifests)
    return unittest.end(env)

_webrtc_shape_test = unittest.make(_webrtc_shape_test_impl)

def _normalization_test_impl(ctx):
    env = unittest.begin(ctx)
    text = """\
Pod::Spec.new do |s|
  s.name = 'norm'
  s.libraries = ['libz', 'z', 'c++', 'sqlite3', 'libsqlite3', 'resolv', 'swiftCoreGraphics', 'libz']
end
"""
    res = read_plugin_podspec(text, "ios/norm.podspec", "norm", "ios")
    asserts.equals(env, ["z", "c++", "sqlite3", "resolv", "swiftCoreGraphics"], res.libraries)
    return unittest.end(env)

_normalization_test = unittest.make(_normalization_test_impl)

def _scoping_test_impl(ctx):
    env = unittest.begin(ctx)
    res = read_plugin_podspec(_SCOPING_PODSPEC, "ios/scoping_test.podspec", "scoping_test", "ios")
    asserts.equals(env, ["AVFoundation", "CoreLocation", "CoreBluetooth", "CoreMotion"], res.frameworks)
    return unittest.end(env)

_scoping_test = unittest.make(_scoping_test_impl)

def _platform_scoping_test_impl(ctx):
    env = unittest.begin(ctx)
    ios_res = read_plugin_podspec(_PLATFORM_PODSPEC, "ios/platform_test.podspec", "platform_test", "ios")
    asserts.equals(env, ["SharedFramework", "UIKit"], ios_res.frameworks)
    asserts.equals(env, [], ios_res.weak_frameworks)

    macos_res = read_plugin_podspec(_PLATFORM_PODSPEC, "macos/platform_test.podspec", "platform_test", "macos")
    asserts.equals(env, ["SharedFramework", "AppKit"], macos_res.frameworks)
    asserts.equals(env, ["MetricKit"], macos_res.weak_frameworks)
    return unittest.end(env)

_platform_scoping_test = unittest.make(_platform_scoping_test_impl)

def _privacy_manifest_test_impl(ctx):
    env = unittest.begin(ctx)
    res = read_plugin_podspec(_PRIVACY_PODSPEC, "ios/privacy_test.podspec", "privacy_test", "ios")
    asserts.equals(
        env,
        ["Resources/PrivacyInfo.xcprivacy", "Extra/PrivacyInfo.xcprivacy", "Direct/PrivacyInfo.xcprivacy"],
        res.privacy_manifests,
    )
    return unittest.end(env)

_privacy_manifest_test = unittest.make(_privacy_manifest_test_impl)

def _error_message_test_impl(ctx):
    env = unittest.begin(ctx)
    msg = podspec_unsupported_field_error(
        "flutter_inappwebview_ios",
        "ios/flutter_inappwebview_ios.podspec",
        17,
        "resources",
        "'Storyboards/**/*.storyboard'",
    )
    expected = (
        'Flutter plugin "flutter_inappwebview_ios": ios/flutter_inappwebview_ios.podspec:17 ' +
        "declares resources ('Storyboards/**/*.storyboard'), which rules_flutter does not build for plugins. " +
        "Replace the plugin's BUILD file with an overlay (flutter.plugin_overlays)."
    )
    asserts.equals(env, expected, msg)
    return unittest.end(env)

_error_message_test = unittest.make(_error_message_test_impl)

def _splice_link_settings_test_impl(ctx):
    env = unittest.begin(ctx)
    content = """\
flutter_apple_plugin_library(
    name = "foo_apple_ios",
    srcs = ["Classes/Foo.m"],
    platform = "ios",
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "foo_apple_ios_xtool",
    srcs = ["Classes/Foo.m"],
    platform = "ios",
    visibility = ["//visibility:public"],
)
"""
    apple = struct(
        ios_podspec = struct(
            frameworks = ["AVFoundation"],
            weak_frameworks = ["MetricKit"],
            libraries = ["c++"],
        ),
        macos_podspec = None,
    )
    spliced = splice_apple_podspec_link_settings(content, "foo", apple)
    asserts.true(env, 'sdk_frameworks = ["AVFoundation"],' in spliced)
    asserts.true(env, 'weak_sdk_frameworks = ["MetricKit"],' in spliced)
    asserts.true(env, 'sdk_dylibs = ["c++"],' in spliced)
    asserts.true(env, spliced.count('sdk_frameworks = ["AVFoundation"],') == 2)
    return unittest.end(env)

_splice_link_settings_test = unittest.make(_splice_link_settings_test_impl)

def _podspec_failure_probe_impl(ctx):
    read_plugin_podspec(ctx.attr.text, ctx.attr.path, ctx.attr.plugin, ctx.attr.platform)
    return [DefaultInfo(files = depset())]

_podspec_failure_probe = rule(
    implementation = _podspec_failure_probe_impl,
    attrs = {
        "path": attr.string(mandatory = True),
        "platform": attr.string(default = "ios"),
        "plugin": attr.string(mandatory = True),
        "text": attr.string(mandatory = True),
    },
)

def _podspec_failure_test_impl(ctx):
    env = analysistest.begin(ctx)
    for exp in ctx.attr.expected_messages:
        asserts.expect_failure(env, exp)
    return analysistest.end(env)

_podspec_failure_test = analysistest.make(
    _podspec_failure_test_impl,
    expect_failure = True,
    attrs = {
        "expected_messages": attr.string_list(mandatory = True),
    },
)

def _pure_swift_linkopts_test_impl(ctx):
    env = unittest.begin(ctx)
    linkopts = ctx.attr.linkopts
    asserts.true(env, "-framework" in linkopts)
    asserts.true(env, "AVFoundation" in linkopts)
    asserts.true(env, "-weak_framework" in linkopts)
    asserts.true(env, "MetricKit" in linkopts)
    asserts.true(env, "-lc++" in linkopts or ("-l" in linkopts and "c++" in linkopts))
    return unittest.end(env)

_pure_swift_linkopts_test = unittest.make(
    _pure_swift_linkopts_test_impl,
    attrs = {
        "linkopts": attr.string_list(mandatory = True),
    },
)

def _xtool_weak_sdk_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    msg = weak_sdk_frameworks_xtool_refusal("my_plugin")
    asserts.true(env, "my_plugin" in msg)
    asserts.true(env, "weak_sdk_frameworks" in msg)
    asserts.true(env, "xtool" in msg)
    return unittest.end(env)

_xtool_weak_sdk_refusal_test = unittest.make(_xtool_weak_sdk_refusal_test_impl)

def podspec_read_test_suite(name):
    """Defines CocoaPods podspec reader unit and analysis tests.

    Args:
        name: Name prefix for the declared test targets.
    """
    unittest.suite(
        name + "_unit",
        _webrtc_shape_test,
        _normalization_test,
        _scoping_test,
        _platform_scoping_test,
        _privacy_manifest_test,
        _error_message_test,
        _splice_link_settings_test,
        _xtool_weak_sdk_refusal_test,
    )

    _podspec_failure_probe(
        name = name + "_inappwebview_probe",
        text = _INAPPWEBVIEW_PODSPEC,
        path = "ios/flutter_inappwebview_ios.podspec",
        plugin = "flutter_inappwebview_ios",
        tags = ["manual"],
    )
    _podspec_failure_test(
        name = name + "_inappwebview_failure_test",
        target_under_test = ":" + name + "_inappwebview_probe",
        expected_messages = [
            'Flutter plugin "flutter_inappwebview_ios": ios/flutter_inappwebview_ios.podspec:17 declares resources',
            "('Storyboards/**/*.storyboard')",
            "Replace the plugin's BUILD file with an overlay (flutter.plugin_overlays).",
        ],
    )

    _podspec_failure_probe(
        name = name + "_vendored_fw_probe",
        text = _VENDORED_FW_PODSPEC,
        path = "ios/vendored_fw.podspec",
        plugin = "vendored_fw",
        tags = ["manual"],
    )
    _podspec_failure_test(
        name = name + "_vendored_fw_failure_test",
        target_under_test = ":" + name + "_vendored_fw_probe",
        expected_messages = [
            'Flutter plugin "vendored_fw": ios/vendored_fw.podspec:3 declares vendored_frameworks',
            "('Frameworks/MyKit.xcframework')",
            "flutter.plugin_overlays",
        ],
    )

    _podspec_failure_probe(
        name = name + "_vendored_lib_probe",
        text = _VENDORED_LIB_PODSPEC,
        path = "ios/vendored_lib.podspec",
        plugin = "vendored_lib",
        tags = ["manual"],
    )
    _podspec_failure_test(
        name = name + "_vendored_lib_failure_test",
        target_under_test = ":" + name + "_vendored_lib_probe",
        expected_messages = [
            'Flutter plugin "vendored_lib": ios/vendored_lib.podspec:3 declares vendored_libraries',
            "('Libraries/libfoo.a')",
            "flutter.plugin_overlays",
        ],
    )

    _podspec_failure_probe(
        name = name + "_bad_bundles_probe",
        text = _NON_PRIVACY_BUNDLES_PODSPEC,
        path = "ios/bad_bundles.podspec",
        plugin = "bad_bundles",
        tags = ["manual"],
    )
    _podspec_failure_test(
        name = name + "_bad_bundles_failure_test",
        target_under_test = ":" + name + "_bad_bundles_probe",
        expected_messages = [
            'Flutter plugin "bad_bundles": ios/bad_bundles.podspec:3 declares resource_bundles',
            "flutter.plugin_overlays",
        ],
    )

    swift_plugin = name + "_pure_swift_plugin"
    flutter_apple_plugin_library(
        name = swift_plugin,
        srcs = [name + "_PureSwift.swift"],
        module_name = "pure_swift_plugin",
        platform = "ios",
        sdk_frameworks = ["AVFoundation"],
        weak_sdk_frameworks = ["MetricKit"],
        sdk_dylibs = ["c++"],
        tags = ["manual"],
    )
    after = native.existing_rules()
    swift_target = after[swift_plugin]
    _pure_swift_linkopts_test(
        name = name + "_pure_swift_linkopts_test",
        linkopts = [str(x) for x in swift_target.get("linkopts", [])],
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_inappwebview_failure_test",
            ":" + name + "_vendored_fw_failure_test",
            ":" + name + "_vendored_lib_failure_test",
            ":" + name + "_bad_bundles_failure_test",
            ":" + name + "_pure_swift_linkopts_test",
        ],
    )
