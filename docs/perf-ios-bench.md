# iOS perf bench

Manual-only workflow (`.github/workflows/perf-ios.yaml`) measuring iOS build
cost of `rules_flutter` on GitHub's free macOS runners. Linux cannot build
iOS targets, so this is the only signal for the iOS half of the monorepo
perf target; the manager dispatches it per comparison and reads the
artifact.

## What it measures

For each of `base_ref` and `head_ref` (rules_flutter commits, wired through
`local_path_override` in the generated `MODULE.bazel`), in each of two
configurations (fixed table `CONFIGS` in `tools/perf/run_rep.py`, recorded
in the summary metadata):

- `device_release`: the Flutter iOS framework assembly itself —
  `//app:__app_framework_framework` with `-c opt
  --ios_multi_cpus=arm64`. That is the `_flutter_ios_framework` rule
  the generator's public `flutter_ios_framework_gen(name =
  "app_framework")` creates (`__<name>_framework` in
  `flutter/ios.bzl`): with `-c opt` the application is non-debug, so
  `flutter_application` runs AOT gen_snapshot for iOS (`FlutterAotMacho`)
  and the framework rule assembles App.framework (`FlutterIOSRetagDylib`
  + `FlutterIOSCopyAssets`), with no `ios_application`, hence no
  signing and no provisioning profile. The public
  `//app:app_framework` wrapper is an `apple_dynamic_framework_import`
  whose outputs are only consumed when linked into an app — building it
  executes zero actions (as the first dispatch showed), so the bench
  targets the inner rule and the driver fails any clean build that
  executes fewer than 10 actions (`--min-clean-actions`).
- `sim_debug`: the full simulator app — `//app:app_ios` with
  `-c dbg --ios_multi_cpus=sim_arm64` (the developer inner loop; the
  simulator runs debug builds only, and simulator bundles need no
  provisioning profile).

Per configuration the three scenarios run against a freshly reset
workspace copy:

1. `clean`: clean build (fresh workspace copy, fresh per-config output
   base, no caches anywhere).
2. `app_edit`: rebuild after a behaviour-changing top-layer app edit
   (`app/lib/main.dart` shows `value + 1` for the first wired widget).
3. `core_edit`: rebuild after a core body edit (layer 0, highest fan-in
   file; same `var total = 1;` to `var total = 2;` shape as the referee's
   `body_edit`). Cumulative: the app edit stays applied.

Per scenario run it records:

- Executed action count by mnemonic, from
  `bazel build --execution_log_json_file` (only executed spawns are logged).
- Total action CPU time (user+sys from each spawn's metrics) plus wall time.
  The Linux sandbox runner does not populate `userTime`/`systemTime` and
  the macOS runner did not either on the first dispatch;
  `cpu_time_available` says whether any spawn carried them, so missing
  data is never mistaken for zero CPU. Wall time is always reported.
  (`--experimental_execution_log_spawn_metrics` does not exist in the
  pinned Bazel 9.3.0 — `bazel help build` lists only the
  `--execution_log_{binary,compact,json}_file` outputs — so there is no
  extra per-spawn metric to consume.)
- Instructions retired for the iOS-only actions (`FlutterAotMacho`
  gen_snapshot for iOS, the `FlutterIOS*` framework/bundle tools,
  `FlutterStripEngine`, `FlutterPlistMerge`, `FlutterMachOVerifyProbe`,
  assembler/clang and linker steps), by replaying each such action's
  command line under `/usr/bin/time -l` with the host environment
  overlaid by the logged environment, in the build's execroot right
  after the build. Kernel compiles are excluded (the Linux bench
  measures them); pass `--mnemonic` to opt back in. Replays run with
  stdin closed, a 600 s per-action timeout, and an 1800 s whole-log
  budget; on exhaustion the report records `truncated=true` and the
  skipped count.
- Replay CPU seconds (`user_s`/`sys_s` from `time -l`) per action and
  per mnemonic. GitHub's macOS VMs may expose no PMU, in which case no
  replayed action carries an instruction counter; the summary then says
  so plainly and replay CPU is the fallback cost signal.
- Failed replays (non-zero exit or timeout) record the exit code plus
  the last 20 lines of stderr in `replay.json`, and the summary shows
  one sample per failing mnemonic (target, exit, stderr tail), so the
  next run tells us why a replay class failed (missing Xcode env,
  sandbox-only paths) instead of just counting it.
- Executed-but-not-replayed actions are counted per reason in
  `replay.json` (`skipped_by_mnemonic`) and shown in the summary's "Not
  replayed" table. Exec-configuration (host tool) spawns — outputs
  under an exec configuration directory such as
  `bazel-out/darwin_arm64-opt-exec-*/` or (Bazel 9's default, with no
  `-ST-<hash>` suffix) `bazel-out/darwin_arm64-opt-exec/`, which build
  host tools (abseil, the Swift worker) rather than the iOS app — are
  skipped by default under the single reason "host tools (not replayed)"
  (`--include-exec-config` opts back in).

## Generator v2: a reachable program

The first generator shape wired `main` to top-layer widgets only, with
no package calling its dependencies at run time, so AOT tree-shaking
dropped everything below the top layer: a layer-0 `core_edit`
re-ran the kernel compile but never `gen_snapshot`, and the AOT dill
came out byte-identical. Since generator v2 (same design as the
referee's `flutter-monorepo` v2) the generated program is reachable
like a real app:

- Each package entry (`entryN(x, probe)`) calls every own file's
  helper and value functions — including the value functions the
  bench edits — and constructs every own file's widget, all
  unconditionally, so a `body_edit` at any layer changes the AOT
  program. (`api_edit` keeps its meaning: adding an unused member
  legitimately changes nothing in AOT.)
- Each entry also calls its direct dependencies' entries, and `main`
  calls every top-layer entry. Cross-package calls are guarded by a
  probe `main` reads from a runtime source the compiler cannot fold
  (`int.tryParse('probe') ?? 0`, always zero at run time), so the
  whole transitive closure stays reachable for tree-shaking without
  running if the app ever runs. The DAG repair pass gives every
  package below the top layer at least one dependent, so reachability
  holds through the dependency graph from every seed.
- `bench-workspace-stats.json` records `generator_version: 2` (also
  embedded in the summary metadata as `base_stats`/`head_stats`); the
  summary warns when the two sides differ in shape. Numbers from the
  old shape are never comparable with v2 numbers.

## Apple replay environment

Bazel's darwin spawn runner adds `DEVELOPER_DIR` and `SDKROOT` at
execution time (as `XcodeLocalEnvProvider` does), so the execution log
never records them and naive replays of Apple actions fail with
`Error: DEVELOPER_DIR not set.` When the logged environment names an
Apple SDK platform (`APPLE_SDK_PLATFORM`, alongside
`APPLE_SDK_VERSION_OVERRIDE` / `XCODE_VERSION_OVERRIDE`),
`tools/perf/replay.py` resolves `DEVELOPER_DIR` from `xcode-select -p`
and `SDKROOT` from `xcrun --sdk <platform lowercased>
--show-sdk-path`, cached per platform. Without those tools (e.g.
Linux) it replays with the logged environment alone.

Ordering (enforced by `tools/perf/run_rep.py`): per repeat and per config,
the workspace is reset from the pristine copy, then all three scenario
builds run, then the execroot's `bazel-out` is made user-writable, then
all three logs are summarized and replayed, then the server shuts down.
Each config builds in its own output base under the per-repeat root, so
configs never share a server. No build follows a replay in the same
output base, so replayed outputs cannot perturb incremental builds.
Builds pass `--materialize_param_files` so `@flagfile` inputs exist at
replay time. Results are stored per config:
`results/<ref>/<config>/<scenario>/rep<N>/`, and the summary reports
medians per config.

Each scenario repeats (`repeats`, default 3); the summary reports medians
with [min, max] spread and head-vs-base deltas (`repeats=1` is called out
as a single sample with no spread). The summary also shows per-mnemonic
replay failure counts (non-zero exit or timeout) and truncation warnings,
so a broken replay can never look like a cost drop. One JSON + one
Markdown file are uploaded as a single artifact (`perf-ios-summary`,
3-day retention). Build outputs are never uploaded.

## Dispatching

Actions > "iOS perf bench" > Run workflow. `head_ref` is required;
`base_ref` defaults to `main`. Keep `target_loc` at the default 500000
unless the 5-hour job timeout is hit, then lower it rather than raising the
timeout. Base and head should share the `rules_dart` pin for a clean
comparison; if they drift, the delta mixes both rule sets.

Rough duration guidance (extrapolation, not a measurement): a 20k-line
Linux smoke builds the shared app kernel in about 80 s; compile cost
scales roughly with lines, so a 500k clean compile lands around the
half-hour mark per config, times two configs, plus fast incremental
rebuilds and serial instruction replay (capped at 30 min per log, 3 h
worst case across 2 refs × 2 configs × 3 scenarios, typically far less).
That fits the 5 h timeout with margin; a 100k dispatch should take
roughly a fifth of the full size. The first successful dispatch
calibrates these numbers; if the job times out, lower `target_loc`.

## `bazel_flags` (A/B experiments, never main points)

Dispatch input `bazel_flags` (string, default empty) carries Bazel flags
separated by whitespace for one run. They apply to the head workspace
only: each flag becomes one `common <flag>` line appended to the
generated head workspace's `.bazelrc`, after generation and before any
Bazel command. Compare mode never gives them to base, and sol mode
measures head only. Empty input runs exactly as before (the workspace
is byte-identical, every Bazel command line unchanged); the only
addition is `meta.bazel_flags: []`. With flags, `ios-sol.json`
`meta.bazel_flags` (and compare mode's `summary.json` meta, plus a
`summary.md` line) records the accepted tokens.

Use it for A/B runs of flags that change how a build runs but not which
rules it uses: the opt-in incremental kernel worker
(`--@rules_flutter//flutter:incremental_kernel`, a persistent worker
whose effect only the warm-server edit flows of sol mode can show), or
`--host_compilation_mode=fastbuild` on the debug clean build, where the
exec-configuration C++ build of the Swift worker dominates. Never use
flagged runs as main dashboard points.

Validation (`tools/perf/bench_flags.py`, before anything is generated
or built) accepts only `--<name>` or `--<name>=<value>` where `<name>`
is a plain option name or a Starlark flag label and `<value>` uses only
letters, digits and `_ @ / : . , + = -`, with no whitespace, quotes,
`$`, backtick, `;`, `|`, `&`, `<`, `>`, `\`, `#` or control characters.
One bad token fails the job naming the token. Refused, in `--name` and
`--no<name>` forms because they would change what the bench measures or
where it writes: caches and remote services (`disk_cache`,
`repository_cache`, `remote_*`, `experimental_remote*`, `bes_*`,
`google_*`); locations, logs and profiles (`output_base`,
`output_user_root`, `install_base`, `symlink_prefix`, `profile`,
`generate_json_trace_profile`, `execution_log*`,
`experimental_execution_log*`); rc files and configs (`config`,
`bazelrc`, `ignore_all_rc_files`); module and repository resolution
(`lockfile_mode`, `override_module`, `override_repository`,
`registry`); and startup options the bench owns (`batch`,
`host_jvm_args`, `max_idle_secs`, `output_base`).

Workers in sol mode: when a flag makes Bazel run a chain step in a
persistent worker (the execution log's `runner` names a worker), the
SOL chain still runs that step by hand, one-shot, from its recorded
argv (its params files are in the execroot, via
`--materialize_param_files`, as for any step). The step's CPU, its
byte-identity proof and the ordering rules stay as for any step. The
flow record carries `worker_steps` (chain steps Bazel ran in a worker,
by mnemonic). The warm number counts live descendants (workers) while
the server is up; the server shuts down after each config and on every
error path, so no worker or server outlives its config.

## Speed-of-light (SOL) mode

The performance dashboard compares each developer flow's cost with its best
case: the same SDK tools run by hand for the same edit. Dispatch the same
workflow with `mode=sol` (Actions > "iOS perf bench" > Run workflow >
`mode: sol`); only `head_ref` is checked out, generated and built.

Per configuration (`device_release`, `sim_debug`) and scenario (`clean`,
`app_edit`, `core_edit` — the same edits compare mode applies), `sol`
mode measures two numbers in the same unit, whole-tree user+sys CPU
seconds:

- the Bazel cost: for the `clean` flow, the whole `bazel --batch build`
  process tree (Bazel's own work plus every action), measured with wait4
  rusage deltas, which include reaped descendants on both macOS and Linux.
  Edit flows (`app_edit`, `core_edit`) are measured against a warm server,
  not `--batch` (below). One unit for the whole run. A macOS instruction
  counter cannot do this: `/usr/bin/time -l` reads "instructions retired"
  for its direct child alone (the JVM for a build, the Python driver for a
  chain), so instructions are never the flow number; `unit` in
  `ios-sol.json` is always `cpu_seconds`.
- the SOL cost: the minimal chain of the same tool binaries Bazel ran
  for that scenario, taken from that build's execution log (kernel
  compile, gen_snapshot, assembler/linker, bundling steps, with the same
  flags and inputs), run by hand in order. The SOL number is the sum of
  the chain steps' own process-tree CPU — the driver's own cost
  (loading the log, hashing, moving files) is never included. Steps
  whose outputs did not change for the edit are skipped as a person
  would skip them: the execution log records executed spawns only, so
  replaying it replays exactly the work the edit required. Edit flows
  run the chain from the warm-server build's execution log, exactly as
  clean flows run it from the `--batch` build's log.

The clean flow is a cold measurement: one `bazel --batch build` with no
server, so its cost includes Bazel startup and full analysis. Edit flows
are warm measurements: after the clean chain and host-tools replay have
restored Bazel's outputs, a server starts on the same output base (same
startup options minus `--batch`), and one unmeasured warm-up build of
the same target and flags must execute zero actions — otherwise the
config fails, because the outputs were perturbed and the edit would not
measure an incremental build. Each edit scenario then applies its
cumulative edit and builds through that warm server. While the server
is up every Bazel command on that output base goes through it, never
`--batch`; the server shuts down after the config's last flow and on
every error path, so no server outlives its config.

The warm number (`tools/perf/warm_server.py`, usable by any other bench)
is the CPU growth of the whole process tree for the one measured
client command: the waiting client's own CPU, the server's own CPU
growth, the server's reaped-children growth, and the growth of the
server's live descendant tree (a child that appears mid-command is
counted from zero). It fails closed — missing server, a server that
restarted under the same pid, or an unreadable sample is a config error,
never a number. Known limit: a descendant that exits and is already
reaped when the command ends contributes its whole-life CPU through the
parent's reaped-children time, so the split across parts is approximate
while their sum is exact. Edit flows record `method: "warm-server"` and
the per-part breakdown as `bazel_parts`; clean flows record
`method: "batch"` with no breakdown. The `profile.jvm` counter covers
the same trace whether the build ran batched or through the server, and
the residual still excludes all server time, so for a warm flow the
residual is mostly JVM launch and analysis-cache warmth the trace
counter never sees.

Chain selection is output-based: a host-tool build is a spawn whose
declared outputs land in an exec configuration
(`bazel-out/*-exec-*/`, or Bazel 9's default with no `-ST-<hash>`
suffix, `bazel-out/*-exec/`), and only those are left out (building
Bazel's helper tools is part of the gap). Every other executed spawn
runs, whatever tool binary it invokes — an action that runs an
exec-built tool to produce target-configuration outputs (the kernel
compile, for example) belongs in the chain. Command arguments never
classify: they name the tool that runs, not what is built. (Compare
mode's replay allowlist is unchanged.)

Proof the SOL did the same work cannot pass by accident: each chain
step runs as Bazel runs it — its declared outputs are removed before
it starts, so merge-style steps cannot see stale inputs — and steps
run in dependency order even for edges the execution log never
records: a step whose input (as the log lists it, with symlinks in the
execroot followed) is, or resolves to, another step's declared output
runs after that step, with ties keeping the log order. A step that
would start while one of its inputs is still a moved-aside output no
earlier step re-created is an ordering failure: it never runs, and the
flow reports `identical: false` with a reason naming the step and the
input. Before the chain every declared output of every step that will
run is moved aside. After the chain, whatever the chain wrote at those
paths is removed and Bazel's originals move back, recreating any parent
directory the chain removed; files and directories the chain created
under `bazel-out` that no step declares (an undeclared sibling of a
declared archive, say) are removed as well. This holds whether the
chain succeeded, stopped at a failed step, or wrote different bytes, so
the next incremental build always finds exactly the files Bazel left.
The scenario's verify set comes from declared outputs only, never a
glob over `bazel-out` (whose leftovers are not this build's outputs):
device_release hashes the App.framework binary among the framework
target's listed outputs (`cquery --output=files`); sim_debug hashes
every file in the final app bundle's payload — every entry of each
listed `.ipa` archive, and every file under each listed `.app`
directory (the kernel blob and the App.framework binary are among
those files) — compared by entry path and content, so archive metadata
such as zip timestamps is not part of the proof. A listing with no
bundle fails loudly instead of globbing. A step that exits non-zero,
times out or cannot start — or any verify entry that differs
afterwards — reports `identical: false` with no SOL number, plus the
step (mnemonic, exit, last stderr lines) and the differing entries
(path with before/after digests; at most 10, plus the count). When a
step fails before the final bundle is written, the bundle does not
exist after the chain: that is the same flow verdict (identical false,
no SOL number, the reason naming the failed step and the missing
entries), Bazel's outputs are restored as usual, and the run continues
with the next scenario — only a fault in the tool itself fails the
config. An unexpected error in one config records its remaining flows with the
error as their reason, lets the other config run, and still writes and
uploads `ios-sol.json` (the job may fail afterwards). Bazel info/query
output is captured stdout-only (Bazel's stderr carries JVM warnings
that once corrupted a parsed path), and every parsed line must resolve
to an existing path under the output base.

Medians over `repeats` go to one small artifact, `ios-sol.json`:

```json
{
  "rules_flutter": "<full sha>",
  "unit": "cpu_seconds",
  "runner": {"system": "Darwin", "machine": "arm64"},
  "flows": {
    "ios-release-clean": {"bazel": 1, "sol": 1, "identical": true,
                          "reason": "ok",
                          "chain": {"steps": {"Genrule": {"count": 1,
                                                          "cpu_s": 1}},
                                    "skipped": {"host-tool build": 2},
                                    "failed": [],
                                    "ordering_failed": null,
                                    "verify_differ": {"n": 0, "differ": []},
                                    "output_drift": {"n": 0, "paths": []},
                                    "side_effects_removed": {"n": 0,
                                                             "paths": []},
                                    "sol_cpu_s": 1,
                                    "status": "ok"},
                          "spread": {"n": 3, "bazel": [1, 1],
                                     "sol": [1, 1]}}
  }
}
```

Flow ids are `ios-release-{clean,app,body}` (device_release; `body` is
the core_edit) and `ios-debug-{clean,app,body}` (sim_debug). Each flow
carries a small `chain` record — steps run per mnemonic with their CPU
seconds, spawns left out per reason, any failed step, any ordering
failure (step plus the still-moved-aside input), any differing verify
entries (path with both digests; at most 10, plus the count), the
chain-created files removed afterwards, and (information only) the
number of chain-step outputs whose digest differs from the digest the
execution log recorded in `actualOutputs` (with up to 10 such paths) —
with no command lines — and a one-line `reason`, also printed per flow
in the job log, so the artifact alone explains what the SOL ran and why
a flow is not identical. The driver is `tools/perf/sol.py` (`run` / `chain` /
`summarize`; unit tests in `sol_test.py` run on Linux CI from recorded
fixtures, including a `run` -> `chain` -> `summarize` end-to-end pass
against a fake `bazel` in both `--batch` and warm-server modes — the
fake Bazel runs a tiny daemon so the warm tests exercise the real
server start, zero-action warm-up and per-part measurement —
with no time binary present). The warm-server measurement itself is
`tools/perf/warm_server.py` (tests in `warm_server_test.py`: a real
process tree on Linux, macOS conversion math against stubbed system
calls, and fail-closed paths).

The generated workspace (`tools/perf/gen_monorepo.py`) builds the bench
app end to end on the runner with no developer-only setup: its
`.bazelrc` sets `common --lockfile_mode=off` by default, and it
registers only the Flutter toolchain (no LLVM or other dev-only
toolchains).

Each flow also carries a small `profile` record, always on, with no
command lines:

- `jvm`: Bazel's own CPU, from the build's `--profile` JSON trace: the
  "CPU usage (Bazel)" counter (`ph: "C"`, `args.cpu` cores, about one
  sample a second) integrated over time and split at the build-phase
  markers, so `phases` names analysis, execution and the rest. The
  counter starts after JVM launch, so launch CPU lands in `residual`,
  not `jvm`.
- `host_tools`: the chain-excluded host-tool builds, replayed by hand
  under the same wait4 method after the chain restores Bazel's outputs
  (total, per mnemonic, top 10 targets). A host build that fails to
  replay is recorded, not fatal.
- `residual`: `bazel - jvm - sol - host_tools`, never clamped, so the
  parts always sum to the flow's Bazel number. A failed chain has no
  SOL number, and the record says so and substitutes the chain CPU
  instead.

The gzipped trace profiles and execution logs behind each record go to
a second small artifact, `ios-profile` (same 3-day retention, no build
outputs). Medians across repeats recompute the residual from the
medians, so the parts still sum exactly.

## Cost rules (binding)

`workflow_dispatch` only; `macos-15`; job timeout 300 minutes; artifact
retention 3 days; no caches; never upload build outputs; never touch
`ci.yaml` or `full.yaml`. The generator and measurement scripts are the
tooling in `tools/perf/` (Python 3 stdlib only).

## Calibrating the replay set

`tools/perf/replay.py` replays a mnemonic allowlist
(`DEFAULT_IOS_MNEMONICS`: the iOS `Flutter*` actions verified in
`flutter/`, plus best-effort `CppCompile`, `CppLink`, `ObjcCompile`,
`ObjcLink`, `SwiftCompile`, `Lipo`). Every report includes the
executed-but-not-replayed table, so the first dispatch shows exactly which
Apple-side mnemonics (actool, storyboards, codesign, final bundle/link)
were missed; extend the allowlist with `--mnemonic` (workflow) or in the
default set (follow-up commit).

## Testing without macOS

Everything except the Bazel invocation, the replay execution, and the
`time -l` counter runs on Linux:

- `python3 -m unittest discover -s tools/perf -p '*_test.py'`
- Generate a small workspace and analyze it:
  `python3 tools/perf/gen_monorepo.py generate --target-loc 20000
  --rules-flutter <checkout> --out <dir>`, then
  `bazel build //packages/... //app:app //app:app_lib --nobuild` in it.
  All three bench targets must load:
  `bazel query '//app:app_framework + //app:app_ios +
  //app:__app_framework_framework'`. The device_release target goes
  further: `bazel build //app:__app_framework_framework --nobuild -c opt
  --ios_multi_cpus=arm64` completes analysis on Linux (only execution
  needs the Apple SDK). The full `//app:app_ios` analysis fails on Linux
  at Apple toolchain resolution, which is expected — macOS builds it.
