// Tagged `runfiles`: this test imports `package:runfiles` to read the shell
// counterpart handed to it through the `RUN_HOME_BZL` runfiles path, supplied
// via the `@rules_dart//dart/runfiles` dep its `dart_test` declares. A bare
// `dart test` resolves only this package's pubspec, where that import does
// not exist, so the file fails to load rather than failing a test.
// Coverage comes from //flutter/private/tools:run_home_test.
@Tags(['runfiles'])
library;

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

// The shared classification table (FF-herm-dart-fileform, ledger row
// opus-2026-10-26:L-1): every row states the `dart` CLI arguments and the
// exact argv the launcher must exec. The Dart unit test and the bash
// launcher test below run this same table, and the Windows `.bat` in
// `//dart:flutter_sdk_binary` mirrors it, so the three launchers agree.
const _classificationTable = <({List<String> args, List<String> want})>[
  // No args: file form, passes through unchanged.
  (args: [], want: []),
  // Global flags only: file form, unchanged (the VM rejects the flag).
  (args: ['--version'], want: ['--version']),
  (args: ['--verbose'], want: ['--verbose']),
  // Program files: file form, unchanged.
  (args: ['hello.dart'], want: ['hello.dart']),
  (
    args: ['--enable-asserts', 'hello.dart'],
    want: ['--enable-asserts', 'hello.dart'],
  ),
  (args: ['HELLO.DART'], want: ['HELLO.DART']),
  (args: ['app.dill'], want: ['app.dill']),
  (args: ['APP.SNAPSHOT'], want: ['APP.SNAPSHOT']),
  (args: ['app.aot'], want: ['app.aot']),
  (args: ['app.jit'], want: ['app.jit']),
  // Commands: the flag is prepended, nothing else reordered.
  (
    args: ['pub', 'get'],
    want: ['--suppress-analytics', 'pub', 'get'],
  ),
  (
    args: ['--verbose', 'pub', 'get'],
    want: ['--suppress-analytics', '--verbose', 'pub', 'get'],
  ),
  (
    args: ['-v', 'format', '.'],
    want: ['--suppress-analytics', '-v', 'format', '.'],
  ),
  (
    args: ['run', 'hello.dart'],
    want: ['--suppress-analytics', 'run', 'hello.dart'],
  ),
  // An already-held flag passes through, never duplicated.
  (
    args: ['--suppress-analytics', 'pub', 'get'],
    want: ['--suppress-analytics', 'pub', 'get'],
  ),
  (
    args: ['--no-suppress-analytics', 'pub', 'get'],
    want: ['--no-suppress-analytics', 'pub', 'get'],
  ),
];

// The `RUN_HOME_SH` snippet, extracted from the `.bzl` source so the bash
// test below executes the shipped text, not a copy.
String _runHomeSnippet() {
  final bzl = _runHomeBzl();
  const marker = 'RUN_HOME_SH = """\\\n';
  final start = bzl.indexOf(marker);
  if (start < 0) fail('RUN_HOME_SH block not found in run_home.bzl.');
  final end = bzl.indexOf('"""', start + marker.length);
  if (end < 0) fail('RUN_HOME_SH block is unterminated in run_home.bzl.');
  return bzl.substring(start + marker.length, end);
}

Future<bool> _bashAvailable() async {
  try {
    return (await Process.run('bash', ['--version'])).exitCode == 0;
  } on ProcessException {
    return false;
  }
}

// Runs the shipped `RUN_HOME_SH` snippet over [args] through a stub `dart`
// that records the argv it was execed with, and returns that argv.
Future<List<String>> _bashArgv(
  Directory scratch,
  String snippet,
  List<String> args,
) async {
  final stub = File('${scratch.path}/stub.sh');
  await stub.writeAsString(
    '#!/usr/bin/env bash\n'
    'echo stub-ran > "\$STUB_RAN"\n'
    'if (( \$# > 0 )); then printf \'%s\\n\' "\$@" > "\$STUB_OUT";'
    ' else : > "\$STUB_OUT"; fi\n',
  );
  final driver = File('${scratch.path}/driver.sh');
  await driver.writeAsString(
    '$snippet\nrun_home_caller_home_exec "\$STUB" "\$@"\n',
  );
  final out = File('${scratch.path}/out.txt');
  final ran = File('${scratch.path}/ran.txt');
  expect((await Process.run('chmod', ['+x', stub.path])).exitCode, 0);
  final result = await Process.run(
    'bash',
    [driver.path, ...args],
    environment: {
      'STUB': stub.path,
      'STUB_OUT': out.path,
      'STUB_RAN': ran.path,
    },
  );
  expect(result.exitCode, 0, reason: 'bash driver failed: ${result.stderr}');
  expect(ran.existsSync(), isTrue, reason: 'the stub was never execed');
  return out.readAsLinesSync();
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
      expect(
        run_home.withSuppressedAnalytics(['--no-suppress-analytics', 'pub']),
        ['--no-suppress-analytics', 'pub'],
      );
    });

    test('an empty argument list is file form and passes through', () {
      expect(run_home.withSuppressedAnalytics([]), isEmpty);
    });

    test('command form takes the flag, file form passes through', () {
      for (final row in _classificationTable) {
        expect(
          run_home.withSuppressedAnalytics(row.args),
          row.want,
          reason: 'args ${row.args}',
        );
      }
    });

    test(
      'the bash launcher classifies the shared table the same way',
      () async {
        if (!await _bashAvailable()) {
          markTestSkipped('bash is not on PATH; the .bat covers Windows.');
        }
        final snippet = _runHomeSnippet();
        final scratch = Directory.systemTemp.createTempSync('run-home-bash-');
        try {
          for (final row in _classificationTable) {
            expect(
              await _bashArgv(scratch, snippet, row.args),
              row.want,
              reason: 'bash args ${row.args}',
            );
          }
        } finally {
          scratch.deleteSync(recursive: true);
        }
      },
    );
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

    test('the RUN_HOME_SH snippet classifies file form like the Dart', () {
      final snippet = _runHomeSnippet();
      // The already-present check covers both flags, leading dash-arguments
      // are skipped, and the program suffixes match the Dart table.
      expect(snippet, contains('"${run_home.noSuppressAnalyticsFlag}"'));
      expect(snippet, contains('== -*'));
      for (final suffix in run_home.programFileSuffixes) {
        expect(snippet, contains(suffix));
      }
    });
  });
}
