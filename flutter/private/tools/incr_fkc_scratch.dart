/// Crash-safe scratch-directory ownership for the incremental worker.
///
/// A worker that is killed outright (Bazel destroying it, a server shutdown,
/// the OOM killer) never runs its graceful-exit cleanup, so its scratch
/// directory — full and incremental dills of tens of megabytes — would stay
/// in the host temp directory for good. Reclaiming that scratch must not
/// depend on the worker exiting gracefully: every worker, when it starts,
/// sweeps the temp directory for scratch left by workers that are no longer
/// alive.
///
/// Liveness is decided by something a dead process cannot keep holding: each
/// live worker holds a loopback server socket open for its whole life and
/// publishes its port plus a random token in `alive.json` inside its own
/// scratch directory. The startup sweep connects to that port: a refused
/// connection (or a wrong token, from an unrelated process that reused the
/// port) means the owner is gone and the directory is deleted; any answer
/// with the right token — or any ambiguity — means the directory is kept.
/// Liveness never depends on age or on PIDs, so PID reuse cannot confuse it.
///
/// The sweep only touches directories the worker's own naming scheme
/// produces (`incr_fkc_*`), never the worker's own directory, and never
/// fails the start or the compile: anything it cannot remove is skipped with
/// a note on stderr.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// The temp-directory entry prefix the worker's scratch uses.
const incrFkcScratchPrefix = 'incr_fkc_';

/// The liveness file inside one worker's scratch directory.
const incrFkcAliveFileName = 'alive.json';

/// How long the sweep waits for one sibling's heartbeat before treating the
/// sibling as ambiguous (and therefore live).
const incrFkcHeartbeatTimeout = Duration(seconds: 1);

/// The token shape the sweep accepts: 16 random bytes as 32 hex digits.
final RegExp _tokenPattern = RegExp(r'^[0-9a-f]{32}$');

/// One worker's held heartbeat: the loopback server that proves it is alive.
class ScratchHeartbeat {
  ScratchHeartbeat._(this._server, this.token);

  final ServerSocket? _server;

  /// The random token the heartbeat answers sweeps with.
  final String token;

  /// Releases the heartbeat. Never throws.
  Future<void> close() async {
    final server = _server;
    if (server == null) return;
    try {
      await server.close();
    } on SocketException {
      // Shutting down; nothing left to report.
    }
  }
}

/// Starts the heartbeat for the scratch directory [dir]: binds the loopback
/// server, answers sweep handshakes with a fresh token, and publishes the
/// liveness file. Never throws: when the socket or the file cannot be set
/// up, the returned heartbeat carries no liveness (future sweeps keep the
/// directory as possibly-live) and the worker still starts.
Future<ScratchHeartbeat> startScratchHeartbeat(Directory dir) async {
  final ServerSocket server;
  try {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  } on SocketException catch (e) {
    stderr.writeln('incr_fkc_worker: no heartbeat socket ($e).');
    return ScratchHeartbeat._(null, '');
  }
  final token = _newToken();
  server.listen(
    (Socket client) {
      _answerHeartbeat(client, token);
    },
    onError: (_) {},
  );
  try {
    _writeAliveFile(dir, server.port, token);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: no heartbeat file ($e).');
    await ScratchHeartbeat._(server, token).close();
    return ScratchHeartbeat._(null, '');
  }
  return ScratchHeartbeat._(server, token);
}

/// Writes the liveness file atomically: a temporary file plus a rename, so
/// a concurrent sweep never reads a half-written claim.
void _writeAliveFile(Directory dir, int port, String token) {
  final sep = Platform.pathSeparator;
  final staging = File('${dir.path}${sep}.alive.json.tmp');
  staging.writeAsStringSync(jsonEncode({'port': port, 'token': token}));
  staging.renameSync('${dir.path}${sep}$incrFkcAliveFileName');
}

/// Sixteen random bytes as 32 hex digits.
String _newToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

/// Answers one sweep handshake: the token line, flushed before the close so
/// the sweeper always reads it. Never throws.
Future<void> _answerHeartbeat(Socket client, String token) async {
  try {
    client.write('$token\n');
    await client.flush();
    await client.close();
  } on SocketException {
    // The sweeper went away mid-handshake; nothing to do.
  } on StateError {
    // The socket closed under us; nothing to do.
  }
}

/// Deletes every dead worker's scratch directory under [parent], except the
/// entry named [exemptName] (this worker's own). Only directories the
/// worker's own naming scheme produces are candidates, and anything the
/// sweep cannot remove is kept. Never throws.
Future<void> sweepWorkerScratch(
  Directory parent, {
  required String exemptName,
}) async {
  final List<FileSystemEntity> entries;
  try {
    entries = parent.listSync(followLinks: false);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: scratch sweep skipped ($e).');
    return;
  }
  for (final entry in entries) {
    if (_entryName(entry) == exemptName) continue;
    await _reclaimEntry(entry);
  }
}

/// The final path segment of [entry].
String _entryName(FileSystemEntity entry) =>
    entry.path.split(Platform.pathSeparator).last;

/// Deletes [entry] when it is a dead worker's scratch. Keeps everything
/// else: non-directories, foreign names, live workers, ambiguous claims and
/// entries that resist removal. Notes kept entries on stderr.
Future<void> _reclaimEntry(FileSystemEntity entry) async {
  if (entry is! Directory) return;
  if (!_entryName(entry).startsWith(incrFkcScratchPrefix)) return;
  final bool dead;
  try {
    dead = await _isDeadScratch(entry);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: keeping ${entry.path} ($e).');
    return;
  } on SocketException catch (e) {
    stderr.writeln('incr_fkc_worker: keeping ${entry.path} ($e).');
    return;
  } on FormatException catch (e) {
    stderr.writeln('incr_fkc_worker: keeping ${entry.path} ($e).');
    return;
  } on TimeoutException catch (e) {
    stderr.writeln('incr_fkc_worker: keeping ${entry.path} ($e).');
    return;
  }
  if (!dead) return;
  try {
    entry.deleteSync(recursive: true);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: keeping ${entry.path} ($e).');
  }
}

/// Whether [dir] is a worker's scratch whose owner is gone: it carries a
/// well-formed liveness claim and nothing answers for it. A missing or
/// malformed claim means a newborn sibling (or a foreign entry), which is
/// treated as live.
Future<bool> _isDeadScratch(Directory dir) async {
  final claim = _readAliveClaim(dir);
  if (claim == null) return false;
  return _heartbeatGone(claim);
}

/// The parsed liveness claim, or null when [dir] carries none usable: no
/// file yet, an unreadable file, or anything but a loopback port plus a
/// token in the worker's shape.
({int port, String token})? _readAliveClaim(Directory dir) {
  final file = File(
    '${dir.path}${Platform.pathSeparator}$incrFkcAliveFileName',
  );
  final String text;
  try {
    text = file.readAsStringSync();
  } on FileSystemException {
    return null;
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final port = decoded['port'];
  final token = decoded['token'];
  if (port is! int || port <= 0 || port > 65535) return null;
  if (token is! String || !_tokenPattern.hasMatch(token)) return null;
  return (port: port, token: token);
}

/// Whether nothing live answers for [claim]: a refused connection means the
/// owner is gone, as does an answer with the wrong token (an unrelated
/// process reusing the port). Anything ambiguous — a timeout, a close
/// without an answer — counts as live, so the sweep never deletes scratch
/// it is unsure about.
Future<bool> _heartbeatGone(({int port, String token}) claim) async {
  final Socket socket;
  try {
    socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      claim.port,
      timeout: incrFkcHeartbeatTimeout,
    );
  } on SocketException {
    return true;
  } on TimeoutException {
    return false;
  }
  try {
    final line = await _socketLines(
      socket,
    ).first.timeout(incrFkcHeartbeatTimeout);
    return line != claim.token;
  } on TimeoutException {
    return false;
  } on StateError {
    return false;
  } finally {
    socket.destroy();
  }
}

/// The socket's bytes as text lines. The cast bridges `Socket`'s
/// `Uint8List` chunks to the decoder's `List<int>` input.
Stream<String> _socketLines(Socket socket) => socket
    .cast<List<int>>()
    .transform(utf8.decoder)
    .transform(const LineSplitter());
