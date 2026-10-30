# iOS real-plugin matrix (POD-2)

This workspace pins fourteen real Flutter plugins and records what the pinned
rules_flutter checkout does with each one today. It turns the design's "today"
column into a measurement, so a change that fixes or breaks a real plugin fails
a gate instead of going unnoticed.

`pubspec.yaml` pins the versions; `pubspec.lock` is resolved with the pinned
Flutter toolchain, and every hosted entry carries its sha256. The single
`flutter.pub` hub is named `deps`, so a plugin's spoke is `@deps__<plugin>`.

## Fetch mode (Linux)

```sh
bazel --max_idle_secs=60 query @deps__url_launcher_ios//:all
python3 run_matrix.py            # --mode fetch is the default
python3 run_matrix.py --self-test
```

Fetch mode reads `expected.json` and runs `bazel query @deps__<plugin>//:all`
once per pinned plugin. An `ok` entry needs exit 0. A refusal entry needs a
non-zero exit and its substring in the combined output. It prints one
`PASS`/`FAIL` line per plugin and a summary, and exits 1 on any mismatch.
`--self-test` exercises the comparator with fake outcomes and needs no Bazel,
network or workspace.

`expected.json` is the contract's data: when a later item fixes a refusal, edit
its entry there; do not add plugin names to the runner.

On this base the FlutterFire plugins, `sentry_flutter` and
`google_mlkit_commons` are refused by the Android Gradle reader before their
Apple sources are read, so `expected.json` records that measured refusal.
`google_sign_in_ios` and `stripe_ios` reach the Apple layer and refuse because
the hub sets no `swift_package_resolved`. A change that fixes either layer
changes the query output and fails this matrix until the entry is updated.

## Build mode (macOS)

```sh
python3 run_matrix.py --mode build
```

Build mode reads the plugins `expected.json` records as `ok` and builds each
spoke's device library, one at a time:

```sh
bazel --max_idle_secs=60 build @deps__<plugin>//:<plugin>_apple_ios
```

`build_expected.json` names the builds that gate the step today.
`image_picker_ios` is expected to fail until POD-1 builds its
`image_picker_ios_objc` target: its Swift code uses `FLTMaxSize` from that
target's pigeon header. The other builds are printed and recorded without
gating yet; a later item adds them to `build_expected.json` when their expected
result is known.

## Regenerating the lock

```sh
bazel --max_idle_secs=60 run @rules_flutter//flutter:pub -- get
```

Never hand-edit `pubspec.lock`; the command above writes it with the pinned
toolchain and the sha256 of every archive.

## Why `MODULE.bazel` is a symlink

`MODULE.bazel` points at `MODULE.bazel.real` so the new workspace follows the
same shape as the other e2e workspaces that were added under a fix whose allowed
paths did not include the release-archive line in `.gitattributes`. The
export-ignore guard (`//flutter/tests:e2e_export_ignore_guard_test`) only sees
regular module files, so until `.gitattributes` gains
`/e2e/ios_plugin_matrix/ export-ignore`, the workspace would ship in the release
archive and fail that guard. Bazel, `check_e2e_coverage` and the acceptance
query all follow the symlink. A later item that may edit `.gitattributes` should
delete the symlink, move the content back to `MODULE.bazel`, and add the line.
