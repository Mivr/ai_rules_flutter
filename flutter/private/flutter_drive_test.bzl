"""`flutter_drive_test`: a host-run driver against an app on the Android emulator or iOS simulator.

The test launches a debug app on a device the way `flutter_integration_test`
does, runs `driver` on the host with the app's Dart VM service URI in its
environment, and exits with the driver's exit status. `app` is either an
Android app (as `flutter_android_app` builds it, run on the pinned headless
emulator) or an iOS simulator app (an `.ipa` as `ios_sim_debug_app` builds it,
run on a simulator booted or reused through `xcrun simctl`, macOS only).
`driver` may be either a `.dart` script (compiled here against `deps` with the
hermetic Dart exec toolchain) or a prebuilt executable target such as
`dart_binary`. Host Dart and driver packages come from the toolchain and the
pinned pub lock; no host Flutter or Dart is read. The Android runtime
(emulator, `adb`) is the one `flutter_integration_test` pins, and the iOS leg
uses the runner's Xcode, so this adds no download.
"""

load("@rules_android//providers:providers.bzl", "ApkInfo")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "STABLE_SCHEME",
    "collect_packages",
    "collect_transitive_resources",
    "collect_transitive_srcs",
    "dart_analyzable_info",
    "generate_stable_package_config",
    "runfiles_path",
    "stable_entry_path",
)
load("//flutter:providers.bzl", "resolve_exec_dart_vm")

visibility(["//flutter/..."])

# The emulator needs the host (`/dev/kvm`, and loopback ports shared with its
# adb server), so this test runs unsandboxed exactly as
# `flutter_integration_test(platform = "android")` does. Kept here rather than
# imported: that file loads `//flutter:android.bzl`, which loads this one.
_DRIVE_TEST_EXECUTION_REQUIREMENTS = {"no-sandbox": ""}

_EXEC_TOOLS_TOOLCHAIN = "@rules_dart//dart:exec_tools_toolchain_type"

def _drive_apk(ctx):
    """Resolves the signed APK produced by the Android `app` target.

    Args:
        ctx: The rule context under analysis.

    Returns:
        The signed `.apk` `File` of `ctx.attr.app`.
    """
    if not ctx.attr.package_name:
        fail("%s: attribute `package_name` is required." % ctx.label)
    apks = [
        f
        for f in ctx.attr.app[DefaultInfo].files.to_list()
        if f.path.endswith(".apk") and not f.path.endswith("_unsigned.apk")
    ]
    if not apks:
        fail("%s: attribute `app` (%s) produces no signed .apk; pass a `flutter_android_app` target." % (
            ctx.label,
            ctx.attr.app.label,
        ))
    return apks[0]

def _drive_ipa(ctx):
    """Resolves the simulator `.ipa` of an iOS `app` target, or `None`.

    Args:
        ctx: The rule context under analysis.

    Returns:
        The `.ipa` `File` of `ctx.attr.app`, or `None` when it has none.
    """
    ipas = [f for f in ctx.attr.app[DefaultInfo].files.to_list() if f.path.endswith(".ipa")]
    return ipas[0] if ipas else None

def _drive_device(ctx, workspace_name):
    """Picks the device kind of `app` and returns its launcher inputs.

    Args:
        ctx: The rule context under analysis.
        workspace_name: The workspace name used to form runfiles paths.

    Returns:
        A struct with `env` (launcher variables), `files` and `transitive`
        runfiles inputs.
    """
    if not ctx.attr.app:
        fail("%s: attribute `app` is required: pass a `flutter_android_app` or iOS simulator app target." % ctx.label)
    if ApkInfo in ctx.attr.app:
        apk = _drive_apk(ctx)
        return struct(
            env = {
                "FLUTTER_DRIVE_ANDROID_ADB": runfiles_path(ctx.file._android_adb, workspace_name),
                "FLUTTER_DRIVE_ANDROID_APK": runfiles_path(apk, workspace_name),
                "FLUTTER_DRIVE_ANDROID_EMULATOR": runfiles_path(ctx.file._android_emulator, workspace_name),
                "FLUTTER_DRIVE_ANDROID_PACKAGE": ctx.attr.package_name,
            },
            files = [apk, ctx.file._android_emulator, ctx.file._android_adb],
            transitive = ctx.files._android_runtime_all_files,
        )
    ipa = _drive_ipa(ctx)
    if ipa == None:
        fail((
            "%s: attribute `app` (%s) is neither an Android app (`flutter_android_app`) nor an " +
            "iOS simulator app (an `.ipa` from `ios_sim_debug_app`)."
        ) % (ctx.label, ctx.attr.app.label))
    bundle_id = ctx.attr.bundle_id or ctx.attr.package_name
    if not bundle_id:
        fail("%s: attribute `bundle_id` is required for an iOS simulator `app`." % ctx.label)
    return struct(
        env = {
            "FLUTTER_DRIVE_IOS_APP": runfiles_path(ipa, workspace_name),
            "FLUTTER_DRIVE_IOS_BUNDLE_ID": bundle_id,
        },
        files = [ipa],
        transitive = [],
    )

def _exec_kernel_tools(ctx):
    """Resolves the hermetic Dart VM and kernel compiler from the exec toolchain.

    Args:
        ctx: The rule context declaring `@rules_dart//dart:exec_tools_toolchain_type`.

    Returns:
        A struct holding `dart`, `runtime_files`, `compile_files`,
        `dartaotruntime`, `gen_kernel` and `platform_dill`.
    """
    dart_exe, runtime_files = resolve_exec_dart_vm(ctx)
    sdk = ctx.toolchains[_EXEC_TOOLS_TOOLCHAIN].dart_sdk_info
    dartaotruntime = None
    gen_kernel = None
    platform_dill = None
    for f in sdk.compile_files.to_list():
        if f.basename in ("dartaotruntime", "dartaotruntime.exe"):
            dartaotruntime = f
        elif f.basename == "gen_kernel_aot.dart.snapshot":
            gen_kernel = f
        elif f.basename == "vm_platform_strong.dill":
            platform_dill = f
    if not dartaotruntime or not gen_kernel or not platform_dill:
        fail("%s: Dart exec toolchain is missing kernel compiler files." % ctx.label)
    return struct(
        dart = dart_exe,
        runtime_files = runtime_files,
        compile_files = sdk.compile_files,
        dartaotruntime = dartaotruntime,
        gen_kernel = gen_kernel,
        platform_dill = platform_dill,
    )

def _compile_driver_dill(ctx, driver_src):
    """Compiles a `.dart` host driver script to a `.dill` kernel with the exec SDK.

    Args:
        ctx: The rule context under analysis.
        driver_src: The `.dart` entrypoint `File` passed to `driver`.

    Returns:
        A struct with `dill`, `dart`, `runtime_files` and `analyzable`.
    """
    tools = _exec_kernel_tools(ctx)
    packages = collect_packages(ctx.attr.deps)
    dep_srcs = collect_transitive_srcs(ctx.attr.deps)
    own_srcs = [driver_src] + ctx.files.srcs
    pkg_cfg = ctx.actions.declare_file(ctx.label.name + "_driver.package_config.json")
    ctx.actions.write(
        output = pkg_cfg,
        content = generate_stable_package_config(packages, own_srcs + dep_srcs.to_list()),
    )
    dill = ctx.actions.declare_file(ctx.label.name + "_driver.dill")
    args = ctx.actions.args()
    args.add(tools.gen_kernel)
    args.add("--platform", tools.platform_dill)
    args.add("--packages", pkg_cfg)
    args.add("--filesystem-scheme", STABLE_SCHEME)
    args.add("--filesystem-root", ".")
    args.add("--filesystem-root", ctx.bin_dir.path)
    args.add("-Ddart.vm.product=false")
    args.add_all(["-Ddart.vm.asan=false", "-Ddart.vm.msan=false", "-Ddart.vm.tsan=false"])
    args.add("-o", dill)
    args.add(STABLE_SCHEME + ":///" + stable_entry_path(ctx, driver_src.path))
    action_env = (
        {
            "LOCALAPPDATA": dill.dirname,
            "TEMP": dill.dirname,
            "TMP": dill.dirname,
            "USERPROFILE": dill.dirname,
        } if tools.dart.basename.endswith(".exe") else {"HOME": dill.dirname, "TMPDIR": dill.dirname}
    )
    ctx.actions.run(
        executable = tools.dartaotruntime,
        arguments = [args],
        inputs = depset(
            direct = own_srcs + [pkg_cfg, tools.dartaotruntime, tools.gen_kernel, tools.platform_dill],
            transitive = [dep_srcs, tools.compile_files],
        ),
        outputs = [dill],
        mnemonic = "FlutterDriveKernel",
        progress_message = "Compiling host driver %s" % ctx.label,
        env = action_env,
        toolchain = _EXEC_TOOLS_TOOLCHAIN,
    )
    return struct(
        dill = dill,
        dart = tools.dart,
        runtime_files = tools.runtime_files,
        analyzable = [dart_analyzable_info(deps = ctx.attr.deps, srcs = own_srcs)],
    )

def _resolve_driver(ctx, workspace_name):
    """Resolves `driver` as either a prebuilt executable or a compiled `.dart` script.

    Args:
        ctx: The rule context under analysis.
        workspace_name: The workspace name used to form runfiles paths.

    Returns:
        A struct with `env`, `files`, `transitive`, `runfiles` and `providers`.
    """
    if not ctx.attr.driver:
        fail("%s: attribute `driver` is required: pass a `.dart` script or a `dart_binary` target." % ctx.label)
    exe = ctx.attr.driver[DefaultInfo].files_to_run.executable
    if (
        len(ctx.files.driver) == 1 and
        ctx.files.driver[0].path.endswith(".dart") and
        (exe == None or exe.path.endswith(".dart"))
    ):
        driver_src = ctx.files.driver[0]
        compiled = _compile_driver_dill(ctx, driver_src)
        return struct(
            env = {
                "FLUTTER_DRIVE_DART": runfiles_path(compiled.dart, workspace_name),
                "FLUTTER_DRIVE_DRIVER": runfiles_path(compiled.dill, workspace_name),
            },
            files = [driver_src, compiled.dill, compiled.dart] + ctx.files.srcs,
            transitive = [compiled.runtime_files, collect_transitive_resources(ctx.attr.deps)],
            runfiles = [],
            providers = compiled.analyzable,
        )
    if exe != None and not exe.is_source:
        if ctx.attr.deps or ctx.files.srcs:
            fail(
                "%s: `deps` and `srcs` apply only when `driver` is a `.dart` file; declare them on %s." % (
                    ctx.label,
                    ctx.attr.driver.label,
                ),
            )
        return struct(
            env = {"FLUTTER_DRIVE_DRIVER": runfiles_path(exe, workspace_name)},
            files = [exe],
            transitive = [],
            runfiles = [ctx.attr.driver[DefaultInfo].default_runfiles],
            providers = [],
        )
    fail(
        "%s: attribute `driver` (%s) must be a single `.dart` script or an executable target." % (
            ctx.label,
            ctx.attr.driver.label,
        ),
    )

def _merged_test_env(ctx, base_env):
    """Merges caller `env` entries with `base_env`, rejecting reserved launcher keys.

    Args:
        ctx: The rule context under analysis.
        base_env: Dict of launcher environment variables set by the rule.

    Returns:
        A merged dict of environment variables for `testing.TestEnvironment`.
    """
    merged = {}
    for key, value in ctx.attr.env.items():
        if key in base_env or key == "VM_SERVICE_URL" or key.startswith("FLUTTER_DRIVE_"):
            fail("%s: `env` key `%s` is reserved by `flutter_drive_test`." % (ctx.label, key))
        merged[key] = ctx.expand_location(value, ctx.attr.data)
    merged.update(base_env)
    return merged

def _flutter_drive_test_impl(ctx):
    """Declares the launcher executable, compiles `.dart` drivers and wires runfiles.

    Args:
        ctx: The rule context under analysis.

    Returns:
        The list of providers for the test target.
    """
    workspace_name = ctx.workspace_name
    device = _drive_device(ctx, workspace_name)
    resolved = _resolve_driver(ctx, workspace_name)
    executable = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(
        output = executable,
        target_file = ctx.executable._tool,
        is_executable = True,
    )
    base_env = dict(device.env)
    base_env.update(resolved.env)
    runfiles = ctx.runfiles(
        files = device.files + resolved.files + ctx.files.data,
        transitive_files = depset(device.transitive, transitive = resolved.transitive),
    )
    extra_runfiles = [ctx.attr._tool[DefaultInfo].default_runfiles] + resolved.runfiles + [
        d[DefaultInfo].default_runfiles
        for d in ctx.attr.data
    ]
    runfiles = runfiles.merge_all(extra_runfiles)
    return [
        DefaultInfo(executable = executable, runfiles = runfiles),
        testing.TestEnvironment(_merged_test_env(ctx, base_env)),
        testing.ExecutionInfo(_DRIVE_TEST_EXECUTION_REQUIREMENTS),
    ] + resolved.providers

_flutter_drive_test = rule(
    implementation = _flutter_drive_test_impl,
    attrs = {
        "app": attr.label(
            doc = "Required app target under test: an Android app (as `flutter_android_app` builds in " +
                  "`-c dbg`) or an iOS simulator app (an `.ipa`, as `ios_sim_debug_app` builds); " +
                  "defaults to `None` and fails analysis when omitted or of neither kind.",
        ),
        "bundle_id": attr.string(
            doc = "Bundle identifier of an iOS simulator `app`; defaults to `package_name` when empty.",
        ),
        "data": attr.label_list(
            allow_files = True,
            doc = "Additional runtime files staged into the host driver's runfiles; defaults to `[]`.",
        ),
        "deps": attr.label_list(
            providers = [DartInfo],
            doc = "Dart library dependencies (from the pinned pub lock) when `driver` is a `.dart` " +
                  "script; defaults to `[]`.",
        ),
        "driver": attr.label(
            allow_files = True,
            cfg = "exec",
            doc = "Required host driver: a `.dart` script or an executable target (`dart_binary`) that " +
                  "reads `VM_SERVICE_URL`; defaults to `None` and fails analysis when omitted.",
        ),
        "env": attr.string_dict(
            doc = "Extra environment variables passed to the test (`$(rlocationpath ...)` expanded over " +
                  "`data`); defaults to `{}`.",
        ),
        "package_name": attr.string(
            doc = "Android application ID of `app` (for example `com.example.myapp`), required for an " +
                  "Android app; defaults to `\"\"`.",
        ),
        "srcs": attr.label_list(
            allow_files = [".dart"],
            doc = "Extra `.dart` helper sources imported by a `.dart` script `driver`; defaults to `[]`.",
        ),
        "_tool": attr.label(
            default = Label("//flutter/private/tools:flutter_drive_runner"),
            executable = True,
            cfg = "exec",
            doc = "Default launcher binary (`//flutter/private/tools:flutter_drive_runner`) that boots " +
                  "the emulator or simulator, starts the app and runs the driver.",
        ),
        "_android_emulator": attr.label(
            default = Label("@flutter_android_headless_runtime//:sdk/emulator/emulator"),
            allow_single_file = True,
            doc = "Pinned Android `emulator` binary; defaults to the headless Android runtime label.",
        ),
        "_android_adb": attr.label(
            default = Label("@flutter_android_headless_runtime//:sdk/platform-tools/adb"),
            allow_single_file = True,
            doc = "Pinned `adb` binary; defaults to the headless Android runtime `adb` label.",
        ),
        "_android_runtime_all_files": attr.label(
            default = Label("@flutter_android_headless_runtime//:all_files"),
            doc = "All files of the pinned headless Android runtime; defaults to `:all_files`.",
        ),
    },
    toolchains = [_EXEC_TOOLS_TOOLCHAIN],
    test = True,
    doc = "Runs a host Dart driver against a debug app on the Android emulator or the iOS simulator.",
)

def flutter_drive_test(
        name,
        app = None,
        driver = None,
        package_name = "",
        deps = [],
        size = None,
        tags = [],
        platform = "android",
        **kwargs):
    """Runs a host-side Dart driver against an app launched on the Android emulator or iOS simulator.

    Launches `app` on the pinned headless Android emulator (as
    `flutter_integration_test(platform = "android")` does) or on an iOS
    simulator (as `platform = "ios"` does), runs `driver` on the host with the
    VM service URI in `VM_SERVICE_URL`, and passes or fails with the driver's
    exit status. The target is tagged `manual`, so it stays out of the default
    test set. With `platform = "ios"` it is `enormous`, `exclusive` (the
    simulator is shared) and compatible with macOS only; otherwise it is `large`.

    Args:
        name: Unique name for this test target.
        app: The Android app (`flutter_android_app`) or the iOS simulator app
            (`ios_sim_debug_app`), built in debug mode (`-c dbg`).
        driver: Host Dart driver — a `.dart` script (compiled with `deps`) or a `dart_binary`.
        package_name: The Android application ID of `app` (for example `com.example.app`);
            for an iOS app it is the bundle id unless `bundle_id` is given.
        deps: Dart package dependencies from the pinned pub lock when `driver` is a `.dart` file.
        size: Test size; `large` for Android and `enormous` for iOS by default.
        tags: Extra Bazel tags; `manual` is always added so wildcard runs skip it.
        platform: `"android"` (default) or `"ios"`; `"ios"` makes the target macOS-only and `exclusive`.
        **kwargs: Additional test attributes (`srcs`, `data`, `env`, `bundle_id`, `timeout`, `visibility`, ...).
    """
    if platform not in ("android", "ios"):
        fail("flutter_drive_test %s: `platform` must be \"android\" or \"ios\", got %r." % (name, platform))
    ios = platform == "ios"
    all_tags = tags + [t for t in (["manual", "exclusive"] if ios else ["manual"]) if t not in tags]
    if ios:
        kwargs["target_compatible_with"] = kwargs.get("target_compatible_with", []) + ["@platforms//os:macos"]
    _flutter_drive_test(
        name = name,
        app = app,
        driver = driver,
        package_name = package_name,
        deps = deps,
        size = size or ("enormous" if ios else "large"),
        tags = all_tags,
        **kwargs
    )
