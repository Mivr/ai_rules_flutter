"""Flutter kernel compilation action using the frontend_server.

Flutter compilation differs from vanilla Dart in that it uses:
- Flutter's patched SDK (platform_strong.dill) instead of the standard Dart SDK
- The frontend_server_aot.dart.snapshot instead of `dart compile kernel`
"""

load("//flutter:providers.bzl", "resolve_exec_dart_vm", "resolve_flutter_sdk_info")
load("//flutter/private:app_entrypoint.bzl", "APP_SCHEME", "stage_generated_inputs")

# `vm_flags` entries analysis accepts, as flag names without the leading
# `--`. The Dart VM interprets every flag before the snapshot, so only flags
# with no file, network or compilation-semantics side effects are allowed:
#
# - heap and GC sizing, each spelled `--name=<bytes>` with a plain integer:
#   `old-gen-heap-size`, `new-gen-semi-initial-size`, `new-gen-semi-max-size`,
#   `new-gen-garbage-threshold`, `new-gen-growth-factor`;
# - side-effect-free diagnostics, spelled bare: `enable-asserts`,
#   `verbose-gc`, `concurrent-mark`, `concurrent-sweep`.
#
# Name matching ignores case and treats `-` and `_` as the same, the way the
# VM parses them. Everything else fails the build at analysis — notably
# `--packages`, `--platform`, `--*-dill`, `--native-assets`,
# `--timeline-recorder`, `--snapshot*`, `--observe`, `--dfe`,
# `--ignore-unrecognized-flags` and `--define`/`-D` (defines belong in
# `defines`): such flags rename the compile's inputs, smuggle undeclared
# bytes into the dill, or write host files outside the action's declared
# inputs and outputs.
_VM_FLAG_SIZES = [
    "old-gen-heap-size",
    "new-gen-semi-initial-size",
    "new-gen-semi-max-size",
    "new-gen-garbage-threshold",
    "new-gen-growth-factor",
]

_VM_FLAGS_BARE = [
    "enable-asserts",
    "verbose-gc",
    "concurrent-mark",
    "concurrent-sweep",
]

# `extra_flags` entries analysis refuses, as flag names without leading
# dashes: `frontend_server` flags that name a file (or a host side effect)
# the action does not declare. The action passes its own inputs
# (`--packages`, `--platform`, `--filesystem-root`, `--source`,
# `--native-assets`, `--recorded-uses`, `--from-dill`, `--import-dill`,
# `--output-dill`) from Starlark `File` objects and records them in the
# `kernel_filter` manifest; a caller spelling any of them in `extra_flags`
# fails the build at analysis instead. Name matching ignores case and treats
# `-` and `_` as the same.
_EXTRA_FLAG_BLOCKED = [
    "packages",
    "package-config",
    "platform",
    "sdk-root",
    "filesystem-root",
    "filesystem-scheme",
    "source",
    "native-assets",
    "recorded-uses",
    "from-dill",
    "import-dill",
    "output-dill",
    "output-incremental-dill",
    "depfile",
    "timeline-recorder",
    "snapshot",
    "snapshot-kind",
    "save-debugging-info",
    "observe",
    "enable-vm-service",
    "dfe",
]

# `extra_flags` entries that would switch off the dependency report
# `kernel_filter` verifies after the compile. The report (`+file://` lines)
# is what turns an undeclared read into a loud build error; switching it off
# makes the check pass vacuously while the dill still embeds the undeclared
# bytes. The compile passes its own `--print-incremental-dependencies` after
# the caller's flags and fails closed on zero reads, but the spelling is
# refused at analysis too so the failure names the flag early. Name matching
# is the same as below (case-insensitive, `-` and `_` the same, one or two
# leading dashes).
_READ_SET_FLAGS = [
    "print-incremental-dependencies",
    "no-print-incremental-dependencies",
]

def _normalize_flag_name(name):
    return name.lower().replace("_", "-")

def _is_uint(value):
    if value == "":
        return False
    for c in value.elems():
        if c not in "0123456789":
            return False
    return True

def _check_vm_flags(label, vm_flags):
    for flag in vm_flags:
        if not flag.startswith("--") or flag == "--":
            fail("%s: vm_flags entries must be `--flag` passed to dartaotruntime, got %r" % (label, flag))
        name, eq, value = flag[2:].partition("=")
        norm = _normalize_flag_name(name)
        if norm in _VM_FLAGS_BARE:
            if eq:
                fail("%s: vm_flags %r takes no value: `%s` is a bare diagnostic flag" % (label, flag, flag))
        elif norm in _VM_FLAG_SIZES:
            if not eq or not _is_uint(value):
                fail("%s: vm_flags %r needs `--name=<bytes>` with a plain integer value" % (label, flag))
        else:
            fail("%s: vm_flags %r is not allowed: only heap/GC sizing (%s) and bare diagnostics (%s) may precede the snapshot; flags naming files or side effects (`--packages`, `--*-dill`, `--platform`, `--native-assets`, `--timeline-recorder`, `--snapshot*` and similar) are refused" % (label, flag, ", ".join(["--" + f for f in _VM_FLAG_SIZES]), ", ".join(["--" + f for f in _VM_FLAGS_BARE])))

def _check_extra_flags(label, extra_flags):
    for flag in extra_flags:
        if not flag.startswith("-") or flag == "-" or flag == "--":
            fail("%s: extra_flags entries must be frontend_server `--flag`s, got %r" % (label, flag))
        stripped = flag[2:] if flag.startswith("--") else flag[1:]
        name, _, _ = stripped.partition("=")
        norm = _normalize_flag_name(name)
        if norm in _READ_SET_FLAGS:
            fail("%s: extra_flags %r controls the dependency report the compile verifies: the compile controls `--print-incremental-dependencies` itself, remove the flag" % (label, flag))
        if norm in _EXTRA_FLAG_BLOCKED:
            fail("%s: extra_flags %r names a file the compile does not declare: pass inputs through `srcs`/`deps`/`import_dill`/`from_dill`/`native_assets_manifest` instead" % (label, flag))

# Private tool labels a downstream rule merges into its own `attrs` to call
# `flutter_kernel_compile_action` — the Flutter half of what rules_dart
# publishes as `KERNEL_MODULE_ATTRS`. Carries no user-facing attrs: the
# caller's rule declares its own `main`, `srcs` and `deps`.
FLUTTER_KERNEL_COMPILE_ATTRS = {
    "_kernel_filter_tool": attr.label(
        default = Label("//flutter/private/tools:kernel_filter"),
        executable = True,
        cfg = "exec",
    ),
}

# Toolchains a downstream rule declares to call `flutter_kernel_compile_action`
# (via `flutter_kernel_compile_tools`) and `compile_package_config` — the
# Flutter half of what rules_dart publishes as `MODULAR_KERNEL_TOOLCHAINS`.
# The product-tools toolchain is optional: only `flutter_kernel_compile_tools`
# with `product = True` reads it.
FLUTTER_KERNEL_COMPILE_TOOLCHAINS = [
    "@rules_flutter//flutter:toolchain_type",
    "@rules_dart//dart:exec_tools_toolchain_type",
    config_common.toolchain_type("@rules_flutter//flutter:product_tools_toolchain_type", mandatory = False),
    Label("@rules_dart//dart:copy_toolchain_type"),
]

def flutter_kernel_compile_tools(ctx, product = False):
    """Resolves the tool Files a `flutter_kernel_compile_action` call needs.

    For a rule in another module composing over `@rules_flutter//flutter:utils.bzl`
    — the Flutter half of what rules_dart publishes as `find_kernel_module_tools`.
    The rule declares `FLUTTER_KERNEL_COMPILE_ATTRS` in its `attrs` and
    `FLUTTER_KERNEL_COMPILE_TOOLCHAINS` in its `toolchains`, then calls this
    and threads the struct into `flutter_kernel_compile_action`.

    Args:
        ctx: The caller rule's context.
        product: When True, `platform_dill` is the release
            `platform_strong_product.dill`; otherwise the debug
            `platform_strong.dill`. A True caller needs the product-tools
            sub-toolchain resolved (it is in `FLUTTER_KERNEL_COMPILE_TOOLCHAINS`).

    Returns:
        struct with `dartaotruntime`, `kernel_filter_tool`, `frontend_server`
        and `platform_dill`.
    """
    flutter_sdk_info = resolve_flutter_sdk_info(ctx)
    platform_dill = flutter_sdk_info.platform_kernel_dill_product if product else flutter_sdk_info.platform_kernel_dill
    if platform_dill == None:
        fail(
            "%s: no %s platform dill: declare the product-tools sub-toolchain from FLUTTER_KERNEL_COMPILE_TOOLCHAINS." %
            (ctx.label, "product" if product else "debug"),
        )
    return struct(
        dartaotruntime = flutter_sdk_info.dartaotruntime,
        kernel_filter_tool = ctx.executable._kernel_filter_tool,
        frontend_server = flutter_sdk_info.frontend_server,
        platform_dill = platform_dill,
    )

def flutter_kernel_compile_action(
        ctx,
        dartaotruntime,
        kernel_filter_tool,
        frontend_server,
        platform_dill,
        main,
        srcs,
        package_config,
        output,
        entrypoint_uri = None,
        aot = False,
        defines = [],
        extra_flags = [],
        target = "flutter",
        native_assets_manifest = None,
        dart_plugin_registrant_uri = None,
        filesystem_roots = [],
        recorded_uses = None,
        from_dill = None,
        vm_flags = [],
        import_dill = None,
        resource_set = None):
    """Creates a Flutter kernel compilation action.

    Invokes the frontend_server via dartaotruntime to compile Dart sources
    to a kernel .dill file using Flutter's patched platform SDK.

    Args:
        ctx: The rule context.
        dartaotruntime: The dartaotruntime executable File (from FlutterSdkInfo).
        kernel_filter_tool: The compiled `kernel_filter` executable File.
        frontend_server: The frontend_server_aot.dart.snapshot File.
        platform_dill: The platform_strong.dill File (debug or product).
        main: The entrypoint .dart source File. Always an action input and
            used for the progress message; it is *not* automatically the
            string handed to frontend_server — see [entrypoint_uri].
        srcs: List of all source Files (direct + transitive).
        package_config: The package_config.json File.
        output: The output .dill File to produce.
        entrypoint_uri: The string frontend_server compiles as the root
            library, which fixes that library's `importUri` in the kernel.
            Pass a `package:` URI (resolved via [package_config]) so the
            URI is identical regardless of where the kernel was built —
            this is required for hot reload, because `reloadSources` only
            applies a delta when the dev tool's incremental dill keys the
            library by the *same* URI as the running program. When None,
            frontend_server is given [main]'s exec path, so the root
            library's URI is a sandbox-specific `file://` path — acceptable
            only for entrypoints that are never hot-reloaded and belong to
            no package (e.g. a generated test bootstrap). The
            app_entrypoint resolver always supplies a concrete value for
            application builds.
        aot: If True, compile for AOT (adds --aot --tfa flags).
        defines: Environment declarations; each entry becomes a -D flag.
        extra_flags: Additional frontend_server flags (e.g. `--incremental`,
            `--track-widget-creation`). Each entry must be a `--flag`; a
            flag naming a file the compile does not declare (`--packages`,
            `--platform`, `--filesystem-root`, `--source`,
            `--native-assets`, `--recorded-uses`, `--from-dill`,
            `--import-dill`, `--output-dill` and similar) fails the build
            at analysis, as does any spelling of
            `--[no-]print-incremental-dependencies` (the compile controls
            the dependency report it verifies).
        target: Frontend server target model ("flutter" or "dartdevc" for web).
        native_assets_manifest: Optional `native_assets.json` File. Passed
            to the frontend_server via `--native-assets`. The frontend
            server embeds the manifest into the resulting kernel so the
            engine can resolve `package:` Native Assets at runtime.
        dart_plugin_registrant_uri: Optional `APP_SCHEME` URI of the
            generated plugin registrant (`app_scheme_location`). When set, the
            registrant is compiled into the kernel as an extra source and
            advertised via `-Dflutter.dart_plugin_registrant=` so the
            engine invokes `_PluginRegistrant.register()` before main() on
            every root-isolate launch (including hot restart). The
            multi-root scheme keeps the library's importUri identical to
            the define regardless of sandbox location — the engine matches
            them by exact string equality.
        filesystem_roots: Extra exec-root-relative directories mounted under
            `APP_SCHEME` alongside the staging root. The exec root itself is
            never mounted: only declared inputs are staged, so an undeclared
            file is not there for the compiler to read whatever its spelling.
            (`""` and `"."` entries are dropped.)
        recorded_uses: Optional declared File the compiler writes the
            `@RecordUse` uses that survive tree-shaking to (`--recorded-uses`),
            the input of package link hooks. Only an AOT compile records; a
            JIT compile writes an empty file.
        from_dill: Optional pre-linked modular `.dill` File passed via
            `--from-dill` to initialize `frontend_server` without re-parsing
            transitive sources.
        vm_flags: Optional Dart VM flags placed right after `dartaotruntime`,
            before the `frontend_server` snapshot (e.g.
            `--old-gen-heap-size=1073741824`). Only side-effect-free tuning
            is allowed: heap/GC sizing (`--old-gen-heap-size`,
            `--new-gen-semi-initial-size`, `--new-gen-semi-max-size`,
            `--new-gen-garbage-threshold`, `--new-gen-growth-factor`, each
            `--name=<bytes>`) and bare diagnostics (`--enable-asserts`,
            `--verbose-gc`, `--concurrent-mark`, `--concurrent-sweep`).
            Every entry must be a `--flag` from that list (a bare `--` or
            anything else fails the build); flags naming files or side
            effects (`--packages`, `--*-dill`, `--platform`,
            `--native-assets`, `--timeline-recorder`, `--snapshot*` and
            similar) fail at analysis. The allow-list is enforced here, and
            `kernel_filter` additionally takes every allowed read from its
            manifest — never from the argv — so a smuggled flag cannot
            widen what the compile may read.
        import_dill: Optional pre-compiled summary `.dill` File passed via
            `--import-dill=<path>` and added to the action inputs. Libraries
            arriving through it are compiled, declared inputs — not sources —
            so the read-set check and the directive guard accept them while
            still refusing undeclared source reads beside them.
        resource_set: Optional value passed to
            `ctx.actions.run(resource_set = ...)` constraining the compile
            action's host resources. Unset by default, so existing callers
            keep byte-identical actions.
    """
    _check_vm_flags(ctx.label, vm_flags)
    _check_extra_flags(ctx.label, extra_flags)
    args = ctx.actions.args()
    args.add("--")
    args.add(dartaotruntime)
    args.add_all(vm_flags)
    args.add(frontend_server)

    # --sdk-root points to the directory containing the platform dill.
    # --platform-dill specifies the exact filename when it's not the
    # default "platform_strong.dill" (e.g. web's dart2wasm_platform.dill).
    args.add("--sdk-root", platform_dill.dirname + "/")
    if platform_dill.basename != "platform_strong.dill":
        args.add("--platform", platform_dill.path)

    args.add("--target", target)
    args.add("--packages", package_config)
    args.add("--output-dill", output)

    # The compiler reports every file it reads as a `+file://` line unless
    # told not to. `kernel_filter` verifies those lines against the declared
    # inputs and drops them, so a successful compile still prints nothing (see
    # below). The boundary-key framing has no flag; kernel_filter.dart drops
    # it too.
    args.add("--verbosity=error")

    if aot:
        args.add("--aot")
        args.add("--tfa")
        args.add("--no-embed-source-text")

    # Compilation mode flags: enable assertions in `-c dbg` and in non-AOT
    # compiles (such as `flutter_test` fallback compiles).
    bazel_mode = ctx.var["COMPILATION_MODE"]
    if bazel_mode == "dbg" or not aot:
        args.add("--enable-asserts")

    for d in defines:
        args.add("-D" + d)

    # Stage every declared input into a per-action staging root and mount only
    # it under APP_SCHEME — never the exec root (`.`) and never
    # `ctx.bin_dir.path`. Mounting either lets the compiler read files the
    # action did not declare: a `file:` directive reads them straight off the
    # host under every strategy, and Bazel caches the stale result. Behind the
    # staging root an undeclared file is not there to be read whatever its
    # spelling, and `kernel_filter` refuses disallowed directives and verifies
    # the compiler's read set on top. Staging by workspace path keeps every
    # `org-dartlang-app:///` URI (package roots, the entrypoint, the
    # registrant) resolving where it did under `.`.
    compile_sources = [main] if from_dill != None else [main] + srcs
    stage = stage_generated_inputs(ctx, compile_sources, output.basename, include_sources = True)
    mounted_roots = []
    if stage.root != None:
        mounted_roots.append(stage.root)
    for r in filesystem_roots:
        if r != None and r != "" and r != "." and r not in mounted_roots:
            mounted_roots.append(r)
    if not mounted_roots:
        fail("%s: no filesystem root to compile under: staging is empty and no filesystem_roots were given" % ctx.label)
    for root in mounted_roots:
        args.add("--filesystem-root", root)
    args.add("--filesystem-scheme", APP_SCHEME)

    if dart_plugin_registrant_uri:
        args.add("--source", dart_plugin_registrant_uri)
        args.add("--source", "package:flutter/src/dart_plugin_registrant.dart")
        args.add("-Dflutter.dart_plugin_registrant=" + dart_plugin_registrant_uri)

    args.add_all(extra_flags)

    if native_assets_manifest != None:
        args.add("--native-assets", native_assets_manifest.path)

    if recorded_uses != None:
        args.add("--recorded-uses", recorded_uses)

    if from_dill != None:
        args.add("--from-dill", from_dill.path)

    if import_dill != None:
        args.add("--import-dill=" + import_dill.path)

    if entrypoint_uri:
        args.add(entrypoint_uri)
    else:
        args.add(main)

    # Suppress Dart/Flutter analytics (avoids writes to $HOME/.dart/ in sandbox).
    # Provide a writable HOME scoped to this action's output directory.
    env = {"CI": "true", "FLUTTER_SUPPRESS_ANALYTICS": "true"}
    if dartaotruntime.basename.endswith(".exe"):
        env["USERPROFILE"] = output.dirname
        env["LOCALAPPDATA"] = output.dirname
    else:
        env["HOME"] = output.dirname

    if from_dill != None:
        direct_inputs = [main, package_config, frontend_server, platform_dill, from_dill] + stage.files
    else:
        direct_inputs = [main, package_config, frontend_server, platform_dill] + srcs + stage.files
    if native_assets_manifest != None:
        direct_inputs.append(native_assets_manifest)
    if import_dill != None:
        direct_inputs.append(import_dill)
    outputs = [output]
    if recorded_uses != None:
        outputs.append(recorded_uses)

    # The declared-inputs manifest `kernel_filter` guards and verifies the
    # compile against: the declared sources, then the staging root's symlinks
    # to them, then every other file the compiler may read (the package
    # config, the platform dill, the summary dills, the native-assets
    # manifest), the mounted filesystem roots the directive guard resolves
    # through, and the output dill the refusal path deletes (see
    # kernel_filter.dart). Every entry names a Starlark-declared `File` (or
    # an action-constructed root/output string): `kernel_filter` derives
    # nothing from the compile argv, so a flag smuggled into `vm_flags` or
    # `extra_flags` cannot widen what the compile may read. Written by path
    # so the tool reads the same files the compiler resolves through the
    # staging root.
    manifest = ctx.actions.declare_file(output.basename + ".flutter_inputs")
    allowed_reads = [package_config, platform_dill]
    if from_dill != None:
        allowed_reads.append(from_dill)
    if import_dill != None:
        allowed_reads.append(import_dill)
    if native_assets_manifest != None:
        allowed_reads.append(native_assets_manifest)
    ctx.actions.write(
        output = manifest,
        content = "\n".join(
            [f.path for f in compile_sources if f != None] +
            ["# staged"] +
            [f.path for f in stage.files] +
            ["# allowed-reads"] +
            [f.path for f in allowed_reads] +
            ["# filesystem-roots"] +
            mounted_roots +
            ["# output", output.path],
        ) + "\n",
    )

    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)

    # `resource_set` stays out of the call unless set, so callers that leave
    # it unset keep byte-identical actions (same argv and action key).
    run_kwargs = dict(
        executable = dart_exe,
        arguments = [kernel_filter_tool.path, "--declared-inputs", manifest.path, args],
        inputs = depset(
            direct = direct_inputs + [dartaotruntime, kernel_filter_tool, manifest],
            transitive = [dart_vm_files],
        ),
        outputs = outputs,
        mnemonic = "FlutterKernelCompile",
        progress_message = "Compiling Flutter kernel %s" % ctx.label,
        env = env,
    )
    if resource_set != None:
        run_kwargs["resource_set"] = resource_set
    ctx.actions.run(**run_kwargs)
