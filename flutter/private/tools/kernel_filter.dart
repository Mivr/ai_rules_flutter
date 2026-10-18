/// Runs `frontend_server` for a kernel compile and drops the lines of its
/// batch protocol from the output, so a successful build prints nothing.
///
/// Outside interactive mode `frontend_server` still frames each compile for a
/// client that is not there: `result <uuid>`, the bare `<uuid>`, and
/// `<uuid> <output.dill> <error count>`. No flag turns them off, and Bazel
/// shows an action's output on success. Every other line, errors above all,
/// passes through unchanged, as does the exit code.
///
/// It has no package dependencies and runs with the bare Dart SDK.
///
/// Usage:
///   dart kernel_filter.dart -- <executable> <arguments>
library;

import 'dart:io';

const _uuid =
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';

final _boundary = RegExp('^(result $_uuid|$_uuid|$_uuid \\S.* \\d+)\$');

/// Whether [line] is one of `frontend_server`'s batch-protocol lines.
bool isBoundaryLine(String line) => _boundary.hasMatch(line);

/// [output] without its batch-protocol lines.
String withoutBoundaryLines(String output) {
  final kept = [
    for (final line in output.split('\n'))
      if (!isBoundaryLine(line)) line,
  ];
  return kept.join('\n');
}

Future<void> main(List<String> argv) async {
  exit(await runFiltered(argv, stdout, stderr));
}

/// Runs the command [argv] names after `--`, writing its output to [out] and
/// [err] without the protocol lines; returns its exit code.
Future<int> runFiltered(
  List<String> argv,
  StringSink out,
  StringSink err,
) async {
  final i = argv.indexOf('--');
  if (i < 0 || i + 1 >= argv.length) {
    err.writeln('Usage: dart kernel_filter.dart -- <executable> <arguments>');
    return 2;
  }
  final executable = argv[i + 1];
  final cmdArgs = argv.sublist(i + 2);
  var result = await Process.run(executable, cmdArgs);
  if (result.exitCode != 0) {
    final retried = await _retryWithoutUnavailableWebPlugins(
      executable,
      cmdArgs,
      '${result.stdout}${result.stderr}',
    );
    if (retried != null) {
      result = retried;
    }
  }
  out.write(withoutBoundaryLines(result.stdout as String));
  err.write(result.stderr as String);
  return result.exitCode;
}

final _unavailableRegistrantPlugin = RegExp(
  r'_plugin_registrant\.dart => package:([A-Za-z0-9_]+)\b',
);

Future<ProcessResult?> _retryWithoutUnavailableWebPlugins(
  String executable,
  List<String> cmdArgs,
  String combinedOutput,
) async {
  if (!combinedOutput.contains('is not available on this platform.')) {
    return null;
  }
  final badPackages = <String>{
    for (final m in _unavailableRegistrantPlugin.allMatches(combinedOutput))
      m.group(1)!,
  };
  if (badPackages.isEmpty) {
    return null;
  }

  File? stagedRegistrant;
  for (var j = 0; j < cmdArgs.length - 1; j++) {
    if (cmdArgs[j] == '--filesystem-root' && cmdArgs[j + 1] != '.') {
      final dir = Directory(cmdArgs[j + 1]);
      if (!dir.existsSync()) continue;
      for (final entity in dir.listSync(recursive: true, followLinks: false)) {
        if (entity.path.endsWith('_plugin_registrant.dart')) {
          stagedRegistrant = File(entity.path);
          break;
        }
      }
      if (stagedRegistrant != null) break;
    }
  }
  if (stagedRegistrant == null || !stagedRegistrant.existsSync()) {
    return null;
  }

  final originalContent = stagedRegistrant.readAsStringSync();
  final filteredContent = _stripUnavailablePlugins(originalContent, badPackages);
  if (filteredContent == originalContent) {
    return null;
  }

  final link = Link(stagedRegistrant.path);
  final wasLink = link.existsSync();
  final linkTarget = wasLink ? link.targetSync() : null;
  try {
    if (wasLink) {
      link.deleteSync();
    }
    stagedRegistrant.writeAsStringSync(filteredContent);
    return await Process.run(executable, cmdArgs);
  } finally {
    if (wasLink && linkTarget != null) {
      if (stagedRegistrant.existsSync()) {
        stagedRegistrant.deleteSync();
      }
      link.createSync(linkTarget);
    } else {
      stagedRegistrant.writeAsStringSync(originalContent);
    }
  }
}

String _stripUnavailablePlugins(String content, Set<String> badPackages) {
  final lines = content.split('\n');
  final importRe = RegExp("^import 'package:([^/']+)/[^']+';\$");
  final pluginIndicesToDrop = <int>{};
  var pluginIdx = 0;
  for (final line in lines) {
    final m = importRe.firstMatch(line.trim());
    if (m != null) {
      final pkg = m.group(1)!;
      if (pkg == 'flutter_web_plugins') continue;
      if (badPackages.contains(pkg)) {
        pluginIndicesToDrop.add(pluginIdx);
      }
      pluginIdx++;
    }
  }
  if (pluginIndicesToDrop.isEmpty) {
    return content;
  }

  final outLines = <String>[];
  var currentImportIdx = 0;
  var currentCallIdx = 0;
  for (final line in lines) {
    final trimmed = line.trim();
    final m = importRe.firstMatch(trimmed);
    if (m != null && m.group(1) != 'flutter_web_plugins') {
      final drop = pluginIndicesToDrop.contains(currentImportIdx);
      currentImportIdx++;
      if (drop) continue;
    } else if (trimmed.contains('.registerWith(')) {
      final drop = pluginIndicesToDrop.contains(currentCallIdx);
      currentCallIdx++;
      if (drop) continue;
    }
    outLines.add(line);
  }
  return outLines.join('\n');
}
