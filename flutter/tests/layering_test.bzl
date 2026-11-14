"""Analysis tests for the strict-layering check on `flutter_test`.

The fixture in `layering_fixture/` has `:bad_test` import `package:leaf`, which
only its dep `mid` depends on. The tests pin what the check's action reads and
that the `_validation` output group carries it (and carries nothing when the
`dart_layering_check` feature is off). Building `:bad_test` with
`--output_groups=_validation` is the failing case, and `:good_test` the passing
one: an action's exit status is not visible from analysis.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

visibility(["//flutter/tests/..."])

def _flag_values(argv, flag):
    """The values that follow each occurrence of `flag` in `argv`."""
    return [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == flag]

def _check_actions(env):
    return [a for a in analysistest.target_actions(env) if a.mnemonic == "DartImportCheck"]

def _on_test_impl(ctx):
    """The test runs one check over its own sources and returns it in `_validation`."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    stamps = [f.basename for f in target[OutputGroupInfo]._validation.to_list()]
    asserts.true(
        env,
        "%s.import_check" % target.label.name in stamps,
        "_validation carries the test's own check stamp: %s" % stamps,
    )
    checks = _check_actions(env)
    asserts.equals(env, 1, len(checks), "one DartImportCheck over the test's own sources")
    if len(checks) != 1:
        return analysistest.end(env)
    argv = checks[0].argv
    direct = _flag_values(argv, "--direct-package")
    for name in ctx.attr.expect_direct:
        asserts.true(env, name in direct, "%s is a direct package: %s" % (name, argv))
    for name in ctx.attr.expect_absent:
        asserts.true(env, name not in direct, "%s is not a direct package: %s" % (name, argv))
    asserts.equals(env, ["layering_fixture"], _flag_values(argv, "--own-package"))
    srcs = _flag_values(argv, "--src")
    for path in ctx.attr.expect_srcs:
        asserts.true(env, path in srcs, "%s is checked: %s" % (path, srcs))
    asserts.false(
        env,
        any([s.endswith("_bootstrap.dart") for s in srcs]),
        "the generated bootstrap is not checked: %s" % srcs,
    )
    return analysistest.end(env)

layering_on_test = analysistest.make(
    _on_test_impl,
    attrs = {
        "expect_absent": attr.string_list(doc = "Package names argv must not list as direct."),
        "expect_direct": attr.string_list(doc = "Package names argv must list as direct."),
        "expect_srcs": attr.string_list(doc = "Short paths of the sources the check must read."),
    },
)

def _off_test_impl(ctx):
    """With the feature off, the test registers no check and its group has no own stamp."""
    env = analysistest.begin(ctx)
    target = analysistest.target_under_test(env)
    asserts.equals(env, 0, len(_check_actions(env)), "no DartImportCheck with the feature off")
    stamps = [f.basename for f in target[OutputGroupInfo]._validation.to_list()]
    asserts.false(
        env,
        "%s.import_check" % target.label.name in stamps,
        "_validation has no check stamp of the test's own: %s" % stamps,
    )
    return analysistest.end(env)

layering_off_test = analysistest.make(_off_test_impl)
