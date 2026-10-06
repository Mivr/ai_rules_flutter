/// Runs `frontend_server` for a kernel compile and drops the lines of its
/// batch protocol from the output, so a successful build prints nothing.
///
/// Outside interactive mode `frontend_server` still frames each compile for a
/// client that is not there: `result <uuid>`, the bare `<uuid>`, and
/// `<uuid> <output.dill> <error count>`. No flag turns them off, and Bazel
/// shows an action's output on success. Every other line, errors above all,
/// passes through unchanged, as does the exit code.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart kernel_filter.dart -- <executable> <arguments>
library;

import 'dart:io';

const _uuid =
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';

final _boundary = RegExp('^(result $_uuid|$_uuid|$_uuid \\S.* \\d+)\$');

/// Whether [line] is one of `frontend_server`'s batch-protocol lines.
bool isBoundaryLine(String line) => _boundary.hasMatch(line);

/// [output] without its batch-protocol lines.
String withoutBoundaryLines(String output) {
  final kept = [
    for (final line in output.split('\n'))
      if (!isBoundaryLine(line)) line,
  ];
  return kept.join('\n');
}

Future<void> main(List<String> argv) async {
  exit(await runFiltered(argv, stdout, stderr));
}

/// Runs the command [argv] names after `--`, writing its output to [out] and
/// [err] without the protocol lines; returns its exit code.
Future<int> runFiltered(
  List<String> argv,
  StringSink out,
  StringSink err,
) async {
  final i = argv.indexOf('--');
  if (i < 0 || i + 1 >= argv.length) {
    err.writeln('Usage: dart kernel_filter.dart -- <executable> <arguments>');
    return 2;
  }
  final result = await Process.run(argv[i + 1], argv.sublist(i + 2));
  out.write(withoutBoundaryLines(result.stdout as String));
  err.write(result.stderr as String);
  return result.exitCode;
}
