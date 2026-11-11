/// Tripwire: every `git_override` of `ai_rules_dart` in `MODULE.bazel`,
/// `e2e/**/MODULE.bazel`, and `e2e/podfile_lock_red/MODULE.bazel.real`
/// must name the same commit, and no such file may name the old pin
/// `db7ec60d2515e0f1dc0eeb6632e0f88b27abd21e`.
library;

import 'dart:io';

import 'package:test/test.dart';

const String _oldPin = 'db7ec60d2515e0f1dc0eeb6632e0f88b27abd21e';
final RegExp _hexSha = RegExp(r'^[0-9a-f]{40}$');
final RegExp _stringOrComment = RegExp(
  r'''"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|#.*''',
);

/// Discovers the workspace root using the test's own source file anchor.
String _findRoot() {
  final Map<String, String> env = Platform.environment;
  final String? anchor = env['PIN_GUARD_ANCHOR'];
  final String? srcdir = env['TEST_SRCDIR'];
  if (anchor == null || anchor.isEmpty || srcdir == null) {
    throw StateError('PIN_GUARD_ANCHOR or TEST_SRCDIR is unset');
  }
  Directory dir = Directory(
    File('$srcdir/$anchor').resolveSymbolicLinksSync(),
  ).parent;
  for (var i = 0; i < 8; i++) {
    if (Directory('${dir.path}/flutter').existsSync() &&
        File('${dir.path}/MODULE.bazel').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  throw StateError('workspace root not found above $anchor');
}

/// Recursively discovers all `MODULE.bazel` files under [directory].
void _collectModuleFiles(Directory directory, List<File> files) {
  for (final FileSystemEntity entity in directory.listSync(
    followLinks: false,
  )) {
    final String name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name.startsWith('.') || name.startsWith('bazel-')) {
      continue;
    }
    if (entity is Directory) {
      _collectModuleFiles(entity, files);
    } else if (name == 'MODULE.bazel') {
      files.add(File(entity.path));
    }
  }
}

/// Strips `#` line comments outside string literals in Starlark [content].
String _stripComments(String content) => content.replaceAllMapped(
  _stringOrComment,
  (Match m) => m[0]!.startsWith('#') ? '' : m[0]!,
);

/// Extracts the commit attribute (or null if absent) from every
/// `ai_rules_dart` `git_override` block in [content].
List<String?> _extractPins(String content) {
  final String stripped = _stripComments(content);
  return [
    for (final RegExpMatch block in RegExp(
      r'git_override\s*\(([^)]*)\)',
    ).allMatches(stripped))
      if (RegExp(
        r'''\bmodule_name\s*=\s*["']ai_rules_dart["']''',
      ).hasMatch(block.group(1)!))
        RegExp(
          r'''\bcommit\s*=\s*["']([^"']*)["']''',
        ).firstMatch(block.group(1)!)?.group(1),
  ];
}

void main() {
  test('rules_dart git_override pins match and exclude old commit', () {
    final String root = _findRoot();
    final requiredFiles = <File>[
      File('$root/MODULE.bazel'),
      File('$root/e2e/podfile_lock_red/MODULE.bazel.real'),
    ];
    final e2eFiles = <File>[];
    _collectModuleFiles(Directory('$root/e2e'), e2eFiles);
    expect(e2eFiles, isNotEmpty, reason: 'Expected e2e MODULE.bazel files');

    final pins = <String, String>{};
    for (final file in <File>[...requiredFiles, ...e2eFiles]) {
      final String content = file.readAsStringSync();
      expect(
        content.toLowerCase().contains(_oldPin),
        isFalse,
        reason: '${file.path} contains old pin $_oldPin',
      );

      final List<String?> filePins = _extractPins(content);
      if (requiredFiles.any((r) => r.path == file.path)) {
        expect(
          filePins,
          isNotEmpty,
          reason: '${file.path} is missing ai_rules_dart git_override',
        );
      }
      for (var i = 0; i < filePins.length; i++) {
        final String? pin = filePins[i];
        expect(
          pin != null && _hexSha.hasMatch(pin),
          isTrue,
          reason:
              '${file.path} ai_rules_dart git_override has invalid commit: '
              '$pin',
        );
        pins['${file.path}#$i'] = pin!;
      }
    }

    final Set<String> distinctPins = pins.values.toSet();
    expect(
      distinctPins.length,
      equals(1),
      reason: 'Expected all ai_rules_dart git_overrides to match, found: $pins',
    );
  });
}
