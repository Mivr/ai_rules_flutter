/// Verifies `track_widget_creation` reaches the iOS simulator kernel.
///
/// Reads two simulator `.ipa` bundles built from the same sources and deps:
/// `:app` (`track_widget_creation = True` on `:app_flutter`) and
/// `:app_untracked` (`false`). Each bundle's
/// `App.framework/flutter_assets/kernel_blob.bin` is the kernel compiled for
/// that application. With tracking on, the pinned Flutter SDK's widget
/// transformer adds its creation-location named parameter to widget
/// constructor calls and sites; with tracking off it does not.
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
import 'dart:typed_data';

import 'ios_test_support.dart';

/// The creation-location parameter name the pinned SDK's widget transformer
/// writes into a kernel compiled with `--track-widget-creation`.
const _creationLocationMarker = r'$creationLocationd_0dea112b090073317d4';

/// Basename of the tracking-on simulator bundle in the test's `data`.
const _onIpaName = 'app.ipa';

/// Basename of the tracking-off simulator bundle in the test's `data`.
const _offIpaName = 'app_untracked.ipa';

/// Path suffix of the kernel blob inside an assembled App.framework.
const _kernelSuffix = 'App.framework/flutter_assets/kernel_blob.bin';

void main() {
  final srcDir = Platform.environment['TEST_SRCDIR'];
  if (srcDir == null) _abort('FAIL: missing TEST_SRCDIR env var');
  final files = filesUnder(Directory(srcDir));
  final onIpa = oneFile(
    files,
    (file) => file.path.endsWith('/$_onIpaName'),
    'one $_onIpaName',
  );
  final offIpa = oneFile(
    files,
    (file) => file.path.endsWith('/$_offIpaName'),
    'one $_offIpaName',
  );

  final onKernel = _readKernel(onIpa, 'tracking-on');
  final offKernel = _readKernel(offIpa, 'tracking-off');
  final marker = _creationLocationMarker.codeUnits;
  final onHasMarker = hasBytes(onKernel.bytes, marker);
  final offHasMarker = hasBytes(offKernel.bytes, marker);

  final report = Report()
    ..check(
      'a non-empty tracking-on kernel at ${onKernel.path}',
      ok: onKernel.bytes.isNotEmpty,
      found: '${onKernel.bytes.length} bytes',
    )
    ..check(
      'a non-empty tracking-off kernel at ${offKernel.path}',
      ok: offKernel.bytes.isNotEmpty,
      found: '${offKernel.bytes.length} bytes',
    )
    ..check(
      'the tracking-on kernel to contain the widget-creation marker '
      '$_creationLocationMarker',
      ok: onHasMarker,
      found: 'no marker in ${onKernel.path}',
    )
    ..check(
      'the tracking-off kernel to omit the widget-creation marker '
      '$_creationLocationMarker',
      ok: !offHasMarker,
      found: 'the marker in ${offKernel.path}',
    );

  if (!report.passed) exit(1);
  print(
    'PASS: track_widget_creation writes creation locations into the iOS '
    'kernel and its False twin does not',
  );
}

/// Stops the test with [message]: a missing input fails, never skips.
Never _abort(String message) {
  stderr.writeln(message);
  exit(1);
}

/// One extracted kernel blob: its path and bytes.
class _Kernel {
  const _Kernel(this.path, this.bytes);

  /// Where the blob was found, for a failure message.
  final String path;

  /// The kernel blob's bytes.
  final Uint8List bytes;
}

/// Extracts [ipa], finds its App.framework kernel blob, and reads it.
_Kernel _readKernel(File ipa, String role) {
  final tmp = Directory.systemTemp.createTempSync('ios_tracking_${role}_');
  try {
    ProcessResult unzipped;
    try {
      unzipped = Process.runSync('unzip', ['-q', ipa.path, '-d', tmp.path]);
    } on ProcessException catch (e) {
      _abort('FAIL: could not run `unzip` on ${ipa.path}: $e');
    }
    if (unzipped.exitCode != 0) {
      _abort('FAIL: could not extract ${ipa.path}: ${unzipped.stderr}');
    }
    final kernel = oneFile(
      filesUnder(tmp),
      (file) => file.path.endsWith(_kernelSuffix),
      'one $_kernelSuffix',
    );
    try {
      return _Kernel(kernel.path, kernel.readAsBytesSync());
    } on FileSystemException catch (e) {
      _abort('FAIL: could not read ${kernel.path}: $e');
    }
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
}
