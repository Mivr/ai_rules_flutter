/// Shared platform-launcher interface for `flutter_integration_test`.
///
/// Imported by the runner harness and by each platform launcher, so no
/// platform launcher ever imports the runner's main library.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'test_support.dart';

/// WebSocket upgrade path the in-app bootstrap dials on the harness server.
const String integrationWebSocketPath = '/__flutter_integration_ws__';

/// Decodes the JSON-encoded declared environment forwarded by
/// `flutter_integration_test.bzl` (`FLUTTER_INTEGRATION_TEST_DECLARED_ENV`).
/// Decodes the JSON map stored in a `*_DECLARED_ENV` launcher variable.
///
/// Public, like [buildChromeArguments], because the test reaches it
/// directly. A missing variable or a malformed payload decodes to an empty
/// map: a build that received no usable declared environment falls back to
/// inherited-environment-only resolution, and a missing variable surfaces
/// later as a concrete lookup error instead.
Map<String, String> decodeDeclaredEnv(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const <String, String>{};
  try {
    final decoded = json.decode(raw);
    if (decoded is Map) {
      return decoded.map(
        (key, value) => MapEntry(key.toString(), value.toString()),
      );
    }
  } on FormatException {
    // Corrupted declared environment behaves like none at all.
  }
  return const <String, String>{};
}

/// Resolves the forwarded ambient values for the `build*Environment`
/// helpers: the declared entries (empty when nothing was forwarded) and the
/// effective timezone, where a declared `TZ` entry wins.
///
/// One helper for all three builders, so the resolution they used to copy
/// stays identical everywhere.
({Map<String, String> declared, String timeZone, String? fontconfigFile})
resolveForwarding(EnvForwarding forwarding) {
  final declared = forwarding.env ?? const <String, String>{};
  return (
    declared: declared,
    timeZone: declared['TZ'] ?? forwarding.tz ?? 'UTC',
    fontconfigFile: forwarding.fontconfigFile,
  );
}

/// Abstraction over how a target platform starts the compiled app and serves
/// any platform-specific HTTP endpoints on the harness [HttpServer].
abstract class PlatformLauncher {
  /// Platform identifier (`'web'`, `'linux'`, `'android'`).
  String get platformName;

  /// Runtime identifier for `package:test_api` `SuitePlatform`.
  String get suiteRuntime;

  /// Compiler identifier for `package:test_api` `SuitePlatform`.
  String get suiteCompiler;

  /// Handles a non-WebSocket HTTP request arriving on the harness server.
  Future<void> handleHttpRequest(HttpRequest request);

  /// Starts the target process against a harness listening on [harnessPort].
  Future<Process> startTarget(int harnessPort);

  /// Cleans up any temporary directories created for the target process.
  Future<void> dispose();
}
