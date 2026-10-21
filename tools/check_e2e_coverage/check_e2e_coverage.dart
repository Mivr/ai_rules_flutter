/// Fails when an e2e module is in no CI workflow without a recorded reason.
///
/// Run from the repo root with no arguments (CI runs it as a job step):
/// `bazel run //tools/check_e2e_coverage`.
///
/// A module is any directory holding a `MODULE.bazel`, at `e2e/*/` or one
/// level deeper (`e2e/_overlay_tests/*/`). A module counts as covered when a
/// workflow under `.github/workflows/` references it outside of comments,
/// either as `working-directory: e2e/<module>`, a `workspace: <module>`
/// matrix entry, or a `WORKSPACES:` list token. Anything else must appear in
/// [_uncoveredReasons] with a one-line reason saying why it has no workflow.
/// A reason for a module that IS covered is also an error, so the table
/// cannot go stale: removing a module from every workflow without recording
/// why fails this check.
library;

import 'dart:io';

/// Module short name -> one line saying why no workflow runs it.
const Map<String, String> _uncoveredReasons = {
  'ios_example':
      'Apple-only; the iOS simulator signal is covered by hello_world\'s '
      'ios_bundle_build_test, the full app awaits a macOS runner slot.',
  'macos_example':
      'Apple-only; the macOS bundle signal is covered by hello_world\'s '
      'macos_bundle_build_test, the full app awaits a macOS runner slot.',
  'windows_example':
      'Windows-only; the Windows runner signal is covered by hello_world, '
      'the full app exceeds the windows-latest runner\'s commit limit.',
  'multi_window_example':
      'Apple-only (macOS bundles + iOS scenes); no macOS slot is left in '
      'push CI under the 2-job budget shared with rules_dart.',
  'link_hooks':
      'Local-only overlay fixture; runs by hand with its sibling override '
      'of rules_flutter, which push CI never checks out.',
  'native_assets_synthetic':
      'Local-only overlay fixture; runs by hand with its sibling override '
      'of rules_flutter, which push CI never checks out.',
};

final RegExp _workspaceRef = RegExp(
  r'working-directory:\s*e2e/([A-Za-z0-9_./-]+)',
);
final RegExp _matrixRef = RegExp(r'workspace:\s*([A-Za-z0-9_-]+)');
final RegExp _workspacesRef = RegExp(r'WORKSPACES:\s*(.+)');

/// Drops `#` comments; workflows carry no `#` inside quoted strings.
String _stripComments(String text) =>
    text.split('\n').map((line) => line.split('#').first).join('\n');

/// Short module names referenced by any workflow.
Set<String> _workflowModules(Directory workflowsDir) {
  final covered = <String>{};
  final entries = workflowsDir.listSync().whereType<File>().where(
    (f) => f.path.endsWith('.yaml') || f.path.endsWith('.yml'),
  );
  for (final file in entries) {
    final text = _stripComments(file.readAsStringSync());
    for (final match in _workspaceRef.allMatches(text)) {
      covered.add(match.group(1)!.split('/').last);
    }
    for (final match in _matrixRef.allMatches(text)) {
      covered.add(match.group(1)!);
    }
    for (final match in _workspacesRef.allMatches(text)) {
      for (final token in match.group(1)!.trim().split(RegExp(r'\s+'))) {
        final bare = token.replaceAll(RegExp('^["\']+|["\']+\$'), '');
        if (bare.isNotEmpty && bare != r'$WORKSPACES') covered.add(bare);
      }
    }
  }
  return covered;
}

/// Short name -> workspace-relative dir for every directory with a
/// `MODULE.bazel`.
Map<String, String> _e2eModules(Directory e2eDir, String rootPath) {
  final modules = <String, String>{};
  final top = e2eDir.listSync().whereType<Directory>();
  final nested = top.expand((d) => d.listSync().whereType<Directory>());
  for (final dir in [...top, ...nested]) {
    if (File('${dir.path}/MODULE.bazel').existsSync()) {
      final name = dir.path.split(Platform.pathSeparator).last;
      final relative = dir.path.startsWith('$rootPath/')
          ? dir.path.substring(rootPath.length + 1)
          : dir.path;
      modules[name] = relative;
    }
  }
  return modules;
}

void main() {
  // Locate the repo root. BUILD_WORKSPACE_DIRECTORY is set by `bazel run`.
  final rootPath =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  if (!File('$rootPath/MODULE.bazel').existsSync() ||
      !Directory('$rootPath/e2e').existsSync()) {
    stderr.writeln(
      'error: run //tools/check_e2e_coverage from the repo root',
    );
    exit(2);
  }
  final modules = _e2eModules(Directory('$rootPath/e2e'), rootPath);
  final covered = _workflowModules(Directory('$rootPath/.github/workflows'));

  final errors = <String>[];
  for (final name in modules.keys.toList()..sort()) {
    final inWorkflow = covered.contains(name);
    final hasReason = _uncoveredReasons.containsKey(name);
    if (inWorkflow && hasReason) {
      errors.add(
        "e2e module '$name' is covered by a workflow but still has an "
        '_uncoveredReasons entry; remove the stale reason',
      );
    } else if (!inWorkflow && !hasReason) {
      errors.add(
        "e2e module '$name' (${modules[name]}) is in no workflow and has no "
        '_uncoveredReasons entry; add it to a workflow or record why it '
        'has none',
      );
    }
  }
  for (final name in _uncoveredReasons.keys.toList()..sort()) {
    if (!modules.containsKey(name)) {
      errors.add(
        "_uncoveredReasons names '$name', which is no e2e module; remove it",
      );
    }
  }
  for (final name in covered.toList()..sort()) {
    if (!modules.containsKey(name)) {
      errors.add(
        "workflow references e2e module '$name', which does not exist; "
        'fix the typo or add the module',
      );
    }
  }
  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('error: $error');
    }
    exit(1);
  }
  final coveredCount = modules.keys.where(covered.contains).length;
  print(
    'ok: $coveredCount e2e modules covered by workflows, '
    '${_uncoveredReasons.length} with recorded reasons',
  );
}
