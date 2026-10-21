/// Fails when a download in flutter/** can run without a validated digest.
///
/// Every `repository_ctx.download(` / `download_and_extract(` call in a `.bzl`
/// file under `flutter/` must pass `sha256 =` whose value is either a call to
/// one of the fail-closed accessors (`require_sha256`,
/// `flutter_artifact_sha256`, `flutter_source_sha256` — each fails when the
/// checksum is missing instead of fetching unverified bytes) or a
/// `<struct>.<field>` produced by a `validate_*` helper in the same file that
/// applies `require_sha256` to every checksum it returns (the
/// headless-runtime validators). Dropping `sha256 =` at any fetch site keeps
/// every other test green, so this guard is the only thing that would turn
/// red.
///
/// The `.bzl` files arrive as test args: BUILD.bazel aggregates every
/// subpackage's `download_guard_bzl` filegroup into one `$(rlocationpaths)`
/// expansion, so a new subpackage's fetches stay covered as soon as its
/// filegroup joins the aggregate.
library;

import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

final RegExp _downloadCall = RegExp(r'\.(download|download_and_extract)\s*\(');
final RegExp _sha256Arg = RegExp(r'sha256\s*=\s*');
final RegExp _validatedCall = RegExp(
  r'(require_sha256|flutter_artifact_sha256|flutter_source_sha256)\s*\(',
);
final RegExp _structField = RegExp(r'[A-Za-z_]\w*(?:\.\w+)+');
final RegExp _validateDef = RegExp(r'def\s+validate_\w+\s*\(');

/// End index of the balanced-`)` closing the `(` at [openParen], or null
/// when the call never closes. String literals (with backslash escapes) are
/// skipped so a paren inside a URL or message cannot end the scan early.
int? _callSpan(String text, int openParen) {
  var depth = 0;
  String? inString;
  var i = openParen;
  while (i < text.length) {
    final ch = text[i];
    if (inString != null) {
      if (ch == r'\') {
        i += 2;
        continue;
      }
      if (ch == inString) inString = null;
    } else if (ch == '"' || ch == "'") {
      inString = ch;
    } else if (ch == '(') {
      depth++;
    } else if (ch == ')') {
      depth--;
      if (depth == 0) return i;
    }
    i++;
  }
  return null;
}

/// 1-based line number of [offset] in [text].
int _lineOf(String text, int offset) =>
    '\n'.allMatches(text.substring(0, offset)).length + 1;

/// Error strings for download calls in one file without a validated digest.
List<String> _checkFile(String key, String text) {
  final hasValidator =
      _validateDef.hasMatch(text) && text.contains('require_sha256');
  final errors = <String>[];
  for (final match in _downloadCall.allMatches(text)) {
    final openParen = text.indexOf('(', match.start);
    final end = _callSpan(text, openParen);
    if (end == null) {
      errors.add(
        '$key: cannot parse ${match.group(1)} call at offset ${match.start}',
      );
      continue;
    }
    final body = text.substring(openParen, end);
    final sha = _sha256Arg.firstMatch(body);
    if (sha == null) {
      errors.add(
        '$key:${_lineOf(text, match.start)}: ${match.group(1)}() without a '
        'sha256 = argument; pass a checksum through require_sha256',
      );
      continue;
    }
    final value = body.substring(sha.end).trimLeft();
    if (_validatedCall.matchAsPrefix(value) != null) continue;
    final field = _structField.matchAsPrefix(value);
    if (field != null && hasValidator) continue;
    final shown = value
        .substring(0, value.length < 60 ? value.length : 60)
        .split('\n')
        .first;
    errors.add(
      '$key:${_lineOf(text, match.start)}: ${match.group(1)}() sha256 is not '
      'a validated digest (require_sha256/flutter_artifact_sha256/'
      'flutter_source_sha256, or a validator-produced field); got $shown',
    );
  }
  return errors;
}

void main(List<String> args) {
  final runfiles = Runfiles.create();
  final keys =
      args
          .expand((arg) => arg.split(RegExp(r'\s+')))
          .where((key) => key.isNotEmpty)
          .toList()
        ..sort();
  for (final key in keys) {
    test('$key passes a validated digest at every download', () {
      final path = runfiles.rlocation(key);
      final problems = _checkFile(key, File(path).readAsStringSync());
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }
}
