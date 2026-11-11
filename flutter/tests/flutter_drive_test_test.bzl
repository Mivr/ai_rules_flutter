"""Analysis tests for `flutter_drive_test`: its shape, its required inputs and its tags."""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@rules_android//providers:providers.bzl", "ApkInfo")
load("//flutter:android.bzl", "flutter_drive_test")

def _app_stub_impl(ctx):
    """Stands in for `flutter_android_app`: one signed APK carrying `ApkInfo`.

    Args:
        ctx: The rule context.

    Returns:
        The provider list for the stub Android app.
    """
    apk = ctx.actions.declare_file(ctx.label.name + ".apk")
    ctx.actions.write(apk, "")
    return [
        DefaultInfo(files = depset([apk])),
        ApkInfo(
            signed_apk = apk,
            unsigned_apk = apk,
            deploy_jar = None,
            coverage_metadata = None,
            signing_keys = [],
            signing_lineage = None,
            signing_min_v3_rotation_api_version = None,
            keystore = None,
        ),
    ]

_app_stub = rule(
    implementation = _app_stub_impl,
    doc = "A target with a signed `.apk` and `ApkInfo`, standing in for `flutter_android_app`.",
)

def _not_android_impl(ctx):
    """Produces a non-Android file target lacking `ApkInfo`.

    Args:
        ctx: The rule context.

    Returns:
        The provider list without `ApkInfo`.
    """
    out = ctx.actions.declare_file(ctx.label.name + ".txt")
    ctx.actions.write(out, "")
    return [DefaultInfo(files = depset([out]))]

_not_android = rule(
    implementation = _not_android_impl,
    doc = "A target without `ApkInfo`, used to test invalid `app` rejection.",
)

def _driver_stub_impl(ctx):
    """Produces an executable host driver stand-in.

    Args:
        ctx: The rule context.

    Returns:
        The provider list with an executable `DefaultInfo`.
    """
    exe = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.write(exe, "", is_executable = True)
    return [DefaultInfo(executable = exe)]

_driver_stub = rule(
    implementation = _driver_stub_impl,
    executable = True,
    doc = "An executable target standing in for a `dart_binary` host driver.",
)

def _shape_test_impl(ctx):
    """Verifies one test executable, `app` and `driver` in runfiles, and no host paths.

    Args:
        ctx: The analysis test context.

    Returns:
        The `analysistest` result token.
    """
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    info = target[DefaultInfo]
    asserts.true(env, info.files_to_run.executable != None, "no test executable")
    asserts.equals(env, ctx.attr.name_of_test, info.files_to_run.executable.basename)
    paths = [f.short_path for f in info.default_runfiles.files.to_list()]
    asserts.true(env, [p for p in paths if p.endswith("_app_stub.apk")], "app APK missing from runfiles")
    for suffix in ctx.attr.expected_driver_suffixes:
        asserts.true(env, [p for p in paths if p.endswith(suffix)], "driver %s missing from runfiles" % suffix)
    asserts.true(env, [p for p in paths if p.endswith("/flutter_drive_runner")], "runner missing from runfiles")
    for p in paths:
        asserts.false(env, p.startswith("/"), "host path in runfiles: %s" % p)
    exec_reqs = target[testing.ExecutionInfo].requirements
    asserts.true(env, "no-sandbox" in exec_reqs, "expected no-sandbox in ExecutionInfo")
    return analysistest.end(env)

_shape_test = analysistest.make(
    _shape_test_impl,
    attrs = {
        "expected_driver_suffixes": attr.string_list(
            doc = "Runfile suffixes expected from the `driver` input; defaults to `[]`.",
        ),
        "name_of_test": attr.string(
            doc = "Expected basename of the declared test executable; defaults to `\"\"`.",
        ),
    },
    doc = "Checks test executable, runfile inputs and absence of host paths on `flutter_drive_test`.",
)

def _missing_driver_test_impl(ctx):
    """Checks that omitting `driver` fails analysis and names `driver`.

    Args:
        ctx: The analysis test context.

    Returns:
        The `analysistest` result token.
    """
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "attribute `driver` is required")
    return analysistest.end(env)

_missing_driver_test = analysistest.make(
    _missing_driver_test_impl,
    expect_failure = True,
    doc = "Verifies that omitting `driver` fails analysis naming `driver`.",
)

def _not_android_app_test_impl(ctx):
    """Checks that a non-Android `app` fails analysis and names `app`.

    Args:
        ctx: The analysis test context.

    Returns:
        The `analysistest` result token.
    """
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "attribute `app`")
    return analysistest.end(env)

_not_android_app_test = analysistest.make(
    _not_android_app_test_impl,
    expect_failure = True,
    doc = "Verifies that passing a non-Android target to `app` fails analysis naming `app`.",
)

def _tags_size_test_impl(ctx):
    """Checks that `size` is `large` and `tags` preserves caller tags plus `manual`.

    Args:
        ctx: The analysis test context.

    Returns:
        The `analysistest` result token.
    """
    env = analysistest.begin(ctx)
    asserts.equals(env, "large", ctx.attr.observed_size)
    asserts.true(env, "manual" in ctx.attr.observed_tags, "manual missing from %s" % ctx.attr.observed_tags)
    asserts.true(env, "extra" in ctx.attr.observed_tags, "caller tags dropped from %s" % ctx.attr.observed_tags)
    return analysistest.end(env)

_tags_size_test = analysistest.make(
    _tags_size_test_impl,
    attrs = {
        "observed_size": attr.string(
            doc = "Observed `size` attribute recorded on the underlying rule; defaults to `\"\"`.",
        ),
        "observed_tags": attr.string_list(
            doc = "Observed `tags` attribute recorded on the underlying rule; defaults to `[]`.",
        ),
    },
    doc = "Verifies default `large` size and `manual` tag exclusion on `flutter_drive_test`.",
)

def flutter_drive_test_test_suite(name):
    """Declares the fixtures and analysis tests for `flutter_drive_test`.

    Args:
        name: Prefix of every fixture target and name of the enclosing `test_suite`.
    """
    _app_stub(name = name + "_app_stub", tags = ["manual"])
    _not_android(name = name + "_not_android", tags = ["manual"])
    _driver_stub(name = name + "_driver_stub", tags = ["manual"])
    flutter_drive_test(
        name = name + "_ok",
        app = ":" + name + "_app_stub",
        driver = ":" + name + "_driver_stub",
        package_name = "com.example.drive",
        tags = ["extra"],
    )
    flutter_drive_test(
        name = name + "_script",
        app = ":" + name + "_app_stub",
        driver = "lib/language_version_main.dart",
        package_name = "com.example.drive",
    )
    flutter_drive_test(
        name = name + "_no_driver",
        app = ":" + name + "_app_stub",
        package_name = "com.example.drive",
    )
    flutter_drive_test(
        name = name + "_bad_app",
        app = ":" + name + "_not_android",
        driver = ":" + name + "_driver_stub",
        package_name = "com.example.drive",
    )
    _shape_test(
        name = name + "_shape",
        target_under_test = ":" + name + "_ok",
        name_of_test = name + "_ok",
        expected_driver_suffixes = ["_driver_stub"],
        size = "small",
    )
    _shape_test(
        name = name + "_script_shape",
        target_under_test = ":" + name + "_script",
        name_of_test = name + "_script",
        expected_driver_suffixes = ["language_version_main.dart", "_script_driver.dill"],
        size = "small",
    )
    declared = native.existing_rule(name + "_ok")
    _tags_size_test(
        name = name + "_tags_size",
        target_under_test = ":" + name + "_ok",
        observed_size = declared["size"],
        observed_tags = declared["tags"],
        size = "small",
    )
    _missing_driver_test(
        name = name + "_missing_driver",
        target_under_test = ":" + name + "_no_driver",
        size = "small",
    )
    _not_android_app_test(
        name = name + "_not_android_app",
        target_under_test = ":" + name + "_bad_app",
        size = "small",
    )
    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_shape",
            ":" + name + "_script_shape",
            ":" + name + "_missing_driver",
            ":" + name + "_not_android_app",
            ":" + name + "_tags_size",
        ],
    )
