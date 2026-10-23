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

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'directive_guard.dart';
import 'incr_fkc_server.dart';
import 'kernel_filter.dart';
import 'sha256.dart';

/// The outcome of one worker request.
typedef IncrResult = ({int exitCode, String output});

/// One request's validated compiler command, private output, entrypoint and
/// declared-inputs manifest.
typedef RequestParts = ({
  List<String> fs,
  String outputRel,
  String entry,
  KernelInputsManifest manifest,
});

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

/// Installs SIGTERM/SIGINT cleanup for [worker]: the signal closes the worker
/// (stopping its servers and deleting its temp directory) before the process
/// exits with the signal's conventional status.
///
/// One-shot actions and persistent workers die on signals without running
/// `finally`, so without this every signalled build leaks an `incr_fkc_*`
/// directory under the temp directory.
///
/// [onSignal] overrides the process exit for tests, which deliver the process
/// its own signal: the default [exit] would end the test runner, so tests
/// record the status instead and let the test end normally.
///
/// [signals] overrides the watched signals for tests: the suite delivers the
/// process its own signal, and SIGTERM/SIGINT are spoken for by the test
/// runner, so tests watch SIGUSR1 through the same subscription, cleanup
/// and status path. Production always passes nothing, watching SIGTERM
/// (status 143) and SIGINT (status 130).
List<StreamSubscription<ProcessSignal>> watchWorkerSignals(
  IncrWorker worker, {
  void Function(int status)? onSignal,
  List<({ProcessSignal signal, int status})>? signals,
}) {
  final subs = <StreamSubscription<ProcessSignal>>[];
  // The conventional 128-plus-signum statuses: SIGTERM is 15, SIGINT is 2.
  // (`ProcessSignal` exposes no number getter on every SDK this builds with,
  // so the statuses travel with the watched signals.)
  final watchedSignals =
      signals ??
      [
        (signal: ProcessSignal.sigterm, status: 143),
        (signal: ProcessSignal.sigint, status: 130),
      ];
  for (final watched in watchedSignals) {
    try {
      subs.add(
        watched.signal.watch().listen((_) async {
          await worker.closeAll();
          (onSignal ?? exit)(watched.status);
        }),
      );
    } on UnsupportedError {
      // The platform delivers no such signal; the `finally` paths still clean
      // up on normal exits, failures and stdin EOF.
    }
  }
  return subs;
}

/// Cancels the subscriptions installed by [watchWorkerSignals].
Future<void> cancelWorkerSignals(
  List<StreamSubscription<ProcessSignal>> subs,
) async {
  for (final sub in subs) {
    await sub.cancel();
  }
}

/// The incremental worker: one [IncrServerState] per configuration key with
/// an LRU cap on live servers (a warm server holds about 1.75 GiB).
class IncrWorker {
  IncrWorker({
    String? cwd,
    int? maxServers,
    SessionFactory? sessions,
    String? tempParent,
  }) : cwd = cwd ?? Directory.current.path,
       maxServers = maxServers ?? _maxServersFromEnv(),
       _sessions = sessions ?? _startRealSession,
       _tmp =
           (tempParent == null ? Directory.systemTemp : Directory(tempParent))
               .createTempSync('incr_fkc_');

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

  /// Stops every server and deletes the worker's temp directory. Used when
  /// the worker itself is done, and after an unexpected error the server
  /// state cannot be trusted. Runs on every exit path — one-shot success and
  /// failure, persistent-worker stdin EOF, exceptions, and signals — so no
  /// `incr_fkc_*` directory survives the worker.
  Future<void> closeAll() async {
    try {
      for (final state in _servers.values) {
        await state.session.close();
      }
    } finally {
      _servers.clear();
      _order.clear();
      _deleteTempDir();
    }
  }

  /// Best-effort deletion of [_tmp]: the exit code already reports the
  /// compile result, so a failed delete must not fail the build.
  void _deleteTempDir() {
    try {
      if (_tmp.existsSync()) _tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Lost a race with an outer cleanup; nothing left to report.
    }
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
  /// the same messages as the batch path, decided by the manifest alone: a
  /// read under a `--filesystem-root` the argv names but the manifest does
  /// not is refused, exactly like batch.
  String? _checkReads(Set<String> current, KernelInputsManifest manifest) {
    final lines = [for (final u in current.toList()..sort()) '+$u'];
    final bad = findUndeclaredReads(
      lines,
      manifest.declared,
      manifest.extraAllowed,
    );
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
    final RequestParts parts;
    try {
      parts = _parseRequest(argv);
    } on FormatException catch (e) {
      return (exitCode: 2, output: e.message);
    }
    final key = configurationKey(parts.fs, sha256Hex);
    var state = _servers[key];
    if (state != null) _touch(key);
    final hashes = _changeSet(inputPaths, state);
    final plan = _planCompile(
      state,
      hashes.changed,
      parts.manifest.sources.toSet(),
    );
    // The guard and the read check take their allowances only from the
    // manifest: argv `--filesystem-root` values never widen what either
    // accepts, so a smuggled root buys no read.
    final roots = parts.manifest.fsRoots;
    final guard = plan.cold ? GuardCache() : state!.guard;
    final guardError = _checkGuard(
      parts.manifest,
      roots,
      guard,
      hashes.current,
    );
    if (guardError != null) {
      return (exitCode: 1, output: guardError);
    }
    try {
      if (plan.cold) {
        final cold = await _runCold(key, parts, roots, guard);
        state = cold.state;
        if (cold.failure != null) return cold.failure!;
      } else {
        final failure = await _runWarm(
          state!,
          key,
          parts,
          plan.uris,
        );
        if (failure != null) return failure;
      }
      final resetFailure = await _runResetPhase(state, key, parts.entry);
      if (resetFailure != null) return resetFailure;
      return await _publishOutput(state, key, parts, hashes.current);
    } catch (_) {
      // The server is not trusted after an unexpected error: drop it so the
      // next request starts cold.
      await _drop(key);
      rethrow;
    }
  }

  /// Validates one request's argv and manifest. Throws [FormatException] with
  /// the action-failing message when malformed.
  RequestParts _parseRequest(List<String> argv) {
    final split = splitWorkerArgv(argv);
    final fs = split.command;
    if (fs.isEmpty) throw const FormatException('no compiler command.');
    if (!File(_abs(split.manifestPath)).existsSync()) {
      throw FormatException(
        'incr_fkc_worker: declared-inputs manifest ${split.manifestPath} does not exist.',
      );
    }
    final manifest = readKernelInputsManifest(_abs(split.manifestPath));
    if (manifest.outputDill == null) {
      throw FormatException(
        'incr_fkc_worker: manifest ${split.manifestPath} names no # output.',
      );
    }
    // The finished dill lands where THIS request's `--output-dill` points,
    // not the manifest's `# output`: harnesses and Bazel strategies give each
    // request a private output path while the manifest names the action's.
    // The configuration key already excludes the output, so requests that
    // differ only here share a warm server.
    final outI = fs.indexOf('--output-dill');
    if (outI < 0 || outI + 1 >= fs.length) {
      throw const FormatException(
        'incr_fkc_worker: compiler argv has no --output-dill.',
      );
    }
    return (
      fs: fs,
      outputRel: fs[outI + 1],
      entry: fs.last,
      manifest: manifest,
    );
  }

  /// Hashes every input's contents and diffs them against the last accepted
  /// request's hashes. Contents — never request digests — decide.
  ({Map<String, String?> current, List<String> changed}) _changeSet(
    List<String> inputPaths,
    IncrServerState? state,
  ) {
    final stored = state?.contentHashes ?? {};
    final current = <String, String?>{};
    for (final p in {...inputPaths, ...stored.keys}) {
      current[p] = _contentHash(p);
    }
    final changed = [
      for (final p in current.keys)
        if (current[p] != stored[p]) p,
    ]..sort();
    return (current: current, changed: changed);
  }

  /// Decides cold start versus warm URIs for [changed] files.
  ({bool cold, List<String> uris}) _planCompile(
    IncrServerState? state,
    List<String> changed,
    Set<String> sources,
  ) {
    if (state == null || !state.session.alive) {
      return (cold: true, uris: const []);
    }
    final classified = classifyChanged(changed, state.roots, sources);
    if (classified.restartReason != null) {
      return (cold: true, uris: const []);
    }
    return (cold: false, uris: classified.uris);
  }

  /// Runs the directive guard before the compiler on every request: any
  /// changed `.dart` file invalidates its content-digest cache. Returns the
  /// refusal text, or null when the sources are clean.
  String? _checkGuard(
    KernelInputsManifest manifest,
    List<String> roots,
    GuardCache guard,
    Map<String, String?> current,
  ) {
    final dartSources = [
      for (final p in manifest.sources)
        if (p.endsWith('.dart')) p,
    ];
    final errors = guard.check(dartSources, roots, current);
    if (errors.isEmpty) return null;
    return errors.join('\n');
  }

  /// Starts a fresh server and runs its first compile plus `accept`.
  Future<({IncrServerState state, IncrResult? failure})> _runCold(
    String key,
    RequestParts parts,
    List<String> roots,
    GuardCache guard,
  ) async {
    final state = await _startFresh(key, parts.fs, roots);
    state.guard = guard;
    final r = await state.session.compile(parts.entry);
    foldDepLines(state.currentReads, r.depLines);
    if (r.errors != 0) {
      await _drop(key);
      return (
        state: state,
        failure: (exitCode: 1, output: r.diagnostics.join('\n')),
      );
    }
    await state.session.accept();
    return (state: state, failure: null);
  }

  /// Recompiles the changed URIs on a warm server. A rejection returns the
  /// server to the last accepted state: the hashes stay at the last good
  /// request, so the next request re-invalidates the same files, while the
  /// failed compile's reads stay in the cumulative set for the next check.
  Future<IncrResult?> _runWarm(
    IncrServerState state,
    String key,
    RequestParts parts,
    List<String> uris,
  ) async {
    final r = await state.session.recompile(
      parts.entry,
      uris.toSet().toList()..sort(),
    );
    foldDepLines(state.currentReads, r.depLines);
    if (r.errors != 0) {
      await state.session.reject();
      final refusal = _checkReads(state.currentReads, parts.manifest);
      if (refusal != null) {
        await _drop(key);
        _deleteOutput(parts.outputRel);
        return (exitCode: 1, output: refusal);
      }
      return (exitCode: 1, output: r.diagnostics.join('\n'));
    }
    await state.session.accept();
    return null;
  }

  /// The second phase: `reset` plus an empty `recompile` writes the full dill
  /// from a compile that compiled nothing (rule F). An error here means the
  /// server is not trusted.
  Future<IncrResult?> _runResetPhase(
    IncrServerState state,
    String key,
    String entry,
  ) async {
    final fin = await state.session.recompile(entry, [], resetFirst: true);
    foldDepLines(state.currentReads, fin.depLines);
    if (fin.errors != 0) {
      await _drop(key);
      return (exitCode: 1, output: fin.diagnostics.join('\n'));
    }
    return null;
  }

  /// Accepts the reset phase, verifies the cumulative read set, and copies
  /// the full dill to the request's output.
  Future<IncrResult> _publishOutput(
    IncrServerState state,
    String key,
    RequestParts parts,
    Map<String, String?> current,
  ) async {
    await state.session.accept();
    final refusal = _checkReads(state.currentReads, parts.manifest);
    if (refusal != null) {
      await _drop(key);
      _deleteOutput(parts.outputRel);
      return (exitCode: 1, output: refusal);
    }
    if (state.currentReads.isEmpty) {
      // A real compile reads at least its entrypoint: zero reads means the
      // dependency report was silenced, so the build fails instead of
      // caching unverified bytes.
      await _drop(key);
      _deleteOutput(parts.outputRel);
      return (exitCode: 1, output: noDependencyReadsMessage());
    }
    state.contentHashes = current;
    final dst = _abs(parts.outputRel);
    await Directory(File(dst).parent.path).create(recursive: true);
    try {
      File(dst).deleteSync();
    } on FileSystemException {
      // Absent; the copy below creates it.
    }
    await File(state.fullDill).copy(dst);
    return (exitCode: 0, output: '');
  }
}

/// Runs one fresh-process request: the same protocol a warm worker runs, so
/// the bytes are identical. This is what sandboxed, local and remote
/// strategies run. The worker's temp directory is deleted on every exit path
/// — success, failure and exception alike — via [IncrWorker.closeAll].
Future<int> runOneShotWorker(
  List<String> argv, {
  IncrWorker Function()? createWorker,
}) async {
  final worker = (createWorker ?? IncrWorker.new)();
  final signals = watchWorkerSignals(worker);
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
    await cancelWorkerSignals(signals);
    await worker.closeAll();
  }
}

/// Serves Bazel JSON persistent-worker requests on stdin/stdout. Returns when
/// stdin closes, after closing every server and deleting the worker's temp
/// directory, so no `incr_fkc_*` directory survives the worker.
Future<void> runPersistentWorker({
  IncrWorker Function()? createWorker,
  Stream<List<int>>? stdinBytes,
  StringSink? responseSink,
}) async {
  final worker = (createWorker ?? IncrWorker.new)();
  final signals = watchWorkerSignals(worker);
  try {
    final out = responseSink ?? stdout;
    final lines = (stdinBytes ?? stdin)
        .transform(utf8.decoder)
        .transform(const LineSplitter());
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
      String response;
      try {
        // Request digests are only a hint: change detection reads file
        // contents, so a stale digest never hides a change.
        final result = await worker.handleRequest(
          expandWorkerFlagfiles(stripWorkerArgv0(rawArgs)),
          inputs,
        );
        code = result.exitCode;
        response = result.output;
      } catch (e) {
        // The servers are not trusted after an error: drop them all. The
        // message goes to stderr so the JSON protocol on stdout stays clean.
        await worker.closeAll();
        code = 1;
        response = 'incr_fkc_worker: worker error: $e';
        stderr.writeln(response);
      }
      out.writeln(
        jsonEncode({'exitCode': code, 'output': response, 'requestId': rid}),
      );
      await stdout.flush();
    }
  } finally {
    await cancelWorkerSignals(signals);
    await worker.closeAll();
  }
}

Future<void> main(List<String> argv) async {
  if (argv.contains('--persistent_worker')) {
    await runPersistentWorker();
  } else {
    exit(await runOneShotWorker(expandWorkerFlagfiles(stripWorkerArgv0(argv))));
  }
}
