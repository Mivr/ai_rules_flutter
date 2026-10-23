/// Tests for the host-Python launch guard ([python_host]).
///
/// Runs the real host `python3` from a directory holding a planted module and
/// shows the planted module is not imported, while a module on the user site
/// path still is. Skipped, with a printed reason, only when the host has no
/// `python3`.
import 'dart:io';

import 'package:test/test.dart';

import '../lib/python_host.dart';

/// Probe run through both launchers: reports whether a module from the
/// launcher's working directory and a module from the user site import.
///
/// The report goes to the file named by `sys.argv[1]` rather than stdout,
/// because the launchers forward the child's stdout to this process's.
const String _probeProgram = r'''
import sys

try:
    import ios_screenshot_planted_xyz
    planted = True
except ImportError:
    planted = False

try:
    import ios_screenshot_site_xyz
    site_ok = ios_screenshot_site_xyz.MARKER == 'site-shim-xyz'
except ImportError:
    site_ok = False

with open(sys.argv[1], 'w') as handle:
    handle.write('planted=%s site=%s' % (planted, site_ok))
''';

void main() {
  group('guarded host-Python launch', () {
    late Directory workDir;
    late String? python;

    setUp(() {
      workDir = Directory.systemTemp.createTempSync('python_host_test_');
      python = findHostPython();
    });

    tearDown(() {
      workDir.deleteSync(recursive: true);
    });

    test(
      'stdin program ignores the working directory, keeps user site',
      () async {
        final interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final planted = await _plantModules(interpreter, workDir);
        final out = '${workDir.path}/report.txt';
        final exitCode = await runPythonProgram(
          interpreter,
          _probeProgram,
          [out],
          workingDirectory: planted.plantedDir.path,
          environment: {'PYTHONUSERBASE': planted.userBase},
        );
        expect(exitCode, equals(0));
        expect(File(out).readAsStringSync(), equals('planted=False site=True'));
      },
    );

    test(
      '`-c` program ignores the working directory, keeps user site',
      () async {
        final interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final planted = await _plantModules(interpreter, workDir);
        final out = '${workDir.path}/report_c.txt';
        final exitCode = await runPythonProgramInteractive(
          interpreter,
          _probeProgram,
          [out],
          workingDirectory: planted.plantedDir.path,
          environment: {'PYTHONUSERBASE': planted.userBase},
        );
        expect(exitCode, equals(0));
        expect(File(out).readAsStringSync(), equals('planted=False site=True'));
      },
    );

    test(
      'relative output path still resolves under the working directory',
      () async {
        final interpreter = _skipWhenNoPython(python);
        if (interpreter == null) return;
        final exitCode = await runPythonProgram(
          interpreter,
          'with open(\'rel_report_xyz.txt\', \'w\') as handle:\n'
          '    handle.write(\'here\')\n',
          const [],
          workingDirectory: workDir.path,
        );
        expect(exitCode, equals(0));
        expect(
          File('${workDir.path}/rel_report_xyz.txt').readAsStringSync(),
          equals('here'),
        );
      },
    );

    test('guard helpers strip what the tool did not choose', () {
      final env = guardedPythonEnvironment(
        {'PYTHONPATH': '/attacker', 'EXTRA': 'kept'},
      );
      expect(env['PYTHONPATH'], isNull);
      expect(env['PYTHONSAFEPATH'], equals('1'));
      expect(env['EXTRA'], equals('kept'));
      expect(env['PATH'], equals(Platform.environment['PATH']));
      expect(
        guardPythonProgram('import planted'),
        contains('_flutter_bazel_guard_sys_path'),
      );
    });
  });
}

/// The interpreter to run, or marks the calling test skipped naming why.
String? _skipWhenNoPython(String? python) {
  if (python == null) {
    markTestSkipped(
      'no python3 on PATH, so the launcher tests cannot run; '
      'install Python 3 to run them',
    );
  }
  return python;
}

/// A working directory holding a planted module, and a user base whose site
/// packages hold a shim module the launchers must still import.
Future<({Directory plantedDir, String userBase})> _plantModules(
  String python,
  Directory workDir,
) async {
  final plantedDir = Directory('${workDir.path}/cwd')..createSync();
  File('${plantedDir.path}/ios_screenshot_planted_xyz.py')
      .writeAsStringSync("MARKER = 'planted-xyz'\n");
  final userBase = '${workDir.path}/userbase';
  final usersite = await _userSite(python, userBase);
  File('$usersite/ios_screenshot_site_xyz.py')
      .writeAsStringSync("MARKER = 'site-shim-xyz'\n");
  return (plantedDir: plantedDir, userBase: userBase);
}

/// The user site-packages directory for a `PYTHONUSERBASE` of [userBase].
Future<String> _userSite(String python, String userBase) async {
  final result = await Process.run(
    python,
    ['-c', 'import site; print(site.getusersitepackages())'],
    environment: {'PYTHONUSERBASE': userBase},
  );
  if (result.exitCode != 0) {
    throw StateError('could not read the user site: ${result.stderr}');
  }
  final path = (result.stdout as String).trim().split('\n').last;
  Directory(path).createSync(recursive: true);
  return path;
}
