"""SwiftPM C-family (`clang`) target translation.

Decides, for one C-family target, which module every Swift importer sees
and which Bazel rules carry the target's sources: the caller supplies
`module_name` (the C99-mangled module name, SwiftPM's `c99name`);
`module_map` is the explicit `module.modulemap` (used as-written) when
the target ships one, else a generated umbrella map for the
`publicHeadersPath` and target-rooted (single-directory) layouts, and
None when the target has no public headers at all — such a target is
link-only and gets no interop hint. The
BUILD emitter (`swiftpm_translate.bzl`) renders the spec this file
computes; the repo rule (`swiftpm_package.bzl`) classifies the sources
and writes the generated map.

Errors are bare details: the caller wraps them with the package identity
(the manifest parser with its `Package.swift` line format, the emitter
with its hub format). Every detail names the target.
"""

load(":swiftpm_settings.bzl", "swiftpm_render_list_attr")

def swiftpm_clang_module_spec(target, module_name, target_dir, sources, public_headers, explicit_map):
    """Compute one C-family target's module spec.

    The module map search walks the target directory the way SwiftPM's
    `ClangTarget.moduleMapPath` does: an explicit `module.modulemap` at
    the target root wins, otherwise the one in the public-headers
    directory (`include/` by default, `publicHeadersPath` when set),
    used as-written. Without an explicit map the public-headers
    directory — `include/` unless `publicHeadersPath:` is set, never the
    target root — gets a generated map: `<public>/<c99name>.h` is the
    umbrella header when present, else `<public>/<c99name>/<c99name>.h`,
    else the directory itself is the umbrella directory. A target with
    no public headers at all is link-only and gets no map. Any mix of C,
    C++, Objective-C and Objective-C++ sources translates to the one
    C-family library, the way SwiftPM builds such targets; only assembly
    sources have no Bazel translation, and the refusal names the file.

    Args:
        target: The parsed target struct (`name`, for messages,
            `public_headers_path` for the public-headers directory).
        module_name: The C99-mangled module name, for the umbrella
            header lookup.
        target_dir: The repo-relative target directory.
        sources: The repo-relative C-family source files.
        public_headers: The repo-relative public header files.
        explicit_map: The repo-relative explicit `module.modulemap`, or
            None.

    Returns:
        `struct(ok, detail, module_map, include_dir, umbrella_header)`:
        `module_map` is the repo-relative map (explicit or generated) or
        None; `include_dir` is the public-headers directory (for the
        search path) or None; `umbrella_header` is the umbrella header
        path relative to the public-headers directory, or None for the
        umbrella-directory form.
    """
    who = "target " + repr(target.name)
    for source in sources:
        if _swiftpm_clang_language(source) == "asm":
            return struct(ok = False, detail = "{who} has assembly source {file}, which has no Bazel translation".format(who = who, file = repr(source)), module_map = None, include_dir = None, umbrella_header = None)
    if explicit_map != None:
        return struct(ok = True, detail = "", module_map = explicit_map, include_dir = None, umbrella_header = None)
    public_dir = target_dir + "/" + target.public_headers_path if target.public_headers_path else target_dir + "/include"
    if not public_headers:
        return struct(ok = True, detail = "", module_map = None, include_dir = None, umbrella_header = None)
    umbrella_header = None
    if public_dir + "/" + module_name + ".h" in public_headers:
        umbrella_header = module_name + ".h"
    elif public_dir + "/" + module_name + "/" + module_name + ".h" in public_headers:
        umbrella_header = module_name + "/" + module_name + ".h"
    return struct(ok = True, detail = "", module_map = public_dir + "/module.modulemap", include_dir = public_dir, umbrella_header = umbrella_header)

def _swiftpm_clang_language(source):
    """Classify one source file by extension.

    Args:
        source: The repo-relative file path.

    Returns:
        `c`, `cxx`, `objc`, `objcxx`, `asm` or `other`.
    """
    for suffix in [".mm", ".M"]:
        if source.endswith(suffix):
            return "objcxx"
    for suffix in [".m"]:
        if source.endswith(suffix):
            return "objc"
    for suffix in [".cc", ".cpp", ".cxx", ".c++", ".C", ".cp"]:
        if source.endswith(suffix):
            return "cxx"
    for suffix in [".c"]:
        if source.endswith(suffix):
            return "c"
    for suffix in [".s", ".S", ".asm"]:
        if source.endswith(suffix):
            return "asm"
    return "other"

def swiftpm_clang_rule(sources):
    """Pick the Bazel rule carrying one target's sources.

    Args:
        sources: The repo-relative C-family source files.

    Returns:
        `"objc_library"` when any source is Objective-C (`.m`/`.mm`),
        else `"cc_library"`.
    """
    for source in sources:
        language = _swiftpm_clang_language(source)
        if language == "objc" or language == "objcxx":
            return "objc_library"
    return "cc_library"

def swiftpm_generated_modulemap_content(module_name, umbrella_header, public_dir, public_headers):
    """Render a generated umbrella module map's contents.

    Every path resolves relative to the directory the map file lives
    in (the public-headers directory): an `umbrella header` line names
    the umbrella header there, else `umbrella "."` names that same
    directory and each `header` line names a public header relative to
    it.

    Args:
        module_name: The C99-mangled module name.
        umbrella_header: The umbrella header path relative to the
            public-headers directory, or None for the umbrella-directory
            form.
        public_dir: The repo-relative public-headers directory, for
            header paths.
        public_headers: The repo-relative public header files, all under
            `public_dir`.

    Returns:
        The `module.modulemap` text.
    """
    lines = ["module {name} {{".format(name = module_name)]
    if umbrella_header:
        lines.append("    umbrella header \"{path}\"".format(path = umbrella_header))
    else:
        lines.append("    umbrella \".\"")
        for header in public_headers:
            lines.append("    header \"{path}\"".format(path = header[len(public_dir) + 1:]))
    lines.append("    export *")
    lines.append("}")
    return "\n".join(lines) + "\n"

def swiftpm_render_clang_library(
        library_name,
        rule,
        srcs,
        public_headers,
        private_headers,
        module_name,
        module_map,
        explicit_map,
        c_only,
        cxx,
        linkopts,
        includes,
        deps,
        tags):
    """Render one C-family target's `cc_library`/`objc_library`.

    The library carries the public and private headers in `hdrs` (Bazel
    needs the private ones for the compile), the header search paths in
    `includes` (hermetic in the spoke repository, where a `-I` in
    `copts` would not rebase), and the module name — plus the explicit
    map when the target ships one — in `aspect_hints` via a separate
    `swift_interop_hint` target (a rule, so it needs its own `name`)
    so Swift importers see the same module SwiftPM
    computes. A target with no public headers gets no hint: it is
    link-only. Lists render through `swiftpm_render_list_attr`, so
    `.when(platforms:)`-gated settings and dependencies become
    `select()`s on the target platform's OS.

    Args:
        library_name: The Bazel library name.
        rule: `"cc_library"` or `"objc_library"`.
        srcs: The unconditional source labels.
        public_headers: The unconditional public header labels.
        private_headers: The unconditional private header labels.
        module_name: The C99-mangled module name ("" for link-only).
        module_map: The explicit map label, or None.
        explicit_map: Whether `module_map` is an explicit map.
        c_only: `struct(text, platforms)` C-only option entries.
        cxx: `struct(text, platforms)` C++ option entries.
        linkopts: `struct(text, platforms)` link option entries.
        includes: `struct(text, platforms)` include entries.
        deps: `struct(text, platforms)` dependency entries.
        tags: The manual-tag list.

    Returns:
        The rule text (the caller loads `swift_interop_hint` when the
        library has a hint).
    """
    lines = ["{rule}(".format(rule = rule), '    name = "{name}",'.format(name = library_name)]
    lines.append("    srcs = [")
    for src in srcs:
        lines.append("        {item},".format(item = repr(src)))
    lines.append("    ],")
    lines.append("    hdrs = [")
    for header in public_headers + private_headers:
        lines.append("        {item},".format(item = repr(header)))
    lines.append("    ],")
    lists = swiftpm_render_list_attr("conlyopts", [], c_only)
    if lists:
        lines.append(lists)
    lists = swiftpm_render_list_attr("cxxopts", [], cxx)
    if lists:
        lines.append(lists)
    lists = swiftpm_render_list_attr("includes", [], includes)
    if lists:
        lines.append(lists)
    lists = swiftpm_render_list_attr("linkopts", [], linkopts)
    if lists:
        lines.append(lists)
    if module_name:
        lines.append("    aspect_hints = [\":{name}_interop_hint\"],".format(name = library_name))
    lists = swiftpm_render_list_attr("deps", [], deps)
    if lists:
        lines.append(lists)
    lines.append("    tags = [{tags}],".format(tags = ", ".join([repr(tag) for tag in tags])))
    lines.append(")")
    if module_name:
        lines.append("")
        lines.append("swift_interop_hint(")
        lines.append("    name = \"{name}_interop_hint\",".format(name = library_name))
        lines.append("    module_name = {name},".format(name = repr(module_name)))
        if explicit_map:
            lines.append("    module_map = {map},".format(map = repr(module_map)))
        lines.append(")")
    return "\n".join(lines)
