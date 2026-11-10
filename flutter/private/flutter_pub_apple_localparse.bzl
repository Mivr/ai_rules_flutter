"""Strict-parser entry for a plugin manifest with its target settings kept.

`parse_swiftpm_package` refuses target arguments Bazel cannot translate
(`resources`, `plugins`, ...). The plugin-local walk keeps the settings it
translates and drops those arguments from the token stream first. Split out
of `flutter_pub_apple_local.bzl` so that file stays under the size limit.
"""

load(":swiftpm_manifest.bzl", "parse_swiftpm_package")
load(":swiftpm_manifest_lex.bzl", "lex_swiftpm_manifest", "swiftpm_first_content_line")

_LOCAL_SKIPPED_ARGS = ["resources", "plugins", "defaultLocalization", "pkgConfig", "providers", "packageAccess"]

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
