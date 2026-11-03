"""flutter_tools' resolution-variant directory rule, shared by the rule set.

Mirrors `_assetVariantDirectoryRegExp` (flutter_tools 3.47.7
`packages/flutter_tools/lib/src/asset.dart:111`) and the manifest's
`parseScale` (`asset.dart:937-963`): a directory name is a resolution
variant when its tail is `<digits>x` or `<digits>.<digits>x`, and the
leading number of that tail is its device-pixel ratio. The asset action and
the pub asset spokes both read the rule from here, so they cannot diverge.
"""

_DIGITS = "0123456789"

def _all_digits(text):
    """True when every character of `text` is an ASCII digit.

    Args:
        text: The text to inspect.

    Returns:
        True for a non-empty all-digit string; True for an empty string as
        well, which is the `\\d*` empty-fraction case of flutter_tools'
        regex.
    """
    for i in range(len(text)):
        if text[i] not in _DIGITS:
            return False
    return True

def _variant_number(name):
    """The number text of a resolution-variant directory name, or None.

    Implements flutter_tools' tail match without a regex engine: scan left
    to right for the first digit run that reaches the end of `name` (before
    its final `x`), optionally followed by `.` and any number of digits.
    That is the match `RegExp.firstMatch` returns for the tail-anchored
    resolution-variant regex, so `2x`, `2.0x`, `0.75x` and `2.x` match
    while `sub`, `x` and `2xx` do not, and `a2.5x` matches with `2.5`.

    Args:
        name: A single directory basename (no slashes).

    Returns:
        The matched number text (`"2"`, `"2.5"`, `"0.75"`, ...), or None
        when the name is not a resolution-variant directory.
    """
    if len(name) < 2 or not name.endswith("x"):
        return None
    stem = name[:len(name) - 1]
    for start in range(len(stem)):
        if stem[start] not in _DIGITS:
            continue
        end = start
        for i in range(start, len(stem)):
            if stem[i] not in _DIGITS:
                break
            end = i + 1
        if end == len(stem):
            return stem[start:]
        if stem[end] != ".":
            continue
        fraction = stem[end + 1:]
        if fraction == "":
            return stem[start:end]
        if _all_digits(fraction):
            return stem[start:]
    return None

def is_asset_variant_dir(name):
    """True when `name` is a resolution-variant directory, per flutter_tools.

    The one predicate every caller shares: pub asset walks decide which
    subdirectories to read with it, and the manifest decides which bundle
    keys group as variants with it.

    Args:
        name: A single directory basename (no slashes).

    Returns:
        True when flutter_tools would treat the directory as variants.
    """
    return _variant_number(name) != None

def asset_variant_dpr(name):
    """The device-pixel ratio of a resolution-variant directory, or None.

    Args:
        name: A single directory basename (no slashes).

    Returns:
        The float ratio parsed from the name (`2.5` for `2.5x`, `2.0` for
        `2.x`), or None when the name is not a resolution-variant directory.
    """
    number = _variant_number(name)
    if number == None:
        return None
    return float(number)
