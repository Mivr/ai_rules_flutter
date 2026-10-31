"""Low-level line-oriented scanner and token parsing for CocoaPods `Podfile.lock`.

CocoaPods writes a deterministic, line-oriented YAML subset. This scanner provides
pure, bounded line inspection: checking indentation tabs, detecting flow syntax
and anchors, counting indentation, and parsing pod entry and dependency lines.
"""

def make_refusal(label, line_num, detail):
    """Format a standard refusal error naming the label and 1-based line.

    Args:
        label: The file label string.
        line_num: 1-based line number.
        detail: The specific error message.

    Returns:
        Formatted error string `"<label> (Podfile.lock line <n>): <detail>."`.
    """
    return "{label} (Podfile.lock line {line}): {detail}.".format(
        label = label,
        line = line_num,
        detail = detail,
    )

def has_indent_tab(line):
    """Whether `line` has a tab character in its leading indentation.

    Args:
        line: The raw line string.

    Returns:
        True if any character before the first non-space character is a tab,
        or if a blank line contains a tab.
    """
    for i in range(len(line)):
        c = line[i]
        if c == "\t":
            return True
        if c != " ":
            return False
    return False

def has_flow_or_anchor(stripped):
    """Whether `stripped` starts a key or value with flow syntax or an anchor.

    Args:
        stripped: The line content stripped of leading and trailing whitespace.

    Returns:
        True if flow syntax (`[`, `]`, `{`, `}`) or anchor/alias (`&`, `*`)
        appears where a key or value begins.
    """
    if not stripped:
        return False
    if stripped[0] in ("[", "]", "{", "}", "&", "*"):
        return True
    if stripped.startswith("- "):
        item = stripped[2:].lstrip()
        if not item:
            return False
        if item[0] in ("[", "]", "{", "}", "&", "*"):
            return True
        item_sep = find_mapping_separator(item)
        if item_sep.has_kv and item_sep.val:
            val = item_sep.val.lstrip()
            if val and val[0] in ("[", "]", "{", "}", "&", "*"):
                return True
        return False
    sep = find_mapping_separator(stripped)
    if sep.has_kv and sep.val:
        val = sep.val.lstrip()
        if val and val[0] in ("[", "]", "{", "}", "&", "*"):
            return True
    return False

def count_indent(line):
    """Count leading spaces of `line`.

    Args:
        line: The line string.

    Returns:
        Number of leading spaces.
    """
    count = 0
    for i in range(len(line)):
        if line[i] == " ":
            count += 1
        else:
            break
    return count

def unquote(scalar):
    """Strip enclosing quotes from `scalar` if present.

    Args:
        scalar: The scalar string.

    Returns:
        Unquoted string.
    """
    s = scalar.strip()
    if len(s) >= 2:
        if (s[0] == '"' and s[-1] == '"') or (s[0] == "'" and s[-1] == "'"):
            return s[1:-1]
    return s

def find_mapping_separator(s):
    """Find the key and value of a YAML mapping in `s`.

    In YAML, a mapping separator ':' is either followed by whitespace or is
    at the end of the line. A colon inside a URL (e.g. 'https://...') is
    not followed by whitespace, so it is part of the scalar, not a separator.
    For symbol keys (e.g. ':path:'), the leading colon is part of the key.

    Args:
        s: The stripped content string.

    Returns:
        `struct(has_kv, key, val)`: `has_kv` is True if a separator was found,
        `key` is the string before the separator, `val` is the string after.
    """
    if not s:
        return struct(has_kv = False, key = "", val = "")
    if s.startswith('"'):
        close_q = s.find('"', 1)
        if close_q != -1:
            key = s[1:close_q]
            after = s[close_q + 1:].lstrip()
            if after.startswith(":"):
                return struct(has_kv = True, key = key, val = after[1:].strip())
            return struct(has_kv = False, key = key, val = "")
    if s.startswith("'"):
        close_q = s.find("'", 1)
        if close_q != -1:
            key = s[1:close_q]
            after = s[close_q + 1:].lstrip()
            if after.startswith(":"):
                return struct(has_kv = True, key = key, val = after[1:].strip())
            return struct(has_kv = False, key = key, val = "")
    if s.endswith(":"):
        return struct(has_kv = True, key = s[:-1].strip(), val = "")
    start_pos = 1 if s.startswith(":") else 0
    n = len(s)
    for i in range(start_pos, n):
        if s[i] == ":":
            if i == n - 1 or s[i + 1] in (" ", "\t"):
                return struct(has_kv = True, key = s[:i].strip(), val = s[i + 1:].strip())
    return struct(has_kv = False, key = s.strip(), val = "")

def parse_mapping_line(stripped):
    """Parse a YAML mapping line into key, kind and value.

    Args:
        stripped: A mapping line stripped of indentation.

    Returns:
        `struct(key, kind, value)`: `key` as written, `kind` without leading
        colon, and unquoted `value`.
    """
    sep = find_mapping_separator(stripped)
    key = unquote(sep.key)
    kind = key[1:] if key.startswith(":") else key
    return struct(key = key, kind = kind, value = unquote(sep.val))

def parse_pods_entry(stripped):
    """Parse a `- <name> (<version>):` or quoted `- "<name> (<version>)":` line.

    Args:
        stripped: The line text stripped of leading indentation.

    Returns:
        `struct(ok, name, version)` where `ok` is True on success, False if
        the line is not a valid entry.
    """
    if not stripped.startswith("- "):
        return struct(ok = False, name = "", version = "")
    rest = stripped[2:].strip()
    if not rest.endswith(":"):
        return struct(ok = False, name = "", version = "")
    inner = unquote(rest[:-1].strip())
    if not inner.endswith(")"):
        return struct(ok = False, name = "", version = "")
    open_paren = inner.rfind(" (")
    if open_paren <= 0:
        return struct(ok = False, name = "", version = "")
    name = unquote(inner[:open_paren].strip())
    version = inner[open_paren + 2:-1].strip()
    if not name or not version:
        return struct(ok = False, name = "", version = "")
    if (name.find("(") != -1 or name.find(")") != -1 or
        version.find("(") != -1 or version.find(")") != -1 or
        name.find(":") != -1):
        return struct(ok = False, name = "", version = "")
    return struct(ok = True, name = name, version = version)

def parse_pods_dep(stripped):
    """Parse a `- <name>` or `- <name> (<requirement>)` dependency line.

    Args:
        stripped: The line text stripped of leading indentation.

    Returns:
        `struct(ok, name, requirement)` where `ok` is True on success, False
        if the line is not a valid dependency line.
    """
    if not stripped.startswith("- "):
        return struct(ok = False, name = "", requirement = "")
    rest = unquote(stripped[2:].strip())
    if rest.endswith(")"):
        open_paren = rest.rfind(" (")
        if open_paren <= 0:
            return struct(ok = False, name = "", requirement = "")
        name = unquote(rest[:open_paren].strip())
        req = rest[open_paren + 2:-1].strip()
        if not name or not req:
            return struct(ok = False, name = "", requirement = "")
        if (name.find("(") != -1 or name.find(")") != -1 or
            req.find("(") != -1 or req.find(")") != -1 or
            name.find(":") != -1 or req.find(":") != -1):
            return struct(ok = False, name = "", requirement = "")
        return struct(ok = True, name = name, requirement = req)
    if rest.find("(") != -1 or rest.find(")") != -1 or rest.find(":") != -1:
        return struct(ok = False, name = "", requirement = "")
    name = unquote(rest)
    if not name:
        return struct(ok = False, name = "", requirement = "")
    return struct(ok = True, name = name, requirement = "")
