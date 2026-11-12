import 'dart:developer';

import 'package:flutter/flutter.dart';

/// Minimal stand-in for `agent.dart` exposing the entrypoints the generated
/// `_PluginRegistrant.register()` calls.
void registerRulesFlutterAgentExtensions() {
  registerExtension(
    'ext.rules_flutter.stubPing',
    (_, _) async => ServiceExtensionResponse.result(flutterFrameworkMarker),
  );
}

/// Receives the debug build-info JSON when an asset bundle is present.
void setRulesFlutterBuildInfo(String _) {}
