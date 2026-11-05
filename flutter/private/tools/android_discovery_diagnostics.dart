/// Diagnostics for an Android emulator that adb never discovers.
///
/// The launcher appends the block built here to a boot timeout (or an adb
/// `device 'emulator-N' not found`), so the test log explains the failure.
/// [buildAndroidDiscoveryDiagnostics] is pure and unit-tested;
/// [collectAndroidDiscoveryDiagnostics] gathers its inputs and never throws.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One diagnostic value, or the reason it could not be collected.
class DiagValue {
  const new({this.text, this.reason});

  final String? text;
  final String? reason;

  /// The value, or `unavailable: <reason>`.
  String get rendered => text ?? 'unavailable: $reason';
}

/// Liveness and namespace facts for one process.
class ProcessDiagnostics {
  const new({
    required this.alive,
    required this.pidNs,
    required this.netNs,
  });

  final DiagValue alive;
  final DiagValue pidNs;
  final DiagValue netNs;
}

/// The ports the launcher chose, plus the port lines the emulator printed.
class DiscoveryPorts {
  const new({
    required this.consolePort,
    required this.adbPort,
    required this.adbServerPort,
    required this.logLines,
  });

  final int consolePort;
  final int adbPort;
  final int adbServerPort;
  final List<String> logLines;
}

/// Everything [buildAndroidDiscoveryDiagnostics] prints.
class DiscoveryDiagnostics {
  const new({
    required this.testTmpDir,
    required this.ports,
    required this.adbDevices,
    required this.discoveryDir,
    required this.adb,
    required this.emulator,
  });

  /// `TEST_TMPDIR`; the only host path the block may show (relative to it).
  final String testTmpDir;
  final DiscoveryPorts ports;
  final DiagValue adbDevices;
  final DiagValue discoveryDir;
  final ProcessDiagnostics adb;
  final ProcessDiagnostics emulator;
}

/// Live inputs for [collectAndroidDiscoveryDiagnostics].
class DiscoveryProbe {
  const new({
    required this.adbBinary,
    required this.runtimeEnv,
    required this.scratchDir,
    required this.testTmpDir,
    required this.ports,
    required this.emulator,
  });

  final String adbBinary;
  final Map<String, String> runtimeEnv;
  final String scratchDir;
  final String testTmpDir;
  final DiscoveryPorts ports;
  final ({int pid, bool alive}) emulator;
}

/// Total time the diagnostic collection may take.
const Duration discoveryDiagnosticsBudget = Duration(seconds: 20);

/// Whether an emulator log [line] reports a port.
bool isEmulatorPortLine(String line) => line.toLowerCase().contains('port');

/// Hides host paths (all but `TEST_TMPDIR`, shown as `$TEST_TMPDIR`) and
/// `token`/`secret`/`password`/`key`-style values in [text].
String redactDiagnostics(String text, String testTmpDir) {
  final String scoped = testTmpDir.isEmpty
      ? text
      : text.replaceAll(testTmpDir, r'$TEST_TMPDIR');
  return scoped
      .replaceAll(
        RegExp(r'''(?<![\w$/.:-])/[^\s'":,;()\[\]]+'''),
        '<host-path>',
      )
      .replaceAllMapped(
        RegExp(
          r'(token|secret|passw(or)?d|auth|key)(\s*[=:]\s*)\S+',
          caseSensitive: false,
        ),
        (m) => '${m[1]}${m[3]}<redacted>',
      );
}

/// Formats the labelled diagnostic block. Pure: inputs in, string out.
String buildAndroidDiscoveryDiagnostics(DiscoveryDiagnostics d) {
  String r(String s) => redactDiagnostics(s, d.testTmpDir);
  String indent(String s) => '  ${r(s).split('\n').join('\n  ')}';
  final DiscoveryPorts p = d.ports;
  return <String>[
    '--- Android emulator discovery diagnostics ---',
    'adb devices -l (hermetic adb environment):',
    indent(d.adbDevices.rendered),
    'ports: emulator console ${p.consolePort}, emulator adb ${p.adbPort}, adb server ${p.adbServerPort}',
    'port lines printed by the emulator:',
    indent(p.logLines.isEmpty ? '(none)' : p.logLines.join('\n')),
    'emulator discovery directory (names, sizes, modes):',
    indent(d.discoveryDir.rendered),
    _processBlock('adb server', d.adb, r),
    _processBlock('emulator', d.emulator, r),
    '--- end of diagnostics ---',
  ].join('\n');
}

String _processBlock(
  String name,
  ProcessDiagnostics proc,
  String Function(String) r,
) => [
  '$name process: alive: ${r(proc.alive.rendered)}',
  '  pid namespace: ${r(proc.pidNs.rendered)}',
  '  net namespace: ${r(proc.netNs.rendered)}',
].join('\n');

/// Whether [error] is an emulator discovery failure for [serial]: a boot
/// timeout or adb reporting `device '<serial>' not found`.
bool isDiscoveryFailure(Object error, String serial) =>
    error is TimeoutException ||
    (error is StateError &&
        error.message.contains("device '$serial' not found"));

/// [message] with the diagnostic [block] after it; the message stays first.
String withDiscoveryDiagnostics(String message, String block) =>
    '$message\n\n$block';

/// [error] rebuilt with [block] appended, keeping its type.
Object decorateDiscoveryFailure(Object error, String block) => switch (error) {
  TimeoutException(:final message, :final duration) => TimeoutException(
    withDiscoveryDiagnostics(message ?? 'Timed out', block),
    duration,
  ),
  StateError(:final message) => StateError(
    withDiscoveryDiagnostics(message, block),
  ),
  _ => error,
};

/// Collects the diagnostic block. Never throws and never takes longer than
/// [discoveryDiagnosticsBudget]; what cannot be collected reads
/// `unavailable: <reason>`.
Future<String> collectAndroidDiscoveryDiagnostics(DiscoveryProbe p) async {
  try {
    return await _collectDiagnostics(p).timeout(discoveryDiagnosticsBudget);
  } on Object catch (e) {
    final gone = DiagValue(
      reason: 'collection failed: ${e.runtimeType}',
    );
    final proc = ProcessDiagnostics(
      alive: gone,
      pidNs: gone,
      netNs: gone,
    );
    return buildAndroidDiscoveryDiagnostics(
      DiscoveryDiagnostics(
        testTmpDir: p.testTmpDir,
        ports: p.ports,
        adbDevices: gone,
        discoveryDir: gone,
        adb: proc,
        emulator: proc,
      ),
    );
  }
}

Future<String> _collectDiagnostics(DiscoveryProbe p) async {
  final int? adbPid = _findAdbServerPid(p.ports.adbServerPort);
  return buildAndroidDiscoveryDiagnostics(
    DiscoveryDiagnostics(
      testTmpDir: p.testTmpDir,
      ports: p.ports,
      adbDevices: await _adbDevices(p),
      discoveryDir: _listDiscoveryDirs(p.scratchDir),
      adb: _processDiagnostics(
        adbPid,
        adbPid == null ? null : Directory('/proc/$adbPid').existsSync(),
      ),
      emulator: _processDiagnostics(p.emulator.pid, p.emulator.alive),
    ),
  );
}

Future<DiagValue> _adbDevices(DiscoveryProbe p) async {
  const limit = Duration(seconds: 5);
  try {
    final Process proc = await Process.start(
      p.adbBinary,
      const <String>['devices', '-l'],
      environment: p.runtimeEnv,
      includeParentEnvironment: false,
    );
    final Future<String> out = proc.stdout.transform(utf8.decoder).join();
    final Future<String> err = proc.stderr.transform(utf8.decoder).join();
    final int code = await proc.exitCode.timeout(
      limit,
      onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        return -1;
      },
    );
    final String text = '${await out}${await err}'.trim();
    return DiagValue(
      text: code == -1 ? '(timed out after ${limit.inSeconds}s)\n$text' : text,
    );
  } on Object catch (e) {
    return DiagValue(reason: 'adb devices -l failed: ${e.runtimeType}');
  }
}

ProcessDiagnostics _processDiagnostics(int? pid, bool? alive) {
  const noPid = DiagValue(reason: 'process id unknown');
  return ProcessDiagnostics(
    alive: alive == null ? noPid : DiagValue(text: alive ? 'yes' : 'no'),
    pidNs: pid == null ? noPid : _readNamespace(pid, 'pid'),
    netNs: pid == null ? noPid : _readNamespace(pid, 'net'),
  );
}

DiagValue _readNamespace(int pid, String kind) {
  try {
    return DiagValue(text: Link('/proc/$pid/ns/$kind').targetSync());
  } on FileSystemException catch (e) {
    return DiagValue(reason: e.osError?.message ?? 'cannot read');
  }
}

/// Lists the directories the emulator registers itself in, under the
/// launcher's isolated `HOME`/`TMPDIR`: names, sizes and modes only.
DiagValue _listDiscoveryDirs(String scratchDir) {
  const rels = [
    'xdg-runtime/avd',
    'android-android/avd',
    '.android/avd',
  ];
  try {
    return DiagValue(
      text: <String>[
        for (final String rel in rels) _listTree(Directory('$scratchDir/$rel')),
      ].join('\n'),
    );
  } on FileSystemException catch (e) {
    return DiagValue(reason: e.osError?.message ?? 'cannot list');
  }
}

String _listTree(Directory dir) {
  if (!dir.existsSync()) return '${dir.path}: directory does not exist';
  final rows = <String>[];
  for (final FileSystemEntity e in dir.listSync(
    recursive: true,
    followLinks: false,
  )) {
    if (rows.length >= 60) break;
    final FileStat st = e.statSync();
    final String mode = (st.mode & 0xFFF).toRadixString(8);
    rows.add('  ${e.path.substring(dir.path.length + 1)} ${st.size}B $mode');
  }
  return '${dir.path}:\n${rows.join('\n')}';
}

/// The pid of the `adb fork-server` listening on [port], or null.
int? _findAdbServerPid(int port) {
  try {
    for (final FileSystemEntity e in Directory('/proc').listSync()) {
      final int? pid = int.tryParse(e.path.split('/').last);
      final String? cmd = pid == null ? null : _readProc(pid, 'cmdline');
      if (cmd == null || !cmd.contains('fork-server')) continue;
      final String env = _readProc(pid!, 'environ') ?? '';
      if (cmd.contains(':$port') ||
          env.contains('ANDROID_ADB_SERVER_PORT=$port')) {
        return pid;
      }
    }
  } on FileSystemException {
    return null; // no readable /proc: the caller prints "unavailable".
  }
  return null;
}

/// A `/proc/<pid>/<name>` file with NULs as spaces, or null when unreadable.
String? _readProc(int pid, String name) {
  try {
    final List<int> bytes = File('/proc/$pid/$name').readAsBytesSync();
    return latin1.decode(bytes).replaceAll('\u0000', ' ');
  } on FileSystemException {
    return null; // the process exited or belongs to another user.
  }
}
