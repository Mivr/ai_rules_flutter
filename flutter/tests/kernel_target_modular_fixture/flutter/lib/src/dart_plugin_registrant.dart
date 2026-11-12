// Mirrors `packages/flutter/lib/src/dart_plugin_registrant.dart` in the SDK:
// unimported by any public `package:flutter` library, read by the engine hook.
@pragma('vm:entry-point')
const String dartPluginRegistrantLibrary = String.fromEnvironment(
  'flutter.dart_plugin_registrant',
);
