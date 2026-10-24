# Incremental kernel compiles

`rules_flutter` can keep the Dart `frontend_server` warm across debug
compiles instead of starting a cold one per build. The finished kernel is
canonically equal either way: the worker always ends with **rule F**, a
`reset` followed by an empty `recompile`, so the output dill comes from a
compile that compiled nothing and carries no history. The worker output is
the unlinked app component (no `dart:` platform link, no call-site metadata
hint payloads); the stock batch output links the platform libraries and
carries `vm.call-site-attributes.metadata`. Canonical check on
`e2e/hello_world`: `canon(platform_strong.dill + F) ==
canon_strip_md(batch)` is byte-equal (53,175,968 bytes both sides; all 739
app libraries and all 1,051 sources identical, same `main`). Only the
second and later builds go faster; the first compile of a configuration
pays the cold cost.

## Turning it on

```sh
bazel build --@rules_flutter//flutter:incremental_kernel //app:app
```

The flag is a `bool_flag` defaulting to `False`. Turning it off again (or
just omitting it) restores the stock one-shot action: with the flag off the
`FlutterKernelCompile` actions are byte-identical to a build without the
flag, so remote and local caches keep hitting.

## Scope

JIT whole-program compiles only (`target == "flutter"`, non-AOT, in any
compilation mode — the predicate has deliberately no `-c` condition). The
flag never applies to AOT, web (`dartdevc`), `from_dill`,
`import_dill` or `recorded_uses` compiles — those always run the stock
action. The guard and read-set checks enforce the same manifest-only policy
as the stock `kernel_filter` path — allowances come only from the
`--declared-inputs` manifest, never from the compiler argv — with identical
refusal messages. The worker deletes its `incr_fkc_*` temp directories on
every exit path, so no state survives a finished build. A worker that is
killed outright cannot run that cleanup, so every starting worker also
reclaims the scratch of workers that are no longer alive (kept alive-proof
by an exclusive lock file each worker holds for its life, published
atomically so it never exists unlocked: a starting worker opens each
sibling's lock read-only and attempts a shared lock in process, and only
an acquired lock means dead — never age or PID).

## Strategies

The compile runs through `incr_fkc_worker`, a Bazel JSON persistent worker
built from Dart (no host Python, no new downloads):

- `worker` strategy: Bazel keeps the worker process alive, and the worker
  keeps one warm `frontend_server` per distinct compiler configuration
  (argv minus the output path). Repeated builds recompile only the changed
  libraries. Staged `org-dartlang-app` deltas recompile by URI; any other
  changed input restarts that server cold. Servers that fail, or whose
  process dies, restart cold on the next request.
- `sandboxed` / `local` / `remote` strategies: the same binary runs once
  per action (a fresh process that compiles cold, then applies rule F), so
  the output is identical without any persistent state.

Each worker keeps at most one warm server by default. One warm server holds
about 1.75 GiB of compiler state, so on small machines bound the worker
processes with `--worker_max_instances=FlutterKernelCompile=N`
(`INCR_FKC_MAX_SERVERS=M` raises the per-worker server cap instead, at
~1.75 GiB per server).

## Errors

A compile error, a guard refusal, or an undeclared read fails the build
with the compiler's diagnostics (or the refusal text), exactly as the
stock action would. The next build resumes from the last accepted state:
rejected recompiles are repaired by recompiling the same URIs again, so
fixing the error and rebuilding converges without a cold restart unless an
input outside the staged sources changed.
