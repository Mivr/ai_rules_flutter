"""Unit tests for `flutter_integration_test`, `chrome_headless_shell_repo`, and `linux_headless_runtime_repo`."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:chrome_headless_shell_repo.bzl",
    "CHROME_HEADLESS_SHELL_SHA256",
    "CHROME_HEADLESS_SHELL_VERSION",
    "CHROME_RUNTIME_DEB_PACKAGES",
    "chrome_headless_shell_url",
    "validate_chrome_headless_shell_downloads",
)
load(
    "//flutter/private:flutter_integration_test.bzl",
    "make_linux_integration_bootstrap_content",
    "make_web_integration_bootstrap_content",
)
load(
    "//flutter/private:linux_headless_runtime_repo.bzl",
    "LINUX_HEADLESS_RUNTIME_DEB_PACKAGES",
    "validate_linux_headless_runtime_downloads",
)

_TEST_IMPORT = "../../integration_test/app_test.dart"

def _chrome_headless_shell_pins_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.equals(env, "155.0.8059.84", CHROME_HEADLESS_SHELL_VERSION)
    asserts.equals(
        env,
        "a5d71b91aa996fef00517cd212b2dfb816b43055edefbe727e6fd562d4ae1f9c",
        CHROME_HEADLESS_SHELL_SHA256,
    )
    asserts.true(env, CHROME_HEADLESS_SHELL_VERSION in chrome_headless_shell_url(CHROME_HEADLESS_SHELL_VERSION))
    asserts.true(env, len(CHROME_RUNTIME_DEB_PACKAGES) >= 40)
    validated = validate_chrome_headless_shell_downloads(
        CHROME_HEADLESS_SHELL_VERSION,
        CHROME_HEADLESS_SHELL_SHA256,
    )
    asserts.equals(env, CHROME_HEADLESS_SHELL_SHA256, validated.browser_sha256)
    asserts.equals(env, len(CHROME_RUNTIME_DEB_PACKAGES), len(validated.runtime_debs))
    for entry in validated.runtime_debs:
        asserts.equals(env, 64, len(entry.sha256))
    return unittest.end(env)

def _linux_headless_runtime_pins_test_impl(ctx):
    env = unittest.begin(ctx)
    asserts.true(env, len(LINUX_HEADLESS_RUNTIME_DEB_PACKAGES) >= 100)
    validated = validate_linux_headless_runtime_downloads()
    asserts.equals(env, len(LINUX_HEADLESS_RUNTIME_DEB_PACKAGES), len(validated.runtime_debs))
    urls = [entry.url for entry in validated.runtime_debs]
    asserts.true(env, any(["/xvfb_" in u for u in urls]))
    asserts.true(env, any(["/x11-xkb-utils_" in u for u in urls]))
    asserts.true(env, any(["/libgtk-3-0_" in u for u in urls]))
    asserts.true(env, any(["/libgl1-mesa-dri_" in u for u in urls]))
    asserts.true(env, any(["/libegl-mesa0_" in u for u in urls]))
    for entry in validated.runtime_debs:
        asserts.equals(env, 64, len(entry.sha256))
    return unittest.end(env)

def _bootstrap_with_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    src = make_web_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = True,
    )
    asserts.true(env, "import 'package:integration_test/integration_test.dart';" in src)
    asserts.true(env, "IntegrationTestWidgetsFlutterBinding.ensureInitialized();" in src)
    asserts.false(env, "class _IntegrationTestBinding" in src)
    asserts.true(env, "RemoteListener.start(() => _runTestMain);" in src)
    asserts.true(env, "/__flutter_integration_ws__" in src)
    asserts.true(env, "'type': 'uncaughtError'" in src)
    return unittest.end(env)

def _bootstrap_without_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    src = make_web_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = False,
    )
    asserts.false(env, "package:integration_test/integration_test.dart" in src)
    asserts.true(env, "class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding" in src)
    asserts.true(env, "_IntegrationTestBinding.ensureInitialized();" in src)
    asserts.true(env, "RemoteListener.start(() => _runTestMain);" in src)
    asserts.true(env, "/__flutter_integration_ws__" in src)
    asserts.true(env, "'type': 'uncaughtError'" in src)
    return unittest.end(env)

def _linux_bootstrap_with_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    src = make_linux_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = True,
    )
    asserts.true(env, "import 'package:integration_test/integration_test.dart';" in src)
    asserts.true(env, "IntegrationTestWidgetsFlutterBinding.ensureInitialized();" in src)
    asserts.false(env, "class _IntegrationTestBinding" in src)
    asserts.true(env, "FLUTTER_INTEGRATION_TEST_HARNESS_URL" in src)
    asserts.true(env, "WebSocket.connect(wsUrl)" in src)
    asserts.true(env, "'type': 'uncaughtError'" in src)
    return unittest.end(env)

def _linux_bootstrap_without_integration_test_pkg_test_impl(ctx):
    env = unittest.begin(ctx)
    src = make_linux_integration_bootstrap_content(
        _TEST_IMPORT,
        has_integration_test = False,
    )
    asserts.false(env, "package:integration_test/integration_test.dart" in src)
    asserts.true(env, "class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding" in src)
    asserts.true(env, "_IntegrationTestBinding.ensureInitialized();" in src)
    asserts.true(env, "FLUTTER_INTEGRATION_TEST_HARNESS_URL" in src)
    asserts.true(env, "WebSocket.connect(wsUrl)" in src)
    asserts.true(env, "'type': 'uncaughtError'" in src)
    return unittest.end(env)

_t0_test = unittest.make(_chrome_headless_shell_pins_test_impl)
_t1_test = unittest.make(_bootstrap_with_integration_test_pkg_test_impl)
_t2_test = unittest.make(_bootstrap_without_integration_test_pkg_test_impl)
_t3_test = unittest.make(_linux_headless_runtime_pins_test_impl)
_t4_test = unittest.make(_linux_bootstrap_with_integration_test_pkg_test_impl)
_t5_test = unittest.make(_linux_bootstrap_without_integration_test_pkg_test_impl)

def flutter_integration_test_test_suite(name):
    unittest.suite(name, _t0_test, _t1_test, _t2_test, _t3_test, _t4_test, _t5_test)
