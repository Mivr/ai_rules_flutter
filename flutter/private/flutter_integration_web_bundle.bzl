"""Web bundle scaffolding for `flutter_integration_test`.

Moved out of `flutter_integration_test.bzl` so iOS support can extend that
file without growing it.
"""

INDEX_HTML_TEMPLATE = """<!DOCTYPE html>
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

BOOTSTRAP_JS_TEMPLATE = """\
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

MANIFEST_JSON_TEMPLATE = """\
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

VERSION_JSON_TEMPLATE = """\
{{
    "app_name": "{app_name}",
    "version": "1.0.0",
    "build_number": "1",
    "package_name": "{app_name}"
}}
"""

def build_config_js(engine_revision, builds):
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

def wasm_build(renderer):
    return {
        "compileTarget": "dart2wasm",
        "renderer": renderer,
        "mainWasmPath": "main.dart.wasm",
        "jsSupportRuntimePath": "main.dart.mjs",
    }

JS_BUILD = {
    "compileTarget": "dart2js",
    "renderer": "canvaskit",
    "mainJsPath": "main.dart.js",
}
