/// Shared HOME-hermeticity helper for runnable targets (RT37-flutter:02).
///
/// Every entry point a user can `bazel run` routes through here, with one of
/// two policies:
///
/// * caller-home: the tool CLI must resolve the caller's `PUB_CACHE` and
///   credentials, so the parent environment is kept and the CLI takes the
///   global [suppressAnalyticsFlag] instead (`withSuppressedAnalytics`).
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
/// Verified against the pinned toolchain: `dart --suppress-analytics
/// --version` and `dart --suppress-analytics pub token list` both exit 0,
/// write nothing under `$HOME`, and `token list` still prints the caller's
/// `XDG_CONFIG_HOME/dart/pub-tokens.json` credentials.
const suppressAnalyticsFlag = '--suppress-analytics';

/// Returns [args] with [suppressAnalyticsFlag] inserted before the command,
/// unless already present. The flag is global, so it must precede the
/// command (`dart --suppress-analytics pub ...`); appending it after the
/// command would make pub reject it.
List<String> withSuppressedAnalytics(List<String> args) {
  if (args.contains(suppressAnalyticsFlag)) return args;
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
