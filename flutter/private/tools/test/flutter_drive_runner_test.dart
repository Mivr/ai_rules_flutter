/// Unit tests for `flutter_drive_runner.dart` helpers and configuration.
///
/// Tagged `runfiles`: `flutter_drive_runner.dart` imports `package:runfiles`,
/// which Bazel supplies via `@rules_dart//dart/runfiles` on its `dart_test`.
@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

import '../flutter_drive_runner.dart';

void main() {
  group('parseVmServiceLine', () {
    test('extracts device port and auth path from Dart VM service line', () {
      const line =
          'The Dart VM service is listening on http://127.0.0.1:41235/abCD_ef=/';
      final ({int port, String path})? parsed = parseVmServiceLine(line);
      expect(parsed, (port: 41235, path: '/abCD_ef=/'));
    });

    test('supports legacy Observatory prefix and defaults missing path', () {
      const line = 'Observatory is listening on http://127.0.0.1:38000';
      expect(parseVmServiceLine(line), (port: 38000, path: '/'));
    });

    test('returns null on unrelated logcat lines', () {
      expect(parseVmServiceLine('I/flutter: hello world'), isNull);
    });
  });

  group('parseLauncherComponent', () {
    test('parses resolved activity component from brief output', () {
      const brief =
          'priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=false\n'
          'com.example.app/.MainActivity\n';
      expect(
        parseLauncherComponent(brief, 'com.example.app'),
        'com.example.app/.MainActivity',
      );
    });

    test('falls back to FlutterActivity when resolve-activity finds none', () {
      expect(
        parseLauncherComponent('No activity found\n', 'com.example.app'),
        'com.example.app/io.flutter.embedding.android.FlutterActivity',
      );
    });
  });

  group('runStep', () {
    test('names the timed-out step in StepTimeout', () async {
      final completer = Completer<int>();
      await expectLater(
        () => runStep(
          'emulator boot',
          const Duration(milliseconds: 10),
          () => completer.future,
        ),
        throwsA(
          isA<StepTimeout>().having(
            (e) => e.toString(),
            'toString',
            contains('"emulator boot"'),
          ),
        ),
      );
    });
  });

  group('runDrive (offline fakes)', runDriveTests);

  group('DriveConfig.fromEnv', () {
    final runfiles = Runfiles.fromState(directory: '/rf');

    test('resolves executable driver when FLUTTER_DRIVE_DART is unset', () {
      final cfg = DriveConfig.fromEnv(<String, String>{
        'FLUTTER_DRIVE_ANDROID_APK': '_main/app.apk',
        'FLUTTER_DRIVE_ANDROID_PACKAGE': 'com.example.app',
        'FLUTTER_DRIVE_ANDROID_EMULATOR': 'rt/sdk/emulator/emulator',
        'FLUTTER_DRIVE_ANDROID_ADB': 'rt/sdk/platform-tools/adb',
        'FLUTTER_DRIVE_DRIVER': '_main/driver_bin',
        'TEST_TMPDIR': '/scratch',
      }, runfiles);
      expect(cfg.apk, '/rf/_main/app.apk');
      expect(cfg.package, 'com.example.app');
      expect(cfg.runtime.emulator, '/rf/rt/sdk/emulator/emulator');
      expect(cfg.runtime.adb, '/rf/rt/sdk/platform-tools/adb');
      expect(cfg.driver.executable, '/rf/_main/driver_bin');
      expect(cfg.driver.args, isEmpty);
      expect(cfg.tmp, '/scratch');
      expect(vmServiceEnv, 'VM_SERVICE_URL');
    });

    test(
      'resolves toolchain dart + compiled dill when FLUTTER_DRIVE_DART is set',
      () {
        final cfg = DriveConfig.fromEnv(<String, String>{
          'FLUTTER_DRIVE_ANDROID_APK': '_main/app.apk',
          'FLUTTER_DRIVE_ANDROID_PACKAGE': 'com.example.app',
          'FLUTTER_DRIVE_ANDROID_EMULATOR': 'rt/sdk/emulator/emulator',
          'FLUTTER_DRIVE_ANDROID_ADB': 'rt/sdk/platform-tools/adb',
          'FLUTTER_DRIVE_DART': 'dart_sdk/bin/dart',
          'FLUTTER_DRIVE_DRIVER': '_main/test_driver.dill',
          'TEST_TMPDIR': '/scratch',
        }, runfiles);
        expect(cfg.driver.executable, '/rf/dart_sdk/bin/dart');
        expect(
          cfg.driver.args,
          <String>['--enable-asserts', '/rf/_main/test_driver.dill'],
        );
      },
    );

    test('throws FormatException naming missing required env var', () {
      expect(
        () => DriveConfig.fromEnv(const <String, String>{}, runfiles),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('FLUTTER_DRIVE_DRIVER'),
          ),
        ),
      );
    });
  });
}

const String _pkg = 'com.example.app';

const String _adbScript = r'''
d="${0%/*}"
echo "$*" >> "$d/adb.log"
case "$*" in
  *getprop*) if [ -e "$d/never_boot" ]; then echo 0; else echo 1; fi ;;
  *resolve-activity*) echo "com.example.app/.MainActivity" ;;
  *install*) if [ -e "$d/fail_install" ]; then echo nope >&2; exit 1; fi ;;
  *"logcat -v"*)
    echo "I/flutter: The Dart VM service is listening on http://127.0.0.1:41235/tok=/"
    exec /bin/sleep 300 ;;
  *"forward tcp:0"*) echo 5555 ;;
  *"am start"*) echo "Starting: Intent" ;;
esac
exit 0
''';

const String _driverScript = r'''
d="${0%/*}"
{
  echo "VM_SERVICE_URL=$VM_SERVICE_URL"
  echo "FLUTTER_DRIVE_VM_SERVICE_URI=$FLUTTER_DRIVE_VM_SERVICE_URI"
  echo "FLUTTER_DRIVE_ANDROID_SERIAL=$FLUTTER_DRIVE_ANDROID_SERIAL"
  echo "FLUTTER_DRIVE_PACKAGE=$FLUTTER_DRIVE_PACKAGE"
  echo "PATH=$PATH"
} > "$d/driver_env"
read code < "$d/driver_exit"
exit "$code"
''';

/// Fake SDK tree (`adb`, `emulator`, driver, marker files) under [root].
class _Fakes {
  new(this.root) {
    final adbDir = Directory('${root.path}/sdk/platform-tools')
      ..createSync(recursive: true);
    Directory('${root.path}/sdk/emulator').createSync(recursive: true);
    adb = '${adbDir.path}/adb';
    emulator = '${root.path}/sdk/emulator/emulator';
    driver = '${root.path}/driver.sh';
    kvm = '${root.path}/kvm';
    tmp = '${root.path}/tmp';
    File(kvm).writeAsStringSync('');
    Directory(tmp).createSync();
    _script(adb, _adbScript);
    _script(
      emulator,
      'echo \$\$ > "${root.path}/emulator.pid"\nexec /bin/sleep 300\n',
    );
    _script(driver, _driverScript);
    driverExit(0);
  }

  final Directory root;
  late final String adb;
  late final String emulator;
  late final String driver;
  late final String kvm;
  late final String tmp;

  static void _script(String path, String body) {
    File(path).writeAsStringSync('#!/bin/sh\n$body');
    Process.runSync('/bin/chmod', <String>['755', path]);
  }

  String get adbDir => File(adb).parent.path;

  void marker(String name) => File('$adbDir/$name').writeAsStringSync('');

  void driverExit(int code) =>
      File('${root.path}/driver_exit').writeAsStringSync('$code');

  DriveConfig config({String? driverPath}) => DriveConfig(
    apk: '${root.path}/app.apk',
    package: _pkg,
    runtime: (emulator: emulator, adb: adb),
    driver: (executable: driverPath ?? driver, args: const <String>[]),
    tmp: tmp,
    kvmPath: kvm,
    budgetScale: 0.05,
  );

  Map<String, String> driverEnv() => <String, String>{
    for (final l in File('${root.path}/driver_env').readAsLinesSync())
      l.substring(0, l.indexOf('=')): l.substring(l.indexOf('=') + 1),
  };

  /// Asserts the teardown contract: order, emulator killed, scratch gone.
  Future<void> expectCleanup({required bool forwarded}) async {
    final List<String> log = File('$adbDir/adb.log').readAsLinesSync();
    int at(String needle) => log.indexWhere((l) => l.contains(needle));
    final int stop = at('am force-stop $_pkg');
    final int kill = at('kill-server');
    expect(stop, isNonNegative, reason: '$log');
    expect(kill, greaterThan(stop), reason: '$log');
    if (forwarded) {
      final int remove = at('forward --remove');
      expect(remove, isNonNegative, reason: '$log');
      expect(stop, greaterThan(remove), reason: '$log');
    } else {
      expect(at('forward --remove'), -1, reason: '$log');
    }
    expect(kill, log.length - 1, reason: 'adb ran after kill-server: $log');
    final int emuPid = int.parse(
      File('${root.path}/emulator.pid').readAsStringSync().trim(),
    );
    for (var i = 0; i < 50 && _alive(emuPid); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(_alive(emuPid), isFalse, reason: 'emulator still running');
    expect(Directory(tmp).listSync(), isEmpty, reason: 'scratch leaked');
  }

  static bool _alive(int pid) =>
      Process.runSync('/bin/kill', <String>['-0', '$pid']).exitCode == 0;
}

/// Records what `runDrive` writes to stderr.
class _Capture implements Stdout {
  new(this.sink);
  final StringBuffer sink;

  @override
  void writeln([Object? object = '']) => sink.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void runDriveTests() {
  late Directory root;
  late _Fakes fakes;
  setUp(() {
    root = Directory.systemTemp.createTempSync('drive_fakes');
    fakes = _Fakes(root);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('passes the driver its environment and returns exit 0', () async {
    expect(await runDrive(fakes.config()), 0);
    final Map<String, String> env = fakes.driverEnv();
    const uri = 'http://127.0.0.1:5555/tok=/';
    expect(env['VM_SERVICE_URL'], uri);
    expect(env['FLUTTER_DRIVE_VM_SERVICE_URI'], uri);
    expect(env['FLUTTER_DRIVE_ANDROID_SERIAL'], startsWith('emulator-'));
    expect(env['FLUTTER_DRIVE_PACKAGE'], _pkg);
    expect(env['PATH'], fakes.adbDir);
    await fakes.expectCleanup(forwarded: true);
  });

  test('returns the driver exit status and cleans up when it fails', () async {
    fakes.driverExit(3);
    expect(await runDrive(fakes.config()), 3);
    await fakes.expectCleanup(forwarded: true);
  });

  test('cleans up after the driver cannot be started', () async {
    final int code = await runDrive(
      fakes.config(driverPath: '${root.path}/missing_driver'),
    );
    expect(code, 1);
    await fakes.expectCleanup(forwarded: true);
  });

  test('cleans up after a launch failure', () async {
    fakes.marker('fail_install');
    expect(await runDrive(fakes.config()), 1);
    await fakes.expectCleanup(forwarded: false);
  });

  test('a boot that never completes times out and cleans up', () async {
    fakes.marker('never_boot');
    final err = StringBuffer();
    final int code = await IOOverrides.runZoned(
      () => runDrive(fakes.config()),
      stderr: () => _Capture(err),
    );
    expect(code, 1);
    expect(
      err.toString(),
      contains('timed out after 9s during step "emulator boot"'),
    );
    await fakes.expectCleanup(forwarded: false);
  });
}
