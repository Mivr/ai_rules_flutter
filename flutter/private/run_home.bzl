"""Shared HOME-hermeticity constants for shell-template launchers (RT37-flutter:02).

`flutter/private/tools/run_home.dart` is the source of truth; this file is
its shell counterpart for launchers that are shell templates and cannot
import Dart. `RUN_HOME_SUPPRESS_ANALYTICS` must equal the Dart
`suppressAnalyticsFlag`, and the `RUN_HOME_SH` snippet must pass that same
flag: `//flutter/private/tools/test/run_home_test.dart` asserts all three
agree, so update them together.
"""

RUN_HOME_SUPPRESS_ANALYTICS = "--suppress-analytics"

RUN_HOME_SH = """\
# run_home counterpart: exec a tool CLI keeping the caller env (so
# PUB_CACHE and credentials resolve) while suppressing CLI telemetry
# writes into the caller's HOME. The flag is global and must precede the
# command; an already-present flag is left alone, never duplicated.
run_home_caller_home_exec() {
  local bin="$1"; shift
  local arg suppress=1
  for arg in "$@"; do
    if [[ "$arg" == "--suppress-analytics" ]]; then suppress=0; break; fi
  done
  if (( suppress )); then
    exec "$bin" --suppress-analytics "$@"
  else
    exec "$bin" "$@"
  fi
}
"""
