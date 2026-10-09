/// Which of Flutter's three build modes a run's app was built in.
///
/// The names are upstream's, and so is the line between them: debug is a JIT
/// app, profile and release are AOT. A device needs to know which, not only
/// "AOT or not": an iOS device attaches a debugger to a debug app and to
/// nothing else, and a profile app may serve a VM service where a release app
/// never does.
library;

enum BuildMode {
  /// A `-c dbg` build: a JIT kernel on the debug engine.
  debug,

  /// A `--profile` run: AOT, built `-c opt`.
  profile,

  /// Any other build: AOT, on the release engine.
  release;

  /// Whether the app runs Dart compiled ahead of time.
  bool get isAot => this != debug;
}
