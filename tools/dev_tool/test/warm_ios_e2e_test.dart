import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/bazel.dart';
import 'package:flutter_bazel_dev_tool/device_ios_sim.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/warm_ios_e2e.dart';

class RecordedCall {
  final List<String> args;
  final String workingDirectory;

  const RecordedCall({required this.args, required this.workingDirectory});
}

void main() {
  group('WarmTarget and WarmFailure', () {
    test('WarmTarget supports equality and hashCode', () {
      const a = WarmTarget(workspace: 'e2e/ios_example', target: ':app');
      final b = WarmTarget(workspace: 'e2e/ios_example', target: ':app');
      const c = WarmTarget(
        workspace: 'e2e/plugin_example',
        target: ':plugin_ios',
      );

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('defaultWarmTargets has expected order and targets', () {
      expect(
        defaultWarmTargets,
        equals([
          const WarmTarget(workspace: 'e2e/ios_example', target: ':app'),
          const WarmTarget(
            workspace: 'e2e/plugin_example',
            target: ':plugin_ios',
          ),
        ]),
      );
    });

    test('WarmFailure supports equality, hashCode, and toString', () {
      const a = WarmFailure('err');
      final b = WarmFailure('err');
      const c = WarmFailure('other');

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), 'err');
    });
  });

  group('resolveWarmDiskCache', () {
    test('reads HOME on POSIX', () {
      final diskCache = resolveWarmDiskCache({
        'HOME': '/home/developer',
      }, isWindows: false);
      expect(diskCache, '/home/developer/.cache/rules_flutter_e2e_disk');
    });

    test(r'reads USERPROFILE when isWindows: true with \ normalized to /', () {
      final diskCache = resolveWarmDiskCache({
        'USERPROFILE': r'C:\Users\developer',
      }, isWindows: true);
      expect(diskCache, 'C:/Users/developer/.cache/rules_flutter_e2e_disk');
    });

    test('throws WarmFailure when unset or empty', () {
      expect(
        () => resolveWarmDiskCache({}, isWindows: false),
        throwsA(
          isA<WarmFailure>().having(
            (f) => f.reason,
            'reason',
            contains('HOME'),
          ),
        ),
      );
      expect(
        () => resolveWarmDiskCache({'HOME': ''}, isWindows: false),
        throwsA(
          isA<WarmFailure>().having(
            (f) => f.reason,
            'reason',
            contains('HOME'),
          ),
        ),
      );
      expect(
        () => resolveWarmDiskCache({'HOME': '   '}, isWindows: false),
        throwsA(
          isA<WarmFailure>().having(
            (f) => f.reason,
            'reason',
            contains('HOME'),
          ),
        ),
      );
      expect(
        () => resolveWarmDiskCache({}, isWindows: true),
        throwsA(
          isA<WarmFailure>().having(
            (f) => f.reason,
            'reason',
            contains('USERPROFILE'),
          ),
        ),
      );
      expect(
        () => resolveWarmDiskCache({'USERPROFILE': ''}, isWindows: true),
        throwsA(
          isA<WarmFailure>().having(
            (f) => f.reason,
            'reason',
            contains('USERPROFILE'),
          ),
        ),
      );
      expect(
        () => resolveWarmDiskCache({'USERPROFILE': '   '}, isWindows: true),
        throwsA(
          isA<WarmFailure>().having(
            (f) => f.reason,
            'reason',
            contains('USERPROFILE'),
          ),
        ),
      );
    });
  });

  group('warmRepoRootFor', () {
    test('is four levels above tools/dev_tool/tool/warm_ios_e2e.dart', () {
      final script = p.join(
        'repo root',
        'tools',
        'dev_tool',
        'tool',
        'warm_ios_e2e.dart',
      );
      expect(warmRepoRootFor(script), 'repo root');
    });
  });

  group('parseWarmTimeout', () {
    test('returns the 60-minute default on []', () {
      expect(parseWarmTimeout([]), const Duration(minutes: 60));
    });

    test('parses --timeout=<seconds>', () {
      expect(parseWarmTimeout(['--timeout=120']), const Duration(seconds: 120));
      expect(parseWarmTimeout(['--timeout=1']), const Duration(seconds: 1));
      expect(parseWarmTimeout(['--timeout=3600']), const Duration(hours: 1));
    });

    test(
      'throws WarmFailure on bare, malformed, negative, or unknown flags and positional arguments',
      () {
        final invalidArgs = [
          ['--timeout'],
          ['--timeout='],
          ['--timeout=0'],
          ['--timeout=-10'],
          ['--timeout=abc'],
          ['--timeout=1.5'],
          ['--timeout=+10'],
          ['--timeout= 10'],
          ['--timeout=010'],
          ['--timeout', '60'],
          ['--unknown'],
          ['positional'],
          ['--timeout=10', 'positional'],
          ['--timeout=10', '--timeout=20'],
        ];

        for (final args in invalidArgs) {
          expect(
            () => parseWarmTimeout(args),
            throwsA(
              isA<WarmFailure>().having(
                (f) => f.reason,
                'reason',
                contains('Usage:'),
              ),
            ),
            reason: 'Expected $args to be rejected with usage WarmFailure',
          );
        }
      },
    );
  });

  group('warmIosE2eBuilds', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('warm_ios_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    void createWorkspace(String relativePath) {
      final wsDir = Directory(p.join(tempDir.path, relativePath));
      wsDir.createSync(recursive: true);
      File(p.join(wsDir.path, 'MODULE.bazel')).writeAsStringSync('');
    }

    test(
      'defaultWarmTargets warms e2e/ios_example then e2e/plugin_example with exact bazelBuildArgs and shutdowns',
      () async {
        createWorkspace('e2e/ios_example');
        createWorkspace('e2e/plugin_example');

        final calls = <RecordedCall>[];
        final logs = <String>[];

        Future<WarmChild> fakeSpawner(
          List<String> args, {
          required String workingDirectory,
        }) async {
          calls.add(
            RecordedCall(args: args, workingDirectory: workingDirectory),
          );
          return WarmChild(
            exitCode: Future.value(0),
            stdoutText: Future.value(''),
            stderrText: Future.value(''),
            kill: () {},
          );
        }

        final options = WarmOptions(
          bazel: fakeSpawner,
          repoRoot: tempDir.path,
          environment: {'HOME': '/test/home'},
          log: logs.add,
        );

        await warmIosE2eBuilds(options);

        expect(calls.length, 4);

        final expectedDiskCache = '/test/home/.cache/rules_flutter_e2e_disk';
        final expectedIosArgs = bazelBuildArgs(
          ':app',
          compilationMode: 'dbg',
          extraArgs: [
            ...IOSSimulatorDevice(udid: 'warm').buildArgs,
            '--disk_cache=$expectedDiskCache',
            '--experimental_disk_cache_gc_max_size=50G',
            '--experimental_disk_cache_gc_max_age=30d',
          ],
        );
        final expectedPluginArgs = bazelBuildArgs(
          ':plugin_ios',
          compilationMode: 'dbg',
          extraArgs: [
            ...IOSSimulatorDevice(udid: 'warm').buildArgs,
            '--disk_cache=$expectedDiskCache',
            '--experimental_disk_cache_gc_max_size=50G',
            '--experimental_disk_cache_gc_max_age=30d',
          ],
        );

        final iosWs = p.join(tempDir.path, 'e2e/ios_example');
        final pluginWs = p.join(tempDir.path, 'e2e/plugin_example');

        expect(calls[0].workingDirectory, iosWs);
        expect(calls[0].args, expectedIosArgs);

        expect(calls[1].workingDirectory, iosWs);
        expect(calls[1].args, ['shutdown']);

        expect(calls[2].workingDirectory, pluginWs);
        expect(calls[2].args, expectedPluginArgs);

        expect(calls[3].workingDirectory, pluginWs);
        expect(calls[3].args, ['shutdown']);
      },
    );

    test('missing <workspace>/MODULE.bazel throws WarmFailure before spawning bazel', () async {
      // Do not create MODULE.bazel.
      final calls = <RecordedCall>[];
      final options = WarmOptions(
        bazel: (args, {required workingDirectory}) async {
          calls.add(
            RecordedCall(args: args, workingDirectory: workingDirectory),
          );
          return WarmChild(
            exitCode: Future.value(0),
            stdoutText: Future.value(''),
            stderrText: Future.value(''),
            kill: () {},
          );
        },
        repoRoot: tempDir.path,
        environment: {'HOME': '/test/home'},
        log: (_) {},
      );

      final expectedMissingPath = p.join(
        tempDir.path,
        'e2e/ios_example',
        'MODULE.bazel',
      );

      expect(
        () => warmIosE2eBuilds(options),
        throwsA(
          isA<WarmFailure>().having(
            (f) => f.reason,
            'reason',
            contains(expectedMissingPath),
          ),
        ),
      );
      expect(calls, isEmpty);
    });

    test(
      'non-zero build exit throws WarmFailure naming workspace, target, and exit code, still runs shutdown, and does not start next workspace build',
      () async {
        createWorkspace('e2e/ios_example');
        createWorkspace('e2e/plugin_example');

        final calls = <RecordedCall>[];
        final logs = <String>[];
        Future<WarmChild> fakeSpawner(
          List<String> args, {
          required String workingDirectory,
        }) async {
          calls.add(
            RecordedCall(args: args, workingDirectory: workingDirectory),
          );
          if (args.first == 'build') {
            return WarmChild(
              exitCode: Future.value(37),
              stdoutText: Future.value('build failure detail stdout'),
              stderrText: Future.value('build failure detail stderr'),
              kill: () {},
            );
          }
          return WarmChild(
            exitCode: Future.value(0),
            stdoutText: Future.value(''),
            stderrText: Future.value(''),
            kill: () {},
          );
        }

        final options = WarmOptions(
          bazel: fakeSpawner,
          repoRoot: tempDir.path,
          environment: {'HOME': '/test/home'},
          log: logs.add,
        );

        WarmFailure? caught;
        try {
          await warmIosE2eBuilds(options);
        } on WarmFailure catch (f) {
          caught = f;
        }

        expect(caught, isNotNull);
        expect(caught!.reason, contains('e2e/ios_example'));
        expect(caught.reason, contains(':app'));
        expect(caught.reason, contains('37'));

        expect(calls.length, 2);
        expect(calls[0].args.first, 'build');
        expect(calls[1].args, ['shutdown']);
        expect(
          calls[1].workingDirectory,
          p.join(tempDir.path, 'e2e/ios_example'),
        );
        expect(logs, contains('build failure detail stdout'));
        expect(logs, contains('build failure detail stderr'));
      },
    );

    test(
      'build hanging past buildTimeout kills child, relays output, throws WarmFailure naming workspace/target/elapsed, runs shutdown',
      () async {
        createWorkspace('e2e/ios_example');
        createWorkspace('e2e/plugin_example');

        final calls = <RecordedCall>[];
        final logs = <String>[];
        var buildKilled = false;
        final buildCompleter = Completer<int>();

        Future<WarmChild> fakeSpawner(
          List<String> args, {
          required String workingDirectory,
        }) async {
          calls.add(
            RecordedCall(args: args, workingDirectory: workingDirectory),
          );
          if (args.first == 'build') {
            return WarmChild(
              exitCode: buildCompleter.future,
              stdoutText: Future.value('timed out stdout output'),
              stderrText: Future.value('timed out stderr output'),
              kill: () {
                buildKilled = true;
                if (!buildCompleter.isCompleted) {
                  buildCompleter.complete(-1);
                }
              },
            );
          }
          return WarmChild(
            exitCode: Future.value(0),
            stdoutText: Future.value(''),
            stderrText: Future.value(''),
            kill: () {},
          );
        }

        final options = WarmOptions(
          bazel: fakeSpawner,
          repoRoot: tempDir.path,
          environment: {'HOME': '/test/home'},
          buildTimeout: const Duration(milliseconds: 30),
          log: logs.add,
        );

        WarmFailure? caught;
        try {
          await warmIosE2eBuilds(options);
        } on WarmFailure catch (f) {
          caught = f;
        }

        expect(caught, isNotNull);
        expect(caught!.reason, contains('e2e/ios_example'));
        expect(caught.reason, contains(':app'));
        expect(caught.reason, contains('timed out after'));
        expect(caught.reason, matches(RegExp(r'timed out after \d+ms')));
        expect(buildKilled, isTrue);
        expect(logs, contains('timed out stdout output'));
        expect(logs, contains('timed out stderr output'));

        expect(calls.length, 2);
        expect(calls[0].args.first, 'build');
        expect(calls[1].args, ['shutdown']);
      },
    );

    test(
      'ProcessException on build spawn throws WarmFailure naming workspace and target, runs shutdown',
      () async {
        createWorkspace('e2e/ios_example');

        final calls = <RecordedCall>[];
        Future<WarmChild> fakeSpawner(
          List<String> args, {
          required String workingDirectory,
        }) async {
          calls.add(
            RecordedCall(args: args, workingDirectory: workingDirectory),
          );
          if (args.first == 'build') {
            throw const ProcessException(
              'bazel',
              ['build'],
              'executable not found',
              2,
            );
          }
          return WarmChild(
            exitCode: Future.value(0),
            stdoutText: Future.value(''),
            stderrText: Future.value(''),
            kill: () {},
          );
        }

        final options = WarmOptions(
          bazel: fakeSpawner,
          repoRoot: tempDir.path,
          environment: {'HOME': '/test/home'},
          log: (_) {},
        );

        WarmFailure? caught;
        try {
          await warmIosE2eBuilds(
            options,
            targets: const [
              WarmTarget(workspace: 'e2e/ios_example', target: ':app'),
            ],
          );
        } on WarmFailure catch (f) {
          caught = f;
        }

        expect(caught, isNotNull);
        expect(caught!.reason, contains('e2e/ios_example'));
        expect(caught.reason, contains(':app'));
        expect(caught.reason, contains('executable not found'));

        expect(calls.length, 2);
        expect(calls[0].args.first, 'build');
        expect(calls[1].args, ['shutdown']);
      },
    );

    test(
      'shutdown hanging past shutdownTimeout kills shutdown child and does not mask prior build success',
      () async {
        createWorkspace('e2e/ios_example');

        final calls = <RecordedCall>[];
        var shutdownKilled = false;
        final shutdownCompleter = Completer<int>();

        Future<WarmChild> fakeSpawner(
          List<String> args, {
          required String workingDirectory,
        }) async {
          calls.add(
            RecordedCall(args: args, workingDirectory: workingDirectory),
          );
          if (args.first == 'shutdown') {
            return WarmChild(
              exitCode: shutdownCompleter.future,
              stdoutText: Future.value(''),
              stderrText: Future.value(''),
              kill: () {
                shutdownKilled = true;
                if (!shutdownCompleter.isCompleted) {
                  shutdownCompleter.complete(-1);
                }
              },
            );
          }
          return WarmChild(
            exitCode: Future.value(0),
            stdoutText: Future.value(''),
            stderrText: Future.value(''),
            kill: () {},
          );
        }

        final options = WarmOptions(
          bazel: fakeSpawner,
          repoRoot: tempDir.path,
          environment: {'HOME': '/test/home'},
          shutdownTimeout: const Duration(milliseconds: 30),
          log: (_) {},
        );

        // Does not throw; prior build success is not masked by shutdown timeout.
        await warmIosE2eBuilds(
          options,
          targets: const [
            WarmTarget(workspace: 'e2e/ios_example', target: ':app'),
          ],
        );

        expect(shutdownKilled, isTrue);
        expect(calls.length, 2);
        expect(calls[0].args.first, 'build');
        expect(calls[1].args, ['shutdown']);
      },
    );

    test(
      'shutdown hanging past shutdownTimeout kills shutdown child and does not mask prior build failure',
      () async {
        createWorkspace('e2e/ios_example');

        final calls = <RecordedCall>[];
        var shutdownKilled = false;
        final shutdownCompleter = Completer<int>();

        Future<WarmChild> fakeSpawner(
          List<String> args, {
          required String workingDirectory,
        }) async {
          calls.add(
            RecordedCall(args: args, workingDirectory: workingDirectory),
          );
          if (args.first == 'shutdown') {
            return WarmChild(
              exitCode: shutdownCompleter.future,
              stdoutText: Future.value(''),
              stderrText: Future.value(''),
              kill: () {
                shutdownKilled = true;
                if (!shutdownCompleter.isCompleted) {
                  shutdownCompleter.complete(-1);
                }
              },
            );
          }
          return WarmChild(
            exitCode: Future.value(42),
            stdoutText: Future.value('build failure detail'),
            stderrText: Future.value(''),
            kill: () {},
          );
        }

        final options = WarmOptions(
          bazel: fakeSpawner,
          repoRoot: tempDir.path,
          environment: {'HOME': '/test/home'},
          shutdownTimeout: const Duration(milliseconds: 30),
          log: (_) {},
        );

        WarmFailure? caught;
        try {
          await warmIosE2eBuilds(
            options,
            targets: const [
              WarmTarget(workspace: 'e2e/ios_example', target: ':app'),
            ],
          );
        } on WarmFailure catch (f) {
          caught = f;
        }

        expect(caught, isNotNull);
        expect(caught!.reason, contains('42'));
        expect(caught.reason, contains('e2e/ios_example'));
        expect(caught.reason, contains(':app'));
        expect(shutdownKilled, isTrue);
      },
    );
  });
}
