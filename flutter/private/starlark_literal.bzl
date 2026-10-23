"""One escaping helper for every string emitted into generated BUILD files.

The pub spoke generators walk file names out of package archives and read
asset, font and shader paths out of pubspec.yaml files. Both are
attacker-controlled for hosted packages and user-controlled for path
packages. Pasting them into BUILD source with a `"..." % value` splice lets
a quote or a backslash in a name close the literal and continue the file as
Starlark: the generated BUILD then fails to parse, names a different file,
or adds rules of the package's choosing that run during the build.

Every generator routes each string it emits through
`starlark_string_literal`, which is `repr()`: the emitted literal always
parses back to the exact input, and ordinary names render byte-identical to
the old quoting. Names no Bazel target can name (empty, or holding a
newline, a carriage return, or a `:` that collides with the label
separator) fail the fetch instead, naming the package, the declaring entry
and the file.
"""

def starlark_string_literal(value):
    """Render `value` as a Starlark string literal that parses back to it.

    Args:
        value: The string to emit (or a list of strings, for `includes`).

    Returns:
        A double-quoted literal with every quote, backslash and control
        character escaped, so the text parses back to the exact input.
    """
    return repr(value)

def spoke_file_name_error(package_name, entry, path):
    """The fetch failure for a declared or walked name no target can name.

    Names the package, the declaring pubspec entry and the file, so the fix
    (renaming the file) is in the message. Returns the message instead of
    failing so unit tests can assert it; the caller `fail()`s with it.

    Args:
        package_name: The pub package the entry comes from.
        entry: The pubspec declaration covering the file (the path itself
            for a direct entry, the trailing-slash directory for a file
            walked out of one, the font block for a font asset).
        path: The file path that cannot be emitted.

    Returns:
        The error string; the caller `fail()`s with it.
    """
    return (
        "flutter.pub spoke for \"{pkg}\": entry \"{entry}\" names file " +
        "{path} which cannot be a Bazel target name (it is empty or holds " +
        "a newline, a carriage return or a `:`). Rename the file rather " +
        "than emitting a spoke that cannot name it."
    ).format(
        pkg = package_name,
        entry = entry,
        path = repr(path),
    )

def check_spoke_file_name(package_name, entry, path):
    """Fail the spoke fetch when `path` cannot be a Bazel target name.

    Quotes and backslashes pass through: the escaping helper round-trips
    them. Only names no literal can name while staying addressable fail.

    Args:
        package_name: The pub package the entry comes from.
        entry: The pubspec declaration covering the file.
        path: The file path to check.

    Returns:
        None when the name is emittable, so unit tests can assert the
        pass-through; otherwise fails with `spoke_file_name_error`.
    """
    if not path or "\n" in path or "\r" in path or ":" in path:
        fail(spoke_file_name_error(package_name, entry, path))
    return None
