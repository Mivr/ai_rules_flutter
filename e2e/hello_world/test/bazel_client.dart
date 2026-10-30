/// Resolves the host executables the macOS stage-clean test spawns.
///
/// Bazel starts a test with a sanitized environment, so a nested `bazel` is
/// not on `PATH` and a bare-name spawn cannot succeed. The target explicitly
/// inherits `BAZEL` and `PATH`; this helper turns those values into an
/// executable path, or into one failure that names what was tried and why.
library;

import 'dart:io';

/// A host tool the test could not resolve or start.
class ToolUnavailable implements Exception {
  /// Creates the failure for [tool], tried as [tried] during [step].
  ToolUnavailable({
    required this.tool,
    required this.tried,
    required this.step,
  });

  /// The tool the test needed, such as `bazel` or `unzip`.
  final String tool;

  /// The override value or `PATH` search the resolver tried.
  final String tried;

  /// The test step that needed the tool.
  final String step;

  @override
  String toString() => 'cannot run $tool for $step: $tried';
}

/// Resolves the `bazel` client for one nested build of [step].
///
/// `BAZEL` wins when it is set and non-empty, so a wrapper can stand in for
/// Bazel; otherwise `bazel` is searched on the inherited `PATH`. The target
/// declares both variables in `env_inherit`, because Bazel sanitizes the
/// environment a test starts with.
String resolveBazelClient({
  required Map<String, String> environment,
  required String step,
}) => resolveHostTool(
  tool: 'bazel',
  overrideVariable: 'BAZEL',
  environment: environment,
  step: step,
);

/// Resolves [tool] for [step] from [environment].
///
/// The [overrideVariable] value wins when it is set and non-empty. Otherwise
/// every `PATH` entry is tried in order, and a bare override value is tried
/// the same way. [ToolUnavailable] names the tool, the value or search path
/// tried, and the step, so a missing client fails clearly instead of
/// surfacing a bare `ProcessException` from the later spawn.
String resolveHostTool({
  required String tool,
  required Map<String, String> environment,
  required String step,
  String? overrideVariable,
}) {
  if (overrideVariable != null) {
    final overrideValue = environment[overrideVariable];
    if (overrideValue != null && overrideValue.isNotEmpty) {
      return _resolveOverride(
        tool: tool,
        variable: overrideVariable,
        value: overrideValue,
        environment: environment,
        step: step,
      );
    }
  }
  final pathValue = environment['PATH'];
  final found = _findOnPath(tool, pathValue);
  if (found != null) {
    return found;
  }
  throw ToolUnavailable(
    tool: tool,
    tried: pathValue == null || pathValue.isEmpty
        ? 'PATH is not set'
        : 'no $tool on PATH=$pathValue',
    step: step,
  );
}

/// Runs [executable] for [step] and turns a spawn failure into
/// [ToolUnavailable].
///
/// A non-zero exit stays in the returned [ProcessResult], so the caller keeps
/// reporting the command's own output and exit code.
ProcessResult runHostTool({
  required String executable,
  required List<String> args,
  required String step,
  String? workingDirectory,
}) {
  try {
    return Process.runSync(
      executable,
      args,
      workingDirectory: workingDirectory,
    );
  } on ProcessException catch (error) {
    throw ToolUnavailable(
      tool: executable,
      tried: error.message.isEmpty ? '$error' : error.message,
      step: step,
    );
  }
}

/// Resolves an [variable] value that is either an executable path or the name
/// of an executable on `PATH`.
String _resolveOverride({
  required String tool,
  required String variable,
  required String value,
  required Map<String, String> environment,
  required String step,
}) {
  if (_isExecutable(value)) {
    return value;
  }
  if (!_namesAPath(value)) {
    final found = _findOnPath(value, environment['PATH']);
    if (found != null) {
      return found;
    }
  }
  throw ToolUnavailable(tool: tool, tried: '$variable=$value', step: step);
}

/// Whether [value] names a path rather than a bare executable name.
bool _namesAPath(String value) => value.contains('/') || value.contains(r'\');

/// The first executable [tool] in [pathValue], in `PATH` order.
String? _findOnPath(String tool, String? pathValue) {
  if (pathValue == null || pathValue.isEmpty) {
    return null;
  }
  final separator = Platform.isWindows ? ';' : ':';
  for (final directory in pathValue.split(separator)) {
    if (directory.isEmpty) {
      continue;
    }
    for (final candidate in _candidates(directory, tool)) {
      if (_isExecutable(candidate)) {
        return candidate;
      }
    }
  }
  return null;
}

/// The file names [tool] may carry inside [directory] on this host.
Iterable<String> _candidates(String directory, String tool) sync* {
  final path = '$directory${Platform.pathSeparator}$tool';
  yield path;
  if (Platform.isWindows && !tool.toLowerCase().endsWith('.exe')) {
    yield '$path.exe';
  }
}

/// Whether [path] is a regular file this host can execute.
bool _isExecutable(String path) {
  if (FileSystemEntity.typeSync(path) != FileSystemEntityType.file) {
    return false;
  }
  if (Platform.isWindows) {
    return true;
  }
  // Any of the owner/group/other execute bits makes the file spawnable.
  return FileStat.statSync(path).mode & 0x49 != 0;
}
