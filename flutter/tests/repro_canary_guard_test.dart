/// Static guard test for Gate 07 reproducibility canary and its CI job.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Finds the rules_flutter repository root directory.
String _locateRepoRoot() {
  final buildDir = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (buildDir != null && buildDir.isNotEmpty && _hasRepoMarkers(buildDir)) {
    return buildDir;
  }
  final anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor != null && anchor.isNotEmpty && srcdir != null) {
    try {
      var candidate = File(
        File('$srcdir/$anchor').resolveSymbolicLinksSync(),
      ).parent;
      for (var depth = 0; depth < 8; depth++) {
        if (_hasRepoMarkers(candidate.path)) {
          return candidate.path;
        }
        candidate = candidate.parent;
      }
    } on FileSystemException {
      // Fall through to Directory.current resolution below.
    }
  }
  var currentDir = Directory.current;
  for (var depth = 0; depth < 8; depth++) {
    if (_hasRepoMarkers(currentDir.path)) {
      return currentDir.path;
    }
    currentDir = currentDir.parent;
  }
  throw StateError('Failed to discover rules_flutter repository root');
}

/// Returns true if [path] looks like the repository root.
bool _hasRepoMarkers(String path) =>
    File('$path/MODULE.bazel').existsSync() &&
    Directory('$path/flutter').existsSync() &&
    Directory('$path/e2e').existsSync();

/// Extracts the block corresponding to the two-space-indented [jobName] in [yaml].
String _extractJobBlock(String yaml, String jobName) {
  final header = '\n  $jobName:\n';
  final start = yaml.indexOf(header);
  expect(
    start,
    isNot(-1),
    reason: 'Job $jobName not found at two-space indentation in YAML',
  );
  final bodyStart = start + header.length;
  final nextJobRegex = RegExp(r'\n  [a-zA-Z0-9_-]+:\n');
  final nextJobMatch = nextJobRegex.firstMatch(yaml.substring(bodyStart));
  if (nextJobMatch == null) {
    return yaml.substring(bodyStart);
  }
  return yaml.substring(bodyStart, bodyStart + nextJobMatch.start);
}

void main() {
  final root = _locateRepoRoot();

  test('e2e/repro_canary workspace structure and nondeterministic action', () {
    final buildFile = File('$root/e2e/repro_canary/BUILD.bazel');
    final moduleFile = File('$root/e2e/repro_canary/MODULE.bazel');
    final nondetFile = File('$root/e2e/repro_canary/nondet.bzl');
    final bazelVersionFile = File('$root/e2e/repro_canary/.bazelversion');
    final lockFile = File('$root/e2e/repro_canary/MODULE.bazel.lock');

    expect(buildFile.existsSync(), isTrue, reason: 'BUILD.bazel must exist');
    expect(
      buildFile.readAsStringSync().trim(),
      isNotEmpty,
      reason: 'BUILD.bazel must not be empty',
    );

    expect(moduleFile.existsSync(), isTrue, reason: 'MODULE.bazel must exist');
    expect(nondetFile.existsSync(), isTrue, reason: 'nondet.bzl must exist');

    expect(
      bazelVersionFile.existsSync(),
      isTrue,
      reason: '.bazelversion must exist',
    );
    expect(
      bazelVersionFile.readAsStringSync().trim(),
      equals('9.3.0'),
      reason: '.bazelversion must contain 9.3.0',
    );

    expect(
      lockFile.existsSync(),
      isTrue,
      reason: 'MODULE.bazel.lock must exist',
    );
    expect(
      lockFile.readAsStringSync().trim(),
      isNotEmpty,
      reason: 'MODULE.bazel.lock must not be empty',
    );

    final nondetContent = nondetFile.readAsStringSync();
    expect(
      nondetContent.contains('/dev/urandom'),
      isTrue,
      reason: 'nondet.bzl must declare an action reading /dev/urandom',
    );
    expect(
      nondetContent.contains('rule('),
      isTrue,
      reason: 'nondet.bzl must declare a rule',
    );
  });

  test(
    'ci.yaml reproducibility job configuration and distinct output bases',
    () {
      final ciFile = File('$root/.github/workflows/ci.yaml');
      expect(ciFile.existsSync(), isTrue, reason: 'ci.yaml must exist');
      final ciContent = ciFile.readAsStringSync();

      final jobBlock = _extractJobBlock(ciContent, 'reproducibility');
      expect(
        jobBlock.contains('e2e/repro_canary'),
        isTrue,
        reason: 'reproducibility job block must name e2e/repro_canary',
      );

      final outputBaseMatches = RegExp(
        r"""--output_base=([^\s"'`]+)""",
      ).allMatches(jobBlock).map((m) => m.group(1)).toSet();
      expect(
        outputBaseMatches.length,
        greaterThanOrEqualTo(2),
        reason: 'reproducibility job must contain at least two distinct --output_base= values',
      );

      expect(
        jobBlock.contains('gates'),
        isFalse,
        reason: 'reproducibility job block must contain no "gates"',
      );
    },
  );

  test('conclusion job requires reproducibility', () {
    final ciContent = File('$root/.github/workflows/ci.yaml')
        .readAsStringSync();
    final conclusionBlock = _extractJobBlock(ciContent, 'conclusion');

    final needsMatch = RegExp(r'needs:\s*\[([^\]]+)\]')
        .firstMatch(conclusionBlock);
    expect(
      needsMatch,
      isNotNull,
      reason: 'conclusion job must have inline needs: [...] list',
    );

    final items = needsMatch!
        .group(1)!
        .split(',')
        .map((s) => s.trim())
        .toList();
    expect(
      items.contains('reproducibility'),
      isTrue,
      reason: 'conclusion job inline needs must contain reproducibility',
    );
  });

  test('repro_canary is not excused in coverage or in positive workflow sweeps', () {
    final coverageContent = File(
      '$root/tools/check_e2e_coverage/coverage.dart',
    ).readAsStringSync();
    expect(
      coverageContent.contains("'e2e/repro_canary'") ||
          coverageContent.contains('"e2e/repro_canary"'),
      isFalse,
      reason: 'coverage.dart uncoveredReasons must not name e2e/repro_canary',
    );

    final workflowsDir = Directory('$root/.github/workflows');
    final workflowFiles = workflowsDir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.yaml') || f.path.endsWith('.yml'),
    );

    final matrixRegex = RegExp(
      r'workspace:\s*(\[[^\]]*\brepro_canary\b[^\]]*\]|\brepro_canary\b)',
    );
    final workspacesRegex = RegExp(r'WORKSPACES:.*?\brepro_canary\b');

    for (final wf in workflowFiles) {
      final text = wf.readAsStringSync();
      expect(
        matrixRegex.hasMatch(text),
        isFalse,
        reason:
            '${wf.path} must not name repro_canary in a workspace: matrix entry',
      );
      expect(
        workspacesRegex.hasMatch(text),
        isFalse,
        reason: '${wf.path} must not name repro_canary in a WORKSPACES: list',
      );
    }
  });
}
