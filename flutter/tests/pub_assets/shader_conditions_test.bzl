"""Tests for shader `platforms` / `flavors` conditions (COV-64).

A `flutter.shaders` entry is validated like an asset entry, but used to
have its conditions dropped, so the shader bundled on every platform. These
tests pin the three parts of the fix:

* the parser keeps `platforms` / `flavors` on a shader entry, with the same
  refusals an asset entry gets;
* the rule carries them into `FlutterInfo.pub_shaders` as tuples, and
  `shader_sources` filters them per platform, leaving unconditional entries
  everywhere;
* a file listed as both an asset and a shader fails analysis, for the
  target's own channels and for pub contributions alike.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts", "unittest")
load("//flutter:providers.bzl", "FlutterInfo")
load("//flutter/private:common.bzl", "shader_sources")
load("//flutter/private:flutter_library.bzl", "flutter_library")
load("//flutter/private:flutter_pub_assets.bzl", "asset_entry_problem_error")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block")

_CONDITIONED_PUBSPEC = """\
name: shader_conditions
flutter:
  shaders:
    - path: shaders/web_only.frag
      platforms: [web]
    - path: shaders/paid_only.frag
      flavors: [paid]
    - path: shaders/any.frag
"""

_SCALAR_PLATFORMS_PUBSPEC = """\
name: shader_scalar_platforms
flutter:
  shaders:
    - path: shaders/web_only.frag
      platforms: web
"""

_SCALAR_FLAVORS_PUBSPEC = """\
name: shader_scalar_flavors
flutter:
  shaders:
    - path: shaders/paid_only.frag
      flavors: paid
"""

_UNKNOWN_PLATFORM_PUBSPEC = """\
name: shader_unknown_platform
flutter:
  shaders:
    - path: shaders/web_only.frag
      platforms: [tvos]
"""

def _shader_conditions_survive_parse_test_impl(ctx):
    """A shader map entry keeps its `platforms` and `flavors` lists."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_CONDITIONED_PUBSPEC)
    asserts.equals(env, [], result.asset_errors)
    asserts.equals(env, 3, len(result.shaders))
    asserts.equals(env, ["web"], result.shaders[0].platforms)
    asserts.equals(env, [], result.shaders[0].flavors)
    asserts.equals(env, ["paid"], result.shaders[1].flavors)
    asserts.equals(env, [], result.shaders[1].platforms)
    return unittest.end(env)

def _shader_unconditional_default_test_impl(ctx):
    """A shader with no conditions reads as the empty lists, as before."""
    env = unittest.begin(ctx)
    result = parse_flutter_assets_block(_CONDITIONED_PUBSPEC)
    plain = result.shaders[2]
    asserts.equals(env, "shaders/any.frag", plain.path)
    asserts.equals(env, [], plain.platforms)
    asserts.equals(env, [], plain.flavors)
    return unittest.end(env)

def _assert_shader_refusal(env, content, key, detail):
    """Assert `content` yields one shader refusal naming package, entry, key.

    Args:
        env: The unittest environment.
        content: Full pubspec.yaml content with a malformed shader entry.
        key: The expected refusal key (`platforms` or `flavors`).
        detail: A substring the refusal detail must carry.

    Returns:
        The parsed block, so the caller can pin what survived.
    """
    result = parse_flutter_assets_block(content)
    asserts.equals(env, 1, len(result.asset_errors))
    problem = result.asset_errors[0]
    asserts.equals(env, key, problem.key)
    asserts.equals(env, "shaders/web_only.frag" if key == "platforms" else "shaders/paid_only.frag", problem.path)
    asserts.true(env, detail in problem.detail, problem.detail)
    message = asset_entry_problem_error("shader_pkg", problem)
    for want in ["shader_pkg", problem.path, key]:
        asserts.true(env, want in message, message)
    return result

def _shader_scalar_platforms_refused_test_impl(ctx):
    """A non-list shader `platforms` fails the fetch like an asset entry's."""
    env = unittest.begin(ctx)
    _assert_shader_refusal(env, _SCALAR_PLATFORMS_PUBSPEC, "platforms", "Expected platforms to be a list")
    return unittest.end(env)

def _shader_scalar_flavors_refused_test_impl(ctx):
    """A non-list shader `flavors` fails the fetch like an asset entry's."""
    env = unittest.begin(ctx)
    _assert_shader_refusal(env, _SCALAR_FLAVORS_PUBSPEC, "flavors", "Expected flavors to be a list")
    return unittest.end(env)

def _shader_unknown_platform_refused_test_impl(ctx):
    """An unknown shader platform fails naming the package, entry and key."""
    env = unittest.begin(ctx)
    _assert_shader_refusal(
        env,
        _UNKNOWN_PLATFORM_PUBSPEC,
        "platforms",
        "Invalid platform(s): \"tvos\"",
    )
    return unittest.end(env)

def _probe_contribution_test_impl(ctx):
    """`pkg_asset_platforms` / `pkg_asset_flavors` reach `pub_shaders` as tuples."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    by_path = {
        entry.shader_path: entry
        for entry in target[FlutterInfo].pub_shaders.to_list()
    }
    asserts.equals(env, ("web",), tuple(by_path["shaders/web_only.frag"].platforms))
    asserts.equals(env, (), tuple(by_path["shaders/web_only.frag"].flavors))
    asserts.equals(env, ("paid",), tuple(by_path["shaders/paid_only.frag"].flavors))
    asserts.equals(env, (), tuple(by_path["shaders/any.frag"].platforms))
    asserts.equals(env, (), tuple(by_path["shaders/any.frag"].flavors))
    return analysistest.end(env)

def _fake_shader_ctx(ctx):
    """A `shader_sources` context over the probe dep, without own shaders.

    Args:
        ctx: The analysistest rule context, carrying `probe_dep`.

    Returns:
        A struct with the `files`, `attr.deps` and `label` fields
        `shader_sources` reads.
    """
    return struct(
        files = struct(shaders = [], shader_includes = []),
        attr = struct(deps = [ctx.attr.probe_dep]),
        label = ctx.label,
    )

def _shader_filter_test_impl(ctx):
    """Only the target platform's shaders are listed; unconditional ones stay."""
    env = analysistest.begin(ctx)
    fake = _fake_shader_ctx(ctx)
    web_key = "packages/shader_probe/shaders/web_only.frag"
    paid_key = "packages/shader_probe/shaders/paid_only.frag"
    any_key = "packages/shader_probe/shaders/any.frag"

    android = shader_sources(fake, "android")
    asserts.false(env, web_key in android, "web-only shader must not be listed for android")
    asserts.false(env, paid_key in android, "flavor-only shader must not be listed without a flavor")
    asserts.true(env, any_key in android, "unconditional shader must stay on android")

    web = shader_sources(fake, "web")
    asserts.true(env, web_key in web, "web-only shader must be listed for web")
    asserts.false(env, paid_key in web, "flavor-only shader must not be listed without a flavor")
    asserts.true(env, any_key in web, "unconditional shader must stay on web")

    ios = shader_sources(fake, "ios")
    asserts.false(env, web_key in ios, "web-only shader must not be listed for ios")
    asserts.true(env, any_key in ios, "unconditional shader must stay on ios")
    return analysistest.end(env)

def _expect_failure_test_impl(ctx):
    """Assert analysis failed with every expected substring."""
    env = analysistest.begin(ctx)
    for expected in ctx.attr.expected_substrings:
        asserts.expect_failure(env, expected)
    return analysistest.end(env)

_probe_contribution_test = analysistest.make(_probe_contribution_test_impl)

_shader_filter_test = analysistest.make(
    _shader_filter_test_impl,
    attrs = {"probe_dep": attr.label(mandatory = True)},
)

_expect_failure_test = analysistest.make(
    _expect_failure_test_impl,
    expect_failure = True,
    attrs = {"expected_substrings": attr.string_list(mandatory = True)},
)

_t0_test = unittest.make(_shader_conditions_survive_parse_test_impl)
_t1_test = unittest.make(_shader_unconditional_default_test_impl)
_t2_test = unittest.make(_shader_scalar_platforms_refused_test_impl)
_t3_test = unittest.make(_shader_scalar_flavors_refused_test_impl)
_t4_test = unittest.make(_shader_unknown_platform_refused_test_impl)

def shader_conditions_test_suite(name):
    """Declares the shader condition parse, filter and conflict tests.

    Args:
        name: Test name prefix; probe and case targets derive from it.
    """
    flutter_library(
        name = name + "_probe_lib",
        srcs = ["stub.dart"],
        package_name = "shader_probe",
        pkg_shaders = {
            ":shaders/web_only.frag": "shaders/web_only.frag",
            ":shaders/paid_only.frag": "shaders/paid_only.frag",
            ":shaders/any.frag": "shaders/any.frag",
        },
        pkg_asset_platforms = {
            ":shaders/web_only.frag": ["web"],
        },
        pkg_asset_flavors = {
            ":shaders/paid_only.frag": ["paid"],
        },
        tags = ["manual"],
    )

    flutter_library(
        name = name + "_own_conflict",
        srcs = ["stub.dart"],
        assets = ["shaders/x.frag"],
        shaders = ["shaders/x.frag"],
        tags = ["manual"],
    )

    flutter_library(
        name = name + "_pub_conflict",
        srcs = ["stub.dart"],
        pkg_assets = {":shaders/x.frag": "shaders/x.frag"},
        pkg_shaders = {":shaders/x.frag": "shaders/x.frag"},
        tags = ["manual"],
    )

    _probe_contribution_test(
        name = name + "_probe",
        target_under_test = ":" + name + "_probe_lib",
    )

    _shader_filter_test(
        name = name + "_filter",
        target_under_test = ":" + name + "_probe_lib",
        probe_dep = ":" + name + "_probe_lib",
    )

    _expect_failure_test(
        name = name + "_own_conflict_fails",
        target_under_test = ":" + name + "_own_conflict",
        expected_substrings = ["`assets`", "`shaders`", "same file"],
    )

    _expect_failure_test(
        name = name + "_pub_conflict_fails",
        target_under_test = ":" + name + "_pub_conflict",
        expected_substrings = ["`pkg_assets`", "`pkg_shaders`", "same file"],
    )

    unittest.suite(
        name + "_unit",
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
    )
