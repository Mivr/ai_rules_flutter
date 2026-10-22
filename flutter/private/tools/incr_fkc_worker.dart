/// An opt-in incremental `FlutterKernelCompile` worker: a persistent
/// `frontend_server` per configuration, debug JIT only.
///
/// The action's output is F: the full dill written by a `reset` plus an empty
/// `recompile` from a `frontend_server` running with
/// `--no-incremental-serialization`, after the deltas. F carries no history,
/// so a warm worker, a fresh one-shot process, and sandboxed or remote runs
/// all write the same bytes.
///
/// Usage (exactly `kernel_filter`'s argv after argv[0], flagfiles included):
///   incr_fkc_worker --declared-inputs <manifest> -- <executable> <arguments>
/// with `--persistent_worker` for the Bazel JSON persistent-worker protocol,
/// without it for a one-shot fresh-process run of the same protocol.
///
/// A request whose inputs differ from the last accepted request only in
/// staged Dart sources sends `recompile` with the changed sources' URIs (a
/// delta), accepts, then `reset` plus an empty `recompile`; anything else (a
/// new key, a changed non-source input, a dead server) starts cold. Every
/// compile's read set is checked against the declared-inputs manifest, and a
/// failed compile is rejected, so the server stays at the last good state.
///
/// Change detection reads file contents: request digests are ignored, so a
/// stale digest never hides a change.
library;

import 'dart:convert';
import 'dart:io';

import 'directive_guard.dart';
import 'incr_fkc_server.dart';
import 'kernel_filter.dart';
import 'sha256.dart';

/// The outcome of one worker request.
typedef IncrResult = ({int exitCode, String output});

/// The directive guard with its result cached by content digest.
///
/// The key mixes every declared source's content hash with the filesystem
/// roots: any changed `.dart` file invalidates the cache and re-runs the
/// guard over all sources, so every changed file is always checked.
class GuardCache {
  GuardCache({List<String> Function(List<String>, List<String>)? runGuard})
    : _runGuard = runGuard ?? _defaultRunGuard;

  final List<String> Function(List<String>, List<String>) _runGuard;
  String? _key;
  List<String>? _errors;

  static List<String> _defaultRunGuard(
    List<String> sources,
    List<String> roots,
  ) => findDisallowedFlutterDirectives(sources, roots, tool: 'flutter');

  /// The guard errors for [dartSources] under [roots] given the current
  /// content [hashes] (null marks a missing file).
  List<String> check(
    List<String> dartSources,
    List<String> roots,
    Map<String, String?> hashes,
  ) {
    final parts = [
      for (final s in dartSources) '${hashes[s] ?? '<missing>'} $s',
      ...roots,
    ]..sort();
    final key = sha256Hex(utf8.encode(parts.join('\x00')));
    if (key == _key) return _errors!;
    final errors = _runGuard(dartSources, roots);
    _key = key;
    _errors = errors;
    return errors;
  }
}

/// One warm server and the last accepted request behind it.
class IncrServerState {
  IncrServerState({
    required this.session,
    required this.roots,
    required this.fullDill,
    required this.incrementalDill,
  });

  CompilerSession session;
  List<String> roots;
  String fullDill;
  String incrementalDill;

  /// The content hashes of the last accepted request (null marks missing).
  Map<String, String?> contentHashes = {};

  /// The cumulative read set: every `+uri` the server reported, minus every
  /// `-uri`, across requests — including the reads of rejected compiles.
  Set<String> currentReads = {};

  GuardCache guard = GuardCache();
}

/// Creates the server session for one configuration key. Tests substitute a
/// fake; production starts a real `frontend_server`.
typedef SessionFactory = Future<CompilerSession> Function(
  List<String> fs,
  String fullDill,
  String incrementalDill,
  String cwd,
);

Future<CompilerSession> _startRealSession(
  List<String> fs,
  String fullDill,
  String incrementalDill,
  String cwd,
) => FrontendServerSession.start(fs, fullDill, incrementalDill, cwd: cwd);

/// The `--filesystem-root` values in the compiler command [fs].
List<String> compilerFilesystemRoots(List<String> fs) {
  final roots = <String>[];
  final flags = fs.sublist(0, fs.length - 1);
  for (var k = 0; k < flags.length - 1; k++) {
    if (flags[k] == '--filesystem-root') roots.add(flags[k + 1]);
  }
  return roots;
}

/// The incremental worker: one [IncrServerState] per configuration key with
/// an LRU cap on live servers (a warm server holds about 1.75 GiB).
class IncrWorker {
  IncrWorker({String? cwd, int? maxServers, SessionFactory? sessions})
    : cwd = cwd ?? Directory.current.path,
      maxServers = maxServers ?? _maxServersFromEnv(),
      _sessions = sessions ?? _startRealSession,
      _tmp = Directory.systemTemp.createTempSync('incr_fkc_');

  final String cwd;
  final int maxServers;
  final SessionFactory _sessions;
  final Directory _tmp;
  final Map<String, IncrServerState> _servers = {};
  final List<String> _order = [];

  static int _maxServersFromEnv() {
    final raw = Platform.environment['INCR_FKC_MAX_SERVERS'];
    final parsed = raw == null ? 0 : int.tryParse(raw) ?? 0;
    return parsed > 0 ? parsed : 1;
  }

  /// Stops every server. Used when the worker itself is done, and after an
  /// unexpected error the server state cannot be trusted.
  Future<void> closeAll() async {
    for (final state in _servers.values) {
      await state.session.close();
    }
    _servers.clear();
    _order.clear();
  }

  void _touch(String key) {
    _order.remove(key);
    _order.add(key);
  }

  Future<void> _drop(String key) async {
    final state = _servers.remove(key);
    _order.remove(key);
    if (state != null) await state.session.close();
  }

  Future<IncrServerState> _startFresh(
    String key,
    List<String> fs,
    List<String> roots,
  ) async {
    final old = _servers.remove(key);
    _order.remove(key);
    if (old != null) await old.session.close();
    while (_order.isNotEmpty && _servers.length >= maxServers) {
      await _drop(_order.first);
    }
    final wdir = Directory(
      '${_tmp.path}${Platform.pathSeparator}$key',
    )..createSync(recursive: true);
    final sep = Platform.pathSeparator;
    final full = '${wdir.path}${sep}full.dill';
    final inc = '${wdir.path}${sep}inc.dill';
    final session = await _sessions(fs, full, inc, cwd);
    final state = IncrServerState(
      session: session,
      roots: roots,
      fullDill: full,
      incrementalDill: inc,
    );
    _servers[key] = state;
    _touch(key);
    return state;
  }

  String _abs(String rel) {
    if (rel.startsWith('/') || RegExp(r'^[a-zA-Z]:').hasMatch(rel)) return rel;
    return '$cwd/$rel';
  }

  String? _contentHash(String rel) {
    try {
      return sha256Hex(File(_abs(rel)).readAsBytesSync());
    } on FileSystemException {
      return null;
    }
  }

  /// The refusal text for the cumulative read set, or null when clean. Uses
  /// the same messages as the batch path.
  String? _checkReads(
    Set<String> current,
    Set<String> declared,
    Set<String> extraAllowed,
  ) {
    final lines = [for (final u in current.toList()..sort()) '+$u'];
    final bad = findUndeclaredReads(lines, declared, extraAllowed);
    if (bad.isEmpty) return null;
    return bad.map(undeclaredReadMessage).join('\n');
  }

  void _deleteOutput(String? outputDill) {
    if (outputDill == null) return;
    try {
      File(_abs(outputDill)).deleteSync();
    } on FileSystemException {
      // Already gone; the nonzero exit fails the action either way.
    }
  }

  /// Serves one request: [argv] is the action argv after argv[0]
  /// (`--declared-inputs <manifest> -- <executable> <arguments>`, flagfiles
  /// already expanded), [inputPaths] the exec-root-relative action inputs.
  Future<IncrResult> handleRequest(
    List<String> argv,
    List<String> inputPaths,
  ) async {
    final String manifestPath;
    final List<String> fs;
    try {
      final split = splitWorkerArgv(argv);
      manifestPath = split.manifestPath;
      fs = split.command;
      if (fs.isEmpty) throw const FormatException('no compiler command.');
    } on FormatException catch (e) {
      return (exitCode: 2, output: e.message);
    }
    if (!File(_abs(manifestPath)).existsSync()) {
      return (
        exitCode: 2,
        output:
            'incr_fkc_worker: declared-inputs manifest $manifestPath does not exist.',
      );
    }
    final manifest = readKernelInputsManifest(_abs(manifestPath));
    final outputRel = manifest.outputDill;
    if (outputRel == null) {
      return (
        exitCode: 2,
        output: 'incr_fkc_worker: manifest $manifestPath names no # output.',
      );
    }
    final entry = fs.last;
    final key = configurationKey(fs, sha256Hex);
    var state = _servers[key];
    if (state != null) _touch(key);

    final current = <String, String?>{};
    for (final p in {...inputPaths, ...?state?.contentHashes.keys}) {
      current[p] = _contentHash(p);
    }
    final stored = state?.contentHashes ?? {};
    final changed = [
      for (final p in current.keys)
        if (current[p] != stored[p]) p,
    ]..sort();

    final bool cold;
    var uris = <String>[];
    if (state == null || !state.session.alive) {
      cold = true;
    } else {
      final classified = classifyChanged(
        changed,
        state.roots,
        manifest.sources.toSet(),
      );
      if (classified.restartReason != null) {
        cold = true;
      } else {
        cold = false;
        uris = classified.uris;
      }
    }

    // The directive guard runs before the compiler, on every request: any
    // changed `.dart` file invalidates its content-digest cache.
    final roots = cold ? compilerFilesystemRoots(fs) : state!.roots;
    final dartSources = [
      for (final p in manifest.sources)
        if (p.endsWith('.dart')) p,
    ];
    final guard = cold ? GuardCache() : state!.guard;
    final guardErrors = guard.check(dartSources, roots, current);
    if (guardErrors.isNotEmpty) {
      return (exitCode: 1, output: guardErrors.join('\n'));
    }

    try {
      if (cold) {
        state = await _startFresh(key, fs, roots);
        state.guard = guard;
      } else {
        state = state!;
      }
      if (cold) {
        final r = await state.session.compile(entry);
        foldDepLines(state.currentReads, r.depLines);
        if (r.errors != 0) {
          await _drop(key);
          return (exitCode: 1, output: r.diagnostics.join('\n'));
        }
        await state.session.accept();
      } else {
        final r = await state.session.recompile(
          entry,
          uris.toSet().toList()..sort(),
        );
        foldDepLines(state.currentReads, r.depLines);
        if (r.errors != 0) {
          // Rejected: the server returns to the last accepted state, and the
          // hashes stay at the last good request, so the next request
          // re-invalidates the same files. The failed compile's reads stay
          // in the cumulative set for the next check.
          await state.session.reject();
          final refusal = _checkReads(
            state.currentReads,
            manifest.declared,
            manifest.extraAllowed,
          );
          if (refusal != null) {
            await _drop(key);
            _deleteOutput(manifest.outputDill);
            return (exitCode: 1, output: refusal);
          }
          return (exitCode: 1, output: r.diagnostics.join('\n'));
        }
        await state.session.accept();
      }
      // The second phase: `reset` plus an empty `recompile` writes the full
      // dill from a compile that compiled nothing (rule F).
      final fin = await state.session.recompile(entry, [], resetFirst: true);
      foldDepLines(state.currentReads, fin.depLines);
      if (fin.errors != 0) {
        // Nothing was invalidated: an error here means the server is not
        // trusted.
        await _drop(key);
        return (exitCode: 1, output: fin.diagnostics.join('\n'));
      }
      await state.session.accept();
      final refusal = _checkReads(
        state.currentReads,
        manifest.declared,
        manifest.extraAllowed,
      );
      if (refusal != null) {
        await _drop(key);
        _deleteOutput(manifest.outputDill);
        return (exitCode: 1, output: refusal);
      }
      if (state.currentReads.isEmpty) {
        // A real compile reads at least its entrypoint: zero reads means the
        // dependency report was silenced, so the build fails instead of
        // caching unverified bytes.
        await _drop(key);
        _deleteOutput(manifest.outputDill);
        return (exitCode: 1, output: noDependencyReadsMessage());
      }
      state.contentHashes = current;
      final dst = _abs(outputRel);
      await Directory(File(dst).parent.path).create(recursive: true);
      try {
        File(dst).deleteSync();
      } on FileSystemException {
        // Absent; the copy below creates it.
      }
      await File(state.fullDill).copy(dst);
      return (exitCode: 0, output: '');
    } catch (_) {
      // The server is not trusted after an unexpected error: drop it so the
      // next request starts cold.
      await _drop(key);
      rethrow;
    }
  }
}

/// Runs one fresh-process request: the same protocol a warm worker runs, so
/// the bytes are identical. This is what sandboxed, local and remote
/// strategies run.
Future<int> runOneShotWorker(List<String> argv) async {
  final worker = IncrWorker();
  try {
    final result = await worker.handleRequest(argv, const []);
    if (result.output.isNotEmpty) stderr.writeln(result.output);
    return result.exitCode;
  } on FormatException catch (e) {
    stderr.writeln(e.message);
    return 2;
  } catch (e) {
    stderr.writeln('incr_fkc_worker: worker error: $e');
    return 1;
  } finally {
    await worker.closeAll();
  }
}

/// Serves Bazel JSON persistent-worker requests on stdin/stdout.
Future<void> runPersistentWorker() async {
  final worker = IncrWorker();
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  await for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final req = jsonDecode(line) as Map<String, dynamic>;
    final rid = req['requestId'] ?? 0;
    final rawArgs = [
      for (final a in (req['arguments'] as List<dynamic>? ?? [])) a as String,
    ];
    final inputs = [
      for (final i in (req['inputs'] as List<dynamic>? ?? []))
        (i as Map<String, dynamic>)['path'] as String,
    ];
    int code;
    String out;
    try {
      // Request digests are only a hint: change detection reads file
      // contents, so a stale digest never hides a change.
      final result = await worker.handleRequest(
        expandWorkerFlagfiles(rawArgs),
        inputs,
      );
      code = result.exitCode;
      out = result.output;
    } catch (e) {
      // The servers are not trusted after an error: drop them all.
      await worker.closeAll();
      code = 1;
      out = 'incr_fkc_worker: worker error: $e';
    }
    stdout.writeln(
      jsonEncode({'exitCode': code, 'output': out, 'requestId': rid}),
    );
    await stdout.flush();
  }
}

Future<void> main(List<String> argv) async {
  if (argv.contains('--persistent_worker')) {
    await runPersistentWorker();
  } else {
    exit(await runOneShotWorker(expandWorkerFlagfiles(argv)));
  }
}
