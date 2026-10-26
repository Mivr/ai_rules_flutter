"""Shared HOME-hermeticity constants for shell-template launchers (RT37-flutter:02).

`flutter/private/tools/run_home.dart` is the source of truth; this file is
its shell counterpart for launchers that are shell templates and cannot
import Dart. `RUN_HOME_SUPPRESS_ANALYTICS` must equal the Dart
`suppressAnalyticsFlag`, and the `RUN_HOME_SH` snippet must implement the
same command-form-only rule as the Dart `withSuppressedAnalytics`:
`//flutter/private/tools/test/run_home_test.dart` asserts the flag, the
classification markers, and a shared table of cases agree, so update them
together.
"""

RUN_HOME_SUPPRESS_ANALYTICS = "--suppress-analytics"

RUN_HOME_SH = """\
# run_home counterpart: exec a tool CLI keeping the caller env (so
# PUB_CACHE and credentials resolve) while suppressing CLI telemetry
# writes into the caller's HOME. Mirrors withSuppressedAnalytics in
# flutter/private/tools/run_home.dart: the flag is global and only valid
# in command form — the VM rejects it for file-form executions (exit 255),
# which keep the caller env — so it is prepended only for command
# form. Leading dash-arguments are skipped, then an empty remainder (a bare
# CLI or global flags only, such as --version) or a first remainder ending
# in .dart/.dill/.snapshot/.aot/.jit (any case) is file form.
# An already-present --suppress-analytics/--no-suppress-analytics passes
# through unchanged, never duplicated; nothing else is reordered.
run_home_caller_home_exec() {
  local bin="$1"; shift
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--suppress-analytics" || "$arg" == "--no-suppress-analytics" ]]; then
      exec "$bin" "$@"
    fi
  done
  local rest=("$@") i=0 first="" form="command"
  while (( i < $# )) && [[ "${rest[i]}" == -* ]]; do
    (( ++i ))
  done
  if (( i < $# )); then
    # tr, not ${var,,}: the launcher also runs under macOS bash 3.2.
    first="$(printf '%s' "${rest[i]}" | tr '[:upper:]' '[:lower:]')"
    case "$first" in
      *.dart|*.dill|*.snapshot|*.aot|*.jit) form="file" ;;
    esac
  else
    form="file"
  fi
  if [[ "$form" == "command" ]]; then
    exec "$bin" --suppress-analytics "$@"
  else
    exec "$bin" "$@"
  fi
}
"""
