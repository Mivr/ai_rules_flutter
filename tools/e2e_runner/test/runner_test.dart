/// End-to-end unit tests for `package:e2e_runner/runner.dart`.
library;

import 'dart:io';

import 'package:e2e_runner/runner.dart';
import 'package:e2e_runner/spec.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Entry point for runner execution tests.
void main() {
  _registerClientResolutionTests();
  _registerGreenExecutionTests();
  _registerFailureAndShutdownTests();
}

String _writeFakeBazel(Directory dir, String scriptBody) {
  final script = File(p.join(dir.path, 'fake_bazel'));
  script.writeAsStringSync('#!/bin/sh\nset -eu\n$scriptBody\n');
  Process.runSync('chmod', ['+x', script.path]);
  return script.path;
}

Directory _createSampleWorkspace(Directory root, String specYaml) {
  final repoRoot = Directory(p.join(root.path, 'repo'))..createSync();
  final ws = Directory(p.join(repoRoot.path, 'e2e', 'demo'))
    ..createSync(recursive: true);
  File(p.join(ws.path, 'MODULE.bazel')).writeAsStringSync('''
module(name = "demo")
local_path_override(
    module_name = "ai_rules_flutter",
    path = "../..",
)
''');
  File(p.join(ws.path, 'data.txt')).writeAsStringSync('ORIGINAL_VALUE');
  File(p.join(ws.path, 'e2e.yaml')).writeAsStringSync(specYaml);
  return ws;
}

void _registerClientResolutionTests() {
  group('resolveWorkspacePath and resolveBazelBinary', () {
    test('resolves BIT_WORKSPACE_DIR and BUILD_WORKING_DIRECTORY', () {
      expect(
        resolveWorkspacePath(
          environment: {'BIT_WORKSPACE_DIR': 'e2e/smoke'},
          baseDirectory: '/runfiles/_main',
        ),
        '/runfiles/_main/e2e/smoke',
      );
      expect(
        callerWorkingDirectory({
          'BUILD_WORKING_DIRECTORY': '/caller/repo',
          'BUILD_WORKSPACE_DIRECTORY': '/caller/ws',
        }),
        '/caller/repo',
      );
    });

    test('resolves extensionless Windows BIT_BAZEL_BINARY and PATH lookup', () {
      final Directory dir = Directory.systemTemp.createTempSync('win_bazel_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final exeFile = File(p.join(dir.path, 'bazel.exe'))
        ..writeAsStringSync('stub');
      final cmdDir = Directory(p.join(dir.path, 'bin'))..createSync();
      final cmdFile = File(p.join(cmdDir.path, 'bazelisk.CMD'))
        ..writeAsStringSync('stub');

      final String resolvedDirect = resolveBazelBinary(
        environment: {'BIT_BAZEL_BINARY': p.join(dir.path, 'bazel')},
        baseDirectory: dir.path,
        isWindows: true,
      );
      expect(resolvedDirect, exeFile.absolute.path);

      final String resolvedPath = resolveBazelBinary(
        flagBazel: 'bazelisk',
        environment: {'Path': cmdDir.path, 'PATHEXT': '.COM;.EXE;.BAT;.CMD'},
        baseDirectory: dir.path,
        isWindows: true,
      );
      expect(resolvedPath, cmdFile.absolute.path);
    });
  });
}

String _greenFakeBazelBody(String callsLogPath, String expectedRepoRoot) =>
    '''
echo "\$*" >> "$callsLogPath"
if [ "\${BUILD_WORKSPACE_DIRECTORY:-}" != "" ] || [ "\${BAZELISK_SKIP_WRAPPER:-}" != "" ]; then
  echo "LEAKED_OUTER_ENV" >&2
  exit 9
fi
case "\$*" in
  *" shutdown") exit 0 ;;
esac
grep -q 'path = "$expectedRepoRoot"' MODULE.bazel
test -f extra.txt
grep -q 'MUTATED_' data.txt
bep=""
for arg in "\$@"; do
  case "\$arg" in
    --build_event_json_file=*) bep="\${arg#--build_event_json_file=}" ;;
  esac
done
xml="\$PWD/generated_test.xml"
log="\$PWD/generated_test.log"
printf '<testsuite><testcase name="t1"/><testcase name="t2"/><testcase name="s"><skipped/></testcase></testsuite>' > "\$xml"
printf 'INNER_SUITE_PASSED\\n' > "\$log"
printf '{"testResult":{"testActionOutput":[{"name":"test.xml","uri":"file://%s"},{"name":"test.log","uri":"file://%s"}]}}\\n' "\$xml" "\$log" > "\$bep"
echo "BUILD_STDOUT_OK"
echo "BUILD_STDERR_OK" >&2
''';

const String _greenSpecYaml = r'''
schema: mivr-e2e-spec/1
commands:
  - name: verify staging and test
    run: bazel test //... --test_output=errors
    min_tests_executed: 2
    write_files:
      extra.txt: "CREATED_IN_STAGE"
    replace_in_files:
      - path: data.txt
        from: ORIGINAL_VALUE
        to: "MUTATED_${WORKSPACE}"
    expect:
      exit_code: 0
      stdout_contains: BUILD_STDOUT_OK
      stderr_contains: BUILD_STDERR_OK
      output_contains:
        - BUILD_STDOUT_OK
        - BUILD_STDERR_OK
      output_regex:
        - 'STDOUT_OK[\s\S]*STDERR_OK'
      stderr_not_contains: FATAL_ERR
      output_not_contains: FORBIDDEN_TOKEN
      test_log_contains: INNER_SUITE_PASSED
''';

void _registerGreenExecutionTests() {
  group('runE2e green execution', () {
    test(
      'stages workspace, strips outer env, checks BEP/logs, shuts down',
      () async {
        final Directory root = Directory.systemTemp.createTempSync(
          'runner_green_',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final callsLog = File(p.join(root.path, 'calls.log'));
        final Directory ws = _createSampleWorkspace(root, _greenSpecYaml);
        final String fakeBazel = _writeFakeBazel(
          root,
          _greenFakeBazelBody(callsLog.path, p.join(root.path, 'repo')),
        );
        await runE2e(
          E2eRunnerOptions(
            workspacePath: ws.path,
            bazelBinary: fakeBazel,
            runtime: (
              environment: {
                ...Platform.environment,
                'BUILD_WORKSPACE_DIRECTORY': '/outer/leaked',
                'BAZELISK_SKIP_WRAPPER': 'true',
              },
              tempParent: root,
              isWindows: false,
              stdoutSink: null,
              stderrSink: null,
            ),
          ),
        );
        expect(
          File(p.join(ws.path, 'data.txt')).readAsStringSync(),
          'ORIGINAL_VALUE',
        );
        expect(File(p.join(ws.path, 'extra.txt')).existsSync(), isFalse);
        final List<String> calls = callsLog.readAsLinesSync();
        expect(calls, hasLength(2));
        expect(calls.first, contains('--output_base='));
        expect(calls.first, contains('test --build_event_json_file='));
        expect(calls.last, matches(RegExp(r'^--output_base=.* shutdown$')));
      },
      skip: Platform.isWindows ? 'POSIX /bin/sh fake bazel fixture' : false,
    );
  });
}

void _registerFailureAndShutdownTests() {
  _registerExit4FailureTest();
  _registerSkippedOnlyFailureTest();
  _registerUnreadableReplaceShutdownTest();
}

void _registerExit4FailureTest() {
  group('runE2e exit 4 guard', () {
    test(
      'rejects exit code 4 unconditionally even with non_zero: true',
      () async {
        final Directory root = Directory.systemTemp.createTempSync(
          'runner_exit4_',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final callsLog = File(p.join(root.path, 'calls.log'));
        final Directory ws = _createSampleWorkspace(root, '''
schema: mivr-e2e-spec/1
commands:
  - name: sneaky-exit-4
    run: bazel test //...
    expect:
      non_zero: true
''');
        final String fakeBazel = _writeFakeBazel(root, '''
echo "\$*" >> "${callsLog.path}"
case "\$*" in
  *" shutdown") exit 0 ;;
esac
exit 4
''');
        await expectLater(
          () => runE2e(
            E2eRunnerOptions(
              workspacePath: ws.path,
              bazelBinary: fakeBazel,
              runtime: (
                environment: Platform.environment,
                tempParent: root,
                isWindows: false,
                stdoutSink: null,
                stderrSink: null,
              ),
            ),
          ),
          throwsA(
            isA<E2eRunnerException>()
                .having((e) => e.commandName, 'commandName', 'sneaky-exit-4')
                .having((e) => e.message, 'message', contains('code 4')),
          ),
        );
        expect(
          callsLog.readAsLinesSync().last,
          matches(RegExp(r'^--output_base=.* shutdown$')),
        );
      },
      skip: Platform.isWindows ? 'POSIX /bin/sh fake bazel fixture' : false,
    );
  });
}

void _registerSkippedOnlyFailureTest() {
  group('runE2e min_tests_executed guard', () {
    test(
      'fails when bazel test exits 0 with only skipped JUnit testcases',
      () async {
        final Directory root = Directory.systemTemp.createTempSync(
          'runner_zero_',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final callsLog = File(p.join(root.path, 'calls.log'));
        final Directory ws = _createSampleWorkspace(root, '''
schema: mivr-e2e-spec/1
commands:
  - name: skipped-only-test
    run: bazel test //...
''');
        final String fakeBazel = _writeFakeBazel(root, '''
echo "\$*" >> "${callsLog.path}"
case "\$*" in
  *" shutdown") exit 0 ;;
esac
mkdir -p bazel-testlogs/pkg/t
printf '<testsuite><testcase name="s"><skipped/></testcase></testsuite>' > bazel-testlogs/pkg/t/test.xml
exit 0
''');
        await expectLater(
          () => runE2e(
            E2eRunnerOptions(
              workspacePath: ws.path,
              bazelBinary: fakeBazel,
              runtime: (
                environment: Platform.environment,
                tempParent: root,
                isWindows: false,
                stdoutSink: null,
                stderrSink: null,
              ),
            ),
          ),
          throwsA(
            isA<E2eRunnerException>()
                .having(
                  (e) => e.commandName,
                  'commandName',
                  'skipped-only-test',
                )
                .having(
                  (e) => e.message,
                  'message',
                  contains('executed 0 non-skipped test(s)'),
                ),
          ),
        );
        expect(
          callsLog.readAsLinesSync().last,
          matches(RegExp(r'^--output_base=.* shutdown$')),
        );
      },
      skip: Platform.isWindows ? 'POSIX /bin/sh fake bazel fixture' : false,
    );
  });
}

void _registerUnreadableReplaceShutdownTest() {
  group('runE2e unreadable file error and shutdown', () {
    test(
      'names spec path and command name and still runs shutdown',
      () async {
        final Directory root = Directory.systemTemp.createTempSync(
          'runner_unreadable_',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final callsLog = File(p.join(root.path, 'calls.log'));
        final Directory ws = _createSampleWorkspace(root, '''
schema: mivr-e2e-spec/1
commands:
  - name: broken-replace
    run: bazel build //:all
    replace_in_files:
      - path: missing_file.txt
        from: a
        to: b
''');
        final String fakeBazel = _writeFakeBazel(
          root,
          'echo "\$*" >> "${callsLog.path}"\nexit 0',
        );
        final String expectedSpec = p.join(ws.path, 'e2e.yaml');
        await expectLater(
          () => runE2e(
            E2eRunnerOptions(
              workspacePath: ws.path,
              bazelBinary: fakeBazel,
              runtime: (
                environment: Platform.environment,
                tempParent: root,
                isWindows: false,
                stdoutSink: null,
                stderrSink: null,
              ),
            ),
          ),
          throwsA(
            isA<E2eRunnerException>()
                .having((e) => e.specPath, 'specPath', expectedSpec)
                .having((e) => e.commandName, 'commandName', 'broken-replace'),
          ),
        );
        expect(
          callsLog.readAsLinesSync().single,
          matches(RegExp(r'^--output_base=.* shutdown$')),
        );
      },
      skip: Platform.isWindows ? 'POSIX /bin/sh fake bazel fixture' : false,
    );
  });
}
