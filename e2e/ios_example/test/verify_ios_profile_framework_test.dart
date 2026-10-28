/// Verifies the device profile `App.framework` is a profile build, not a
/// release build that silently linked the release engine.
///
/// Reads `:app_profile_device`, a `flutter_application` built through the
/// `ios_device_opt` transition (`-c opt`, `arm64`, iOS device platform,
/// `//flutter:profile`). The target forwards the App.framework built in that
/// configuration and the Flutter.framework the configuration linked, plus a
/// unique symlink to the engine binary (`app_profile_device.linked_engine`)
/// so the test can hash exactly the engine that binary would load. Its `data`
/// also carries the pinned profile and release engine xcframeworks.
///
/// Checks:
///
/// * `App.framework/App` is a 64-bit arm64 Mach-O whose `LC_BUILD_VERSION`
///   platform is iOS (2), so it is a device binary;
/// * the snapshot features name arm64 and ios and do NOT contain `product`,
///   which a release snapshot carries;
/// * the linked engine binary's sha256 equals the pinned profile engine's
///   device binary and differs from the pinned release engine's, so a build
///   that silently selected release fails.
///
/// Every failed assertion prints what it expected and what it found. A
/// missing input fails the test; nothing here is ever skipped.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'ios_test_support.dart';
import 'macho_snapshot.dart';

/// Basename of the symlink the transitioned bundle writes for the engine it
/// linked.
const _linkedEngineName = 'app_profile_device.linked_engine';

void main() {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  if (srcDir == null) _abort('FAIL: missing TEST_SRCDIR env var');
  final files = filesUnder(Directory(srcDir));

  final app = oneFile(
    files,
    _isAppBinary,
    'one profile App.framework/App',
  );
  final linked = oneFile(
    files,
    (file) => file.uri.pathSegments.last == _linkedEngineName,
    'the transitioned bundle engine symlink $_linkedEngineName',
  );
  final pinnedProfile = oneFile(
    files,
    (file) => _isDeviceEngine(file) && _isProfileRepo(file),
    'one pinned profile engine binary for ios-arm64',
  );
  final pinnedRelease = oneFile(
    files,
    (file) => _isDeviceEngine(file) && !_isProfileRepo(file),
    'one pinned release engine binary for ios-arm64',
  );

  final report = Report();
  final appBytes = readOrAbort(app);
  _checkMachO(report, app.path, appBytes);
  _checkFeatures(report, app.path, appBytes);

  final linkedHash = _sha256(linked);
  final profileHash = _sha256(pinnedProfile);
  final releaseHash = _sha256(pinnedRelease);
  report
    ..check(
      'the linked engine binary to be the pinned profile engine '
      '($profileHash)',
      ok: linkedHash == profileHash,
      found: '$linkedHash at ${linked.path}',
    )
    ..check(
      'the linked engine binary to differ from the pinned release engine '
      '($releaseHash)',
      ok: linkedHash != releaseHash,
      found: '$linkedHash at ${linked.path}',
    )
    ..check(
      'the pinned profile and release engines to differ, so the comparison '
      'cannot pass vacuously',
      ok: profileHash != releaseHash,
      found: 'profile $profileHash, release $releaseHash',
    );

  if (!report.passed) exit(1);
  print(
    'PASS: the device profile App.framework is an arm64 iOS AOT snapshot '
    'without the product feature and links the pinned profile engine',
  );
}

/// Whether [file] is the App.framework binary the profile application built.
bool _isAppBinary(File file) => file.path.endsWith('App.framework/App');

/// Whether [file] is the device slice of a Flutter.xcframework.
bool _isDeviceEngine(File file) {
  final path = file.path;
  return path.endsWith(
        'Flutter.xcframework/ios-arm64/Flutter.framework/Flutter',
      ) &&
      !path.contains('extension_safe');
}

/// Whether [file] lives in the repository for the profile engine.
bool _isProfileRepo(File file) =>
    file.path.contains('flutter_ios_engine_profile');

/// Checks the App binary is a 64-bit arm64 Mach-O for iOS, not the simulator.
void _checkMachO(Report report, String path, Uint8List bytes) {
  MachOInfo macho;
  try {
    macho = parseMachO(bytes);
  } on FormatException catch (e) {
    report.check(
      'an App binary whose Mach-O header and load commands parse',
      ok: false,
      found: '$e in $path',
    );
    return;
  }
  report
    ..check(
      'an App binary that is a 64-bit Mach-O for arm64',
      ok: macho.cpuType == cpuArm64,
      found: 'cputype 0x${macho.cpuType.toRadixString(16)} in $path',
    )
    ..check(
      'an App binary targeting iOS (platform $platformIos), not the simulator',
      ok: macho.platform == platformIos,
      found: macho.platform == null
          ? 'no LC_BUILD_VERSION in $path'
          : 'platform ${macho.platform} in $path',
    );
}

/// Checks the snapshot was compiled for iOS on arm64 and is not a release
/// snapshot.
void _checkFeatures(Report report, String path, Uint8List bytes) {
  final features = snapshotFeatures(bytes);
  final words = features.split(' ');
  report
    ..check(
      'an App snapshot whose features name arm64 and ios',
      ok: words.contains('arm64') && words.contains('ios'),
      found: features.isEmpty ? 'no features string in $path' : features,
    )
    ..check(
      'an App snapshot without the product feature (a profile, not release, '
      'snapshot)',
      ok: features.isNotEmpty && !words.contains('product'),
      found: features.isEmpty ? 'no features string in $path' : features,
    );
}

/// Stops the test with [message]: a missing input fails, never skips.
Never _abort(String message) {
  stderr.writeln(message);
  exit(1);
}

/// The sha256 hex digest of [file], or a failure naming what failed.
String _sha256(File file) {
  final attempts = [
    ['shasum', '-a', '256', file.path],
    ['sha256sum', file.path],
  ];
  for (final attempt in attempts) {
    ProcessResult result;
    try {
      result = Process.runSync(attempt.first, attempt.sublist(1));
    } on ProcessException {
      continue;
    }
    if (result.exitCode == 0) {
      final digest = (result.stdout as String).trim().split(RegExp(r'\s+'));
      if (digest.isNotEmpty && digest.first.isNotEmpty) return digest.first;
    }
    _abort(
      'FAIL: `${attempt.join(' ')}` failed on ${file.path}: ${result.stderr}',
    );
  }
  _abort('FAIL: no sha256 tool (tried shasum and sha256sum) for ${file.path}');
}
