"""Variant-aware expansion of pub package `flutter.assets` entries.

flutter_tools parity for `flutter.pub` spokes (`flutter_pub_package.bzl`):

- A file entry bundles its main file plus every resolution variant living
  in a sibling `<N>x` / `<N.M>x` directory (`_AssetDirectoryCache.variantsFor`
  in `packages/flutter_tools/lib/src/asset.dart`), each inheriting the
  entry's `platforms` / `flavors`. A variant-only entry (main absent) is
  accepted; an entry with neither a main file nor a variant fails the fetch.
- A trailing-slash directory entry bundles the directory's own files plus
  each one's variants. Files in deeper subdirectories are not bundled
  (`listSync()` without recursion in `_parseAssetsFromFolder`).
- Every walk is bounded and fails loudly at the bound instead of silently
  dropping files.

The pure core (`list_files_recursive`, `expand_pub_asset_entries`) works
over caller-provided `readdir` / `list_dir` callables so unit tests drive it
with fakes; the spoke passes context-backed adapters and `fail()`s the
fetch on the returned error, which already names the package and the entry
or directory.
"""

load(":flutter_pub_walk.bzl", "PUB_WALK_BOUND")

# Bound for every asset directory walk. Starlark has no `while`, so every
# walk is a bounded `for`; reaching the bound fails loudly (see
# `walk_bound_error`) instead of silently dropping files. This is the
# shared pub spoke walk bound (`PUB_WALK_BOUND` in `flutter_pub_walk.bzl`),
# kept under its old name so existing loads keep working.
PUB_ASSET_LIST_BOUND = PUB_WALK_BOUND

def is_asset_variant_dir(name):
    """True when `name` is a resolution-variant directory, per flutter_tools.

    Mirrors `_assetVariantDirectoryRegExp` (`/?(\\d+(\\.\\d*)?)x$`, matched
    with `hasMatch`, so only the tail matters): `name` ends in `x` and the
    stem ends in `<digits>` (`2x`) or `<digits>.` (`2.x`, the empty-fraction
    `\\.\\d*` case). E.g. `2x`, `2.0x`, `1.5x` match; `sub`, `foo`, `x` do not.

    Args:
        name: A single directory basename (no slashes).

    Returns:
        True when flutter_tools would treat the directory as variants.
    """
    if len(name) < 2 or not name.endswith("x"):
        return False
    stem = name[:len(name) - 1]
    if stem[len(stem) - 1] in "0123456789":
        return True
    return (
        stem.endswith(".") and
        len(stem) >= 2 and
        stem[len(stem) - 2] in "0123456789"
    )

def walk_bound_error(package_name, directory, bound):
    """The fetch failure for an asset walk that reaches its bound.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and the directory.

    Args:
        package_name: The pub package walked.
        directory: The package-relative directory walked.
        bound: The walk bound reached.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    shown = directory if directory else "."
    return (
        "flutter.pub spoke for \"{pkg}\": asset directory \"{dir}\" holds " +
        "more than {bound} directories; refusing it rather than bundling " +
        "part of the tree."
    ).format(pkg = package_name, dir = shown, bound = bound)

def missing_asset_error(package_name, entry_path):
    """The fetch failure for an asset entry with no main file and no variant.

    Mirrors flutter_tools' `No file or variants found for ...` refusal.
    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package and the entry.

    Args:
        package_name: The pub package the entry comes from.
        entry_path: The entry's `path`, as declared in pubspec.yaml.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": no file or variants found for " +
        "asset \"{entry}\"."
    ).format(pkg = package_name, entry = entry_path)

def asset_entry_problem_error(package_name, problem):
    """The fetch failure for one malformed asset entry condition.

    Returns the message instead of failing so unit tests can assert it; the
    caller `fail()`s with it. Names the package, the entry and the key.

    Args:
        package_name: The pub package the entry comes from.
        problem: A `struct(path, key, detail)` from the asset entry parser;
            `detail` already words the complaint flutter_tools style.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": asset \"{entry}\": {detail}"
    ).format(pkg = package_name, entry = problem.path, detail = problem.detail)

def check_asset_entry_problems(package_name, asset_errors):
    """Fail the spoke fetch on the first malformed asset entry, if any.

    A `platforms` / `flavors` value that is not a list of strings, or an
    entry carrying `transformers`, loads today but contradicts
    flutter_tools; refusing it is a breaking change. Each failure names the
    package, the entry and the key.

    Args:
        package_name: The pub package the entries come from.
        asset_errors: The `asset_errors` of `parse_flutter_assets_block`.

    Returns:
        None; fails the fetch on the first problem.
    """
    for problem in asset_errors:
        fail(asset_entry_problem_error(package_name, problem))

def list_files_recursive(readdir, rel_dir, package_name, bound = PUB_ASSET_LIST_BOUND):
    """Walk `rel_dir` and return every file under it, bounded and loud.

    Args:
        readdir: Callable taking a package-relative directory path and
            returning its immediate children as a list of
            `struct(name, is_dir)`. A missing directory returns [].
        rel_dir: Package-relative directory to walk ("" for the package root).
        package_name: The pub package walked, for the bound failure.
        bound: Maximum directory pops; reaching it with work left returns
            `error` instead of silently truncating. Tests drive this small.

    Returns:
        `struct(files, error)`: `files` holds the package-relative path of
        every file under `rel_dir` ([] on error); `error` is "" or the fetch
        failure naming the package and the directory.
    """
    files = []
    stack = [rel_dir]
    for _ in range(bound):
        if not stack:
            break
        current = stack.pop()
        for child in readdir(current):
            child_rel = child.name if current == "" else current + "/" + child.name
            if child.is_dir:
                stack.append(child_rel)
            else:
                files.append(child_rel)
    if stack:
        return struct(files = [], error = walk_bound_error(package_name, rel_dir, bound))
    return struct(files = files, error = "")

def _split_asset_path(path):
    """Split a package-relative path into `(directory, basename)`.

    Args:
        path: A package-relative file path.

    Returns:
        The `(directory, basename)` tuple; directory is "" for top-level files.
    """
    parent, _, base = path.rpartition("/")
    return (parent, base)

def _conditioned_entry(entry, path):
    """One expanded file inheriting its declaring entry's conditions."""
    return struct(path = path, flavors = entry.flavors, platforms = entry.platforms)

def _variant_files_for(own_path, files):
    """The resolution variants of one bundled file, sorted.

    Mirrors `variantsFor`: same-basename files living exactly one level down
    in a sibling directory whose name matches `is_asset_variant_dir`. Files
    deeper in the tree, or under a non-variant subdirectory, are not variants.

    Args:
        own_path: The package-relative main file (it need not exist: a
            variant-only entry still bundles its variants).
        files: Every file under the entry's parent directory, recursively.

    Returns:
        The sorted variant paths.
    """
    parent, base = _split_asset_path(own_path)
    variants = []
    for candidate in files:
        cand_parent, cand_base = _split_asset_path(candidate)
        if cand_base != base or cand_parent == parent:
            continue
        grandparent, _, vdir = cand_parent.rpartition("/")
        if grandparent != parent or not is_asset_variant_dir(vdir):
            continue
        variants.append(candidate)
    return sorted(variants)

def _expand_directory_entry(entry, scope, expanded):
    """Bundle a trailing-slash entry's own files plus each one's variants.

    Args:
        entry: The parsed entry (`struct(path, flavors, platforms)`).
        scope: `struct(list_dir, package_name)`; `list_dir` takes a directory
            path (no trailing slash) and returns `struct(files, error)` with
            every file under it.
        expanded: The output list to append `struct(path, flavors, platforms)`
            entries to.

    Returns:
        "" or the fetch failure (a walk bound, already naming the package
        and the directory).
    """
    listed = scope.list_dir(entry.path.rstrip("/"))
    if listed.error:
        return listed.error
    own = sorted([f for f in listed.files if _split_asset_path(f)[0] == entry.path.rstrip("/")])
    for main in own:
        expanded.append(_conditioned_entry(entry, main))
        for variant in _variant_files_for(main, listed.files):
            expanded.append(_conditioned_entry(entry, variant))
    return ""

def _expand_file_entry(entry, scope, expanded):
    """Bundle a file entry's main file (when present) plus its variants.

    Args:
        entry: The parsed entry (`struct(path, flavors, platforms)`).
        scope: `struct(list_dir, package_name)`, as in `_expand_directory_entry`.
        expanded: The output list to append to.

    Returns:
        "" or the fetch failure: a walk bound, or `missing_asset_error`
        when neither the main file nor any variant exists.
    """
    parent, _base = _split_asset_path(entry.path)
    listed = scope.list_dir(parent)
    if listed.error:
        return listed.error
    found_main = entry.path in listed.files
    variants = _variant_files_for(entry.path, listed.files)
    if not found_main and not variants:
        return missing_asset_error(scope.package_name, entry.path)
    if found_main:
        expanded.append(_conditioned_entry(entry, entry.path))
    for variant in variants:
        expanded.append(_conditioned_entry(entry, variant))
    return ""

def expand_pub_asset_entries(parsed_assets, list_dir, package_name = ""):
    """Expand parsed `flutter.assets` entries to one struct per bundled file.

    Pure core of the spoke's asset expansion: file entries resolve to their
    main file plus resolution variants (variant-only entries are accepted),
    directory entries to their own files plus each one's variants. Every
    emitted file inherits its declaring entry's `platforms` / `flavors`.

    Args:
        parsed_assets: List of `struct(path, flavors, platforms)` from
            `parse_flutter_assets_block().assets`.
        list_dir: Callable taking a directory path (no trailing slash, ""
            for the package root) and returning `struct(files, error)` with
            every file under it. Tests pass a fake; the spoke passes a
            context-backed lister (see `ctx_package_lister`).
        package_name: The pub package the entries come from, for failures.

    Returns:
        `struct(expanded, error)`: `expanded` holds one
        `struct(path, flavors, platforms)` per bundled file (in declaration
        order, mains before their variants); `error` is "" or the fetch
        failure naming the package and the entry or directory. The caller
        `fail()`s on it.
    """
    scope = struct(list_dir = list_dir, package_name = package_name)
    expanded = []
    for entry in parsed_assets:
        if entry.path.endswith("/"):
            error = _expand_directory_entry(entry, scope, expanded)
        else:
            error = _expand_file_entry(entry, scope, expanded)
        if error:
            return struct(expanded = [], error = error)
    return struct(expanded = expanded, error = "")

def _ctx_readdir(ctx, directory):
    """The immediate children of a spoke directory as `struct(name, is_dir)`."""
    base = ctx.path(directory if directory else ".")
    if not base.exists:
        return []
    return [struct(name = child.basename, is_dir = child.is_dir) for child in base.readdir()]

def ctx_package_lister(ctx, package_name, bound = PUB_ASSET_LIST_BOUND):
    """The spoke's `list_dir` for `expand_pub_asset_entries`, memoized.

    Walks through `list_files_recursive` with the fetch's bound; a walk that
    reaches it fails the fetch naming the package and the directory rather
    than bundling part of the tree. One walk per distinct directory: file
    entries sharing a parent reuse it.

    Args:
        ctx: The spoke's repository context.
        package_name: The pub package walked, for the bound failure.
        bound: Maximum directory pops per walked directory.

    Returns:
        A `list_dir` callable as `expand_pub_asset_entries` takes it.
    """
    cache = {}

    def list_dir(rel_dir):
        """Every file under `rel_dir`, memoized per directory."""
        if rel_dir not in cache:
            cache[rel_dir] = list_files_recursive(
                lambda directory: _ctx_readdir(ctx, directory),
                rel_dir,
                package_name,
                bound,
            )
        return cache[rel_dir]

    return list_dir
