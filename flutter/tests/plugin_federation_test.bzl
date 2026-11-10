"""Unit and analysis tests for plugin_federation.bzl pure functions."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter/private:plugin_federation.bzl", "resolve_federated_plugins")
load("//flutter/tests:test_suite.bzl", "small_unittest_suite")

def _default_only_test_impl(ctx):
    """With no other implementation, the default implementation stays."""
    env = unittest.begin(ctx)
    u = struct(
        name = "greeting",
        platforms = {"android": {"default_package": "greeting_android"}},
        implements = "",
    )
    def_pkg = struct(
        name = "greeting_android",
        platforms = {"android": {"pluginClass": "GreetingAndroidPlugin"}},
        implements = "greeting",
    )
    result = resolve_federated_plugins([u, def_pkg], "android")
    asserts.equals(env, ["greeting", "greeting_android"], [p.name for p in result])
    return unittest.end(env)

def _default_replaced_by_app_chosen_test_impl(ctx):
    """An app-chosen implementation replaces the default implementation."""
    env = unittest.begin(ctx)
    u = struct(
        name = "greeting",
        platforms = {"android": {"default_package": "greeting_android"}},
        implements = "",
    )
    def_pkg = struct(
        name = "greeting_android",
        platforms = {"android": {"pluginClass": "GreetingAndroidPlugin"}},
        implements = "greeting",
    )
    alt_pkg = struct(
        name = "greeting_alt",
        platforms = {"android": {"pluginClass": "GreetingAltPlugin"}},
        implements = "greeting",
    )
    result = resolve_federated_plugins([u, def_pkg, alt_pkg], "android")
    asserts.equals(env, ["greeting_alt"], [p.name for p in result])
    return unittest.end(env)

def _platform_without_entry_test_impl(ctx):
    """A platform on which the other implementation has no entry is accepted."""
    env = unittest.begin(ctx)
    u = struct(
        name = "greeting",
        platforms = {
            "android": {"default_package": "greeting_android"},
            "ios": {"default_package": "greeting_ios"},
        },
        implements = "",
    )
    def_android = struct(
        name = "greeting_android",
        platforms = {"android": {"pluginClass": "GreetingAndroidPlugin"}},
        implements = "greeting",
    )
    def_ios = struct(
        name = "greeting_ios",
        platforms = {"ios": {"pluginClass": "GreetingIosPlugin"}},
        implements = "greeting",
    )
    alt_android_only = struct(
        name = "greeting_alt",
        platforms = {"android": {"pluginClass": "GreetingAltPlugin"}},
        implements = "greeting",
    )
    result_ios = resolve_federated_plugins(
        [u, def_android, def_ios, alt_android_only],
        "ios",
    )
    asserts.true(env, "greeting_ios" in [p.name for p in result_ios])
    asserts.equals(
        env,
        ["greeting", "greeting_android", "greeting_ios", "greeting_alt"],
        [p.name for p in result_ios],
    )

    result_android = resolve_federated_plugins(
        [u, def_android, def_ios, alt_android_only],
        "android",
    )
    asserts.equals(env, ["greeting_alt", "greeting_ios"], [p.name for p in result_android])
    return unittest.end(env)

def _order_preserved_test_impl(ctx):
    """The order of remaining plugins is unchanged."""
    env = unittest.begin(ctx)
    p1 = struct(name = "p1", platforms = {"android": {"pluginClass": "P1"}}, implements = "")
    u = struct(name = "umbrella", platforms = {"android": {"default_package": "def_pkg"}}, implements = "")
    p2 = struct(name = "p2", platforms = {"android": {"pluginClass": "P2"}}, implements = "")
    def_pkg = struct(name = "def_pkg", platforms = {"android": {"pluginClass": "Def"}}, implements = "umbrella")
    p3 = struct(name = "p3", platforms = {"android": {"pluginClass": "P3"}}, implements = "")
    alt = struct(name = "alt", platforms = {"android": {"pluginClass": "Alt"}}, implements = "umbrella")
    p4 = struct(name = "p4", platforms = {"android": {"pluginClass": "P4"}}, implements = "")

    result = resolve_federated_plugins([p1, u, p2, def_pkg, p3, alt, p4], "android")
    asserts.equals(env, ["p1", "alt", "p2", "p3", "p4"], [p.name for p in result])
    return unittest.end(env)

def _empty_list_test_impl(ctx):
    """An empty plugin list returns an empty list."""
    env = unittest.begin(ctx)
    result = resolve_federated_plugins([], "android")
    asserts.equals(env, [], result)
    return unittest.end(env)

def _untouched_plugins_test_impl(ctx):
    """A plugin with no implements and no default_package is untouched."""
    env = unittest.begin(ctx)
    p = struct(name = "plain", platforms = {"android": {"pluginClass": "PlainPlugin"}}, implements = "")
    result = resolve_federated_plugins([p], "android")
    asserts.equals(env, [p], result)
    return unittest.end(env)

def _conflict_target_impl(_ctx):
    """Implementation of conflict target rule to trigger duplicate implementations error."""
    u = struct(
        name = "greeting",
        platforms = {"android": {"default_package": "greeting_android"}},
        implements = "",
    )
    c1 = struct(
        name = "greeting_alt1",
        platforms = {"android": {"pluginClass": "Alt1Plugin"}},
        implements = "greeting",
    )
    c2 = struct(
        name = "greeting_alt2",
        platforms = {"android": {"pluginClass": "Alt2Plugin"}},
        implements = "greeting",
    )
    resolve_federated_plugins([u, c1, c2], "android")
    return [DefaultInfo()]

_conflict_target = rule(
    implementation = _conflict_target_impl,
    doc = "Fixture rule that triggers conflicting federated plugin resolution.",
)

def _two_implementations_refused_test_impl(ctx):
    """Two or more non-default implementations fail closed with exact error message."""
    env = analysistest.begin(ctx)
    asserts.expect_failure(
        env,
        'flutter plugin registrant: "greeting" has more than one implementation for android (greeting_alt1, greeting_alt2). Depend on one, or on the default "greeting_android" only.',
    )
    return analysistest.end(env)

_two_implementations_refused_test = analysistest.make(
    _two_implementations_refused_test_impl,
    expect_failure = True,
)

_t0_test = unittest.make(_default_only_test_impl)
_t1_test = unittest.make(_default_replaced_by_app_chosen_test_impl)
_t2_test = unittest.make(_platform_without_entry_test_impl)
_t3_test = unittest.make(_order_preserved_test_impl)
_t4_test = unittest.make(_empty_list_test_impl)
_t5_test = unittest.make(_untouched_plugins_test_impl)

def plugin_federation_test_suite(name):
    """Test suite entry point for plugin federation unit and analysis tests.

    Args:
        name: Name of the test suite.
    """
    _conflict_target(
        name = name + "_conflict_fixture",
        tags = ["manual"],
    )
    _two_implementations_refused_test(
        name = name + "_two_implementations_refused",
        target_under_test = ":" + name + "_conflict_fixture",
    )
    small_unittest_suite(
        name + "_unit",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_unit",
            ":" + name + "_two_implementations_refused",
        ],
    )
