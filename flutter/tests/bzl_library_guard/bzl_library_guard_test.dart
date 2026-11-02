/// Guard test verifying the root-module `bzl_library` graph, `flutter/*.bzl`
/// public file exports, and `//docs` `starlark_doc_extract` declarations.
library;

import 'dart:io';

import 'package:test/test.dart';

/// Public `@rules_dart` `.bzl` loads that provide a public `bzl_library` at
/// the pinned `ai_rules_dart` revision.
const Map<String, String> _rulesDartTargets = <String, String>{
  '@rules_dart//dart:analyze.bzl': '@rules_dart//dart:analyze',
  '@rules_dart//dart:defs.bzl': '@rules_dart//dart:defs',
  '@rules_dart//dart:extensions.bzl': '@rules_dart//dart:extensions',
  '@rules_dart//dart:providers.bzl': '@rules_dart//dart:providers',
  '@rules_dart//dart:repositories.bzl': '@rules_dart//dart:repositories',
  '@rules_dart//dart:toolchain.bzl': '@rules_dart//dart:toolchain',
  '@rules_dart//dart:utils.bzl': '@rules_dart//dart:utils',
  '@rules_dart//dart/ext:registry.bzl': '@rules_dart//dart/ext:registry',
  '@rules_dart//dart/pub:defs.bzl': '@rules_dart//dart/pub:defs',
  '@rules_dart//dart/pub:extensions.bzl': '@rules_dart//dart/pub:extensions',
  '@rules_dart//dart/pub:pinned_sources.bzl':
      '@rules_dart//dart/pub:pinned_sources',
  '@rules_dart//dart/pub:pub_lock_hub.bzl':
      '@rules_dart//dart/pub:pub_lock_hub',
  '@rules_dart//dart/pub:pub_lock_package.bzl':
      '@rules_dart//dart/pub:pub_lock_package',
  '@rules_dart//dart/pub:yaml_parser.bzl': '@rules_dart//dart/pub:yaml_parser',
};

/// External ruleset `.bzl` loads that expose a public `bzl_library` target.
const Map<String, String> _externalRuleTargets = <String, String>{
  '@apple_support//lib:apple_support.bzl': '@apple_support//lib:apple_support',
  '@rules_android//providers:providers.bzl':
      '@rules_android//providers:providers_bzl',
  '@rules_apple//apple:apple.bzl': '@rules_apple//apple:apple',
  '@rules_apple//apple:ios.bzl': '@rules_apple//apple:ios',
  '@rules_apple//apple:macos.bzl': '@rules_apple//apple:macos',
  '@rules_apple//apple:resources.bzl': '@rules_apple//apple:resources',
  '@rules_apple//apple:versioning.bzl': '@rules_apple//apple:versioning',
  '@rules_cc//cc:action_names.bzl': '@rules_cc//cc:action_names_bzl',
  '@rules_cc//cc:defs.bzl': '@rules_cc//cc:defs_bzl',
  '@rules_cc//cc:find_cc_toolchain.bzl': '@rules_cc//cc:find_cc_toolchain_bzl',
  '@rules_cc//cc:objc_library.bzl': '@rules_cc//cc:core_rules',
  '@rules_cc//cc/common:cc_common.bzl': '@rules_cc//cc/common:common',
  '@rules_cc//cc/common:cc_info.bzl': '@rules_cc//cc/common:common',
  '@rules_cc//cc/common:cc_shared_library_info.bzl':
      '@rules_cc//cc/common:cc_shared_library_info_bzl',
  '@rules_cc//cc/common:objc_info.bzl': '@rules_cc//cc/common:common',
  '@rules_java//java:java_import.bzl': '@rules_java//java:core_rules',
  '@rules_java//java/common:java_common.bzl': '@rules_java//java/common:common',
  '@rules_java//java/common:java_info.bzl': '@rules_java//java/common:common',
  '@rules_swift//swift:swift.bzl': '@rules_swift//swift:swift',
};

/// Expected public `.bzl` entry stems under `//flutter`.
const List<String> _publicEntryStems = <String>[
  'android',
  'defs',
  'dev_files',
  'extensions',
  'ios',
  'linux',
  'macos',
  'native_assets',
  'native_hot_patch',
  'providers',
  'repositories',
  'toolchain',
  'utils',
  'web',
  'windows',
];

enum _TokKind { ident, string, punct }

class _Tok {
  const _Tok(this.kind, this.text, this.depth);

  final _TokKind kind;
  final String text;
  final int depth;
}

class _CallNode {
  const _CallNode({
    required this.callee,
    required this.firstStringArg,
    required this.firstListArg,
    required this.stringAttrs,
    required this.listAttrs,
  });

  final String callee;
  final String? firstStringArg;
  final List<String>? firstListArg;
  final Map<String, String> stringAttrs;
  final Map<String, List<String>?> listAttrs;
}

class _BzlRule {
  const _BzlRule({
    required this.name,
    required this.packagePath,
    required this.srcs,
    required this.explicitVisibility,
    required this.deps,
  });

  final String name;
  final String packagePath;
  final List<String>? srcs;
  final List<String>? explicitVisibility;
  final List<String>? deps;

  String get label => '//$packagePath:$name';
}

class _PackageBuild {
  const _PackageBuild({
    required this.packagePath,
    required this.defaultVisibility,
    required this.bzlRules,
    required this.otherRuleNames,
    required this.calls,
  });

  final String packagePath;
  final List<String> defaultVisibility;
  final List<_BzlRule> bzlRules;
  final Set<String> otherRuleNames;
  final List<_CallNode> calls;
}

class _WorkspaceGraph {
  const _WorkspaceGraph({
    required this.repoRoot,
    required this.bzlFiles,
    required this.packages,
    required this.fileToOwner,
    required this.duplicateCoverage,
  });

  final String repoRoot;
  final List<String> bzlFiles;
  final Map<String, _PackageBuild> packages;
  final Map<String, _BzlRule> fileToOwner;
  final List<String> duplicateCoverage;
}

int _skipLineComment(String src, int pos) {
  var idx = pos;
  while (idx < src.length && src.codeUnitAt(idx) != 0x0A) {
    idx++;
  }
  return idx;
}

bool _isStringStart(String src, int pos) {
  final ch = src[pos];
  if (ch == '"' || ch == "'") return true;
  if ((ch == 'r' || ch == 'R' || ch == 'b' || ch == 'B') &&
      pos + 1 < src.length) {
    final next = src[pos + 1];
    return next == '"' || next == "'";
  }
  return false;
}

(String, int) _scanStringLiteral(String src, int start) {
  var pos = start;
  var isRaw = false;
  if (src[pos] != '"' && src[pos] != "'") {
    isRaw = src[pos] == 'r' || src[pos] == 'R';
    pos++;
  }
  final quote = src[pos];
  final delim = src.startsWith('$quote$quote$quote', pos)
      ? '$quote$quote$quote'
      : quote;
  pos += delim.length;
  final buf = StringBuffer();
  while (pos < src.length) {
    if (src.startsWith(delim, pos)) {
      return (buf.toString(), pos + delim.length);
    }
    final ch = src[pos];
    if (!isRaw && ch == r'\' && pos + 1 < src.length) {
      buf.write(src[pos + 1]);
      pos += 2;
      continue;
    }
    buf.write(ch);
    pos++;
  }
  return (buf.toString(), pos);
}

bool _isIdentChar(int unit, {required bool start}) {
  final isAlpha =
      (unit >= 0x41 && unit <= 0x5A) ||
      (unit >= 0x61 && unit <= 0x7A) ||
      unit == 0x5F;
  if (start) return isAlpha;
  return isAlpha || (unit >= 0x30 && unit <= 0x39);
}

(String, int) _scanIdentifier(String src, int start) {
  var end = start + 1;
  while (end < src.length && _isIdentChar(src.codeUnitAt(end), start: false)) {
    end++;
  }
  return (src.substring(start, end), end);
}

int _updateDepthAndEmitPunct(String ch, int depth, List<_Tok> out) {
  if (ch == '(' || ch == '[' || ch == '{') {
    out.add(_Tok(_TokKind.punct, ch, depth));
    return depth + 1;
  }
  if (ch == ')' || ch == ']' || ch == '}') {
    final nextDepth = depth > 0 ? depth - 1 : 0;
    out.add(_Tok(_TokKind.punct, ch, nextDepth));
    return nextDepth;
  }
  out.add(_Tok(_TokKind.punct, ch, depth));
  return depth;
}

List<_Tok> _tokenizeStarlark(String src) {
  final out = <_Tok>[];
  var depth = 0;
  var pos = 0;
  while (pos < src.length) {
    final unit = src.codeUnitAt(pos);
    if (unit <= 0x20) {
      pos++;
    } else if (unit == 0x23) {
      pos = _skipLineComment(src, pos);
    } else if (_isStringStart(src, pos)) {
      final (val, next) = _scanStringLiteral(src, pos);
      out.add(_Tok(_TokKind.string, val, depth));
      pos = next;
    } else if (_isIdentChar(unit, start: true)) {
      final (ident, next) = _scanIdentifier(src, pos);
      out.add(_Tok(_TokKind.ident, ident, depth));
      pos = next;
    } else {
      depth = _updateDepthAndEmitPunct(src[pos], depth, out);
      pos++;
    }
  }
  return out;
}

List<String>? _parseLiteralList(List<_Tok> tokens, int openBracket, int limit) {
  final bracketDepth = tokens[openBracket].depth;
  final items = <String>[];
  for (var idx = openBracket + 1; idx < limit; idx++) {
    final tok = tokens[idx];
    if (tok.depth == bracketDepth && tok.text == ']') {
      final hasTrailingExpr =
          idx + 1 < limit &&
          tokens[idx + 1].depth == bracketDepth &&
          tokens[idx + 1].text != ',' &&
          tokens[idx + 1].text != ')';
      return hasTrailingExpr ? null : items;
    }
    if (tok.depth != bracketDepth + 1) continue;
    if (tok.kind == _TokKind.string) {
      items.add(tok.text);
    } else if (tok.text != ',') {
      return null;
    }
  }
  return null;
}

(String?, List<String>?) _parseFirstPositionalArg(
  List<_Tok> tokens,
  int openParen,
  int closeParen,
) {
  final firstIdx = openParen + 1;
  if (firstIdx >= closeParen) return (null, null);
  final t0 = tokens[firstIdx];
  if (t0.depth != 1) return (null, null);
  final isKeyword =
      t0.kind == _TokKind.ident &&
      firstIdx + 1 < closeParen &&
      tokens[firstIdx + 1].depth == 1 &&
      tokens[firstIdx + 1].text == '=';
  if (isKeyword) return (null, null);
  if (t0.kind == _TokKind.string) return (t0.text, null);
  if (t0.text == '[') {
    return (null, _parseLiteralList(tokens, firstIdx, closeParen));
  }
  return (null, null);
}

_CallNode _buildCallNode(
  String callee,
  List<_Tok> tokens,
  int openParen,
  int closeParen,
) {
  final (firstStr, firstList) = _parseFirstPositionalArg(
    tokens,
    openParen,
    closeParen,
  );
  final strAttrs = <String, String>{};
  final listAttrs = <String, List<String>?>{};

  for (var i = openParen + 1; i + 2 < closeParen; i++) {
    final tok = tokens[i];
    final eq = tokens[i + 1];
    if (tok.depth != 1 || tok.kind != _TokKind.ident) continue;
    if (eq.depth != 1 || eq.text != '=') continue;
    final valTok = tokens[i + 2];
    if (valTok.depth == 1 && valTok.kind == _TokKind.string) {
      strAttrs[tok.text] = valTok.text;
      continue;
    }
    listAttrs[tok.text] = (valTok.depth == 1 && valTok.text == '[')
        ? _parseLiteralList(tokens, i + 2, closeParen)
        : null;
  }

  return _CallNode(
    callee: callee,
    firstStringArg: firstStr,
    firstListArg: firstList,
    stringAttrs: strAttrs,
    listAttrs: listAttrs,
  );
}

List<_CallNode> _parseTopLevelCalls(String source) {
  final tokens = _tokenizeStarlark(source);
  final calls = <_CallNode>[];
  var i = 0;
  while (i + 1 < tokens.length) {
    final tok = tokens[i];
    final next = tokens[i + 1];
    if (tok.depth == 0 &&
        tok.kind == _TokKind.ident &&
        next.depth == 0 &&
        next.text == '(') {
      var callee = tok.text;
      if (i >= 2 &&
          tokens[i - 1].depth == 0 &&
          tokens[i - 1].text == '.' &&
          tokens[i - 2].depth == 0 &&
          tokens[i - 2].kind == _TokKind.ident) {
        callee = '${tokens[i - 2].text}.${tok.text}';
      }
      var close = i + 2;
      while (close < tokens.length &&
          !(tokens[close].depth == 0 && tokens[close].text == ')')) {
        close++;
      }
      if (close < tokens.length) {
        calls.add(_buildCallNode(callee, tokens, i + 1, close));
        i = close + 1;
        continue;
      }
    }
    i++;
  }
  return calls;
}

String _resolveWorkspaceRoot() {
  final envDir = Platform.environment['BUILD_WORKSPACE_DIRECTORY'];
  if (envDir != null &&
      envDir.isNotEmpty &&
      Directory('$envDir/flutter').existsSync() &&
      File('$envDir/MODULE.bazel').existsSync()) {
    return envDir;
  }
  final anchor = Platform.environment['GUARD_ROOT_ANCHOR'];
  final srcDir = Platform.environment['TEST_SRCDIR'];
  if (anchor == null || anchor.isEmpty || srcDir == null || srcDir.isEmpty) {
    throw StateError('Missing GUARD_ROOT_ANCHOR or TEST_SRCDIR environment');
  }
  var cursor = File('$srcDir/$anchor').resolveSymbolicLinksSync();
  var dir = File(cursor).parent;
  for (var step = 0; step < 10; step++) {
    if (Directory('${dir.path}/flutter').existsSync() &&
        File('${dir.path}/MODULE.bazel').existsSync()) {
      return dir.path;
    }
    dir = dir.parent;
  }
  throw StateError('Unable to locate rules_flutter root above $anchor');
}

Set<String> _readBazelIgnorePrefixes(String repoRoot) {
  final prefixes = <String>{'e2e', 'flutter/tests'};
  final ignoreFile = File('$repoRoot/.bazelignore');
  if (!ignoreFile.existsSync()) return prefixes;
  for (final raw in ignoreFile.readAsLinesSync()) {
    final trimmed = raw.trim().replaceAll(RegExp(r'/+$'), '');
    if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
      prefixes.add(trimmed);
    }
  }
  return prefixes;
}

bool _isExcludedRelDir(String relDir, Set<String> ignoredPrefixes) {
  final segments = relDir.split('/');
  if (segments.any((s) => s.startsWith('.') || s == 'node_modules')) {
    return true;
  }
  for (final prefix in ignoredPrefixes) {
    if (relDir == prefix || relDir.startsWith('$prefix/')) return true;
  }
  return false;
}

File? _collectDirectoryEntries({
  required Directory dir,
  required String relDir,
  required Set<String> ignored,
  required List<Directory> queue,
  required List<String> bzlFiles,
}) {
  File? pkgBuild;
  for (final entity in dir.listSync(followLinks: false)) {
    final base = entity.path.split(Platform.pathSeparator).last;
    final childRel = relDir.isEmpty ? base : '$relDir/$base';
    if (entity is Directory) {
      if (!_isExcludedRelDir(childRel, ignored)) queue.add(entity);
    } else if (entity is File && base == 'BUILD.bazel') {
      pkgBuild = entity;
    } else if (entity is File && base == 'BUILD' && pkgBuild == null) {
      pkgBuild = entity;
    } else if (entity is File && base.endsWith('.bzl')) {
      bzlFiles.add(childRel);
    }
  }
  return pkgBuild;
}

(List<String>, Map<String, File>) _scanWorkspaceTree(String repoRoot) {
  final ignored = _readBazelIgnorePrefixes(repoRoot);
  final bzlFiles = <String>[];
  final buildFiles = <String, File>{};
  final queue = <Directory>[Directory(repoRoot)];

  while (queue.isNotEmpty) {
    final current = queue.removeLast();
    final relDir = current.path == repoRoot
        ? ''
        : current.path.substring(repoRoot.length + 1);
    final pkgBuild = _collectDirectoryEntries(
      dir: current,
      relDir: relDir,
      ignored: ignored,
      queue: queue,
      bzlFiles: bzlFiles,
    );
    if (pkgBuild != null) buildFiles[relDir] = pkgBuild;
  }
  bzlFiles.sort();
  return (bzlFiles, buildFiles);
}

_PackageBuild _parsePackageBuild(String pkgPath, File buildFile) {
  final calls = _parseTopLevelCalls(buildFile.readAsStringSync());
  var defaultVis = const <String>[];
  final bzlRules = <_BzlRule>[];
  final otherNames = <String>{};

  for (final call in calls) {
    if (call.callee == 'package') {
      defaultVis = call.listAttrs['default_visibility'] ?? const <String>[];
      continue;
    }
    final isBzlLib =
        call.callee == 'bzl_library' || call.callee == 'native.bzl_library';
    final name = call.stringAttrs['name'];
    if (isBzlLib && name != null) {
      final hasVis = call.listAttrs.containsKey('visibility');
      bzlRules.add(
        _BzlRule(
          name: name,
          packagePath: pkgPath,
          srcs: call.listAttrs.containsKey('srcs')
              ? call.listAttrs['srcs']
              : const <String>[],
          explicitVisibility: hasVis
              ? (call.listAttrs['visibility'] ?? const <String>[])
              : null,
          deps: call.listAttrs.containsKey('deps')
              ? call.listAttrs['deps']
              : const <String>[],
        ),
      );
    } else if (name != null) {
      otherNames.add(name);
    }
  }
  return _PackageBuild(
    packagePath: pkgPath,
    defaultVisibility: defaultVis,
    bzlRules: bzlRules,
    otherRuleNames: otherNames,
    calls: calls,
  );
}

String? _enclosingPackage(String relFile, Map<String, _PackageBuild> packages) {
  var dir = relFile.contains('/')
      ? relFile.substring(0, relFile.lastIndexOf('/'))
      : '';
  while (true) {
    if (packages.containsKey(dir)) return dir;
    if (dir.isEmpty) return null;
    dir = dir.contains('/') ? dir.substring(0, dir.lastIndexOf('/')) : '';
  }
}

_WorkspaceGraph _loadWorkspaceGraph() {
  final repoRoot = _resolveWorkspaceRoot();
  final (bzlFiles, buildFiles) = _scanWorkspaceTree(repoRoot);
  final packages = <String, _PackageBuild>{
    for (final entry in buildFiles.entries)
      entry.key: _parsePackageBuild(entry.key, entry.value),
  };

  final fileToOwner = <String, _BzlRule>{};
  final duplicates = <String>[];
  for (final pkg in packages.values) {
    for (final rule in pkg.bzlRules) {
      for (final src in rule.srcs ?? const <String>[]) {
        final cleanSrc = src.startsWith(':') ? src.substring(1) : src;
        final relPath = pkg.packagePath.isEmpty
            ? cleanSrc
            : '${pkg.packagePath}/$cleanSrc';
        final previous = fileToOwner[relPath];
        if (previous != null) {
          duplicates.add(
            '$relPath covered by ${previous.label} and ${rule.label}',
          );
        } else {
          fileToOwner[relPath] = rule;
        }
      }
    }
  }
  return _WorkspaceGraph(
    repoRoot: repoRoot,
    bzlFiles: bzlFiles,
    packages: packages,
    fileToOwner: fileToOwner,
    duplicateCoverage: duplicates,
  );
}

void _validatePackageRules(
  _PackageBuild pkg,
  Set<String> bzlSet,
  List<String> problems,
) {
  final seenNames = <String>{};
  for (final rule in pkg.bzlRules) {
    if (!seenNames.add(rule.name)) {
      problems.add('duplicate bzl_library name ${rule.label}');
    }
    if (pkg.otherRuleNames.contains(rule.name)) {
      problems.add('${rule.label} collides with another target in package');
    }
    final srcs = rule.srcs;
    if (srcs == null || srcs.length != 1) {
      problems.add('${rule.label} must declare exactly 1 literal srcs file');
      continue;
    }
    final src = srcs.single;
    final cleanSrc = src.startsWith(':') ? src.substring(1) : src;
    final stem = cleanSrc.endsWith('.bzl')
        ? cleanSrc.substring(0, cleanSrc.length - 4)
        : cleanSrc;
    if (rule.name != stem && !pkg.otherRuleNames.contains(stem)) {
      problems.add('${rule.label} name must equal stem $stem');
    }
    final relPath = pkg.packagePath.isEmpty
        ? cleanSrc
        : '${pkg.packagePath}/$cleanSrc';
    if (!bzlSet.contains(relPath)) {
      problems.add('${rule.label} srcs entry $src is not a non-test .bzl');
    }
  }
}

void _verifyCoverageAndShape(_WorkspaceGraph graph) {
  final problems = <String>[...graph.duplicateCoverage];
  final bzlSet = graph.bzlFiles.toSet();

  for (final file in graph.bzlFiles) {
    final pkg = _enclosingPackage(file, graph.packages);
    if (pkg == null) {
      problems.add('$file has no enclosing BUILD.bazel package');
    } else if (!graph.fileToOwner.containsKey(file)) {
      problems.add('$file has no bzl_library target in //$pkg');
    }
  }

  for (final pkg in graph.packages.values) {
    if (pkg.packagePath != 'docs') {
      _validatePackageRules(pkg, bzlSet, problems);
    }
  }

  expect(problems, isEmpty, reason: problems.join('\n'));
}

void _verifyDocsVisibility(_WorkspaceGraph graph) {
  final violations = <String>[];
  for (final pkg in graph.packages.values) {
    if (pkg.packagePath == 'docs') continue;
    for (final rule in pkg.bzlRules) {
      final effective = rule.explicitVisibility ?? pkg.defaultVisibility;
      final visibleToDocs =
          effective.contains('//visibility:public') ||
          effective.contains('//docs:__pkg__') ||
          effective.contains('//docs:__subpackages__');
      if (!visibleToDocs) {
        violations.add('${rule.label} visibility $effective excludes //docs');
      }
    }
  }
  expect(violations, isEmpty, reason: violations.join('\n'));
}

String _canonicalizeDep(String rawDep, String packagePath) {
  var dep = rawDep;
  if (dep.startsWith('@@//')) {
    dep = dep.substring(2);
  } else if (dep.startsWith('@rules_flutter//')) {
    dep = dep.substring('@rules_flutter'.length);
  }
  if (dep.startsWith(':')) {
    return '//$packagePath$dep';
  }
  if (!dep.contains(':')) {
    final lastSlash = dep.lastIndexOf('/');
    final implicitName = dep.substring(lastSlash + 1);
    return '$dep:$implicitName';
  }
  return dep;
}

String? _sameRepoFileFromLoad(String rawLoad, String currentPkg) {
  var normalized = rawLoad;
  if (normalized.startsWith('@@//')) {
    normalized = normalized.substring(2);
  } else if (normalized.startsWith('@rules_flutter//')) {
    normalized = normalized.substring('@rules_flutter'.length);
  }
  if (normalized.startsWith(':')) {
    final file = normalized.substring(1);
    return currentPkg.isEmpty ? file : '$currentPkg/$file';
  }
  if (normalized.startsWith('//')) {
    final colon = normalized.indexOf(':');
    if (colon < 0) return null;
    final pkg = normalized.substring(2, colon);
    final file = normalized.substring(colon + 1);
    return pkg.isEmpty ? file : '$pkg/$file';
  }
  return null;
}

String? _resolveExternalDepTarget(String rawLoad, String currentPkg) {
  if (rawLoad.startsWith('@bazel_skylib//')) {
    final target = rawLoad.endsWith('.bzl')
        ? rawLoad.substring(0, rawLoad.length - 4)
        : rawLoad;
    return _canonicalizeDep(target, currentPkg);
  }
  if (rawLoad.startsWith('@rules_dart//')) {
    return _rulesDartTargets[rawLoad];
  }
  return _externalRuleTargets[rawLoad];
}

(Set<String>, List<String>) _expectedDepsForFile(
  String bzlFile,
  String currentPkg,
  _WorkspaceGraph graph,
) {
  final calls = _parseTopLevelCalls(
    File('${graph.repoRoot}/$bzlFile').readAsStringSync(),
  );
  final requiredDeps = <String>{};
  final loadErrors = <String>[];

  for (final call in calls) {
    if (call.callee != 'load' || call.firstStringArg == null) continue;
    final rawLoad = call.firstStringArg!;
    final sameRepoFile = _sameRepoFileFromLoad(rawLoad, currentPkg);
    if (sameRepoFile != null) {
      final owner = graph.fileToOwner[sameRepoFile];
      if (owner == null) {
        loadErrors.add('$bzlFile loads $rawLoad which has no bzl_library');
      } else {
        requiredDeps.add(owner.label);
      }
      continue;
    }
    final externalTarget = _resolveExternalDepTarget(rawLoad, currentPkg);
    if (externalTarget != null) requiredDeps.add(externalTarget);
  }
  return (requiredDeps, loadErrors);
}

void _checkSingleOwnerDeps(
  String file,
  _BzlRule owner,
  _WorkspaceGraph graph,
  List<String> errors,
) {
  final rawDeps = owner.deps;
  if (rawDeps == null) {
    errors.add('${owner.label} has non-literal deps expression');
    return;
  }

  final seenRaw = <String>{};
  final declaredCanonical = <String>{};
  for (final rawDep in rawDeps) {
    if (!seenRaw.add(rawDep)) {
      errors.add('${owner.label} lists duplicate dep $rawDep');
    }
    if (rawDep.endsWith('.bzl')) {
      errors.add('${owner.label} lists raw .bzl path $rawDep in deps');
    }
    declaredCanonical.add(_canonicalizeDep(rawDep, owner.packagePath));
  }

  final (expectedDeps, loadErrors) = _expectedDepsForFile(
    file,
    owner.packagePath,
    graph,
  );
  errors.addAll(loadErrors);

  for (final req in expectedDeps) {
    if (!declaredCanonical.contains(req)) {
      errors.add('$file (${owner.label}) missing dep $req');
    }
  }
  for (final decl in declaredCanonical) {
    if (!expectedDeps.contains(decl)) {
      errors.add('$file (${owner.label}) lists unloaded dep $decl');
    }
  }
}

void _verifyLoadObligations(_WorkspaceGraph graph) {
  final errors = <String>[];
  for (final file in graph.bzlFiles) {
    final owner = graph.fileToOwner[file];
    if (owner != null) {
      _checkSingleOwnerDeps(file, owner, graph, errors);
    }
  }
  expect(errors, isEmpty, reason: errors.join('\n'));
}

void _verifyPublicExports(_WorkspaceGraph graph) {
  final problems = <String>[];
  final flutterPkg = graph.packages['flutter'];
  if (flutterPkg == null) {
    problems.add('flutter/BUILD.bazel not found');
  } else {
    final publicExports = <String>[];
    for (final call in flutterPkg.calls) {
      if (call.callee != 'exports_files') continue;
      final vis = call.listAttrs['visibility'] ?? flutterPkg.defaultVisibility;
      if (vis.contains('//visibility:public') && call.firstListArg != null) {
        publicExports.addAll(call.firstListArg!);
      }
    }
    final seenExports = <String>{};
    for (final exp in publicExports) {
      if (!seenExports.add(exp)) {
        problems.add('flutter/BUILD.bazel exports $exp more than once');
      }
    }
    for (final stem in _publicEntryStems) {
      if (!seenExports.contains('$stem.bzl')) {
        problems.add('flutter/BUILD.bazel does not publicly export $stem.bzl');
      }
    }
  }
  expect(problems, isEmpty, reason: problems.join('\n'));
}

void _validateSingleDocExtract(
  String stem,
  Map<String, _CallNode> docExtracts,
  List<String> problems,
) {
  final target = docExtracts['$stem.doc_extract'];
  if (target == null) {
    problems.add('Missing //docs:$stem.doc_extract');
    return;
  }
  if (target.stringAttrs['src'] != '//flutter:$stem.bzl') {
    problems.add('//docs:$stem.doc_extract has wrong src');
  }
  final deps = target.listAttrs['deps'] ?? const <String>[];
  if (deps.length != 1 || deps.single != '//flutter:$stem') {
    problems.add('//docs:$stem.doc_extract must depend on //flutter:$stem');
  }
}

void _verifyDocsExtracts(_WorkspaceGraph graph) {
  final docsPkg = graph.packages['docs'];
  if (docsPkg == null) {
    fail('docs/BUILD.bazel does not exist');
  }
  final problems = <String>[];
  final docExtracts = <String, _CallNode>{};
  var hasAllFilegroup = false;
  for (final call in docsPkg.calls) {
    if (call.callee == 'starlark_doc_extract') {
      final name = call.stringAttrs['name'];
      if (name != null) docExtracts[name] = call;
    } else if (call.callee == 'filegroup' &&
        call.stringAttrs['name'] == 'all_doc_extracts') {
      final vis = call.listAttrs['visibility'] ?? docsPkg.defaultVisibility;
      hasAllFilegroup = vis.contains('//visibility:public');
    }
  }
  if (docExtracts.length != _publicEntryStems.length) {
    final count = docExtracts.length;
    problems.add(
      'Expected 15 starlark_doc_extract targets in //docs, got $count',
    );
  }
  for (final stem in _publicEntryStems) {
    _validateSingleDocExtract(stem, docExtracts, problems);
  }
  if (!hasAllFilegroup) {
    problems.add('Missing public filegroup //docs:all_doc_extracts');
  }
  expect(problems, isEmpty, reason: problems.join('\n'));
}

void main() {
  late final _WorkspaceGraph graph;

  setUpAll(() {
    graph = _loadWorkspaceGraph();
  });

  test(
    'every root-module non-test bzl file belongs to a single bzl_library',
    () {
      _verifyCoverageAndShape(graph);
    },
  );

  test('every root-module non-test bzl_library is visible to //docs', () {
    _verifyDocsVisibility(graph);
  });

  test('every bzl_library deps list matches its srcs load statements', () {
    _verifyLoadObligations(graph);
  });

  test('flutter publicly exports all 15 entry bzl files', () {
    _verifyPublicExports(graph);
  });

  test(
    'docs declares 15 starlark_doc_extract targets and all_doc_extracts',
    () {
      _verifyDocsExtracts(graph);
    },
  );
}
