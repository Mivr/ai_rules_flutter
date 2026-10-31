/// Unit tests for the rules_android_maven pin validation tool.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../pins.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('maven_pins_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  Directory createFakeWorkspace({
    String? lockFileAttr = '"//:rules_android_maven_install.json"',
    List<String> declaredArtifacts = const [
      'androidx.annotation:annotation:1.9.1',
    ],
    String? lockContent,
    bool createLockFile = true,
  }) {
    final wsDir = Directory('${tempDir.path}/fake_ws')..createSync();
    final lockLine = lockFileAttr != null
        ? '    lock_file = $lockFileAttr,\n'
        : '';
    final artifactsLines = declaredArtifacts
        .map((a) => '        "$a",\n')
        .join();

    File('${wsDir.path}/MODULE.bazel').writeAsStringSync('''
maven.install(
    name = "rules_android_maven",
    artifacts = [
$artifactsLines    ],
$lockLine)
''');

    if (createLockFile) {
      final defaultLock = jsonEncode({
        'version': '3',
        'artifacts': {
          'androidx.annotation:annotation': {
            'shasums': {
              'jar': '66bc2c13bd91fb8ea09e445b21f784d3e5d3a9ec9b180cd07e0e9208c2f939c6',
            },
            'version': '1.9.1',
          },
        },
      });
      File('${wsDir.path}/rules_android_maven_install.json').writeAsStringSync(
        lockContent ?? defaultLock,
      );
    }

    return wsDir;
  }

  group('checkWorkspacePins', () {
    test('passes on valid workspace with v3 lock', () {
      final ws = createFakeWorkspace();
      final errors = checkWorkspacePins(ws.path);
      expect(errors, isEmpty);
    });

    test('passes on valid workspace with v2 lock', () {
      final lock = jsonEncode({
        'version': '2',
        'artifacts': {
          'androidx.annotation:annotation': {
            'shasums': {
              'jar': '66bc2c13bd91fb8ea09e445b21f784d3e5d3a9ec9b180cd07e0e9208c2f939c6',
            },
            'version': '1.9.1',
          },
        },
      });
      final ws = createFakeWorkspace(lockContent: lock);
      final errors = checkWorkspacePins(ws.path);
      expect(errors, isEmpty);
    });

    test('fails when rules_android_maven has no lock_file', () {
      final ws = createFakeWorkspace(lockFileAttr: null);
      final errors = checkWorkspacePins(ws.path);
      expect(errors, hasLength(1));
      expect(errors.first, contains(ws.path));
      expect(errors.first, contains('MODULE.bazel'));
      expect(errors.first, contains('has no lock_file'));
    });

    test('fails when lock file is missing', () {
      final ws = createFakeWorkspace(createLockFile: false);
      final errors = checkWorkspacePins(ws.path);
      expect(errors, hasLength(1));
      expect(errors.first, contains(ws.path));
      expect(errors.first, contains('rules_android_maven_install.json'));
      expect(errors.first, contains('lock file is missing'));
    });

    test('fails when lock file is not valid JSON', () {
      final ws = createFakeWorkspace(lockContent: 'not valid json {{{');
      final errors = checkWorkspacePins(ws.path);
      expect(errors, hasLength(1));
      expect(errors.first, contains(ws.path));
      expect(errors.first, contains('rules_android_maven_install.json'));
      expect(errors.first, contains('lock file is not valid JSON'));
    });

    test('fails when lock file version is not 2 or 3', () {
      final lock = jsonEncode({
        'version': '1',
        'artifacts': {
          'androidx.annotation:annotation': {
            'shasums': {
              'jar': '66bc2c13bd91fb8ea09e445b21f784d3e5d3a9ec9b180cd07e0e9208c2f939c6',
            },
            'version': '1.9.1',
          },
        },
      });
      final ws = createFakeWorkspace(lockContent: lock);
      final errors = checkWorkspacePins(ws.path);
      expect(errors, hasLength(1));
      expect(errors.first, contains(ws.path));
      expect(errors.first, contains('expected lock version 2 or 3, got \'1\''));
    });

    test('fails when artifact entry has no 64-hex sha256', () {
      final lock = jsonEncode({
        'version': '3',
        'artifacts': {
          'androidx.annotation:annotation': {
            'shasums': {'jar': 'invalid-sha'},
            'version': '1.9.1',
          },
        },
      });
      final ws = createFakeWorkspace(lockContent: lock);
      final errors = checkWorkspacePins(ws.path);
      expect(errors, hasLength(1));
      expect(errors.first, contains(ws.path));
      expect(
        errors.first,
        contains(
          'artifact \'androidx.annotation:annotation\' has no 64-hex sha256 under shasums',
        ),
      );
    });

    test('fails when artifact entry has empty shasums', () {
      final lock = jsonEncode({
        'version': '3',
        'artifacts': {
          'androidx.annotation:annotation': {
            'shasums': {},
            'version': '1.9.1',
          },
        },
      });
      final ws = createFakeWorkspace(lockContent: lock);
      final errors = checkWorkspacePins(ws.path);
      expect(errors, hasLength(1));
      expect(errors.first, contains(ws.path));
      expect(
        errors.first,
        contains(
          'artifact \'androidx.annotation:annotation\' has no 64-hex sha256 under shasums',
        ),
      );
    });

    test('fails when declared group:artifact is absent from lock', () {
      final lock = jsonEncode({
        'version': '3',
        'artifacts': {
          'com.google.guava:guava': {
            'shasums': {
              'jar': '66bc2c13bd91fb8ea09e445b21f784d3e5d3a9ec9b180cd07e0e9208c2f939c6',
            },
            'version': '32.1.2-jre',
          },
        },
      });
      final ws = createFakeWorkspace(
        declaredArtifacts: ['androidx.annotation:annotation:1.9.1'],
        lockContent: lock,
      );
      final errors = checkWorkspacePins(ws.path);
      expect(errors, hasLength(1));
      expect(errors.first, contains(ws.path));
      expect(
        errors.first,
        contains(
          'declared artifact \'androidx.annotation:annotation:1.9.1\' (androidx.annotation:annotation) is absent from lock',
        ),
      );
    });

    test('checkAllWorkspaces validates custom workspaces list', () {
      createFakeWorkspace();
      final errors = checkAllWorkspaces(
        rootPath: tempDir.path,
        workspaces: ['fake_ws'],
      );
      expect(errors, isEmpty);
    });
  });
}
