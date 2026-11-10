"""Strict parser, refusal rules and target lookup for the plugin-local walk.

`parse_plugin_local_package` (the strict parser) keeps the target settings
Bazel translates and drops keyword arguments (`resources`, `plugins`, ...) it
does not, refusing anything else. The walk used to treat every refusal as "no
local targets", so a multi-target plugin silently built only its primary
target. This file decides which refusals may stay silent: a manifest the
lenient spoke parser reads (declarative) never may, and a program-style
manifest may only when it has no sibling target to drop. It also holds the
manifest-target lookup and reachability-seeding helpers `plugin_local_targets`
shares with the dependency walk.
"""

load(":swiftpm_manifest.bzl", "parse_swiftpm_package", "parse_swiftpm_plugin_package")
load(":swiftpm_manifest_lex.bzl", "lex_swiftpm_manifest", "swiftpm_first_content_line")

_TARGET_CALLS = ["target", "binaryTarget", "systemLibrary", "executableTarget", "plugin", "macro"]
_LOCAL_SKIPPED_ARGS = ["resources", "plugins", "defaultLocalization", "pkgConfig", "providers", "packageAccess"]
_LOCAL_SPECIAL_KINDS = ["executableTarget", "binaryTarget", "systemLibrary", "plugin", "macro"]

def _token_depths(tokens):
    """The paren/bracket depth before each token.

    Args:
        tokens: The lexed manifest token list.

    Returns:
        The depth list, one entry per token.
    """
    depths = []
    depth = 0
    for token in tokens:
        depths.append(depth)
        if token.kind == "punct" and token.text in ("(", "["):
            depth += 1
        elif token.kind == "punct" and token.text in (")", "]"):
            depth -= 1
    return depths

def _is_keyword_argument(tokens, index, keywords):
    """True when token `index` opens a `keyword:` argument to drop.

    Args:
        tokens: The lexed manifest token list.
        index: The token to inspect.
        keywords: The argument names to drop.

    Returns:
        True for a matching word followed by a colon.
    """
    if tokens[index].kind != "word" or tokens[index].text not in keywords:
        return False
    return index + 1 < len(tokens) and tokens[index + 1].kind == "punct" and tokens[index + 1].text == ":"

def _skip_keyword_argument(tokens, depths, start):
    """Return the index one past one keyword argument's value.

    Args:
        tokens: The lexed manifest token list.
        depths: The per-token depth list from `_token_depths`.
        start: The keyword token's index.

    Returns:
        The index after the value's comma, or at its closing bracket.
    """
    target_depth = depths[start]
    i = start + 1
    for _ in range(len(tokens) + 1):
        if i >= len(tokens):
            break
        if depths[i] == target_depth and tokens[i].kind == "punct":
            if tokens[i].text == ",":
                return i + 1
            if tokens[i].text in (")", "]"):
                return i
        i += 1
    return i

def _strip_tokens(tokens, keywords):
    """Drop the skipped keyword arguments from a token list.

    Args:
        tokens: The lexed manifest token list.
        keywords: The argument names to drop.

    Returns:
        The token list without those arguments and their values.
    """
    depths = _token_depths(tokens)
    out = []
    i = 0
    for _ in range(len(tokens) + 1):
        if i >= len(tokens):
            break
        if _is_keyword_argument(tokens, i, keywords):
            i = _skip_keyword_argument(tokens, depths, i)
            continue
        out.append(tokens[i])
        i += 1
    return out

def _render_tokens(tokens):
    """Render a token list as manifest text the parser accepts.

    Args:
        tokens: The token list to render.

    Returns:
        The manifest body text.
    """
    parts = []
    for t in tokens:
        item = "\n" if t.kind == "nl" else ('"""' + t.text + '""" ' if t.kind == "str" else t.text + " ")
        parts.append(item)
    return "".join(parts)

def parse_plugin_local_package(plugin, text):
    """Parse a plugin manifest with target settings kept.

    Args:
        plugin: The pub plugin name, for messages.
        text: The `Package.swift` text.

    Returns:
        The strict parser's `struct(ok, error, model)`.
    """
    lexed = lex_swiftpm_manifest(text, plugin)
    if not lexed.ok:
        return struct(ok = False, error = lexed.error, model = None)
    first = swiftpm_first_content_line(text)
    if not first.ok:
        return struct(ok = False, error = first.error, model = None)
    stripped = _strip_tokens(lexed.tokens, _LOCAL_SKIPPED_ARGS)
    rendered = first.line + "\n" + _render_tokens(stripped)
    return parse_swiftpm_package(plugin, rendered)

def _count_target_calls(tokens):
    """Count the non-test target declarations in a lexed manifest.

    Args:
        tokens: The lexer's token list.

    Returns:
        The number of `.target(`-style calls, `testTarget` excluded.
    """
    count = 0
    for i in range(len(tokens) - 2):
        if tokens[i].kind == "punct" and tokens[i].text == "." and tokens[i + 1].kind == "word" and \
           tokens[i + 1].text in _TARGET_CALLS and tokens[i + 2].text == "(":
            count += 1
    return count

def local_manifest_decision(plugin, text, parsed, other_source_dirs):
    """Decide whether a strict-parser result may be ignored by the walk.

    Args:
        plugin: The pub plugin name, for messages.
        text: The `Package.swift` text.
        parsed: The `parse_plugin_local_package` result for `text`.
        other_source_dirs: Directories under the manifest's `Sources` other
            than the primary one.

    Returns:
        `struct(ok, error, parsed)`: `ok` is False when the spoke fetch must
        fail with `error`; otherwise `parsed.ok` says whether to translate.
    """
    if parsed.ok:
        return struct(ok = True, error = "", parsed = parsed)
    refuse = struct(ok = False, error = parsed.error, parsed = parsed)
    if parse_swiftpm_plugin_package(plugin, text).ok:
        return refuse
    lexed = lex_swiftpm_manifest(text, plugin)
    if other_source_dirs or (lexed.ok and _count_target_calls(lexed.tokens) > 1):
        return refuse
    return struct(ok = True, error = "", parsed = parsed)

def local_special_error(plugin, target):
    """Refuse reached targets whose kind rules_apple cannot build.

    Args:
        plugin: The pub plugin name, for messages.
        target: The reached target struct.

    Returns:
        The refusal string.
    """
    kind = getattr(target, "kind", "target")
    if kind == "binaryTarget":
        return "binary targets in plugin manifests land in POD-10"
    msg = "Flutter plugin %r: target %r has unsupported kind `%s`."
    return msg % (plugin, getattr(target, "name", ""), kind)

def local_target_dir(manifest_dir, target):
    """The package-relative directory one manifest target lives in.

    Args:
        manifest_dir: The manifest's package-relative directory.
        target: The parsed target struct (`path`, `name`).

    Returns:
        The target directory.
    """
    path = getattr(target, "path", "")
    suffix = path if path else "Sources/" + getattr(target, "name", "")
    return manifest_dir + "/" + suffix

def local_target_by_name(targets, name):
    """Find one target in the parsed manifest by its case-insensitive name.

    Args:
        targets: The parsed target list.
        name: The target name to search for.

    Returns:
        The target struct, or None when missing.
    """
    lower = name.lower()
    for target in targets:
        target_name = getattr(target, "name", "")
        if target_name == name or target_name.lower() == lower:
            return target
    return None

def local_primary_target(model, manifest_dir, primary_dir):
    """Pick the manifest target matching the primary globbed directory.

    Args:
        model: The parsed plugin manifest model.
        manifest_dir: The manifest's package-relative directory.
        primary_dir: The package-relative directory the spoke globs.

    Returns:
        The primary target struct, or None when nothing matches.
    """
    for target in getattr(model, "targets", []):
        if getattr(target, "kind", "target") != "target":
            continue
        if local_target_dir(manifest_dir, target) == primary_dir:
            return target
    return None

def local_append_reached(plugin, target, reached, stack):
    """Mark one target reached and queue it for the same-dependency walk.

    Args:
        plugin: The pub plugin name, for messages.
        target: The target struct to visit.
        reached: The reached-name dict (mutated in place).
        stack: The pending-name list (mutated in place).

    Returns:
        "" or the refusal naming an untranslatable special target.
    """
    name = getattr(target, "name", "")
    if not name:
        return "Flutter plugin %r: a manifest target has no name." % plugin
    if name in reached:
        return ""
    kind = getattr(target, "kind", "target")
    if kind in _LOCAL_SPECIAL_KINDS:
        return local_special_error(plugin, target)
    if kind == "testTarget":
        return "Flutter plugin %r: target %r depends on test target %r, which is ignored." % (plugin, plugin, name)
    reached[name] = name
    reached[name.lower()] = name
    stack.append(name)
    return ""

def local_seed_products(plugin, model, reached, stack):
    """Seed reachability from every `.library` product's targets.

    Args:
        plugin: The pub plugin name, for messages.
        model: The parsed plugin manifest model.
        reached: The reached-name dict (mutated in place).
        stack: The pending-name list (mutated in place).

    Returns:
        "" or the refusal for an unknown or untranslatable target.
    """
    for product in getattr(model, "products", []):
        if getattr(product, "kind", "") != "library":
            continue
        for name in getattr(product, "targets", []):
            target = local_target_by_name(getattr(model, "targets", []), name)
            if target == None:
                return "Flutter plugin %r: product %r names unknown target %r." % (plugin, getattr(product, "name", ""), name)
            refused = local_append_reached(plugin, target, reached, stack)
            if refused:
                return refused
    return ""

def local_dep_applies(dep, platform):
    """Whether one same-package dependency applies on a platform.

    Args:
        dep: The parsed dependency reference.
        platform: `"ios"` or `"macos"`.

    Returns:
        True when the dependency is built on the platform.
    """
    condition = getattr(dep, "condition", None)
    if condition == None:
        return True
    return platform in getattr(condition, "platforms", [])
