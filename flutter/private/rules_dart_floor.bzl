"""Floor check for the resolved `ai_rules_dart` module.

`rules_flutter` needs `ai_rules_dart` 0.20.0 (see `MODULE.bazel`), but a root
module override (`archive_override`, `git_override`, `local_path_override`
or `single_version_override`) replaces that resolution while Bazel ignores
the overridden module's `bazel_dep` version. Release archives carry no module
version and overridden modules report none, so the version cannot be read:
this module probes the behaviour the floor exists for instead. The 0.20.0
pubspec reader refuses a `%YAML` or `%TAG` directive after the `...` end
marker; the 0.19.0 one silently reads past it. One tiny parse per extension
evaluation keeps the check cheap, and everything the check needs (the floor,
the probe and the message) lives here so a floor bump touches one file.
"""

load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_document_error")

RULES_DART_FLOOR = "0.20.0"

# A pubspec-shaped stream the floor reader refuses and the previous release
# accepts: `parse_pubspec_document_error` is public in both, reports None on
# 0.19.0 (the trailing directive is silently dropped) and an error on 0.20.0
# (`directive after document end (...) at line 3`).
_FLOOR_PROBE = "name: floor_probe\n...\n%YAML 1.2\n"

def _floor_message():
    """Returns the failure message naming the module, floor and override fix."""
    return (
        "rules_flutter needs ai_rules_dart " + RULES_DART_FLOOR + " or newer, but the " +
        "resolved ai_rules_dart reads pubspecs like an older release: it accepts a " +
        "%YAML/%TAG directive after `...` that " + RULES_DART_FLOOR + " refuses. A root " +
        "archive_override, git_override, local_path_override or " +
        "single_version_override is probably pinning an older ai_rules_dart: raise " +
        "that override to " + RULES_DART_FLOOR + " or above, or drop it so the version " +
        "in rules_flutter's MODULE.bazel applies."
    )

def rules_dart_floor_error(read_error = parse_pubspec_document_error):
    """Returns why the resolved `ai_rules_dart` predates the floor, or None.

    The injected `read_error` is `parse_pubspec_document_error` by default;
    tests pass a stand-in that mimics an older reader. A None probe result
    means the reader accepts the trailing directive, so it is older than
    `RULES_DART_FLOOR` and the returned message says which override to
    change. A non-None result means the reader refuses it, so it meets the
    floor and there is no error.

    Args:
        read_error: Callable taking pubspec text and returning an error
            string or None, as `parse_pubspec_document_error` does.

    Returns:
        The floor failure message, or None when the reader meets the floor.
    """
    if read_error(_FLOOR_PROBE) == None:
        return _floor_message()
    return None

def check_rules_dart_floor(read_error = parse_pubspec_document_error):
    """Fails extension evaluation when `ai_rules_dart` predates the floor.

    Call this before creating any repository so toolchain-only consumers
    fail the same way `flutter.pub` consumers do.

    Args:
        read_error: Callable taking pubspec text and returning an error
            string or None, as `parse_pubspec_document_error` does.
    """
    err = rules_dart_floor_error(read_error)
    if err != None:
        fail(err)
