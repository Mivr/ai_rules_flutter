/// Both plugin registrants of the app name `shared_preferences_android`.
///
/// A missing registration is invisible at build time and surfaces on the
/// device as a `MissingPluginException` from `SharedPreferences.getInstance()`.
/// This test reads the two generated files the build produces and fails,
/// naming the plugin and the file, unless each registers it:
///
/// - the Dart registrant, by the plugin's `dartPluginClass`
///   (`SharedPreferencesAndroid`, from its `pubspec.yaml`), and
/// - the Android `GeneratedPluginRegistrant.java`, by its `pluginClass`
///   (`io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin`).
///
/// The Dart registrant is the Android one the dev loop compiles
/// (`app_flutter.dev_plugin_registrant.android.dart`), written by the same
/// generator, with `target_platform = android`, as the build's own registrant;
/// the workspace builds in `-c dbg` so that file is an output of the app.
library;

import 'dart:io';

const _plugin = 'shared_preferences_android';
const _dartPluginClass = 'SharedPreferencesAndroid';
const _javaPluginClass =
    'io.flutter.plugins.sharedpreferences.SharedPreferencesPlugin';

const _dartRegistrant = 'app_flutter.dev_plugin_registrant.android.dart';
const _javaRegistrant =
    'app_registrant/io/flutter/plugins/GeneratedPluginRegistrant.java';

String _read(String relativePath) {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  final workspace = Platform.environment['TEST_WORKSPACE'];
  if (srcDir == null || workspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }
  final file = File('$srcDir/$workspace/$relativePath');
  if (!file.existsSync()) {
    stderr.writeln('$relativePath was not generated (looked at ${file.path})');
    exit(1);
  }
  return file.readAsStringSync();
}

/// Reports a failure naming the missing plugin and the registrant file.
bool _check({
  required String file,
  required String content,
  required Pattern registration,
  required String what,
}) {
  if (content.contains(registration)) {
    stdout.writeln('ok: $file registers $_plugin ($what)');
    return true;
  }
  stderr
    ..writeln('FAIL: $file does not register $_plugin: no $what.')
    ..writeln('--- $file ---')
    ..writeln(content);
  return false;
}

void main() {
  final dart = _read(_dartRegistrant);
  final java = _read(_javaRegistrant);
  final results = [
    _check(
      file: _dartRegistrant,
      content: dart,
      registration: RegExp('\\b$_dartPluginClass\\.registerWith\\(\\)'),
      what: '$_dartPluginClass.registerWith() call',
    ),
    _check(
      file: _dartRegistrant,
      content: dart,
      registration: "import 'package:$_plugin/$_plugin.dart'",
      what: 'import of package:$_plugin',
    ),
    _check(
      file: _javaRegistrant,
      content: java,
      registration: RegExp(
        '\\.add\\(\\s*new\\s+${RegExp.escape(_javaPluginClass)}\\(\\)',
      ),
      what: 'plugins.add(new $_javaPluginClass()) call',
    ),
  ];
  if (results.contains(false)) {
    exit(1);
  }
}
