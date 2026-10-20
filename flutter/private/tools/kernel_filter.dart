/// Runs `frontend_server` for a kernel compile and drops the lines of its
/// batch protocol from the output, so a successful build prints nothing.
///
/// Outside interactive mode `frontend_server` still frames each compile for a
/// client that is not there: `result <uuid>`, the bare `<uuid>`, and
/// `<uuid> <output.dill> <error count>`. No flag turns them off, and Bazel
/// shows an action's output on success. Every other line, errors above all,
/// passes through unchanged, as does the exit code.
///
/// Before the compiler runs, every declared source's directives are checked
/// against the declared inputs (`directive_guard.dart`): a directive that
/// names no declared file — a `file:` URI in any spelling, any other
/// unexpected scheme, or a relative URI climbing out of the declared inputs —
/// fails the build, under every strategy. The compile mounts only its staging
/// root, so an undeclared file is not there to be read whatever its spelling.
///
/// After the compiler runs, its `+file://` dependency lines are verified
/// against the same declared inputs: a read of a file the action did not
/// declare fails the build instead of caching bytes Bazel never reruns on.
/// The lines are dropped either way, so a successful build stays silent.
///
/// A plugin that is not available on the compiled platform fails the build
/// with a hint saying so: shipping without its registration (where `flutter
/// build` would fail) is never the right recovery.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart kernel_filter.dart --declared-inputs <manifest> -- <executable> <arguments>
library;

import 'dart:io';

import 'directive_guard.dart';

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

/// Splits [stdoutText] into the `+uri` dependency lines the compiler printed
/// and everything else (without its batch-protocol lines).
({List<String> reads, String rest}) splitDependencyLines(String stdoutText) {
  final reads = <String>[];
  final kept = <String>[];
  for (final line in stdoutText.split('\n')) {
    if (isBoundaryLine(line)) continue;
    if (line.startsWith('+')) {
      reads.add(line);
    } else {
      kept.add(line);
    }
  }
  return (reads: reads, rest: kept.join('\n'));
}

/// The exec-root-relative path a `+file://` dependency [line] names, or null
/// when the line names no file under the compile's working directory. Percent
/// escapes decode once, the way the front end spells them.
String? dependencyExecPath(String line) {
  final text = line.substring(1).trim();
  final Uri uri;
  try {
    uri = Uri.parse(text);
  } on FormatException {
    return null;
  }
  if (uri.scheme != 'file') return null;
  final path = uri.toFilePath().replaceAll(r'\', '/');
  final cwd = Directory.current.path.replaceAll(r'\', '/');
  if (path == cwd) return '';
  if (!path.startsWith('$cwd/')) return null;
  return path.substring(cwd.length + 1);
}

/// The subset of `frontend_server`'s `+uri` dependency [lines] that names no
/// declared input: each entry is the offending line. [declared] holds the
/// exec-root-relative paths from the `--declared-inputs` manifest, and
/// [extraAllowed] the compiler's own data files (`--packages`,
/// `--native-assets`, `--platform`, `--from-dill`), resolved the same way.
List<String> findUndeclaredReads(
  List<String> lines,
  Set<String> declared,
  Set<String> extraAllowed,
) {
  final undeclared = <String>[];
  for (final line in lines) {
    final path = dependencyExecPath(line);
    if (path == null ||
        (!declared.contains(path) && !extraAllowed.contains(path))) {
      undeclared.add(line);
    }
  }
  return undeclared;
}

/// The value of the single-valued flag [flag] in [cmdArgs] (`--flag value` or
/// `--flag=value`), or null when absent.
String? flagValue(List<String> cmdArgs, String flag) {
  for (var j = 0; j < cmdArgs.length; j++) {
    if (cmdArgs[j] == flag && j + 1 < cmdArgs.length) return cmdArgs[j + 1];
    if (cmdArgs[j].startsWith('$flag=')) {
      return cmdArgs[j].substring(flag.length + 1);
    }
  }
  return null;
}

/// The values of the repeated flag [flag] in [cmdArgs].
List<String> flagValues(List<String> cmdArgs, String flag) {
  final values = <String>[];
  for (var j = 0; j < cmdArgs.length; j++) {
    if (cmdArgs[j] == flag && j + 1 < cmdArgs.length) {
      values.add(cmdArgs[j + 1]);
    } else if (cmdArgs[j].startsWith('$flag=')) {
      values.add(cmdArgs[j].substring(flag.length + 1));
    }
  }
  return values;
}

/// The exec-root-relative form of the compiler flag value [value] (which the
/// action passes exec-root-relative already), or null for an absolute path.
String? execRelative(String value) {
  final slash = value.replaceAll(r'\', '/');
  if (slash.startsWith('/') || _isWindowsAbsolute(slash)) return null;
  return slash.replaceFirst(RegExp(r'^(?:\./)+'), '');
}

bool _isWindowsAbsolute(String path) =>
    path.length >= 3 &&
    ((path.codeUnitAt(0) >= 0x41 && path.codeUnitAt(0) <= 0x5a) ||
        (path.codeUnitAt(0) >= 0x61 && path.codeUnitAt(0) <= 0x7a)) &&
    path.codeUnitAt(1) == 0x3a &&
    (path.codeUnitAt(2) == 0x2f || path.codeUnitAt(2) == 0x5c);

Future<void> main(List<String> argv) async {
  exit(await runFiltered(argv, stdout, stderr));
}

/// Runs the command [argv] names after `--`, writing its output to [out] and
/// [err] without the protocol and dependency lines; returns its exit code.
///
/// The tool flags before `--` name the compile's declared inputs
/// (`--declared-inputs <manifest>`): the manifest lists one exec-root-relative
/// path per line — the declared sources, then a `# staged` marker, then the
/// staging root's symlinks to them — written by
/// `flutter_kernel_compile_action`. The sources' directives are refused before
/// the compiler runs when they name an undeclared file, and the compiler's own
/// read set is verified against both sections after it runs.
Future<int> runFiltered(
  List<String> argv,
  StringSink out,
  StringSink err,
) async {
  final i = argv.indexOf('--');
  if (i < 0 || i + 1 >= argv.length) {
    err.writeln(
      'Usage: dart kernel_filter.dart --declared-inputs <manifest> -- <executable> <arguments>',
    );
    return 2;
  }
  String? manifestPath;
  for (var j = 0; j < i; j++) {
    if (argv[j] == '--declared-inputs' && j + 1 < i) {
      manifestPath = argv[++j];
    } else {
      err.writeln('kernel_filter: unexpected argument ${argv[j]}.');
      return 2;
    }
  }
  if (manifestPath == null) {
    err.writeln(
      'kernel_filter: missing required --declared-inputs <manifest>.',
    );
    return 2;
  }
  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    err.writeln(
      'kernel_filter: declared-inputs manifest $manifestPath does not exist.',
    );
    return 2;
  }
  // The manifest lists the declared sources, then `# staged`, then the
  // staging root's symlinks to them: the guard scans the sources (the links
  // hold the same bytes), while the read set allows both spellings.
  final sources = <String>[];
  final declared = <String>{};
  var staged = false;
  for (final line in manifest.readAsLinesSync()) {
    final path = line.trim().replaceAll(r'\', '/');
    if (path.isEmpty) continue;
    if (path.startsWith('#')) {
      staged = true;
      continue;
    }
    declared.add(path);
    if (!staged && path.endsWith('.dart')) sources.add(path);
  }
  final executable = argv[i + 1];
  final cmdArgs = argv.sublist(i + 2);

  final fsRoots = flagValues(cmdArgs, '--filesystem-root');
  final guardErrors = findDisallowedFlutterDirectives(
    sources,
    fsRoots,
    tool: 'flutter',
  );
  if (guardErrors.isNotEmpty) {
    for (final error in guardErrors) {
      err.writeln(error);
    }
    return 1;
  }

  final result = await Process.run(executable, cmdArgs);
  if (result.exitCode != 0) {
    final split = splitDependencyLines(result.stdout as String);
    out.write(split.rest);
    err.write(result.stderr as String);
    if ('${result.stdout}${result.stderr}'.contains(
      'is not available on this platform.',
    )) {
      err.writeln(
        'flutter: this compile imports a plugin that is not available on the '
        'compiled platform. Remove the dependency or add a platform '
        'implementation; the build fails instead of shipping without the '
        "plugin's registration.",
      );
    }
    return result.exitCode;
  }

  final split = splitDependencyLines(result.stdout as String);
  final extraAllowed = <String>{};
  for (final flag in [
    '--packages',
    '--native-assets',
    '--platform',
    '--from-dill',
  ]) {
    final value = flagValue(cmdArgs, flag);
    if (value == null) continue;
    final rel = execRelative(value);
    if (rel != null) extraAllowed.add(rel);
  }
  final undeclared = findUndeclaredReads(split.reads, declared, extraAllowed);
  if (undeclared.isNotEmpty) {
    for (final line in undeclared) {
      err.writeln(
        'flutter: the compiler read $line, which is not a declared input of '
        'this compile. Declare the file in `srcs` (typically '
        '`glob(["lib/**/*.dart"])`) or stop importing it.',
      );
    }
    final outputDill = flagValue(cmdArgs, '--output-dill');
    if (outputDill != null) {
      try {
        File(outputDill).deleteSync();
      } on FileSystemException {
        // Already gone; the nonzero exit fails the action either way.
      }
    }
    return 1;
  }
  out.write(split.rest);
  err.write(result.stderr as String);
  return result.exitCode;
}
