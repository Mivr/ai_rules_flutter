"""Per-hub plugin overlay root selection (root-wins).

A hub declared by module M resolves its spokes' `BUILD.bazel.tpl`
overlays against the root module's `flutter.plugin_overlays(roots = ...)`
first, then M's own roots (when M is not the root), then the bundled
`@rules_flutter//ext` root. A module's overlays never reach a hub another
non-root module declared, and never the root's hubs. Order inside one
module stays tag order.

Why root-wins: the extension used to hand every module's roots to every
hub, so any module in the dependency graph could replace the BUILD file
of any pub package in the root's hubs (one it does not override itself),
and the root could not tell. The Flutter version choice is already
root-wins; overlays were the remaining gap. A hub consults its root
list in order and the first root holding a template for the package wins,
so listing the root's roots first is what makes the root's overlay win.
"""

def hub_overlay_roots(root_roots, owner_roots, owner_is_root):
    """Overlay roots for one hub, with the root module's roots first.

    Pure selection core: the extension collects each module's roots in tag
    order and calls this per hub, so unit tests can pin the per-hub list
    for a root hub, a dependency's hub, and both modules overlaying the
    same package.

    Args:
        root_roots: Overlay roots declared by the root module, in tag order.
        owner_roots: Overlay roots declared by the hub's own module, in tag
            order.
        owner_is_root: Whether the hub's module is the root module.

    Returns:
        The root module's roots first, then the owner's own roots when the
        owner is not the root. The caller appends the bundled
        `@rules_flutter//ext` root last.
    """
    if owner_is_root:
        return list(root_roots)
    return list(root_roots) + list(owner_roots)
