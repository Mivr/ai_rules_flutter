"""The debug-mode outputs of `flutter_web_bundle`: DDC dev files and the dev-loop config.

The dev tool discovers these in the build output list, the same way it does for
a native `flutter_application`.
"""

load(
    "//flutter/private:app_entrypoint.bzl",
    "app_main_location",
    "app_scheme_sources",
)
load("//flutter/private:common.bzl", "shader_sources")

def _web_stage_ddc_files(ctx, dev_bootstrap_js):
    """Stages the DDC dev-loop files as top-level debug outputs.

    The dev tool discovers these in the build output list (same pattern as native).
    """
    ddc_files = []

    # DDC outline dill (--platform flag for frontend_server).
    ddc_outline_dill = ctx.actions.declare_file(ctx.label.name + "_ddc_outline.dill")
    ctx.actions.symlink(output = ddc_outline_dill, target_file = ctx.file._ddc_outline_dill)
    ddc_files.append(ddc_outline_dill)

    # DDC libraries spec (--libraries-spec flag).
    ddc_libraries_json = ctx.actions.declare_file(ctx.label.name + "_ddc_libraries.json")
    ctx.actions.symlink(output = ddc_libraries_json, target_file = ctx.file._ddc_libraries_spec)
    ddc_files.append(ddc_libraries_json)

    # DDC-compiled Dart SDK JS.
    ddc_dart_sdk_js = ctx.actions.declare_file(ctx.label.name + "_ddc_dart_sdk.js")
    ctx.actions.symlink(output = ddc_dart_sdk_js, target_file = ctx.file._ddc_dart_sdk_js)
    ddc_files.append(ddc_dart_sdk_js)

    # DDC module loader JS.
    ddc_module_loader_js = ctx.actions.declare_file(ctx.label.name + "_ddc_module_loader.js")
    ctx.actions.symlink(output = ddc_module_loader_js, target_file = ctx.file._ddc_module_loader_js)
    ddc_files.append(ddc_module_loader_js)

    # DDC stack trace mapper JS.
    ddc_stack_trace_mapper_js = ctx.actions.declare_file(ctx.label.name + "_ddc_stack_trace_mapper.js")
    ctx.actions.symlink(output = ddc_stack_trace_mapper_js, target_file = ctx.file._ddc_stack_trace_mapper_js)
    ddc_files.append(ddc_stack_trace_mapper_js)

    # AI-agent service extensions, staged for the dev tool to import from
    # its synthetic entrypoint (see the `agentExtensions` dev-config key).
    #
    # Staged only here, in the DDC branch, rather than compiled into the
    # bundle the way the native rules compile it into their kernel. The
    # bundle is built by dart2wasm/dart2js, where `dart:developer`'s
    # `registerExtension` is a no-op stub — and the runs that serve the
    # bundle (`--wasm`, release) have no VM service to register against
    # either. Only the DDC dev loop can carry these.
    staged_agent = ctx.actions.declare_file(ctx.label.name + ".agent_extensions.dart")
    ctx.actions.symlink(output = staged_agent, target_file = ctx.file._agent_extensions_src)
    ddc_files.append(staged_agent)

    # The dev loop's bootstrap, declared a top-level debug output so it is
    # materialized locally for the dev server to read and serve.
    ddc_files.append(dev_bootstrap_js)
    return ddc_files, staged_agent

def _web_dev_config_content(ctx, flutter_sdk_info, debug, staged_agent, bundle):
    """Builds the web dev-loop config content.

    The synthetic-main entrypoint the dev tool imports: the `main`'s
    `package:` URI, backed by the record `synthesize_app_package` wrote
    above, or — for a `main` outside the package's `lib/`, which
    `flutter run -t` allows — its app-scheme URI, which the dev loop
    resolves through the root `dev_filesystem_roots` carries for it.

    Never a URI derived any other way. An earlier version fabricated
    `package:<name>/main.dart` for a `main` it could not place, which
    named some other app's entrypoint whenever the workspace root held
    one, and the dev loop booted that program with nothing reporting a
    mismatch.

    Args:
        ctx: Rule context.
        flutter_sdk_info: The Flutter SDK info struct (engine revision,
            version and host tool paths).
        debug: The debug struct (`defines`, `lib_root`, `registrant`,
            `dev_bootstrap_js`, `dev`, `build_package_config`,
            `config_file`).
        staged_agent: The staged AI-agent service extensions File.
        bundle: The `_web_assemble_copies` struct (reads the declared
            native modules and their binding contracts).
    """
    app_entrypoint = app_main_location(ctx.attr.package_name, debug.lib_root, ctx.file.main).uri

    # The dart-sdk root is derived from the module loader path:
    # .../dart-sdk/lib/dev_compiler/ddc/ddc_module_loader.js → .../dart-sdk
    dart_sdk_root = ctx.file._ddc_module_loader_js.path.rsplit("/lib/", 1)[0]
    return json.encode({
        "engineRevision": flutter_sdk_info.engine_revision,
        "flutterVersion": flutter_sdk_info.version,
        "dartSdkRoot": dart_sdk_root,
        "dartaotruntime": flutter_sdk_info.dartaotruntime.path,
        "frontendServer": flutter_sdk_info.frontend_server.path,
        "patchedSdkRoot": flutter_sdk_info.platform_kernel_dill.path.rsplit("/", 1)[0],
        "appEntrypoint": app_entrypoint,
        # The generated web plugin registrant (`registerPlugins()`). The
        # bundled build reaches it through the wrapper main's relative
        # import; DDC dev mode builds its own synthetic entrypoint, so the
        # dev tool needs the path named explicitly — it stages the file
        # beside that entrypoint and imports it the same way. Empty when
        # the app has no web plugins.
        "webPluginRegistrant": debug.registrant.path if debug.registrant else "",
        # The staged AI-agent service extensions. Same staging contract as
        # `webPluginRegistrant`: the build names the file, the dev tool
        # copies it beside its synthetic entrypoint and imports it. Always
        # present in this branch — a dbg web run is a dev-loop run.
        "agentExtensions": staged_agent.path,
        # The bootstrap the dev server answers `/flutter_bootstrap.js`
        # with: this target's template, substituted with the DDC build
        # config the dev loop runs under. Named here rather than found by
        # suffix because it is one file per target, and a run that served
        # another target's would boot the wrong app.
        "flutterBootstrapJs": debug.dev_bootstrap_js.path,
        # Merged user defines (attr + extra_dart_defines flag). The dev
        # tool replays these as -D on its resident frontend_server so
        # hot reload/restart recompiles keep the same environment.
        "dartDefines": debug.defines,
        # Whether the DDC dev loop asserts native nullability, so a run of
        # this app checks what its built bundle checks. The dev loop
        # applies it through the SDK options in its generated bootstrap
        # rather than as a compiler flag, which is why it travels as a
        # value here instead of joining `dartDefines`.
        "nativeNullAssertions": ctx.attr.native_null_assertions,
        # The dev loop's frontend_server parses the same source these
        # experiments change, so without them a `flutter_bazel run` of an
        # experiment-using app fails to parse code its bundle compiles
        # cleanly. The dev tool's side of this is #58-#67.
        "enableExperiments": ctx.attr.enable_experiments,
        # Codegen hot-reload: dev package_config + multi-root layout +
        # generated source paths/URIs (empty for non-codegen apps).
        "devPackageConfig": debug.dev.dev_package_config.path if debug.dev.dev_package_config else "",
        # The BUILD package_config, for the one consumer that needs file
        # paths rather than live sources: DWDS, which reads a `package:`
        # URI's source off disk to show it in the debugger.
        #
        # Named separately from `devPackageConfig` because the two are not
        # interchangeable and only the call site knows which it wants. A
        # source-assembled package's dev `rootUri` is
        # `<filesystemScheme>:///<lib_root>`, which the frontend_server
        # resolves through `--filesystem-root` but `Uri.toFilePath()`
        # cannot: DWDS asked through it gets "Cannot extract a file path
        # from a org-dartlang-app URI" and shows no source at all. This
        # one's rootUris are ordinary relative paths, so they resolve.
        "buildPackageConfig": debug.build_package_config.path if debug.build_package_config else debug.config_file.path,
        "filesystemRoots": debug.dev.dev_filesystem_roots,
        "filesystemScheme": debug.dev.dev_filesystem_scheme,
        "generatedSourcePaths": debug.dev.dev_generated_source_paths,
        "generatedSourceUris": debug.dev.dev_generated_source_uris,
        # See flutter_application's dev config.
        "shaders": shader_sources(ctx),
        # The native modules the page instantiates, and per module the files
        # its bindings were generated from. A reload cannot replace an
        # instantiated module any more than a process can replace a `dlopen`ed
        # image, so the dev tool compares these the same way — see
        # `NativeLibsWatch`. The built file rather than its served copy: the
        # copy derives from it, and this is the path the rebuild rewrites.
        #
        # Declared, never inferred. This directory also holds Flutter's own
        # `main.dart.wasm`, which changes on every Dart edit, so a watch that
        # recognised a module by extension would flag every reload.
        "nativeLibs": [f.path for f in bundle.native_module_files],
        "nativeLibContracts": {
            f.path: [c.path for c in contracts]
            for f, contracts in bundle.native_module_contracts.items()
        },
        # First-party source packages (app + local deps) the dev tool maps
        # live edits back to via its SourceUriResolver. libRoot is
        # workspace-relative.
        "sourcePackages": [
            {"name": sp[0], "libRoot": sp[1]}
            for sp in debug.dev.dev_source_packages
        ],
        # The sources outside every package the app compiles under the app
        # scheme — a `main` outside its package's `lib/` and the `srcs`
        # beside it — with the URI the compiler keys each by. Empty for a
        # `main` with a `package:` URI.
        "appSources": app_scheme_sources(
            ctx.attr.package_name,
            debug.lib_root,
            ctx.file.main,
            ctx.files.srcs,
        ),
    })

def web_debug_result(ctx, flutter_sdk_info, debug, bundle, output_dir, output_groups, analyzable_info):
    """Assembles the debug-mode providers: DDC files plus the dev config.

    Args:
        ctx: Rule context.
        flutter_sdk_info: The Flutter SDK info struct (engine revision,
            version and host tool paths).
        debug: The debug struct (`defines`, `lib_root`, `registrant`,
            `dev_bootstrap_js`, `dev`, `build_package_config`,
            `build_package_dirs`, `config_file`).
        bundle: The `_web_assemble_copies` struct (reads the declared
            native modules' binding contracts).
        output_dir: The bundled web directory.
        output_groups: The bundler's output groups.
        analyzable_info: The Dart analysis closure.
    """
    ddc_files, staged_agent = _web_stage_ddc_files(ctx, debug.dev_bootstrap_js)

    # Dev config JSON with engine revision, version, and host tool paths.
    dev_config_content = _web_dev_config_content(ctx, flutter_sdk_info, debug, staged_agent, bundle)
    dev_config = ctx.actions.declare_file(ctx.label.name + "_dev_config.json")
    ctx.actions.write(dev_config, dev_config_content)
    ddc_files.append(dev_config)
    if debug.dev:
        ddc_files.extend(debug.dev.dev_generated_source_files)
        if debug.dev.dev_package_config:
            ddc_files.append(debug.dev.dev_package_config)
    if debug.build_package_config:
        ddc_files.append(debug.build_package_config)
    ddc_files.extend(debug.build_package_dirs)

    # Include package_config in debug outputs.
    ddc_files.append(debug.config_file)

    # The web plugin registrant is otherwise only an input to the
    # dart2wasm/dart2js compile actions; declaring it a top-level debug
    # output guarantees it is materialized locally for the dev tool to
    # stage next to its synthetic entrypoint.
    if debug.registrant:
        ddc_files.append(debug.registrant)

    # And the declared modules' binding contracts, which are an input to no
    # action here at all — nothing but the dev tool reads their bytes. A
    # *generated* contract is otherwise a path in the config that this build
    # never writes, unless some other action happens to produce it. See
    # `flutter_application`, which declares them for the same reason.
    for contracts in bundle.native_module_contracts.values():
        ddc_files.extend(contracts)

    return [DefaultInfo(files = depset([output_dir] + ddc_files)), output_groups, analyzable_info]
