import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../run_home.dart' as run_home;

// The shell counterpart (`RUN_HOME_SH` / `RUN_HOME_SUPPRESS_ANALYTICS` in
// `//flutter/private:run_home.bzl`) is handed to this test as a runfiles
// path via the `RUN_HOME_BZL` env var, so the agreement checks below fail
// the moment the two copies drift apart.
String _runHomeBzl() {
  final rel = Platform.environment['RUN_HOME_BZL'];
  if (rel == null || rel.isEmpty) {
    fail('RUN_HOME_BZL is not set; run this through `bazel test`.');
  }
  return File(Runfiles.create().rlocation(rel)).readAsStringSync();
}

void main() {
  group('privateHomeEnv', () {
    test('covers every home-locating key at the given dir', () {
      final env = run_home.privateHomeEnv('/priv');
      expect(env.keys.toSet(), run_home.homeEnvKeys.toSet());
      expect(env.values.toSet(), {'/priv'});
    });

    test('covers the POSIX and Windows keys', () {
      expect(
        run_home.homeEnvKeys.toSet(),
        {
          'HOME',
          'USERPROFILE',
          'LOCALAPPDATA',
          'APPDATA',
          'XDG_CONFIG_HOME',
          'XDG_CACHE_HOME',
          'XDG_DATA_HOME',
        },
      );
    });
  });

  group('withSuppressedAnalytics', () {
    test('inserts the flag before the command', () {
      expect(
        run_home.withSuppressedAnalytics(['pub', 'token', 'list']),
        ['--suppress-analytics', 'pub', 'token', 'list'],
      );
    });

    test('never duplicates an already-present flag', () {
      expect(
        run_home.withSuppressedAnalytics(['--suppress-analytics', 'pub']),
        ['--suppress-analytics', 'pub'],
      );
    });

    test('a bare CLI still takes the flag', () {
      expect(run_home.withSuppressedAnalytics([]), ['--suppress-analytics']);
    });
  });

  group('createPrivateHome', () {
    test('makes a fresh dir the caller removes', () {
      final dir = run_home.createPrivateHome(Directory.systemTemp.path);
      try {
        expect(dir.existsSync(), isTrue);
      } finally {
        dir.deleteSync(recursive: true);
      }
      expect(dir.existsSync(), isFalse);
    });
  });

  group('shell counterpart agreement', () {
    test('the flag value is pinned', () {
      expect(run_home.suppressAnalyticsFlag, '--suppress-analytics');
    });

    test('run_home.bzl defines the same flag', () {
      expect(
        _runHomeBzl(),
        contains(
          'RUN_HOME_SUPPRESS_ANALYTICS = "${run_home.suppressAnalyticsFlag}"',
        ),
      );
    });

    test('the RUN_HOME_SH snippet passes the same flag', () {
      final bzl = _runHomeBzl();
      final snippet = bzl.substring(bzl.indexOf('run_home_caller_home_exec()'));
      // Both the already-present check and the insertion site spell the
      // flag literally, so a const-only change fails here until the
      // snippet follows.
      expect(snippet, contains('"${run_home.suppressAnalyticsFlag}"'));
      expect(snippet, contains('exec '));
    });
  });
}
