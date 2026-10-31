"""Cycle planning and lockfile facts for flutter.pub dependency graphs.

Loads cycle planner and verification helpers from @rules_dart//dart/pub:pub_scc.bzl,
collects facts and plans strongly connected components (SCCs) for flutter.pub.
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "trim_gzip_trailing_nulls")
load(
    "@rules_dart//dart/pub:pub_scan.bzl",
    "check_package_symlinks",
    "run_pub_archive_scans",
)
load(
    "@rules_dart//dart/pub:pub_scc.bzl",
    "PARSER_SOURCE_LABELS",
    "compute_sccs",
    "package_dep_graph",
    "parser_schema",
    "read_scope_pubspec",
    "record_scope_facts",
    "scc_repo_name",
    "split_scope_facts",
)
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_deps")
load("//flutter/private:download.bzl", "pinned_download")
load("//flutter/private:flutter_pub_cycle_breaks.bzl", "apply_cycle_breaks")
load("//flutter/private:flutter_pub_mirror.bzl", "path_spoke_resolves_outside")
load(
    "//flutter/private:pub_lock_sdks.bzl",
    "hosted_package_sha256",
)

def resolve_flutter_pub_schema(module_ctx):
    """Builds the fact-key schema from pubspec parser source bytes."""
    texts = [module_ctx.read(label, watch = "no") for label in PARSER_SOURCE_LABELS]
    return parser_schema(texts)

def _download_and_scan_scratch(module_ctx, scope_dir, misses):
    """Downloads missing hosted package archives into scratch and scans them."""
    pending = []
    for name in sorted(misses.keys()):
        pkg = misses[name]
        url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
            base = pkg.url,
            name = name,
            version = pkg.version,
        )
        archive = "{dir}/{name}.tar.gz".format(dir = scope_dir, name = name)
        out = "{dir}/{name}".format(dir = scope_dir, name = name)
        pinned_download(module_ctx, url = url, output = archive, sha256 = pkg.sha256)
        raw = module_ctx.read(archive)
        trimmed = trim_gzip_trailing_nulls(raw)
        if trimmed != raw:
            module_ctx.file(archive, trimmed, executable = False)
        pending.append(struct(archive = archive, name = name, out = out))

    if pending:
        run_pub_archive_scans(
            module_ctx,
            [struct(archive = p.archive, name = p.name) for p in pending],
        )

    miss_deps = {}
    for p in pending:
        module_ctx.extract(p.archive, output = p.out)
        check_package_symlinks(module_ctx, p.name, root = p.out)
        pubspec_content = read_scope_pubspec(module_ctx, p.name, p.out)
        miss_deps[p.name] = sorted(parse_pubspec_deps(pubspec_content))

    return miss_deps

def collect_hosted_facts(module_ctx, hub_name, hosted, pub_lock, schema, recorded_facts):
    """Collects pubspec dependencies for hosted packages, caching in facts.

    Args:
        module_ctx: The module extension context.
        hub_name: The name of the pub hub.
        hosted: Dict mapping package name to hosted package info dict.
        pub_lock: The parsed pubspec.lock data.
        schema: The parser schema string.
        recorded_facts: Mutable dict to record facts into.

    Returns:
        Dict mapping package name to its sorted dependency list.
    """
    hosted_structs = {}
    for name, info in hosted.items():
        desc = info.get("description", {})
        base_url = desc.get("url", "https://pub.dev") if type(desc) == "dict" else "https://pub.dev"
        sha256 = hosted_package_sha256(name, info, pub_lock)
        hosted_structs[name] = struct(
            version = info.get("version", ""),
            sha256 = sha256,
            url = base_url,
        )

    facts = getattr(module_ctx, "facts", {})
    split = split_scope_facts(facts, hosted_structs, {}, schema)

    miss_deps = {}
    if split.hosted_miss:
        scope_dir = "_scc_scratch/" + hub_name
        module_ctx.file(scope_dir + "/.scc_scope", "flutter pub dependency-cycle scope scratch")
        miss_deps = _download_and_scan_scratch(module_ctx, scope_dir, split.hosted_miss)
        if hasattr(module_ctx, "delete"):
            module_ctx.delete(scope_dir)

    record_scope_facts(recorded_facts, split, miss_deps)

    deps = dict(split.deps)
    for name, d in miss_deps.items():
        deps[name] = d
    return deps

def collect_path_deps(module_ctx, hub_name, path_pkgs):
    """Collects pubspec dependencies for workspace path packages.

    Args:
        module_ctx: The module extension context.
        hub_name: The name of the pub hub.
        path_pkgs: Dict mapping package name to path package info struct.

    Returns:
        Dict mapping package name to its sorted dependency list.
    """
    ws_root = module_ctx.path(Label("@@//:MODULE.bazel")).dirname
    ws_realpath = str(ws_root.realpath)
    deps = {}

    for name in sorted(path_pkgs.keys()):
        info = path_pkgs[name]
        segments = info.path.split("/")
        prefix = []
        for seg in segments:
            prefix.append(seg)
            node = ws_root.get_child(*prefix)
            if not node.exists:
                break
            if path_spoke_resolves_outside(ws_realpath, str(node.realpath), False):
                fail("flutter.pub hub \"%s\": path dependency \"%s\" resolves outside workspace (%s)" % (
                    hub_name,
                    name,
                    str(node.realpath),
                ))

        pkg_dir = ws_root.get_child(*segments)
        pubspec_file = pkg_dir.get_child("pubspec.yaml")
        if not pubspec_file.exists:
            fail("flutter.pub hub \"%s\": path dependency \"%s\" has no readable pubspec.yaml" % (
                hub_name,
                name,
            ))

        content = module_ctx.read(pubspec_file)
        deps[name] = sorted(parse_pubspec_deps(content))

    return deps

def plan_flutter_pub_sccs(all_package_names, hub_name, package_deps, cycle_breaks):
    """Plans strongly connected components for a flutter.pub hub.

    Applies cycle_breaks before computing SCCs so explicitly broken edges
    do not merge packages. Single-package SCCs become individual spokes;
    multi-package SCCs emit a merged spoke repository.

    Args:
        all_package_names: List of all package names in the lock.
        hub_name: The name of the pub hub.
        package_deps: Dict mapping package name to its dependency list.
        cycle_breaks: Dict mapping package name to broken dependency list.

    Returns:
        A struct with singletons, merged, and scc_targets.
    """
    filtered_deps = {}
    for pkg in all_package_names:
        raw = package_deps.get(pkg, [])
        applied = apply_cycle_breaks(pkg, raw, cycle_breaks.get(pkg, []))
        if applied.error:
            fail(applied.error)
        filtered_deps[pkg] = applied.dependencies

    graph = package_dep_graph(filtered_deps, {}, all_package_names, [hub_name], [hub_name])
    components = compute_sccs(graph)

    singletons = []
    merged = {}
    scc_targets = {}

    for comp in components:
        if len(comp) < 2:
            singletons.append(comp[0])
        else:
            repo = scc_repo_name(hub_name, comp)
            merged[repo] = comp
            for member in comp:
                scc_targets[member] = "@" + repo + "//:" + member

    return struct(
        singletons = singletons,
        merged = merged,
        sccs = [comp for comp in components if len(comp) >= 2],
        scc_targets = scc_targets,
        planned_deps = filtered_deps,
    )
