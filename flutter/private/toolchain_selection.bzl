"""Picks one Flutter SDK version per toolchain name from the versions modules request."""

def _parse_identifier_list(text, what, version):
    """Validates dot-separated prerelease/build identifiers."""
    identifiers = []
    for identifier in text.split("."):
        if not identifier:
            fail("Invalid Flutter SDK version \"{v}\": the {what} part is empty.".format(v = version, what = what))
        for c in identifier.elems():
            if not (c.isalnum() or c == "-"):
                fail("Invalid Flutter SDK version \"{v}\": bad character {c} in the {what} part.".format(v = version, c = repr(c), what = what))
        if identifier.isdigit():
            identifiers.append((0, int(identifier), ""))
        else:
            identifiers.append((1, 0, identifier))
    return identifiers

def _parse_version(v):
    """Parses a Flutter SDK version into a comparable key.

    Accepts a numeric dotted core plus an optional semver-style `-<prerelease>`
    and/or `+<build>` suffix, so enterprise rebuilds (`3.44.1-acme`), Flutter
    prereleases (`3.45.0-0.1.pre`) and build-stamped versions (`3.44.1+corp.7`)
    all compare. Ordering is numeric on the core first; a prerelease sorts
    below its release; build metadata never decides. Anything else fails with
    the offending version named.

    Args:
      v: The version string.

    Returns:
      A `(core, release_rank, prerelease)` tuple of comparables.
    """
    build_split = v.split("+")
    if len(build_split) > 2:
        fail("Invalid Flutter SDK version \"{v}\": at most one +<build> suffix is allowed.".format(v = v))
    without_build = build_split[0]
    if len(build_split) == 2:
        _parse_identifier_list(build_split[1], "build", v)
    dash = without_build.find("-")
    if dash == -1:
        core_text = without_build
        prerelease = []
        release_rank = 1
    else:
        core_text = without_build[:dash]
        prerelease_text = without_build[dash + 1:]
        prerelease = _parse_identifier_list(prerelease_text, "prerelease", v)
        release_rank = 0
    core = []
    for part in core_text.split("."):
        if not part or not part.isdigit():
            fail("Invalid Flutter SDK version \"{v}\": expected numeric components separated by dots (e.g. '3.44.1'), optionally followed by -<prerelease> and/or +<build>.".format(v = v))
        core.append(int(part))
    if not core:
        fail("Invalid Flutter SDK version \"{v}\": the numeric core is empty.".format(v = v))
    return (core, release_rank, prerelease)

def select_toolchain_version(name, requests):
    """Selects the Flutter SDK version for one toolchain name.

    The root module's request wins when it makes one: a root pin is selected
    even when a dependency requests a newer SDK. With no root request, the
    highest requested version wins, as before.

    When several root tags request the same name, the highest of the root's own
    requests is used.

    Args:
      name: The toolchain name, used in the note.
      requests: Non-empty list of `struct(version, is_root)`, one per tag.

    Returns:
      `struct(version, note)`. `note` is a message for the user when the root
      module pinned a version older than a dependency's request (the root still
      wins), and None otherwise.
    """
    root_requests = [r for r in requests if r.is_root]
    dep_requests = [r for r in requests if not r.is_root]

    # Every requested version parses up front, so a malformed string fails
    # here naming the version — even a lone root pin that no comparison
    # would otherwise touch.
    keys = {r.version: _parse_version(r.version) for r in requests}

    if root_requests:
        selected = root_requests[0].version
        for request in root_requests[1:]:
            if keys[request.version] > keys[selected]:
                selected = request.version

        # The root pin wins even when it is older than a dependency's request;
        # surface that as an informational note naming both versions.
        newer_dep_versions = [
            r.version
            for r in dep_requests
            if keys[r.version] > keys[selected]
        ]
        note = None
        if newer_dep_versions:
            newest_dep = newer_dep_versions[0]
            for v in newer_dep_versions[1:]:
                if keys[v] > keys[newest_dep]:
                    newest_dep = v
            note = "Flutter toolchain {} uses {} requested by the root module, which is older than {} requested by a dependency".format(
                name,
                selected,
                newest_dep,
            )
        return struct(version = selected, note = note)

    # No root request: highest requested version wins.
    selected = requests[0].version
    for request in requests[1:]:
        if keys[request.version] > keys[selected]:
            selected = request.version
    return struct(version = selected, note = None)

def select_toolchain_source(name, requests):
    """Selects the source (local SDK or downloaded version) for one toolchain name.

    The root module's choice wins exactly as it does for versions: a root
    `local_path` replaces every non-root version request for the name, and a
    root version pin goes through `select_toolchain_version`. "Mixed" is an
    error only when the root module itself sets both `local_path` and
    `flutter_version` for the name. A non-root `local_path` is always an
    error: dependencies must request downloadable versions.

    Args:
      name: The toolchain name, used in notes and errors.
      requests: Non-empty list of `struct(version, local_path, is_root)`, one
        per tag. `version` is `""` for local requests, `local_path` is `""`
        for download requests. A request setting both counts as both, so it
        trips the root-mix error below.

    Returns:
      `struct(local_path, version, note)`: exactly one of `local_path` and
      `version` is set. `note` names the overridden non-root requests, if
      any, and None otherwise.
    """
    for r in requests:
        if r.local_path and not r.is_root:
            fail("Only the root module may source a Flutter toolchain from a local SDK (local_path); dependencies must request downloadable versions.")
    root_locals = [r for r in requests if r.is_root and r.local_path]
    root_downloads = [r for r in requests if r.is_root and r.version]
    dep_downloads = [r for r in requests if not r.is_root and not r.local_path]
    if root_locals and root_downloads:
        fail("Flutter toolchain {} mixes a local SDK (local_path) with a downloaded version; use one or the other.".format(name))
    if root_locals:
        local_paths = {r.local_path: True for r in root_locals}.keys()
        if len(local_paths) > 1:
            fail("Flutter toolchain {} has multiple local SDKs {}; keep exactly one local_path.".format(name, list(local_paths)))
        local_path = root_locals[0].local_path
        note = None
        if dep_downloads:
            note = "Flutter toolchain {} uses local SDK {} requested by the root module, ignoring {} version request(s) from dependencies".format(
                name,
                local_path,
                len(dep_downloads),
            )
        return struct(local_path = local_path, version = "", note = note)
    selection = select_toolchain_version(
        name,
        [struct(version = r.version, is_root = r.is_root) for r in requests],
    )
    return struct(local_path = "", version = selection.version, note = selection.note)
