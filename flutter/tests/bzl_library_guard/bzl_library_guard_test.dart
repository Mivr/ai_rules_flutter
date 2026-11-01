/// Tripwire: every root-module non-test .bzl file must belong to a public
/// bzl_library target whose deps cover all load statements.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Representation of a parsed `bzl_library` rule in a `BUILD.bazel` file.
class BzlTarget {
  /// Constructs a [BzlTarget].
  const BzlTarget({
    required this.name,
    required this.package,
    required this.srcs,
    required this.visibility,
    required this.deps,
  });

  /// The target name within its package.
  final String name;

  /// Package path relative to repo root (e.g. `flutter/private`).
  final String package;

  /// Source file names declared in `srcs`.
  final List<String> srcs;

  /// Visibility list entries.
  final List<String> visibility;

  /// Dependency target labels declared in `deps`.
  final List<String> deps;

  /// Full target label.
  String get label => '//$package:$name';
}

/// Locates the rules_flutter repository root using environment anchors.
String _findWorkspaceRoot() {
  final bwd = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (bwd != null && bwd.isNotEmpty && Directory('$bwd/flutter').existsSync()) {
    return bwd;
  }
  final anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final srcdir = Platform.environment['TEST_SRCDIR'];
  if (anchor == null || anchor.isEmpty || srcdir == null) {
    throw StateError('GUARD_ROOT_ANCHOR or TEST_SRCDIR is unset');
  }
  var dir = Directory(
    File('$srcdir/$anchor').resolveSymbolicLinksSync(),
  ).parent;
  for (var i = 0; i < 10; i++) {
    if (Directory('${dir.path}/flutter').existsSync() &&
        File('${dir.path}/MODULE.bazel').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  throw StateError('workspace root not found above $anchor');
}

/// Whether directory with relative path [rel] should be ignored.
bool _isIgnoredDirectory(String rel) =>
    rel.startsWith('.') ||
    rel.startsWith('e2e') ||
    rel.startsWith('flutter/tests');

/// Discovers all non-test `.bzl` file paths relative to [root].
List<String> _findNonTestBzlFiles(String root) {
  final result = <String>[];
  void scan(Directory dir) {
    for (final entity in dir.listSync(followLinks: false)) {
      if (entity is Directory) {
        final rel = entity.path.substring(root.length + 1);
        if (!_isIgnoredDirectory(rel)) scan(entity);
      } else if (entity is File && entity.path.endsWith('.bzl')) {
        final rel = entity.path.substring(root.length + 1);
        if (!rel.endsWith('_test.bzl')) result.add(rel);
      }
    }
  }

  scan(Directory(root));
  result.sort();
  return result;
}

/// Extracts list of string literals from a bracketed attribute argument.
List<String> _extractStringList(String block, String attribute) {
  final pattern = RegExp('$attribute\\s*=\\s*\\[(.*?)\\]', dotAll: true);
  final match = pattern.firstMatch(block);
  if (match == null) return const [];
  final body = match.group(1)!;
  final itemPattern = RegExp('["\']([^"\']+)["\']');
  return itemPattern.allMatches(body).map((m) => m.group(1)!).toList();
}

/// Parses all `bzl_library` targets declared in [buildFile] for [package].
List<BzlTarget> _parseBzlLibraries(File buildFile, String package) {
  if (!buildFile.existsSync()) return const [];
  final content = buildFile.readAsStringSync();
  final targetPattern = RegExp(r'bzl_library\s*\((.*?)\n\)', dotAll: true);
  final result = <BzlTarget>[];
  for (final match in targetPattern.allMatches(content)) {
    final block = match.group(1)!;
    final nameMatch = RegExp('name\\s*=\\s*["\']([^"\']+)["\']')
        .firstMatch(block);
    if (nameMatch == null) continue;
    final name = nameMatch.group(1)!;
    result.add(
      BzlTarget(
        name: name,
        package: package,
        srcs: _extractStringList(block, 'srcs'),
        visibility: _extractStringList(block, 'visibility'),
        deps: _extractStringList(block, 'deps'),
      ),
    );
  }
  return result;
}

/// Loads all parsed `bzl_library` targets grouped by package.
Map<String, List<BzlTarget>> _loadPackageTargets(
  String root,
  List<String> bzlFiles,
) {
  final result = <String, List<BzlTarget>>{};
  final packages = bzlFiles
      .map((f) => f.contains('/') ? f.substring(0, f.lastIndexOf('/')) : '')
      .toSet();
  for (final pkg in packages) {
    final buildPath = pkg.isEmpty
        ? '$root/BUILD.bazel'
        : '$root/$pkg/BUILD.bazel';
    result[pkg] = _parseBzlLibraries(File(buildPath), pkg);
  }
  return result;
}

/// Maps each `.bzl` file relative path to its owning `bzl_library` target label.
Map<String, String> _buildFileToTargetMap(
  Map<String, List<BzlTarget>> packageTargets,
) {
  final fileToTarget = <String, String>{};
  for (final entry in packageTargets.entries) {
    final pkg = entry.key;
    for (final target in entry.value) {
      for (final src in target.srcs) {
        final relPath = pkg.isEmpty ? src : '$pkg/$src';
        fileToTarget[relPath] = target.label;
      }
    }
  }
  return fileToTarget;
}

/// Normalizes a dep target label [dep] from [currentPackage] to canonical label.
String _normalizeDep(String dep, String currentPackage) {
  var d = dep;
  if (d.startsWith('@rules_flutter//')) {
    d = d.substring('@rules_flutter'.length);
  }
  if (d.startsWith(':')) {
    return '//$currentPackage$d';
  }
  return d;
}

/// Resolves a [rawLoad] inside [relFilePath] to the expected `bzl_library` label.
String? _resolveLoadTarget(
  String rawLoad,
  String relFilePath,
  Map<String, String> fileToTarget,
) {
  var loadStr = rawLoad;
  if (loadStr.startsWith('@rules_flutter//')) {
    loadStr = loadStr.substring('@rules_flutter'.length);
  }
  if (loadStr.startsWith(':')) {
    final curPkg = relFilePath.contains('/')
        ? relFilePath.substring(0, relFilePath.lastIndexOf('/'))
        : '';
    final targetFile = '$curPkg/${loadStr.substring(1)}';
    return fileToTarget[targetFile];
  }
  if (loadStr.startsWith('//')) {
    final colon = loadStr.indexOf(':');
    final pkg = loadStr.substring(2, colon);
    final file = loadStr.substring(colon + 1);
    final targetFile = pkg.isEmpty ? file : '$pkg/$file';
    return fileToTarget[targetFile];
  }
  if (loadStr.startsWith('@bazel_skylib//')) {
    return loadStr.endsWith('.bzl')
        ? loadStr.substring(0, loadStr.length - 4)
        : loadStr;
  }
  if (loadStr.startsWith('@rules_dart//')) {
    if (loadStr == '@rules_dart//dart/pub:pub_scan.bzl' ||
        loadStr == '@rules_dart//dart/private:dart_test_runner.bzl') {
      return null;
    }
    return loadStr.endsWith('.bzl')
        ? loadStr.substring(0, loadStr.length - 4)
        : loadStr;
  }
  return null;
}

/// Checks missing load obligations for a single [file].
void _checkFileLoadObligations(
  String root,
  String file,
  BzlTarget target,
  Map<String, String> fileToTarget,
  List<String> missingObligations,
) {
  final pkg = target.package;
  final declaredDeps = target.deps.map((d) => _normalizeDep(d, pkg)).toSet();
  final fileContent = File('$root/$file').readAsStringSync();
  final cleanContent = fileContent
      .replaceAll(RegExp(r'""".*?"""', dotAll: true), '')
      .replaceAll(RegExp(r"'''.*?'''", dotAll: true), '');
  final loadMatches = RegExp(
    r'^load\s*\(\s*["\x27]([^"\x27]+)["\x27]',
    multiLine: true,
  ).allMatches(cleanContent);

  for (final lm in loadMatches) {
    final rawLoad = lm.group(1)!;
    final expectedDep = _resolveLoadTarget(rawLoad, file, fileToTarget);
    if (expectedDep != null && !declaredDeps.contains(expectedDep)) {
      missingObligations.add(
        '$file (${target.label}) missing dep on $expectedDep (loaded via $rawLoad)',
      );
    }
  }
}

/// Verifies that every non-test .bzl file has a matching bzl_library target.
void _verifyTargetCoverage(
  List<String> bzlFiles,
  Map<String, String> fileToTarget,
) {
  final uncovered = <String>[];
  for (final file in bzlFiles) {
    if (!fileToTarget.containsKey(file)) {
      uncovered.add(file);
    }
  }
  expect(
    uncovered,
    isEmpty,
    reason: 'The following .bzl files have no bzl_library target: $uncovered',
  );
}

/// Verifies that every non-test bzl_library target is visible to //docs.
void _verifyDocsVisibility(Map<String, List<BzlTarget>> packageTargets) {
  final nonPublic = <String>[];
  for (final targets in packageTargets.values) {
    for (final t in targets) {
      final isPublic =
          t.visibility.contains('//visibility:public') ||
          t.visibility.contains('//docs:__pkg__') ||
          t.visibility.contains('//docs:...');
      if (!isPublic) {
        nonPublic.add('${t.label} (visibility: ${t.visibility})');
      }
    }
  }
  expect(
    nonPublic,
    isEmpty,
    reason: 'bzl_library targets not visible to //docs: $nonPublic',
  );
}

/// Verifies that all bzl_library targets include required load obligations.
void _verifyLoadObligations(
  String root,
  List<String> bzlFiles,
  Map<String, String> fileToTarget,
  Map<String, List<BzlTarget>> packageTargets,
) {
  final missingObligations = <String>[];
  for (final file in bzlFiles) {
    final targetLabel = fileToTarget[file];
    if (targetLabel == null) continue;
    final pkg = file.contains('/')
        ? file.substring(0, file.lastIndexOf('/'))
        : '';
    final targets = packageTargets[pkg] ?? const [];
    final target = targets.firstWhere((t) => t.label == targetLabel);
    _checkFileLoadObligations(
      root,
      file,
      target,
      fileToTarget,
      missingObligations,
    );
  }
  expect(
    missingObligations,
    isEmpty,
    reason: 'Missing load obligations in deps: $missingObligations',
  );
}

/// Verifies that docs/BUILD.bazel exists and declares exactly 15 starlark_doc_extract targets.
void _verifyDocsDocExtracts(String root) {
  final docsBuild = File('$root/docs/BUILD.bazel');
  expect(
    docsBuild.existsSync(),
    isTrue,
    reason: 'docs/BUILD.bazel does not exist',
  );
  final content = docsBuild.readAsStringSync();
  final matches = RegExp(r'starlark_doc_extract\s*\(').allMatches(content);
  expect(
    matches.length,
    equals(15),
    reason: 'Expected 15 starlark_doc_extract targets in docs/BUILD.bazel',
  );
}

/// Main test entrypoint for bzl_library graph invariants.
void main() {
  late final String root;
  late final List<String> bzlFiles;
  late final Map<String, List<BzlTarget>> packageTargets;
  late final Map<String, String> fileToTarget;

  setUpAll(() {
    root = _findWorkspaceRoot();
    bzlFiles = _findNonTestBzlFiles(root);
    packageTargets = _loadPackageTargets(root, bzlFiles);
    fileToTarget = _buildFileToTargetMap(packageTargets);
  });

  test(
    'all root-module non-test bzl files belong to exactly one bzl_library',
    () {
      _verifyTargetCoverage(bzlFiles, fileToTarget);
    },
  );

  test('all non-test bzl_library targets are visible to //docs', () {
    _verifyDocsVisibility(packageTargets);
  });

  test('all bzl_library targets include required load obligations in deps', () {
    _verifyLoadObligations(root, bzlFiles, fileToTarget, packageTargets);
  });

  test('docs BUILD.bazel declares exactly 15 starlark_doc_extract targets', () {
    _verifyDocsDocExtracts(root);
  });
}
