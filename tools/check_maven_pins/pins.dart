/// Maven lock file validation logic for Android e2e workspaces.
///
/// Ensures all Android workspaces pin `@rules_android_maven` with a valid
/// lock file containing 64-hex sha256 checksums for every artifact, and
/// covering all artifacts declared in the workspace's `MODULE.bazel`.
library;

import 'dart:convert';
import 'dart:io';

/// The 6 e2e Android workspaces that declare `rules_android_maven`.
const List<String> defaultAndroidWorkspaces = [
  'e2e/android_example',
  'e2e/android_no_go_sdk',
  'e2e/hello_world',
  'e2e/integration_android',
  'e2e/min_versions',
  'e2e/plugin_example',
];

final RegExp _hex64Pattern = RegExp(r'^[0-9a-fA-F]{64}$');

/// Parsed metadata for a `rules_android_maven` install.
class MavenInstallInfo {
  /// The label or relative path specified in `lock_file`, if any.
  final String? lockFile;

  /// Maven coordinates declared in `artifacts = [...]`.
  final List<String> artifacts;

  /// Creates a descriptor for a parsed `rules_android_maven` install.
  const MavenInstallInfo({
    required this.lockFile,
    required this.artifacts,
  });
}

/// Drops `#` comments from text outside of string literals.
String stripComments(String text) =>
    text.split('\n').map((line) => line.split('#').first).join('\n');

/// Extracts all `maven.install(...)` call blocks using balanced parentheses.
List<String> extractMavenInstallBlocks(String text) {
  final clean = stripComments(text);
  final blocks = <String>[];
  var idx = 0;
  while (true) {
    final pos = clean.indexOf('maven.install(', idx);
    if (pos == -1) break;
    var openCount = 0;
    var endPos = -1;
    final startSearch = pos + 'maven.install'.length;
    for (var i = startSearch; i < clean.length; i++) {
      final ch = clean[i];
      if (ch == '(') {
        openCount++;
      } else if (ch == ')') {
        openCount--;
        if (openCount == 0) {
          endPos = i;
          break;
        }
      }
    }
    if (endPos != -1) {
      blocks.add(clean.substring(pos, endPos + 1));
      idx = endPos + 1;
    } else {
      break;
    }
  }
  return blocks;
}

/// Parses the `rules_android_maven` install block from `MODULE.bazel` content.
MavenInstallInfo? parseRulesAndroidMavenInstall(String moduleContent) {
  final blocks = extractMavenInstallBlocks(moduleContent);
  final nameRegex = RegExp(r'''name\s*=\s*['"]rules_android_maven['"]''');
  for (final block in blocks) {
    if (!nameRegex.hasMatch(block)) continue;
    final lockFileMatch = RegExp(
      r'''lock_file\s*=\s*['"]([^'"]+)['"]''',
    ).firstMatch(block);
    final lockFile = lockFileMatch?.group(1);

    final artifactsMatch = RegExp(
      r'artifacts\s*=\s*\[(.*?)\]',
      dotAll: true,
    ).firstMatch(block);
    final artifacts = <String>[];
    if (artifactsMatch != null) {
      final raw = artifactsMatch.group(1)!;
      for (final m in RegExp(r'''['"]([^'"]+)['"]''').allMatches(raw)) {
        artifacts.add(m.group(1)!);
      }
    }
    return MavenInstallInfo(lockFile: lockFile, artifacts: artifacts);
  }
  return null;
}

/// Resolves a Bazel lock file label (e.g. `//:rules_android_maven_install.json`)
/// to a filesystem path relative to the workspace directory.
String resolveLockFilePath(String workspacePath, String lockFileLabel) {
  final sep = Platform.pathSeparator;
  if (lockFileLabel.startsWith('//:')) {
    return '$workspacePath$sep${lockFileLabel.substring(3)}';
  }
  if (lockFileLabel.startsWith('//')) {
    final rel = lockFileLabel.substring(2).replaceAll(':', sep);
    return '$workspacePath$sep$rel';
  }
  return '$workspacePath$sep$lockFileLabel';
}

/// Checks that a lock entry's shasums map contains only 64-hex sha256 hashes.
bool _hasValidSha256(dynamic shasums) {
  if (shasums is! Map<String, dynamic> || shasums.isEmpty) return false;
  for (final sha in shasums.values) {
    if (sha is! String || !_hex64Pattern.hasMatch(sha)) return false;
  }
  return true;
}

/// Validates each artifact entry under the lock file's `artifacts` map.
List<String> _validateArtifactEntries(
  Map<String, dynamic> artifacts,
  String workspacePath,
  String lockFilePath,
  Set<String> outGroupArtifacts,
) {
  final errors = <String>[];
  for (final entry in artifacts.entries) {
    final artifactKey = entry.key;
    final parts = artifactKey.split(':');
    if (parts.length >= 2) {
      outGroupArtifacts.add('${parts[0]}:${parts[1]}');
    }

    final val = entry.value;
    final shasums = (val is Map<String, dynamic>) ? val['shasums'] : null;
    if (!_hasValidSha256(shasums)) {
      errors.add(
        "workspace '$workspacePath', file '$lockFilePath': "
        "artifact '$artifactKey' has no 64-hex sha256 under shasums",
      );
    }
  }
  return errors;
}

/// Verifies that all declared artifacts are present in the lock.
List<String> _validateDeclaredArtifacts(
  List<String> declaredArtifacts,
  Set<String> lockGroupArtifacts,
  String workspacePath,
  String lockFilePath,
) {
  final errors = <String>[];
  for (final declared in declaredArtifacts) {
    final parts = declared.split(':');
    if (parts.length < 2) continue;
    final ga = '${parts[0]}:${parts[1]}';
    if (!lockGroupArtifacts.contains(ga)) {
      errors.add(
        "workspace '$workspacePath', file '$lockFilePath': "
        "declared artifact '$declared' ($ga) is absent from lock",
      );
    }
  }
  return errors;
}

/// Validates the JSON content and entries of a maven lock file.
List<String> validateLockContent({
  required String workspacePath,
  required String lockFilePath,
  required String lockJsonContent,
  required List<String> declaredArtifacts,
}) {
  final errors = <String>[];
  dynamic decoded;
  try {
    decoded = jsonDecode(lockJsonContent);
  } on FormatException {
    errors.add(
      "workspace '$workspacePath', file '$lockFilePath': "
      'lock file is not valid JSON',
    );
    return errors;
  }

  if (decoded is! Map<String, dynamic>) {
    errors.add(
      "workspace '$workspacePath', file '$lockFilePath': "
      'lock file root is not a JSON object',
    );
    return errors;
  }

  final version = decoded['version']?.toString();
  if (version != '2' && version != '3') {
    errors.add(
      "workspace '$workspacePath', file '$lockFilePath': "
      "expected lock version 2 or 3, got '$version'",
    );
  }

  final artifactsRaw = decoded['artifacts'];
  if (artifactsRaw is! Map<String, dynamic>) {
    errors.add(
      "workspace '$workspacePath', file '$lockFilePath': "
      'lock file has no valid artifacts map',
    );
    return errors;
  }

  final lockGroupArtifacts = <String>{};
  errors.addAll(
    _validateArtifactEntries(
      artifactsRaw,
      workspacePath,
      lockFilePath,
      lockGroupArtifacts,
    ),
  );
  errors.addAll(
    _validateDeclaredArtifacts(
      declaredArtifacts,
      lockGroupArtifacts,
      workspacePath,
      lockFilePath,
    ),
  );

  return errors;
}

/// Checks the `rules_android_maven` pin in a single workspace.
List<String> checkWorkspacePins(String workspacePath) {
  final sep = Platform.pathSeparator;
  final moduleFile = File('$workspacePath${sep}MODULE.bazel');
  if (!moduleFile.existsSync()) {
    return [
      "workspace '$workspacePath', file '${moduleFile.path}': "
          'MODULE.bazel does not exist',
    ];
  }

  final moduleContent = moduleFile.readAsStringSync();
  final install = parseRulesAndroidMavenInstall(moduleContent);
  if (install == null) {
    return [
      "workspace '$workspacePath', file '${moduleFile.path}': "
          "an install of 'rules_android_maven' was not found",
    ];
  }

  if (install.lockFile == null || install.lockFile!.isEmpty) {
    return [
      "workspace '$workspacePath', file '${moduleFile.path}': "
          "an install of 'rules_android_maven' has no lock_file",
    ];
  }

  final lockFilePath = resolveLockFilePath(workspacePath, install.lockFile!);
  final lockFile = File(lockFilePath);
  if (!lockFile.existsSync()) {
    return [
      "workspace '$workspacePath', file '$lockFilePath': lock file is missing",
    ];
  }

  final lockContent = lockFile.readAsStringSync();
  return validateLockContent(
    workspacePath: workspacePath,
    lockFilePath: lockFilePath,
    lockJsonContent: lockContent,
    declaredArtifacts: install.artifacts,
  );
}

/// Checks all requested workspaces, defaulting to [defaultAndroidWorkspaces].
List<String> checkAllWorkspaces({
  required String rootPath,
  List<String>? workspaces,
}) {
  final sep = Platform.pathSeparator;
  final pathsToCheck = workspaces ?? defaultAndroidWorkspaces;
  final errors = <String>[];

  for (final relPath in pathsToCheck) {
    final fullPath = '$rootPath$sep$relPath';
    final wsErrors = checkWorkspacePins(fullPath);
    errors.addAll(wsErrors);
  }

  return errors;
}
