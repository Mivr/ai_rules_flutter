"""The `swiftpm_package` repository rule: one fetched SwiftPM spoke.

Each SwiftPM pin in `Package.resolved` becomes a `<hub>__swiftpm-<identity>`
repo holding the pinned sources and a generated BUILD file. The fetch is
fail-closed throughout: an unpinned entry fails before any download (naming
the `swift_package_sha256` fix), the archive must hold one top-level
directory with the plain `Package.swift` manifest, and every source
refusal from the translator fails here. A `swift_package_build_files`
override still downloads the pinned archive but skips the translation,
writing the hand-written file as-is.
"""

load(":download.bzl", "pinned_download_and_extract")
load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND", "has_files_bound_error")
load(":swiftpm_clang.bzl", "swiftpm_clang_module_spec", "swiftpm_generated_modulemap_content")
load(":swiftpm_manifest.bzl", "parse_swiftpm_package")
load(
    ":swiftpm_translate.bzl",
    "swiftpm_c99name",
    "swiftpm_reachable_targets",
    "translate_swiftpm_package",
)

_SWIFTPM_DEFAULT_DIRS = ["Sources", "Source", "src", "srcs"]

def _swiftpm_repo_fail(identity, detail):
    """The fetch failure for fetch-level (non-manifest) refusals.

    Args:
        identity: The SwiftPM package identity.
        detail: What was found and why it is unsupported.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return "SwiftPM package {identity}: {detail}.".format(identity = repr(identity), detail = detail)

def _swiftpm_check_entry(identity, target_name, entry, kind):
    """Refuse an exclude/sources entry that could escape the target dir.

    Args:
        identity: The SwiftPM package identity.
        target_name: The target holding the entry, for messages.
        entry: The manifest entry string.
        kind: `"exclude:"` or `"sources:"`, for messages.

    Returns:
        "" or the fetch failure.
    """
    for segment in entry.split("/"):
        if segment == "" or segment == "." or segment == "..":
            return _swiftpm_repo_fail(identity, "target {target} has an {kind} entry {entry} escaping the target directory".format(target = repr(target_name), kind = kind, entry = repr(entry)))
    return ""

def _swiftpm_package_root(ctx, identity):
    """Read the archive's single top-level directory as the package root.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.

    Returns:
        `struct(ok, error, root)`: `root` is the repo-relative directory.
    """
    children = ctx.path(".").readdir()
    dirs = [child.basename for child in children if child.is_dir]
    if len(children) != 1 or len(dirs) != 1:
        shown = sorted([child.basename for child in children])
        if len(shown) > 8:
            shown = shown[:8] + ["... ({count} entries)".format(count = len(children))]
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "expected the archive to hold one top-level directory (the package root), got {entries}".format(entries = shown)), root = "")
    return struct(ok = True, error = "", root = dirs[0])

def _swiftpm_manifest_filename(ctx, identity, root):
    """Require the plain `Package.swift` manifest at the package root.

    A versioned `Package@swift-*.swift` sitting next to it fails the
    fetch naming it: the translator reads only the plain manifest, and
    silently ignoring a versioned sibling could build stale sources.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        root: The repo-relative package root.

    Returns:
        `struct(ok, error, filename)`: the manifest basename.
    """
    if not ctx.path(root + "/Package.swift").exists:
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "no `Package.swift` manifest at the archive top level"), filename = "")
    versioned = [child.basename for child in ctx.path(root).readdir() if not child.is_dir and child.basename.startswith("Package@swift-") and child.basename.endswith(".swift")]
    if versioned:
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "versioned manifest(s) ({names}) sit next to `Package.swift`: only the plain manifest is translated, so remove them or point at a hand-written BUILD file with swift_package_build_files[{identity}]".format(names = sorted(versioned), identity = repr(identity))), filename = "")
    return struct(ok = True, error = "", filename = "Package.swift")

def _swiftpm_resolve_target_dir(ctx, identity, root, target):
    """Resolve one reached target's directory.

    An explicit `path:` must name an existing directory inside the package
    root; otherwise the first existing `Sources/<name>`, `Source/<name>`,
    `src/<name>` or `srcs/<name>` wins.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        root: The repo-relative package root.
        target: The target struct.

    Returns:
        `struct(ok, error, rel_dir)`: the repo-relative directory.
    """
    if target.path:
        bad = _swiftpm_check_entry(identity, target.name, target.path, "`path:`")
        if bad:
            return struct(ok = False, error = bad, rel_dir = "")
        rel_dir = root + "/" + target.path
        node = ctx.path(rel_dir)
        if not node.exists or not node.is_dir:
            return struct(ok = False, error = _swiftpm_repo_fail(identity, "target {target} names a missing directory in `path:` ({dir})".format(target = repr(target.name), dir = repr(target.path))), rel_dir = "")
        return struct(ok = True, error = "", rel_dir = rel_dir)
    for base in _SWIFTPM_DEFAULT_DIRS:
        rel_dir = root + "/" + base + "/" + target.name
        node = ctx.path(rel_dir)
        if node.exists and node.is_dir:
            return struct(ok = True, error = "", rel_dir = rel_dir)
    return struct(ok = False, error = _swiftpm_repo_fail(identity, "target {target} has no `path:` and none of {dirs} exist".format(target = repr(target.name), dirs = [base + "/" + target.name for base in _SWIFTPM_DEFAULT_DIRS])), rel_dir = "")

_SWIFTPM_CODE_EXTENSIONS = {
    "c": True,
    "cc": True,
    "cpp": True,
    "cxx": True,
    "m": True,
    "mm": True,
    "h": True,
    "hh": True,
    "hpp": True,
    "inc": True,
    "s": True,
    "S": True,
}

_SWIFTPM_HEADER_SUFFIXES = [".h", ".hh", ".hpp", ".hxx", ".inc"]

_SWIFTPM_CLANG_SOURCE_SUFFIXES = [".c", ".cc", ".cpp", ".cxx", ".c++", ".C", ".cp", ".m", ".mm", ".M", ".s", ".S", ".asm"]

def _swiftpm_file_kind(basename):
    """Sort one filename into Swift, C-family, header, module map or skip.

    Args:
        basename: The file's basename (no directory).

    Returns:
        `"swift"`, `"clang"`, `"header"`, `"modulemap"` or `"skip"`.
        Any other file with no Bazel translation — READMEs, licenses,
        notes, images, DocC input — is skipped the way SwiftPM ignores
        unhandled files with a warning.
    """
    if basename.endswith(".swift"):
        return "swift"
    if basename == "module.modulemap":
        return "modulemap"
    for suffix in _SWIFTPM_HEADER_SUFFIXES:
        if basename.endswith(suffix):
            return "header"
    for suffix in _SWIFTPM_CLANG_SOURCE_SUFFIXES:
        if basename.endswith(suffix):
            return "clang"
    return "skip"

def swiftpm_is_code_file(basename):
    """Whether a non-Swift filename is C-family code, a header or a module map.

    The target file selector translates these instead of skipping them
    the way it skips files with no Bazel translation (READMEs, licenses,
    notes, images, DocC input), which SwiftPM ignores with a warning.

    Args:
        basename: The file's basename (no directory).

    Returns:
        True for C-family sources and headers plus module maps.
    """
    if basename.endswith(".modulemap"):
        return True
    dot = basename.rfind(".")
    if dot < 0:
        return False
    return basename[dot + 1:] in _SWIFTPM_CODE_EXTENSIONS

def _swiftpm_is_under(full, roots):
    """Whether a repo-relative path is one of `roots` or sits under one.

    Args:
        full: The repo-relative path.
        roots: The repo-relative root paths (a list).

    Returns:
        True on an exact or `/`-boundary prefix match.
    """
    for root in roots:
        if full == root or full.startswith(root + "/"):
            return True
    return False

def _swiftpm_under_docc(rel):
    """Whether a target-relative path sits inside a DocC catalog directory.

    SwiftPM ignores `<Name>.docc` catalogs by rule, so their contents are
    skipped like any other file with no translation.

    Args:
        rel: The path relative to the target directory.

    Returns:
        True when any leading directory segment ends in `.docc`.
    """
    segments = rel.split("/")
    for segment in segments[:len(segments) - 1]:
        if segment.endswith(".docc"):
            return True
    return False

def _swiftpm_keep_existing(identity, target_name, kind, entries, rel_dir, tree):
    """Drop entries naming nothing on disk, fail entries escaping the dir.

    Args:
        identity: The SwiftPM package identity.
        target_name: The target holding the entries, for messages.
        kind: "`exclude:`" or "`sources:`", for messages.
        entries: The manifest entry strings.
        rel_dir: The repo-relative target directory.
        tree: The `struct(files, dirs)` listing from
            `_swiftpm_list_target_tree`.

    Returns:
        `struct(ok, error, kept)`: the repo-relative paths that exist.
    """
    kept = []
    for entry in entries:
        bad = _swiftpm_check_entry(identity, target_name, entry, kind)
        if bad:
            return struct(ok = False, error = bad, kept = [])
        full = rel_dir + "/" + entry
        if full in tree.files or full in tree.dirs:
            kept.append(full)
    return struct(ok = True, error = "", kept = kept)

def _swiftpm_split_headers(identity, target, rel_dir, headers, files, dirs):
    """Split headers into public and private, and find the explicit map.

    The module map search follows SwiftPM's `ClangTarget.moduleMapPath`
    order: `module.modulemap` at the target root wins; otherwise the
    public-headers directory (`include/` by default, `publicHeadersPath`
    when set). A `publicHeadersPath` makes the headers under it public; otherwise the
    headers under `include/` are public when that directory exists, else
    (a single-directory layout) the headers at the target root are.
    Every other header is private: it still compiles, but Swift
    importers do not see it.

    Args:
        identity: The SwiftPM package identity.
        target: The target struct (`name`, `public_headers_path`).
        rel_dir: The repo-relative target directory.
        headers: The repo-relative header files.
        files: Every file under the target directory (a dict set of
            repo-relative paths).
        dirs: Every directory under the target directory (a dict set of
            repo-relative paths).

    Returns:
        `struct(ok, error, public_hdrs, private_hdrs, explicit_map,
        map_in_include)`: `explicit_map` is the repo-relative explicit
        map or None; `map_in_include` when it lives under the
        public-headers directory rather than the target root.
    """
    if target.public_headers_path:
        bad = _swiftpm_check_entry(identity, target.name, target.public_headers_path, "`publicHeadersPath:`")
        if bad:
            return struct(ok = False, error = bad, public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False)
        public_root = rel_dir + "/" + target.public_headers_path
        public_hdrs = [header for header in headers if header.startswith(public_root + "/")]
        private_hdrs = [header for header in headers if not header.startswith(public_root + "/")]
        root_map = rel_dir + "/module.modulemap"
        public_map = public_root + "/module.modulemap"
        explicit_map = None
        map_in_include = False
        if root_map in files:
            explicit_map = root_map
        elif public_map in files:
            explicit_map = public_map
            map_in_include = True
        return struct(ok = True, error = "", public_hdrs = sorted(public_hdrs), private_hdrs = sorted(private_hdrs), explicit_map = explicit_map, map_in_include = map_in_include)
    include_dir = rel_dir + "/include"
    if include_dir in dirs:
        public_hdrs = [header for header in headers if header.startswith(include_dir + "/")]
        private_hdrs = [header for header in headers if not header.startswith(include_dir + "/")]
    else:
        public_hdrs = [header for header in headers if "/" not in header[len(rel_dir) + 1:]]
        private_hdrs = [header for header in headers if "/" in header[len(rel_dir) + 1:]]
    root_map = rel_dir + "/module.modulemap"
    include_map = include_dir + "/module.modulemap"
    explicit_map = None
    map_in_include = False
    if root_map in files:
        explicit_map = root_map
    elif include_map in files:
        explicit_map = include_map
        map_in_include = True
    return struct(ok = True, error = "", public_hdrs = sorted(public_hdrs), private_hdrs = sorted(private_hdrs), explicit_map = explicit_map, map_in_include = map_in_include)

def swiftpm_select_target_files(identity, target, rel_dir, files, dirs):
    """Select one reached target's Swift and C-family files, purely.

    `exclude:` and `sources:` entries that escape the target directory fail
    the fetch; entries naming nothing on disk drop out, the way SwiftPM warns
    and builds with the files that exist. Every remaining file under the
    target directory contributes its `.swift` sources, its C-family sources
    and headers (split into public and private, with the explicit module
    map when the target ships one), except DocC catalog contents and other
    files with no Bazel translation, which are skipped.

    Args:
        identity: The SwiftPM package identity.
        target: The target struct (`name`, `exclude`, `sources`,
            `public_headers_path`).
        rel_dir: The repo-relative target directory.
        files: Every file under the target directory (a dict set of
            repo-relative paths).
        dirs: Every directory under the target directory (a dict set of
            repo-relative paths).

    Returns:
        `struct(ok, error, srcs, c_srcs, public_hdrs, private_hdrs,
        explicit_map, map_in_include)`: the sorted repo-relative paths;
        `explicit_map` is None unless the target ships one.
    """
    excluded = _swiftpm_keep_existing(identity, target.name, "`exclude:`", target.exclude, rel_dir, struct(files = files, dirs = dirs))
    if not excluded.ok:
        return struct(ok = False, error = excluded.error, srcs = [], c_srcs = [], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False)
    listed = None
    if target.sources != None:
        narrowed = _swiftpm_keep_existing(identity, target.name, "`sources:`", target.sources, rel_dir, struct(files = files, dirs = dirs))
        if not narrowed.ok:
            return struct(ok = False, error = narrowed.error, srcs = [], c_srcs = [], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False)
        listed = narrowed.kept
    srcs = []
    c_srcs = []
    headers = []
    for full in files.keys():
        if _swiftpm_is_under(full, excluded.kept):
            continue
        if listed != None and not _swiftpm_is_under(full, listed):
            continue
        rel = full[len(rel_dir) + 1:]
        if _swiftpm_under_docc(rel):
            continue
        kind = _swiftpm_file_kind(full[full.rfind("/") + 1:])
        if kind == "swift":
            srcs.append(full)
        elif kind == "clang":
            c_srcs.append(full)
        elif kind == "header":
            headers.append(full)
    if not srcs and not c_srcs:
        return struct(ok = False, error = _swiftpm_repo_fail(identity, "target {target} reaches zero Swift files".format(target = repr(target.name))), srcs = [], c_srcs = [], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False)
    split = _swiftpm_split_headers(identity, target, rel_dir, headers, files, dirs)
    if not split.ok:
        return struct(ok = False, error = split.error, srcs = [], c_srcs = [], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False)
    return struct(ok = True, error = "", srcs = sorted(srcs), c_srcs = sorted(c_srcs), public_hdrs = split.public_hdrs, private_hdrs = split.private_hdrs, explicit_map = split.explicit_map, map_in_include = split.map_in_include)

def _swiftpm_list_target_tree(ctx, identity, rel_dir):
    """List every file and directory under one target directory, bounded.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        rel_dir: The repo-relative target directory.

    Returns:
        `struct(ok, error, files, dirs)`: dict sets of repo-relative paths.
    """
    files = {}
    dirs = {}
    stack = [rel_dir]
    for _ in range(PUB_WALK_BOUND):
        if not stack:
            break
        current = stack.pop()
        for child in ctx.path(current).readdir():
            full = current + "/" + child.basename
            if child.is_dir:
                dirs[full] = True
                stack.append(full)
            else:
                files[full] = True
    if stack:
        return struct(ok = False, error = has_files_bound_error(identity, rel_dir, PUB_WALK_BOUND), files = {}, dirs = {})
    return struct(ok = True, error = "", files = files, dirs = dirs)

def _swiftpm_collect_sources(ctx, identity, root, target):
    """Resolve one reached target's directory and explicit file lists.

    Args:
        ctx: The repository context.
        identity: The SwiftPM package identity.
        root: The repo-relative package root.
        target: The target struct.

    Returns:
        `struct(ok, error, files)`: `files` is `struct(dir, srcs, c_srcs,
        public_hdrs, private_hdrs, explicit_map, map_in_include)` with
        the repo-relative directory, Swift sources, C-family sources,
        headers and explicit module map.
    """
    resolved = _swiftpm_resolve_target_dir(ctx, identity, root, target)
    if not resolved.ok:
        return struct(ok = False, error = resolved.error, files = None)
    listed = _swiftpm_list_target_tree(ctx, identity, resolved.rel_dir)
    if not listed.ok:
        return struct(ok = False, error = listed.error, files = None)
    selected = swiftpm_select_target_files(identity, target, resolved.rel_dir, listed.files, listed.dirs)
    if not selected.ok:
        return struct(ok = False, error = selected.error, files = None)
    return struct(ok = True, error = "", files = struct(dir = resolved.rel_dir, srcs = selected.srcs, c_srcs = selected.c_srcs, public_hdrs = selected.public_hdrs, private_hdrs = selected.private_hdrs, explicit_map = selected.explicit_map, map_in_include = selected.map_in_include))

def _swiftpm_write_generated_map(identity, target, files):
    """Write one C-family target's generated umbrella module map, if any.

    Targets shipping an explicit `module.modulemap`, or with no public
    headers at all (link-only), need no map. Anything else gets
    `<umbrella>/module.modulemap` covering its public headers, which the
    translated `cc_library`/`objc_library` points at through
    `swift_interop_hint`.

    Args:
        identity: The SwiftPM package identity.
        target: The target struct.
        files: The collected files struct from `_swiftpm_collect_sources`.

    Returns:
        `struct(ok, error, path, content)`: `path` is "" when the target
        needs no generated map.
    """
    if not files.c_srcs or files.explicit_map != None:
        return struct(ok = True, error = "", path = "", content = "")
    spec = swiftpm_clang_module_spec(target, files.dir, files.c_srcs, files.public_hdrs, None)
    if not spec.ok:
        return struct(ok = False, error = _swiftpm_repo_fail(identity, spec.detail), path = "", content = "")
    if spec.module_map == None:
        return struct(ok = True, error = "", path = "", content = "")
    return struct(ok = True, error = "", path = spec.module_map, content = swiftpm_generated_modulemap_content(swiftpm_c99name(target.name), spec.umbrella_dir, files.public_hdrs))

def _swiftpm_package_impl(ctx):
    identity = ctx.attr.identity
    if ctx.attr.unpinned_error:
        fail(ctx.attr.unpinned_error)
    pinned_download_and_extract(ctx, url = ctx.attr.archive_url, sha256 = ctx.attr.sha256)
    if ctx.attr.build_file:
        ctx.file("BUILD.bazel", ctx.read(ctx.path(ctx.attr.build_file)))
        return
    root = _swiftpm_package_root(ctx, identity)
    if not root.ok:
        fail(root.error)
    manifest = _swiftpm_manifest_filename(ctx, identity, root.root)
    if not manifest.ok:
        fail(manifest.error)
    parsed = parse_swiftpm_package(identity, ctx.read(root.root + "/" + manifest.filename))
    if not parsed.ok:
        fail(parsed.error)
    reached = swiftpm_reachable_targets(identity, parsed.model, ctx.attr.pin_identities, ctx.attr.hub_name)
    if not reached.ok:
        fail(reached.error)
    by_name = {target.name: target for target in parsed.model.targets}
    files_by_target = {}
    for name in reached.names:
        collected = _swiftpm_collect_sources(ctx, identity, root.root, by_name[name])
        if not collected.ok:
            fail(collected.error)
        files_by_target[name] = collected.files
        generated = _swiftpm_write_generated_map(identity, by_name[name], collected.files)
        if not generated.ok:
            fail(generated.error)
        if generated.path:
            ctx.file(generated.path, generated.content)
    translated = translate_swiftpm_package(identity, ctx.attr.hub_name, parsed.model, ctx.attr.pin_identities, files_by_target)
    if not translated.ok:
        fail(translated.error)
    ctx.file("BUILD.bazel", translated.text)

swiftpm_package = repository_rule(
    implementation = _swiftpm_package_impl,
    doc = "One fetched SwiftPM spoke: the pinned GitHub archive plus a BUILD file translated from its plain `Package.swift`, or the `swift_package_build_files` override.",
    attrs = {
        "archive_url": attr.string(doc = "The pinned archive URL to download (always downloaded, even with a build_file override)."),
        "build_file": attr.label(allow_single_file = True, doc = "Label of a hand-written BUILD file replacing the generated one; Bazel resolves it in the module that wrote the flutter.pub tag. None (the default) translates the manifest. Skips the translation only, not the download."),
        "hub_name": attr.string(mandatory = True, doc = "The flutter.pub hub name, for cross-package dep labels."),
        "identity": attr.string(mandatory = True, doc = "The SwiftPM package identity (the spoke suffix)."),
        "pin_identities": attr.string_list(doc = "Every identity pinned in Package.resolved, for dependency resolution."),
        "sha256": attr.string(doc = "The pinned SHA-256 of the archive (empty when unpinned, which fails before downloading)."),
        "unpinned_error": attr.string(default = "", doc = "The fetch failure for an unpinned entry; failing first keeps unpinned bytes out."),
    },
)
