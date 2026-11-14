"""The strict-layering (import) check for Flutter program rules.

rules_dart's `dart_binary` and `dart_test` refuse a source that imports a
package none of its direct `deps` provides. This file is the one place a
Flutter rule picks that check up, so every checked rule shares one wiring:

  * `LAYERING_CHECK_ASPECT` goes on the rule's `deps`,
  * `LAYERING_CHECK_ATTRS` into its `attrs`,
  * `LAYERING_CHECK_TOOLCHAINS` into its `toolchains`,
  * `layering_check()` returns what its `_validation` output group carries.

Checked rules: `flutter_test`.

The check is on by default; the `dart_layering_check` feature turns it off per
package or per build, exactly as in rules_dart.
"""

load(
    "@rules_dart//dart:import_check.bzl",
    "EXECUTABLE_IMPORT_CHECK_TOOLCHAINS",
    "dart_import_check_aspect",
    "executable_import_check",
)

visibility(["//flutter/..."])

LAYERING_CHECK_ASPECT = dart_import_check_aspect

# These mirror rules_dart's `EXECUTABLE_IMPORT_CHECK_ATTRS`, because
# `executable_import_check` reads both by name. They are spelled out here so
# the rule's attribute surface stays resolvable without loading a dict.
LAYERING_CHECK_ATTRS = {
    "_import_check": attr.label(
        doc = "The import checker, run on the rule's own sources.",
        default = Label("@rules_dart//dart:import_check"),
        executable = True,
        cfg = "exec",
    ),
    "_refused_dart_libraries": attr.label(
        doc = "The Dart libraries a source may not import.",
        default = Label("@rules_dart//dart:refused_dart_libraries"),
    ),
}

LAYERING_CHECK_TOOLCHAINS = EXECUTABLE_IMPORT_CHECK_TOOLCHAINS

def layering_check(ctx, package):
    """Checks a rule's own sources and gathers the stamps of its deps.

    Args:
        ctx: The rule context; it declares `LAYERING_CHECK_ATTRS` and
            `LAYERING_CHECK_TOOLCHAINS` and has `main`, `srcs` and `deps`.
        package: The rule's own package, from `dart_package_identity`. An
            empty `package_name` means the rule states no package.

    Returns:
        A depset of check stamps, for the `_validation` output group.
    """
    return executable_import_check(ctx, package if package.package_name else None)
