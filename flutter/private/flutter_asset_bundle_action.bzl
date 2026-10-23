"""Shared `flutter_assets/` tree build action.

Leaf module for the action both `flutter_asset_bundle` and the shared asset
bundling step in `//flutter/private:common.bzl` register. Kept apart from the
rule so the rule can load the shader helpers from `common.bzl` without a
load cycle.
"""

# Regex-like DPR directory patterns we detect in Starlark.
# A directory named like "2x", "1.5x", "3.0x" indicates a resolution variant.
_DPR_SUFFIXES = {
    "1.5x": 1.5,
    "2x": 2.0,
    "2.0x": 2.0,
    "3x": 3.0,
    "3.0x": 3.0,
    "4x": 4.0,
    "4.0x": 4.0,
}

def detect_dpr(path):
    """Detect device-pixel-ratio from a resolution variant directory name.

    Args:
        path: Asset path string (e.g. "assets/2.0x/icon.png").

    Returns:
        (base_path, dpr) tuple.  base_path has the DPR dir removed (e.g.
        "assets/icon.png").  dpr is a float or None if not a variant.
    """
    parts = path.split("/")
    for i, part in enumerate(parts):
        if part in _DPR_SUFFIXES:
            base = "/".join(parts[:i] + parts[i + 1:])
            return base, _DPR_SUFFIXES[part]
    return path, None

def build_asset_manifest(assets):
    """Build the asset manifest structure from a list of asset paths.

    Args:
        assets: list of asset path strings relative to package root.

    Returns:
        dict mapping logical key -> list of variant dicts.
    """
    manifest = {}

    # Group by base path.
    for path in sorted(assets):
        base, dpr = detect_dpr(path)
        if base not in manifest:
            manifest[base] = []
        entry = {"asset": path}
        if dpr != None:
            entry["dpr"] = dpr
        manifest[base].append(entry)

    # Ensure the main (1x) variant is first in each list.
    for base in manifest:
        variants = manifest[base]
        main_idx = None
        for i, v in enumerate(variants):
            if v["asset"] == base:
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
    asset_paths = []
    copies = {}
    for entry in content.assets:
        asset_paths.append(entry.key)
        copies[entry.key] = entry.file.path

    # Add extra copies with custom destination paths.
    extra_files = []
    for dest_path, f in content.extra_asset_copies.items():
        asset_paths.append(dest_path)
        copies[dest_path] = f.path
        extra_files.append(f)

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
