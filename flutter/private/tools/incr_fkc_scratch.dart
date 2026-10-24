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
/// sweep probes each sibling's lock file in process, with the same lock
/// call: `lockSync(FileLock.exclusive)` is the non-blocking attempt (only
/// `FileLock.blockingExclusive` blocks), so a held lock fails at once.
/// Acquiring the lock proves the owner is gone and the directory is deleted,
/// while a held lock, a missing or unopenable lock file, or any other
/// failure keeps the directory. This is sound because POSIX record locks
/// conflict between processes, and the sweeping worker is never the process
/// that owns a sibling's lock — it never sweeps its own directory, and it
/// never opens its own lock file through any other handle. Liveness never
/// depends on age or on PIDs, so PID reuse cannot confuse it.
///
/// The sweep only touches directories the worker's own naming scheme
/// produces (`incr_fkc_*`), never the worker's own directory, spawns no
/// process, and never fails the start or the compile: anything it cannot
/// remove is skipped with a note on stderr.
library;

import 'dart:io';

/// The temp-directory entry prefix the worker's scratch uses.
const incrFkcScratchPrefix = 'incr_fkc_';

/// The lock file inside one worker's scratch directory.
const incrFkcLockFileName = 'lock';

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
    // Append mode never truncates: a probe must not destroy another
    // worker's file, and neither must a repeated claim.
    final handle = File(
      scratchLockPath(dir),
    ).openSync(mode: FileMode.append);
    handle.lockSync(FileLock.exclusive);
    return ScratchLock._(handle);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: no scratch lock ($e).');
    return ScratchLock._(null);
  }
}

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
    _reclaimEntry(entry);
  }
}

/// The final path segment of [entry].
String _entryName(FileSystemEntity entry) =>
    entry.path.split(Platform.pathSeparator).last;

/// Deletes [entry] when it is a dead worker's scratch. Keeps everything
/// else and notes kept entries on stderr. Never throws.
void _reclaimEntry(FileSystemEntity entry) {
  if (entry is! Directory) return;
  if (!_entryName(entry).startsWith(incrFkcScratchPrefix)) return;
  if (!_siblingDead(entry)) return;
  try {
    entry.deleteSync(recursive: true);
  } on FileSystemException catch (e) {
    stderr.writeln('incr_fkc_worker: keeping ${entry.path} ($e).');
  }
}

/// Whether [entry] is a dead worker's scratch: it carries a lock file whose
/// exclusive lock this process can take right now. A missing lock file, an
/// owner that still holds the lock, and every failure count as alive. If the
/// lock file vanishes between the existence check and the open, the open
/// throws and the entry is kept.
bool _siblingDead(Directory entry) {
  if (!File(scratchLockPath(entry)).existsSync()) return false;
  return _tryTakeLock(scratchLockPath(entry));
}

/// Attempts the exclusive lock on [lockPath] without blocking and releases
/// it again. `lockSync(FileLock.exclusive)` is the non-blocking attempt: a
/// lock held by a live owner fails at once, so this always answers in
/// microseconds. Returns true only when the lock was acquired — the owner
/// is dead — and false on a held lock, an unopenable file, or any other
/// [FileSystemException]. Releasing the probe handle touches only this
/// process's lock, never the owner's. Never throws.
bool _tryTakeLock(String lockPath) {
  RandomAccessFile? handle;
  try {
    // Append mode never truncates a live worker's file.
    handle = File(lockPath).openSync(mode: FileMode.append);
    handle.lockSync(FileLock.exclusive);
  } on FileSystemException {
    if (handle != null) {
      try {
        handle.closeSync();
      } on FileSystemException {
        // Releasing a lock that was never taken; nothing to report.
      }
    }
    return false;
  }
  try {
    handle.closeSync();
  } on FileSystemException {
    // Already released; the verdict stands.
  }
  return true;
}
