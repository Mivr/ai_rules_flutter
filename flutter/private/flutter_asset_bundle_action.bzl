"""Shared `flutter_assets/` tree build action.

Leaf module for the action both `flutter_asset_bundle` and the shared asset
bundling step in `//flutter/private:common.bzl` register. Kept apart from the
rule so the rule can load the shader helpers from `common.bzl` without a
load cycle.
"""

load("//flutter/private:asset_uri.bzl", "decode_asset_key")
load("//flutter/private:asset_variants.bzl", "asset_variant_dpr")

def detect_dpr(path):
    """Group an asset key under its own parent directory's resolution variant.

    Mirrors flutter_tools' manifest grouping (3.47.7 `asset.dart:937-963`
    reads the file's immediate parent from `Uri.pathSegments`, and
    `asset.dart:1626` treats any `<number>x` directory as a variant): only
    the parent directory is a variant directory, so `assets/2.5x/a.png`
    groups under `assets/a.png` while `assets/2x/sub/a.png` keeps its own
    key because its parent `sub` is not a variant.

    Args:
        path: Encoded asset path string (e.g. "assets/2.0x/icon.png").

    Returns:
        (base_path, dpr) tuple.  base_path has the parent variant directory
        removed (e.g. "assets/icon.png").  dpr is a float or None when the
        parent directory is not a variant.
    """
    parts = path.split("/")
    if len(parts) < 2:
        return path, None
    dpr = asset_variant_dpr(parts[len(parts) - 2])
    if dpr == None:
        return path, None
    base = "/".join(parts[:len(parts) - 2] + parts[len(parts) - 1:])
    return base, dpr

def _collapse_empty_segments(key):
    """Drop the empty segments of one encoded bundle key.

    Mirrors how flutter_tools reads an entry whose URI keeps an empty
    segment: it keys the manifest by the raw path (`entryUri.path`) but
    opens the collapsed file (the OS resolves `f//fm.png` to `f/fm.png`).
    `a//b.png` collapses to `a/b.png`; a key without empty segments is
    unchanged.

    Args:
        key: The encoded bundle key.

    Returns:
        The key with every empty `/`-separated piece removed.
    """
    return "/".join([part for part in key.split("/") if part != ""])

def _parent_segment_dpr(key):
    """The dpr of one bundle key's own parent directory, if it names one.

    Mirrors the manifest dpr (flutter_tools 3.47.7 `asset.dart:937-963`,
    `_createAssetManifestBinary`): each variant carries the dpr parsed from
    its own parent directory, so the raw spelling of an empty-segment
    entry carries the dpr of the directory it names (`a//2.0x/b.png` is
    dpr 2.0).

    Args:
        key: The encoded bundle key.

    Returns:
        The float dpr, or None when the parent is not a variant directory.
    """
    parts = key.split("/")
    if len(parts) < 2:
        return None
    return asset_variant_dpr(parts[len(parts) - 2])

def _raw_manifest_variants(raw_key, assets):
    """The manifest variants of one raw (`//`-keeping) bundle key.

    Mirrors one flutter_tools manifest entry for an entry whose URI keeps
    an empty segment (`asset.dart:905-975`, `1217-1270`): the raw key
    itself, the collapsed path (its file is what the spoke read, so it
    exists whenever the raw key was emitted), then the collapsed
    directory's variant files present in the bundle, each with the dpr of
    its own parent directory.

    Args:
        raw_key: The encoded bundle key keeping an empty segment.
        assets: Every encoded bundle key, for the variant scan.

    Returns:
        The variant dict list for the raw key's manifest entry.
    """
    collapsed = _collapse_empty_segments(raw_key)
    raw_variant = {"asset": decode_asset_key(raw_key)}
    raw_dpr = _parent_segment_dpr(raw_key)
    if raw_dpr != None:
        raw_variant["dpr"] = raw_dpr
    collapsed_variant = {"asset": decode_asset_key(collapsed)}
    collapsed_dpr = _parent_segment_dpr(collapsed)
    if collapsed_dpr != None:
        collapsed_variant["dpr"] = collapsed_dpr
    variants = [raw_variant, collapsed_variant]
    for path in sorted(assets):
        if path == raw_key or path == collapsed or "" in path.split("/"):
            continue
        base, _stripped = detect_dpr(path)
        if base != collapsed:
            continue
        variant = {"asset": decode_asset_key(path)}
        variant_dpr = _parent_segment_dpr(path)
        if variant_dpr != None:
            variant["dpr"] = variant_dpr
        variants.append(variant)
    return variants

def _dedupe_bundle_keys(assets):
    """One copy of each encoded bundle key, in sorted order.

    The same file reaches the bundle once per declaring entry (two entries
    declaring `a/b.png` both carry `a/2.0x/b.png`), while the copies map
    already collapses to one file per key. Grouping a repeated key twice would list its variant twice; flutter_tools keeps one
    manifest entry per declaration key instead (`asset.dart:905-930`), so a
    repeat contributes nothing.

    Args:
        assets: The encoded bundle keys, possibly with repeats.

    Returns:
        The sorted keys with repeats removed.
    """
    seen = {}
    for path in assets:
        seen[path] = True
    return sorted(seen.keys())

def _collapsed_claims(assets):
    """The raw (`//`-keeping) claimant of each collapsed bundle key.

    One raw key per collapsed path: `build_asset_manifest` lets a
    collapsed file (or its variants) without its own declaration ride its
    claimant's entry instead of gaining a key that would name a file the
    entry did not declare.

    Args:
        assets: Every encoded bundle key.

    Returns:
        dict mapping each collapsed path to its raw claimant key.
    """
    collapsed_of = {}
    for path in sorted(assets):
        if "" in path.split("/"):
            collapsed = _collapse_empty_segments(path)
            if collapsed not in collapsed_of:
                collapsed_of[collapsed] = path
    return collapsed_of

def build_asset_manifest(assets):
    """Build the asset manifest structure from a list of encoded asset keys.

    Mirrors `_createAssetManifest` (flutter_tools 3.47.7 `asset.dart:905-930`):
    the input lists the encoded bundle keys (what the copied files are named,
    `bundle_builder.dart:182`), while every manifest key and variant path is
    `Uri.decodeFull` of its key. Variant grouping still reads the encoded
    keys, as flutter_tools groups by `entryUri.path`. Font assets never reach
    here; FontManifest keeps the encoded `assetUri.path`
    (`flutter_manifest.dart:480`).

    A key keeping an empty segment groups flutter_tools' entry under its
    raw key (see `_raw_manifest_variants`): the raw key, the collapsed
    path, and the collapsed directory's variants, each with its own dpr.
    The collapsed files ride that entry alone and never gain their own key,
    so no key names a file the entry did not declare. Every other key
    groups exactly as before. Each variant carries the dpr parsed from its
    own parent directory. A repeated key groups once: the copies map holds
    one file per key, so a file reached through two declarations still
    contributes one variant (see `_dedupe_bundle_keys`).

    Args:
        assets: list of encoded asset keys relative to the bundle root.
            Repeats collapse to one entry each.

    Returns:
        dict mapping decoded logical key -> list of variant dicts with
        decoded `asset` paths.
    """
    manifest = {}

    # One copy per key: the same file arrives once per declaring entry, but
    # the copies map files it once, so grouping a repeat would list its
    # variant twice.
    assets = _dedupe_bundle_keys(assets)

    # Bundle keys claimed by a raw entry, by collapsed path: a collapsed
    # file (or its variants) without its own declaration rides the raw
    # key's entry instead of gaining one.
    key_set = {path: True for path in assets}
    collapsed_of = _collapsed_claims(assets)

    # Group by base path, sorted by the encoded key as flutter_tools sorts by
    # `entryUri.path`; only the emitted keys and variants are decoded.
    for path in sorted(assets):
        if "" in path.split("/"):
            manifest[decode_asset_key(path)] = _raw_manifest_variants(path, assets)
            continue
        base, dpr = detect_dpr(path)
        if base in collapsed_of and base not in key_set:
            continue
        decoded_base = decode_asset_key(base)
        if decoded_base not in manifest:
            manifest[decoded_base] = []
        entry = {"asset": decode_asset_key(path)}
        if dpr != None:
            entry["dpr"] = dpr
        manifest[decoded_base].append(entry)

    # Ensure the main (1x) variant is first in each list.
    for decoded_base in manifest:
        variants = manifest[decoded_base]
        main_idx = None
        for i, v in enumerate(variants):
            if v["asset"] == decoded_base:
                main_idx = i
                break
        if main_idx != None and main_idx != 0:
            main = variants.pop(main_idx)
            variants.insert(0, main)

    return manifest

def make_bundle_content(assets = [], fonts = [], notices = "", license_files = [], extra_asset_copies = {}):
    """What goes into a `flutter_assets/` bundle.

    Args:
        assets: list of asset entry structs (`struct(key, file, label)`) to
            include in the bundle, each keyed once by the target that listed
            it — relative to its Bazel package, or `packages/<name>/...` for
            a library. The bundle keys every file by its carried `key`.
        fonts: list of font declaration dicts (FontManifest.json schema).
        notices: License text string to compress into NOTICES.Z.
        license_files: list of File objects containing license text to include in NOTICES.Z.
        extra_asset_copies: dict mapping custom dest path → File for assets that
            need a specific destination path (e.g. "fonts/MaterialIcons-Regular.otf").

    Returns:
        A struct with `assets`, `fonts`, `notices`, `license_files` and
        `extra_asset_copies`.
    """
    return struct(
        assets = assets,
        fonts = fonts,
        notices = notices,
        license_files = license_files,
        extra_asset_copies = extra_asset_copies,
    )

def make_tree_shake(dart = None, flutter_sdk_files = None, const_finder = None, font_subset = None, kernel_dill = None, kernel_dills = [], tree_shake_key = ""):
    """The icon tree-shaking toolchain and kernels for a bundle action.

    Every field is None or empty when tree shaking is off; the action then
    registers a plain bundle with no icon step.

    Args:
        dart: The `dart` executable File from the Flutter SDK (only required when icon tree shaking is enabled).
        flutter_sdk_files: SDK files needed to run dart (for action inputs when icon tree shaking is enabled).
        const_finder: File for const_finder.dart.snapshot (enables icon tree shaking).
        font_subset: File for font-subset binary (enables icon tree shaking).
        kernel_dill: File for the compiled kernel .dill (needed for icon tree shaking).
        kernel_dills: Optional list of compiled kernel .dill Files when icon tree
            shaking unions code points across multiple shipped builds.
        tree_shake_key: Optional configuration fingerprint for the shipped
            programs whose icons are tree-shaken.

    Returns:
        A struct with `dart`, `flutter_sdk_files`, `const_finder`,
        `font_subset`, `kernel_dill`, `kernel_dills` and `tree_shake_key`.
    """
    return struct(
        dart = dart,
        flutter_sdk_files = flutter_sdk_files,
        const_finder = const_finder,
        font_subset = font_subset,
        kernel_dill = kernel_dill,
        kernel_dills = kernel_dills,
        tree_shake_key = tree_shake_key,
    )

def _add_collapsed_copies(asset_paths, copies):
    """Copy each `//`-keeping key's file under its collapsed key, if free.

    An entry keeping an empty segment also bundles its collapsed file:
    the manifest lists the collapsed variant (see
    `build_asset_manifest`), so the copy must exist under the collapsed
    key too, holding the same file flutter_tools read. The collapsed key
    joins `copies` only, never `asset_paths`, so it gains no manifest key
    of its own; a key another entry already claimed keeps its file.

    Args:
        asset_paths: The manifest bundle keys, in copy order.
        copies: The dest-key-to-file map, extended in place.
    """
    for dest in asset_paths:
        if "" in dest.split("/"):
            collapsed = _collapse_empty_segments(dest)
            if collapsed not in copies:
                copies[collapsed] = copies[dest]

def flutter_asset_bundle_action(ctx, content, shaking, output_dir):
    """Create an action that generates the flutter_assets/ tree artifact.

    Args:
        ctx: Rule context.
        content: What goes into the bundle, from `make_bundle_content`.
        shaking: The icon tree-shaking toolchain and kernels, from
            `make_tree_shake` (all empty when tree shaking is off).
        output_dir: The already-declared directory (tree artifact) File to
            write the bundle into. Declared by the caller rather than here
            because an application has to know where its assets will land
            *before* this action runs — the path is baked into the app as
            `rules_flutter.build_info.assetsDir`, which the dev tool matches
            against the tree it watches and rebuilds. Declaring an output and
            registering the action that fills it are separate steps in
            Starlark, so hoisting the declaration introduces no cycle even
            though icon tree shaking makes this action depend on the kernel.

    Returns:
        The `output_dir` it was given, so callers can chain.
    """
    if output_dir == None:
        fail("flutter_asset_bundle_action: `output_dir` is required — declare it with ctx.actions.declare_directory().")
    tool = ctx.executable._asset_bundle_tool

    # Build asset paths and copy map relative to the output directory. The key
    # travels with the file — set once by the target that listed the asset —
    # so this action keys every file by its carried key and computes none.
    # The manifest decodes those keys (`build_asset_manifest`); the copies
    # keep them encoded.
    # One channel may repeat a key another already claimed for the same file
    # (a diamond, or an own asset a dep also ships through pub): both callers
    # refuse two different files for one key before reaching this action, so
    # a repeat here is always the same file, and the manifest lists each key
    # once. The copies map already collapses to one entry per key.
    asset_paths = []
    copies = {}
    for entry in content.assets:
        if entry.key not in copies:
            asset_paths.append(entry.key)
        copies[entry.key] = entry.file.path

    # Add extra copies with custom destination paths.
    extra_files = []
    for dest_path, f in content.extra_asset_copies.items():
        if dest_path not in copies:
            asset_paths.append(dest_path)
        copies[dest_path] = f.path
        extra_files.append(f)

    # An entry keeping an empty segment also bundles its collapsed file
    # under the collapsed key, holding the same file flutter_tools read.
    _add_collapsed_copies(asset_paths, copies)

    # Build manifest structure.
    manifest = build_asset_manifest(asset_paths)

    # Write the config JSON.
    config = {
        "assets": manifest,
        "fonts": content.fonts,
        "copies": copies,
        "notices": content.notices,
        "license_files": [f.path for f in content.license_files],
    }

    # Icon tree shaking config.
    all_kernel_dills = list(shaking.kernel_dills) if shaking.kernel_dills else ([shaking.kernel_dill] if shaking.kernel_dill != None else [])
    extra_inputs = []
    transitive_inputs = []
    if shaking.const_finder and shaking.font_subset and all_kernel_dills:
        icon_cfg = {
            "dart": shaking.dart.path,
            "const_finder": shaking.const_finder.path,
            "font_subset": shaking.font_subset.path,
            "kernel_dill": all_kernel_dills[0].path,
            "kernel_dills": [d.path for d in all_kernel_dills],
        }
        if shaking.tree_shake_key:
            icon_cfg["key"] = "%x" % (hash(shaking.tree_shake_key) & 0xffffffff)
        config["icon_tree_shaking"] = icon_cfg
        extra_inputs.extend([shaking.dart, shaking.const_finder, shaking.font_subset] + all_kernel_dills)
        if shaking.flutter_sdk_files:
            transitive_inputs.append(shaking.flutter_sdk_files)

    config_content = json.encode(config)
    config_name = (
        "%s.%x.asset_bundle_config.json" % (ctx.label.name, hash(config_content) & 0xffffffff) if shaking.tree_shake_key else ctx.label.name + ".asset_bundle_config.json"
    )
    config_file = ctx.actions.declare_file(config_name)
    ctx.actions.write(config_file, config_content)

    ctx.actions.run(
        executable = tool,
        arguments = [
            "--config",
            config_file.path,
            "--output-dir",
            output_dir.path,
        ],
        inputs = depset(
            direct = [config_file] + [entry.file for entry in content.assets] + extra_files + content.license_files + extra_inputs,
            transitive = transitive_inputs,
        ),
        outputs = [output_dir],
        mnemonic = "FlutterAssetBundle",
        progress_message = "Bundling Flutter assets %s" % ctx.label,
    )

    return output_dir
