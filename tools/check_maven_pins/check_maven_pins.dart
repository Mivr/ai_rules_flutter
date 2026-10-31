/// Validates that Android e2e workspaces have pinned rules_android_maven locks.
///
/// Run from the repo root with no arguments (CI runs it as a job step):
/// `bazel run //tools/check_maven_pins`.
library;

import 'dart:io';

import 'pins.dart';

void main(List<String> args) {
  final rootPath =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;

  final sep = Platform.pathSeparator;
  if (!File('$rootPath${sep}MODULE.bazel').existsSync() ||
      !Directory('$rootPath${sep}e2e').existsSync()) {
    stderr.writeln('error: run //tools/check_maven_pins from the repo root');
    exit(2);
  }

  final workspaces = args.isNotEmpty ? args : null;
  final errors = checkAllWorkspaces(
    rootPath: rootPath,
    workspaces: workspaces,
  );

  if (errors.isNotEmpty) {
    for (final error in errors) {
      stderr.writeln('error: $error');
    }
    exit(1);
  }

  final count = workspaces?.length ?? defaultAndroidWorkspaces.length;
  print('ok: $count Android workspaces have valid rules_android_maven locks');
}
