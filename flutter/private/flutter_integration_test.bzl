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
"""

load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart:utils.bzl",
    "MODULAR_KERNEL_TOOLCHAINS",
    "collect_packages",
    "collect_transitive_srcs",
    "dart_analyzable_info_with_package",
    "derive_lib_root",
    "runfiles_path",
)
load("//flutter:providers.bzl", "FlutterInfo")
load(
    "//flutter/private:app_entrypoint.bzl",
    "compile_package_config",
    "package_lib_prefix",
    "resolve_wrapper_main_import",
    "synthesize_app_package",
)
load(
    "//flutter/private:common.bzl",
    "COPY_TO_DIRECTORY_TOOLCHAINS",
    "FLUTTER_APPLICATION_ATTRS",
    "FLUTTER_DEPS_DOC",
    "KERNEL_COMPILE_ATTRS",
    "PLATFORM_CONSTRAINT_ATTRS",
    "declare_flutter_assets_dir",
    "flutter_build_assets",
    "flutter_compile_shaders",
    "flutter_web_shader_aspect",
    "make_web_wrapper_main_content",
    "merge_dart_defines",
    "resolve_exec_dart_vm",
    "resolve_flutter_sdk_info",
)
load("//flutter/private:flutter_info.bzl", "dedup_plugins")
load(
    "//flutter/private:flutter_kernel_module.bzl",
    "MODULAR_KERNEL_ATTRS",
    "flutter_kernel_module_aspect",
)
load(
    "//flutter/private:flutter_web_compile.bzl",
    "flutter_dart2js_action",
    "flutter_dart2wasm_action",
    "web_build_mode",
)
load("//flutter/private:plugin_registrant.bzl", "generate_dart_plugin_registrant")
load(
    "//flutter/private:validation.bzl",
    "escape_html",
    "validate_web_compiler_renderer",
    "web_renderer",
)

_INDEX_HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
  <base href="$FLUTTER_BASE_HREF">
  <meta charset="UTF-8">
  <meta content="IE=Edge" http-equiv="X-UA-Compatible">
  <title>{title}</title>
</head>
<body>
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
"""

_BOOTSTRAP_JS_TEMPLATE = """\
{{flutter_build_config}}
{
  let script = document.createElement("script");
  script.src = "flutter.js";
  script.addEventListener("load", function() {
    _flutter.loader.load();
  });
  document.head.appendChild(script);
}
"""

_MANIFEST_JSON_TEMPLATE = """\
{{
    "name": "{name}",
    "short_name": "{name}",
    "start_url": ".",
    "display": "standalone",
    "background_color": "#0175C2",
    "theme_color": "#0175C2",
    "description": "A Flutter web integration test.",
    "orientation": "portrait-primary",
    "prefer_related_applications": false
}}
"""

_VERSION_JSON_TEMPLATE = """\
{{
    "app_name": "{app_name}",
    "version": "1.0.0",
    "build_number": "1",
    "package_name": "{app_name}"
}}
"""

def _build_config_js(engine_revision, builds):
    config = {
        "engineRevision": engine_revision,
        "builds": builds,
        "useLocalCanvasKit": True,
    }
    return """if (!window._flutter) {
  window._flutter = {};
}
_flutter.buildConfig = %s;
""" % json.encode(config)

def _wasm_build(renderer):
    return {
        "compileTarget": "dart2wasm",
        "renderer": renderer,
        "mainWasmPath": "main.dart.wasm",
        "jsSupportRuntimePath": "main.dart.mjs",
    }

_JS_BUILD = {
    "compileTarget": "dart2js",
    "renderer": "canvaskit",
    "mainJsPath": "main.dart.js",
}

def _exposes_package(deps, names):
    """True if any dep transitively exposes one of `names`."""
    for dep in deps:
        if DartInfo not in dep:
            continue
        for pkg in dep[DartInfo].transitive_packages.to_list():
            if pkg.package_name in names:
                return True
    return False

def make_web_integration_bootstrap_content(test_import, has_integration_test = False):
    """Generate the per-target web integration test bootstrap Dart source.

    The generated file is wrapped by `make_web_wrapper_main_content` so
    `ui_web.bootstrapEngine` initializes the Flutter web engine and implicit
    view before calling `main()` here.

    Args:
        test_import: Import URI for the user's integration test entrypoint.
        has_integration_test: Whether `deps` exposes `package:integration_test`.

    Returns:
        Dart source string.
    """
    if has_integration_test:
        binding_import = "import 'package:integration_test/integration_test.dart';\n"
        binding_decl = ""
        binding_init = "IntegrationTestWidgetsFlutterBinding.ensureInitialized();"
    else:
        binding_import = ""
        binding_decl = """
class _IntegrationTestBinding extends LiveTestWidgetsFlutterBinding {
  static _IntegrationTestBinding? _instance;

  @override
  void initInstances() {
    super.initInstances();
    _instance = this;
  }

  static _IntegrationTestBinding ensureInitialized() {
    if (_instance == null) {
      _IntegrationTestBinding();
    }
    return _instance!;
  }

  @override
  bool get overrideHttpClient => false;

  @override
  bool get registerTestTextInput => false;

  Size? _surfaceSize;

  @override
  Future<void> setSurfaceSize(Size? size) {
    return TestAsyncUtils.guard<void>(() async {
      assert(inTest);
      if (_surfaceSize == size) {
        return;
      }
      _surfaceSize = size;
      handleMetricsChanged();
    });
  }

  @override
  ViewConfiguration createViewConfigurationFor(RenderView renderView) {
    final FlutterView view = renderView.flutterView;
    final Size? surfaceSize =
        view == platformDispatcher.implicitView ? _surfaceSize : null;
    return TestViewConfiguration.fromView(
      size: surfaceSize ?? view.physicalSize / view.devicePixelRatio,
      view: view,
    );
  }

  @override
  void setLabel(String value) {}

  @override
  void reportExceptionNoticed(FlutterErrorDetails exception) {}
}
"""
        binding_init = "_IntegrationTestBinding.ensureInitialized();"

    return """// GENERATED by flutter_integration_test — do not edit.
// ignore_for_file: type=lint

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:test_api/backend.dart';
{binding_import}import '{test_import}' as test_entrypoint;

@JS('window')
external _JSWindow get _window;

extension type _JSWindow._(JSObject _) implements JSObject {{
  external _JSLocation get location;
  external void addEventListener(String type, JSFunction listener);
}}

extension type _JSLocation._(JSObject _) implements JSObject {{
  external String get host;
  external String get protocol;
}}

@JS('WebSocket')
extension type _JSWebSocket._(JSObject _) implements JSObject {{
  external factory _JSWebSocket(String url);
  external int get readyState;
  external void send(String data);
  external void close();
  external void addEventListener(String type, JSFunction listener);
}}

extension type _JSMessageEvent._(JSObject _) implements JSObject {{
  external JSAny? get data;
}}

extension type _JSErrorEvent._(JSObject _) implements JSObject {{
  external String? get message;
  external JSAny? get error;
}}

extension type _JSPromiseRejectionEvent._(JSObject _) implements JSObject {{
  external JSAny? get reason;
}}
{binding_decl}
bool _bindingInitialized = false;

bool _isBindingInTest() {{
  return _bindingInitialized && TestWidgetsFlutterBinding.instance.inTest;
}}

Future<void> _runTestMain() async {{
  debugPrint = debugPrintSynchronously;
  {binding_init}
  debugPrint = debugPrintSynchronously;
  reportTestException = (FlutterErrorDetails details, String testDescription) {{
    debugPrint = debugPrintSynchronously;
    FlutterError.dumpErrorToConsole(details, forceReport: true);
    final String additional = testDescription.isNotEmpty
        ? '\\nThe test description was: $testDescription'
        : '';
    registerException(
      TestFailure('${{details.exceptionAsString()}}$additional'),
      details.stack ?? StackTrace.current,
    );
  }};
  _bindingInitialized = true;
  await Future(test_entrypoint.main);
}}

Future<void> main() async {{
  final wsScheme = _window.location.protocol == 'https:' ? 'wss' : 'ws';
  final wsUrl = '$wsScheme://${{_window.location.host}}/__flutter_integration_ws__';
  final ws = _JSWebSocket(wsUrl);

  final openCompleter = Completer<void>();
  ws.addEventListener(
    'open',
    ((JSObject _) {{
      if (!openCompleter.isCompleted) {{
        openCompleter.complete();
      }}
    }}).toJS,
  );
  ws.addEventListener(
    'error',
    ((JSObject _) {{
      if (!openCompleter.isCompleted) {{
        openCompleter.completeError(
          StateError('Failed to connect to integration test harness at $wsUrl'),
        );
      }}
    }}).toJS,
  );
  if (ws.readyState == 1 && !openCompleter.isCompleted) {{
    openCompleter.complete();
  }}

  void sendToHarness(Object? payload) {{
    if (ws.readyState == 1) {{
      ws.send(json.encode(payload));
    }}
  }}

  void reportUncaughtError(Object error, StackTrace? stack) {{
    final effectiveStack = stack ?? StackTrace.current;
    sendToHarness(<String, Object?>{{
      'type': 'uncaughtError',
      'message': error.toString(),
      'stack': effectiveStack.toString(),
    }});
    if (_isBindingInTest()) {{
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: effectiveStack,
          library: 'flutter_integration_test',
          context: ErrorDescription('while running integration test'),
        ),
      );
    }}
  }}

  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {{
    reportUncaughtError(error, stack);
    return true;
  }};

  final FlutterExceptionHandler? prevOnError = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {{
    prevOnError?.call(details);
    if (!_isBindingInTest()) {{
      sendToHarness(<String, Object?>{{
        'type': 'uncaughtError',
        'message': details.exceptionAsString(),
        'stack': (details.stack ?? StackTrace.current).toString(),
      }});
    }}
  }};

  _window.addEventListener(
    'error',
    ((JSObject rawEvent) {{
      final event = _JSErrorEvent._(rawEvent);
      final msg =
          event.message ??
          event.error?.dartify()?.toString() ??
          'Uncaught window error';
      reportUncaughtError(msg, StackTrace.current);
    }}).toJS,
  );

  _window.addEventListener(
    'unhandledrejection',
    ((JSObject rawEvent) {{
      final event = _JSPromiseRejectionEvent._(rawEvent);
      final reason =
          event.reason?.dartify()?.toString() ?? 'Unhandled promise rejection';
      reportUncaughtError(reason, StackTrace.current);
    }}).toJS,
  );

  final testChannel = RemoteListener.start(() => _runTestMain);

  ws.addEventListener(
    'message',
    ((JSObject rawEvent) {{
      final event = _JSMessageEvent._(rawEvent);
      final data = event.data;
      if (data != null) {{
        final text = (data as JSString).toDart;
        testChannel.sink.add(json.decode(text));
      }}
    }}).toJS,
  );
  ws.addEventListener(
    'close',
    ((JSObject _) {{
      testChannel.sink.close();
    }}).toJS,
  );

  await openCompleter.future;
  await for (final dynamic message in testChannel.stream) {{
    sendToHarness(message);
  }}
}}
""".format(
        binding_import = binding_import,
        test_import = test_import,
        binding_decl = binding_decl,
        binding_init = binding_init,
    )

def _resolve_main_and_srcs(ctx):
    """Resolve the integration test entrypoint File and additional source Files."""
    if ctx.file.main != None:
        main_file = ctx.file.main
        extra_srcs = [
            f
            for f in (ctx.files.srcs + ctx.files.app_srcs)
            if f != main_file
        ]
        return main_file, extra_srcs

    if len(ctx.files.srcs) == 1:
        main_file = ctx.files.srcs[0]
        extra_srcs = [f for f in ctx.files.app_srcs if f != main_file]
        return main_file, extra_srcs

    test_candidates = [
        f
        for f in ctx.files.srcs
        if f.short_path.endswith("_test.dart")
    ]
    if len(test_candidates) == 1:
        main_file = test_candidates[0]
        extra_srcs = [
            f
            for f in (ctx.files.srcs + ctx.files.app_srcs)
            if f != main_file
        ]
        return main_file, extra_srcs

    fail(
        "%s: specify `main` (or pass a single test file in `srcs`)." % ctx.label,
    )

def _flutter_integration_test_impl(ctx):
    if ctx.attr.platform != "web":
        fail(
            "%s: flutter_integration_test does not yet support platform = %r " % (
                ctx.label,
                ctx.attr.platform,
            ) + "(supported: \"web\").",
        )

    if not _exposes_package(ctx.attr.deps, ["flutter_test"]):
        fail((
            "flutter_integration_test target {name} must depend on " +
            "package:flutter_test. Add `@<hub>//:flutter_test` to deps."
        ).format(name = ctx.label.name))

    main_file, extra_srcs = _resolve_main_and_srcs(ctx)

    renderer = web_renderer(ctx.attr.compiler, ctx.attr.renderer)
    validate_web_compiler_renderer(ctx.attr.compiler, renderer)

    flutter_sdk_info = resolve_flutter_sdk_info(ctx)
    user_defines = merge_dart_defines(ctx)
    mode = web_build_mode(ctx)
    is_debug = mode == "debug"

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

    pc = compile_package_config(ctx, packages, all_srcs + [main_file])
    config_file = pc.config_file
    all_srcs = pc.srcs

    # Step 1a: Generate the test bootstrap `<name>_bootstrap.dart`.
    bootstrap = ctx.actions.declare_file(ctx.label.name + "_bootstrap.dart")
    bootstrap_depth = len(bootstrap.dirname.split("/"))
    test_import = resolve_wrapper_main_import(
        package_name,
        lib_root,
        main_file.short_path,
        main_file.path,
        bootstrap_depth,
    )
    has_integration_test = _exposes_package(ctx.attr.deps, ["integration_test"])
    ctx.actions.write(
        bootstrap,
        make_web_integration_bootstrap_content(
            test_import = test_import,
            has_integration_test = has_integration_test,
        ),
    )

    # Step 1b: Wrap `<name>_bootstrap.dart` with `ui_web.bootstrapEngine()` so
    # the Flutter web engine creates its implicit view before running the test.
    all_dep_plugins = []
    for dep in ctx.attr.deps:
        if FlutterInfo in dep:
            all_dep_plugins.extend(dep[FlutterInfo].plugins)
    plugins = dedup_plugins(all_dep_plugins)
    registrant = generate_dart_plugin_registrant(ctx, plugins, target_platform = "web")

    wrapper = ctx.actions.declare_file(ctx.label.name + "_wrapper_main.dart")
    wrapper_content = make_web_wrapper_main_content(
        bootstrap.basename,
        registrant.basename if registrant else None,
    )
    ctx.actions.write(wrapper, wrapper_content)
    entrypoint = wrapper
    extra_wrapper_srcs = [main_file, bootstrap, wrapper]
    if registrant:
        extra_wrapper_srcs.append(registrant)
    all_srcs = all_srcs + extra_wrapper_srcs

    # Step 2: Compile to JS or WASM.
    web_sdk_file_list = ctx.attr._web_sdk.files.to_list() if ctx.attr._web_sdk else []
    dart2js_web_sdk_files = [
        f
        for f in web_sdk_file_list
        if f.path.endswith("/libraries.json")
    ]
    compile_outputs = []
    compile_copies = []
    dart2js_dirs = []

    exec_dart, dart_vm_files = resolve_exec_dart_vm(ctx, flutter_sdk_info)
    web_compile_inputs = [
        f
        for f in dart_vm_files.to_list()
        if f.basename in ("dartvm", "dartvm.exe")
    ]
    if ctx.attr.compiler == "dart2wasm":
        output_wasm = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm")
        output_mjs = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.mjs")
        output_wasm_map = None
        if ctx.attr.source_maps:
            output_wasm_map = ctx.actions.declare_file(ctx.label.name + "_wasm/main.dart.wasm.map")
        flutter_dart2wasm_action(
            ctx = ctx,
            dart = exec_dart,
            flutter_sdk_files = flutter_sdk_info.dart2wasm_files,
            dart2wasm_platform_dill = ctx.file._dart2wasm_platform_dill,
            main_dart = entrypoint,
            srcs = all_srcs,
            package_config = config_file,
            output_wasm = output_wasm,
            output_mjs = output_mjs,
            mode = mode,
            output_source_map = output_wasm_map,
            optimization_level = ctx.attr.optimization_level_wasm,
            strip_wasm = ctx.attr.strip_wasm,
            minify = ctx.attr.minify_wasm,
            enable_experiments = ctx.attr.enable_experiments,
            defines = user_defines,
            renderer = renderer,
            web_compile_tool = ctx.executable._web_template_tool,
            web_compile_inputs = web_compile_inputs,
        )
        compile_outputs = [output_wasm, output_mjs]
        compile_copies = [
            {"src": output_wasm.path, "dst": "main.dart.wasm"},
            {"src": output_mjs.path, "dst": "main.dart.mjs"},
        ]
        if output_wasm_map != None:
            compile_outputs.append(output_wasm_map)
            compile_copies.append({"src": output_wasm_map.path, "dst": "main.dart.wasm.map"})
        builds = [_wasm_build(renderer)]
    else:
        output_js_dir = ctx.actions.declare_directory(ctx.label.name + "_dart2js")
        flutter_dart2js_action(
            ctx = ctx,
            dart = exec_dart,
            flutter_sdk_files = flutter_sdk_info.dart2js_files,
            web_sdk_files = dart2js_web_sdk_files,
            dart2js_platform_dill = ctx.file._dart2js_platform_dill,
            main_dart = entrypoint,
            srcs = all_srcs,
            package_config = config_file,
            output_dir = output_js_dir,
            mode = mode,
            optimization_level = ctx.attr.optimization_level_js,
            minify = ctx.attr.minify_js,
            native_null_assertions = ctx.attr.native_null_assertions,
            frequency_based_minification = ctx.attr.frequency_based_minification,
            enable_experiments = ctx.attr.enable_experiments,
            dump_info = False,
            source_maps = ctx.attr.source_maps,
            defines = user_defines,
            renderer = renderer,
            web_compile_tool = ctx.executable._web_template_tool,
            web_compile_inputs = web_compile_inputs,
        )
        dart2js_dirs = [output_js_dir]
        builds = [_JS_BUILD]

    # Step 3: Compile shaders + bundle assets.
    compiled_shaders = flutter_compile_shaders(ctx, flutter_sdk_info, "web")
    flutter_assets = declare_flutter_assets_dir(ctx)
    flutter_build_assets(
        ctx,
        flutter_sdk_info,
        flutter_assets,
        compiled_shaders,
        kernel_dill = None,
        is_debug = is_debug,
    )

    # Step 4: Generate web templates (index.html, flutter_bootstrap.js, manifest.json, version.json).
    safe_title = escape_html(ctx.label.name)
    index_template = ctx.actions.declare_file(ctx.label.name + "_index_template.html")
    ctx.actions.write(index_template, _INDEX_HTML_TEMPLATE.format(title = safe_title))

    bootstrap_template = ctx.actions.declare_file(ctx.label.name + "_bootstrap_template.js")
    ctx.actions.write(bootstrap_template, _BOOTSTRAP_JS_TEMPLATE)

    manifest_json = ctx.actions.declare_file(ctx.label.name + "_manifest.json")
    ctx.actions.write(manifest_json, _MANIFEST_JSON_TEMPLATE.format(name = safe_title))

    version_json = ctx.actions.declare_file(ctx.label.name + "_version.json")
    ctx.actions.write(version_json, _VERSION_JSON_TEMPLATE.format(app_name = package_name))

    flutter_js_file = None
    renderer_files = []
    for f in web_sdk_file_list:
        if f.path.endswith("/flutter_js/flutter.js"):
            flutter_js_file = f
        if "/web-sdk/canvaskit/" in f.path:
            renderer_files.append(f)

    index_html = ctx.actions.declare_file(ctx.label.name + "_index.html")
    bootstrap_js = ctx.actions.declare_file(ctx.label.name + "_flutter_bootstrap.js")

    build_config = _build_config_js(flutter_sdk_info.engine_revision, builds)
    shared_builtins = {
        "flutter_build_config": {"value": build_config},
        "flutter_service_worker_version": {"value": "null"},
    }
    template_inputs = [index_template, bootstrap_template]
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
                "template": bootstrap_template.path,
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
                "template": index_template.path,
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
        executable = exec_dart,
        arguments = [
            ctx.executable._web_template_tool.path,
            "--config",
            template_config_file.path,
        ],
        inputs = depset(
            direct = template_inputs + [template_config_file, ctx.executable._web_template_tool],
            transitive = [dart_vm_files],
        ),
        outputs = [index_html, bootstrap_js],
        mnemonic = "FlutterWebTemplate",
        progress_message = "Substituting web templates for %s" % ctx.label,
    )

    # Step 5: Assemble web bundle directory.
    output_dir = ctx.actions.declare_directory(ctx.label.name + "_web")
    copies = list(compile_copies)
    copies.extend([
        {"src": index_html.path, "dst": "index.html"},
        {"src": bootstrap_js.path, "dst": "flutter_bootstrap.js"},
        {"src": manifest_json.path, "dst": "manifest.json"},
        {"src": version_json.path, "dst": "version.json"},
    ])
    engine_inputs = []
    if flutter_js_file:
        copies.append({"src": flutter_js_file.path, "dst": "flutter.js"})
        engine_inputs.append(flutter_js_file)
    for f in renderer_files:
        idx = f.path.find("/web-sdk/canvaskit/")
        if idx >= 0:
            rel = "canvaskit/" + f.path[idx + len("/web-sdk/canvaskit/"):]
            copies.append({"src": f.path, "dst": rel})
            engine_inputs.append(f)

    copy_dirs = [{"src": flutter_assets.path, "dst": "assets"}]
    for d in dart2js_dirs:
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

    all_bundle_inputs = (
        compile_outputs +
        dart2js_dirs +
        engine_inputs +
        [flutter_assets, index_html, bootstrap_js, manifest_json, version_json, bundle_config_file]
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

    # Step 6: Symlink the runner executable and wire test environment + runfiles.
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

    workspace_name = ctx.workspace_name
    env = {
        "FLUTTER_INTEGRATION_TEST_PLATFORM": ctx.attr.platform,
        "FLUTTER_INTEGRATION_TEST_WEB_DIR": runfiles_path(output_dir, workspace_name),
        "FLUTTER_INTEGRATION_TEST_BROWSER": runfiles_path(ctx.file._chrome_headless_shell, workspace_name),
        "FLUTTER_INTEGRATION_TEST_FONTCONFIG": runfiles_path(ctx.file._chrome_fontconfig, workspace_name),
        "FLUTTER_INTEGRATION_TEST_ROBOTO_FONT": runfiles_path(ctx.file._roboto_font, workspace_name),
        "FLUTTER_INTEGRATION_TEST_PATH": main_file.short_path,
    }
    for key, value in ctx.attr.env.items():
        if key in env:
            fail((
                "flutter_integration_test {name}: env key {key} is set by the " +
                "rule itself and cannot be overridden."
            ).format(name = ctx.label.name, key = key))
        env[key] = value

    env_info = testing.TestEnvironment(env)

    runtime_files = [
        output_dir,
        ctx.file._chrome_headless_shell,
        ctx.file._chrome_fontconfig,
        ctx.file._roboto_font,
    ] + ctx.attr._chrome_all_files.files.to_list()
    tool_runfiles = tool[DefaultInfo].default_runfiles
    runfiles = ctx.runfiles(
        files = runtime_files + ctx.files.data,
    )
    runfiles = runfiles.merge(tool_runfiles)
    for data_target in ctx.attr.data:
        runfiles = runfiles.merge(data_target[DefaultInfo].default_runfiles)

    instrumented_files_info = coverage_common.instrumented_files_info(
        ctx,
        source_attributes = ["srcs", "app_srcs", "main"],
        dependency_attributes = ["deps"],
    )

    prefix = package_lib_prefix(lib_root)
    in_pkg_srcs = []
    non_pkg_srcs = []
    for f in [main_file] + extra_srcs:
        if f.short_path.startswith(prefix):
            in_pkg_srcs.append(f)
        else:
            non_pkg_srcs.append(f)

    analyzable_info = dart_analyzable_info_with_package(
        label = ctx.label,
        package_name = package_name,
        lib_root = lib_root,
        deps = ctx.attr.deps + [ctx.attr._sky_engine],
        srcs = non_pkg_srcs,
        package_srcs = in_pkg_srcs,
        language_version = ctx.attr.language_version,
    )

    return [
        DefaultInfo(
            executable = executable,
            runfiles = runfiles,
        ),
        env_info,
        instrumented_files_info,
        analyzable_info,
    ]

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

_INTEGRATION_TEST_ATTRS = KERNEL_COMPILE_ATTRS | {
    k: v
    for k, v in FLUTTER_APPLICATION_ATTRS.items()
    if k in _WEB_RELEVANT_KEYS
}
_INTEGRATION_TEST_ATTRS["main"] = attr.label(
    doc = "The integration test .dart entry point. Optional when `srcs` " +
          "contains a single `.dart` file.",
    allow_single_file = [".dart"],
)
_INTEGRATION_TEST_ATTRS["package_name"] = attr.string(
    doc = "Dart package name (from pubspec.yaml). Defaults to target name.",
)
_INTEGRATION_TEST_ATTRS["app_srcs"] = attr.label_list(
    doc = "Dart source files for the application under test (e.g. `[\"lib/main.dart\"]`).",
    allow_files = [".dart"],
)
_INTEGRATION_TEST_ATTRS["deps"] = attr.label_list(
    doc = FLUTTER_DEPS_DOC,
    providers = [DartInfo],
    aspects = [flutter_web_shader_aspect, flutter_kernel_module_aspect],
)
_INTEGRATION_TEST_ATTRS["tree_shake_icons"] = attr.bool(
    doc = "Whether to tree-shake icon fonts in non-debug builds.",
    default = False,
)
_INTEGRATION_TEST_ATTRS["platform"] = attr.string(
    doc = "Target platform to run the integration test on ('web', 'linux', or 'android').",
    default = "web",
    values = ["web", "linux", "android"],
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
_INTEGRATION_TEST_ATTRS["profile"] = attr.bool(
    doc = "Whether to compile in profile mode.",
    default = False,
)
_INTEGRATION_TEST_ATTRS["data"] = attr.label_list(
    allow_files = True,
    doc = "Runtime data files made available in test runfiles.",
)
_INTEGRATION_TEST_ATTRS["env"] = attr.string_dict(
    doc = "Extra environment variables for the test runner process.",
)
_INTEGRATION_TEST_ATTRS.update(PLATFORM_CONSTRAINT_ATTRS)
_INTEGRATION_TEST_ATTRS.update(MODULAR_KERNEL_ATTRS)
_INTEGRATION_TEST_ATTRS["_tool"] = attr.label(
    default = Label("//flutter/private/tools:flutter_integration_test_runner"),
    executable = True,
    cfg = "exec",
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
)
_INTEGRATION_TEST_ATTRS["_dart2js_platform_dill"] = attr.label(
    default = Label("@flutter_web_sdk//:web-sdk/kernel/dart2js_platform.dill"),
    allow_single_file = True,
)
_INTEGRATION_TEST_ATTRS["_web_sdk"] = attr.label(
    default = Label("@flutter_web_sdk//:web_sdk"),
)
_INTEGRATION_TEST_ATTRS["_bundle_tool"] = attr.label(
    default = Label("//flutter/private/tools:bundle_app"),
    executable = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_web_template_tool"] = attr.label(
    default = Label("//flutter/private/tools:web_template"),
    executable = True,
    cfg = "exec",
)
_INTEGRATION_TEST_ATTRS["_sky_engine"] = attr.label(
    default = Label("@flutter_sky_engine//:sky_engine"),
    providers = [DartInfo],
)

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
    ] + COPY_TO_DIRECTORY_TOOLCHAINS + MODULAR_KERNEL_TOOLCHAINS,
    doc = "Compiles a Flutter app with an in-app integration test and runs it on the target platform.",
)

def flutter_integration_test(
        name,
        package_name = "",
        deps = [],
        app_deps = [],
        app = None,
        **kwargs):
    """Builds and runs an end-to-end Flutter integration test on a real platform.

    Compiles the application and the integration test (`WidgetTester` code) into
    a real platform bundle and drives it via the platform runner. On `web`, the
    built web bundle is served from `127.0.0.1` and executed inside a hermetic,
    pinned `chrome-headless-shell` browser.

    Args:
        name: Target name.
        package_name: Dart package name (from `pubspec.yaml`). Defaults to `name`.
        deps: Dependencies (`dart_library` / `flutter_library`) for the test and app.
        app_deps: Optional additional dependencies for the app, merged with `deps`.
        app: Optional library target for the app under test, merged with `deps`.
        **kwargs: Additional attributes forwarded to the rule (`main`, `srcs`,
            `app_srcs`, `platform`, `assets`, `shaders`, `compiler`, `renderer`,
            `defines`, `data`, `env`, etc.).
    """
    merged_deps = list(deps)
    for extra in list(app_deps) + ([app] if app != None else []):
        if extra not in merged_deps:
            merged_deps.append(extra)

    _flutter_integration_test(
        name = name,
        package_name = package_name or name,
        deps = merged_deps,
        **kwargs
    )
