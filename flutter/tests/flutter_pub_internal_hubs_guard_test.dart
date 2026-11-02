/// Lockfile guard: internal `flutter.pub` hubs stay reproducible and never
/// pollute consumer `MODULE.bazel.lock` facts.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

String _anchorFilePath() {
  final Map<String, String> env = Platform.environment;
  final String? anchor = env['GUARD_ROOT_ANCHOR'];
  final String? srcDir = env['TEST_SRCDIR'];
  if (anchor != null &&
      srcDir != null &&
      File('$srcDir/$anchor').existsSync()) {
    return '$srcDir/$anchor';
  }
  final String? manifest = env['RUNFILES_MANIFEST_FILE'];
  if (anchor != null && manifest != null && File(manifest).existsSync()) {
    for (final String entry in File(manifest).readAsLinesSync()) {
      if (entry.startsWith('$anchor ')) {
        return entry.substring(anchor.length + 1);
      }
    }
  }
  return 'flutter/tests/flutter_pub_internal_hubs_guard_test.dart';
}

String _locateRepoRoot() {
  final String? workspaceEnv =
      Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (workspaceEnv != null && File('$workspaceEnv/MODULE.bazel').existsSync()) {
    return workspaceEnv;
  }
  final String resolved = File(_anchorFilePath()).resolveSymbolicLinksSync();
  final String candidate = File(resolved).parent.parent.parent.path;
  if (!File('$candidate/MODULE.bazel').existsSync()) {
    throw StateError('Cannot locate rules_flutter root at $candidate');
  }
  return candidate;
}

Map<String, Object?> _readJsonObject(String path) {
  final Object? decoded = jsonDecode(File(path).readAsStringSync());
  if (decoded is Map<String, Object?>) {
    return decoded;
  }
  throw FormatException('Expected top-level JSON object in $path');
}

Map<String, Object?> _jsonSection(
  Map<String, Object?> parent,
  String key,
) => switch (parent[key]) {
  final Map<String, Object?> map => map,
  _ => const <String, Object?>{},
};

void _expectNoFlutterExtension(Map<String, Object?> lockJson, String label) {
  for (final section in const <String>['moduleExtensions', 'facts']) {
    final Map<String, Object?> entries = _jsonSection(lockJson, section);
    for (final String key in entries.keys) {
      expect(
        key.contains('flutter:extensions.bzl%flutter'),
        isFalse,
        reason: '$label contains unexpected $section key $key',
      );
    }
  }
}

Set<String> _hostedPackagesInPubspecLock(String path) {
  final hosted = <String>{};
  String? currentPkg;
  for (final String line in File(path).readAsLinesSync()) {
    final RegExpMatch? pkgMatch = RegExp(
      r'^  ([a-z0-9_]+):\s*$',
    ).firstMatch(line);
    if (pkgMatch != null) {
      currentPkg = pkgMatch.group(1);
      continue;
    }
    if (currentPkg != null && line.trim() == 'source: hosted') {
      hosted.add(currentPkg);
    }
  }
  return hosted;
}

Set<String> _factHostedPackages(Map<String, Object?> extFacts) {
  final packages = <String>{};
  for (final String key in extFacts.keys) {
    final List<String> parts = key.split('/');
    if (parts.length >= 3 && parts[1] == 'hosted') {
      packages.add(parts[2]);
    }
  }
  return packages;
}

/// Entrypoint for the internal-hubs lockfile guard tests.
void main() {
  final String root = _locateRepoRoot();

  test('root MODULE.bazel.lock contains no flutter extension entry', () {
    _expectNoFlutterExtension(
      _readJsonObject('$root/MODULE.bazel.lock'),
      'MODULE.bazel.lock',
    );
  });

  test('e2e/smoke has no flutter.pub hub and no flutter lockfile entry', () {
    final String smokeModule = File(
      '$root/e2e/smoke/MODULE.bazel',
    ).readAsStringSync();
    expect(
      smokeModule.contains('flutter.pub('),
      isFalse,
      reason: 'e2e/smoke/MODULE.bazel must not declare any flutter.pub hubs',
    );
    _expectNoFlutterExtension(
      _readJsonObject('$root/e2e/smoke/MODULE.bazel.lock'),
      'e2e/smoke/MODULE.bazel.lock',
    );
  });

  test('e2e/pub_scc/MODULE.bazel.lock facts cover only consumer packages', () {
    final Map<String, Object?> pubSccLock = _readJsonObject(
      '$root/e2e/pub_scc/MODULE.bazel.lock',
    );
    final Map<String, Object?> facts = _jsonSection(pubSccLock, 'facts');
    const flutterFactKey =
        '@@ai_rules_flutter+//flutter:extensions.bzl%flutter';

    expect(
      facts.containsKey(flutterFactKey),
      isTrue,
      reason: 'e2e/pub_scc/MODULE.bazel.lock must record flutter facts',
    );

    final Map<String, Object?> extFacts = _jsonSection(facts, flutterFactKey);
    final Set<String> covered = _factHostedPackages(extFacts);
    final Set<String> lockHosted = _hostedPackagesInPubspecLock(
      '$root/e2e/pub_scc/pubspec.lock',
    );
    const expectedPackages = <String>{
      'characters',
      'collection',
      'material_color_utilities',
      'meta',
      'vector_math',
    };
    expect(lockHosted, equals(expectedPackages));
    expect(extFacts.length, equals(expectedPackages.length));
    expect(covered, equals(expectedPackages));

    const internalOnlyPackages = <String>{
      'args',
      'dwds',
      'intl',
      'vm_service',
      'watcher',
    };
    for (final pkg in internalOnlyPackages) {
      expect(covered.contains(pkg), isFalse);
    }
  });
}
