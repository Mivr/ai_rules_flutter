"""Static reader for CocoaPods plugin .podspec files (POD-12)."""

load("//flutter/private:starlark_literal.bzl", "starlark_string_literal")

def podspec_unsupported_field_error(plugin, podspec_path, line, field, raw_value):
    """Format Message 5 for an untranslated podspec field.

    Args:
        plugin: Plugin name string.
        podspec_path: Repository-relative podspec path string.
        line: 1-based line number integer.
        field: Field name as written in podspec.
        raw_value: Raw RHS expression string.

    Returns:
        Formatted error message string.
    """
    return (
        'Flutter plugin "%s": %s:%d declares %s (%s), which rules_flutter does not build for plugins. ' % (
            plugin,
            podspec_path,
            line,
            field,
            raw_value,
        ) + "Replace the plugin's BUILD file with an overlay (flutter.plugin_overlays)."
    )

def _normalize_library_name(lib):
    """Normalize CocoaPods library name by stripping 'lib' prefix if len > 3."""
    if len(lib) > 3 and lib.startswith("lib"):
        return lib[3:]
    return lib

def _strip_quotes(s):
    """Strip matching enclosing single or double quotes."""
    s = s.strip()
    if len(s) >= 2 and ((s[0] == "'" and s[-1] == "'") or (s[0] == '"' and s[-1] == '"')):
        return s[1:-1]
    return s

def _is_single_quoted_string(s):
    """Whether s is a single string literal wrapped in matching quotes."""
    s = s.strip()
    if len(s) >= 2 and ((s[0] == "'" and s[-1] == "'") or (s[0] == '"' and s[-1] == '"')):
        quote = s[0]
        first_close = s.find(quote, 1)
        return first_close == len(s) - 1
    return False

def _has_glob_wildcard(s):
    """Check if string contains glob wildcards (*, ?, {, [)."""
    for ch in ("*", "?", "{", "["):
        if ch in s:
            return True
    return False

def _parse_comma_separated_strings(inner):
    """Parse comma-separated single-quoted strings."""
    items = []
    for part in inner.split(","):
        p = part.strip()
        if not p:
            continue
        if not _is_single_quoted_string(p):
            return None
        items.append(_strip_quotes(p))
    return items

def _parse_string_list_or_single(raw_val):
    """Parse a single string, array of strings, or %w[...] literal into a list of strings."""
    v = raw_val.strip()
    if v.startswith("%w[") and v.endswith("]"):
        inner = v[3:-1].strip()
        if not inner:
            return []
        return [_strip_quotes(word) for word in inner.split()]

    if v.startswith("[") and v.endswith("]"):
        inner = v[1:-1].strip()
        if not inner:
            return []
        return _parse_comma_separated_strings(inner)

    if _is_single_quoted_string(v):
        return [_strip_quotes(v)]

    if "," in v:
        return _parse_comma_separated_strings(v)

    return None

def _parse_resource_bundles_hash(raw_val):
    """Parse resource_bundles hash { 'k' => ['v'] } or { 'k' => 'v' }."""
    v = raw_val.strip()
    if not (v.startswith("{") and v.endswith("}")):
        return None
    inner = v[1:-1].strip()
    if not inner:
        return []

    manifests = []

    # Split entries by '=>'
    pairs = inner.split("=>")
    if len(pairs) < 2:
        return None

    for i in range(1, len(pairs)):
        curr_val_chunk = pairs[i].strip()
        if i < len(pairs) - 1:
            comma_idx = curr_val_chunk.rfind(",")
            if comma_idx < 0:
                return None
            val_str = curr_val_chunk[:comma_idx].strip()
        else:
            val_str = curr_val_chunk.rstrip(",").strip()

        parsed_items = _parse_string_list_or_single(val_str)
        if parsed_items == None:
            return None
        for item in parsed_items:
            if not item.endswith(".xcprivacy") or _has_glob_wildcard(item):
                return None
            manifests.append(item)

    return manifests

def _detect_heredoc_tag(line):
    """Detect heredoc opener (<<-TAG, <<~TAG, <<TAG) on line."""
    idx = line.find("<<")
    if idx < 0:
        return None
    rest = line[idx + 2:]
    strip_mode = False
    if rest.startswith("-") or rest.startswith("~"):
        strip_mode = True
        rest = rest[1:]
    rest = rest.strip()
    if not rest:
        return None
    tag = ""
    for ch in rest.elems():
        if ch.isalnum() or ch == "_":
            tag += ch
        else:
            break
    if not tag:
        return None
    return struct(tag = tag, strip = strip_mode)

def _strip_ruby_comments(line):
    """Strip Ruby '#' comments not inside quotes or interpolation."""
    in_single = False
    in_double = False
    interp_depth = 0
    chars = line.elems()
    for i in range(len(chars)):
        c = chars[i]
        if c == "'" and not in_double:
            in_single = not in_single
        elif c == '"' and not in_single:
            in_double = not in_double
        elif in_double and c == "#" and i + 1 < len(chars) and chars[i + 1] == "{":
            interp_depth += 1
        elif in_double and interp_depth > 0 and c == "}":
            interp_depth -= 1
        elif c == "#" and not in_single and not in_double and interp_depth == 0:
            return line[:i]
    return line

def _classify_block_boundary(line):
    """Check if line opens or closes a Ruby block."""
    stripped = line.strip()
    if stripped == "end" or stripped.startswith("end ") or stripped.startswith("end;"):
        return struct(kind = "end", is_spec = False)

    is_spec = ".test_spec" in stripped or ".app_spec" in stripped
    if (
        stripped.startswith("def ") or
        stripped.startswith("begin") or
        stripped.startswith("case ") or
        stripped.startswith("class ") or
        stripped.startswith("module ") or
        stripped.startswith("if ") or
        stripped.startswith("unless ") or
        " do" in stripped or
        " do|" in stripped
    ):
        return struct(kind = "open", is_spec = is_spec)

    return None

def _extract_statement_parts(stmt):
    """Extract (recv, scope, attr, is_assign, raw_rhs) from statement."""
    clean = stmt.strip()
    op = None
    if "+=" in clean:
        op = "+="
    elif "=" in clean:
        op = "="

    if op:
        lhs, _, raw_rhs = clean.partition(op)
        lhs = lhs.strip()
        raw_rhs = raw_rhs.strip()
        dots = lhs.split(".")
        if len(dots) == 2:
            return struct(recv = dots[0], scope = "", attr = dots[1], is_assign = True, raw_rhs = raw_rhs)
        if len(dots) == 3:
            return struct(recv = dots[0], scope = dots[1], attr = dots[2], is_assign = True, raw_rhs = raw_rhs)
        return None

    # Method call syntax: recv.attr val
    space_idx = clean.find(" ")
    if space_idx > 0:
        lhs = clean[:space_idx].strip()
        raw_rhs = clean[space_idx:].strip()
        dots = lhs.split(".")
        if len(dots) == 2:
            return struct(recv = dots[0], scope = "", attr = dots[1], is_assign = False, raw_rhs = raw_rhs)
        if len(dots) == 3:
            return struct(recv = dots[0], scope = dots[1], attr = dots[2], is_assign = False, raw_rhs = raw_rhs)

    return None

def _is_scope_active(scope, platform):
    """Check if scope applies to platform."""
    if not scope:
        return True
    if scope == "ios":
        return platform == "ios"
    if scope in ("osx", "macos"):
        return platform == "macos"
    return False

def _accumulate_unique(target_list, new_items):
    """Append new_items to target_list without duplicates."""
    for item in new_items:
        if item not in target_list:
            target_list.append(item)

def _handle_resources(v, line_num, plugin, path, attr_name, privacy_manifests):
    """Handle resources/resource field."""
    parsed = _parse_string_list_or_single(v)
    if parsed != None and len(parsed) > 0:
        all_privacy = True
        for p in parsed:
            if not p.endswith(".xcprivacy") or _has_glob_wildcard(p):
                all_privacy = False
                break
        if all_privacy:
            _accumulate_unique(privacy_manifests, parsed)
            return
    fail(podspec_unsupported_field_error(plugin, path, line_num, attr_name, v))

def _handle_resource_bundles(v, line_num, plugin, path, attr_name, privacy_manifests):
    """Handle resource_bundles field."""
    parsed = _parse_resource_bundles_hash(v)
    if parsed != None and len(parsed) > 0:
        _accumulate_unique(privacy_manifests, parsed)
        return
    fail(podspec_unsupported_field_error(plugin, path, line_num, attr_name, v))

def _handle_link_field(v, line_num, plugin, path, attr_name, target_list, is_library):
    """Handle frameworks/libraries literal list."""
    parsed = _parse_string_list_or_single(v)
    if parsed == None:
        fail(podspec_unsupported_field_error(plugin, path, line_num, attr_name, v))
    if is_library:
        parsed = [_normalize_library_name(x) for x in parsed]
    _accumulate_unique(target_list, parsed)

def _check_heredoc_line(heredoc, raw_line):
    """Check if raw_line terminates current heredoc."""
    stripped = raw_line.strip() if heredoc.strip else raw_line
    if stripped == heredoc.tag:
        return None
    return heredoc

def _update_block_stack(block_stack, clean_line):
    """Update block nesting stack from clean_line."""
    b_boundary = _classify_block_boundary(clean_line)
    if b_boundary:
        if b_boundary.kind == "open":
            block_stack.append(b_boundary.is_spec)
        elif b_boundary.kind == "end" and block_stack:
            block_stack.pop()

def _dispatch_statement_attr(attr, val, stmt_line, plugin, podspec_path, collected):
    """Dispatch an attribute assignment to the appropriate handler."""
    if attr in ("vendored_frameworks", "vendored_framework", "vendored_libraries", "vendored_library"):
        fail(podspec_unsupported_field_error(plugin, podspec_path, stmt_line, attr, val))
    elif attr in ("frameworks", "framework"):
        _handle_link_field(val, stmt_line, plugin, podspec_path, attr, collected.frameworks, False)
    elif attr in ("weak_frameworks", "weak_framework"):
        _handle_link_field(val, stmt_line, plugin, podspec_path, attr, collected.weak_frameworks, False)
    elif attr in ("libraries", "library"):
        _handle_link_field(val, stmt_line, plugin, podspec_path, attr, collected.libraries, True)
    elif attr in ("resources", "resource"):
        _handle_resources(val, stmt_line, plugin, podspec_path, attr, collected.privacy_manifests)
    elif attr == "resource_bundles":
        _handle_resource_bundles(val, stmt_line, plugin, podspec_path, attr, collected.privacy_manifests)

def read_plugin_podspec(text, podspec_path, plugin, platform):
    """Statically parse a plugin podspec for link settings and privacy manifests.

    Args:
        text: Full podspec text string.
        podspec_path: Relative path string of the podspec.
        plugin: Plugin name string.
        platform: Target platform ('ios' or 'macos').

    Returns:
        struct(frameworks, weak_frameworks, libraries, privacy_manifests, ...).
    """
    frameworks = []
    weak_frameworks = []
    libraries = []
    privacy_manifests = []
    collected = struct(
        frameworks = frameworks,
        weak_frameworks = weak_frameworks,
        libraries = libraries,
        privacy_manifests = privacy_manifests,
    )

    lines = text.split("\n")
    heredoc = None
    block_stack = []

    accum_stmt = ""
    accum_start_line = 0

    for i in range(len(lines)):
        line_num = i + 1
        raw_line = lines[i]

        if heredoc:
            heredoc = _check_heredoc_line(heredoc, raw_line)
            continue

        hdoc_info = _detect_heredoc_tag(raw_line)
        if hdoc_info:
            heredoc = hdoc_info

        clean_line = _strip_ruby_comments(raw_line).strip()
        if not clean_line:
            continue

        _update_block_stack(block_stack, clean_line)
        in_skipped_spec = True in block_stack

        if accum_stmt:
            accum_stmt += " " + clean_line
        else:
            accum_stmt = clean_line
            accum_start_line = line_num

        open_b = accum_stmt.count("[") - accum_stmt.count("]")
        open_c = accum_stmt.count("{") - accum_stmt.count("}")
        if open_b > 0 or open_c > 0:
            continue

        full_stmt = accum_stmt
        stmt_line = accum_start_line
        accum_stmt = ""

        if in_skipped_spec:
            continue

        parsed = _extract_statement_parts(full_stmt)
        if not parsed or not _is_scope_active(parsed.scope, platform):
            continue

        _dispatch_statement_attr(parsed.attr, parsed.raw_rhs, stmt_line, plugin, podspec_path, collected)

    return struct(
        frameworks = frameworks,
        weak_frameworks = weak_frameworks,
        libraries = libraries,
        privacy_manifests = privacy_manifests,
        sdk_frameworks = frameworks,
        weak_sdk_frameworks = weak_frameworks,
        sdk_dylibs = libraries,
    )

def splice_apple_podspec_link_settings(content, plugin, apple):
    """Splice SDK link settings into a rendered spoke BUILD file.

    Args:
        content: Spoke BUILD content string.
        plugin: Plugin name string.
        apple: Struct from detect_apple_plugin_sources.

    Returns:
        Patched BUILD content string.
    """
    for platform in ("ios", "macos"):
        podspec = getattr(apple, platform + "_podspec", None)
        if not podspec:
            continue
        lines = []
        if podspec.frameworks:
            lines.append("    sdk_frameworks = %s," % starlark_string_literal(podspec.frameworks))
        if podspec.weak_frameworks:
            lines.append("    weak_sdk_frameworks = %s," % starlark_string_literal(podspec.weak_frameworks))
        if podspec.libraries:
            lines.append("    sdk_dylibs = %s," % starlark_string_literal(podspec.libraries))
        if not lines:
            continue
        insert_text = "\n".join(lines) + "\n"

        for suffix in ("", "_xtool"):
            marker = '    name = "%s_apple_%s%s",\n' % (plugin, platform, suffix)
            head, sep, tail = content.partition(marker)
            if not sep:
                continue
            block, vis_sep, vis_tail = tail.partition("\n    visibility = ")
            if not vis_sep:
                continue
            content = head + sep + block + "\n" + insert_text + "    visibility = " + vis_tail

    return content

def _scan_directory_podspecs(ctx, plugin, dir_path):
    """Scan dir_path for *.podspec files, failing on multiples."""
    dir_node = ctx.path(dir_path)
    if not dir_node.exists:
        return None
    if hasattr(dir_node, "readdir"):
        podspecs = [c.basename for c in dir_node.readdir() if c.basename.endswith(".podspec")]
    else:
        single = dir_path + "/" + plugin + ".podspec"
        podspecs = [plugin + ".podspec"] if ctx.path(single).exists else []

    if len(podspecs) > 1:
        fail('Flutter plugin "%s": multiple podspecs found in %s: %s' % (plugin, dir_path, ", ".join(podspecs)))
    if len(podspecs) == 1:
        return dir_path + "/" + podspecs[0]
    return None

def discover_platform_podspec(ctx, plugin, platform, shared_darwin):
    """Find the single .podspec for a given platform.

    Args:
        ctx: Repository context.
        plugin: Plugin name string.
        platform: 'ios' or 'macos'.
        shared_darwin: bool indicating shared Darwin layout.

    Returns:
        Relative podspec path string or None.
    """
    if shared_darwin:
        darwin_spec = _scan_directory_podspecs(ctx, plugin, "darwin")
        if darwin_spec:
            return darwin_spec
    return _scan_directory_podspecs(ctx, plugin, platform)

def detect_apple_privacy_manifests(ctx, source_dirs):
    """Find each plugin source dir's `PrivacyInfo.xcprivacy` file.

    Args:
        ctx: Repository context.
        source_dirs: List of source directory relative paths.

    Returns:
        Sorted, deduplicated list of relative paths.
    """
    manifests = {}
    for src_dir in source_dirs:
        for relpath in (
            src_dir + "/PrivacyInfo.xcprivacy",
            src_dir + "/Resources/PrivacyInfo.xcprivacy",
        ):
            if ctx.path(relpath).exists:
                manifests[relpath] = True
    return sorted(manifests.keys())

def detect_apple_podspecs(
        ctx,
        plugin,
        macos_srcs,
        ios_srcs,
        macos_shared_darwin,
        ios_shared_darwin):
    """Detect and parse platform podspecs, merging privacy manifests.

    Args:
        ctx: Repository context.
        plugin: Plugin name string.
        macos_srcs: List of macOS source dirs.
        ios_srcs: List of iOS source dirs.
        macos_shared_darwin: bool for macOS sharedDarwinSource.
        ios_shared_darwin: bool for iOS sharedDarwinSource.

    Returns:
        struct(macos_podspec, ios_podspec, macos_manifests, ios_manifests).
    """
    macos_manifests = detect_apple_privacy_manifests(ctx, macos_srcs)
    m_spec_path = discover_platform_podspec(ctx, plugin, "macos", macos_shared_darwin) if macos_srcs else None
    macos_podspec = None
    if m_spec_path:
        m_dir = m_spec_path[:m_spec_path.rfind("/")]
        macos_podspec = read_plugin_podspec(ctx.read(m_spec_path), m_spec_path, plugin, "macos")
        for m in macos_podspec.privacy_manifests:
            full_p = m_dir + "/" + m
            if ctx.path(full_p).exists and full_p not in macos_manifests:
                macos_manifests.append(full_p)

    ios_manifests = detect_apple_privacy_manifests(ctx, ios_srcs)
    i_spec_path = discover_platform_podspec(ctx, plugin, "ios", ios_shared_darwin) if ios_srcs else None
    ios_podspec = None
    if i_spec_path:
        i_dir = i_spec_path[:i_spec_path.rfind("/")]
        ios_podspec = read_plugin_podspec(ctx.read(i_spec_path), i_spec_path, plugin, "ios")
        for m in ios_podspec.privacy_manifests:
            full_p = i_dir + "/" + m
            if ctx.path(full_p).exists and full_p not in ios_manifests:
                ios_manifests.append(full_p)

    return struct(
        macos_podspec = macos_podspec,
        ios_podspec = ios_podspec,
        macos_manifests = sorted(macos_manifests),
        ios_manifests = sorted(ios_manifests),
    )
