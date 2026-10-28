/// Small helpers shared by the Android artifact tests.
///
/// These are test plumbing: they find declared runfiles, unzip build outputs,
/// read bytes, and collect pass/fail lines whose failures name what was
/// expected and what was found.
library;

// This library's diagnostics are its product: it prints each passing check
// to the bazel test log.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

/// Every file under [root], following the runfiles symlinks.
List<File> filesUnder(Directory root) {
  final out = <File>[];
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File) out.add(entity);
  }
  return out;
}

/// The single file matching [matches], or a failure naming what was found.
File oneFile(
  List<File> files,
  bool Function(File) matches,
  String description,
) {
  final hits = [
    for (final file in files)
      if (matches(file)) file,
  ];
  if (hits.length != 1) {
    final paths = [for (final file in hits.take(4)) file.path].join(', ');
    stderr.writeln(
      'FAIL: expected $description; found ${hits.length}'
      '${paths.isEmpty ? '' : ': $paths'}',
    );
    exit(1);
  }
  return hits[0];
}

/// The bytes of [file], or a failure naming the read error.
Uint8List readOrAbort(File file) {
  try {
    return file.readAsBytesSync();
  } on FileSystemException catch (e) {
    stderr.writeln('FAIL: could not read ${file.path}: $e');
    exit(1);
  }
}

/// Extracts [archive] into [destination] with `unzip`, or fails naming both.
void unzipInto(File archive, Directory destination) {
  ProcessResult result;
  try {
    result = Process.runSync('unzip', [
      '-q',
      archive.path,
      '-d',
      destination.path,
    ]);
  } on ProcessException catch (e) {
    stderr.writeln('FAIL: could not run `unzip` on ${archive.path}: $e');
    exit(1);
  }
  if (result.exitCode != 0) {
    stderr.writeln('FAIL: could not extract ${archive.path}: ${result.stderr}');
    exit(1);
  }
}

/// Collects passing and failing checks; every failure names expected/found.
class Report {
  final _failures = <String>[];

  /// Whether every check so far passed.
  bool get passed => _failures.isEmpty;

  /// Records one check of [description], printing the outcome.
  void check(String description, {required bool ok, String? found}) {
    if (ok) {
      print('OK: $description');
    } else {
      stderr.writeln(
        'FAIL: expected $description; found ${found ?? 'nothing'}',
      );
      _failures.add(description);
    }
  }
}

/// Whether [haystack] holds [needle] as contiguous bytes.
bool hasBytes(Uint8List haystack, List<int> needle) {
  if (needle.isEmpty) return true;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var hit = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return true;
  }
  return false;
}

/// The sha256 hex digest of [file], or a failure naming what failed.
String sha256(File file) {
  final attempts = [
    ['sha256sum', file.path],
    ['shasum', '-a', '256', file.path],
  ];
  for (final attempt in attempts) {
    ProcessResult result;
    try {
      result = Process.runSync(attempt.first, attempt.sublist(1));
    } on ProcessException {
      continue;
    }
    if (result.exitCode == 0) {
      final digest = (result.stdout as String).trim().split(RegExp(r'\s+'));
      if (digest.isNotEmpty && digest.first.isNotEmpty) return digest.first;
    }
    stderr.writeln(
      'FAIL: `${attempt.join(' ')}` failed on ${file.path}: ${result.stderr}',
    );
    exit(1);
  }
  stderr.writeln(
    'FAIL: no sha256 tool (tried sha256sum and shasum) for ${file.path}',
  );
  exit(1);
}
