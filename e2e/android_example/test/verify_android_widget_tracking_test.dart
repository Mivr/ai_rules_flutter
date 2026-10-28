/// Verifies `track_widget_creation` reaches the Android kernel.
///
/// Reads two debug APKs built from the same sources and deps:
/// `:app` (`track_widget_creation = True` on `:app_flutter`) and
/// `:app_untracked` (`false`), each through `debug_build`. Their
/// `assets/flutter_assets/kernel_blob.bin` is the kernel compiled for that
/// application. With tracking on, the pinned Flutter SDK's widget transformer
/// adds its creation-location named parameter to widget constructor calls and
/// sites; with tracking off it does not.
///
/// The marker is the parameter name from the SDK's
/// `pkg/kernel/lib/transformations/track_widget_constructor_locations.dart`,
/// not a string guessed here. The off twin proves the check cannot pass on any
/// kernel: it must be a real, non-empty kernel that does not contain the
/// marker.
library;

// This script's diagnostics are its product: it reports what it found in the
// built artifact to the bazel test log, so `print` is its output channel
// rather than a stray debugging statement.
// ignore_for_file: avoid_print

import 'dart:io';

import 'android_test_support.dart';

/// The creation-location parameter name the pinned SDK's widget transformer
/// writes into a kernel compiled with `--track-widget-creation`.
const _creationLocationMarker = r'$creationLocationd_0dea112b090073317d4';

/// Path of the kernel blob inside an APK's assets.
const _kernelPath = 'assets/flutter_assets/kernel_blob.bin';

void main() {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  if (srcDir == null) _abort('FAIL: missing TEST_SRCDIR env var');
  final files = filesUnder(Directory(srcDir));
  final onApk = oneFile(
    files,
    (file) => file.path.endsWith('/app.apk'),
    'one app.apk',
  );
  final offApk = oneFile(
    files,
    (file) => file.path.endsWith('/app_untracked.apk'),
    'one app_untracked.apk',
  );

  final tmp = Directory.systemTemp.createTempSync('android_tracking_');
  try {
    final onDir = Directory('${tmp.path}/on')..createSync();
    final offDir = Directory('${tmp.path}/off')..createSync();
    unzipInto(onApk, onDir);
    unzipInto(offApk, offDir);
    final onKernel = File('${onDir.path}/$_kernelPath');
    final offKernel = File('${offDir.path}/$_kernelPath');
    final onBytes = readOrAbort(onKernel);
    final offBytes = readOrAbort(offKernel);
    final marker = _creationLocationMarker.codeUnits;

    final report = Report()
      ..check(
        'a non-empty tracking-on kernel at ${onKernel.path}',
        ok: onBytes.isNotEmpty,
        found: '${onBytes.length} bytes',
      )
      ..check(
        'a non-empty tracking-off kernel at ${offKernel.path}',
        ok: offBytes.isNotEmpty,
        found: '${offBytes.length} bytes',
      )
      ..check(
        'the tracking-on kernel to contain the widget-creation marker '
        '$_creationLocationMarker',
        ok: hasBytes(onBytes, marker),
        found: 'no marker in ${onKernel.path}',
      )
      ..check(
        'the tracking-off kernel to omit the widget-creation marker '
        '$_creationLocationMarker',
        ok: !hasBytes(offBytes, marker),
        found: 'the marker in ${offKernel.path}',
      );

    if (!report.passed) exit(1);
    print(
      'PASS: track_widget_creation writes creation locations into the '
      'Android kernel and its False twin does not',
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
