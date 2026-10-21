# Dependencies

Which Bazel modules `rules_flutter` pulls into a consumer's graph, for which
feature, and what each costs. Floors below are what this repo's `MODULE.bazel`
declares; higher versions resolve by MVS as usual, except where noted.

## By feature

| Feature | Modules | Notes |
|---|---|---|
| Every app | `rules_dart` 0.7.3 (plus the `git_override` to the `Mivr` fork), `bazel_skylib`, `platforms`, `package_metadata` | Dart compilation, hooks, codegen. |
| iOS / macOS bundles | `rules_apple` ≥ 4.5.3, `rules_swift`, `apple_support`, `rules_cc` | 4.5.3 is the proven floor: `e2e/min_versions` pins it exactly and builds both Apple legs. `rules_swift`/`apple_support` float to the graph's maxima (4.5.3 accepts Swift at compatibility level 3). |
| Android APK | `rules_android` 0.8.0, `rules_kotlin`, `rules_java`, `rules_jvm_external` 7.1, `rules_go` ≥ 0.59.0 | 0.8.0 is the floor (see below). `rules_go` stays a regular dependency because the Android proxy transition sets `go/config:pure`, which must resolve in every consumer; Android apps should also copy the pinned `go_sdk.download` block from `MODULE.bazel` (as `e2e/hello_world` does). |
| xtool Darwin backend (opt-in) | `llvm` 0.8.19, exec-host toolchain archive only | Needs only `flutter.darwin_sdk(url = ..., sha256 = ...)` or `flutter.darwin_sdk(path = ...)` in the root module — no other `MODULE.bazel` lines. Plain consumers fetch nothing (see below). |
| Dev tool, `gen_l10n` | Resolved inside `rules_flutter` | `dev_tool_deps` and `gen_l10n_deps` are the ruleset's own `flutter.pub` hubs; consumers never name them. |
| No feature | No `rules_python` | The iOS screenshot/tunnel helpers are `dart_binary` drivers over a host `python3` (a documented host prerequisite like Xcode), so neither this repo's graph nor any consumer's contains `rules_python` from us. |

## The version-floor trade-off

Bazel's MVS picks the *maximum* of the versions in the graph, so a floor is a
promise ("works at this version or newer"), not a pin. A consumer that names
no version of a module gets our floor — and the floor's own transitive
deps, which may be *older and heavier* than the current release's:

- An unpinned consumer resolves `rules_apple` 4.5.3, not 5.2.0 (that is what
  a plain consumer graph selects today). This repo's own builds stay on
  5.2.0 via a root-only `single_version_override` (consumers ignore that
  line), and `e2e/min_versions` pins 4.5.3 exactly to prove the floor
  builds. Flooring Apple selects its older transitive pins too, so if you
  want the newer Apple tree, add your own `bazel_dep(name = "rules_apple",
  version = "5.2.0")`: MVS then selects 5.2.0 for everyone, at the cost of
  tracking Apple's releases yourself.
- `rules_android` stays at 0.8.0 with no lower option: the signing overlay
  reads `@rules_android//flags:apk_signing_method`, and that package exists
  only in 0.8.0+ (0.7.2 and 0.7.3 have no `flags/` directory at all), so
  every Android app fails at analysis with anything older. There is no
  version-tolerant way to read their flag.
- `rules_go` floors at 0.59.0 — the lowest rules_go that builds on Bazel 9
  (0.50.0 through 0.58.3 fail to load: `go/private/rules/cross.bzl` uses the
  native `CcInfo` symbol Bazel 9 removed; the `rules_cc` import landed in
  0.59.0). In practice `rules_android` already imposes the same floor, and
  MVS usually selects much newer (0.64.2 in current graphs).

## Heavy transitive repos, and who brings them

`bazel mod explain <module>` in any consumer workspace prints the chains.
For a plain consumer (e.g. `e2e/smoke`) today:

- `rules_python` arrives via `rules_dart → protobuf → rules_pkg`,
  via `rules_android` (directly, plus through `abseil-py` and
  `rules_robolectric`), via `rules_apple`, via `llvm`, and via
  `re2 → pybind11_bazel`. None of these is `rules_flutter`'s own dep —
  removing ours (done) is all we can do; the rest belongs to those
  rulesets. Its `pypi__*` bootstrap hub repos materialize only when
  something evaluates `rules_python`'s toolchain extension.
- `rules_go` arrives via `rules_dart` (directly and through `gazelle`)
  and via `rules_android`. The `go_toolchains`/`nogo` hub repos belong to
  its `go_sdk` extension. Our own pinned `go_sdk.download` (Go 1.26.2,
  checksummed) is dev-only; Android consumers without their own override
  build host tools with `rules_android`'s bundled Go SDK instead.
- `llvm`'s `bazel_lib`, `rules_shell`, `tar.bzl`, `with_cfg.bzl`,
  `zlib-ng`, `zstd` module deps resolve in the graph but fetch only if
  something references them — for a plain consumer, nothing does.

## What a plain consumer pays for LLVM

`llvm` stays a regular (non-dev) `bazel_dep` because the xtool repo rule
resolves llvm's per-host prebuilt-toolchain repos in `rules_flutter`'s own
repo mapping, and that mapping needs the non-dev edge: `MODULE.bazel` runs
`use_extension("@llvm//extensions:llvm_toolchain_minimal.bzl", ...)` (joining
llvm's own instance, no tags) and `use_repo`s the four
`llvm-toolchain-minimal-<os>-<cpu>` repos. A `Label(...)` built in an
extension implementation cannot see them, and canonical repo names are
unstable across Bazel versions, so the extension passes the four apparent
names as plain strings and the repo rule builds the label itself — only for
the exec host, and only when the root module configured `flutter.darwin_sdk`
(or for this repo's own hermetic-LLVM script tests, which assert the linkage
with no SDK).

Concretely, a consumer that never opts into xtool pays:

- the module-graph edge (`llvm` and its deps appear in `bazel mod deps`)
  and the small `llvm` ruleset-repo fetch (Bazel reads the extension `.bzl`
  during evaluation);
- **no** toolchain-archive download (verified: `@flutter_xtool_darwin_sdk`
  contains no `llvm/` tree for plain consumers, and no
  `llvm-toolchain-minimal-*` repo is fetched);
- **no** C/C++ toolchain registration (the eight `@llvm//toolchain:*`
  registrations are dev-only).

An opting-in consumer configures only the SDK — a nonexistent bundle path
fails the fetch on the path error before any LLVM download starts
(`e2e/xtool_sdk_invalid` pins this red path in CI).
