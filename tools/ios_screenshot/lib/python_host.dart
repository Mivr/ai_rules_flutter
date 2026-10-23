/// Shared host-Python driving for the iOS screenshot helpers.
///
/// `screenshot` and `tunneld` run their programs through a host `python3`
/// (see `screenshot.dart` for why), so both need the same lookup, the same
/// missing-interpreter diagnostic, and the same spawn plumbing. Dependency-
/// free (`dart:io` only) so the helpers stay standalone `dart_binary` targets.
import 'dart:io';

/// Names tried on PATH, most preferred first. `python` is a fallback for
/// machines where only that name exists (notably Windows); `python3` stays
/// first so a Python 2 `python` elsewhere on PATH never shadows it.
List<String> get _pythonNames => Platform.isWindows
    ? const ['python', 'python3']
    : const ['python3', 'python'];

/// Candidate file names for [name] in one PATH entry.
List<String> _candidates(String dir, String name) {
  if (Platform.isWindows) {
    return ['$dir\\$name.exe', '$dir\\$name.bat', '$dir\\$name.cmd'];
  }
  return ['$dir/$name'];
}

/// The host Python interpreter to run, or null when there is none.
///
/// Searches each PATH entry for the preferred names (specific files, never
/// a bare name handed to the shell), mirroring the `HostTool` lookup the
/// dev tool uses for `adb` and friends: absence is reported, not guessed.
String? findHostPython() {
  final path = Platform.environment['PATH'] ?? '';
  final separator = Platform.isWindows ? ';' : ':';
  for (final name in _pythonNames) {
    for (final dir in path.split(separator)) {
      if (dir.isEmpty) continue;
      for (final candidate in _candidates(dir, name)) {
        if (FileSystemEntity.isFileSync(candidate)) return candidate;
      }
    }
  }
  return null;
}

/// Diagnostic for a missing interpreter, naming what to install.
String missingPythonMessage({required String purpose}) {
  final names = _pythonNames.join(' or ');
  return 'Could not find $names on PATH, which is needed for $purpose.\n'
      'Install Python 3 (https://www.python.org/downloads/) and pymobiledevice3:\n'
      '  python3 -m pip install pymobiledevice3';
}

/// Preamble prepended to every program this package runs.
///
/// Python puts the current working directory first on `sys.path` for both
/// launch forms used here (`python -` reads the program from stdin,
/// `python -c` takes it as an argument: `sys.path[0]` is `''` either way).
/// A module sitting in the directory the user runs from would then shadow
/// the real one, and the tunnel daemon runs as root, so this drops the
/// directory entries before the program's own imports run. Only `sys` is
/// imported before the drop, because it is a builtin module: importing
/// anything else first could itself resolve through the hostile directory.
///
/// Defense in depth with [guardedPythonEnvironment]'s `PYTHONSAFEPATH`: that
/// variable only exists from Python 3.11, while this preamble runs on every
/// version down to 3.8. The launcher's working directory is left alone, so a
/// relative screenshot output path still names a file under the directory the
/// user ran from.
const String _pythonPathGuard = r'''
def _flutter_bazel_guard_sys_path():
    import sys as _sys

    for _entry in list(_sys.path):
        if _entry == '' or _entry == '.':
            _sys.path.remove(_entry)
    # The placeholder is gone, so this resolves to the real stdlib.
    import os as _os

    try:
        _cwd = _os.getcwd()
    except OSError:
        return
    for _entry in list(_sys.path):
        try:
            _absolute = _os.path.abspath(_entry)
        except OSError:
            continue
        if _os.path.normcase(_absolute) == _os.path.normcase(_cwd):
            _sys.path.remove(_entry)


_flutter_bazel_guard_sys_path()
del _flutter_bazel_guard_sys_path
''';

/// [program] with the current-directory import guard prepended.
///
/// The single place both launchers ([runPythonProgram] and
/// [runPythonProgramInteractive]) get the protection from: neither keeps its
/// own copy.
String guardPythonProgram(String program) => '$_pythonPathGuard\n$program';

/// The environment a guarded host-Python child runs with.
///
/// Starts from [overrides] over this process's environment, then drops
/// `PYTHONPATH` (a directory the tool did not choose must not outrank the
/// installed packages either) and sets `PYTHONSAFEPATH=1` (honoured from
/// Python 3.11, ignored before, where the preamble above does the work).
/// User-site installs and virtualenvs keep working: nothing here touches
/// `site` or the interpreter's own prefix. Pass with
/// `includeParentEnvironment: false` so the dropped variable stays dropped.
Map<String, String> guardedPythonEnvironment([
  Map<String, String>? overrides,
]) {
  final env = Map<String, String>.from(Platform.environment);
  if (overrides != null) env.addAll(overrides);
  env.remove('PYTHONPATH');
  env['PYTHONSAFEPATH'] = '1';
  return env;
}

/// Whether this process runs as root (POSIX `id -u`; always false where
/// that question has no meaning).
bool isRoot() {
  if (Platform.isWindows) return false;
  try {
    final result = Process.runSync('id', ['-u']);
    return result.exitCode == 0 && (result.stdout as String).trim() == '0';
  } on ProcessException {
    return false;
  }
}

/// Runs [program] with [python], forwarding its stdout/stderr and returning
/// its exit code. The program travels on stdin (`python - ...`), so no
/// source file is staged anywhere; [args] reach it as `sys.argv[1:]`.
///
/// When the run fails because `pymobiledevice3` is not installed, the
/// interpreter's own `ModuleNotFoundError` is followed by the install
/// remedy (the program's other diagnostics pass through verbatim, since
/// callers match on them).
Future<int> runPythonProgram(
  String python,
  String program,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    python,
    ['-', ...args],
    workingDirectory: workingDirectory,
    environment: guardedPythonEnvironment(environment),
    includeParentEnvironment: false,
  );
  process.stdin.write(guardPythonProgram(program));
  await process.stdin.close();
  final stderrBytes = <int>[];
  await Future.wait([
    stdout.addStream(process.stdout),
    process.stderr.listen((chunk) {
      stderr.add(chunk);
      stderrBytes.addAll(chunk);
    }).asFuture<void>(),
  ]);
  final exitCode = await process.exitCode;
  if (exitCode != 0) {
    final stderrText = String.fromCharCodes(stderrBytes);
    if (stderrText.contains('ModuleNotFoundError') &&
        stderrText.contains('pymobiledevice3')) {
      stderr.writeln(
        "pymobiledevice3 is not installed for $python, which iOS device commands need.\n"
        'Install it:\n'
        '  $python -m pip install pymobiledevice3',
      );
    }
  }
  return exitCode;
}

/// Runs [program] with [python] as a long-lived foreground process: stdio
/// is the terminal's, and the program travels as `python -c` (stdin is
/// taken, so it cannot carry the program). Returns the exit code.
Future<int> runPythonProgramInteractive(
  String python,
  String program,
  List<String> args, {
  String? workingDirectory,
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    python,
    ['-c', guardPythonProgram(program), ...args],
    mode: ProcessStartMode.inheritStdio,
    workingDirectory: workingDirectory,
    environment: guardedPythonEnvironment(environment),
    includeParentEnvironment: false,
  );
  return process.exitCode;
}
