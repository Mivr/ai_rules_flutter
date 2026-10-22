/// Proves package-relative asset keys inside the Android bundle.
///
/// `//apps/sub:sub_test` lives in Bazel package `//apps/sub`: its own
/// `assets/sub.txt` must load at `assets/sub.txt` (relative to the listing
/// package), and the first-party `//libs/brand` dependency's asset at
/// `packages/brand/assets/brand.txt`. On the pre-fix keying (raw
/// `File.short_path`) both lookups throw because the bundle carries
/// `apps/sub/assets/sub.txt` and `libs/brand/assets/brand.txt` instead.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sub/main.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('subpackage and brand assets resolve at package-relative keys', (
    tester,
  ) async {
    await tester.pumpWidget(const SubApp());
    await tester.pumpAndSettle();

    expect(find.text('Sub Brand'), findsOneWidget);

    expect(
      await rootBundle.loadString('assets/sub.txt'),
      equals('sub asset\n'),
    );
    expect(
      await rootBundle.loadString('packages/brand/assets/brand.txt'),
      equals('brand asset\n'),
    );
  });
}
