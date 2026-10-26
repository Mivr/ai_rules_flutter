/// Shared HOME-hermeticity helper for runnable targets (RT37-flutter:02).
///
/// Every entry point a user can `bazel run` routes through here, with one of
/// two policies:
///
/// * caller-home: the tool CLI must resolve the caller's `PUB_CACHE` and
///   credentials, so the parent environment is kept and a command-form CLI
///   takes the global [suppressAnalyticsFlag] instead
///   (`withSuppressedAnalytics`). File-form executions (`dart program.dart`)
///   pass through unchanged: the VM rejects the flag there (exit 255), so
///   the program keeps the caller env and any telemetry the SDK itself
///   writes on a file run is outside what the launcher can suppress.
/// * private: the spawned program gets a fresh dir for every home-locating
///   key ([privateHomeEnv]), removed afterwards (`createPrivateHome`).
///
/// User app/test code keeps the caller env; only rule-owned launchers and
/// tool CLIs are routed through this library (plus its shell counterpart
/// `RUN_HOME_SH` in `//flutter/private:run_home.bzl`, used where the
/// launcher is a shell template).
library;

import 'dart:io';

/// Env keys through which the dart CLI, pub, flutter_tools, or the Dart VM
/// locate per-user state (telemetry, credentials, caches), on POSIX and on
/// Windows.
const homeEnvKeys = <String>[
  'HOME',
  'USERPROFILE',
  'LOCALAPPDATA',
  'APPDATA',
  'XDG_CONFIG_HOME',
  'XDG_CACHE_HOME',
  'XDG_DATA_HOME',
];

/// Global dart/flutter CLI flag disabling analytics and telemetry writes.
///
/// Command-form only: the flag must precede the command (`dart
/// --suppress-analytics pub ...`). The Dart VM rejects it for file-form
/// executions (`dart program.dart` exits 255), which keep the caller env,
/// so [withSuppressedAnalytics] leaves those invocations unchanged.
/// Verified against the pinned toolchain: `dart --suppress-analytics
/// --version` and `dart --suppress-analytics pub token list` both exit 0,
/// write nothing under `$HOME`, and `token list` still prints the caller's
/// `XDG_CONFIG_HOME/dart/pub-tokens.json` credentials.
const suppressAnalyticsFlag = '--suppress-analytics';

/// Explicit opt-out twin of [suppressAnalyticsFlag]: an argument list holding
/// either flag already states its analytics policy and passes through
/// unchanged, never duplicated.
const noSuppressAnalyticsFlag = '--no-suppress-analytics';

/// Suffixes naming a runnable program file for the `dart` CLI, matched
/// case-insensitively against the first non-flag argument.
const programFileSuffixes = <String>[
  '.dart',
  '.dill',
  '.snapshot',
  '.aot',
  '.jit',
];

/// Whether [args] to the `dart` CLI is a file-form execution.
///
/// Skips leading arguments starting with `-` (global flags such as
/// `--verbose` or `--enable-asserts), then an empty remainder (a bare CLI or
/// global flags only, such as `--version`) or a first remainder ending,
/// case-insensitively, in a [programFileSuffixes] entry (`program.dart`,
/// `app.dill`, ...) is file form. Everything else names a command (`pub`,
/// `format`, ...) whose run writes telemetry under HOME unless suppressed.
/// Mirrors the corrected rules_dart classification (`isFileExecution` in
/// `dart/private/tools/private_home.dart`, rules_dart task
/// FD-herm-launcher-env); the shell launchers (`RUN_HOME_SH` in
/// `//flutter/private:run_home.bzl` and the Windows `.bat` in
/// `//dart:flutter_sdk_binary`) implement the same rule.
bool isFileForm(List<String> args) {
  var rest = args;
  while (rest.isNotEmpty && rest.first.startsWith('-')) {
    rest = rest.sublist(1);
  }
  if (rest.isEmpty) return true;
  final first = rest.first.toLowerCase();
  return programFileSuffixes.any(first.endsWith);
}

/// Returns [args] with [suppressAnalyticsFlag] inserted before the command,
/// unless already present. The flag is global, so it must precede the
/// command (`dart --suppress-analytics pub ...`); appending it after the
/// command would make pub reject it. File-form executions ([isFileForm])
/// pass through unchanged: the VM rejects the flag there (exit 255), so the
/// program keeps the caller env and any telemetry the SDK itself writes on
/// a file run is outside what the launcher can suppress. An [args] holding [suppressAnalyticsFlag] or
/// [noSuppressAnalyticsFlag] passes through unchanged, never duplicated, and
/// nothing else is ever reordered.
List<String> withSuppressedAnalytics(List<String> args) {
  if (args.contains(suppressAnalyticsFlag) ||
      args.contains(noSuppressAnalyticsFlag)) {
    return args;
  }
  if (isFileForm(args)) return args;
  return <String>[suppressAnalyticsFlag, ...args];
}

/// Creates a fresh private home dir under [parent]. The caller removes it
/// afterwards; integration launchers use their own scratch lifecycle, while
/// single spawns (such as `flutter_tester`) delete it once the child exits.
Directory createPrivateHome(String parent) =>
    Directory(parent).createTempSync('run-home-');

/// Env overrides routing every home-locating key at [dir]. Merge over the
/// launcher's env (or the parent env for single spawns); everything else is
/// inherited unchanged.
Map<String, String> privateHomeEnv(String dir) => <String, String>{
  for (final key in homeEnvKeys) key: dir,
};
