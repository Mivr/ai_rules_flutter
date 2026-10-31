"""Unit tests for the CocoaPods Podfile.lock parser."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:podfile_lock.bzl", "read_podfile_lock")
load(
    "//flutter/private:swiftpm_resolved.bzl",
    "pub_spoke_podfile_lock_attr",
    "pub_spoke_swiftpm_attrs",
    "pub_spoke_swiftpm_rule_attrs",
)

_LOCK_LABEL = "//app/ios:Podfile.lock"

_SYNTHETIC_LOCK = """PODS:
  - firebase_auth (5.1.0):
    - Firebase/Auth (= 12.19.3)
    - Flutter
  - "Firebase/Auth (12.19.3)":
    - Firebase/CoreOnly
  - Firebase/CoreOnly (12.19.3):
    - FirebaseCore (= 12.19.3)
  - FirebaseCore (12.19.3):
  - google_maps_flutter_ios (0.0.1):
    - Flutter
    - GoogleMaps (= 10.15.0)
  - GoogleMaps (10.15.0):
  - google_sign_in_ios (0.0.1):
    - Flutter
    - GoogleSignIn (= 9.0.0)
  - GoogleSignIn (9.0.0):
  - google_mlkit_commons (0.0.1):
    - Flutter
    - MLKitVision (= 10.0.0)
  - MLKitVision (10.0.0):

DEPENDENCIES:
  - firebase_auth (from `.symlinks/plugins/firebase_auth/ios`)
  - google_maps_flutter_ios (from `.symlinks/plugins/google_maps_flutter_ios/darwin`)
  - google_sign_in_ios (from `.symlinks/plugins/google_sign_in_ios/macos`)
  - google_mlkit_commons (from `.symlinks/plugins/google_mlkit_commons/ios`)

EXTERNAL SOURCES:
  custom_git:
    :git: "https://github.com/custom/git.git"
  firebase_auth:
    :path: ".symlinks/plugins/firebase_auth/ios"
  google_maps_flutter_ios:
    :path: ".symlinks/plugins/google_maps_flutter_ios/darwin"
  google_mlkit_commons:
    :path: ".symlinks/plugins/google_mlkit_commons/ios"
  google_sign_in_ios:
    :path: ".symlinks/plugins/google_sign_in_ios/macos"
  local_non_plugin:
    :path: "../local/path"

CHECKOUT OPTIONS:
  custom_git:
    :commit: "abcdef"
    :git: "https://github.com/custom/git.git"
  custom_http:
    :http: "https://example.com/archive.tar.gz"

SPEC REPOS:
  trunk:
    - Firebase
    - FirebaseCore
    - GoogleMaps
    - GoogleSignIn
    - MLKitVision

SPEC CHECKSUMS:
  Firebase: "1111111111111111111111111111111111111111"
  FirebaseCore: "2222222222222222222222222222222222222222"
  GoogleMaps: "3333333333333333333333333333333333333333"
  GoogleSignIn: "4444444444444444444444444444444444444444"
  MLKitVision: "5555555555555555555555555555555555555555"

PODFILE CHECKSUM: "9999999999999999999999999999999999999999"

COCOAPODS: 1.14.3
"""

def _synthetic_lock_parses_test_impl(ctx):
    """The synthetic lock parses with versions, lines and dependencies in order."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.true(env, res.ok)
    asserts.equals(env, "", res.error)

    fb_auth = res.pods.get("firebase_auth")
    asserts.true(env, fb_auth != None)
    asserts.equals(env, "5.1.0", fb_auth.version)
    asserts.equals(env, 2, fb_auth.line)
    asserts.equals(env, [
        struct(name = "Firebase/Auth", requirement = "= 12.19.3"),
        struct(name = "Flutter", requirement = ""),
    ], fb_auth.deps)

    core_only = res.pods.get("Firebase/CoreOnly")
    asserts.true(env, core_only != None)
    asserts.equals(env, "12.19.3", core_only.version)
    asserts.equals(env, [
        struct(name = "FirebaseCore", requirement = "= 12.19.3"),
    ], core_only.deps)

    fb_core = res.pods.get("FirebaseCore")
    asserts.true(env, fb_core != None)
    asserts.equals(env, "12.19.3", fb_core.version)
    asserts.equals(env, [], fb_core.deps)
    asserts.equals(env, 9, fb_core.line)
    return unittest.end(env)

def _quoted_subspec_test_impl(ctx):
    """A quoted Name/Subspec entry parses to the same name a bare entry does."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.true(env, "Firebase/Auth" in res.pods)
    asserts.equals(env, "12.19.3", res.pods["Firebase/Auth"].version)
    asserts.equals(env, 5, res.pods["Firebase/Auth"].line)

    bare_lock = "PODS:\n  - Firebase/Auth (12.19.3):\n    - Firebase/CoreOnly\n"
    bare_res = read_podfile_lock(bare_lock, _LOCK_LABEL)
    asserts.true(env, bare_res.ok)
    asserts.true(env, "Firebase/Auth" in bare_res.pods)
    asserts.equals(env, bare_res.pods["Firebase/Auth"].version, res.pods["Firebase/Auth"].version)
    asserts.equals(env, bare_res.pods["Firebase/Auth"].deps, res.pods["Firebase/Auth"].deps)

    single_lock = "PODS:\n  - 'Firebase/Auth (12.19.3)':\n    - 'Firebase/CoreOnly'\n"
    single_res = read_podfile_lock(single_lock, _LOCK_LABEL)
    asserts.true(env, single_res.ok)
    asserts.true(env, "Firebase/Auth" in single_res.pods)
    asserts.equals(env, single_res.pods["Firebase/Auth"].version, res.pods["Firebase/Auth"].version)
    asserts.equals(env, single_res.pods["Firebase/Auth"].deps, res.pods["Firebase/Auth"].deps)
    return unittest.end(env)

def _plugin_pods_test_impl(ctx):
    """Plugin paths with /darwin and /macos land in plugin_pods; non-plugin paths do not."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.equals(env, "firebase_auth", res.plugin_pods.get("firebase_auth"))
    asserts.equals(env, "google_maps_flutter_ios", res.plugin_pods.get("google_maps_flutter_ios"))
    asserts.equals(env, "google_sign_in_ios", res.plugin_pods.get("google_sign_in_ios"))
    asserts.equals(env, "google_mlkit_commons", res.plugin_pods.get("google_mlkit_commons"))
    asserts.false(env, "local_non_plugin" in res.plugin_pods)
    asserts.false(env, "custom_git" in res.plugin_pods)
    return unittest.end(env)

def _checkout_options_test_impl(ctx):
    """CHECKOUT OPTIONS and EXTERNAL SOURCES record external source kinds."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.equals(env, "git", res.checkout.get("custom_git"))
    asserts.equals(env, "http", res.checkout.get("custom_http"))

    quoted_symbol_lock = "CHECKOUT OPTIONS:\n  foo:\n    \":git\": \"https://github.com/foo.git\"\n"
    q_res = read_podfile_lock(quoted_symbol_lock, _LOCK_LABEL)
    asserts.true(env, q_res.ok)
    asserts.equals(env, "git", q_res.checkout.get("foo"))
    return unittest.end(env)

def _spec_repos_and_checksums_test_impl(ctx):
    """spec_repos and checksums hold the values written in the lock."""
    env = unittest.begin(ctx)
    res = read_podfile_lock(_SYNTHETIC_LOCK, _LOCK_LABEL)
    asserts.equals(env, "trunk", res.spec_repos.get("Firebase"))
    asserts.equals(env, "trunk", res.spec_repos.get("FirebaseCore"))
    asserts.equals(env, "trunk", res.spec_repos.get("GoogleMaps"))
    asserts.equals(env, "1111111111111111111111111111111111111111", res.checksums.get("Firebase"))
    asserts.equals(env, "5555555555555555555555555555555555555555", res.checksums.get("MLKitVision"))

    url_repo_lock = "SPEC REPOS:\n  https://github.com/CocoaPods/Specs.git:\n    - CustomPod\n"
    url_res = read_podfile_lock(url_repo_lock, _LOCK_LABEL)
    asserts.true(env, url_res.ok)
    asserts.equals(env, "https://github.com/CocoaPods/Specs.git", url_res.spec_repos.get("CustomPod"))
    return unittest.end(env)

def _refusals_syntax_test_impl(ctx):
    """Refusals for tabs, unknown keys, flow syntax and anchors name line and detail."""
    env = unittest.begin(ctx)

    tab_lock = "PODS:\n\t- firebase_auth (5.1.0):\n"
    res = read_podfile_lock(tab_lock, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + " (Podfile.lock line 2): " +
        "an indentation tab is not part of the Podfile.lock YAML subset rules_flutter reads.",
        res.error,
    )

    bad_key = "UNKNOWN_KEY:\n  foo\n"
    res = read_podfile_lock(bad_key, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock line 1): "UNKNOWN_KEY" is not a Podfile.lock top-level key rules_flutter reads.',
        res.error,
    )

    bad_quoted_key = "'UNKNOWN_KEY':\n  foo\n"
    res = read_podfile_lock(bad_quoted_key, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock line 1): "UNKNOWN_KEY" is not a Podfile.lock top-level key rules_flutter reads.',
        res.error,
    )

    flow_lock = "PODS:\n  - [a, b]\n"
    res = read_podfile_lock(flow_lock, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + " (Podfile.lock line 2): " +
        "flow syntax and anchors are not part of the Podfile.lock YAML subset rules_flutter reads.",
        res.error,
    )

    anchor_lock = "PODS:\n  - &anchor foo\n"
    res = read_podfile_lock(anchor_lock, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + " (Podfile.lock line 2): " +
        "flow syntax and anchors are not part of the Podfile.lock YAML subset rules_flutter reads.",
        res.error,
    )

    bad_flow_symbol = "EXTERNAL SOURCES:\n  foo:\n    :path: [a, b]\n"
    res = read_podfile_lock(bad_flow_symbol, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + " (Podfile.lock line 3): " +
        "flow syntax and anchors are not part of the Podfile.lock YAML subset rules_flutter reads.",
        res.error,
    )

    bad_anchor_symbol = "CHECKOUT OPTIONS:\n  foo:\n    :commit: *alias\n"
    res = read_podfile_lock(bad_anchor_symbol, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + " (Podfile.lock line 3): " +
        "flow syntax and anchors are not part of the Podfile.lock YAML subset rules_flutter reads.",
        res.error,
    )

    return unittest.end(env)

def _refusals_pods_test_impl(ctx):
    """Refusals for malformed PODS entries, dependencies and duplicates."""
    env = unittest.begin(ctx)

    bad_entry = "PODS:\n  - bad_entry\n"
    res = read_podfile_lock(bad_entry, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock line 2): "- bad_entry" is not a "<name> (<version>):" PODS entry.',
        res.error,
    )

    bad_indent0 = "PODS:\n- foo (1.0):\n"
    res = read_podfile_lock(bad_indent0, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock line 2): "- foo (1.0):" is not a "<name> (<version>):" PODS entry.',
        res.error,
    )

    bad_indent3 = "PODS:\n   - foo (1.0):\n"
    res = read_podfile_lock(bad_indent3, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock line 2): "- foo (1.0):" is not a "<name> (<version>):" PODS entry.',
        res.error,
    )

    bad_entry_indent3_following = "PODS:\n  - foo (1.0):\n    - bar\n   - baz (2.0):\n"
    res = read_podfile_lock(bad_entry_indent3_following, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock line 4): "- baz (2.0):" is not a "<name> (<version>):" PODS entry.',
        res.error,
    )

    bad_dep = "PODS:\n  - foo (1.0):\n    - bar (bad req\n"
    res = read_podfile_lock(bad_dep, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock line 3): "- bar (bad req" is not a "<name> (<requirement>)" PODS dependency.',
        res.error,
    )

    bad_indent6 = "PODS:\n  - foo (1.0):\n      - bar\n"
    res = read_podfile_lock(bad_indent6, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock line 3): "- bar" is not a "<name> (<requirement>)" PODS dependency.',
        res.error,
    )

    dup_pod = "PODS:\n  - foo (1.0):\n  - foo (2.0):\n"
    res = read_podfile_lock(dup_pod, _LOCK_LABEL)
    asserts.false(env, res.ok)
    asserts.equals(
        env,
        _LOCK_LABEL + ' (Podfile.lock line 3): PODS lists "foo" twice.',
        res.error,
    )

    return unittest.end(env)

def _empty_and_ignored_sections_test_impl(ctx):
    """An empty file or a file with only ignored keys parses with empty maps."""
    env = unittest.begin(ctx)
    res = read_podfile_lock("", _LOCK_LABEL)
    asserts.true(env, res.ok)
    asserts.equals(env, "", res.error)
    asserts.equals(env, {}, res.pods)
    asserts.equals(env, {}, res.plugin_pods)
    asserts.equals(env, {}, res.spec_repos)
    asserts.equals(env, {}, res.checksums)
    asserts.equals(env, {}, res.checkout)

    ignored_lock = "PODFILE CHECKSUM: abc\nCOCOAPODS: 1.14.3\n"
    res = read_podfile_lock(ignored_lock, _LOCK_LABEL)
    asserts.true(env, res.ok)
    asserts.equals(env, "", res.error)
    asserts.equals(env, {}, res.pods)
    asserts.equals(env, {}, res.plugin_pods)
    asserts.equals(env, {}, res.spec_repos)
    asserts.equals(env, {}, res.checksums)
    asserts.equals(env, {}, res.checkout)
    return unittest.end(env)

def _dependency_free_entry_test_impl(ctx):
    """A dependency-free entry parses with an empty deps list."""
    env = unittest.begin(ctx)
    dep_free = "PODS:\n  - pod_bigint_plugin (0.0.1):\n"
    res = read_podfile_lock(dep_free, _LOCK_LABEL)
    asserts.true(env, res.ok)
    asserts.equals(env, "", res.error)
    asserts.true(env, "pod_bigint_plugin" in res.pods)
    asserts.equals(env, "0.0.1", res.pods["pod_bigint_plugin"].version)
    asserts.equals(env, [], res.pods["pod_bigint_plugin"].deps)
    asserts.equals(env, 2, res.pods["pod_bigint_plugin"].line)
    return unittest.end(env)

def _pub_spoke_podfile_lock_attrs_test_impl(ctx):
    """Spoke rules declare podfile_lock and pub_spoke_swiftpm_attrs forwards it."""
    env = unittest.begin(ctx)
    rule_attrs = pub_spoke_swiftpm_rule_attrs({})
    asserts.true(env, "podfile_lock" in rule_attrs)
    asserts.equals(env, pub_spoke_podfile_lock_attr, rule_attrs["podfile_lock"])

    attrs_unset = pub_spoke_swiftpm_attrs(struct(swift_package_resolved = None))
    asserts.equals(env, None, attrs_unset.podfile_lock)

    attrs_set = pub_spoke_swiftpm_attrs(struct(
        swift_package_resolved = None,
        ios_podfile_lock = "//app/ios:Podfile.lock",
    ))
    asserts.equals(env, "//app/ios:Podfile.lock", str(attrs_set.podfile_lock))
    return unittest.end(env)

_synthetic_lock_parses_test = unittest.make(_synthetic_lock_parses_test_impl)
_quoted_subspec_test = unittest.make(_quoted_subspec_test_impl)
_plugin_pods_test = unittest.make(_plugin_pods_test_impl)
_checkout_options_test = unittest.make(_checkout_options_test_impl)
_spec_repos_and_checksums_test = unittest.make(_spec_repos_and_checksums_test_impl)
_refusals_syntax_test = unittest.make(_refusals_syntax_test_impl)
_refusals_pods_test = unittest.make(_refusals_pods_test_impl)
_empty_and_ignored_sections_test = unittest.make(_empty_and_ignored_sections_test_impl)
_dependency_free_entry_test = unittest.make(_dependency_free_entry_test_impl)
_pub_spoke_podfile_lock_attrs_test = unittest.make(_pub_spoke_podfile_lock_attrs_test_impl)

def podfile_lock_test_suite(name):
    """Defines the CocoaPods Podfile.lock unit test suite.

    Args:
        name: Name of the test suite.
    """
    unittest.suite(
        name,
        _synthetic_lock_parses_test,
        _quoted_subspec_test,
        _plugin_pods_test,
        _checkout_options_test,
        _spec_repos_and_checksums_test,
        _refusals_syntax_test,
        _refusals_pods_test,
        _empty_and_ignored_sections_test,
        _dependency_free_entry_test,
        _pub_spoke_podfile_lock_attrs_test,
    )
