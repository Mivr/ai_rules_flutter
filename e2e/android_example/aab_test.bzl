"""Analysis test for `flutter_android_aab`.

The rule builds on rules_android 0.8.0's public `android_application` macro:
the wrapped target emits `<name>_unsigned.aab` through one `BuildBundle`
action (`bundletool build-bundle`), and that action's bundletool is the
pinned Maven artifact of `@rules_android_maven`. The test names both so that
a rules_android bump that renames the output or the mnemonic fails loudly.
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")

def _aab_build_bundle_impl(ctx):
    env = analysistest.begin(ctx)
    bundle_actions = [a for a in analysistest.target_actions(env) if a.mnemonic == "BuildBundle"]
    asserts.equals(env, 1, len(bundle_actions))
    action = bundle_actions[0]
    asserts.equals(env, ["build-bundle"], [a for a in action.argv if a == "build-bundle"])
    asserts.equals(
        env,
        [ctx.attr.unsigned_aab],
        [o.basename for o in action.outputs.to_list()],
    )

    # The bundletool jar comes from the sha256-locked rules_android_maven
    # repo; no host tool path appears among the inputs.
    input_paths = [i.path for i in action.inputs.to_list()]
    asserts.true(
        env,
        [p for p in input_paths if "rules_android_maven" in p and "bundletool" in p],
        "no pinned bundletool jar among the BuildBundle inputs: %s" % input_paths,
    )
    asserts.equals(env, [], [p for p in input_paths if p.startswith("/")])
    return analysistest.end(env)

aab_build_bundle_test = analysistest.make(
    _aab_build_bundle_impl,
    attrs = {"unsigned_aab": attr.string(mandatory = True)},
)
