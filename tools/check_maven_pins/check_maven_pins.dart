/// Validates that Android e2e workspaces have pinned rules_android_maven locks.
///
/// Run from the repo root with no arguments (CI runs it as a job step):
/// `bazel run //tools/check_maven_pins`.
library;

import 'dart:io';

import 'pins.dart';

/// CLI entry point for checking `rules_android_maven` lock files.
void main(List<String> args) {
  final String rootPath =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;

  if (!File('$rootPath/MODULE.bazel').existsSync() ||
      !Directory('$rootPath/e2e').existsSync()) {
    stderr.writeln('error: run //tools/check_maven_pins from the repo root');
    exit(2);
  }

  final List<String>? workspaces = args.isNotEmpty ? args : null;
  final List<String> errors = checkAllWorkspaces(
    rootPath: rootPath,
    workspaces: workspaces,
  );

  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('error: $error');
    }
    exit(1);
  }

  final int count = workspaces?.length ?? defaultAndroidWorkspaces.length;
  stdout.writeln(
    'ok: $count Android workspaces have valid rules_android_maven locks',
  );
}
