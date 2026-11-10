"""SwiftPM product links of a plugin's non-primary local targets.

A plugin manifest can list a product of another package on any target it
owns, `.product(name:package:)` or by name (`dependencies: ["BigInt"]`).
The SwiftPM product path links the primary target's products; the targets
the local walk reaches compile as libraries of their own, so each needs the
same product labels in its `deps`. This file resolves them with the same
rules as the primary target (`apple_swiftpm_labels_for_products`): a product
that resolves is linked, anything else fails the fetch naming the plugin,
the dependency and the `.product(name:package:)` fix.
"""

load(
    ":flutter_pub_apple.bzl",
    "apple_swiftpm_keeps_dep",
    "apple_swiftpm_labels_for_products",
    "apple_swiftpm_read_pins",
    "apple_swiftpm_read_product_deps",
)
load(":flutter_pub_apple_byname.bzl", "apple_swiftpm_names_product")

def _with_edges(target, labels):
    """Copy a local target struct with product labels added to its edges.

    Args:
        target: The `plugin_local_targets(...).targets` entry.
        labels: The product labels the target links.

    Returns:
        The same struct with one unconditional edge per label.
    """
    return struct(
        name = target.name,
        dir = target.dir,
        directory = target.directory,
        path = target.path,
        module_name = target.module_name,
        kind = target.kind,
        target = target.target,
        settings = target.settings,
        clang_settings = target.clang_settings,
        swift_settings = target.swift_settings,
        edges = target.edges + [struct(text = label, platforms = None) for label in labels],
    )

def apple_local_product_links(ctx, plugin, platform, manifest_dir, model, targets):
    """Link the product dependencies of the reached non-primary targets.

    Args:
        ctx: The spoke's repository context, carrying the hub's resolved
            label, checksum-file label, native-deps label and name.
        plugin: The pub plugin name.
        platform: `"ios"` or `"macos"`.
        manifest_dir: The manifest's package-relative directory.
        model: The parsed plugin manifest model.
        targets: The `plugin_local_targets(...).targets` list.

    Returns:
        `struct(ok, error, targets, labels)`: `targets` carry the product
        labels in their edges; `labels` lists every linked label once, for
        the primary library (the xtool backend compiles all targets as one).
    """
    local = [other.name.lower() for other in model.targets if other.name]
    pins = None
    product_deps = None
    out = []
    labels = []
    for target in targets:
        products = [
            dep
            for dep in target.target.deps
            if apple_swiftpm_names_product(dep, local) and apple_swiftpm_keeps_dep(dep, model.pkg_deps, platform)
        ]
        if not products:
            out.append(target)
            continue
        if pins == None:
            pins = apple_swiftpm_read_pins(ctx, ctx.attr.package_resolved, ctx.attr.package_sha256, ctx.attr.hub_name)
            product_deps = apple_swiftpm_read_product_deps(ctx, ctx.attr.ios_native_deps, ctx.attr.hub_name)
        prepared = struct(products = products, pkg_deps = model.pkg_deps, target = target.target)
        selected = apple_swiftpm_labels_for_products(
            plugin,
            manifest_dir,
            [target.dir],
            platform,
            pins,
            prepared,
            product_deps,
        )
        if not selected.ok:
            return struct(ok = False, error = selected.error, targets = [], labels = [])
        out.append(_with_edges(target, selected.labels))
        labels.extend([label for label in selected.labels if label not in labels])
    return struct(ok = True, error = "", targets = out, labels = labels)
