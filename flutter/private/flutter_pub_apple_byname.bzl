"""By-name SwiftPM dependencies and package-declaration detection for plugin spokes.

A plugin target can write `dependencies: ["BigInt"]` (or `.byName(name:)`)
to name a product of another package, which SwiftPM resolves against the
manifest's `.package(...)` declarations. The spoke links such a dependency
like `.product(name:package:)` when exactly one declared package can own
it, and refuses the fetch otherwise. This file also decides, from the
lexer's tokens rather than a raw substring, whether a manifest the parser
cannot read declares a package dependency at all.
"""

load(":swiftpm_manifest_lex.bzl", "lex_swiftpm_manifest")
load(":swiftpm_translate.bzl", "swiftpm_url_identity")

def apple_swiftpm_declares_package(text):
    """Whether a manifest text spells a `.package` member anywhere in its code.

    Reads the lexer's tokens, so every legal spelling counts (`.package(`,
    `.package (`, a line break after the dot) while comments and string
    literals do not. A text the lexer rejects cannot be read token by
    token; it counts as declaring one when `.package` appears once the
    whitespace is removed.

    Args:
        text: The `Package.swift` text.

    Returns:
        True when the manifest may declare a package dependency.
    """
    lexed = lex_swiftpm_manifest(text, "")
    if not lexed.ok:
        squeezed = "".join(text.split())
        return ".package" in squeezed
    previous = None
    for tok in lexed.tokens:
        if tok.kind == "nl":
            continue
        if previous != None and previous.kind == "punct" and previous.text == "." and tok.kind == "word" and tok.text == "package":
            return True
        previous = tok
    return False

def apple_swiftpm_decl_reference(decl):
    """The `package:` spelling that names one `.package(...)` declaration.

    Args:
        decl: A parsed `.package(...)` declaration.

    Returns:
        Its `name:`, else its url's identity, else its path's last
        segment ("" when it has none of these).
    """
    if decl.name:
        return decl.name
    if decl.ref_kind == "url":
        return swiftpm_url_identity(decl.ref)
    if decl.ref_kind == "path":
        path = decl.ref.replace("\\", "/").rstrip("/")
        return path[path.rfind("/") + 1:]
    return ""

def _byname_candidates(pkg_deps):
    """The declared packages a by-name dependency could belong to.

    Args:
        pkg_deps: The manifest's parsed `.package(...)` declarations.

    Returns:
        The `package:` spellings of the declarations, without the
        template's `FlutterFramework` (the rules link Flutter themselves).
    """
    refs = []
    for decl in pkg_deps:
        ref = apple_swiftpm_decl_reference(decl)
        if ref and ref.lower() != "flutterframework" and ref not in refs:
            refs.append(ref)
    return refs

def _byname_error(plugin_name, dep, detail):
    """The fetch failure for a by-name dependency that cannot be linked.

    Args:
        plugin_name: The pub plugin name.
        dep: The parsed by-name dependency reference.
        detail: What is wrong with it.

    Returns:
        The failure text, naming the plugin, the dependency and the fix.
    """
    return ("Flutter plugin {plugin}: target dependency {name} {detail} " +
            "Write it as `.product(name: {name}, package: \"<package>\")` " +
            "so the package that owns the product is explicit.").format(
        plugin = repr(plugin_name),
        name = json.encode(dep.name),
        detail = detail,
    )

def apple_swiftpm_resolve_byname(plugin_name, dep, pkg_deps, is_mapped):
    """Turn a by-name dependency into the product dependency it names.

    A by-name dependency that is not a target of the plugin's manifest
    names a product of another package. It resolves to the declared
    package that the hub's `swift_package_product_deps` maps it from,
    else to the only declared package; with none or several it fails.

    Args:
        plugin_name: The pub plugin name, for messages.
        dep: The parsed `kind == "same"` dependency reference.
        pkg_deps: The manifest's parsed `.package(...)` declarations.
        is_mapped: A callable `(package, product) -> bool` telling whether
            the hub maps the product of that package.

    Returns:
        `struct(ok, error, dep)`: `dep` is the product dependency.
    """
    candidates = _byname_candidates(pkg_deps)
    owners = [ref for ref in candidates if is_mapped(ref, dep.name)]
    if not owners:
        owners = candidates
    if not owners:
        detail = "names neither a target of its Package.swift nor a product of a declared `.package(...)`."
        return struct(ok = False, error = _byname_error(plugin_name, dep, detail), dep = None)
    if len(owners) > 1:
        detail = "could be a product of any of the declared packages " + ", ".join([json.encode(ref) for ref in owners]) + "."
        return struct(ok = False, error = _byname_error(plugin_name, dep, detail), dep = None)
    return struct(ok = True, error = "", dep = struct(kind = "product", name = dep.name, package = owners[0], condition = dep.condition))
