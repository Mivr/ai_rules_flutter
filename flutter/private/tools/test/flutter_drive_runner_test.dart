/// Unit tests for `flutter_drive_runner.dart` helpers and configuration.
///
/// Tagged `runfiles`: `flutter_drive_runner.dart` imports `package:runfiles`,
/// which Bazel supplies via `@rules_dart//dart/runfiles` on its `dart_test`.
@Tags(['runfiles'])
library;

import 'dart:async';

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
