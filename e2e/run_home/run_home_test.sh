#!/usr/bin/env bash
#
# run_home_test.sh — HOME-hermeticity gate for runnable targets.
#
# Covers the RT37-flutter:02 class: runnable targets letting the dart CLI,
# pub, flutter_tools, or the Dart VM write telemetry/state into the
# caller's HOME. For every row in registry.tsv the script either runs the
# target under canary HOME dirs (mode `run`) or builds it (mode `build`).
#
# Canary model: each run row gets a fresh temp root holding canary dirs for
# HOME, USERPROFILE, APPDATA, LOCALAPPDATA, XDG_CONFIG_HOME, XDG_CACHE_HOME
# and XDG_DATA_HOME, each seeded with a single marker file. PUB_CACHE and
# BAZELISK_HOME point at sibling dirs outside the canaries (the tools under
# test must resolve their package cache outside HOME-derived defaults).
# Caller-home rows additionally seed the caller credential at
# XDG_CONFIG_HOME/dart/pub-tokens.json — the location `pub token list`
# reads — and the script asserts the tool prints it while writing nothing
# else. After `bazel run` the script snapshots every canary dir and fails
# naming the entry if anything was created, changed, or removed — except
# Bazel's own output base, which a PATH `bazel` unavoidably places under
# HOME (or XDG_CACHE_HOME when set): paths under `home/.cache/bazel` and
# `xdg-cache/bazel` are allowlisted. Target telemetry (.dart-tool,
# .config/dart, ...) matches no allowlist entry, so a leak always fails.
#
# Usage: ./run_home_test.sh (runs from this directory)
# Env:   BAZEL (default: bazel) — the Bazel binary; no startup flags needed.
#
set -euo pipefail

BAZEL="${BAZEL:-bazel}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REGISTRY="$HERE/registry.tsv"
AUDIT="$HERE/audit.tsv"
# Fake hosted credential planted in the caller-env XDG_CONFIG_HOME (at
# dart/pub-tokens.json, the location `pub token list` reads). The URL
# (never the token) is asserted on the tool's stdout to prove credential
# lookup still resolves from the caller env while HOME stays clean.
FAKE_HOST="https://pub.example.com"
FAILURES=""

fail() {
  echo "FAIL: $1" >&2
  FAILURES="$FAILURES $1"
}

registry_rows() {
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$REGISTRY"
}

audit_patterns() {
  grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$AUDIT" | cut -f1
}

# True if $1 is covered by audit.tsv (exact label or `prefix/...` subtree).
audited() {
  local label="$1" pattern
  while IFS= read -r pattern; do
    if [[ "$pattern" == *"/..." ]]; then
      [[ "$label" == "${pattern%/...}"* ]] && return 0
    elif [[ "$label" == "$pattern" ]]; then
      return 0
    fi
  done < <(audit_patterns)
  return 1
}

registered() {
  local label="$1" row l
  while IFS=$'\t' read -r l _ _ _ _; do
    [[ "$l" == "$label" ]] && return 0
  done < <(registry_rows)
  return 1
}

check_enumeration() {
  echo "== enumeration: replaying the registry queries"
  local got="" missing=0 label q one
  for q in \
    'kind(flutter_sdk_binary, @rules_flutter//dart/...)' \
    'kind(flutter_pub, @rules_flutter//flutter/...)' \
    'kind(test, //...)' \
    'kind(test_suite, //...)' \
    'kind(".*_binary rule", //...)' \
    'kind(".*_binary rule", @rules_flutter//dart/...)' \
    'kind(".*_binary rule", @rules_flutter//flutter/...)' \
    'kind(test, @rules_flutter//dart/...)' \
    'kind(test, @rules_flutter//flutter/...)'; do
    one=""
    if ! one="$("$BAZEL" query "$q" 2>/dev/null)"; then
      fail "enumeration query failed: $q"
      missing=1
      continue
    fi
    got="$got$one"$'\n'
  done
  # //tools/... does not load from a downstream workspace, so its audit
  # rows are only re-enumerated when these queries happen to succeed.
  local tools_got=""
  if tools_got="$("$BAZEL" query \
    'kind(".*_binary rule", @rules_flutter//tools/...)' \
    'kind(test, @rules_flutter//tools/...)' 2>/dev/null)"; then
    got="$got$tools_got"$'\n'
  else
    echo "note: //tools/... is not queryable from this workspace; its $(grep -c '^@rules_flutter//tools/' "$AUDIT" || true) audit rows are attested, not re-enumerated"
  fi
  while IFS= read -r label; do
    [[ -z "$label" ]] && continue
    if ! registered "$label" && ! audited "$label"; then
      fail "unregistered runnable target: $label"
      missing=1
    fi
  done <<<"$(sort -u <<<"$got")"
  # Every registry row must still resolve.
  while IFS=$'\t' read -r label _ _ _ _; do
    if [[ -z "$("$BAZEL" query "$label" 2>/dev/null)" ]]; then
      fail "registry entry does not resolve: $label"
      missing=1
    fi
  done < <(registry_rows)
  if [[ "$missing" -eq 0 ]]; then
    echo "enumeration: all runnable targets registered"
  fi
}

snapshot_tree() {
  local dir="$1" out="$2"
  (cd "$dir" && find . -mindepth 1 | LC_ALL=C sort >"$out.files")
  (cd "$dir" && find . -mindepth 1 -type f -exec sha256sum -- {} + | LC_ALL=C sort >"$out.sums")
}

# Prints diff lines (unified, one per changed path) that are NOT Bazel's own
# output base. $1 = subdir name under the canary root (selects the
# allowlist), $2/$3 = before/after snapshot prefixes.
unsanctioned_changes() {
  local sub="$1" before="$2" after="$3" diff
  diff="$(diff -u "$before.files" "$after.files"; diff -u "$before.sums" "$after.sums"; true)"
  case "$sub" in
    home) grep -E '^[+-][^+-]' <<<"$diff" | grep -v '^[+-] \./\.cache/bazel\(/\|$\)' || true ;;
    xdg-cache) grep -E '^[+-][^+-]' <<<"$diff" | grep -v '^[+-] \./bazel\(/\|$\)' || true ;;
    *) grep -E '^[+-][^+-]' <<<"$diff" || true ;;
  esac
}

run_row() {
  local label="$1" args="$2" policy="$3"
  echo "== run: $label -- $args ($policy)"
  local root canary sub out changes rc=0 row_failed=0
  root="$(mktemp -d "${TMPDIR:-/tmp}/run-home.XXXXXX")"
  # Bazel marks its output-base files and directories read-only, so plain
  # `rm -rf` fails there; restore write permission first. Quoted at trap
  # definition time so the cleanup runs even after `cd` elsewhere.
  # shellcheck disable=SC2064
  trap "chmod -R u+w '$root' 2>/dev/null; rm -rf '$root'" RETURN
  for sub in home userprofile appdata localappdata xdg-config xdg-cache xdg-data; do
    mkdir -p "$root/$sub"
    echo "run-home canary for $label" >"$root/$sub/.run-home-marker"
  done
  mkdir -p "$root/ext/pubcache" "$root/ext/bazelisk-home"
  mkdir -p "$root/xdg-config/dart"
  printf '{"version":1,"hosted":[{"url":"%s","token":"run-home-fake-token"}]}' \
    "$FAKE_HOST" >"$root/xdg-config/dart/pub-tokens.json"
  for sub in home userprofile appdata localappdata xdg-config xdg-cache xdg-data; do
    snapshot_tree "$root/$sub" "$root/$sub.before"
  done
  out="$root/stdout.log"
  if [[ "$args" == "-" ]]; then
    HOME="$root/home" USERPROFILE="$root/userprofile" APPDATA="$root/appdata" \
      LOCALAPPDATA="$root/localappdata" XDG_CONFIG_HOME="$root/xdg-config" \
      XDG_CACHE_HOME="$root/xdg-cache" XDG_DATA_HOME="$root/xdg-data" \
      PUB_CACHE="$root/ext/pubcache" BAZELISK_HOME="$root/ext/bazelisk-home" \
      "$BAZEL" run "$label" -- >"$out" 2>&1 || rc=$?
  else
    # Word-split the registry args: they are simple tokens, never quoted.
    # shellcheck disable=SC2086
    HOME="$root/home" USERPROFILE="$root/userprofile" APPDATA="$root/appdata" \
      LOCALAPPDATA="$root/localappdata" XDG_CONFIG_HOME="$root/xdg-config" \
      XDG_CACHE_HOME="$root/xdg-cache" XDG_DATA_HOME="$root/xdg-data" \
      PUB_CACHE="$root/ext/pubcache" BAZELISK_HOME="$root/ext/bazelisk-home" \
      "$BAZEL" run "$label" -- $args >"$out" 2>&1 || rc=$?
  fi
  # Shut down this row's server: its output base lives under the canary,
  # which the trap removes, so never reuse it.
  HOME="$root/home" XDG_CACHE_HOME="$root/xdg-cache" \
    BAZELISK_HOME="$root/ext/bazelisk-home" \
    "$BAZEL" shutdown >/dev/null 2>&1 || true
  if [[ "$rc" -ne 0 ]]; then
    fail "$label exited $rc (expected 0); log: $out (canary root kept: $root)"
    trap - RETURN
    return
  fi
  if [[ "$args" == *"token list"* ]] && ! grep -q -F "$FAKE_HOST" "$out"; then
    fail "$label hid the caller XDG credential ($FAKE_HOST not on stdout)"
    row_failed=1
  fi
  for sub in home userprofile appdata localappdata xdg-config xdg-cache xdg-data; do
    snapshot_tree "$root/$sub" "$root/$sub.after"
    changes="$(unsanctioned_changes "$sub" "$root/$sub.before" "$root/$sub.after")"
    if [[ -n "$changes" ]]; then
      fail "$label wrote under canary $sub:$changes"
      row_failed=1
    fi
  done
  if [[ "$row_failed" -eq 0 ]]; then
    echo "ok: $label left every canary dir unchanged"
  else
    echo "forensics for $label: stdout $out, canary root kept: $root" >&2
    trap - RETURN
  fi
}

build_row() {
  local label="$1" log rc=0
  echo "== build (not-run): $label"
  log="$(mktemp "${TMPDIR:-/tmp}/run-home-build.XXXXXX.log")"
  if ! "$BAZEL" build "$label" >"$log" 2>&1; then
    fail "$label failed to build; log kept: $log"
  else
    rm -f "$log"
    echo "ok: $label built"
  fi
}

main() {
  cd "$HERE"
  check_enumeration
  local label args policy mode
  while IFS=$'\t' read -r label args policy mode _; do
    case "$mode" in
      run) run_row "$label" "$args" "$policy" ;;
      build) build_row "$label" ;;
      *) fail "registry row with unknown mode: $label" ;;
    esac
  done < <(registry_rows)
  if [[ -n "$FAILURES" ]]; then
    echo "FAILING ENTRIES:$FAILURES" >&2
    exit 1
  fi
  echo "run_home: all entries clean"
}

main "$@"
