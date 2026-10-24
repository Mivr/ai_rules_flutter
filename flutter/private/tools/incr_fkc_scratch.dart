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
/// Liveness is decided by something a dead process cannot keep holding: an
/// advisory exclusive file lock. Each worker creates a lock file inside its
/// own scratch, takes `lockSync(FileLock.exclusive)` on it, and keeps that
/// one handle open for its whole life; the kernel drops the lock when the
/// process dies, SIGKILL included, in every network and mount namespace. The
/// sweep probes each sibling's lock file with the same lock call from a
/// short-lived helper process (the SDK exposes no non-blocking attempt, and
/// a helper in another process has clean cross-process lock semantics):
/// acquiring the lock proves the owner is gone and the directory is deleted,
/// while a held lock, a missing or unopenable lock file, or any other
/// failure keeps the directory. Liveness never depends on age or on PIDs,
/// so PID reuse cannot confuse it.
///
/// The sweep only touches directories the worker's own naming scheme
/// produces (`incr_fkc_*`), never the worker's own directory, and never
/// fails the start or the compile: anything it cannot remove is skipped with
/// a note on stderr.
library;

import 'dart:async';
import 'dart:io';

/// The temp-directory entry prefix the worker's scratch uses.
const incrFkcScratchPrefix = 'incr_fkc_';

/// The lock file inside one worker's scratch directory.
const incrFkcLockFileName = 'lock';

/// The worker's lock-probe mode flag: `--incr-fkc-try-lock=<lock path>`.
/// A sweep runs the worker binary itself with this flag to probe one
/// sibling's lock file in a separate process.
const incrFkcTryLockFlag = '--incr-fkc-try-lock=';

/// Upper bound for one sibling's lock probe. A probe answers in
/// milliseconds either way — the lock attempt below never blocks — so a
/// probe that outlasts this is wedged: it is killed and the entry kept.
const incrFkcTryLockTimeout = Duration(seconds: 5);

/// How long a stray lock probe may live. The parent sweep kills a probe
/// that outlasts [incrFkcTryLockTimeout]; this timer only fires when the
/// parent itself vanished, so a stranded probe still exits on its own.
const incrFkcProbeLifetime = Duration(seconds: 30);

/// One worker's held scratch lock: the open handle whose exclusive lock
/// proves this worker is alive. The handle stays open for the worker's whole
/// life and is never duplicated: POSIX locks are per process and are dropped
/// when the process closes any descriptor for the file, so this file is
/// opened exactly once and never read back through another handle.
class ScratchLock {
  ScratchLock._(this._handle);

  final RandomAccessFile? _handle;

  /// Releases the lock. Never throws.
  Future<void> close() async {
    final handle = _handle;
    if (handle == null) return;
    try {
      await handle.close();
    } on FileSystemException {
      // Shutting down; nothing left to report.
    }
  }
}

/// The lock file path inside scratch directory [dir].
String scratchLockPath(Directory dir) =>
    '${dir.path}${Platform.pathSeparator}$incrFkcLockFileName';

/// Claims the lock for scratch directory [dir]: creates the lock file,
/// takes the exclusive lock, and holds the handle. Runs before the worker
/// writes anything costly, so a claimed directory never holds valuable
/// state another worker could sweep. Never throws: when the lock cannot be
/// set up, the returned lock holds nothing (future sweeps keep the
/// directory as possibly-live) and the worker still starts.
Future<ScratchLock> lockWorkerScratch(Directory dir) async {
  try {
    final handle = File(scratchLockPath(dir)).openSync(mode: FileMode.write);
    handle.lockSync(FileLock.exclusive);
    return ScratchLock._(handle);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: no scratch lock ($e).');
    return ScratchLock._(null);
  }
}

/// Extracts the lock-probe path from the worker argv, or null when this is
/// not a lock probe.
String? tryLockPath(List<String> argv) {
  for (final arg in argv) {
    if (arg.startsWith(incrFkcTryLockFlag)) {
      return arg.substring(incrFkcTryLockFlag.length);
    }
  }
  return null;
}

/// Probes one lock file the way a sweep's helper does: attempts the
/// exclusive lock and releases it again. The attempt never blocks: when a
/// live owner holds the lock it fails at once (EAGAIN) and the probe exits
/// 1. Returns 0 when the lock was acquired (the owner is dead), 1 when the
/// file cannot be opened or the lock is held. The parent sweep kills a
/// probe that outlasts [incrFkcTryLockTimeout], and the lifetime timer
/// below ends a probe whose parent vanished.
Future<int> tryScratchLock(String lockPath) async {
  Timer(incrFkcProbeLifetime, () => exit(2));
  try {
    final handle = File(lockPath).openSync(mode: FileMode.write);
    handle.lockSync(FileLock.exclusive);
    await handle.close();
  } on FileSystemException {
    return 1;
  }
  return 0;
}

/// Spawns one lock probe for [lockPath]. A test seam: production passes
/// nothing and probes by running the worker binary itself (always
/// available); tests pass a spawner for their own Dart VM.
typedef ProbeSpawner = Future<Process> Function(String lockPath);

/// Probes by running this worker binary in lock-probe mode.
Future<Process> _selfProbe(String lockPath) => Process.start(
  Platform.resolvedExecutable,
  ['$incrFkcTryLockFlag$lockPath'],
);

/// Deletes every dead worker's scratch directory under [parent], except the
/// entry named [exemptName] (this worker's own). Only directories the
/// worker's own naming scheme produces are candidates. A sibling without a
/// lock file is always kept: it is either a newborn whose owner has not
/// claimed yet (the claim lands after the directory becomes visible) or a
/// foreign entry, and neither may be deleted. Anything the sweep cannot
/// remove is kept. Never throws.
Future<void> sweepWorkerScratch(
  Directory parent, {
  required String exemptName,
  ProbeSpawner? spawnProbe,
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
    await _reclaimEntry(entry, spawnProbe ?? _selfProbe);
  }
}

/// The final path segment of [entry].
String _entryName(FileSystemEntity entry) =>
    entry.path.split(Platform.pathSeparator).last;

/// Deletes [entry] when it is a dead worker's scratch. Keeps everything
/// else and notes kept entries on stderr.
Future<void> _reclaimEntry(
  FileSystemEntity entry,
  ProbeSpawner spawnProbe,
) async {
  if (entry is! Directory) return;
  if (!_entryName(entry).startsWith(incrFkcScratchPrefix)) return;
  if (!await _siblingDead(entry, spawnProbe)) return;
  try {
    entry.deleteSync(recursive: true);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: keeping ${entry.path} ($e).');
  }
}

/// Whether [entry] is a dead worker's scratch: it carries a lock file and
/// a helper process could take its lock. A missing lock file, an owner that
/// still holds the lock, and every probe failure count as alive.
Future<bool> _siblingDead(Directory entry, ProbeSpawner spawnProbe) async {
  if (!File(scratchLockPath(entry)).existsSync()) return false;
  return _probeSiblingLock(scratchLockPath(entry), spawnProbe);
}

/// Runs one probe for [lockPath]: exit 0 means the lock was acquired (the
/// owner is dead); any other exit — held lock, missing or unopenable file —
/// means keep. A probe that outlasts its timeout is wedged (a live owner
/// only ever fails the attempt fast): it is killed and the entry kept. A
/// spawn failure also keeps. Never throws.
Future<bool> _probeSiblingLock(String lockPath, ProbeSpawner spawnProbe) async {
  final Process probe;
  try {
    probe = await spawnProbe(lockPath);
  } on ProcessException catch (e) {
    stderr.writeln('incr_fkc_worker: lock probe failed ($e).');
    return false;
  }
  // The probe writes nothing, so no pipe can block it.
  try {
    final code = await probe.exitCode.timeout(incrFkcTryLockTimeout);
    return code == 0;
  } on TimeoutException {
    probe.kill(ProcessSignal.sigkill);
    try {
      await probe.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      stderr.writeln('incr_fkc_worker: lock probe stuck; keeping $lockPath.');
    }
    return false;
  }
}
