/// Maven lock file validation logic for Android e2e workspaces.
///
/// Ensures all Android workspaces pin `@rules_android_maven` with a valid
/// lock file containing 64-hex sha256 checksums for every artifact, and
/// covering all artifacts declared in the workspace's `MODULE.bazel`.
library;

import 'dart:convert';
import 'dart:io';

/// The six e2e Android workspaces that declare `rules_android_maven`.
const List<String> defaultAndroidWorkspaces = [
  'e2e/android_example',
  'e2e/android_no_go_sdk',
  'e2e/hello_world',
  'e2e/integration_android',
  'e2e/min_versions',
  'e2e/plugin_example',
];

final RegExp _hex64Pattern = RegExp(r'^[0-9a-fA-F]{64}$');
final RegExp _mavenExtPattern = RegExp(
  r'''(\w+)\s*=\s*use_extension\([^)]*(['"])maven\2''',
);
final RegExp _installNamePattern = RegExp(
  r'''\bname\s*=\s*(['"])rules_android_maven\1''',
);
final RegExp _lockFilePattern = RegExp(
  r'''\block_file\s*=\s*(['"])([^'"]*)\1''',
);
final RegExp _groupAttrPattern = RegExp(
  r'''\bgroup\s*=\s*(['"])([^'"]+)\1''',
);
final RegExp _artifactAttrPattern = RegExp(
  r'''\bartifact\s*=\s*(['"])([^'"]+)\1''',
);
final RegExp _quotedStringPattern = RegExp(r'''(['"])([^'"]+)\1''');

/// Parsed metadata for `rules_android_maven` declarations in `MODULE.bazel`.
typedef MavenInstallInfo = ({
  String? lockFile,
  List<String> artifacts,
});

typedef _LockContext = ({
  String workspacePath,
  String lockFilePath,
});

typedef _ScanState = ({
  String? quote,
  bool escaped,
});

_ScanState _stepScan(_ScanState state, String ch) {
  if (state.escaped) return (quote: state.quote, escaped: false);
  if (state.quote != null) {
    if (ch == r'\') return (quote: state.quote, escaped: true);
    if (ch == state.quote) return (quote: null, escaped: false);
    return state;
  }
  if (ch == '"' || ch == "'") return (quote: ch, escaped: false);
  return state;
}

String _stripLineComment(String line) {
  _ScanState state = (quote: null, escaped: false);
  for (var i = 0; i < line.length; i++) {
    final String ch = line[i];
    if (state.quote == null && ch == '#') {
      return line.substring(0, i);
    }
    state = _stepScan(state, ch);
  }
  return line;
}

/// Drops `#` comments outside single- or double-quoted string literals.
String stripComments(String text) =>
    text.split('\n').map(_stripLineComment).join('\n');

int _findMatchingClose(
  String text,
  int openIndex,
  String openChar,
  String closeChar,
) {
  var depth = 0;
  _ScanState state = (quote: null, escaped: false);
  for (var i = openIndex; i < text.length; i++) {
    final String ch = text[i];
    if (state.quote == null) {
      if (ch == openChar) {
        depth++;
      } else if (ch == closeChar) {
        depth--;
        if (depth == 0) return i;
      }
    }
    state = _stepScan(state, ch);
  }
  return -1;
}

Set<String> _findMavenExtensionNames(String cleanText) {
  final names = <String>{'maven'};
  for (final RegExpMatch match in _mavenExtPattern.allMatches(cleanText)) {
    names.add(match.group(1)!);
  }
  return names;
}

List<String> _extractMethodBlocks(
  String cleanText,
  Set<String> receivers,
  String method,
) {
  final pattern = RegExp(
    '\\b(?:${receivers.join('|')})\\s*\\.\\s*$method\\s*\\(',
  );
  final blocks = <String>[];
  var searchFrom = 0;
  while (searchFrom < cleanText.length) {
    final RegExpMatch? match = pattern.firstMatch(
      cleanText.substring(searchFrom),
    );
    if (match == null) break;
    final int callStart = searchFrom + match.start;
    final int openParen = searchFrom + match.end - 1;
    final int closeParen = _findMatchingClose(cleanText, openParen, '(', ')');
    if (closeParen == -1) break;
    blocks.add(cleanText.substring(callStart, closeParen + 1));
    searchFrom = closeParen + 1;
  }
  return blocks;
}

String? _parseArtifactStructCoord(String block) {
  final String? group = _groupAttrPattern.firstMatch(block)?.group(2);
  final String? artifact = _artifactAttrPattern.firstMatch(block)?.group(2);
  if (group == null || artifact == null) return null;
  return '$group:$artifact';
}

List<String> _parseArtifactsAttribute(String installBlock, Set<String> exts) {
  final coords = <String>[];
  final attrStart = RegExp(r'\bartifacts\s*=\s*\[');
  final RegExpMatch? firstMatch = attrStart.firstMatch(installBlock);
  if (firstMatch == null) return coords;

  int listOpen = firstMatch.end - 1;
  final plusNextList = RegExp(r'^\s*\+\s*\[');
  while (listOpen >= 0 && listOpen < installBlock.length) {
    final int listClose = _findMatchingClose(installBlock, listOpen, '[', ']');
    if (listClose == -1) break;
    String body = installBlock.substring(listOpen + 1, listClose);
    final List<String> structBlocks = _extractMethodBlocks(
      body,
      exts,
      'artifact',
    );
    for (final structBlock in structBlocks) {
      final String? coord = _parseArtifactStructCoord(structBlock);
      if (coord != null) coords.add(coord);
      body = body.replaceFirst(structBlock, '');
    }
    for (final RegExpMatch m in _quotedStringPattern.allMatches(body)) {
      coords.add(m.group(2)!);
    }
    final RegExpMatch? next = plusNextList.firstMatch(
      installBlock.substring(listClose + 1),
    );
    if (next == null) break;
    listOpen = listClose + 1 + next.end - 1;
  }
  return coords;
}

/// Parses `rules_android_maven` install metadata from `MODULE.bazel` content.
MavenInstallInfo? parseRulesAndroidMavenInstall(String moduleContent) {
  final String clean = stripComments(moduleContent);
  final Set<String> exts = _findMavenExtensionNames(clean);
  final List<String> installBlocks = _extractMethodBlocks(
    clean,
    exts,
    'install',
  );

  var foundInstall = false;
  var missingLockOnAnyInstall = false;
  String? resolvedLockFile;
  final artifacts = <String>[];

  for (final block in installBlocks) {
    if (!_installNamePattern.hasMatch(block)) continue;
    foundInstall = true;
    final String? lockFile = _lockFilePattern.firstMatch(block)?.group(2);
    if (lockFile == null || lockFile.isEmpty) {
      missingLockOnAnyInstall = true;
    } else {
      resolvedLockFile = lockFile;
    }
    artifacts.addAll(_parseArtifactsAttribute(block, exts));
  }

  if (!foundInstall) return null;

  final List<String> artifactTagBlocks = _extractMethodBlocks(
    clean,
    exts,
    'artifact',
  );
  for (final block in artifactTagBlocks) {
    if (!_installNamePattern.hasMatch(block)) continue;
    final String? coord = _parseArtifactStructCoord(block);
    if (coord != null) artifacts.add(coord);
  }

  return (
    lockFile: missingLockOnAnyInstall ? null : resolvedLockFile,
    artifacts: artifacts,
  );
}

/// Resolves a Bazel lock file label (e.g. `//:rules_android_maven_install.json`)
/// to a filesystem path relative to the workspace directory.
String resolveLockFilePath(String workspacePath, String lockFileLabel) {
  final String normalized = lockFileLabel.startsWith('@//')
      ? lockFileLabel.substring(1)
      : lockFileLabel;
  if (normalized.startsWith('//:')) {
    return '$workspacePath/${normalized.substring(3)}';
  }
  if (normalized.startsWith('//')) {
    final String rel = normalized.substring(2).replaceAll(':', '/');
    return '$workspacePath/$rel';
  }
  if (normalized.startsWith(':')) {
    return '$workspacePath/${normalized.substring(1)}';
  }
  return '$workspacePath/$normalized';
}

bool _hasValidSha256(Object? shasums) {
  if (shasums is! Map<String, Object?> || shasums.isEmpty) return false;
  for (final Object? sha in shasums.values) {
    if (sha is! String || !_hex64Pattern.hasMatch(sha)) return false;
  }
  return true;
}

List<String> _validateArtifactEntries(
  Map<String, Object?> artifacts,
  _LockContext context,
  Set<String> outGroupArtifacts,
) {
  final errors = <String>[];
  for (final MapEntry<String, Object?> entry in artifacts.entries) {
    final String artifactKey = entry.key;
    final List<String> parts = artifactKey.split(':');
    if (parts.length >= 2) {
      outGroupArtifacts.add('${parts[0]}:${parts[1]}');
    }

    final Object? val = entry.value;
    final Object? shasums = val is Map<String, Object?> ? val['shasums'] : null;
    if (!_hasValidSha256(shasums)) {
      errors.add(
        "workspace '${context.workspacePath}', file '${context.lockFilePath}': "
        "artifact '$artifactKey' has no 64-hex sha256 under shasums",
      );
    }
  }
  return errors;
}

List<String> _validateDeclaredArtifacts(
  List<String> declaredArtifacts,
  Set<String> lockGroupArtifacts,
  _LockContext context,
) {
  final errors = <String>[];
  for (final declared in declaredArtifacts) {
    final List<String> parts = declared.split(':');
    if (parts.length < 2 || parts[0].isEmpty || parts[1].isEmpty) {
      errors.add(
        "workspace '${context.workspacePath}', file '${context.lockFilePath}': "
        "declared artifact '$declared' is not a valid group:artifact coordinate",
      );
      continue;
    }
    final ga = '${parts[0]}:${parts[1]}';
    if (!lockGroupArtifacts.contains(ga)) {
      errors.add(
        "workspace '${context.workspacePath}', file '${context.lockFilePath}': "
        "declared artifact '$declared' ($ga) is absent from lock",
      );
    }
  }
  return errors;
}

/// Validates the JSON content and entries of a Maven lock file.
List<String> validateLockContent({
  required String workspacePath,
  required String lockFilePath,
  required String lockJsonContent,
  required List<String> declaredArtifacts,
}) {
  final _LockContext context = (
    workspacePath: workspacePath,
    lockFilePath: lockFilePath,
  );
  Object? decoded;
  try {
    decoded = jsonDecode(lockJsonContent);
  } on FormatException {
    final msg =
        "workspace '$workspacePath', file '$lockFilePath': "
        'lock file is not valid JSON';
    return [msg];
  }

  if (decoded is! Map<String, Object?>) {
    final msg =
        "workspace '$workspacePath', file '$lockFilePath': "
        'lock file is not valid JSON (expected JSON object)';
    return [msg];
  }

  final errors = <String>[];
  final Object? rawVersion = decoded['version'];
  if (rawVersion != '2' && rawVersion != '3') {
    errors.add(
      "workspace '$workspacePath', file '$lockFilePath': "
      "expected lock version 2 or 3, got '$rawVersion'",
    );
  }

  final Object? artifactsRaw = decoded['artifacts'];
  if (artifactsRaw is! Map<String, Object?> || artifactsRaw.isEmpty) {
    errors.add(
      "workspace '$workspacePath', file '$lockFilePath': "
      'lock file has no valid artifacts map',
    );
    return errors;
  }

  final lockGroupArtifacts = <String>{};
  errors.addAll(
    _validateArtifactEntries(artifactsRaw, context, lockGroupArtifacts),
  );
  errors.addAll(
    _validateDeclaredArtifacts(declaredArtifacts, lockGroupArtifacts, context),
  );
  return errors;
}

/// Checks the `rules_android_maven` pin in a single workspace.
List<String> checkWorkspacePins(String workspacePath) {
  final moduleFile = File('$workspacePath/MODULE.bazel');
  if (!moduleFile.existsSync()) {
    final msg =
        "workspace '$workspacePath', file '${moduleFile.path}': "
        'MODULE.bazel does not exist';
    return [msg];
  }

  final String moduleContent = moduleFile.readAsStringSync();
  final MavenInstallInfo? install = parseRulesAndroidMavenInstall(
    moduleContent,
  );
  if (install == null) {
    final msg =
        "workspace '$workspacePath', file '${moduleFile.path}': "
        "an install of 'rules_android_maven' was not found";
    return [msg];
  }

  final String? lockLabel = install.lockFile;
  if (lockLabel == null || lockLabel.isEmpty) {
    final msg =
        "workspace '$workspacePath', file '${moduleFile.path}': "
        "an install of 'rules_android_maven' has no lock_file";
    return [msg];
  }

  if (lockLabel.startsWith('@') && !lockLabel.startsWith('@//')) {
    final msg =
        "workspace '$workspacePath', file '${moduleFile.path}': "
        "lock_file '$lockLabel' must point inside the workspace";
    return [msg];
  }

  final String lockFilePath = resolveLockFilePath(workspacePath, lockLabel);
  final lockFile = File(lockFilePath);
  if (!lockFile.existsSync()) {
    final msg =
        "workspace '$workspacePath', file '$lockFilePath': "
        'lock file is missing';
    return [msg];
  }

  final String lockContent = lockFile.readAsStringSync();
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
  final List<String> pathsToCheck = workspaces ?? defaultAndroidWorkspaces;
  final errors = <String>[];

  for (final relPath in pathsToCheck) {
    final fullPath = '$rootPath/$relPath';
    final List<String> wsErrors = checkWorkspacePins(fullPath);
    errors.addAll(wsErrors);
  }

  return errors;
}
