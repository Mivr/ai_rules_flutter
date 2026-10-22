/// Fail-closed download guard: no fetch in flutter/** runs without a digest.
///
/// Every network fetch under `flutter/` runs through the `pinned_download` /
/// `pinned_download_and_extract` helpers in `flutter/private/download.bzl`,
/// which fail the fetch unless `sha256` is exactly 64 lowercase hex
/// characters and which hand the digest to Bazel's own checksum comparison.
/// That runtime check is the guarantee; this test is the tripwire that keeps
/// it wired up. It fails on:
///
/// * any `.download` / `.download_and_extract` attribute use on a context
///   outside `flutter/private/download.bzl` — a direct call, an alias such
///   as `fetch = ctx.download_and_extract`, or a `getattr` lookup. Comments
///   and string literals are ignored, so docs that name the methods stay
///   green while code that reaches them turns red;
/// * any `http_archive` / `http_file` / `http_jar` instantiation, in a
///   `.bzl` file or a `MODULE.bazel`, without a non-empty literal `sha256`
///   or `integrity`.
///
/// The test discovers its inputs at runtime from the workspace root (the
/// test's own source file in `data`, or `BUILD_WORKSPACE_DIRECTORY` when
/// set): every `.bzl` file under `flutter/`, the root `MODULE.bazel`, and
/// every `MODULE.bazel` under `e2e/`. There is no file list to maintain — a
/// `.bzl` added in a new package is checked with no other change. Reading
/// undeclared files means Bazel cannot know when to re-run, so the target
/// is tagged `external`: the guard re-runs on every invocation and is
/// never served a stale pass.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Whether [root] is the rules_flutter workspace root.
bool _looksLikeRoot(String root) =>
    Directory('$root/flutter').existsSync() &&
    File('$root/MODULE.bazel').existsSync();

/// Workspace root the test walks: `BUILD_WORKSPACE_DIRECTORY` when set,
/// otherwise the source file behind the test's own anchor in `data` (an
/// unsandboxed runfiles tree symlinks it into the source tree; the root is
/// the first ancestor that looks like the workspace). Null when neither
/// resolves, so the test fails loudly instead of scanning the wrong tree
/// or silently passing.
String? _workspaceRoot() {
  final fromEnv = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (fromEnv != null && fromEnv.isNotEmpty && _looksLikeRoot(fromEnv)) {
    return fromEnv;
  }
  final anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    try {
      var dir = File(
        File('$srcdir/$anchor').resolveSymbolicLinksSync(),
      ).parent;
      for (var i = 0; i < 8; i++) {
        if (_looksLikeRoot(dir.path)) return dir.path;
        dir = dir.parent;
      }
    } on FileSystemException {
      // Fall through to the loud failure below.
    }
  }
  return null;
}

/// Relative paths of every file named [fileName] under [dir], recursively
/// (never following symlinks, skipping `node_modules`), sorted.
List<String> _findNamed(String root, String dir, String fileName) {
  final base = Directory('$root/$dir');
  if (!base.existsSync()) return <String>[];
  final found = <String>[];
  final stack = <Directory>[base];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    List<FileSystemEntity> children;
    try {
      children = current.listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final child in children) {
      if (child is Directory) {
        if (child.path.split(Platform.pathSeparator).last == 'node_modules') {
          continue;
        }
        stack.add(child);
      } else if (child is File &&
          child.path.split(Platform.pathSeparator).last == fileName) {
        var rel = child.path;
        if (rel.startsWith('$root/')) rel = rel.substring(root.length + 1);
        found.add(rel);
      }
    }
  }
  found.sort();
  return found;
}

/// Relative paths of every `.bzl` file under `flutter/`, sorted.
List<String> _findBzl(String root) {
  final base = Directory('$root/flutter');
  final found = <String>[];
  final stack = <Directory>[base];
  while (stack.isNotEmpty) {
    final current = stack.removeLast();
    List<FileSystemEntity> children;
    try {
      children = current.listSync(followLinks: false);
    } on FileSystemException {
      continue;
    }
    for (final child in children) {
      if (child is Directory) {
        stack.add(child);
      } else if (child is File && child.path.endsWith('.bzl')) {
        found.add(child.path.substring(root.length + 1));
      }
    }
  }
  found.sort();
  return found;
}

/// [text] with every `#` comment and every string literal replaced by
/// spaces. When [blankStrings] is false, strings are kept. Newlines are
/// kept, so offsets (and therefore line numbers) match the original.
String _blankNonCode(String text, {required bool blankStrings}) {
  final out = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final ch = text[i];
    if (ch == '#') {
      while (i < text.length && text[i] != '\n') {
        out.write(' ');
        i++;
      }
    } else if (ch == '"' || ch == "'") {
      final triple =
          i + 2 < text.length && text[i + 1] == ch && text[i + 2] == ch;
      final quote = triple ? ch + ch + ch : ch;
      out.write(blankStrings ? ' ' * quote.length : quote);
      i += quote.length;
      while (i < text.length) {
        if (triple &&
            i + 2 < text.length &&
            text[i] == ch &&
            text[i + 1] == ch &&
            text[i + 2] == ch) {
          out.write(blankStrings ? '   ' : quote);
          i += 3;
          break;
        }
        if (!triple && text[i] == ch) {
          out.write(blankStrings ? ' ' : ch);
          i++;
          break;
        }
        if (text[i] == r'\' && i + 1 < text.length) {
          out.write(blankStrings ? '  ' : text.substring(i, i + 2));
          i += 2;
          continue;
        }
        if (text[i] == '\n') {
          out.write('\n');
          i++;
          continue;
        }
        out.write(blankStrings ? ' ' : text[i]);
        i++;
      }
    } else {
      out.write(ch);
      i++;
    }
  }
  return out.toString();
}

/// End index of the balanced-`)` closing the `(` at [openParen] in
/// comment- and string-blanked text, or null when the call never closes.
int? _callEnd(String blanked, int openParen) {
  var depth = 0;
  for (var i = openParen; i < blanked.length; i++) {
    if (blanked[i] == '(') {
      depth++;
    } else if (blanked[i] == ')') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return null;
}

/// 1-based line number of [offset] in [text].
int _lineOf(String text, int offset) =>
    '\n'.allMatches(text.substring(0, offset)).length + 1;

final RegExp _rawDownloadUse = RegExp(
  r'\.download(_and_extract)?(?![A-Za-z0-9_])',
);
final RegExp _getattrDownload = RegExp(
  r'''getattr\s*\([^()]*['"]download(_and_extract)?['"]''',
);
final RegExp _httpRule = RegExp(
  r'(http_archive|http_file|http_jar)\s*\(',
);
final RegExp _literalChecksum = RegExp(
  '''(sha256|integrity)\\s*=\\s*(?:"([^"]*)"|'([^']*)')''',
);

/// Error strings for raw context downloads in one `.bzl` file. The helpers
/// in `flutter/private/download.bzl` are the only code allowed to touch
/// `ctx.download` / `ctx.download_and_extract`.
List<String> _checkNoRawDownload(String rel, String text) {
  if (rel == 'flutter/private/download.bzl') return <String>[];
  final errors = <String>[];
  final code = _blankNonCode(text, blankStrings: true);
  for (final match in _rawDownloadUse.allMatches(code)) {
    errors.add(
      '$rel:${_lineOf(text, match.start)}: raw ctx.${match.group(0)!.substring(1)} '
      'outside flutter/private/download.bzl; fetch through '
      'pinned_download / pinned_download_and_extract',
    );
  }
  final codeWithStrings = _blankNonCode(text, blankStrings: false);
  for (final match in _getattrDownload.allMatches(codeWithStrings)) {
    errors.add(
      '$rel:${_lineOf(text, match.start)}: getattr lookup of a ctx download '
      'method outside flutter/private/download.bzl; fetch through '
      'pinned_download / pinned_download_and_extract',
    );
  }
  return errors;
}

/// Error strings for `http_*` rules without a non-empty literal checksum.
List<String> _checkHttpChecksums(String rel, String text) {
  final errors = <String>[];
  final code = _blankNonCode(text, blankStrings: true);
  for (final match in _httpRule.allMatches(code)) {
    final openParen = code.indexOf('(', match.start);
    final end = _callEnd(code, openParen);
    if (end == null) {
      errors.add(
        '$rel:${_lineOf(text, match.start)}: cannot parse '
        '${match.group(1)} call',
      );
      continue;
    }
    final body = text.substring(openParen, end);
    var pinned = false;
    for (final checksum in _literalChecksum.allMatches(body)) {
      final value = checksum.group(2) ?? checksum.group(3) ?? '';
      if (value.isNotEmpty) {
        pinned = true;
        break;
      }
    }
    if (!pinned) {
      errors.add(
        '$rel:${_lineOf(text, match.start)}: ${match.group(1)}() without a '
        'non-empty literal sha256 = or integrity =; pin the digest',
      );
    }
  }
  return errors;
}

void main() {
  final root = _workspaceRoot();
  if (root == null) {
    test('download guard discovers the workspace', () {
      fail(
        'BUILD_WORKSPACE_DIRECTORY does not point at the rules_flutter '
        'workspace; run this test unsandboxed (it is tagged no-sandbox) via '
        'bazel test //flutter/tests:download_digest_guard_test',
      );
    });
    return;
  }
  final bzlFiles = _findBzl(root);
  final moduleFiles = <String>[
    'MODULE.bazel',
    ..._findNamed(root, 'e2e', 'MODULE.bazel'),
  ];

  test('download guard discovers its inputs (no file list)', () {
    expect(
      bzlFiles,
      contains('flutter/private/download.bzl'),
      reason: 'the walk under flutter/ missed the helper itself',
    );
    expect(
      moduleFiles,
      contains('MODULE.bazel'),
      reason: 'the root MODULE.bazel is not scanned',
    );
    expect(
      moduleFiles.any((path) => path.startsWith('e2e/')),
      isTrue,
      reason: 'no MODULE.bazel under e2e/ was discovered',
    );
  });

  for (final rel in bzlFiles) {
    test('$rel fetches only through the pinned helpers', () {
      final text = File('$root/$rel').readAsStringSync();
      final problems = [
        ..._checkNoRawDownload(rel, text),
        ..._checkHttpChecksums(rel, text),
      ];
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  for (final rel in moduleFiles) {
    test('$rel pins every http checksum', () {
      final text = File('$root/$rel').readAsStringSync();
      final problems = _checkHttpChecksums(rel, text);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }
}
