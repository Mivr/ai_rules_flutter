"""Flutter integration test rule.

Compiles a Flutter application together with an in-app integration test
entrypoint (`package:integration_test` / `package:flutter_test` `WidgetTester`
code) for the target platform and runs it end-to-end under a platform runner.

For `platform = "web"`:
  1. Generates `<name>_bootstrap.dart` which initializes the live integration
     test binding (`IntegrationTestWidgetsFlutterBinding` when
     `package:integration_test` is in `deps`, or a built-in
     `LiveTestWidgetsFlutterBinding` subclass otherwise), connects back to the
     host runner over a WebSocket (`/__flutter_integration_ws__`), and drives
     the suite via `package:test_api/backend.dart` `RemoteListener`.
  2. Wraps `<name>_bootstrap.dart` in the standard Flutter web engine bootstrap
     (`ui_web.bootstrapEngine`) and compiles the whole app + test to JS/WASM
     with local CanvasKit/Skwasm and bundled `flutter_assets/`.
  3. Runs `flutter_integration_test_runner`, which serves the built web bundle
     over `http://127.0.0.1:<ephemeral>`, launches the hermetic pinned
     `chrome-headless-shell` binary with its pinned shared-library closure, and
     collects test results and any uncaught errors.

For `platform = "linux"`:
  1. Generates `<name>_linux_bootstrap.dart` which initializes the live
     integration test binding, connects back to the host runner over the
     WebSocket URL in `FLUTTER_INTEGRATION_TEST_HARNESS_URL`, and drives the
     suite via `RemoteListener`.
  2. Compiles the app + test to a kernel `.dill` (and in non-debug modes AOT
     `libapp.so`), compiles the C++ GTK runner + native C++ plugin registrant +
     Linux plugin C++ sources against the hermetic Chromium sysroot, and
     assembles the `<name>_linux` desktop bundle directory.
  3. Runs `flutter_integration_test_runner`, which starts the hermetic pinned
     `Xvfb` virtual display (`-displayfd`), launches the compiled Linux desktop
     application against that display and the pinned GTK3/Mesa/EGL/GLib runtime
     shared-library closure, and collects test results and any uncaught errors.

For `platform = "android"`:
  1. Generates `<name>_android_bootstrap.dart` which initializes the live
     integration test binding, connects back to the host runner over a localhost
     WebSocket forwarded into the emulator via `adb reverse`, and drives the
     suite via `RemoteListener`.
  2. Compiles the app + test to a kernel `.dill` (and in non-debug modes AOT
     `libapp.so`) for `android_x64`, generates `GeneratedPluginRegistrant.java`,
     compiles transitive Android plugin libraries, and packages a real signed
     Android APK via `android_binary`.
  3. Runs `flutter_integration_test_runner`, which boots the hermetic pinned
     Android emulator (`x86_64` API 35 `aosp_atd`) headless with KVM and
     SwiftShader, sets up `adb reverse`, installs and launches the APK, monitors
     for crashes/ANRs, and collects test results and any uncaught errors.
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_android//android:rules.bzl", "android_binary")
load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "MODULAR_KERNEL_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "derive_lib_root",
    "runfiles_path",
)
load("@rules_java//java:java_import.bzl", "java_import")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")
load(
    "//flutter:android.bzl",
    "ANDROID_MIN_SDK_VERSION",
    "ANDROID_TARGET_SDK_VERSION",
    "flutter_android_bundle",
    "flutter_android_engine",
    "flutter_android_manifest_merge",
)
load("//flutter:providers.bzl", "FlutterApplicationInfo", "FlutterInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_location",
    "app_scheme_location",
    "app_scheme_rel_path",
    "compile_kernel_package_config",
    "resolve_wrapper_main_import",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "FLUTTER_APPLICATION_ATTRS",
    "FLUTTER_DEPS_DOC",
    "KERNEL_COMPILE_ATTRS",
    "LIBRARY_TAGS_TOOL_ATTR",
    "PLATFORM_CONSTRAINT_ATTRS",
    "check_unreplaced_hooks",
    "collect_native_libs",
    "compute_desktop_bundle_copies",
    "declare_flutter_assets_dir",
    "extract_library_tags_action",
    "flutter_app_shader_aspect",
    "flutter_build_assets",
    "flutter_build_mode",
    "flutter_compile_shaders",
    "flutter_web_shader_aspect",
    "host_target_arch",
    "make_bundle_inputs",
    "make_desktop_bundle_artifacts",
    "make_desktop_bundle_libs",
    "make_web_wrapper_main_content",
    "merge_dart_defines",
    "resolve_exec_dart_vm",
    "resolve_flutter_sdk_info",
)
load(
    "//flutter/private:flutter_android_registrant.bzl",
    "flutter_android_plugins_aggregator",
    "flutter_android_registrant",
)
load("//flutter/private:flutter_aot_compile.bzl", "flutter_aot_elf_action")
load(
    "//flutter/private:flutter_compile.bzl",
    "flutter_kernel_compile_action",
    "flutter_kernel_dills",
    "flutter_kernel_options",
    "flutter_kernel_outputs",
    "flutter_kernel_sources",
)
load(
    "//flutter/private:flutter_info.bzl",
    "collect_flutter_plugin_deps",
)
load(
    "//flutter/private:flutter_integration_android_app.bzl",
    "ANDROID_APP_KWARG_KEYS",
    "make_android_integration_manifest_lines",
    "sanitize_android_package_segment",
)
load(
    "//flutter/private:flutter_integration_test_ios.bzl",
    "RESERVED_TAG_ENV_KEYS",
    "assemble_ios_integration_test",
    "build_analyzable_and_coverage_infos",
    "exposes_package",
    "ios_integration_bootstrap_substitutions",
    "resolve_main_and_srcs",
    "test_tag_env",
)
load(
    "//flutter/private:flutter_integration_web_bundle.bzl",
    "BOOTSTRAP_JS_TEMPLATE",
    "INDEX_HTML_TEMPLATE",
    "JS_BUILD",
    "MANIFEST_JSON_TEMPLATE",
    "VERSION_JSON_TEMPLATE",
    "build_config_js",
    "wasm_build",
)
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "MODULAR_KERNEL_ATTRS",
    "flutter_kernel_module_aspect",
)
load(
    "//flutter/private:flutter_linux_application.bzl",
    "compile_linux_runner",
    "linux_plugin_inputs",
    "linux_registrant_inputs",
    "linux_runner_defines",
    "linux_runner_inputs",
)
load(
    "//flutter/private:flutter_native_assets.bzl",
    "collect_application_native_assets",
    "collect_bundled_code_asset_files",
    "write_native_assets_manifest",
)
load(
    "//flutter/private:flutter_web_compile.bzl",
    "flutter_dart2js_action",
    "flutter_dart2wasm_action",
    "make_dart2js_request",
    "make_dart2wasm_request",
    "web_build_mode",
    "web_compile_tool_inputs",
    "web_sdk_files_for_dart2js",
)
load(
    "//flutter/private:integration_test_bootstrap_snippets.bzl",
    "LINUX_HARNESS_URL_PROLOGUE",
    "integration_test_binding_substitutions",
)
load("//flutter/private:native_sources.bzl", "native_sources_aspect")
load(
    "//flutter/private:plugin_registrant.bzl",
    "generate_dart_plugin_registrant",
    "generate_native_plugin_registrant",
    "generate_native_plugin_registrant_header",
)
load(
    "//flutter/private:validation.bzl",
    "escape_html",
    "validate_web_compiler_renderer",
    "web_renderer",
)

def make_web_integration_bootstrap_content(test_import, has_integration_test = False):
    """Build the substitutions for the web integration test bootstrap template.

    The program is `web_bootstrap.dart.tpl`, expanded per target by the rule
    with `ctx.actions.expand_template`. `make_web_wrapper_main_content` wraps
    the result so `ui_web.bootstrapEngine` initializes the Flutter web engine
    and implicit view before calling its `main()`. The bootstrap dials the
    harness back over a WebSocket carrying the run's token (from the page URL
    the launcher opens), so the harness adopts only this run's app.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        A `{placeholder: replacement}` dict for `ctx.actions.expand_template`.
    """
    return _bootstrap_substitutions(test_import, has_integration_test)

def make_linux_integration_bootstrap_content(test_import, has_integration_test = False):
    """Build the substitutions for the Linux desktop bootstrap template.

    The program is `linux_bootstrap.dart.tpl`. It initializes the live
    integration test binding (`IntegrationTestWidgetsFlutterBinding` when
    `package:integration_test` is in `deps`, or a built-in
    `LiveTestWidgetsFlutterBinding` subclass otherwise), connects to the host
    runner over the WebSocket URL in `FLUTTER_INTEGRATION_TEST_HARNESS_URL`,
    forwards uncaught errors, and drives the suite via `RemoteListener`.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        A `{placeholder: replacement}` dict for `ctx.actions.expand_template`.
    """
    return _bootstrap_substitutions(
        test_import,
        has_integration_test,
        harness_url_prologue = LINUX_HARNESS_URL_PROLOGUE,
    )

def make_android_integration_bootstrap_content(test_import, has_integration_test = False):
    """Build the substitutions for the Android bootstrap template.

    The program is `android_bootstrap.dart.tpl`. It initializes the live
    integration test binding (`IntegrationTestWidgetsFlutterBinding` when
    `package:integration_test` is in `deps`, or a built-in
    `LiveTestWidgetsFlutterBinding` subclass otherwise), connects to the host
    runner over a localhost WebSocket forwarded via `adb reverse` (accepting
    the harness URL via `dart_entrypoint_args`,
    `FLUTTER_INTEGRATION_TEST_HARNESS_URL`, or the default
    `ws://127.0.0.1:38427/__flutter_integration_ws__`), forwards uncaught
    errors, and drives the suite via `RemoteListener`.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        A `{placeholder: replacement}` dict for `ctx.actions.expand_template`.
    """
    return _bootstrap_substitutions(test_import, has_integration_test)

def _bootstrap_substitutions(test_import, has_integration_test, harness_url_prologue = None):
    """The template substitutions the platform bootstrap generators share.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.
        harness_url_prologue: The URL prologue the template substitutes, or
            `None` for a template that resolves the harness URL itself.

    Returns:
        A `{placeholder: replacement}` dict for `ctx.actions.expand_template`.
    """
    binding = integration_test_binding_substitutions(has_integration_test)
    substitutions = {
        "{binding_import}": binding.import_stmt,
        "{binding_decl}": binding.decl,
        "{binding_init}": binding.init,
        "{test_import}": test_import,
    }
    if harness_url_prologue != None:
        substitutions["{harness_url_prologue}"] = harness_url_prologue
    return substitutions

def _web_sdk_file_list(ctx):
    """All files the web SDK target carries (renderer/template lookup)."""
    return ctx.attr._web_sdk.files.to_list() if ctx.attr._web_sdk else []

def _integration_test_common_setup(ctx):
    """The checks and build-mode inputs the dart:io test rules share.

    Args:
        ctx: Rule context.

    Returns:
        A struct with `aot`, `extra_srcs`, `is_debug`, `lib_root`, `main_file`,
        `mode`, `package_name`, `sdk` and `strip`.
    """
    if not exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    hook_err = check_unreplaced_hooks(ctx.label, ctx.attr.deps)
    if hook_err != None:
        fail(hook_err)

    main_file, extra_srcs = resolve_main_and_srcs(ctx)

    mode = "profile" if ctx.attr.profile else flutter_build_mode(ctx)
    is_debug = mode == "debug"
    return struct(
        aot = not is_debug,
        extra_srcs = extra_srcs,
        is_debug = is_debug,
        lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package),
        main_file = main_file,
        mode = mode,
        package_name = ctx.attr.package_name or ctx.label.name,
        sdk = resolve_flutter_sdk_info(ctx),
        strip = ctx.var["COMPILATION_MODE"] == "opt",
    )

def _integration_test_dart_sources(ctx, setup, platform, content):
    """Generates the bootstrap and registrant, and computes the package config.

    Args:
        ctx: Rule context.
        setup: An `_integration_test_common_setup` struct.
        platform: The registrant's target platform (`linux` or `android`).
        content: The bootstrap `{placeholder: replacement}` dict.

    Returns:
        A struct with `bootstrap`, `bootstrap_location`, `package_config`,
        `plugins`, `registrant` and `registrant_location`.
    """
    packages = collect_packages(ctx.attr.deps)
    packages = synthesize_app_package(
        ctx.label,
        packages,
        setup.package_name,
        setup.lib_root,
        ctx.attr.language_version,
    )

    bootstrap = ctx.actions.declare_file(ctx.label.name + "_" + platform + "_bootstrap.dart")
    ctx.actions.expand_template(
        template = ctx.file._bootstrap_template,
        output = bootstrap,
        substitutions = content,
    )

    plugins = _integration_test_plugins(ctx)
    registrant = generate_dart_plugin_registrant(
        ctx,
        plugins.all_plugins,
        target_platform = platform,
    )
    registrant_location = app_scheme_location(registrant) if registrant else None
    bootstrap_location = app_scheme_location(bootstrap)

    all_srcs = (
        list(setup.extra_srcs) +
        collect_transitive_srcs(ctx.attr.deps).to_list() +
        [setup.main_file, bootstrap] +
        ([registrant] if registrant else [])
    )
    pc = compile_kernel_package_config(
        ctx,
        packages,
        all_srcs,
        roots = {setup.package_name: True} if setup.package_name else None,
    )
    return struct(
        bootstrap = bootstrap,
        bootstrap_location = bootstrap_location,
        package_config = pc,
        plugins = plugins,
        registrant = registrant,
        registrant_location = registrant_location,
    )

def _integration_test_plugins(ctx):
    """Collects the plugin sets `deps` propagate for the registrant generators.

    Args:
        ctx: Rule context carrying `deps`.

    Returns:
        The `collect_flutter_plugin_deps` struct.
    """
    return collect_flutter_plugin_deps(ctx.attr.deps)

def _integration_test_native_assets(ctx, flutter_sdk_info, target_os):
    """Collects the native assets and writes the compiler's manifest.

    Args:
        ctx: Rule context.
        flutter_sdk_info: The resolved Flutter SDK info.
        target_os: The target OS the manifest is keyed by.

    Returns:
        A struct with `list`, `data_assets`, `manifest` and `bundled`.
    """
    assets = collect_application_native_assets(ctx)
    target_arch = host_target_arch(ctx, flutter_sdk_info)
    native_assets_manifest = ctx.actions.declare_file(ctx.label.name + ".native_assets.json")
    write_native_assets_manifest(
        ctx = ctx,
        output_file = native_assets_manifest,
        native_assets = assets.list,
        target_os = target_os,
        target_arch = target_arch,
    )
    return struct(
        bundled = collect_bundled_code_asset_files(assets.list),
        data_assets = assets.data_assets,
        list = assets.list,
        manifest = native_assets_manifest,
    )

def _integration_test_runner_executable(ctx):
    """Declares the runner symlink the test rule exposes as its executable.

    Args:
        ctx: Rule context carrying `_tool` and `_windows_constraint`.

    Returns:
        The declared executable File.
    """
    tool = ctx.attr._tool
    is_windows = ctx.target_platform_has_constraint(
        ctx.attr._windows_constraint[platform_common.ConstraintValueInfo],
    )
    ext = ".exe" if is_windows else ""
    executable = ctx.actions.declare_file(ctx.label.name + ext)
    ctx.actions.symlink(
        output = executable,
        target_file = tool[DefaultInfo].files_to_run.executable,
        is_executable = True,
    )
    return executable

def _integration_test_env(ctx, env, main_file):
    """Completes a platform env dict with the caller's overrides and tags.

    Args:
        ctx: Rule context carrying `env`, `include_tags` and `exclude_tags`.
        env: The platform env dict to complete.
        main_file: The entrypoint whose `@Tags` the runner receives.

    Returns:
        The `library_tags` File the runner reads.
    """
    workspace_name = ctx.workspace_name
    test_tag_env(ctx, env)

    # The entrypoint's own `@Tags`, extracted at build time (see
    # `extract_library_tags_action`): the runner injects them as the root
    # group's metadata, so they inherit down to every test in the suite.
    library_tags = extract_library_tags_action(ctx, main_file)
    env["FLUTTER_TEST_LIBRARY_TAGS"] = runfiles_path(library_tags, workspace_name)
    for key, value in ctx.attr.env.items():
        if key in env or key in RESERVED_TAG_ENV_KEYS:
            fail((
                "flutter_integration_test {name}: env key {key} is set by the " +
                "rule itself and cannot be overridden."
            ).format(name = ctx.label.name, key = key))
        env[key] = value
    return library_tags

def _integration_test_runfiles(ctx, runtime_files):
    """The runner's runfiles: its inputs, the caller's data and the tool's own.

    Args:
        ctx: Rule context carrying `data` and `_tool`.
        runtime_files: The platform files the runner reads.

    Returns:
        The merged runfiles.
    """
    tool = ctx.attr._tool
    runfiles = ctx.runfiles(
        files = runtime_files + ctx.files.data,
    )
    runfiles = runfiles.merge(tool[DefaultInfo].default_runfiles)
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)
    return runfiles

def _integration_test_providers(ctx, sources, run):
    """The providers every platform test rule returns.

    Args:
        ctx: Rule context.
        sources: struct with `package_name`, `lib_root`, `main_file`, `extra_srcs`.
        run: struct with `executable`, `env` and `runtime_files`.

    Returns:
        The provider list.
    """
    runfiles = _integration_test_runfiles(ctx, run.runtime_files)
    instrumented_files_info, analyzable_info = build_analyzable_and_coverage_infos(
        ctx,
        sources.package_name,
        sources.lib_root,
        sources.main_file,
        sources.extra_srcs,
    )
    return [
        DefaultInfo(
            executable = run.executable,
            runfiles = runfiles,
        ),
        testing.TestEnvironment(run.env),
        instrumented_files_info,
        analyzable_info,
    ]

def _integration_test_platform_dill(flutter_sdk_info, aot, mode):
    """The platform kernel dill the kernel compile reads.

    Args:
        flutter_sdk_info: The resolved Flutter SDK info.
        aot: Whether the build is AOT (non-debug).
        mode: The build mode.

    Returns:
        The platform `.dill` File.
    """
    if aot and mode == "release":
        platform_dill = flutter_sdk_info.platform_kernel_dill_product
        if platform_dill == None:
            fail(
                "Unresolved @rules_flutter//flutter:product_tools_toolchain_type " +
                "(@rules_flutter//flutter/private:product_tools_toolchain_type): " +
                "Flutter toolchain does not provide platform_kernel_dill_product, " +
                "which is required for release AOT kernel compilation. Register " +
                "the Flutter toolchains (e.g. `flutter.toolchain()` in MODULE.bazel " +
                "or `register_toolchains(\"@flutter_toolchains//:all\")`) or set " +
                "`platform_kernel_dill_product` on `flutter_toolchain`.",
            )
        return platform_dill
    platform_dill = flutter_sdk_info.platform_kernel_dill
    if platform_dill == None:
        fail(
            "Unresolved @rules_flutter//flutter:toolchain_type: " +
            "Flutter toolchain does not provide platform_kernel_dill. " +
            "Register a Flutter toolchain (e.g. `flutter.toolchain()` in " +
            "MODULE.bazel) or set `platform_kernel_dill` on `flutter_toolchain`.",
        )
    return platform_dill

def _integration_test_kernel_flags(ctx, mode, aot):
    """The defines and frontend flags the kernel compile passes.

    Args:
        ctx: Rule context carrying `track_widget_creation`.
        mode: The build mode.
        aot: Whether the build is AOT (non-debug).

    Returns:
        A struct with `defines` and `frontend_flags`.
    """
    all_defines = list(merge_dart_defines(ctx))
    if mode == "profile":
        all_defines.append("dart.vm.profile=true")
    elif aot:
        all_defines.append("dart.vm.product=true")
    frontend_flags = []
    if ctx.attr.track_widget_creation:
        frontend_flags.append("--track-widget-creation")
    return struct(
        defines = all_defines,
        frontend_flags = frontend_flags,
    )

def _integration_test_kernel(ctx, flutter_sdk_info, sources, native_assets, aot, mode):
    """Runs the kernel compile the dart:io test rules share.

    Args:
        ctx: Rule context.
        flutter_sdk_info: The resolved Flutter SDK info.
        sources: struct with `bootstrap`, `bootstrap_location`,
            `package_config` and `registrant_location`.
        native_assets: The `_integration_test_native_assets` struct.
        aot: Whether the build is AOT (non-debug).
        mode: The build mode.

    Returns:
        The compiled kernel `.dill` File.
    """
    platform_dill = _integration_test_platform_dill(flutter_sdk_info, aot, mode)
    flags = _integration_test_kernel_flags(ctx, mode, aot)
    kernel_dill = ctx.actions.declare_file(ctx.label.name + ".dill")
    flutter_kernel_compile_action(
        ctx,
        struct(
            dartaotruntime = flutter_sdk_info.dartaotruntime,
            kernel_filter_tool = ctx.executable._kernel_filter_tool,
            frontend_server = flutter_sdk_info.frontend_server,
            platform_dill = platform_dill,
        ),
        flutter_kernel_sources(
            main = sources.bootstrap,
            entrypoint_uri = sources.bootstrap_location.uri,
            srcs = sources.package_config.srcs,
            package_config = sources.package_config.config_file,
            native_assets_manifest = native_assets.manifest,
            dart_plugin_registrant_uri = sources.registrant_location.uri if sources.registrant_location else None,
        ),
        flutter_kernel_outputs(output = kernel_dill),
        flutter_kernel_options(
            aot = aot,
            defines = flags.defines,
            target = "flutter",
            extra_flags = flags.frontend_flags,
        ),
        flutter_kernel_dills(),
    )
    return kernel_dill

def _integration_test_aot(ctx, flutter_sdk_info, kernel_dill, is_debug, strip):
    """AOT-compiles the kernel in ELF form when the build is not debug.

    Args:
        ctx: Rule context.
        flutter_sdk_info: The resolved Flutter SDK info.
        kernel_dill: The compiled kernel File.
        is_debug: Whether the build is debug.
        strip: Whether to strip the AOT output.

    Returns:
        The AOT `.so` File, or None in debug mode.
    """
    if is_debug:
        return None
    aot_output = ctx.actions.declare_file(ctx.label.name + ".so")
    flutter_aot_elf_action(
        ctx = ctx,
        gen_snapshot = flutter_sdk_info.gen_snapshot,
        kernel_dill = kernel_dill,
        output = aot_output,
        strip = strip,
    )
    return aot_output

def _integration_test_assets(ctx, flutter_sdk_info, target_platform, kernel_dill, is_debug, data_assets):
    """Compiles shaders and builds the `flutter_assets/` tree.

    Args:
        ctx: Rule context.
        flutter_sdk_info: The resolved Flutter SDK info.
        target_platform: The bundle's platform.
        kernel_dill: The compiled kernel File, or None for web.
        is_debug: Whether the build is debug.
        data_assets: The transitive data-asset depset, or None.

    Returns:
        The declared `flutter_assets` directory.
    """
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, target_platform)
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_build_assets(
        ctx = ctx,
        flutter_sdk_info = flutter_sdk_info,
        output_dir = flutter_assets,
        bundle = make_bundle_inputs(
            target_platform = target_platform,
            compiled_shaders = compiled_shaders,
            kernel_dill = kernel_dill,
            is_debug = is_debug,
            data_assets = data_assets,
        ),
    )
    return flutter_assets

def _integration_test_native_libs(ctx, bundled_code_assets = None):
    """The loose native libraries a desktop or Android bundle carries.

    Args:
        ctx: Rule context carrying `native_deps` and `deps`.
        bundled_code_assets: The code-asset File list to add, or None.

    Returns:
        The native library File list.
    """
    native_libs = collect_native_libs(ctx.attr.native_deps)
    transitive_native_depsets = [
        dep[FlutterInfo].transitive_native_libs
        for dep in ctx.attr.deps
        if FlutterInfo in dep
    ]
    if transitive_native_depsets:
        native_libs.extend(depset(transitive = transitive_native_depsets).to_list())
    if bundled_code_assets != None:
        native_libs.extend(bundled_code_assets.to_list())
    return native_libs

def _web_integration_test_setup(ctx):
    """Validates a web target and resolves its compile inputs.

    Args:
        ctx: Rule context.

    Returns:
        A struct with `main_file`, `extra_srcs`, `renderer`, `sdk`,
        `user_defines`, `mode`, `is_debug`, `package_name`, `lib_root`,
        `srcs` and `package_config`.
    """
    if ctx.attr.platform != "web":
        fail(
            "%s: flutter_integration_test does not yet support platform = %r " % (
                ctx.label,
                ctx.attr.platform,
            ) + "(supported: \"web\", \"linux\", \"android\").",
        )

    if not exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, extra_srcs = resolve_main_and_srcs(ctx)

    renderer = web_renderer(ctx.attr.compiler, ctx.attr.renderer)
    validate_web_compiler_renderer(ctx.attr.compiler, renderer)

    flutter_sdk_info = resolve_flutter_sdk_info(ctx)
    user_defines = merge_dart_defines(ctx)
    mode = web_build_mode(ctx)

    package_name = ctx.attr.package_name or ctx.label.name
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)

    # Collect sources and synthesize the package config.
    all_srcs = list(extra_srcs) + collect_transitive_srcs(ctx.attr.deps).to_list()
    packages = collect_packages(ctx.attr.deps)
    packages = synthesize_app_package(
        ctx.label,
        packages,
        package_name,
        lib_root,
        ctx.attr.language_version,
    )

    pc = compile_kernel_package_config(
        ctx,
        packages,
        all_srcs + [main_file],
        roots = {package_name: True} if package_name else None,
    )
    return struct(
        extra_srcs = extra_srcs,
        is_debug = mode == "debug",
        lib_root = lib_root,
        main_file = main_file,
        mode = mode,
        package_config = pc.config_file,
        package_name = package_name,
        renderer = renderer,
        sdk = flutter_sdk_info,
        srcs = pc.srcs,
        user_defines = user_defines,
    )

def _web_integration_test_bootstrap(ctx, setup):
    """Generates the bootstrap, its engine wrapper and the plugin registrant.

    Args:
        ctx: Rule context.
        setup: The `_web_integration_test_setup` struct.

    Returns:
        A struct with `entrypoint` (the wrapper) and `srcs` (the compile set).
    """
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    bootstrap_rel = app_scheme_rel_path(bootstrap)
    bootstrap_depth = len(bootstrap_rel.split("/")) - 1
    test_import = resolve_wrapper_main_import(
        setup.package_name,
        setup.lib_root,
        setup.main_file.short_path,
        app_scheme_rel_path(setup.main_file),
        bootstrap_depth,
    )
    has_integration_test = exposes_package(ctx.attr.deps, ["integration_test"])
    ctx.actions.expand_template(
        template = ctx.file._bootstrap_template,
        output = bootstrap,
        substitutions = make_web_integration_bootstrap_content(
            test_import = test_import,
            has_integration_test = has_integration_test,
        ),
    )

    # Wrap `<name>_bootstrap.dart` with `ui_web.bootstrapEngine()` so the
    # Flutter web engine creates its implicit view before running the test.
    plugins = _integration_test_plugins(ctx).all_plugins
    registrant = generate_dart_plugin_registrant(ctx, plugins, target_platform = "web")

    wrapper = ctx.actions.declare_file(ctx.label.name + "_wrapper_main.dart")
    wrapper_content = make_web_wrapper_main_content(
        bootstrap.basename,
        registrant.basename if registrant else None,
    )
    ctx.actions.write(wrapper, wrapper_content)
    extra_wrapper_srcs = [setup.main_file, bootstrap, wrapper]
    if registrant:
        extra_wrapper_srcs.append(registrant)
    return struct(
        entrypoint = wrapper,
        srcs = setup.srcs + extra_wrapper_srcs,
    )

def _web_integration_test_compile(ctx, setup, entrypoint):
    """Compiles the wrapped test for dart2wasm or dart2js.

    Args:
        ctx: Rule context.
        setup: The `_web_integration_test_setup` struct.
        entrypoint: The `_web_integration_test_bootstrap` struct.

    Returns:
        A struct with `outputs`, `copies`, `dart2js_dirs` and `builds`.
    """
    compile = struct(
        dart = setup.sdk.dart,
        flutter_sdk_info = setup.sdk,
        dart2wasm_platform_dill = ctx.file._dart2wasm_platform_dill,
        dart2js_platform_dill = ctx.file._dart2js_platform_dill,
        web_sdk_files = web_sdk_files_for_dart2js(ctx.attr._web_sdk),
        main_dart = entrypoint.entrypoint,
        srcs = entrypoint.srcs,
        package_config = setup.package_config,
        mode = setup.mode,
        defines = setup.user_defines,
        renderer = setup.renderer,
        stage_salt = "",
        web_compile_tool = ctx.executable._web_template_tool,
        web_compile_inputs = web_compile_tool_inputs(setup.sdk.dart_vm_files),
        web_guard_tool = ctx.executable._web_guard_tool,
        enable_experiments = ctx.attr.enable_experiments,
    )
    compile_outputs = []
    compile_copies = []
    dart2js_dirs = []
    if ctx.attr.compiler == "dart2wasm":
        output_wasm = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm")
        output_mjs = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.mjs")
        output_wasm_map = None
        if ctx.attr.source_maps:
            output_wasm_map = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm.map")
        flutter_dart2wasm_action(ctx, make_dart2wasm_request(
            compile,
            struct(
                optimization_level = ctx.attr.optimization_level_wasm,
                minify = ctx.attr.minify_wasm,
                strip_wasm = ctx.attr.strip_wasm,
            ),
            output_wasm,
            output_mjs,
            output_wasm_map,
        ))
        compile_outputs = [output_wasm, output_mjs]
        compile_copies = [
            {"src": output_wasm.path, "dst": "main.dart.wasm"},
            {"src": output_mjs.path, "dst": "main.dart.mjs"},
        ]
        if output_wasm_map != None:
            compile_outputs.append(output_wasm_map)
            compile_copies.append({"src": output_wasm_map.path, "dst": "main.dart.wasm.map"})
        builds = [wasm_build(setup.renderer)]
    else:
        output_js_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js")
        flutter_dart2js_action(ctx, make_dart2js_request(
            compile,
            struct(
                optimization_level = ctx.attr.optimization_level_js,
                minify = ctx.attr.minify_js,
                native_null_assertions = ctx.attr.native_null_assertions,
                frequency_based_minification = ctx.attr.frequency_based_minification,
                dump_info = False,
                source_maps = ctx.attr.source_maps,
            ),
            setup.renderer,
            output_js_dir,
        ))
        dart2js_dirs = [output_js_dir]
        builds = [JS_BUILD]
    return struct(
        builds = builds,
        copies = compile_copies,
        dart2js_dirs = dart2js_dirs,
        outputs = compile_outputs,
    )

def _web_integration_test_template_files(ctx, setup):
    """Writes the four web template inputs the substitution tool reads.

    Args:
        ctx: Rule context.
        setup: The `_web_integration_test_setup` struct.

    Returns:
        A struct with `index_template`, `bootstrap_template`, `manifest_json`
        and `version_json`.
    """
    safe_title = escape_html(ctx.label.name)
    index_template = ctx.actions.declare_file(ctx.label.name + "_index_template.html")
    ctx.actions.write(index_template, INDEX_HTML_TEMPLATE.format(title = safe_title))

    bootstrap_template = ctx.actions.declare_file(ctx.label.name + "_bootstrap_template.js")
    ctx.actions.write(bootstrap_template, BOOTSTRAP_JS_TEMPLATE)

    manifest_json = ctx.actions.declare_file(ctx.label.name + "_manifest.json")
    ctx.actions.write(manifest_json, MANIFEST_JSON_TEMPLATE.format(name = safe_title))

    version_json = ctx.actions.declare_file(ctx.label.name + "_version.json")
    ctx.actions.write(version_json, VERSION_JSON_TEMPLATE.format(app_name = setup.package_name))
    return struct(
        bootstrap_template = bootstrap_template,
        index_template = index_template,
        manifest_json = manifest_json,
        version_json = version_json,
    )

def _web_integration_test_templates(ctx, setup, builds, inputs):
    """Runs the web template substitution tool over the written inputs.

    Args:
        ctx: Rule context.
        setup: The `_web_integration_test_setup` struct.
        builds: The compiler build records.
        inputs: The `_web_integration_test_template_files` struct.

    Returns:
        A struct with the generated template files and the SDK files to copy.
    """
    flutter_js_file = None
    renderer_files = []
    for f in _web_sdk_file_list(ctx):
        if f.path.endswith("/flutter_js/flutter.js"):
            flutter_js_file = f
        if "/web-sdk/canvaskit/" in f.path:
            renderer_files.append(f)

    index_html = ctx.actions.declare_file(ctx.label.name + "_index.html")
    bootstrap_js = ctx.actions.declare_file(ctx.label.name + "_flutter_bootstrap.js")

    build_config = build_config_js(setup.sdk.engine_revision, builds)
    shared_builtins = {
        "flutter_build_config": {"value": build_config},
        "flutter_service_worker_version": {"value": "null"},
    }
    template_inputs = [inputs.index_template, inputs.bootstrap_template]
    if flutter_js_file:
        shared_builtins["flutter_js"] = {"file": flutter_js_file.path}
        template_inputs.append(flutter_js_file)

    index_builtins = dict(shared_builtins)
    index_builtins["flutter_bootstrap_js"] = {"from_output": 0}

    template_config = {
        "web_defines": {},
        "keep_placeholders": [],
        "files": [
            {
                "template": inputs.bootstrap_template.path,
                "output": bootstrap_js.path,
                "label": "flutter_bootstrap.js",
                "base_href": "",
                "static_assets_url": None,
                "dev_loop_guard": False,
                "manages_service_worker": False,
                "check_constructs": True,
                "builtins": shared_builtins,
            },
            {
                "template": inputs.index_template.path,
                "output": index_html.path,
                "label": "index.html",
                "base_href": "/",
                "static_assets_url": "/",
                "dev_loop_guard": False,
                "manages_service_worker": False,
                "check_constructs": True,
                "builtins": index_builtins,
            },
        ],
    }
    template_config_file = ctx.actions.declare_file(ctx.label.name + "_web_template_config.json")
    ctx.actions.write(template_config_file, json.encode(template_config))

    ctx.actions.run(
        executable = setup.sdk.dart,
        arguments = [
            ctx.executable._web_template_tool.path,
            "--config",
            template_config_file.path,
        ],
        inputs = depset(
            direct = template_inputs + [template_config_file, ctx.executable._web_template_tool],
            transitive = [setup.sdk.dart_vm_files],
        ),
        outputs = [index_html, bootstrap_js],
        mnemonic = "FlutterWebTemplate",
        progress_message = "Substituting web templates for %s" % ctx.label,
    )
    return struct(
        bootstrap_js = bootstrap_js,
        flutter_js_file = flutter_js_file,
        index_html = index_html,
        manifest_json = inputs.manifest_json,
        renderer_files = renderer_files,
        version_json = inputs.version_json,
    )

def _web_integration_test_bundle(ctx, setup, compile, assets, templates):
    """Assembles the web bundle directory the runner serves.

    Args:
        ctx: Rule context.
        setup: The `_web_integration_test_setup` struct.
        compile: The `_web_integration_test_compile` struct.
        assets: The `flutter_assets` directory.
        templates: The `_web_integration_test_templates` struct.

    Returns:
        The declared web bundle directory.
    """
    output_dir = ctx.actions.declare_directory(ctx.label.name + "_web")
    copies = list(compile.copies)
    copies.extend([
        {"src": templates.index_html.path, "dst": "index.html"},
        {"src": templates.bootstrap_js.path, "dst": "flutter_bootstrap.js"},
        {"src": templates.manifest_json.path, "dst": "manifest.json"},
        {"src": templates.version_json.path, "dst": "version.json"},
    ])
    engine_inputs = []
    if templates.flutter_js_file:
        copies.append({"src": templates.flutter_js_file.path, "dst": "flutter.js"})
        engine_inputs.append(templates.flutter_js_file)
    for f in templates.renderer_files:
        idx = f.path.find("/web-sdk/canvaskit/")
        if idx >= 0:
            rel = "canvaskit/" + f.path[idx + len("/web-sdk/canvaskit/"):]
            copies.append({"src": f.path, "dst": rel})
            engine_inputs.append(f)

    copy_dirs = [{"src": assets.path, "dst": "assets"}]
    for d in compile.dart2js_dirs:
        copy_dirs.append({
            "src": d.path,
            "dst": ".",
            "exclude": ["*.deps", "*.info.json"],
        })

    bundle_config = {
        "output_dir": output_dir.path,
        "copies": copies,
        "copy_dirs": copy_dirs,
        "extracts": [],
    }
    bundle_config_file = ctx.actions.declare_file(ctx.label.name + "_web_bundle_config.json")
    ctx.actions.write(bundle_config_file, json.encode(bundle_config))

    exec_dart, dart_vm_files = resolve_exec_dart_vm(ctx, setup.sdk)
    all_bundle_inputs = (
        compile.outputs +
        compile.dart2js_dirs +
        engine_inputs +
        [
            assets,
            templates.index_html,
            templates.bootstrap_js,
            templates.manifest_json,
            templates.version_json,
            bundle_config_file,
        ]
    )
    ctx.actions.run(
        executable = exec_dart,
        arguments = [
            ctx.executable._bundle_tool.path,
            "--config",
            bundle_config_file.path,
        ],
        inputs = depset(
            direct = all_bundle_inputs + [ctx.executable._bundle_tool],
            transitive = [dart_vm_files],
        ),
        outputs = [output_dir],
        mnemonic = "FlutterWebBundle",
        progress_message = "Bundling Flutter web integration test %s" % ctx.label,
    )
    return output_dir

def _web_integration_test_run(ctx, setup, output_dir):
    """Wires the runner executable, environment and runfiles for the web bundle.

    Args:
        ctx: Rule context.
        setup: The `_web_integration_test_setup` struct.
        output_dir: The web bundle directory the runner serves.

    Returns:
        The provider list.
    """
    executable = _integration_test_runner_executable(ctx)
    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": ctx.attr.platform,
        "FLUTTER_INTEGRATION_TEST_WEB_DIR": runfiles_path(output_dir, workspace_name),
        "FLUTTER_INTEGRATION_TEST_BROWSER": runfiles_path(ctx.file._chrome_headless_shell, workspace_name),
        "FLUTTER_INTEGRATION_TEST_FONTCONFIG": runfiles_path(ctx.file._chrome_fontconfig, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ROBOTO_FONT": runfiles_path(ctx.file._roboto_font, workspace_name),
        "FLUTTER_INTEGRATION_TEST_PATH": setup.main_file.short_path,
        "FLUTTER_INTEGRATION_TEST_DECLARED_ENV": json.encode(ctx.attr.env),
    }
    library_tags = _integration_test_env(ctx, env, setup.main_file)
    return _integration_test_providers(
        ctx,
        struct(
            extra_srcs = setup.extra_srcs,
            lib_root = setup.lib_root,
            main_file = setup.main_file,
            package_name = setup.package_name,
        ),
        struct(
            env = env,
            executable = executable,
            runtime_files = [
                output_dir,
                ctx.file._chrome_headless_shell,
                ctx.file._chrome_fontconfig,
                ctx.file._roboto_font,
                library_tags,
            ] + ctx.attr._chrome_all_files.files.to_list(),
        ),
    )

def _flutter_integration_test_impl(ctx):
    setup = _web_integration_test_setup(ctx)
    entrypoint = _web_integration_test_bootstrap(ctx, setup)
    compile = _web_integration_test_compile(ctx, setup, entrypoint)
    assets = _integration_test_assets(
        ctx,
        setup.sdk,
        "web",
        None,
        setup.is_debug,
        None,
    )
    template_files = _web_integration_test_template_files(ctx, setup)
    templates = _web_integration_test_templates(ctx, setup, compile.builds, template_files)
    output_dir = _web_integration_test_bundle(ctx, setup, compile, assets, templates)
    return _web_integration_test_run(ctx, setup, output_dir)

def _linux_integration_test_setup(ctx):
    """Validates a Linux target and resolves its shared build inputs.

    Args:
        ctx: Rule context.

    Returns:
        An `_integration_test_common_setup` struct.
    """
    if ctx.attr.platform != "linux":
        fail(
            "%s: _flutter_linux_integration_test requires platform = 'linux', got %r." % (
                ctx.label,
                ctx.attr.platform,
            ),
        )

    setup = _integration_test_common_setup(ctx)
    if not setup.is_debug and setup.sdk.target_os in ("linux", "macos", "windows"):
        fail(
            "AOT cross-compilation between desktop platforms is not supported. " +
            "Build on a Linux host, or use debug mode (-c dbg).",
        )
    if not setup.is_debug and not setup.sdk.gen_snapshot:
        fail(
            "No target-compatible AOT gen_snapshot toolchain is registered for " +
            "this host and target platform.",
        )
    if setup.sdk.engine_library == None:
        fail(
            "No Linux engine library available in the Flutter toolchain. " +
            "Run Linux integration tests on a Linux host.",
        )
    return setup

def _linux_integration_test_sources(ctx, setup):
    """Generates the Linux bootstrap and registrant, and its package config.

    Args:
        ctx: Rule context.
        setup: The `_linux_integration_test_setup` struct.

    Returns:
        An `_integration_test_dart_sources` struct.
    """
    main_location = app_main_location(setup.package_name, setup.lib_root, setup.main_file)
    content = make_linux_integration_bootstrap_content(
        test_import = main_location.uri,
        has_integration_test = exposes_package(ctx.attr.deps, ["integration_test"]),
    )
    return _integration_test_dart_sources(ctx, setup, "linux", content)

def _linux_integration_test_runner(ctx, setup, sources):
    """Compiles the GTK runner and the native plugin registrant sources.

    Args:
        ctx: Rule context.
        setup: The `_linux_integration_test_setup` struct.
        sources: The `_linux_integration_test_sources` struct.

    Returns:
        A struct with `binary` and `engine_files`.
    """
    native_registrant_cc = generate_native_plugin_registrant(ctx, sources.plugins.all_plugins, "linux")
    native_registrant_h = generate_native_plugin_registrant_header(ctx, "linux")

    plugin_srcs = []
    plugin_hdrs = []
    plugin_include_dirs = []
    for entry in sources.plugins.linux_plugin_libraries.to_list():
        plugin_srcs.extend(entry.srcs.to_list())
        plugin_hdrs.extend(entry.hdrs.to_list())
        plugin_include_dirs.extend(entry.include_dirs.to_list())

    engine_files = setup.sdk.engine_library.files.to_list()
    runner_binary = compile_linux_runner(
        ctx,
        engine_files = engine_files,
        defines = linux_runner_defines(ctx.attr.gtk_app_id, ctx.attr.window_title),
        linux_sysroot = setup.sdk.linux_sysroot,
        runner = linux_runner_inputs([ctx.file._linux_runner_source]),
        registrant = linux_registrant_inputs([native_registrant_cc], [native_registrant_h]),
        target_arch = setup.sdk.target_arch,
        plugins = linux_plugin_inputs(plugin_srcs, plugin_hdrs, plugin_include_dirs),
    )
    return struct(
        binary = runner_binary,
        engine_files = engine_files,
    )

def _linux_integration_test_bundle(ctx, setup, kernel_dill, aot_output, assets, runner, native_assets):
    """Assembles the Linux desktop bundle directory.

    Args:
        ctx: Rule context.
        setup: The `_linux_integration_test_setup` struct.
        kernel_dill: The compiled kernel File.
        aot_output: The AOT `.so` File, or None in debug mode.
        assets: The `flutter_assets` directory.
        runner: The `_linux_integration_test_runner` struct.
        native_assets: The `_integration_test_native_assets` struct.

    Returns:
        A struct with `bundle`, `binary_name` and `native_libs`.
    """
    native_libs = _integration_test_native_libs(ctx, native_assets.bundled)
    bundle_dir = ctx.actions.declare_directory(ctx.label.name + "_linux")
    binary_name = ctx.label.name
    copies = compute_desktop_bundle_copies(
        artifacts = make_desktop_bundle_artifacts(
            is_debug = setup.is_debug,
            kernel_dill_path = kernel_dill.path if setup.is_debug else None,
            aot_output_path = aot_output.path if aot_output else None,
            aot_dst = "lib/libapp.so",
            icu_data_path = setup.sdk.icu_data.path,
        ),
        libs = make_desktop_bundle_libs(
            engine_basenames = [(f.path, f.basename) for f in runner.engine_files],
            native_basenames = [(lib.path, lib.basename) for lib in native_libs],
        ),
    )
    copies.append({"src": runner.binary.path, "dst": binary_name})

    bundle_config = {
        "output_dir": bundle_dir.path,
        "copies": copies,
        "copy_dirs": [
            {"src": assets.path, "dst": "data/flutter_assets"},
        ],
    }
    bundle_config_file = ctx.actions.declare_file(ctx.label.name + "_linux_bundle_config.json")
    ctx.actions.write(bundle_config_file, json.encode(bundle_config))

    extra_bundle_inputs = [kernel_dill] if setup.is_debug else [aot_output]
    all_bundle_inputs = (
        [bundle_config_file, assets, setup.sdk.icu_data, runner.binary] +
        extra_bundle_inputs +
        native_libs +
        runner.engine_files
    )
    exec_dart, dart_vm_files = resolve_exec_dart_vm(ctx, setup.sdk)
    ctx.actions.run(
        executable = exec_dart,
        arguments = [
            ctx.executable._bundle_tool.path,
            "--config",
            bundle_config_file.path,
        ],
        inputs = depset(
            direct = all_bundle_inputs + [ctx.executable._bundle_tool],
            transitive = [dart_vm_files],
        ),
        outputs = [bundle_dir],
        mnemonic = "FlutterLinuxBundle",
        progress_message = "Bundling Flutter Linux integration test %s" % ctx.label,
    )
    return struct(
        binary_name = binary_name,
        bundle = bundle_dir,
        native_libs = native_libs,
    )

def _linux_integration_test_run(ctx, setup, bundle):
    """Wires the runner executable, environment and runfiles for the Linux bundle.

    Args:
        ctx: Rule context.
        setup: The `_linux_integration_test_setup` struct.
        bundle: The `_linux_integration_test_bundle` struct.

    Returns:
        The provider list.
    """
    executable = _integration_test_runner_executable(ctx)
    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": "linux",
        "FLUTTER_INTEGRATION_TEST_LINUX_BUNDLE": runfiles_path(bundle.bundle, workspace_name),
        "FLUTTER_INTEGRATION_TEST_LINUX_BINARY": bundle.binary_name,
        "FLUTTER_INTEGRATION_TEST_XVFB": runfiles_path(ctx.file._linux_xvfb, workspace_name),
        "FLUTTER_INTEGRATION_TEST_XKBCOMP": runfiles_path(ctx.file._linux_xkbcomp, workspace_name),
        "FLUTTER_INTEGRATION_TEST_FONTCONFIG": runfiles_path(ctx.file._linux_fontconfig, workspace_name),
        "FLUTTER_INTEGRATION_TEST_PATH": setup.main_file.short_path,
        "FLUTTER_INTEGRATION_TEST_DECLARED_ENV": json.encode(ctx.attr.env),
    }
    library_tags = _integration_test_env(ctx, env, setup.main_file)
    return _integration_test_providers(
        ctx,
        struct(
            extra_srcs = setup.extra_srcs,
            lib_root = setup.lib_root,
            main_file = setup.main_file,
            package_name = setup.package_name,
        ),
        struct(
            env = env,
            executable = executable,
            runtime_files = [
                bundle.bundle,
                ctx.file._linux_xvfb,
                ctx.file._linux_xkbcomp,
                ctx.file._linux_fontconfig,
                library_tags,
            ] + ctx.attr._linux_runtime_all_files.files.to_list(),
        ),
    )

def _flutter_linux_integration_test_impl(ctx):
    setup = _linux_integration_test_setup(ctx)
    native_assets = _integration_test_native_assets(ctx, setup.sdk, "linux")
    sources = _linux_integration_test_sources(ctx, setup)
    kernel_dill = _integration_test_kernel(ctx, setup.sdk, sources, native_assets, setup.aot, setup.mode)
    aot_output = _integration_test_aot(ctx, setup.sdk, kernel_dill, setup.is_debug, setup.strip)
    assets = _integration_test_assets(
        ctx,
        setup.sdk,
        "linux",
        kernel_dill,
        setup.is_debug,
        native_assets.data_assets,
    )
    runner = _linux_integration_test_runner(ctx, setup, sources)
    bundle = _linux_integration_test_bundle(ctx, setup, kernel_dill, aot_output, assets, runner, native_assets)
    return _linux_integration_test_run(ctx, setup, bundle)

def _android_integration_app_setup(ctx):
    """Validates an Android app target and resolves its shared build inputs.

    Args:
        ctx: Rule context.

    Returns:
        An `_integration_test_common_setup` struct.
    """
    setup = _integration_test_common_setup(ctx)
    if not setup.is_debug and not setup.sdk.gen_snapshot:
        fail(
            "No target-compatible AOT gen_snapshot toolchain is registered for " +
            "this host and Android target platform.",
        )
    return setup

def _android_integration_app_sources(ctx, setup):
    """Generates the Android bootstrap and registrant, and its package config.

    Args:
        ctx: Rule context.
        setup: The `_android_integration_app_setup` struct.

    Returns:
        An `_integration_test_dart_sources` struct.
    """
    main_location = app_main_location(setup.package_name, setup.lib_root, setup.main_file)
    content = make_android_integration_bootstrap_content(
        test_import = main_location.uri,
        has_integration_test = exposes_package(ctx.attr.deps, ["integration_test"]),
    )
    return _integration_test_dart_sources(ctx, setup, "android", content)

def _android_integration_app_providers(ctx, setup, sources, native_assets, kernel_dill, aot_output, assets):
    """The providers a compiled Android integration-test app returns.

    Args:
        ctx: Rule context.
        setup: The `_android_integration_app_setup` struct.
        sources: The `_android_integration_app_sources` struct.
        native_assets: The `_integration_test_native_assets` struct.
        kernel_dill: The compiled kernel File.
        aot_output: The AOT `.so` File, or None in debug mode.
        assets: The `flutter_assets` directory.

    Returns:
        The provider list.
    """
    native_libs = _integration_test_native_libs(ctx)
    default_files = [
        assets,
        sources.package_config.config_file,
        native_assets.manifest,
    ] + native_libs + native_assets.bundled.to_list()
    if aot_output:
        default_files.append(aot_output)
    if setup.is_debug:
        default_files.append(kernel_dill)
    return [
        DefaultInfo(files = depset(default_files)),
        FlutterApplicationInfo(
            aot_output = aot_output,
            aot_strip = setup.strip if aot_output != None else False,
            kernel_dill = kernel_dill if setup.is_debug else None,
            flutter_assets = assets,
            icu_data = setup.sdk.icu_data,
            native_libs = native_libs,
            is_debug = setup.is_debug,
            package_config = sources.package_config.config_file,
            native_assets_manifest = native_assets.manifest,
            bundled_code_assets = native_assets.bundled,
            bundled_data_assets = native_assets.data_assets,
            apple_privacy_manifests = sources.plugins.apple_privacy_manifests,
            plugins = sources.plugins.all_plugins,
            apple_plugin_libraries = sources.plugins.apple_plugin_libraries,
            android_plugin_libraries = sources.plugins.android_plugin_libraries,
            linux_plugin_libraries = sources.plugins.linux_plugin_libraries,
            windows_plugin_libraries = sources.plugins.windows_plugin_libraries,
        ),
    ]

def _flutter_android_integration_app_impl(ctx):
    setup = _android_integration_app_setup(ctx)
    native_assets = _integration_test_native_assets(ctx, setup.sdk, "android")
    sources = _android_integration_app_sources(ctx, setup)
    kernel_dill = _integration_test_kernel(ctx, setup.sdk, sources, native_assets, setup.aot, setup.mode)
    aot_output = _integration_test_aot(ctx, setup.sdk, kernel_dill, setup.is_debug, setup.strip)
    assets = _integration_test_assets(
        ctx,
        setup.sdk,
        "android",
        kernel_dill,
        setup.is_debug,
        native_assets.data_assets,
    )
    return _android_integration_app_providers(ctx, setup, sources, native_assets, kernel_dill, aot_output, assets)

def _android_integration_test_setup(ctx):
    """Validates an Android test target and resolves its run inputs.

    Args:
        ctx: Rule context.

    Returns:
        A struct with `main_file`, `extra_srcs`, `package_name`, `lib_root`
        and `apk_file`.
    """
    if ctx.attr.platform != "android":
        fail(
            "%s: _flutter_android_integration_test requires platform = 'android', got %r." % (
                ctx.label,
                ctx.attr.platform,
            ),
        )

    if not exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, extra_srcs = resolve_main_and_srcs(ctx)

    apk_files = [
        f
        for f in ctx.files.apk
        if f.path.endswith(".apk") and not f.path.endswith("_unsigned.apk")
    ]
    if not apk_files:
        fail(
            "flutter_integration_test %s: expected a signed .apk from %s, got %s" % (
                ctx.label.name,
                ctx.attr.apk.label,
                [f.short_path for f in ctx.files.apk],
            ),
        )
    return struct(
        apk_file = apk_files[0],
        extra_srcs = extra_srcs,
        lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package),
        main_file = main_file,
        package_name = ctx.attr.package_name or ctx.label.name,
    )

def _flutter_android_integration_test_impl(ctx):
    setup = _android_integration_test_setup(ctx)
    executable = _integration_test_runner_executable(ctx)
    workspace_name = ctx.workspace_name
    apk_file = setup.apk_file
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": "android",
        "FLUTTER_INTEGRATION_TEST_ANDROID_APK": runfiles_path(apk_file, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ANDROID_PACKAGE": ctx.attr.android_package,
        "FLUTTER_INTEGRATION_TEST_ANDROID_EMULATOR": runfiles_path(ctx.file._android_emulator, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ANDROID_ADB": runfiles_path(ctx.file._android_adb, workspace_name),
        "FLUTTER_INTEGRATION_TEST_PATH": setup.main_file.short_path,
        "FLUTTER_INTEGRATION_TEST_DECLARED_ENV": json.encode(ctx.attr.env),
    }
    library_tags = _integration_test_env(ctx, env, setup.main_file)
    return _integration_test_providers(
        ctx,
        struct(
            extra_srcs = setup.extra_srcs,
            lib_root = setup.lib_root,
            main_file = setup.main_file,
            package_name = setup.package_name,
        ),
        struct(
            env = env,
            executable = executable,
            runtime_files = [
                apk_file,
                ctx.file._android_emulator,
                ctx.file._android_adb,
                library_tags,
            ] + ctx.attr._android_runtime_all_files.files.to_list(),
        ),
    )

_WEB_RELEVANT_KEYS = (
    "assets",
    "shaders",
    "shader_includes",
    "require_sksl_shaders",
    "_shader_compile_tool",
    "tree_shake_icons",
    "license_files",
    "track_widget_creation",
    "_asset_bundle_tool",
)

_COMMON_INTEGRATION_TEST_ATTRS = KERNEL_COMPILE_ATTRS | {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in _WEB_RELEVANT_KEYS
}
_COMMON_INTEGRATION_TEST_ATTRS["main"] = attr.label(
    doc = "The integration test .dart entry point. Optional when `srcs` " +
          "contains a single `.dart` file.",
    allow_single_file = [".dart"],
)
_COMMON_INTEGRATION_TEST_ATTRS["package_name"] = attr.string(
    doc = "Dart package name (from pubspec.yaml). Defaults to target name.",
)
_COMMON_INTEGRATION_TEST_ATTRS["app_srcs"] = attr.label_list(
    doc = "Dart source files for the application under test (e.g. `[\"lib/main.dart\"]`).",
    allow_files = [".dart"],
)
_COMMON_INTEGRATION_TEST_ATTRS["tree_shake_icons"] = attr.bool(
    doc = "Whether to tree-shake icon fonts in non-debug builds.",
    default = False,
)
_COMMON_INTEGRATION_TEST_ATTRS["platform"] = attr.string(
    doc = "Target platform to run the integration test on ('web', 'linux', 'android', or 'ios').",
    default = "web",
    values = ["web", "linux", "android", "ios"],
)
_COMMON_INTEGRATION_TEST_ATTRS["profile"] = attr.bool(
    doc = "Whether to compile in profile mode.",
    default = False,
)
_COMMON_INTEGRATION_TEST_ATTRS["data"] = attr.label_list(
    allow_files = True,
    doc = "Runtime data files made available in test runfiles.",
)
_COMMON_INTEGRATION_TEST_ATTRS["env"] = attr.string_dict(
    doc = "Extra environment variables for the test runner process.",
)

# Tag selection, as `flutter test --tags` / `--exclude-tags` resolve it.
# Named `include_tags` / `exclude_tags` rather than `tags` because Bazel's
# own `tags` attribute means something else. A `--test_env=FLUTTER_TEST_TAGS=...`
# (or `FLUTTER_TEST_EXCLUDE_TAGS`) value at run time overrides the attribute.
#
# Library-level `@Tags` on the entrypoint need no attribute: they are extracted
# at build time and always honoured (see `extract_library_tags_action`).
_COMMON_INTEGRATION_TEST_ATTRS["include_tags"] = attr.string_list(
    doc = "Run only tests matching every one of these `package:test` tag " +
          "selectors (library, group or test level), as `flutter test " +
          "--tags` intersects them. Each entry is a boolean selector " +
          "(`a && b`, `a || b`, `!a`, parentheses); several entries, or " +
          "comma-separated values in one entry, all have to match. A test " +
          "matching an `exclude_tags` selector never runs. An attribute " +
          "selection that matches no test fails the target.",
)
_COMMON_INTEGRATION_TEST_ATTRS["exclude_tags"] = attr.string_list(
    doc = "Skip tests matching any of these `package:test` tag selectors " +
          "(library, group or test level), as `flutter test " +
          "--exclude-tags` unions them. Wins over `include_tags`.",
)
_COMMON_INTEGRATION_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_COMMON_INTEGRATION_TEST_ATTRS.update(MODULAR_KERNEL_ATTRS)
_COMMON_INTEGRATION_TEST_ATTRS["_tool"] = attr.label(
    default = Label("//flutter/private/tools:flutter_integration_test_runner"),
    executable = True,
    cfg = "exec",
)
_COMMON_INTEGRATION_TEST_ATTRS["_library_tags_tool"] = LIBRARY_TAGS_TOOL_ATTR
_COMMON_INTEGRATION_TEST_ATTRS["_bundle_tool"] = attr.label(
    default = Label("//flutter/private/tools:bundle_app"),
    executable = True,
    cfg = "exec",
)
_COMMON_INTEGRATION_TEST_ATTRS["_sky_engine"] = attr.label(
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

_INTEGRATION_TEST_ATTRS = dict(_COMMON_INTEGRATION_TEST_ATTRS)
_INTEGRATION_TEST_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_web_shader_aspect, flutter_kernel_module_aspect],
)
_INTEGRATION_TEST_ATTRS["compiler"] = attr.string(
    doc = "Web compiler: 'dart2js' (default) or 'dart2wasm'.",
    default = "dart2js",
    values = ["dart2js", "dart2wasm"],
)
_INTEGRATION_TEST_ATTRS["renderer"] = attr.string(
    doc = "Web renderer: 'canvaskit' or 'skwasm'. Defaults to matching `compiler`.",
    default = "",
    values = ["", "canvaskit", "skwasm"],
)
_INTEGRATION_TEST_ATTRS["optimization_level_js"] = attr.string(
    doc = "The `-O` level for dart2js compilation.",
    default = "1",
    values = ["auto", "0", "1", "2", "3", "4"],
)
_INTEGRATION_TEST_ATTRS["optimization_level_wasm"] = attr.string(
    doc = "The `-O` level for dart2wasm compilation.",
    default = "0",
    values = ["auto", "0", "1", "2", "3", "4"],
)
_INTEGRATION_TEST_ATTRS["minify_js"] = attr.string(
    doc = "Whether dart2js minifies identifiers.",
    default = "false",
    values = ["auto", "true", "false"],
)
_INTEGRATION_TEST_ATTRS["minify_wasm"] = attr.string(
    doc = "Whether dart2wasm minifies runtime type names.",
    default = "false",
    values = ["auto", "true", "false"],
)
_INTEGRATION_TEST_ATTRS["strip_wasm"] = attr.bool(
    doc = "Whether to strip static symbol names from WASM output.",
    default = False,
)
_INTEGRATION_TEST_ATTRS["native_null_assertions"] = attr.bool(
    doc = "Whether to check JS interop nullability at runtime.",
    default = True,
)
_INTEGRATION_TEST_ATTRS["frequency_based_minification"] = attr.bool(
    doc = "Whether dart2js uses frequency-based minification.",
    default = True,
)
_INTEGRATION_TEST_ATTRS["enable_experiments"] = attr.string_list(
    doc = "Dart language experiments to enable.",
)
_INTEGRATION_TEST_ATTRS["source_maps"] = attr.bool(
    doc = "Whether to generate source maps.",
    default = False,
)
_INTEGRATION_TEST_ATTRS["_chrome_headless_shell"] = attr.label(
    default = Label("@flutter_chrome_headless_shell//:browser/chrome-headless-shell"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_chrome_fontconfig"] = attr.label(
    default = Label("@flutter_chrome_headless_shell//:fonts/fonts.conf"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_chrome_all_files"] = attr.label(
    default = Label("@flutter_chrome_headless_shell//:all_files"),
)
_INTEGRATION_TEST_ATTRS["_roboto_font"] = attr.label(
    default = Label("@flutter_material_fonts//:material-fonts/Roboto-Regular.ttf"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_dart2wasm_platform_dill"] = attr.label(
    default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2wasm_platform.dill"),
    allow_single_file = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_dart2js_platform_dill"] = attr.label(
    default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2js_platform.dill"),
    allow_single_file = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_web_sdk"] = attr.label(
    default = Label("@flutter_web_sdk//:web_sdk"),
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_web_template_tool"] = attr.label(
    default = Label("//flutter/private/tools:web_template"),
    executable = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_bootstrap_template"] = attr.label(
    default = Label("//flutter/private/integration_test_bootstrap:web_bootstrap.dart.tpl"),
    allow_single_file = True,
    doc = "The Dart bootstrap program expanded into the test's `_bootstrap.dart`.",
)

_LINUX_INTEGRATION_TEST_ATTRS = dict(_COMMON_INTEGRATION_TEST_ATTRS)
_LINUX_INTEGRATION_TEST_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_app_shader_aspect, flutter_kernel_module_aspect],
)
_LINUX_INTEGRATION_TEST_ATTRS["native_deps"] = attr.label_list(
    doc = "Native shared library targets (cc_library) for dart:ffi bundled into lib/.",
    aspects = [native_sources_aspect],
)
_LINUX_INTEGRATION_TEST_ATTRS["gtk_app_id"] = attr.string(
    doc = "GTK application identifier for the Linux test runner.",
    default = "com.example.flutter_integration_test",
)
_LINUX_INTEGRATION_TEST_ATTRS["window_title"] = attr.string(
    doc = "Window title for the Linux test runner.",
    default = "Flutter Integration Test",
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_runner_source"] = attr.label(
    default = Label("//flutter/private/runners:linux_runner.cc"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_cc_toolchain"] = attr.label(
    default = "@bazel_tools//tools/cpp:current_cc_toolchain",
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_xvfb"] = attr.label(
    default = Label("@flutter_linux_headless_runtime//:sysroot/usr/bin/Xvfb"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_xkbcomp"] = attr.label(
    default = Label("@flutter_linux_headless_runtime//:sysroot/usr/bin/xkbcomp"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_fontconfig"] = attr.label(
    default = Label("@flutter_linux_headless_runtime//:fonts/fonts.conf"),
    allow_single_file = True,
)
_LINUX_INTEGRATION_TEST_ATTRS["_linux_runtime_all_files"] = attr.label(
    default = Label("@flutter_linux_headless_runtime//:all_files"),
)
_LINUX_INTEGRATION_TEST_ATTRS["_bootstrap_template"] = attr.label(
    default = Label("//flutter/private/integration_test_bootstrap:linux_bootstrap.dart.tpl"),
    allow_single_file = True,
    doc = "The Dart bootstrap program expanded into the test's `_linux_bootstrap.dart`.",
)

_ANDROID_INTEGRATION_APP_ATTRS = KERNEL_COMPILE_ATTRS | {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in _WEB_RELEVANT_KEYS
}
_ANDROID_INTEGRATION_APP_ATTRS["main"] = _COMMON_INTEGRATION_TEST_ATTRS["main"]
_ANDROID_INTEGRATION_APP_ATTRS["package_name"] = _COMMON_INTEGRATION_TEST_ATTRS["package_name"]
_ANDROID_INTEGRATION_APP_ATTRS["app_srcs"] = _COMMON_INTEGRATION_TEST_ATTRS["app_srcs"]
_ANDROID_INTEGRATION_APP_ATTRS["tree_shake_icons"] = _COMMON_INTEGRATION_TEST_ATTRS["tree_shake_icons"]
_ANDROID_INTEGRATION_APP_ATTRS["profile"] = _COMMON_INTEGRATION_TEST_ATTRS["profile"]
_ANDROID_INTEGRATION_APP_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_app_shader_aspect, flutter_kernel_module_aspect],
)
_ANDROID_INTEGRATION_APP_ATTRS["native_deps"] = attr.label_list(
    doc = "Native shared library targets (cc_library) for dart:ffi bundled into lib/.",
    aspects = [native_sources_aspect],
)
_ANDROID_INTEGRATION_APP_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_ANDROID_INTEGRATION_APP_ATTRS.update(MODULAR_KERNEL_ATTRS)
_ANDROID_INTEGRATION_APP_ATTRS["_bootstrap_template"] = attr.label(
    default = Label("//flutter/private/integration_test_bootstrap:android_bootstrap.dart.tpl"),
    allow_single_file = True,
    doc = "The Dart bootstrap program expanded into the app's `_android_bootstrap.dart`.",
)

_ANDROID_INTEGRATION_TEST_ATTRS = {
    "apk": attr.label(
        mandatory = True,
        allow_files = True,
        doc = "The compiled Android APK target.",
    ),
    "android_package": attr.string(
        mandatory = True,
        doc = "Android application ID (e.g. 'com.example.app_test').",
    ),
    "srcs": KERNEL_COMPILE_ATTRS["srcs"],
    "main": _COMMON_INTEGRATION_TEST_ATTRS["main"],
    "app_srcs": _COMMON_INTEGRATION_TEST_ATTRS["app_srcs"],
    "package_name": _COMMON_INTEGRATION_TEST_ATTRS["package_name"],
    "language_version": KERNEL_COMPILE_ATTRS["language_version"],
    "deps": attr.label_list(
        doc = FLUTTER_DEPS_DOC,
        providers = [DartInfo],
    ),
    "platform": _COMMON_INTEGRATION_TEST_ATTRS["platform"],
    "data": _COMMON_INTEGRATION_TEST_ATTRS["data"],
    "env": _COMMON_INTEGRATION_TEST_ATTRS["env"],
    "include_tags": _COMMON_INTEGRATION_TEST_ATTRS["include_tags"],
    "exclude_tags": _COMMON_INTEGRATION_TEST_ATTRS["exclude_tags"],
    "_tool": _COMMON_INTEGRATION_TEST_ATTRS["_tool"],
    "_library_tags_tool": _COMMON_INTEGRATION_TEST_ATTRS["_library_tags_tool"],
    "_sky_engine": _COMMON_INTEGRATION_TEST_ATTRS["_sky_engine"],
    "_android_emulator": attr.label(
        default = Label("@flutter_android_headless_runtime//:sdk/emulator/emulator"),
        allow_single_file = True,
    ),
    "_android_adb": attr.label(
        default = Label("@flutter_android_headless_runtime//:sdk/platform-tools/adb"),
        allow_single_file = True,
    ),
    "_android_runtime_all_files": attr.label(
        default = Label("@flutter_android_headless_runtime//:all_files"),
    ),
}
_ANDROID_INTEGRATION_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)

_flutter_integration_test = rule(
    implementation = _flutter_integration_test_impl,
    attrs = _INTEGRATION_TEST_ATTRS,
    test = True,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:product_tools_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:font_subset_toolchain_type",
            mandatory = False,
        ),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter app with an in-app integration test and runs it on the web platform.",
)

_flutter_linux_integration_test = rule(
    implementation = _flutter_linux_integration_test_impl,
    attrs = _LINUX_INTEGRATION_TEST_ATTRS,
    fragments = ["cpp"],
    test = True,
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:product_tools_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:aot_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:desktop_engine_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:font_subset_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_dart//dart:exec_tools_toolchain_type",
            mandatory = False,
        ),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter Linux desktop app with an in-app integration test and runs it headlessly under Xvfb.",
)

_flutter_android_integration_app = rule(
    implementation = _flutter_android_integration_app_impl,
    attrs = _ANDROID_INTEGRATION_APP_ATTRS,
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:product_tools_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:aot_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_flutter//flutter/private:font_subset_toolchain_type",
            mandatory = False,
        ),
        config_common.toolchain_type(
            "@rules_dart//dart:exec_tools_toolchain_type",
            mandatory = False,
        ),
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter Android application with an in-app integration test bootstrap.",
)

# The iOS bootstrap shares the Linux bootstrap's shape (a JIT build with
# dart:io available, driven via `RemoteListener`), but not its harness-URL
# read: on iOS `Platform.environment` is always empty, so the iOS bootstrap
# expands the same Linux template with the iOS prologue chosen by
# `ios_integration_bootstrap_substitutions`
# (`flutter_integration_test_ios.bzl`, where iOS-only code lives): the
# data-container file fallback and the flushed failure. The Linux generator
# itself is unchanged.
def _flutter_ios_integration_bootstrap_impl(ctx):
    if not exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, _extra_srcs = resolve_main_and_srcs(ctx)
    package_name = ctx.attr.package_name or ctx.label.name
    lib_root = derive_lib_root(ctx.label.workspace_root, ctx.label.package)
    main_location = app_main_location(package_name, lib_root, main_file)
    has_integration_test = exposes_package(ctx.attr.deps, ["integration_test"])
    bootstrap = ctx.actions.declare_file(ctx.label.name + ".dart")
    ctx.actions.expand_template(
        template = ctx.file._bootstrap_template,
        output = bootstrap,
        substitutions = ios_integration_bootstrap_substitutions(
            make_linux_integration_bootstrap_content(
                test_import = main_location.uri,
                has_integration_test = has_integration_test,
            ),
        ),
    )
    return [DefaultInfo(files = depset([bootstrap]))]

flutter_ios_integration_bootstrap = rule(
    implementation = _flutter_ios_integration_bootstrap_impl,
    attrs = {
        "main": attr.label(
            doc = "The integration test .dart entry point. Optional when `srcs` " +
                  "contains a single `.dart` file.",
            allow_single_file = [".dart"],
        ),
        "srcs": attr.label_list(
            doc = "Integration test Dart source files.",
            allow_files = [".dart"],
        ),
        "app_srcs": attr.label_list(
            doc = "Dart source files for the application under test (e.g. `[\"lib/main.dart\"]`).",
            allow_files = [".dart"],
        ),
        "package_name": attr.string(
            doc = "Dart package name (from pubspec.yaml). Defaults to target name.",
        ),
        "deps": attr.label_list(
            doc = FLUTTER_DEPS_DOC,
            providers = [DartInfo],
        ),
        "_bootstrap_template": attr.label(
            default = Label("//flutter/private/integration_test_bootstrap:linux_bootstrap.dart.tpl"),
            allow_single_file = True,
            doc = "The shared Linux bootstrap program expanded with the iOS harness-URL prologue.",
        ),
    },
    doc = "Resolves the integration test entrypoint and writes its iOS bootstrap.",
)

_flutter_android_integration_test = rule(
    implementation = _flutter_android_integration_test_impl,
    attrs = _ANDROID_INTEGRATION_TEST_ATTRS,
    test = True,
    doc = "Runs a compiled Flutter Android integration test APK inside a hermetic, pinned headless Android emulator.",
)

def _merge_integration_test_deps(deps, app_deps, app):
    """The caller's test deps plus `app_deps` and `app`, without duplicates.

    Args:
        deps: The caller's `deps`.
        app_deps: Extra app dependencies.
        app: An optional app library target.

    Returns:
        The merged dependency list.
    """
    merged_deps = list(deps)
    for extra in list(app_deps) + ([app] if app != None else []):
        if extra not in merged_deps:
            merged_deps.append(extra)
    return merged_deps

def _android_integration_test_app(name, package_name, deps, kwargs):
    """Declares the Android helper app, bundle, engine and plugin targets.

    Args:
        name: The test target's name the helper names derive from.
        package_name: The resolved Dart package name.
        deps: The merged dependencies.
        kwargs: The macro's extra attributes.
    """
    helper_tags = ["manual"]
    app_kwargs = {}
    for k in ANDROID_APP_KWARG_KEYS:
        if k in kwargs:
            app_kwargs[k] = kwargs[k]

    _flutter_android_integration_app(
        name = "__%s_app" % name,
        package_name = package_name,
        deps = deps,
        tags = helper_tags,
        visibility = ["//visibility:private"],
        **app_kwargs
    )

    flutter_android_bundle(
        name = "__%s_bundle" % name,
        application = ":__%s_app" % name,
        android_abi = "x86_64",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    native.filegroup(
        name = "__%s_native_libs_jar" % name,
        srcs = [":__%s_bundle" % name],
        output_group = "native_libs_jar",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    java_import(
        name = "__%s_native_libs" % name,
        jars = [":__%s_native_libs_jar" % name],
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    flutter_android_engine(
        name = "__%s_engine" % name,
        android_abi = "x64",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    native.filegroup(
        name = "__%s_flutter_assets" % name,
        srcs = [":__%s_bundle" % name],
        output_group = "mobile_install",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    flutter_android_registrant(
        name = "__%s_registrant_src" % name,
        application = ":__%s_app" % name,
        android_abi = "x86_64",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    flutter_android_plugins_aggregator(
        name = "__%s_android_plugins" % name,
        application = ":__%s_app" % name,
        android_abi = "x86_64",
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

def _android_integration_test_apk(name, android_package, pub_hub_name, android_deps):
    """Declares the Android registrant, merged manifest and signed APK targets.

    Args:
        name: The test target's name the helper names derive from.
        android_package: The resolved Android application ID.
        pub_hub_name: Optional `flutter.pub` hub whose plugin aggregator links.
        android_deps: Extra Android library targets.
    """
    helper_tags = ["manual"]
    registrant_deps = [
        ":__%s_engine" % name,
        ":__%s_android_plugins" % name,
    ]
    if pub_hub_name:
        registrant_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)
    registrant_deps = registrant_deps + list(android_deps)

    kt_android_library(
        name = "__%s_registrant" % name,
        srcs = [":__%s_registrant_src" % name],
        custom_package = "io.flutter.plugins",
        deps = registrant_deps,
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    binary_deps = [
        ":__%s_native_libs" % name,
        ":__%s_engine" % name,
        ":__%s_registrant" % name,
        ":__%s_android_plugins" % name,
    ]
    if pub_hub_name:
        binary_deps.append("@%s//android:all_android_plugin_libs" % pub_hub_name)
    binary_deps = binary_deps + list(android_deps)

    write_file(
        name = "__%s_base_manifest" % name,
        out = "__%s_base_manifest/AndroidManifest.xml" % name,
        content = make_android_integration_manifest_lines(
            android_package,
            name,
        ),
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    flutter_android_manifest_merge(
        name = "__%s_manifest" % name,
        base = ":__%s_base_manifest" % name,
        libraries = binary_deps,
        placeholders = ["applicationId", "minSdkVersion", "targetSdkVersion"],
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

    android_binary(
        name = "__%s_apk" % name,
        manifest = ":__%s_manifest" % name,
        manifest_values = {
            "applicationId": android_package,
            "minSdkVersion": ANDROID_MIN_SDK_VERSION,
            "targetSdkVersion": ANDROID_TARGET_SDK_VERSION,
        },
        assets = [":__%s_flutter_assets" % name],
        assets_dir = "assets",
        deps = binary_deps,
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )

def _android_integration_test(name, package_name, deps, android_package, android_deps, pub_hub_name, kwargs):
    """Declares the Android integration-test app and test targets.

    Args:
        name: The test target's name.
        package_name: The resolved Dart package name.
        deps: The merged dependencies.
        android_package: Optional explicit Android application ID.
        android_deps: Extra Android library targets.
        pub_hub_name: Optional `flutter.pub` hub whose plugin aggregator links.
        kwargs: The macro's extra attributes.
    """
    resolved_android_package = android_package or (
        "com.example.%s" % sanitize_android_package_segment(package_name)
    )
    _android_integration_test_app(name, package_name, deps, kwargs)
    _android_integration_test_apk(name, resolved_android_package, pub_hub_name, android_deps)

    test_kwargs = {
        k: v
        for k, v in kwargs.items()
        if k not in ANDROID_APP_KWARG_KEYS or k in ("srcs", "main", "app_srcs", "language_version")
    }

    _flutter_android_integration_test(
        name = name,
        apk = ":__%s_apk" % name,
        android_package = resolved_android_package,
        package_name = package_name,
        deps = deps,
        platform = "android",
        **test_kwargs
    )

def _ios_integration_test(name, package_name, deps, ios_bundle_id, ios_runner_srcs, ios_info_plist, kwargs):
    """Declares the iOS bootstrap and simulator test targets.

    Args:
        name: The test target's name.
        package_name: The resolved Dart package name.
        deps: The merged dependencies.
        ios_bundle_id: Optional explicit bundle ID.
        ios_runner_srcs: Optional Runner Swift sources.
        ios_info_plist: Optional `Info.plist` override.
        kwargs: The macro's extra attributes.
    """
    helper_tags = ["manual"]
    flutter_ios_integration_bootstrap(
        name = "__%s_bootstrap" % name,
        package_name = package_name,
        deps = deps,
        main = kwargs.get("main"),
        srcs = kwargs.get("srcs", []),
        app_srcs = kwargs.get("app_srcs", []),
        tags = helper_tags,
        visibility = ["//visibility:private"],
    )
    assemble_ios_integration_test(
        name = name,
        package_name = package_name,
        deps = deps,
        ios_bundle_id = ios_bundle_id,
        ios_runner_srcs = ios_runner_srcs,
        ios_info_plist = ios_info_plist,
        platform = "ios",
        bootstrap = ":__%s_bootstrap" % name,
        **kwargs
    )

def flutter_integration_test(
        name,
        package_name = "",
        deps = [],
        app_deps = [],
        app = None,
        platform = "web",
        android_package = "",
        android_deps = [],
        pub_hub_name = None,
        ios_bundle_id = "",
        ios_runner_srcs = None,
        ios_info_plist = None,
        **kwargs):
    """Builds and runs an end-to-end Flutter integration test on a real platform.

    Compiles the application and the integration test (`WidgetTester` code) into
    a real platform bundle and drives it via the platform runner. On `web`, the
    built web bundle is served from `127.0.0.1` and executed inside a hermetic,
    pinned `chrome-headless-shell` browser. On `linux`, the built GTK desktop
    bundle is executed inside a hermetic, pinned `Xvfb` virtual display with
    pinned GTK3 and Mesa software OpenGL/EGL libraries. On `android`, the built
    Android APK is installed and executed inside a hermetic, pinned headless
    Android `x86_64` emulator accelerated with KVM. On `ios`, the built
    simulator-debug app is installed and executed on an iOS simulator from the
    macOS host (needs a macOS host with Xcode, a simulator runtime, and the
    package's `ios/Runner` sources).

    Args:
        name: Target name.
        package_name: Dart package name (from `pubspec.yaml`). Defaults to `name`.
        deps: Dependencies (`dart_library` / `flutter_library`) for the test and app.
        app_deps: Optional additional dependencies for the app, merged with `deps`.
        app: Optional library target for the app under test, merged with `deps`.
        platform: Target platform (`"web"`, `"linux"`, `"android"`, or `"ios"`, defaults to `"web"`).
        android_package: Optional Android application ID when `platform = "android"`.
            Defaults to `"com.example.<package_name>"`.
        android_deps: Optional additional Android library targets (`kt_android_library`,
            `android_library`, `flutter_android_plugin_library`) when `platform = "android"`.
            Workspace plugins that set `android_libs` on `flutter_plugin` are
            collected automatically from `deps`.
        pub_hub_name: Optional `flutter.pub` hub name (e.g. `"deps"`) whose
            `@<pub_hub_name>//android:all_android_plugin_libs` aggregator should
            be linked when `platform = "android"`.
        ios_bundle_id: Optional iOS bundle ID when `platform = "ios"`.
            Used verbatim when set. Defaults to
            `"com.example.<package path>.<name>.<label hash>"`, where the
            hash covers the test target's full label, so two tests never
            share an id; pass `ios_bundle_id` to keep a fixed id. The test
            runs with the `exclusive` tag (merged with `tags`), so Bazel
            never runs two simulator tests at once.
        ios_runner_srcs: Optional Runner Swift sources when `platform = "ios"`.
            Defaults to `None`, which discovers the package's
            `ios/Runner/*.swift`.
        ios_info_plist: Optional `Info.plist` override when `platform = "ios"`.
            Defaults to `None`, which preprocesses the package's
            `ios/Runner/Info.plist`.
        **kwargs: Additional attributes forwarded to the rule (`main`, `srcs`,
            `app_srcs`, `assets`, `shaders`, `compiler`, `renderer`,
            `native_deps`, `defines`, `data`, `env`, etc.).
    """
    merged_deps = _merge_integration_test_deps(deps, app_deps, app)
    resolved_package_name = package_name or name

    if platform == "android":
        _android_integration_test(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            android_package = android_package,
            android_deps = android_deps,
            pub_hub_name = pub_hub_name,
            kwargs = kwargs,
        )
    elif platform == "ios":
        _ios_integration_test(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            ios_bundle_id = ios_bundle_id,
            ios_runner_srcs = ios_runner_srcs,
            ios_info_plist = ios_info_plist,
            kwargs = kwargs,
        )
    elif platform == "linux":
        _flutter_linux_integration_test(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            platform = platform,
            **kwargs
        )
    else:
        _flutter_integration_test(
            name = name,
            package_name = resolved_package_name,
            deps = merged_deps,
            platform = platform,
            **kwargs
        )
