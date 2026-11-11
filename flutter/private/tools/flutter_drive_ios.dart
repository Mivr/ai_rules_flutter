/// iOS simulator leg of `flutter_drive_test`.
///
/// Boots (or reuses) a simulator the way `flutter_integration_test` does,
/// installs the debug `.ipa`, launches it and reads the app's Dart VM service
/// URI from the launch console. The simulator shares the host's loopback, so
/// the URI is usable as printed. The driver runs on the host with that URI and
/// the test's exit status is the driver's. The app is terminated and a
/// simulator this run booted is shut down however the run ends; a timeout
/// names the step that timed out.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'flutter_drive_common.dart';
import 'flutter_integration_test_ios.dart';
import 'test_support.dart';

/// Everything the iOS run reads from the test environment.
class IosDriveConfig {
  /// Creates an iOS drive configuration.
  const new({
    required this.app,
    required this.bundleId,
    required this.driver,
    required this.tmp,
  });

  /// Reads the configuration from the test [env] and runfiles [r].
  factory fromEnv(Map<String, String> env, Runfiles r) => IosDriveConfig(
    app: r.rlocation(requiredEnv(env, 'FLUTTER_DRIVE_IOS_APP')),
    bundleId: requiredEnv(env, 'FLUTTER_DRIVE_IOS_BUNDLE_ID'),
    driver: driverCommandFromEnv(env, r),
    tmp: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
  );

  /// The simulator `.ipa` (or `.app` directory) under test.
  final String app;

  /// Bundle identifier the app is installed and launched under.
  final String bundleId;

  /// Host command that runs the driver.
  final DriverCommand driver;

  /// Scratch parent directory.
  final String tmp;
}

/// One simulator session: boot, install, launch and tear down.
class IosDriveSession {
  /// Creates a simulator session for [config].
  new(this.config, {CommandSpawner? spawner})
    : spawner = spawner ?? ProcessCommandSpawner();

  /// The run's inputs.
  final IosDriveConfig config;

  /// How `xcrun` children are started.
  final CommandSpawner spawner;

  String? _udid;
  bool _bootedHere = false;
  bool _launched = false;
  Directory? _scratch;
  Process? _console;

  /// The booted simulator's UDID, or an empty string before boot.
  String get udid => _udid ?? '';

  /// The session scratch directory, or [IosDriveConfig.tmp] before boot.
  String get scratchPath => _scratch?.path ?? config.tmp;

  Future<void> _simctl(String step, List<String> args, Duration limit) async {
    final CommandResult r;
    try {
      r = await runSimctl(
        spawner,
        <String>['simctl', ...args],
        timeout: limit,
      );
    } on BootFailure catch (e) {
      if (e.reason.contains('timed out')) throw StepTimeout(step, limit);
      throw StateError('$step: ${e.reason}');
    }
    if (r.exitCode != 0) {
      throw StateError(
        'simctl ${args.first} failed (${r.exitCode}): ${r.stderrText.trim()}',
      );
    }
  }

  /// Boots or reuses a simulator, remembering whether this run booted it.
  Future<void> boot() async {
    _scratch = Directory(
      '${config.tmp}/drive_ios_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    final SimulatorChoice choice = await runStep(
      'simulator boot',
      const Duration(seconds: 900),
      () => bootSimulator(
        BootOptions(
          spawner: spawner,
          bootstatusTimeout: const Duration(seconds: 600),
          log: print,
        ),
      ),
    );
    _udid = choice.device.udid;
    _bootedHere = !choice.wasBooted;
  }

  /// Installs the app, launches it and returns the VM service URI it prints.
  Future<String> launchApp() async {
    final String appDir = _resolveApp();
    await _simctl('install app', <String>[
      'install',
      udid,
      appDir,
    ], const Duration(seconds: 180));
    final Process console = await Process.start('xcrun', <String>[
      'simctl',
      'launch',
      '--console-pty',
      '--terminate-running-process',
      udid,
      config.bundleId,
    ]);
    _console = console;
    _launched = true;
    final Future<({int port, String path})> found = _vmServiceLines(console);
    final ({int port, String path}) svc = await runStep(
      'wait for VM service',
      const Duration(seconds: 300),
      () => found,
    );
    return 'http://127.0.0.1:${svc.port}${svc.path}';
  }

  Future<({int port, String path})> _vmServiceLines(Process console) {
    final merged = StreamController<List<int>>();
    var open = 2;
    void done() {
      if (--open == 0) unawaited(merged.close());
    }

    console.stdout.listen(merged.add, onDone: done);
    console.stderr.listen(merged.add, onDone: done);
    return merged.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map(parseVmServiceLine)
        .where((m) => m != null)
        .map((m) => m!)
        .first;
  }

  String _resolveApp() {
    if (Directory(config.app).existsSync()) return config.app;
    if (!File(config.app).existsSync()) {
      throw StateError('iOS simulator app not found at "${config.app}".');
    }
    return extractIpaApp(
      ipaBytes: File(config.app).readAsBytesSync(),
      destDir: Directory('$scratchPath/app')..createSync(recursive: true),
    );
  }

  /// Terminates the app, shuts down a simulator this run booted and drops the
  /// scratch; never throws.
  Future<void> dispose() async {
    _console?.kill(ProcessSignal.sigkill);
    final String id = udid;
    if (id.isNotEmpty && _launched) {
      await teardownQuietly(
        () => _simctl('terminate app', <String>[
          'terminate',
          id,
          config.bundleId,
        ], const Duration(seconds: 60)),
      );
    }
    if (id.isNotEmpty && _bootedHere) {
      await teardownQuietly(
        () => _simctl('shut down simulator', <String>[
          'shutdown',
          id,
        ], const Duration(seconds: 120)),
      );
    }
    final Directory? dir = _scratch;
    if (dir != null && dir.existsSync()) {
      cleanupQuietly(() => dir.deleteSync(recursive: true));
    }
  }
}

/// Boots, launches and drives on the simulator; always cleans up. Returns the
/// exit status.
Future<int> runIosDrive(IosDriveConfig config) async {
  final session = IosDriveSession(config);
  try {
    await session.boot();
    final String uri = await session.launchApp();
    return await runDriverProcess(
      config.driver,
      session.scratchPath,
      <String, String>{
        'PATH': '/usr/bin:/bin',
        vmServiceEnv: uri,
        'FLUTTER_DRIVE_VM_SERVICE_URI': uri,
        'FLUTTER_DRIVE_IOS_UDID': session.udid,
        'FLUTTER_DRIVE_PACKAGE': config.bundleId,
      },
    );
  } on Object catch (e) {
    stderr.writeln('flutter_drive_test: $e');
    return 1;
  } finally {
    await session.dispose();
  }
}
