import 'package:flutter/flutter.dart';

/// Dart-side plugin class registered from the generated `_PluginRegistrant`.
class ModularFixturePlugin {
  static String? registeredWith;

  /// Called by `_PluginRegistrant.register()` before `main()`.
  static void registerWith() {
    registeredWith = flutterFrameworkMarker;
  }
}
