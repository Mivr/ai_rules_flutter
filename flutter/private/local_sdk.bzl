"""Sourcing Flutter repositories from a pre-extracted local Flutter SDK.

A warmed Flutter SDK on disk already holds every artifact the download-mode
repository rules fetch: its `bin/cache` tree is what `flutter precache` (and a
first `flutter build`) materializes from exactly the archives pinned in
`versions.bzl`. The helpers here let each repository rule serve its files out
of that tree instead of the network:

* `resolve_local_sdk_root` turns the user-facing `local_path` (workspace-root
  relative, or absolute) into a repository-space path, watching it so a moved
  SDK refetches.
* `read_local_sdk_version` parses `bin/cache/flutter.version.json`, so the
  version stamping and the version manifest come from the SDK's own bytes
  rather than a table that could drift from them.
* `link_local_dir` / `link_local_file` symlink one repo entry at a SDK
  subtree, failing with the expected SDK-relative path when it is absent, and
  watching the linked tree so edits invalidate the repository.

Every helper fails rather than falling back to the network: a local
repository never downloads.
"""

def resolve_local_sdk_root(repository_ctx, local_path):
    """Resolves a `local_path` toolchain value to a watched SDK root path.

    A relative path resolves against the main workspace root (the directory
    holding the root `MODULE.bazel`), so `local_path = "third_party/flutter"`
    means the same thing on every machine the workspace checks out on. An
    absolute path (POSIX, or a Windows drive path) is used as-is.

    Args:
        repository_ctx: The repository rule context.
        local_path: The user-supplied SDK path string. Must be non-empty.

    Returns:
        The SDK root as a `path` object, watched for changes.
    """
    if not local_path:
        fail("flutter local SDK: no local_path was given; pass the path to a pre-extracted Flutter SDK")
    if local_path.startswith("/") or (len(local_path) > 2 and local_path[1] == ":"):
        sdk_root = repository_ctx.path(local_path)
    else:
        sdk_root = repository_ctx.path(str(repository_ctx.workspace_root) + "/" + local_path)
    repository_ctx.watch(sdk_root)
    return sdk_root

def read_local_sdk_version(repository_ctx, sdk_root):
    """Reads the Flutter version and engine revision from a local SDK.

    Args:
        repository_ctx: The repository rule context.
        sdk_root: The SDK root path, from `resolve_local_sdk_root`.

    Returns:
        `struct(flutter_version, engine_revision)` parsed out of the SDK's own
        `bin/cache/flutter.version.json`.
    """
    manifest = sdk_root.get_child("bin/cache/flutter.version.json")
    if not manifest.exists:
        fail(
            "flutter local SDK: expected bin/cache/flutter.version.json under " +
            str(sdk_root) + ", but it does not exist; point local_path at a " +
            "pre-extracted Flutter SDK (one that has run `flutter precache`)",
        )
    repository_ctx.watch(manifest)
    parsed = json.decode(repository_ctx.read(manifest))
    flutter_version = parsed.get("flutterVersion", "")
    engine_revision = parsed.get("engineRevision", "")
    if not flutter_version or not engine_revision:
        fail(
            "flutter local SDK: bin/cache/flutter.version.json under " +
            str(sdk_root) + " has no flutterVersion/engineRevision; " +
            "it is not a usable Flutter SDK",
        )
    return struct(
        flutter_version = flutter_version,
        engine_revision = engine_revision,
    )

def _check_local_source(repository_ctx, source, sdk_rel, what):
    if not source.exists:
        fail(
            "flutter local SDK: expected {rel} ({what}) under {root}, but it " +
            "does not exist; point local_path at a complete pre-extracted " +
            "Flutter SDK (one that has run `flutter precache`)".format(
                rel = sdk_rel,
                what = what,
                root = str(repository_ctx.attr.local_path),
            ),
        )

def link_local_dir(repository_ctx, sdk_root, sdk_rel, repo_rel, what):
    """Symlinks one repository directory at a local SDK subtree.

    Args:
        repository_ctx: The repository rule context.
        sdk_root: The SDK root path, from `resolve_local_sdk_root`.
        sdk_rel: SDK-relative source directory (e.g. `"bin/cache/dart-sdk"`).
        repo_rel: Repository-relative link to create (e.g. `"dart-sdk"`).
        what: Human-readable artifact description for the missing-path error
            (e.g. `"the Flutter-bundled Dart SDK"`).
    """
    source = sdk_root.get_child(sdk_rel)
    _check_local_source(repository_ctx, source, sdk_rel, what)
    repository_ctx.watch_tree(source)
    repository_ctx.symlink(source, repo_rel)

def link_local_file(repository_ctx, sdk_root, sdk_rel, repo_rel, what):
    """Symlinks one repository file at a local SDK file.

    Same contract as `link_local_dir`, for single files (e.g. `flutter.jar`).

    Args:
        repository_ctx: The repository rule context.
        sdk_root: The SDK root path, from `resolve_local_sdk_root`.
        sdk_rel: SDK-relative source file.
        repo_rel: Repository-relative link to create.
        what: Human-readable artifact description for the missing-path error.
    """
    source = sdk_root.get_child(sdk_rel)
    _check_local_source(repository_ctx, source, sdk_rel, what)
    repository_ctx.watch(source)
    repository_ctx.symlink(source, repo_rel)

def engine_cache_dir(artifact_path):
    """Returns the `bin/cache/artifacts/engine` subdirectory holding an artifact.

    Mirrors flutter_tool's `Cache` layout (`flutter_cache.dart` binary-dir
    tables): each `[dir, file]` pair extracts `file` into `engine/<dir>/`, and
    `dir` is always the artifact path minus its filename
    (`android-arm64-release/linux-x64.zip` lives in
    `engine/android-arm64-release/linux-x64/`; `darwin-x64/artifacts.zip` in
    `engine/darwin-x64/`). Bare filenames (`flutter_patched_sdk.zip`) extract
    into `engine/common/`.

    Args:
        artifact_path: GCS artifact path (e.g. `"ios-release/artifacts.zip"`).

    Returns:
        The cache subdirectory relative to `bin/cache/artifacts/engine`.
    """
    parts = artifact_path.split("/")
    if len(parts) == 1:
        return "common"
    return "/".join(parts[:-1])

def copy_local_file(repository_ctx, src, dst, what):
    """Stages one SDK file as a repo-owned copy, without network or listing.

    Symlinks cannot be patched or rewritten in place without writing through
    into the user's SDK tree, so files the fetch must modify (the dartdev AOT
    snapshot, the gen-l10n subset) are copied instead. The destination's parent
    directories must already exist (a `repository_ctx.file` placeholder creates
    them).

    Args:
        repository_ctx: The repository rule context.
        src: Absolute source path string inside the local SDK.
        dst: Absolute destination path string inside the repository.
        what: Human-readable description for the failure message.
    """
    if "windows" in repository_ctx.os.name.lower():
        result = repository_ctx.execute([
            "cmd",
            "/c",
            "copy",
            "/y",
            src.replace("/", "\\"),
            dst.replace("/", "\\"),
        ])
    else:
        result = repository_ctx.execute(["cp", src, dst])
    if result.return_code != 0:
        fail("flutter local SDK: could not stage {what} ({src}); {err}".format(
            what = what,
            src = src,
            err = result.stderr.strip(),
        ))
