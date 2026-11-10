/// Verifies the code-size JSON produced by flutter_android_app with
/// analyze_size = True: valid JSON listing the app's own library.
library;

import 'dart:convert';
import 'dart:io';

void main() {
  final testSrcDir = Platform.environment['TEST_SRCDIR'];
  final testWorkspace = Platform.environment['TEST_WORKSPACE'];
  if (testSrcDir == null || testWorkspace == null) {
    stderr.writeln('Missing TEST_SRCDIR or TEST_WORKSPACE env vars');
    exit(1);
  }

  final defaultSizePath =
      '$testSrcDir/$testWorkspace/app_analyze_size_size.json';
  var sizeFile = File(defaultSizePath);
  if (!sizeFile.existsSync()) {
    final candidate = Directory('$testSrcDir/$testWorkspace')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('_size.json'))
        .firstOrNull;
    if (candidate != null) {
      sizeFile = candidate;
    }
  }

  if (!sizeFile.existsSync()) {
    stderr.writeln(
      'FAIL: size JSON not found at $defaultSizePath or in $testSrcDir/$testWorkspace',
    );
    exit(1);
  }

  stdout.writeln('Reading size JSON from ${sizeFile.path}');
  final content = sizeFile.readAsStringSync();
  final dynamic decoded;
  try {
    decoded = json.decode(content);
  } catch (e) {
    stderr.writeln('FAIL: size JSON is not valid JSON: $e');
    exit(1);
  }

  if (decoded == null) {
    stderr.writeln('FAIL: size JSON parsed to null');
    exit(1);
  }

  final found = _containsAppLibrary(decoded, 'package:android_example/');
  if (!found) {
    stderr.writeln(
      'FAIL: size JSON does not list the app library (package:android_example/...)',
    );
    exit(1);
  }

  stdout.writeln(
    'OK: size JSON is valid and lists package:android_example/...',
  );
}

bool _containsAppLibrary(dynamic obj, String prefix) {
  if (obj is String) {
    return obj.startsWith(prefix);
  }
  if (obj is List) {
    for (final item in obj) {
      if (_containsAppLibrary(item, prefix)) {
        return true;
      }
    }
    return false;
  }
  if (obj is Map) {
    for (final entry in obj.entries) {
      if (_containsAppLibrary(entry.key, prefix) ||
          _containsAppLibrary(entry.value, prefix)) {
        return true;
      }
    }
    return false;
  }
  return false;
}
