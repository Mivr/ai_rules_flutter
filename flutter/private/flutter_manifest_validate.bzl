"""Fail-closed validation of a pub package's `flutter:` section, mirroring flutter_tools.

flutter_tools 3.47.7 validates every package's pubspec with `_validate` in
`packages/flutter_tools/lib/src/flutter_manifest.dart` (and what it calls:
`_validateFlutter`, `_validateFonts`, `_computeAssetsSafe`,
`_validateDeferredComponents`, `_parseList`, and `Plugin.validatePluginYaml`
in `plugins.dart` with each platform's `validate` in `platform_plugins.dart`).
Any error it reports stops an app's build ("Please correct the pubspec.yaml
file"); for a dependency package its assets, fonts and licenses are dropped.

`parse_flutter_assets_block` in `flutter_pubspec.bzl` parses the section
leniently, so this module re-checks the parsed value with the same checks and
returns one refusal per error. The spoke fails the fetch on each through the
single `asset_errors` / `check_asset_entry_problems` path, naming the package,
`pubspec.yaml` and the offending line. Refusal details reuse flutter_tools'
wording. Shapes flutter_tools only warns on (a font family without `family`,
a font file entry without `asset`, an empty map asset entry) stay silent.
"""

def _refusal(path, key, detail, line):
    """One `asset_errors` refusal for a malformed `flutter:` section shape.

    Args:
        path: The entry the problem is reported against: a real entry path,
            an indexed `key[index]` slot, or the key itself for a
            whole-section shape.
        key: The section key (`"assets"`, `"fonts"`, `"plugin"`, ...), for
            the failure message.
        detail: The complaint, worded like flutter_tools where it has one.
        line: The 1-based `pubspec.yaml` line of the offending key or entry.

    Returns:
        A `struct(path, key, detail, line)` as `check_asset_entry_problems`
        takes it.
    """
    return struct(path = path, key = key, detail = detail, line = line)

# ---------------------------------------------------------------------------
# Line numbers
# ---------------------------------------------------------------------------

def _indent_of(line):
    """The leading-whitespace width of `line` (spaces and tabs count one)."""
    width = 0
    for ch in line.elems():
        if ch == " " or ch == "\t":
            width += 1
        else:
            break
    return width

def _is_real_line(text):
    """True when stripped `text` carries YAML content (not blank or a comment)."""
    return text != "" and not text.startswith("#")

def _key_head(text):
    """The mapping key a stripped line declares, or "" when it declares none.

    `assets: foo`, `assets:` and `assets : foo` all declare `assets`; a quoted
    `'assets': foo` declares `assets` too. A list item (`- family: F`) or a
    scalar declares nothing: the head before the colon never equals the key.
    """
    idx = text.find(":")
    if idx < 0:
        return ""
    head = text[:idx].strip()
    if len(head) >= 2 and head[0] == head[-1] and (head[0] == '"' or head[0] == "'"):
        head = head[1:-1]
    return head

def _is_dash_line(text):
    """True when stripped `text` opens a block-sequence item (`-` or `- ...`)."""
    return text == "-" or text.startswith("- ")

def _span_end(lines, start, parent_indent, in_item):
    """First index at or after `start` outside the block nested under `parent_indent`.

    A block opened by a key (or item) at `parent_indent` runs until the next
    content line at or above that indent, or `len(lines)` at the end. A `-`
    line at the key's own column is the key's compact sequence (see
    `parse_pubspec_document`), so outside an item scope it belongs to the key
    instead of ending the span.

    Args:
        lines: The pubspec text split on newlines.
        start: First index the span may cover.
        parent_indent: Indent of the key or item line that opened the block.
        in_item: True when the scope was opened by a list item: a `-` line at
            the same indent is the next item and ends the span.

    Returns:
        The first index past the block.
    """
    for i in range(start, len(lines)):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        indent = _indent_of(lines[i])
        if indent > parent_indent:
            continue
        if not in_item and indent == parent_indent and _is_dash_line(text):
            continue
        return i
    return len(lines)

def _child_key_line(lines, start, end, parent_indent, key):
    """Line index of `key:` in `[start, end)` nested under `parent_indent`, or -1.

    The shallowest match wins (a deeper same-named key belongs to a nested
    map), then the first. A value written in flow on the key's own line keeps
    the key's line: there is nothing deeper to find.
    """
    best = -1
    best_indent = 0
    for i in range(start, end):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        indent = _indent_of(lines[i])
        if indent <= parent_indent:
            continue
        if _key_head(text) != key:
            continue
        if best == -1 or indent < best_indent:
            best = i
            best_indent = indent
    return best

def _list_item_line(lines, start, end, parent_indent, index):
    """Line index of the `index`th block-sequence item in `[start, end)`, or -1.

    Items sit at the shallowest `-` indent in the span (a compact sequence sits
    at its key's own column; deeper `-` lines belong to nested lists). No item
    means the sequence is written in flow (`fonts: [1]`), so the caller falls
    back to the key's own line.
    """
    seq_indent = -1
    for i in range(start, end):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        indent = _indent_of(lines[i])
        if indent < parent_indent:
            continue
        if _is_dash_line(text):
            if seq_indent == -1 or indent < seq_indent:
                seq_indent = indent
    if seq_indent == -1:
        return -1
    seen = 0
    for i in range(start, end):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        if _indent_of(lines[i]) != seq_indent:
            continue
        if _is_dash_line(text):
            if seen == index:
                return i
            seen += 1
    return -1

def _flutter_section_line(lines):
    """Line index of the top-level `flutter:` key, or -1 when absent."""
    for i in range(len(lines)):
        text = lines[i].strip()
        if not _is_real_line(text):
            continue
        if _indent_of(lines[i]) == 0 and _key_head(text) == "flutter":
            return i
    return -1

def flutter_line_of(lines, locator):
    """The 1-based `pubspec.yaml` line of the entry `locator` names.

    `locator` starts at `"flutter"` and alternates child keys and list
    indices, e.g. `["flutter", "fonts", 0, "fonts", 1, "weight"]`. Each step
    descends into the key's (or item's) block; a step with nothing deeper to
    find (a value in flow, a missing key, a short list) resolves to the
    deepest line found so far. The answer is therefore always the closest
    named line: the key holding a flow collection, the item holding an inline
    map, the section key, or `flutter:` itself.

    Args:
        lines: The pubspec text split on newlines.
        locator: The `["flutter", key-or-index, ...]` path to the entry.

    Returns:
        The 1-based line number, always at least 1.
    """
    section = _flutter_section_line(lines)
    if section == -1:
        return 1
    if len(locator) <= 1:
        return section + 1
    line = section + 1
    indent = _indent_of(lines[section])
    start = section + 1
    in_item = False
    for step in locator[1:]:
        end = _span_end(lines, start, indent, in_item)
        if type(step) == "string":
            found = _child_key_line(lines, start, end, indent, step)
        else:
            found = _list_item_line(lines, start, end, indent, step)
        if found == -1:
            return line
        line = found + 1
        indent = _indent_of(lines[found])
        start = found + 1
        in_item = type(step) != "string"
    return line

# ---------------------------------------------------------------------------
# Scalar flags: uses-material-design, default-flavor, disable-swift-package-manager
# ---------------------------------------------------------------------------

def _uses_material_design_problem(flutter, lines):
    """The refusal when `uses-material-design` is present but not a bool.

    Mirrors the `uses-material-design` case in `_validateFlutter`
    (`flutter_manifest.dart`): a string `"yes"` or an empty value reads as
    false today, silently dropping the material icons, where flutter_tools
    refuses the package.
    """
    value = flutter["uses-material-design"]
    if type(value) == "bool":
        return []
    return [_refusal(
        "uses-material-design",
        "uses-material-design",
        "Expected \"uses-material-design\" to be a bool, but got {value} ({type}).".format(
            value = str(value),
            type = type(value),
        ),
        flutter_line_of(lines, ["flutter", "uses-material-design"]),
    )]

def _default_flavor_problem(flutter, lines):
    """The refusal when `default-flavor` is present but not a string.

    Mirrors the `default-flavor` case in `_validateFlutter`
    (`flutter_manifest.dart`).
    """
    value = flutter["default-flavor"]
    if type(value) == "string":
        return []
    return [_refusal(
        "default-flavor",
        "default-flavor",
        "Expected \"default-flavor\" to be a string, but got {value} ({type}).".format(
            value = str(value),
            type = type(value),
        ),
        flutter_line_of(lines, ["flutter", "default-flavor"]),
    )]

def _moved_swift_package_manager_problem(lines):
    """The refusal for any `disable-swift-package-manager` entry.

    Mirrors the `disable-swift-package-manager` case in `_validateFlutter`
    (`flutter_manifest.dart`): the key moved under `config`, so its presence
    at any value (even empty) is an error carrying the migration.
    """
    return _refusal(
        "disable-swift-package-manager",
        "disable-swift-package-manager",
        "The \"disable-swift-package-manager\" configuration has moved. In your pubspec.yaml:\n" +
        "# Before\n" +
        "flutter:\n" +
        "  disable-swift-package-manager: true\n" +
        "\n" +
        "# After\n" +
        "flutter:\n" +
        "  config:\n" +
        "    enable-swift-package-manager: false\n",
        flutter_line_of(lines, ["flutter", "disable-swift-package-manager"]),
    )

# ---------------------------------------------------------------------------
# Unknown children and non-string keys
# ---------------------------------------------------------------------------

def _unexpected_child_problem(key, lines):
    """The refusal for an unknown `key` directly under `flutter:`.

    Mirrors the `default` case in `_validateFlutter`
    (`flutter_manifest.dart`).
    """
    return _refusal(
        key,
        key,
        "Unexpected child \"{key}\" found under \"flutter\".".format(key = key),
        flutter_line_of(lines, ["flutter", key]),
    )

def _non_string_key_problem(key, value, lines):
    """The refusal for a non-string `key` directly under `flutter:`.

    Mirrors the non-string-key case in `_validateFlutter`
    (`flutter_manifest.dart`). The line is the section's own: a non-string
    key cannot be named by a locator.
    """
    return _refusal(
        "flutter",
        "flutter",
        "Expected YAML key to be a string, but got {key} ({type}).".format(
            key = str(key),
            type = type(value),
        ),
        flutter_line_of(lines, ["flutter"]),
    )

# ---------------------------------------------------------------------------
# licenses
# ---------------------------------------------------------------------------

def _licenses_problems(flutter, lines):
    """The refusals for a malformed `flutter.licenses` value.

    Mirrors the `licenses` case in `_validateFlutter` (`_parseList` in
    `flutter_manifest.dart`): the value must be a list of file paths. A
    scalar `licenses: a.txt` loads today and silently grants no license.
    An absent or empty value reads as null and is valid.
    """
    raw = flutter.get("licenses")
    if raw == None:
        return []
    locator = ["flutter", "licenses"]
    if type(raw) != "list":
        return [_refusal(
            "licenses",
            "licenses",
            "Expected \"licenses\" to be a list of files, but got {value} ({type}).".format(
                value = str(raw),
                type = type(raw),
            ),
            flutter_line_of(lines, locator),
        )]
    problems = []
    for index, item in enumerate(raw):
        if type(item) != "string":
            problems.append(_refusal(
                "licenses[{index}]".format(index = index),
                "licenses",
                "Expected \"licenses\" to be a list of files, but element at index {index} was a {type}.".format(
                    index = index,
                    type = type(item),
                ),
                flutter_line_of(lines, locator + [index]),
            ))
    return problems

# ---------------------------------------------------------------------------
# module
# ---------------------------------------------------------------------------

def _module_problems(flutter, lines):
    """The refusals for a malformed `flutter.module` value.

    Mirrors the `module` case in `_validateFlutter`
    (`flutter_manifest.dart`): the value must be a map, and `androidX` must
    be a bool, `androidPackage` a string and `iosBundleIdentifier` a string
    when set. Each check is independent, so all are reported. An absent or
    empty value reads as null and is valid.
    """
    raw = flutter.get("module")
    if raw == None:
        return []
    locator = ["flutter", "module"]
    if type(raw) != "dict":
        return [_refusal(
            "module",
            "module",
            "Expected \"module\" to be an object, but got {value} ({type}).".format(
                value = str(raw),
                type = type(raw),
            ),
            flutter_line_of(lines, locator),
        )]
    problems = []
    android_x = raw.get("androidX")
    if android_x != None and type(android_x) != "bool":
        problems.append(_refusal(
            "module",
            "module",
            "The \"androidX\" value must be a bool if set.",
            flutter_line_of(lines, locator + ["androidX"]),
        ))
    android_package = raw.get("androidPackage")
    if android_package != None and type(android_package) != "string":
        problems.append(_refusal(
            "module",
            "module",
            "The \"androidPackage\" value must be a string if set.",
            flutter_line_of(lines, locator + ["androidPackage"]),
        ))
    bundle_id = raw.get("iosBundleIdentifier")
    if bundle_id != None and type(bundle_id) != "string":
        problems.append(_refusal(
            "module",
            "module",
            "The \"iosBundleIdentifier\" section must be a string if set.",
            flutter_line_of(lines, locator + ["iosBundleIdentifier"]),
        ))
    return problems

# ---------------------------------------------------------------------------
# plugin
# ---------------------------------------------------------------------------

# Keys of the legacy plugin format (plugins.dart `validatePluginYaml`).
_OLD_PLUGIN_KEYS = ("androidPackage", "iosPrefix", "pluginClass")

# Platforms `_validateMultiPlatformYaml` (plugins.dart) validates. `web` is
# deliberately absent: flutter_tools does not validate it there.
_VALIDATED_PLUGIN_PLATFORMS = ("android", "ios", "linux", "macos", "windows")

def _is_plugin_identifier(value):
    """True when `value` is a valid plugin class or package identifier.

    Mirrors `_pluginIdentifierPattern` (`^[a-zA-Z_$][a-zA-Z0-9_$]*` dot-joined,
    in `platform_plugins.dart`): plugin `class`/`package` values are
    interpolated verbatim into the generated registrant, so each dot-separated
    part must start with a letter, `_` or `$` and continue with those or
    digits. Starlark has no regex, so the pattern is checked by hand.
    """
    if type(value) != "string" or value == "":
        return False
    for part in value.split("."):
        if part == "":
            return False
        if part[0] not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_$":
            return False
        for ch in part.elems():
            if ch not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ_0123456789$":
                return False
    return True

def _platform_entry_invalid(info, platform):
    """True when a `flutter.plugin.platforms.<platform>` map is invalid.

    Mirrors each platform's `validate` in `platform_plugins.dart`: an entry
    must declare an implementation (a native `package` plus `pluginClass` on
    Android, a `pluginClass` elsewhere, or a `dartPluginClass`, `ffiPlugin`,
    `sharedDarwinSource` on darwin, or `default_package` anywhere), and every
    identifier present must match the plugin identifier pattern.
    """
    package = info.get("package")
    plugin_class = info.get("pluginClass")
    dart_class = info.get("dartPluginClass")
    ffi = info.get("ffiPlugin") == True
    default = type(info.get("default_package")) == "string"
    if platform == "android":
        declared = (type(package) == "string" and type(plugin_class) == "string")
        declared = declared or type(dart_class) == "string" or ffi or default
    elif platform == "ios" or platform == "macos":
        declared = type(plugin_class) == "string" or type(dart_class) == "string"
        declared = declared or ffi or info.get("sharedDarwinSource") == True or default
    else:
        declared = type(plugin_class) == "string" or type(dart_class) == "string"
        declared = declared or ffi or default
    if not declared:
        return True
    if platform == "android" and type(package) == "string" and not _is_plugin_identifier(package):
        return True
    if type(plugin_class) == "string" and not _is_plugin_identifier(plugin_class):
        return True
    if type(dart_class) == "string" and not _is_plugin_identifier(dart_class):
        return True
    return False

def _multi_platform_problems(plugin, lines, locator):
    """The refusals for a malformed new-format `flutter.plugin` value.

    Mirrors `_validateMultiPlatformYaml` (plugins.dart): `platforms` must be
    a map (an empty one is valid), and each validated platform entry must be
    a map the platform accepts (an entry carrying `default_package` is valid
    whatever else it holds). Unknown platforms and `web` are ignored.
    """
    platforms = plugin.get("platforms")
    if type(platforms) != "dict":
        if platforms == None:
            detail = "Invalid \"platforms\" specification."
        else:
            detail = "flutter.plugin.platforms should be a map with the platform name as the key"
        return [_refusal(
            "plugin",
            "plugin",
            detail,
            flutter_line_of(lines, locator + ["platforms"]),
        )]
    problems = []
    for platform in _VALIDATED_PLUGIN_PLATFORMS:
        if platform not in platforms:
            continue
        info = platforms[platform]
        if type(info) != "dict" or ("default_package" not in info and _platform_entry_invalid(info, platform)):
            problems.append(_refusal(
                "plugin",
                "plugin",
                "Invalid \"{platform}\" plugin specification.".format(platform = platform),
                flutter_line_of(lines, locator + ["platforms", platform]),
            ))
    return problems

def _legacy_plugin_problems(plugin, lines, locator):
    """The refusals for a malformed legacy-format `flutter.plugin` value.

    Mirrors `_validateLegacyYaml` (plugins.dart): each legacy key must be a
    string or null when present.
    """
    checks = (
        ("androidPackage", "The \"androidPackage\" must either be null or a string."),
        ("iosPrefix", "The \"iosPrefix\" must either be null or a string."),
        ("pluginClass", "The \"pluginClass\" must either be null or a string."),
    )
    problems = []
    for key, detail in checks:
        value = plugin.get(key)
        if value != None and type(value) != "string":
            problems.append(_refusal(
                "plugin",
                "plugin",
                detail,
                flutter_line_of(lines, locator + [key]),
            ))
    return problems

def _plugin_problems(flutter, lines):
    """The refusals for a malformed `flutter.plugin` value.

    Mirrors the `plugin` case in `_validateFlutter` (`flutter_manifest.dart`)
    and `Plugin.validatePluginYaml` (plugins.dart): the value must be a map
    (an empty `plugin: {}` carries neither format and fails), the old
    `androidPackage`/`iosPrefix`/`pluginClass` keys cannot combine with
    `platforms`, and each format validates as above. Extra keys beside a
    valid `platforms` map are ignored, as flutter_tools ignores them.
    """
    if "plugin" not in flutter:
        return []
    locator = ["flutter", "plugin"]
    value = flutter["plugin"]
    if type(value) != "dict":
        return [_refusal(
            "plugin",
            "plugin",
            "Expected \"plugin\" to be an object, but got {value} ({type}).".format(
                value = str(value),
                type = type(value),
            ),
            flutter_line_of(lines, locator),
        )]
    uses_old = False
    for key in _OLD_PLUGIN_KEYS:
        if key in value:
            uses_old = True
    uses_new = "platforms" in value
    if uses_old and uses_new:
        return [_refusal(
            "plugin",
            "plugin",
            "The flutter.plugin.platforms key cannot be used in combination with the old " +
            "flutter.plugin.{androidPackage,iosPrefix,pluginClass} keys. " +
            "See: https://flutter.dev/to/pubspec-plugin-platforms",
            flutter_line_of(lines, locator),
        )]
    if not uses_old and not uses_new:
        return [_refusal(
            "plugin",
            "plugin",
            "Cannot find the `flutter.plugin.platforms` key in the `pubspec.yaml` file. " +
            "An instruction to format the `pubspec.yaml` can be found here: " +
            "https://flutter.dev/to/pubspec-plugin-platforms",
            flutter_line_of(lines, locator),
        )]
    if uses_new:
        return _multi_platform_problems(value, lines, locator)
    return _legacy_plugin_problems(value, lines, locator)

# ---------------------------------------------------------------------------
# deferred-components
# ---------------------------------------------------------------------------

def _libraries_problems(libraries, index, lines, locator):
    """The refusals for a malformed deferred-component `libraries` value.

    Mirrors the `libraries` check in `_validateDeferredComponents`
    (`flutter_manifest.dart`): a present value (even an empty one) must be a
    list of strings.
    """
    context = "\"libraries\" key in the element at index {index} of \"deferred-components\"".format(
        index = index,
    )
    if type(libraries) != "list":
        return [_refusal(
            "deferred-components",
            "deferred-components",
            "Expected {context} to be a list of String, but got {value} ({type}).".format(
                context = context,
                value = str(libraries),
                type = type(libraries),
            ),
            flutter_line_of(lines, locator),
        )]
    problems = []
    for position, item in enumerate(libraries):
        if type(item) != "string":
            problems.append(_refusal(
                "deferred-components",
                "deferred-components",
                "Expected {context} to be a list of String, but element at index {position} was a {type}.".format(
                    context = context,
                    position = position,
                    type = type(item),
                ),
                flutter_line_of(lines, locator + [position]),
            ))
    return problems

def _deferred_problems(flutter, scope):
    """The refusals for a malformed `flutter.deferred-components` value.

    Mirrors `_validateDeferredComponents` (`flutter_manifest.dart`): an
    absent or empty value is valid (flutter_tools itself crashes on an empty
    list, which is never a reported error, so it stays accepted here); any
    other non-list value, or a list whose first element is not a map, is one
    refusal naming the whole value. Each map element needs a string `name`,
    a string list `libraries` when present, and valid `assets` when present
    (checked by the caller's asset validator, which shares the top-level
    asset rules; the entries are validated only, never bundled).

    Args:
        flutter: The parsed `flutter:` mapping.
        scope: A `struct(lines, check_assets)`: the pubspec text split on
            newlines, and a `check_assets(raw, locator, shown)` callable
            returning that value's asset problems (it lives with the asset
            parser so this module never loads it back).

    Returns:
        The refusal structs for `asset_errors`.
    """
    if "deferred-components" not in flutter:
        return []
    raw = flutter["deferred-components"]
    if raw == None:
        return []
    locator = ["flutter", "deferred-components"]
    if type(raw) != "list" or (len(raw) > 0 and type(raw[0]) != "dict"):
        return [_refusal(
            "deferred-components",
            "deferred-components",
            "Expected \"deferred-components\" to be a list, but got {value} ({type}).".format(
                value = str(raw),
                type = type(raw),
            ),
            flutter_line_of(scope.lines, locator),
        )]
    problems = []
    for index, element in enumerate(raw):
        elocator = locator + [index]
        if type(element) != "dict":
            problems.append(_refusal(
                "deferred-components[{index}]".format(index = index),
                "deferred-components",
                "Expected the {index} element in \"deferred-components\" to be a map, but got {value} ({type}).".format(
                    index = index,
                    value = str(element),
                    type = type(element),
                ),
                flutter_line_of(scope.lines, elocator),
            ))
            continue
        if type(element.get("name")) != "string":
            problems.append(_refusal(
                "deferred-components[{index}]".format(index = index),
                "deferred-components",
                "Expected the {index} element in \"deferred-components\" to have required key \"name\" of type String".format(
                    index = index,
                ),
                flutter_line_of(scope.lines, elocator + ["name"]),
            ))
        if element.get("libraries") != None:
            problems.extend(_libraries_problems(
                element["libraries"],
                index,
                scope.lines,
                elocator + ["libraries"],
            ))
        if "assets" in element:
            problems.extend(scope.check_assets(
                element["assets"],
                elocator + ["assets"],
                "deferred-components[{index}].assets".format(index = index),
            ))
    return problems

# ---------------------------------------------------------------------------
# Section entry point
# ---------------------------------------------------------------------------

def validate_flutter_section(flutter, scope):
    """Validate one parsed `flutter:` mapping the way flutter_tools does.

    Dispatches per key in document order over the checks above. `assets`,
    `shaders` and `fonts` shapes are validated by the asset parser (which
    shares this module's line finder), and `generate` and `config` carry no
    checks in flutter_tools, so those keys contribute nothing here.

    Args:
        flutter: The parsed `flutter:` mapping ({} when absent).
        scope: A `struct(lines, check_assets)` as `_deferred_problems`
            takes it.

    Returns:
        The refusal structs for `asset_errors`, in document order.
    """
    problems = []
    for key in flutter.keys():
        if type(key) != "string":
            problems.append(_non_string_key_problem(key, flutter[key], scope.lines))
        elif key == "uses-material-design":
            problems.extend(_uses_material_design_problem(flutter, scope.lines))
        elif key == "licenses":
            problems.extend(_licenses_problems(flutter, scope.lines))
        elif key == "module":
            problems.extend(_module_problems(flutter, scope.lines))
        elif key == "plugin":
            problems.extend(_plugin_problems(flutter, scope.lines))
        elif key == "deferred-components":
            problems.extend(_deferred_problems(flutter, scope))
        elif key == "disable-swift-package-manager":
            problems.append(_moved_swift_package_manager_problem(scope.lines))
        elif key == "default-flavor":
            problems.extend(_default_flavor_problem(flutter, scope.lines))
        elif key == "assets" or key == "shaders" or key == "fonts":
            pass
        elif key == "generate" or key == "config":
            pass
        else:
            problems.append(_unexpected_child_problem(key, scope.lines))
    return problems
