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
