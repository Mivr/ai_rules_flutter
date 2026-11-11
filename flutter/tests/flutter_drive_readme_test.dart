/// Text check: the README documents `flutter_drive_test` (clause D).
///
/// The README must show a `load` of `flutter_drive_test` from
/// `@rules_flutter//flutter:android.bzl`, name its attributes and the
/// environment the driver receives, state the Android-only scope and say the
/// iOS simulator is a later item.
library;

import 'dart:io';

import 'package:test/test.dart';

String _readme() {
  final String srcdir = Platform.environment['TEST_SRCDIR']!;
  final String key = Platform.environment['README_PATH']!;
  return File('$srcdir/$key').readAsStringSync();
}

void main() {
  late String readme;
  setUpAll(() => readme = _readme());

  test('has a flutter_drive_test section', () {
    expect(readme, contains('### flutter_drive_test'));
  });

  test('loads flutter_drive_test from flutter/android.bzl', () {
    final load = RegExp(
      r'load\("@rules_flutter//flutter:android\.bzl"[^)]*"flutter_drive_test"',
    );
    expect(load.hasMatch(readme), isTrue);
  });

  test('documents the attributes and the driver environment', () {
    for (final word in [
      '`app`',
      '`driver`',
      '`package_name`',
      'VM_SERVICE_URL',
    ]) {
      expect(readme, contains(word));
    }
  });

  test('states the Android-only scope and that iOS is later', () {
    expect(readme, contains('Android only'));
    expect(readme, contains('iOS simulator support is a later item'));
  });
}
