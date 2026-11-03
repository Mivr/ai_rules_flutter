/// Proves package-relative asset keys and resolution variants inside the
/// Android bundle.
///
/// `//apps/sub:sub_test` lives in Bazel package `//apps/sub`: its own
/// `assets/sub.txt` must load at `assets/sub.txt` (relative to the listing
/// package), and the first-party `//libs/brand` dependency's asset at
/// `packages/brand/assets/brand.txt`. On the pre-fix keying (raw
/// `File.short_path`) both lookups throw because the bundle carries
/// `apps/sub/assets/sub.txt` and `libs/brand/assets/brand.txt` instead.
///
/// The same package-relative rule covers the target's own `shaders`:
/// `shaders/sub.frag` must load as `shaders/sub.frag`, which is where
/// `FragmentProgram.fromAsset` looks for it.
///
/// The app's `assets/2.0x/logo.png` and `assets/2.5x/logo.png` are
/// resolution variants of `assets/logo.png`, and the brand package's
/// `packages/brand/assets/2.0x/brand.png` is a variant of
/// `packages/brand/assets/brand.png`. `AssetImage` must pick the one its
/// device pixel ratio asks for, and the loaded bytes carry that fixture's
/// marker.
library;

import 'dart:ui';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sub/main.dart';

/// Loads an asset's text with checkout line endings normalized away.
///
/// Git on Windows checks text fixtures out with CRLF and the bundle carries
/// bytes verbatim, so comparing raw bytes against an LF literal fails there.
/// Normalizing here keeps the assertion exact on every runner.
Future<String> _assetText(String key) async =>
    (await rootBundle.loadString(key)).replaceAll('\r\n', '\n');

/// Asserts the asset at [key] is the fixture whose marker is [marker].
Future<void> _expectMarker(String key, String marker) async {
  final data = await rootBundle.load(key);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  expect(String.fromCharCodes(bytes), contains(marker));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('subpackage and brand assets resolve at package-relative keys', (
    tester,
  ) async {
    await tester.pumpWidget(const SubApp());
    await tester.pumpAndSettle();

    expect(find.text('Sub Brand'), findsOneWidget);

    expect(await _assetText('assets/sub.txt'), equals('sub asset\n'));
    expect(
      await _assetText('packages/brand/assets/brand.txt'),
      equals('brand asset\n'),
    );
  });

  testWidgets('resolution variants resolve by device pixel ratio', (
    tester,
  ) async {
    await tester.pumpWidget(const SubApp());
    await tester.pumpAndSettle();

    final logoMain = await const AssetImage('assets/logo.png')
        .obtainKey(ImageConfiguration.empty);
    expect(logoMain.name, 'assets/logo.png');
    expect(logoMain.scale, 1);
    await _expectMarker(logoMain.name, 'FF-ASSET-VARIANTS logo 1x');

    final logo20 = await const AssetImage('assets/logo.png')
        .obtainKey(const ImageConfiguration(devicePixelRatio: 2));
    expect(logo20.name, 'assets/2.0x/logo.png');
    expect(logo20.scale, 2);
    await _expectMarker(logo20.name, 'FF-ASSET-VARIANTS logo 2.0x');

    final logo25 = await const AssetImage('assets/logo.png')
        .obtainKey(const ImageConfiguration(devicePixelRatio: 2.5));
    expect(logo25.name, 'assets/2.5x/logo.png');
    expect(logo25.scale, 2.5);
    await _expectMarker(logo25.name, 'FF-ASSET-VARIANTS logo 2.5x');

    final brandMain = await const AssetImage(
      'assets/brand.png',
      package: 'brand',
    ).obtainKey(ImageConfiguration.empty);
    expect(brandMain.name, 'packages/brand/assets/brand.png');
    await _expectMarker(brandMain.name, 'FF-ASSET-VARIANTS brand 1x');

    final brand20 = await const AssetImage(
      'assets/brand.png',
      package: 'brand',
    ).obtainKey(const ImageConfiguration(devicePixelRatio: 2));
    expect(brand20.name, 'packages/brand/assets/2.0x/brand.png');
    expect(brand20.scale, 2);
    await _expectMarker(brand20.name, 'FF-ASSET-VARIANTS brand 2.0x');
  });

  testWidgets('subpackage shader loads at its package-relative key', (
    tester,
  ) async {
    await tester.pumpWidget(const SubApp());
    await tester.pumpAndSettle();

    final program = await FragmentProgram.fromAsset('shaders/sub.frag');
    expect(program.fragmentShader(), isNotNull);
  });
}
