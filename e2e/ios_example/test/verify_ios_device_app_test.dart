/// Verifies the unsigned physical-device `.ipa` built from
/// `:app_device_unsigned` is a real device bundle and carries no signature.
///
/// The app is built `-c opt` for `arm64` through `:app_device_unsigned_opt`,
/// the same transition the release framework checks use. It sets
/// `signing = False`, so rules_apple adds its `disable_legacy_signing`
/// feature: no provisioning profile, no codesign action and no secrets.
///
/// The test unzips the archive and asserts, each with its own message naming
/// what it expected and what it found:
///
/// * `Runner.app/Runner` and `Runner.app/Frameworks/App.framework/App` are
///   64-bit arm64 Mach-O binaries whose `LC_BUILD_VERSION` platform is iOS
///   (2), not the simulator (7);
/// * no `embedded.mobileprovision` sits anywhere in `Runner.app`;
/// * there is no `_CodeSignature/CodeResources` and neither binary carries an
///   `LC_CODE_SIGNATURE` load command;
/// * `Info.plist` declares `CFBundleSupportedPlatforms` exactly
///   `["iPhoneOS"]`;
/// * `App.framework/App`'s snapshot VM features start with `product`, so the
///   bundle carries a release/AOT snapshot rather than a debug stub.
///
/// The archive is unpacked with the host `unzip` the test's macOS run already
/// requires; the Mach-O and snapshot bytes are read by the shared reader, and
/// `plutil` converts the bundled binary plist. A missing input fails the test;
/// nothing here is ever skipped.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'ios_bundle_reader.dart';

/// The archive the unsigned device target produces.
const _ipaName = 'app_device_unsigned.ipa';

/// The bundle name `:app_device_unsigned` asks for.
const _bundleName = 'Runner.app';

/// The runner executable inside the bundle.
const _runnerName = 'Runner';

/// The Dart AOT dylib inside the engine framework.
const _appFrameworkBinary = 'Frameworks/App.framework/App';

void main() {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  final workspace = Platform.environment['TEST_WORKSPACE'];
  if (srcDir == null || workspace == null) {
    abort('FAIL: missing TEST_SRCDIR or TEST_WORKSPACE env vars');
  }

  final files = allFiles(Directory('$srcDir/$workspace'));
  final ipa = takeSingle(
    files,
    _isUnsignedIpa,
    'one unsigned device $_ipaName in the runfiles',
  );
  final tmp = Directory.systemTemp.createTempSync('ios_device_app_');
  try {
    _extract(ipa, tmp);
    final payload = Directory('${tmp.path}/Payload');
    final app = Directory('${payload.path}/$_bundleName');
    if (!app.existsSync()) {
      abort(
        'FAIL: expected the device bundle at ${app.path}; '
        'found ${childNames(payload)}',
      );
    }

    final report = BundleReport();
    _checkMachO(
      report,
      'Runner.app/$_runnerName',
      File('${app.path}/$_runnerName'),
    );
    _checkMachO(
      report,
      'Runner.app/$_appFrameworkBinary',
      File('${app.path}/$_appFrameworkBinary'),
    );
    _checkNoProfile(report, app);
    _checkNoCodeResources(report, app);
    _checkSupportedPlatforms(report, File('${app.path}/Info.plist'));
    _checkSnapshotIsProduct(report, File('${app.path}/$_appFrameworkBinary'));

    if (!report.passed) exit(1);
    print(
      'PASS: the unsigned device app is arm64 iOS AOT with no profile '
      'and no code signature',
    );
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}

/// Whether [file] is the unsigned device archive.
bool _isUnsignedIpa(File file) => file.path.endsWith('/$_ipaName');

/// Extracts [ipa] into [dir], failing with the tool's output on any error.
void _extract(File ipa, Directory dir) {
  ProcessResult unzipped;
  try {
    unzipped = Process.runSync('unzip', ['-q', ipa.path, '-d', dir.path]);
  } on ProcessException catch (e) {
    abort('FAIL: could not run the `unzip` tool on ${ipa.path}: $e');
  }
  if (unzipped.exitCode != 0) {
    abort('FAIL: could not extract ${ipa.path}: ${unzipped.stderr}');
  }
}

/// Checks [file] is a 64-bit arm64 iOS Mach-O with no code signature.
void _checkMachO(BundleReport report, String role, File file) {
  if (!file.existsSync()) {
    report.check(
      'a $role binary in the device bundle',
      ok: false,
      found: 'no file at ${file.path}',
    );
    return;
  }
  MachO macho;
  try {
    macho = parseMachO(readOrAbort(file));
  } on FormatException catch (e) {
    report.check(
      'a $role binary whose Mach-O header and load commands parse',
      ok: false,
      found: '$e in ${file.path}',
    );
    return;
  }
  report
    ..check(
      'a $role binary that is a 64-bit Mach-O for arm64',
      ok: macho.cpuType == machOArm64CpuType,
      found: 'cputype 0x${macho.cpuType.toRadixString(16)} in ${file.path}',
    )
    ..check(
      'a $role binary targeting iOS (platform $machOPlatformIos), '
      'not the simulator',
      ok: macho.platform == machOPlatformIos,
      found: macho.platform == null
          ? 'no LC_BUILD_VERSION in ${file.path}'
          : 'platform ${macho.platform} in ${file.path}',
    )
    ..check(
      'a $role binary with no LC_CODE_SIGNATURE load command',
      ok: !macho.hasCodeSignature,
      found: macho.hasCodeSignature
          ? 'an LC_CODE_SIGNATURE load command in ${file.path}'
          : 'nothing',
    );
}

/// Checks no `embedded.mobileprovision` sits anywhere inside [app].
void _checkNoProfile(BundleReport report, Directory app) {
  final hits = [
    for (final entity in app.listSync(recursive: true))
      if (entity is File &&
          entity.uri.pathSegments.last == 'embedded.mobileprovision')
        entity.path,
  ]..sort();
  report.check(
    'no embedded.mobileprovision anywhere in $_bundleName',
    ok: hits.isEmpty,
    found: hits.isEmpty ? 'nothing' : hits.join(', '),
  );
}

/// Checks there is no `_CodeSignature/CodeResources` inside [app].
void _checkNoCodeResources(BundleReport report, Directory app) {
  final resources = File('${app.path}/_CodeSignature/CodeResources');
  report.check(
    'no _CodeSignature/CodeResources in $_bundleName',
    ok: !resources.existsSync(),
    found: resources.existsSync() ? 'a file at ${resources.path}' : 'nothing',
  );
}

/// Checks `Info.plist` names exactly `["iPhoneOS"]` as its supported platform.
void _checkSupportedPlatforms(BundleReport report, File plist) {
  if (!plist.existsSync()) {
    report.check(
      'an Info.plist in the device bundle',
      ok: false,
      found: 'no file at ${plist.path}',
    );
    return;
  }
  final converted = Process.runSync(
    'plutil',
    ['-convert', 'json', '-o', '-', plist.path],
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  if (converted.exitCode != 0) {
    report.check(
      'an Info.plist that plutil converts',
      ok: false,
      found: 'exit ${converted.exitCode}: ${converted.stderr}',
    );
    return;
  }
  Object? platforms;
  try {
    final decoded = jsonDecode(converted.stdout as String);
    platforms = decoded is Map ? decoded['CFBundleSupportedPlatforms'] : null;
  } on FormatException catch (e) {
    report.check(
      'an Info.plist that parses as JSON',
      ok: false,
      found: 'a decode failure: $e',
    );
    return;
  }
  final ok =
      platforms is List &&
      platforms.length == 1 &&
      platforms.single == 'iPhoneOS';
  report.check(
    'Info.plist CFBundleSupportedPlatforms exactly ["iPhoneOS"]',
    ok: ok,
    found: 'CFBundleSupportedPlatforms $platforms',
  );
}

/// Checks the App.framework snapshot is a release/AOT product build.
void _checkSnapshotIsProduct(BundleReport report, File binary) {
  if (!binary.existsSync()) {
    report.check(
      'an App.framework/App binary in the device bundle',
      ok: false,
      found: 'no file at ${binary.path}',
    );
    return;
  }
  final features = snapshotFeatures(readOrAbort(binary));
  final words = features.split(' ');
  report.check(
    'App.framework/App snapshot features start with product '
    '(a release/AOT build)',
    ok: words.isNotEmpty && words.first == 'product',
    found: features.isEmpty ? 'no features string in ${binary.path}' : features,
  );
}
