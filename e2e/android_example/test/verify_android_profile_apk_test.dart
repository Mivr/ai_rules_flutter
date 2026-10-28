/// Verifies the Android profile APK really ships a profile build.
///
/// Reads `:app_profile_apk`, built behind `profile_build` (`-c opt`, the arm64
/// Android platform and `//flutter:profile`), which forwards the APK and the
/// pinned profile engine jar; `:app_release_check`, the same application
/// under the default release configuration; and the pinned release engine
/// jar. It then checks:
///
/// * `lib/arm64-v8a/libflutter.so` in the APK is byte-identical (sha256) to
///   the pinned profile engine's and differs from the pinned release engine's,
///   so a build that silently selected release fails;
/// * `lib/arm64-v8a/libapp.so` is a 64-bit aarch64 ELF whose snapshot features
///   do not contain the `product` feature, so it is an AOT profile snapshot;
/// * the profile APK declares INTERNET from
///   `android/app/src/profile/AndroidManifest.xml`, and the release APK built
///   from the same main manifest does not.
///
/// Every failed assertion prints what it expected and what it found. A
/// missing input fails the test; nothing here is ever skipped.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'android_test_support.dart';
import 'axml.dart';

/// The ABI directory the profile APK and engine jars carry.
const _abi = 'arm64-v8a';

/// Path of the engine library inside an APK or engine jar.
const _flutterSo = 'lib/$_abi/libflutter.so';

/// Path of the application's AOT snapshot inside an APK.
const _appSo = 'lib/$_abi/libapp.so';

/// `e_machine` of aarch64 ELF binaries.
const _emAarch64 = 0xb7;

void main() {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  if (srcDir == null) _abort('FAIL: missing TEST_SRCDIR env var');
  final files = filesUnder(Directory(srcDir));
  final profileApk = oneFile(
    files,
    (file) => file.path.endsWith('/app_profile.apk'),
    'one app_profile.apk',
  );
  final releaseApk = oneFile(
    files,
    (file) => file.path.endsWith('/app_release_check.apk'),
    'one app_release_check.apk',
  );
  final profileJar = oneFile(
    files,
    _isProfileEngineJar,
    'one pinned profile engine jar',
  );
  final releaseJar = oneFile(
    files,
    (file) => _isEngineJar(file) && !_isProfileEngineJar(file),
    'one pinned release engine jar',
  );

  final tmp = Directory.systemTemp.createTempSync('android_profile_apk_');
  try {
    final profileDir = Directory('${tmp.path}/profile')..createSync();
    final releaseDir = Directory('${tmp.path}/release')..createSync();
    final profileJarDir = Directory('${tmp.path}/profile_jar')..createSync();
    final releaseJarDir = Directory('${tmp.path}/release_jar')..createSync();
    unzipInto(profileApk, profileDir);
    unzipInto(releaseApk, releaseDir);
    unzipInto(profileJar, profileJarDir);
    unzipInto(releaseJar, releaseJarDir);

    final report = Report();
    _checkEngines(
      report,
      File('${profileDir.path}/$_flutterSo'),
      File('${profileJarDir.path}/$_flutterSo'),
      File('${releaseJarDir.path}/$_flutterSo'),
    );
    _checkAppSnapshot(report, File('${profileDir.path}/$_appSo'));
    _checkPermissions(
      report,
      File('${profileDir.path}/AndroidManifest.xml'),
      File('${releaseDir.path}/AndroidManifest.xml'),
    );

    if (!report.passed) exit(1);
    print(
      'PASS: the Android profile APK links the pinned profile engine, ships '
      'a non-product AOT snapshot and carries the profile INTERNET grant',
    );
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

/// Stops the test with [message]: a missing input fails, never skips.
Never _abort(String message) {
  stderr.writeln(message);
  exit(1);
}

/// Whether [file] is a `stripped.jar` from the arm64 Flutter engine repository.
bool _isEngineJar(File file) =>
    file.path.endsWith('/stripped.jar') &&
    (file.path.contains('flutter_android_engine_arm64/') ||
        _isProfileEngineJar(file));

/// Whether [file] is the pinned profile engine repository's `stripped.jar`.
bool _isProfileEngineJar(File file) =>
    file.path.endsWith('/stripped.jar') &&
    file.path.contains('flutter_android_engine_arm64_profile/');

/// Checks the APK engine is the pinned profile engine, not the release one.
void _checkEngines(Report report, File apkEngine, File profile, File release) {
  final apkHash = sha256(apkEngine);
  final profileHash = sha256(profile);
  final releaseHash = sha256(release);
  report
    ..check(
      'the APK libflutter.so to be the pinned profile engine ($profileHash)',
      ok: apkHash == profileHash,
      found: '$apkHash at ${apkEngine.path}',
    )
    ..check(
      'the APK libflutter.so to differ from the pinned release engine '
      '($releaseHash)',
      ok: apkHash != releaseHash,
      found: '$apkHash at ${apkEngine.path}',
    )
    ..check(
      'the pinned profile and release engines to differ, so the comparison '
      'cannot pass vacuously',
      ok: profileHash != releaseHash,
      found: 'profile $profileHash, release $releaseHash',
    );
}

/// Checks [file] is a 64-bit aarch64 ELF, then checks its snapshot features.
void _checkAppSnapshot(Report report, File file) {
  final bytes = readOrAbort(file);
  final isElf =
      bytes.length > 20 &&
      bytes[0] == 0x7f &&
      bytes[1] == 0x45 &&
      bytes[2] == 0x4c &&
      bytes[3] == 0x46 &&
      bytes[4] == 2 &&
      bytes[5] == 1;
  final machine = bytes.length > 20 ? bytes[18] | (bytes[19] << 8) : -1;
  report.check(
    'libapp.so to be a 64-bit little-endian aarch64 ELF',
    ok: isElf && machine == _emAarch64,
    found: isElf
        ? 'ELF machine 0x${machine.toRadixString(16)} at ${file.path}'
        : 'no ELF header at ${file.path}',
  );
  if (!isElf || machine != _emAarch64) return;

  final features = _features(bytes);
  final words = features.split(' ');
  report
    ..check(
      'the libapp.so snapshot features to name arm64 and android',
      ok: words.contains('arm64') && words.contains('android'),
      found: features.isEmpty ? 'no features string in ${file.path}' : features,
    )
    ..check(
      'the libapp.so snapshot not to contain the product feature (profile, '
      'not release)',
      ok: features.isNotEmpty && !words.contains('product'),
      found: features.isEmpty ? 'no features string in ${file.path}' : features,
    );
}

/// Checks the profile manifest has INTERNET and the release manifest does not.
void _checkPermissions(Report report, File profile, File release) {
  Set<String> profilePermissions;
  Set<String> releasePermissions;
  try {
    profilePermissions = usesPermissions(readOrAbort(profile));
    releasePermissions = usesPermissions(readOrAbort(release));
  } on FormatException catch (e) {
    report.check('both manifests to parse as AXML', ok: false, found: '$e');
    return;
  }
  const internet = 'android.permission.INTERNET';
  report
    ..check(
      'the profile APK to declare $internet from its profile variant manifest',
      ok: profilePermissions.contains(internet),
      found: profilePermissions.isEmpty
          ? 'no permissions'
          : profilePermissions.join(', '),
    )
    ..check(
      'the release APK not to declare $internet',
      ok: !releasePermissions.contains(internet),
      found: releasePermissions.isEmpty
          ? 'no permissions'
          : releasePermissions.join(', '),
    );
}

/// The VM features string in [bytes], or empty when the binary holds none.
///
/// The VM embeds a space-separated word list naming the target, for example
/// `product no-asan ... arm64 android` in a release build or
/// `release no-asan ... arm64 android` in a profile build. It is stored glued
/// to a hash with no separator, so this finds the printable run and returns it
/// from the mode marker.
String _features(Uint8List bytes) {
  final text = latin1.decode(bytes);
  for (final run in RegExp('[ -~]{16,}').allMatches(text)) {
    final raw = run.group(0)!;
    if (!raw.contains('arm64') ||
        !raw.contains('android') ||
        !raw.contains('no-asan')) {
      continue;
    }
    for (final marker in ['product ', 'no-product ', 'release ']) {
      final at = raw.indexOf(marker);
      if (at < 0) continue;
      final features = raw.substring(at);
      final words = features.split(' ');
      if (words.contains('arm64') &&
          words.contains('android') &&
          words.contains('no-asan')) {
        return features;
      }
    }
  }
  return '';
}
