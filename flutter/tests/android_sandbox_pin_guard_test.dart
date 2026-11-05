/// Guard for the Android integration test's sandbox requirement.
///
/// `no-sandbox` stays on the Android test action in every default run (under
/// `linux-sandbox` adb never discovers the emulator). The only way off it is
/// the dispatch-only `android_linux_sandbox` job in `full.yaml`, which drops
/// the requirement with `--modify_execution_info` and never gates. The guard
/// reads both files from the workspace root (found from the test's own source
/// file in `data`, or `BUILD_WORKSPACE_DIRECTORY`); the target is tagged
/// `external` and `no-sandbox` because it reads undeclared files.
library;

import 'dart:io';

import 'package:test/test.dart';

const String _rule = 'flutter/private/flutter_integration_test.bzl';
const String _workflow = '.github/workflows/full.yaml';

Directory _root() {
  final String fromEnv =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ?? '';
  if (fromEnv.isNotEmpty) return Directory(fromEnv);
  final String anchor = Platform.environment['GUARD_ROOT_ANCHOR'] ?? '';
  final String srcdir = Platform.environment['TEST_SRCDIR'] ?? '';
  Directory dir = File(File('$srcdir/$anchor').resolveSymbolicLinksSync())
      .parent;
  while (!File('${dir.path}/$_rule').existsSync()) {
    if (dir.parent.path == dir.path) {
      throw StateError('no workspace above $anchor');
    }
    dir = dir.parent;
  }
  return dir;
}

String _read(String rel) => File('${_root().path}/$rel').readAsStringSync();

/// The text of the top-level `name:` block (job or input) at [indent].
String _block(String yaml, String name, int indent) {
  final String pad = ' ' * indent;
  final List<String> lines = yaml.split('\n');
  final int start = lines.indexWhere((String l) => l == '$pad$name:');
  if (start < 0) throw StateError('no $name block in $_workflow');
  final int len = lines
      .skip(start + 1)
      .takeWhile((String l) => l.isEmpty || l.startsWith('$pad '))
      .length;
  return lines.sublist(start, start + 1 + len).join('\n');
}

void main() {
  test('the default Android test action still carries no-sandbox', () {
    final String bzl = _read(_rule);
    final int impl = bzl.indexOf('def _flutter_android_integration_test_impl');
    final int end = bzl.indexOf('\n_WEB_RELEVANT_KEYS', impl);
    expect(impl, isNonNegative);
    expect(end, greaterThan(impl));
    expect(
      bzl.substring(impl, end),
      contains(
        'return providers + [testing.ExecutionInfo({"no-sandbox": ""})]',
      ),
    );
  });

  test('the linux-sandbox dispatch input defaults to off', () {
    final String input = _block(_read(_workflow), 'android_linux_sandbox', 6);
    expect(input, contains('default: false'));
    expect(input, contains('type: boolean'));
  });

  test(
    'the linux-sandbox job is dispatch-only, non-gating and drops no-sandbox',
    () {
      final String yaml = _read(_workflow);
      final String job = _block(yaml, 'e2e-android-linux-sandbox', 2);
      expect(job, contains("github.event_name == 'workflow_dispatch'"));
      expect(job, contains('inputs.android_linux_sandbox'));
      expect(job, contains('continue-on-error: true'));
      expect(job, contains('--modify_execution_info=TestRunner=-no-sandbox'));
      expect(job, contains('--test_output=all'));
      expect(job, contains('.github/scripts/enable_linux_sandbox.sh'));
      final String conclusion = _block(yaml, 'conclusion', 2);
      expect(conclusion, isNot(contains('e2e-android-linux-sandbox')));
    },
  );
}
