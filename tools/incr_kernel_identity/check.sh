#!/usr/bin/env bash
#
# Incremental kernel worker identity check.
#
# Proves the design claim in docs/incremental-kernel.md against the real
# compiler: with `--@rules_flutter//flutter:incremental_kernel`, a warm
# persistent worker's `.dill` output is byte-for-byte the one-shot output for
# the same inputs, after a sequence of edits.
#
# What it does, on e2e/hello_world's `//:hello_world` (a real
# `flutter_kernel_target` over `package:flutter`) under `-c dbg`:
#   1. Worker leg, in one fresh output base, with
#      `--strategy=FlutterKernelCompile=worker` and a single worker instance:
#      builds the original sources (s0), then two successive edits (s1, s2)
#      that together touch more than one app library including one library's
#      import directives, then the revert to the original (s3). The builds run
#      back to back on one Bazel server so the worker stays up. The reverted
#      build deletes the previous outputs first, so the action-cache hit the
#      identical inputs would otherwise serve cannot hide a cold worker.
#   2. One-shot leg, in a second fresh output base, with
#      `--strategy=FlutterKernelCompile=local` (the same binary runs once per
#      action, cold): builds the same source states s0, s1, s2.
#   3. Compares every worker dill byte-for-byte with the one-shot dill of the
#      same source state (the reverted s3 against the original s0).
#   4. Fails on any difference, naming the step and both sha256 values. Also
#      fails when any compared build did not execute its compile under its
#      stated strategy: every build writes `--execution_log_json_file`, and
#      the log must hold a `FlutterKernelCompile` entry with the expected
#      runner and `cacheHit: false`. No build reads a disk or remote cache:
#      each build gets a fresh empty `--disk_cache` directory (overriding the
#      `--disk_cache` CI's `~/.bazelrc` sets) plus `--noremote_accept_cached`
#      and `--noremote_upload_local_results`.
#   5. Fails unless the worker leg stayed warm: exactly one
#      `FlutterKernelCompile` worker is created across the four builds (seen
#      in `--worker_verbose` output), none is destroyed, and the worker
#      process and its `frontend_server` child keep the same PIDs (parentage
#      verified through the process tree, not timing).
#   6. Leaves the tree as found: edited sources are restored from backups on
#      every exit path, and both output bases are shut down and deleted.
#      Bazel gets no startup flag other than `--output_base`.
#
# Usage: from a checkout's root:  bash tools/incr_kernel_identity/check.sh
# Bazel is `${BAZEL:-bazel}`, so a wrapper can be substituted. Exits 0 when
# every comparison holds, 1 otherwise.
set -u

BAZEL="${BAZEL:-bazel}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WS="$ROOT/e2e/hello_world"
TARGET="//:hello_world"
FLAG="--@rules_flutter//flutter:incremental_kernel"
MAIN="$WS/lib/main.dart"
COMMON="$WS/lib/common_widgets.dart"
DILL_NAME="hello_world.dill"

WORK=""
WB=""
OB=""

die() {
  echo "identity-check: FAIL: $*" >&2
  exit 1
}

cleanup() {
  if [ -n "$WORK" ] && [ -f "$WORK/main.dart.bak" ]; then
    cp -p "$WORK/main.dart.bak" "$MAIN" 2>/dev/null || true
    cp -p "$WORK/common_widgets.bak" "$COMMON" 2>/dev/null || true
  fi
  if [ -n "$WB" ]; then
    "$BAZEL" --output_base="$WB" shutdown >/dev/null 2>&1 || true
  fi
  if [ -n "$OB" ]; then
    "$BAZEL" --output_base="$OB" shutdown >/dev/null 2>&1 || true
  fi
  if [ -n "$WORK" ]; then
    rm -rf "$WORK"
  fi
}
trap 'exit 130' INT
trap 'exit 143' TERM
trap cleanup EXIT

command -v python3 >/dev/null 2>&1 || die "python3 is required"

[ -d "$WS" ] || die "workspace $WS not found (run from the repo root)"
[ -f "$MAIN" ] && [ -f "$COMMON" ] || die "fixture sources not found"

WORK="$(mktemp -d)"
WB="$WORK/wbase"
OB="$WORK/obase"
mkdir -p "$WB" "$OB" "$WORK/wdisk" "$WORK/odisk" "$WORK/w3disk"
cp -p "$MAIN" "$WORK/main.dart.bak"
cp -p "$COMMON" "$WORK/common_widgets.bak"

T_START="$(date +%s)"

cd "$WS"

# require_strategy <execlog> <want-runner> <step>: the log must hold at least
# one FlutterKernelCompile entry, all with the expected runner and no hit.
require_strategy() {
  python3 - "$1" "$2" "$3" <<'PYEOF'
import json, sys
path, want, step = sys.argv[1], sys.argv[2], sys.argv[3]
txt = open(path).read()
dec = json.JSONDecoder()
rows = []
i, n = 0, len(txt)
while i < n:
  while i < n and txt[i].isspace():
    i += 1
  if i >= n:
    break
  obj, i = dec.raw_decode(txt, i)
  rows.append(obj)
fkc = [o for o in rows if o.get("mnemonic") == "FlutterKernelCompile"]
if not fkc:
  print("identity-check: FAIL: %s executed no FlutterKernelCompile action"
        " (cache hit or misconfiguration)" % step)
  sys.exit(1)
bad = [o for o in fkc
       if o.get("runner") != want or o.get("cacheHit") is not False]
if bad:
  print("identity-check: FAIL: %s ran %d FlutterKernelCompile action(s)"
        " outside its strategy (want runner=%s, no cache hit): %s"
        % (step, len(bad), want,
           ["runner=%s cacheHit=%s" % (o.get("runner"), o.get("cacheHit"))
            for o in bad]))
  sys.exit(1)
print("identity-check: %s executed %d FlutterKernelCompile action(s)"
      " as runner=%s, no cache hit" % (step, len(fkc), want))
PYEOF
}

worker_build() {
  local step="$1" execlog="$2" log="$3" disk="$4" rc t0 t1
  t0="$(date +%s)"
  "$BAZEL" --output_base="$WB" build "$TARGET" -c dbg "$FLAG" \
    --strategy=FlutterKernelCompile=worker \
    --worker_max_instances=FlutterKernelCompile=1 \
    --disk_cache="$disk" --noremote_accept_cached \
    --noremote_upload_local_results \
    --execution_log_json_file="$execlog" --execution_log_sort=false \
    --symlink_prefix="$WORK/wlink-" --worker_verbose >"$log" 2>&1
  rc=$?
  t1="$(date +%s)"
  echo "identity-check: build $step: rc=$rc ($((t1 - t0))s)"
  if [ "$rc" -ne 0 ]; then
    tail -n 30 "$log"
    die "build $step failed (rc=$rc)"
  fi
  require_strategy "$execlog" worker "$step" || die "build $step is not warm-worker execution"
}

oneshot_build() {
  local step="$1" execlog="$2" log="$3" rc t0 t1
  t0="$(date +%s)"
  "$BAZEL" --output_base="$OB" build "$TARGET" -c dbg "$FLAG" \
    --strategy=FlutterKernelCompile=local \
    --disk_cache="$WORK/odisk" --noremote_accept_cached \
    --noremote_upload_local_results \
    --execution_log_json_file="$execlog" --execution_log_sort=false \
    --symlink_prefix="$WORK/olink-" >"$log" 2>&1
  rc=$?
  t1="$(date +%s)"
  echo "identity-check: build $step: rc=$rc ($((t1 - t0))s)"
  if [ "$rc" -ne 0 ]; then
    tail -n 30 "$log"
    die "build $step failed (rc=$rc)"
  fi
  require_strategy "$execlog" local "$step" || die "build $step is not one-shot execution"
}

# locate_dill <link-prefix>: the hello_world.dill built under that prefix,
# resolved to its real path under the output base.
locate_dill() {
  local link="$1bin/$DILL_NAME" real
  [ -e "$link" ] || die "no $link (build produced no dill?)"
  real="$(readlink -f "$link")"
  [ -f "$real" ] || die "$link resolves to no file ($real)"
  printf '%s' "$real"
}

# save_dill <src> <dst>: copies a built dill, failing loudly when absent.
save_dill() {
  [ -f "$1" ] || die "no built dill at $1"
  cp "$1" "$2"
  [ -f "$2" ] || die "could not save $1 to $2"
}

sha_of() {
  sha256sum "$1" | cut -d' ' -f1
}

# compare_dills <step> <worker-dill> <oneshot-dill>
compare_dills() {
  local step="$1" ha hb
  ha="$(sha_of "$2")"
  hb="$(sha_of "$3")"
  if ! cmp -s "$2" "$3"; then
    die "$step differs: worker sha256=$ha one-shot sha256=$hb"
  fi
  echo "identity-check: $step identical (sha256=$ha)"
}

# First edit: both app libraries; common_widgets gains an import and uses it.
apply_s1() {
  python3 - "$COMMON" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
def rep(old, new):
  global src
  if src.count(old) != 1:
    print("identity-check: s1 anchor %r found %d times, want 1"
          % (old[:60], src.count(old)))
    sys.exit(1)
  src = src.replace(old, new)
rep("import 'package:flutter/material.dart';",
    "import 'package:flutter/foundation.dart';\n"
    "import 'package:flutter/material.dart';")
rep("const AppTitle({required this.text, super.key});",
    "const AppTitle({required this.text, this.tooltip, super.key});")
rep("  /// The string this widget renders.\n  final String text;",
    "  /// The string this widget renders.\n  final String text;\n"
    "\n  /// An optional tooltip shown on long press.\n  final String? tooltip;")
rep("""    return Text(
      text,
      style: Theme.of(context).textTheme.headlineMedium,
    );""",
    """    final label = tooltip ?? (kDebugMode ? 'debug' : 'release');
    return Tooltip(
      message: label,
      child: Text(
        text,
        style: Theme.of(context).textTheme.headlineMedium,
      ),
    );""")
open(path, "w").write(src)
PYEOF
  [ "$?" -eq 0 ] || die "applying edit s1 to common_widgets failed"
  python3 - "$MAIN" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = "AppTitle(text: '$_counter'),"
if src.count(old) != 1:
  print("identity-check: s1 anchor %r found %d times, want 1"
        % (old[:60], src.count(old)))
  sys.exit(1)
open(path, "w").write(
  src.replace(old, "AppTitle(text: '$_counter', tooltip: 'counter'),"))
PYEOF
  [ "$?" -eq 0 ] || die "applying edit s1 to main failed"
}

# Second edit: both app libraries again (a label and a text style).
apply_s2() {
  python3 - "$MAIN" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = "Text('count: $_counter', key: const ValueKey('agent_test_label')),"
if src.count(old) != 1:
  print("identity-check: s2 anchor %r found %d times, want 1"
        % (old[:60], src.count(old)))
  sys.exit(1)
open(path, "w").write(
  src.replace(old,
              "Text('total: $_counter', key: const ValueKey('agent_test_label')),"))
PYEOF
  [ "$?" -eq 0 ] || die "applying edit s2 to main failed"
  python3 - "$COMMON" <<'PYEOF'
import sys
path = sys.argv[1]
src = open(path).read()
old = "style: Theme.of(context).textTheme.headlineMedium,"
if src.count(old) != 1:
  print("identity-check: s2 anchor %r found %d times, want 1"
        % (old[:60], src.count(old)))
  sys.exit(1)
open(path, "w").write(
  src.replace(old, "style: Theme.of(context).textTheme.headlineLarge,"))
PYEOF
  [ "$?" -eq 0 ] || die "applying edit s2 to common_widgets failed"
}

# snapshot_pids: prints "<worker-pid> <compiler-pid>". Matches the persistent
# worker by its command line and the compiler by parentage, so a stray
# process can never match; each must be exactly one.
snapshot_pids() {
  local w p ppid kids kid
  w="$(pgrep -f "incr_fkc_worker --persistent_worker")"
  [ -n "$w" ] || die "no persistent incr_fkc_worker process found"
  if [ "$(printf '%s\n' "$w" | wc -l)" != "1" ]; then
    die "more than one persistent worker: $w"
  fi
  case "$(tr '\0' ' ' <"/proc/$w/cmdline" 2>/dev/null)" in
    *incr_fkc_worker*) ;;
    *) die "pid $w is not the worker" ;;
  esac
  kids=""
  for p in $(pgrep -f "frontend_server_aot.dart.snapshot"); do
    ppid="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    if [ "$ppid" = "$w" ]; then
      kids="$kids $p"
    fi
  done
  # shellcheck disable=SC2086
  set -- $kids
  [ "$#" = "1" ] || die "expected one frontend_server child of worker $w, found:$kids"
  kid="$1"
  printf '%s %s' "$w" "$kid"
}

record_pids() {
  # record_pids <__wvar> <__fvar>: snapshots into the named variables.
  local out w f
  out="$(snapshot_pids)" || die "worker pids unavailable: $out"
  w="${out%% *}"
  f="${out##* }"
  [ -n "$w" ] && [ -n "$f" ] || die "worker pids unavailable: $out"
  printf -v "$1" '%s' "$w"
  printf -v "$2" '%s' "$f"
}

echo "identity-check: worker leg (strategy=worker, one instance)"
worker_build "worker-s0" "$WORK/w0.json" "$WORK/w0.log" "$WORK/wdisk"
WDILL="$(locate_dill "$WORK/wlink-")" || die "could not locate worker dill"
save_dill "$WDILL" "$WORK/hw0.dill"
record_pids W0 F0
echo "identity-check: warm worker pid=$W0 compiler pid=$F0"
[ "$(grep -c "Created .*FlutterKernelCompile worker" "$WORK/w0.log" || true)" = "1" ] \
  || die "worker-s0 created no (or several) FlutterKernelCompile worker(s)"

echo "identity-check: one-shot leg (strategy=local)"
oneshot_build "oneshot-s0" "$WORK/o0.json" "$WORK/o0.log"
ODILL="$(locate_dill "$WORK/olink-")" || die "could not locate one-shot dill"
save_dill "$ODILL" "$WORK/ho0.dill"
compare_dills "s0 worker-vs-oneshot" "$WORK/hw0.dill" "$WORK/ho0.dill"

echo "identity-check: edit s1 (both libraries, new import)"
apply_s1
worker_build "worker-s1" "$WORK/w1.json" "$WORK/w1.log" "$WORK/wdisk"
save_dill "$WDILL" "$WORK/hw1.dill"
record_pids W1 F1
[ "$W1" = "$W0" ] || die "worker-s1 ran on another worker ($W0 -> $W1)"
[ "$F1" = "$F0" ] || die "worker-s1 started a new compiler ($F0 -> $F1)"
oneshot_build "oneshot-s1" "$WORK/o1.json" "$WORK/o1.log"
save_dill "$ODILL" "$WORK/ho1.dill"
[ "$(sha_of "$WORK/hw1.dill")" != "$(sha_of "$WORK/hw0.dill")" ] \
  || die "edit s1 changed no bytes"
compare_dills "s1 worker-vs-oneshot" "$WORK/hw1.dill" "$WORK/ho1.dill"

echo "identity-check: edit s2 (both libraries)"
apply_s2
worker_build "worker-s2" "$WORK/w2.json" "$WORK/w2.log" "$WORK/wdisk"
save_dill "$WDILL" "$WORK/hw2.dill"
record_pids W2 F2
[ "$W2" = "$W0" ] || die "worker-s2 ran on another worker ($W0 -> $W2)"
[ "$F2" = "$F0" ] || die "worker-s2 started a new compiler ($F0 -> $F2)"
oneshot_build "oneshot-s2" "$WORK/o2.json" "$WORK/o2.log"
save_dill "$ODILL" "$WORK/ho2.dill"
[ "$(sha_of "$WORK/hw2.dill")" != "$(sha_of "$WORK/hw1.dill")" ] \
  || die "edit s2 changed no bytes"
compare_dills "s2 worker-vs-oneshot" "$WORK/hw2.dill" "$WORK/ho2.dill"

echo "identity-check: revert to the original sources"
cp -p "$WORK/main.dart.bak" "$MAIN"
cp -p "$WORK/common_widgets.bak" "$COMMON"
# The reverted inputs repeat s0 exactly, so without this the compile would be
# an action-cache hit and the warm path would go untested.
rm -f "$WDILL"
worker_build "worker-s3-reverted" "$WORK/w3.json" "$WORK/w3.log" "$WORK/w3disk"
save_dill "$WDILL" "$WORK/hw3.dill"
record_pids W3 F3
[ "$W3" = "$W0" ] || die "worker-s3 ran on another worker ($W0 -> $W3)"
[ "$F3" = "$F0" ] || die "worker-s3 started a new compiler ($F0 -> $F3)"
compare_dills "s3-reverted worker-vs-oneshot-s0" "$WORK/hw3.dill" "$WORK/ho0.dill"

echo "identity-check: warmth evidence across the worker leg"
CREATED=0
for l in "$WORK/w0.log" "$WORK/w1.log" "$WORK/w2.log" "$WORK/w3.log"; do
  CREATED=$((CREATED + $(grep -c "Created .*FlutterKernelCompile worker" "$l" || true)))
done
[ "$CREATED" = "1" ] || die "created $CREATED FlutterKernelCompile workers, want 1"
if grep -h -i -E "destroying.*flutterkernelcompile|killing.*flutterkernelcompile" \
    "$WORK/w0.log" "$WORK/w1.log" "$WORK/w2.log" "$WORK/w3.log"; then
  die "a FlutterKernelCompile worker was destroyed mid-leg"
fi
echo "identity-check: one worker (pid=$W0), one compiler (pid=$F0), all four builds warm"

T_END="$(date +%s)"
echo "identity-check: PASS in $((T_END - T_START))s"
