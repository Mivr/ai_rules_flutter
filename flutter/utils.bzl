"""Public compile helpers for downstream rules.

What `flutter_application` compiles with, published the way
`@rules_dart//dart:utils.bzl` publishes its helpers: a rule in another module
composes its own kernel compile over these with nothing but public loads.

```starlark
load(
    "@rules_flutter//flutter:utils.bzl",
    "FLUTTER_KERNEL_COMPILE_ATTRS",
    "FLUTTER_KERNEL_COMPILE_TOOLCHAINS",
    "compile_package_config",
    "flutter_kernel_compile_action",
    "flutter_kernel_compile_tools",
)

def _my_compile_impl(ctx):
    tools = flutter_kernel_compile_tools(ctx)
    pc = compile_package_config(ctx, packages, all_srcs)
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
    )
    return [DefaultInfo(files = depset([output]))]

my_compile = rule(
    implementation = _my_compile_impl,
    attrs = {
        "main": attr.label(mandatory = True, allow_single_file = [".dart"]),
        "srcs": attr.label_list(allow_files = [".dart"]),
        "deps": attr.label_list(providers = [DartInfo]),
    } | FLUTTER_KERNEL_COMPILE_ATTRS,
    toolchains = FLUTTER_KERNEL_COMPILE_TOOLCHAINS,
)
```

Stability note: these helpers are stable for external use. New optional
parameters may be added to `flutter_kernel_compile_action` (and matching
fields to the `flutter_kernel_compile_tools` struct), but existing calls keep
their argv and action keys.

Allowed `vm_flags` (Dart VM flags before the snapshot): heap/GC sizing, each
spelled `--name=<bytes>` with a plain integer (`--old-gen-heap-size`,
`--new-gen-semi-initial-size`, `--new-gen-semi-max-size`,
`--new-gen-garbage-threshold`, `--new-gen-growth-factor`), and bare
diagnostics (`--enable-asserts`, `--verbose-gc`, `--concurrent-mark`,
`--concurrent-sweep`). Anything else — notably `--packages`, `--platform`,
`--*-dill`, `--native-assets`, `--timeline-recorder`, `--snapshot*`,
`--observe`, `--dfe` — fails the build at analysis, as does any
`extra_flags` entry naming a file the compile does not declare. The compile
guard takes every allowed read from a manifest of declared files, never from
the argv, so a smuggled flag cannot widen what the compile may read.
"""

load(
    "//flutter/private:app_entrypoint.bzl",
    _compile_package_config = "compile_package_config",
)
load(
    "//flutter/private:flutter_compile.bzl",
    _FLUTTER_KERNEL_COMPILE_ATTRS = "FLUTTER_KERNEL_COMPILE_ATTRS",
    _FLUTTER_KERNEL_COMPILE_TOOLCHAINS = "FLUTTER_KERNEL_COMPILE_TOOLCHAINS",
    _flutter_kernel_compile_action = "flutter_kernel_compile_action",
    _flutter_kernel_compile_tools = "flutter_kernel_compile_tools",
)
load(
    "//flutter/private:flutter_test_common.bzl",
    _flutter_test_bootstrap_action = "flutter_test_bootstrap_action",
)

# The whole-program kernel compile behind every Flutter target: runs
# `frontend_server` via `dartaotruntime` behind the `kernel_filter` guard.
# See `flutter_kernel_compile_action` for the parameters (including `vm_flags`,
# `import_dill` and `resource_set`).
flutter_kernel_compile_action = _flutter_kernel_compile_action

# Co-locates packages and writes the matching `package_config.json`, including
# `extra_roots` entries for packages with no sources in the closure. See
# `compile_package_config` — the caller must also make those roots' files
# action inputs.
compile_package_config = _compile_package_config

# The attrs a calling rule merges into its own (`main`/`srcs`/`deps` stay the
# caller's to declare). See `FLUTTER_KERNEL_COMPILE_ATTRS`.
FLUTTER_KERNEL_COMPILE_ATTRS = _FLUTTER_KERNEL_COMPILE_ATTRS

# The toolchains a calling rule declares. See `FLUTTER_KERNEL_COMPILE_TOOLCHAINS`.
FLUTTER_KERNEL_COMPILE_TOOLCHAINS = _FLUTTER_KERNEL_COMPILE_TOOLCHAINS

# Resolves the tool Files a `flutter_kernel_compile_action` call needs.
# See `flutter_kernel_compile_tools`.
flutter_kernel_compile_tools = _flutter_kernel_compile_tools

# The attrs a rule calling `flutter_test_bootstrap` merges into its own. Only
# the golden comparator: `flutter_test_bootstrap` reads the calling target's
# `deps` itself, and `ctx.actions` / `ctx.label` need no attrs. Implicit (so no
# private-named attr enters the caller's build-visible contract), defaulting to
# the comparator `flutter_test` installs — see `flutter_test_bootstrap`.
FLUTTER_TEST_BOOTSTRAP_ATTRS = {
    "_golden_comparator_src": attr.label(
        default = Label("//flutter/private/goldens:comparator.dart"),
        allow_single_file = [".dart"],
    ),
}

def flutter_test_bootstrap(ctx, test_main_uri, output):
    """Write the bootstrap library a prebuilt test kernel is compiled from.

    The same bootstrap `flutter_test` compiles into its own test kernel: a
    generated entry point that imports the test at `test_main_uri`, registers
    it with `package:test_api`'s `RemoteListener`, and dials the test harness
    back over a WebSocket. A kernel compiled from anything else does not speak
    the harness protocol, so a `flutter_prebuilt_test` over it fails to
    connect rather than running zero tests.

    When the calling target's `deps` expose `package:flutter_test`, the golden
    comparator is staged next to `output` and imported by the bootstrap, as in
    `flutter_test`. That needs `FLUTTER_TEST_BOOTSTRAP_ATTRS` merged into the
    calling rule's attrs; without it — or with only `package:test_api` in
    `deps` — the bootstrap carries no golden block. Either way the harness, tag
    and JUnit handling match `flutter_test`'s.

    A suite outside any `lib/` has no `package:` URI to import it by. Name it
    by path from the bootstrap instead — climb out of the bootstrap's directory,
    then descend to the suite's exec-root-relative path — as
    `e2e/hello_world/custom_test_kernel.bzl` does:

    ```starlark
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    test_main_uri = "../" * len(bootstrap.path.split("/")[:-1]) + ctx.file.main.path
    comparator = flutter_test_bootstrap(ctx, test_main_uri, bootstrap)
    srcs = [bootstrap] + ([comparator] if comparator else [])
    pc = compile_package_config(ctx, packages, srcs + all_test_srcs)
    flutter_kernel_compile_action(
        ctx = ctx,
        dartaotruntime = tools.dartaotruntime,
        kernel_filter_tool = tools.kernel_filter_tool,
        frontend_server = tools.frontend_server,
        platform_dill = tools.platform_dill,
        main = bootstrap,
        srcs = pc.srcs,
        package_config = pc.config_file,
        output = kernel_dill,
    )
    ```

    Then run the resulting dill under `flutter_prebuilt_test`.

    Args:
        ctx: The calling rule's context. Reads the calling target's `deps`
            for `package:flutter_test`, and the `_golden_comparator_src` file
            when the rule merges `FLUTTER_TEST_BOOTSTRAP_ATTRS`.
        test_main_uri: Import URI from the bootstrap to the test entrypoint.
        output: The already-declared bootstrap `.dart` File to write.

    Returns:
        The staged golden comparator File, or None. Pass it to the kernel
        compile alongside the bootstrap when present.
    """
    return _flutter_test_bootstrap_action(ctx, test_main_uri, output)
