"""Compose `flutter.pub(ios_plugin_defines = ...)` entries into compile options.

Every entry (`NAME` or `NAME=VALUE`) becomes a target-local `-D<entry>` on a
C-family compile. A Swift compilation condition carries no value, so only a
value-less `NAME` reaches a Swift compile. The composition uses `+` so a
`select()` from `.when(platforms:)` stays concatenable.
"""

def plugin_define_copts(defines):
    """The C-family `-D` flags for a plugin's define entries, in order."""
    return ["-D" + define for define in defines]

def plugin_swift_define_copts(defines):
    """The Swift `-D` flags: only value-less entries, because a condition has no value."""
    return ["-D" + define for define in defines if "=" not in define]

def plugin_objc_copts(copts, objc_copts, plugin_defines):
    """Compose ObjC compile options, keeping a `select()` in `copts` intact."""
    return copts + objc_copts + plugin_define_copts(plugin_defines)

def plugin_swift_copts(copts, plugin_defines):
    """Compose Swift compile options, keeping a `select()` in `copts` intact."""
    return copts + plugin_swift_define_copts(plugin_defines)
