@Tags(['runfiles'])
library;

import 'dart:io';

import 'package:test/test.dart';

import '../flutter_integration_test_android.dart' as android;

void main() {
  group('Android emulator, AVD & KVM helpers', () {
    test('builds hermetic Android runtime environment and emulator flags', () {
      final env = android.buildAndroidRuntimeEnvironment(
        sdkRoot: '/runfiles/flutter_android_headless_runtime/sdk',
        sysrootDir: '/runfiles/flutter_android_headless_runtime/sysroot',
        scratchDir: '/tmp/android_scratch',
        avdHomeDir: '/tmp/android_scratch/.android/avd',
        adbServerPort: 15037,
      );
      expect(
        env['PATH'],
        '/runfiles/flutter_android_headless_runtime/sdk/platform-tools:'
        '/runfiles/flutter_android_headless_runtime/sdk/emulator',
      );
      expect(
        env['LD_LIBRARY_PATH'],
        '/runfiles/flutter_android_headless_runtime/sdk/emulator/lib64:'
        '/runfiles/flutter_android_headless_runtime/sdk/emulator/lib64/gles_swiftshader:'
        '/runfiles/flutter_android_headless_runtime/sysroot/usr/lib/x86_64-linux-gnu:'
        '/runfiles/flutter_android_headless_runtime/sysroot/lib/x86_64-linux-gnu',
      );
      expect(
        env['ANDROID_SDK_ROOT'],
        '/runfiles/flutter_android_headless_runtime/sdk',
      );
      expect(env['ANDROID_ADB_SERVER_PORT'], '15037');

      final args = android.buildAndroidEmulatorArguments(
        avdName: 'test',
        consolePort: 5554,
        adbPort: 5555,
      );
      expect(args, containsAllInOrder(['-avd', 'test']));
      expect(args, contains('-no-window'));
      expect(args, contains('-no-audio'));
      expect(args, contains('-no-snapshot'));
      expect(args, contains('-wipe-data'));
      expect(args, containsAllInOrder(['-gpu', 'swiftshader_indirect']));
      expect(args, containsAllInOrder(['-accel', 'on']));
      expect(args, containsAllInOrder(['-ports', '5554,5555']));

      final avdIni = android.buildAndroidAvdIniContent(
        avdDir: '/tmp/android_scratch/.android/avd/test.avd',
      );
      expect(
        avdIni,
        contains('path=/tmp/android_scratch/.android/avd/test.avd'),
      );
      expect(avdIni, contains('target=android-35'));

      final avdConfig = android.buildAndroidAvdConfigContent();
      expect(avdConfig, contains('abi.type=x86_64'));
      expect(avdConfig, contains('hw.gpu.mode=swiftshader_indirect'));
      expect(
        avdConfig,
        contains('image.sysdir.1=system-images/android-35/aosp_atd/x86_64/'),
      );
    });

    test('verifyKvmAvailable fails clearly when KVM device is missing', () {
      expect(
        () => android.verifyKvmAvailable(
          '/tmp/non_existent_kvm_device_${DateTime.now().microsecondsSinceEpoch}',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('KVM device not found'),
              contains('/dev/kvm'),
            ),
          ),
        ),
      );
    });

    test('verifyKvmAvailable succeeds on a readable and writable file', () {
      final tmpDir = Directory.systemTemp.createTempSync('kvm_check_test_');
      try {
        final fakeKvm = File('${tmpDir.path}/kvm')..writeAsStringSync('');
        android.verifyKvmAvailable(fakeKvm.path);
      } finally {
        if (tmpDir.existsSync()) {
          tmpDir.deleteSync(recursive: true);
        }
      }
    });

    test(
      'allocateAndroidEmulatorPorts returns valid even/odd port pair',
      () async {
        final ports = await android.allocateAndroidEmulatorPorts();
        expect(ports.adbServerPort, greaterThan(0));
        expect(ports.consolePort, inInclusiveRange(5554, 5680));
        expect(ports.consolePort.isEven, isTrue);
        expect(ports.adbPort, ports.consolePort + 1);
      },
    );
  });
}
