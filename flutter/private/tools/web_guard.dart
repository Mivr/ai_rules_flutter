/// Guards a Flutter web compile (dart2js, dart2wasm, or the `--cfe-only`
/// icon kernel) and then runs it.
///
/// Before the compiler runs, every declared source's directives are checked
/// against the declared inputs (`directive_guard.dart`): a directive that
/// names no declared file — a `file:` URI in any spelling, any other
/// unexpected scheme, or a relative URI climbing out of the declared inputs —
/// fails the build, under every strategy. The compile mounts only its staging
/// root, so an undeclared file is not there to be read whatever its spelling.
///
/// Unlike `kernel_filter.dart`, there is no post-compile read-set check: the
/// web compilers print no `+file://` dependency lines to verify. The guard
/// plus the stage-only root is the whole confinement.
///
/// A source that is not decodable UTF-8 fails closed here instead of being
/// skipped: the front ends accept such files, so skipping the check while the
/// compiler reads the import would confine nothing.
///
/// It is compiled to a self-contained native executable (see the `web_guard`
/// `dart_binary`): the guarded compile stages only the executable and its
/// manifest, never a Dart VM's snapshots and debug symbols.
///
/// Usage:
///   web_guard --declared-inputs <manifest> -- <executable> <arguments>
library;

import 'dart:io';

import 'directive_guard.dart';

Future<void> main(List<String> argv) async {
  exit(await runGuarded(argv, stdout, stderr));
}

/// Runs the command [argv] names after `--` once its declared sources pass
/// the directive guard, writing its output to [out] and [err]; returns its
/// exit code.
///
/// The tool flags before `--` name the compile's declared inputs
/// (`--declared-inputs <manifest>`): the manifest lists one exec-root-relative
/// path per line — the declared sources, then a `# staged` marker, then the
/// staging root's symlinks to them — written by the `flutter_dart2js_action`,
/// `flutter_dart2wasm_action` and `flutter_dart2js_cfe_action` helpers. The
/// `.dart` sources' directives are refused before the compiler runs when they
/// name an undeclared file; a source that cannot be read as text fails closed
/// for the same reason. The `--multi-root` values in the compiler's own
/// arguments are the filesystem roots the app-scheme keys resolve against.
Future<int> runGuarded(
  List<String> argv,
  StringSink out,
  StringSink err,
) async {
  final i = argv.indexOf('--');
  if (i < 0 || i + 1 >= argv.length) {
    err.writeln(
      'Usage: web_guard --declared-inputs <manifest> -- <executable> <arguments>',
    );
    return 2;
  }
  String? manifestPath;
  for (var j = 0; j < i; j++) {
    if (argv[j] == '--declared-inputs' && j + 1 < i) {
      manifestPath = argv[++j];
    } else {
      err.writeln('web_guard: unexpected argument ${argv[j]}.');
      return 2;
    }
  }
  if (manifestPath == null) {
    err.writeln(
      'web_guard: missing required --declared-inputs <manifest>.',
    );
    return 2;
  }
  final manifest = File(manifestPath);
  if (!manifest.existsSync()) {
    err.writeln(
      'web_guard: declared-inputs manifest $manifestPath does not exist.',
    );
    return 2;
  }
  // The manifest lists the declared sources, then `# staged`, then the
  // staging root's symlinks to them: the guard scans the sources (the links
  // hold the same bytes).
  final sources = <String>[];
  var staged = false;
  for (final line in manifest.readAsLinesSync()) {
    final path = line.trim().replaceAll(r'\', '/');
    if (path.isEmpty) continue;
    if (path.startsWith('#')) {
      staged = true;
      continue;
    }
    if (!staged && path.endsWith('.dart')) sources.add(path);
  }
  final executable = argv[i + 1];
  final cmdArgs = argv.sublist(i + 2);

  // A file the guard cannot decode is refused rather than skipped: the web
  // front ends compile such files, so a skip would leave the import they
  // carry unchecked. A file missing here is left to the compiler, which
  // reports it. (`readAsStringSync` reports a decode failure as a
  // `FileSystemException`, so existence is what tells a missing file from an
  // undecodable one.)
  for (final path in sources) {
    final file = File(path);
    if (!file.existsSync()) continue;
    try {
      file.readAsStringSync();
    } on FileSystemException {
      err.writeln(
        "flutter: $path is not decodable text and is not a declared input.",
      );
      return 1;
    }
  }

  // The bzl helpers pass the staging root the compilers mount as
  // `--multi-root=<stage>`: app-scheme keys resolve against it the way the
  // compilers resolve them.
  final fsRoots = <String>[];
  for (var j = 0; j < cmdArgs.length; j++) {
    final arg = cmdArgs[j];
    if (arg == '--multi-root' && j + 1 < cmdArgs.length) {
      fsRoots.add(cmdArgs[++j]);
    } else if (arg.startsWith('--multi-root=')) {
      fsRoots.add(arg.substring('--multi-root='.length));
    }
  }
  final guardErrors = findDisallowedFlutterDirectives(
    sources,
    fsRoots,
    tool: 'flutter',
  );
  if (guardErrors.isNotEmpty) {
    for (final error in guardErrors) {
      err.writeln(error);
    }
    return 1;
  }

  final result = await Process.run(executable, cmdArgs);
  out.write(result.stdout as String);
  err.write(result.stderr as String);
  return result.exitCode;
}
