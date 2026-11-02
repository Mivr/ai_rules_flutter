/// Unit tests for the rules_android_maven pin validation tool.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../pins.dart';

const String _validSha =
    '66bc2c13bd91fb8ea09e445b21f784d3e5d3a9ec9b180cd07e0e9208c2f939c6';

String _encodeLock({
  Object? version = '3',
  Map<String, Object?>? artifacts,
}) {
  return jsonEncode(<String, Object?>{
    'version': version,
    'artifacts':
        artifacts ??
        <String, Object?>{
          'androidx.annotation:annotation': <String, Object?>{
            'shasums': <String, Object?>{'jar': _validSha},
            'version': '1.9.1',
          },
        },
  });
}

Directory _writeFakeWorkspace(
  Directory parent, {
  String? lockFileAttr = '"//:rules_android_maven_install.json"',
  List<String> declaredArtifacts = const [
    'androidx.annotation:annotation:1.9.1',
  ],
  String? extraModuleContent,
  String? lockContent,
}) {
  final wsDir = Directory('${parent.path}/fake_ws')..createSync();
  final lockLine = lockFileAttr != null
      ? '    lock_file = $lockFileAttr,\n'
      : '';
  final String artifactsLines = declaredArtifacts
      .map((String a) => '        "$a",\n')
      .join();
  final suffix = extraModuleContent != null ? '\n$extraModuleContent\n' : '';

  File('${wsDir.path}/MODULE.bazel').writeAsStringSync(
    'maven.install(\n'
    '    name = "rules_android_maven",\n'
    '    artifacts = [\n'
    '$artifactsLines'
    '    ],\n'
    '$lockLine'
    ')$suffix\n',
  );

  File('${wsDir.path}/rules_android_maven_install.json').writeAsStringSync(
    lockContent ?? _encodeLock(),
  );
  return wsDir;
}

void _registerValidPinTests(Directory Function() getTempDir) {
  test('passes on valid workspace with v3 lock', () {
    final Directory ws = _writeFakeWorkspace(getTempDir());
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, isEmpty);
  });

  test('passes on valid workspace with v2 lock', () {
    final String lock = _encodeLock(version: '2');
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockContent: lock);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, isEmpty);
  });

  test('ignores hash characters inside string literals', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      extraModuleContent: '# lock_file comment\n_url = "https://example.com#x"',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, isEmpty);
  });

  test('checkAllWorkspaces validates custom workspaces list', () {
    final Directory root = getTempDir();
    _writeFakeWorkspace(root);
    final List<String> errors = checkAllWorkspaces(
      rootPath: root.path,
      workspaces: const ['fake_ws'],
    );
    expect(errors, isEmpty);
  });
}

void _registerMissingOrMalformedLockTests(Directory Function() getTempDir) {
  test('fails when rules_android_maven has no lock_file', () {
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockFileAttr: null);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(errors.first, contains('MODULE.bazel'));
    expect(errors.first, contains('has no lock_file'));
  });

  test('fails when lock_file is commented out', () {
    final Directory root = getTempDir();
    final wsDir = Directory('${root.path}/commented_ws')..createSync();
    File('${wsDir.path}/MODULE.bazel').writeAsStringSync(
      'maven.install(\n'
      '    name = "rules_android_maven",\n'
      '    # lock_file = "//:rules_android_maven_install.json",\n'
      ')\n',
    );
    final List<String> errors = checkWorkspacePins(wsDir.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('has no lock_file'));
  });

  test('fails when lock file is missing', () {
    final Directory ws = _writeFakeWorkspace(getTempDir());
    File('${ws.path}/rules_android_maven_install.json').deleteSync();
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(errors.first, contains('rules_android_maven_install.json'));
    expect(errors.first, contains('lock file is missing'));
  });

  test('fails when lock file is not valid JSON', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      lockContent: 'not valid json [',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(errors.first, contains('rules_android_maven_install.json'));
    expect(errors.first, contains('lock file is not valid JSON'));
  });

  test('fails when lock file version is not 2 or 3', () {
    final String lock = _encodeLock(version: '1');
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockContent: lock);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(errors.first, contains("expected lock version 2 or 3, got '1'"));
  });
}

void _registerShaTests(Directory Function() getTempDir) {
  test('fails when artifact entry has no 64-hex sha256', () {
    final String lock = _encodeLock(
      artifacts: <String, Object?>{
        'androidx.annotation:annotation': <String, Object?>{
          'shasums': <String, Object?>{'jar': 'invalid-sha'},
          'version': '1.9.1',
        },
      },
    );
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockContent: lock);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(
      errors.first,
      contains(
        "artifact 'androidx.annotation:annotation' has no 64-hex sha256 under shasums",
      ),
    );
  });

  test('fails when artifact entry has empty shasums', () {
    final String lock = _encodeLock(
      artifacts: <String, Object?>{
        'androidx.annotation:annotation': <String, Object?>{
          'shasums': <String, Object?>{},
          'version': '1.9.1',
        },
      },
    );
    final Directory ws = _writeFakeWorkspace(getTempDir(), lockContent: lock);
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(
      errors.first,
      contains(
        "artifact 'androidx.annotation:annotation' has no 64-hex sha256 under shasums",
      ),
    );
  });
}

void _registerDeclaredArtifactTests(Directory Function() getTempDir) {
  test('fails when declared group:artifact is absent from lock', () {
    final String lock = _encodeLock(
      artifacts: <String, Object?>{
        'com.google.guava:guava': <String, Object?>{
          'shasums': <String, Object?>{'jar': _validSha},
          'version': '32.1.2-jre',
        },
      },
    );
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      lockContent: lock,
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains(ws.path));
    expect(
      errors.first,
      contains(
        "declared artifact 'androidx.annotation:annotation:1.9.1' "
        '(androidx.annotation:annotation) is absent from lock',
      ),
    );
  });

  test('fails when maven.artifact tag coordinate is absent from lock', () {
    final Directory ws = _writeFakeWorkspace(
      getTempDir(),
      extraModuleContent:
          'maven.artifact(\n'
          '    name = "rules_android_maven",\n'
          '    group = "com.google.guava",\n'
          '    artifact = "listenablefuture",\n'
          '    version = "1.0",\n'
          ')',
    );
    final List<String> errors = checkWorkspacePins(ws.path);
    expect(errors, hasLength(1));
    expect(errors.first, contains('com.google.guava:listenablefuture'));
  });
}

/// Runs the unit test suite for `tools/check_maven_pins`.
void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('maven_pins_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  group('checkWorkspacePins', () {
    _registerValidPinTests(() => tempDir);
    _registerMissingOrMalformedLockTests(() => tempDir);
    _registerShaTests(() => tempDir);
    _registerDeclaredArtifactTests(() => tempDir);
  });
}
