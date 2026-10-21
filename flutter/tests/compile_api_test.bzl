"""Analysis tests for the public compile API (`//flutter:utils.bzl`).

`flutter_kernel_compile_action` and `compile_package_config` live in
`//flutter/private`, but downstream rules compose over them through the public
`//flutter:utils.bzl` — this file's caller rule loads only that (plus the
public `@rules_dart` helpers), never `//flutter/private`, and still builds a
kernel with `vm_flags`/`import_dill`/`resource_set`. The tests pin what the
hidden consumer checks rely on:

- the default argv is unchanged (no `vm_flags` slot, no `--import-dill`);
- `vm_flags` sit right after `dartaotruntime`, before the snapshot, and
  anything that is not a `--flag` fails the build;
- `import_dill` is passed as `--import-dill=<path>` and is an action input,
  while an undeclared source beside it stays out of the inputs and the
  mounted roots (its refusal is pinned in `kernel_filter_test.dart`);
- `extra_roots` entries appear in the emitted `package_config.json`;
- a caller that sets every new parameter still compiles (`build_test` —
  `resource_set` is not observable from analysis, so executing the action is
  the presence check).
"""

load("@bazel_skylib//lib:unittest.bzl", "analysistest", "asserts")
load("@bazel_skylib//rules:build_test.bzl", "build_test")
load("@rules_dart//dart:defs.bzl", "dart_library")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load("@rules_dart//dart:utils.bzl", "collect_packages", "collect_transitive_srcs")
load("//flutter:utils.bzl", "FLUTTER_KERNEL_COMPILE_ATTRS", "FLUTTER_KERNEL_COMPILE_TOOLCHAINS", "compile_package_config", "flutter_kernel_compile_action", "flutter_kernel_compile_tools")
load(":action_content.bzl", "package_entry", "written_json")

# `HOST_COMPATIBLE` without the `//flutter/private` load this file must not
# have: these compiles run on a host OS only.
_HOST_COMPATIBLE = select({
    "@platforms//os:linux": [],
    "@platforms//os:macos": [],
    "@platforms//os:windows": [],
    "//conditions:default": ["@platforms//:incompatible"],
})

_TEST_RESOURCE_SET = {"memory": 8000, "cpu": 1}

def _compile_api_caller_impl(ctx):
    """A downstream-style compile over the public utils only."""
    tools = flutter_kernel_compile_tools(ctx)
    packages = collect_packages(ctx.attr.deps)
    all_srcs = list(ctx.files.srcs) + collect_transitive_srcs(ctx.attr.deps).to_list() + [ctx.file.main]
    pc = compile_package_config(ctx, packages, all_srcs, extra_roots = ctx.attr.extra_roots)
    output = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = tools.dartaotruntime,
        kernel_filter_tool = tools.kernel_filter_tool,
        frontend_server = tools.frontend_server,
        platform_dill = tools.platform_dill,
        main = ctx.file.main,
        srcs = pc.srcs,
        package_config = pc.config_file,
        output = output,
        vm_flags = ctx.attr.vm_flags,
        import_dill = ctx.file.import_dill if ctx.attr.import_dill else None,
        resource_set = _TEST_RESOURCE_SET if ctx.attr.use_resource_set else None,
    )
    return [DefaultInfo(files = depset([output, pc.config_file]))]

_compile_api_caller = rule(
    implementation = _compile_api_caller_impl,
    attrs = {
        "main": attr.label(
            doc = "The entrypoint .dart source.",
            mandatory = True,
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Additional Dart sources.",
            allow_files = [".dart"],
        ),
        "deps": attr.label_list(
            doc = "DartInfo dependencies.",
            providers = [DartInfo],
        ),
        "vm_flags": attr.string_list(
            doc = "Dart VM flags for dartaotruntime.",
        ),
        "import_dill": attr.label(
            doc = "Pre-compiled summary dill.",
            allow_single_file = True,
        ),
        "use_resource_set": attr.bool(
            doc = "Constrain the compile action's host resources.",
            default = False,
        ),
        "extra_roots": attr.string_dict(
            doc = "Package name to exec-root-relative root for sourceless packages.",
        ),
    } | FLUTTER_KERNEL_COMPILE_ATTRS,
    toolchains = FLUTTER_KERNEL_COMPILE_TOOLCHAINS,
)

def _kernel_action(env):
    kernels = [
        a
        for a in analysistest.target_actions(env)
        if a.mnemonic == "FlutterKernelCompile"
    ]
    asserts.equals(env, 1, len(kernels), "expected one FlutterKernelCompile")
    return kernels[0] if kernels else None

def _compile_argv(env, action):
    """The frontend_server argv: everything after the kernel_filter `--`."""
    argv = action.argv if action else []
    asserts.true(env, "--" in argv, "expected the kernel_filter `--` separator, got %r" % (argv,))
    if "--" not in argv:
        return []
    return argv[argv.index("--") + 1:]

def _default_argv_test_impl(ctx):
    """Without the new parameters the action keeps its exact default shape."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = _compile_argv(env, action)

    # `[dartaotruntime, frontend_server snapshot, ...]`: no `vm_flags` slot.
    asserts.true(env, len(argv) > 2, "expected a full compile argv, got %r" % (argv,))
    if len(argv) > 2:
        asserts.true(
            env,
            argv[1].endswith(".snapshot"),
            "with no vm_flags the snapshot follows dartaotruntime directly, got %r" % (argv[:3],),
        )
    asserts.equals(
        env,
        [],
        [a for a in argv if a.startswith("--import-dill")],
        "the default compile passes no --import-dill, got %r" % (argv,),
    )
    asserts.true(
        env,
        argv[-1].endswith("flutter/tests/compile_api_main.dart") if argv else False,
        "the entrypoint source closes the argv, got %r" % (argv[-1] if argv else None,),
    )
    return analysistest.end(env)

def _extras_argv_test_impl(ctx):
    """`vm_flags` precede the snapshot; `import_dill` rides along as an input."""
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    argv = _compile_argv(env, action)

    asserts.true(env, len(argv) > 3, "expected a full compile argv, got %r" % (argv,))
    if len(argv) > 3:
        asserts.equals(
            env,
            "--old-gen-heap-size=2147483648",
            argv[1],
            "vm_flags sit right after dartaotruntime, got %r" % (argv[:4],),
        )
        asserts.true(
            env,
            argv[2].endswith(".snapshot"),
            "the snapshot follows vm_flags, got %r" % (argv[:4],),
        )

    import_args = [a for a in argv if a.startswith("--import-dill=")]
    asserts.equals(env, 1, len(import_args), "expected one --import-dill=<path>, got %r" % (argv,))
    if action and len(import_args) == 1:
        input_paths = [f.path for f in action.inputs.to_list()]
        dill_path = import_args[0][len("--import-dill="):]
        asserts.true(
            env,
            dill_path in input_paths,
            "--import-dill path %r must be an action input" % dill_path,
        )
        asserts.true(
            env,
            dill_path.endswith("flutter/tests/compile_api_import.dill"),
            "unexpected --import-dill path %r" % dill_path,
        )

    # The `deps` closure still resolves: the extras main reaches its package.
    config = written_json(env, ".package_config.json")
    asserts.true(
        env,
        package_entry(config, "compile_api_dep") != None,
        "expected a `compile_api_dep` entry in .package_config.json",
    )
    return analysistest.end(env)

def _vm_flags_reject_test_impl(ctx):
    env = analysistest.begin(ctx)
    asserts.expect_failure(env, "vm_flags")
    return analysistest.end(env)

def _undeclared_staged_out_test_impl(ctx):
    """An undeclared source beside an `import_dill` stays out of the compile.

    The sibling exists on disk and the entrypoint imports it, but no target
    declares it: it must reach neither the action inputs nor any mounted
    `--filesystem-root`. `kernel_filter` then refuses the import before the
    compiler runs (see `kernel_filter_test.dart`); the staging here is what
    leaves the compiler nothing undeclared to read whatever its spelling.
    """
    env = analysistest.begin(ctx)
    action = _kernel_action(env)
    if action:
        input_paths = [f.path for f in action.inputs.to_list()]
        asserts.equals(
            env,
            [],
            [p for p in input_paths if p.endswith("compile_api_undeclared_sibling.dart")],
            "the undeclared sibling must not be an action input",
        )
        argv = _compile_argv(env, action)
        roots = [argv[i + 1] for i in range(len(argv) - 1) if argv[i] == "--filesystem-root"]
        asserts.false(
            env,
            "." in roots,
            "only the staging root is mounted, got %r" % (roots,),
        )
        asserts.equals(
            env,
            1,
            len([a for a in argv if a.startswith("--import-dill=")]),
            "the import_dill still rides along, got %r" % (argv,),
        )
    return analysistest.end(env)

def _extra_roots_test_impl(ctx):
    """`extra_roots` gives a sourceless package its config entry."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".package_config.json")
    entry = package_entry(config, "compile_api_ghost")
    asserts.true(env, entry != None, "expected a `compile_api_ghost` entry in .package_config.json")
    if entry != None:
        asserts.true(
            env,
            entry.get("rootUri", "").endswith("flutter/tests"),
            "the ghost rootUri must name the extra root, got %r" % (entry,),
        )
        asserts.equals(env, "lib/", entry.get("packageUri"))
    return analysistest.end(env)

def _no_extra_roots_test_impl(ctx):
    """Without `extra_roots` the sourceless package stays out of the config."""
    env = analysistest.begin(ctx)
    config = written_json(env, ".package_config.json")
    asserts.equals(
        env,
        None,
        package_entry(config, "compile_api_ghost"),
        "no entry without extra_roots",
    )
    return analysistest.end(env)

_DBG = {
    "//command_line_option:compilation_mode": "dbg",
    str(Label("//flutter:profile")): False,
}

_default_argv_test = analysistest.make(_default_argv_test_impl, config_settings = _DBG)
_extras_argv_test = analysistest.make(_extras_argv_test_impl, config_settings = _DBG)
_vm_flags_reject_test = analysistest.make(_vm_flags_reject_test_impl, config_settings = _DBG, expect_failure = True)
_undeclared_staged_out_test = analysistest.make(_undeclared_staged_out_test_impl, config_settings = _DBG)
_extra_roots_test = analysistest.make(_extra_roots_test_impl, config_settings = _DBG)
_no_extra_roots_test = analysistest.make(_no_extra_roots_test_impl, config_settings = _DBG)

def compile_api_test_suite(name):
    """Fixtures and tests for the public compile API.

    Args:
        name: The test suite name.
    """
    dart_library(
        name = "_compile_api_dep",
        package_name = "compile_api_dep",
        srcs = ["lib/compile_api_dep.dart"],
        tags = ["manual"],
    )
    dart_library(
        name = "_compile_api_ghost",
        package_name = "compile_api_ghost",
        srcs = [],
        tags = ["manual"],
    )

    _compile_api_caller(
        name = "_compile_api_default",
        main = "compile_api_main.dart",
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_extras",
        main = "compile_api_extras_main.dart",
        deps = [":_compile_api_dep"],
        vm_flags = ["--old-gen-heap-size=2147483648"],
        import_dill = "compile_api_import.dill",
        use_resource_set = True,
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_bad_flags",
        main = "compile_api_main.dart",
        vm_flags = ["--old-gen-heap-size=2147483648", "frontend_server_aot.dart.snapshot"],
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_undeclared",
        main = "compile_api_undeclared_main.dart",
        import_dill = "compile_api_import.dill",
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_roots",
        main = "compile_api_main.dart",
        deps = [":_compile_api_ghost"],
        extra_roots = {"compile_api_ghost": "flutter/tests"},
        tags = ["manual"],
    )
    _compile_api_caller(
        name = "_compile_api_no_roots",
        main = "compile_api_main.dart",
        deps = [":_compile_api_ghost"],
        tags = ["manual"],
    )

    # Executed compiles: the default shape and every-new-parameter shape both
    # build. `resource_set` is invisible to analysis, so running the action is
    # its presence check. Neither sets `import_dill`: the checked-in stub is
    # analysis-only, and a real compile would read it as a dill.
    _compile_api_caller(
        name = "_compile_api_build_default",
        main = "compile_api_main.dart",
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )
    _compile_api_caller(
        name = "_compile_api_build_extras",
        main = "compile_api_extras_main.dart",
        deps = [":_compile_api_dep"],
        vm_flags = ["--old-gen-heap-size=2147483648"],
        use_resource_set = True,
        tags = ["manual"],
        target_compatible_with = _HOST_COMPATIBLE,
    )

    _default_argv_test(
        name = name + "_default_argv",
        target_under_test = ":_compile_api_default",
    )
    _extras_argv_test(
        name = name + "_extras_argv",
        target_under_test = ":_compile_api_extras",
    )
    _vm_flags_reject_test(
        name = name + "_vm_flags_reject",
        target_under_test = ":_compile_api_bad_flags",
    )
    _undeclared_staged_out_test(
        name = name + "_undeclared_staged_out",
        target_under_test = ":_compile_api_undeclared",
    )
    _extra_roots_test(
        name = name + "_extra_roots",
        target_under_test = ":_compile_api_roots",
    )
    _no_extra_roots_test(
        name = name + "_no_extra_roots",
        target_under_test = ":_compile_api_no_roots",
    )
    build_test(
        name = name + "_build",
        target_compatible_with = _HOST_COMPATIBLE,
        targets = [
            ":_compile_api_build_default",
            ":_compile_api_build_extras",
        ],
    )

    native.test_suite(
        name = name,
        tests = [
            ":" + name + "_default_argv",
            ":" + name + "_extras_argv",
            ":" + name + "_vm_flags_reject",
            ":" + name + "_undeclared_staged_out",
            ":" + name + "_extra_roots",
            ":" + name + "_no_extra_roots",
            ":" + name + "_build",
        ],
    )
