/// Warm-versus-one-shot kernel identity check.
///
/// Run from the repo root with no arguments (CI runs it as a job step):
/// `bazel run //tools/incr_kernel_identity`.
///
/// Proves the design claim in docs/incremental-kernel.md against the real
/// compiler: with `--@rules_flutter//flutter:incremental_kernel`, a warm
/// persistent worker's `.dill` output is byte-for-byte the one-shot output
/// for the same inputs, after a sequence of edits on `e2e/hello_world`'s
/// `//:hello_world`. Prints its own elapsed time and exits 0 when every
/// comparison holds, 1 otherwise.
library;

import 'dart:io';

import 'identity.dart';

Future<void> main() async {
  // Locate the repo root. BUILD_WORKSPACE_DIRECTORY is set by `bazel run`.
  final rootPath =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'] ??
      Directory.current.path;
  if (!File('$rootPath/MODULE.bazel').existsSync() ||
      !Directory('$rootPath/e2e/hello_world').existsSync()) {
    stderr.writeln(
      'error: run //tools/incr_kernel_identity from the repo root',
    );
    exit(2);
  }
  final run = IdentityRun(
    // `$BAZEL` substitutes a wrapper; otherwise the wrapper the user invoked
    // is recovered from PATH (never bazelisk's raw download shim).
    bazel: await resolveBazel(override: Platform.environment['BAZEL']),
    repoRoot: rootPath,
  );
  final stopwatch = Stopwatch()..start();
  var code = 0;
  try {
    await run.run();
  } on IdentityFailure catch (e) {
    stderr.writeln(e);
    code = 1;
  } finally {
    stopwatch.stop();
  }
  print(
    'identity-check: ${code == 0 ? 'PASS' : 'FAIL'} '
    'in ${stopwatch.elapsed.inSeconds}s',
  );
  exit(code);
}
