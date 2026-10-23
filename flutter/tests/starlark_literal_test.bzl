"""Unit tests for the spoke BUILD escaping helper (`starlark_literal.bzl`).

The spoke generators paste pubspec-declared and file-system-walked names
into generated BUILD files. Each test below pins that the helper's output
is a literal the Starlark parser reads back to the exact input: the
expected value is written as a literal in this file, so equality means the
emitted text parses back to the input. Final tests pin that quote-,
backslash- and mixed-odd names render escaped (not spliced raw) in
generated `flutter_library` and `flutter_plugin` spokes, and that the
refusal for unrepresentable names carries the package, entry and file.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "make_flutter_library_build_content",
    "make_flutter_plugin_build_content",
)
load(
    "//flutter/private:starlark_literal.bzl",
    "check_spoke_file_name",
    "spoke_file_name_error",
    "starlark_string_literal",
)

def _literal_round_trip_test_impl(ctx):
    """Quotes, backslashes, newlines, `$` and non-ASCII survive the helper."""
    env = unittest.begin(ctx)

    cases = [
        ("plain.txt", '"plain.txt"'),
        (":assets/note.txt", '":assets/note.txt"'),
        ('say"hi.txt', '"say\\"hi.txt"'),
        ("back\\slash.txt", '"back\\\\slash.txt"'),
        ('both"and\\here.txt', '"both\\"and\\\\here.txt"'),
        ("line\nbreak.txt", '"line\\nbreak.txt"'),
        ("$HOME/x.txt", '"$HOME/x.txt"'),
        ("café.txt", '"café.txt"'),
    ]
    for inp, want in cases:
        asserts.equals(env, want, starlark_string_literal(inp), inp)

    return unittest.end(env)

literal_round_trip_test = unittest.make(_literal_round_trip_test_impl)

def _odd_name_error_names_all_three_test_impl(ctx):
    """Each refusal names the package, the declaring entry and the file."""
    env = unittest.begin(ctx)

    for entry, bad in [
        ("assets/", "assets/a:b.txt"),
        ("assets/", "assets/has\nnewline.txt"),
        ("assets/", "assets/has\rcarriage.txt"),
        ("assets/", ""),
    ]:
        err = spoke_file_name_error("mypkg", entry, bad)
        asserts.true(env, "mypkg" in err, err)
        asserts.true(env, entry in err, err)
        asserts.true(env, starlark_string_literal(bad) in err, err)

    return unittest.end(env)

odd_name_error_names_all_three_test = unittest.make(
    _odd_name_error_names_all_three_test_impl,
)

def _ordinary_name_passes_test_impl(ctx):
    """Ordinary names (including quotes) pass the fetch-time check."""
    env = unittest.begin(ctx)

    asserts.equals(env, None, check_spoke_file_name("p", "assets/", "assets/note.txt"))
    asserts.equals(env, None, check_spoke_file_name("p", "assets/", 'assets/say"hi.txt'))

    return unittest.end(env)

ordinary_name_passes_test = unittest.make(_ordinary_name_passes_test_impl)

def _odd_names_render_escaped_test_impl(ctx):
    """Odd names render escaped in generated spokes, never spliced raw."""
    env = unittest.begin(ctx)

    odd = ['say"hi.txt', "back\\slash.txt", 'both"and\\mix.txt']
    assets = {}
    for name in odd:
        assets[":" + name] = name

    library = make_flutter_library_build_content(
        name = "odd_assets",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = dict(assets),
        pkg_shaders = {},
        version = "0.1.0",
    )
    plugin = make_flutter_plugin_build_content(
        name = "odd_plugin",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        plugin_platforms_json = '{"web":{"pluginClass":"WebPlugin"}}',
        apple_macos_srcs_dirs = [],
        apple_ios_srcs_dirs = [],
        apple_macos_include_dirs = [],
        apple_ios_include_dirs = [],
        apple_macos_privacy_manifests = [],
        apple_ios_privacy_manifests = [],
        linux_src_dir = "",
        windows_src_dir = "",
        pkg_assets = dict(assets),
        version = "0.1.0",
    )

    for name in odd:
        want = starlark_string_literal(":" + name) + ": " + starlark_string_literal(name) + ","
        asserts.true(env, want in library, want)
        asserts.true(env, want in plugin, want)
        asserts.false(env, '":' + name + '"' in library, name)
        asserts.false(env, '":' + name + '"' in plugin, name)

    return unittest.end(env)

odd_names_render_escaped_test = unittest.make(
    _odd_names_render_escaped_test_impl,
)

def starlark_literal_test_suite(name):
    unittest.suite(
        name,
        literal_round_trip_test,
        odd_name_error_names_all_three_test,
        ordinary_name_passes_test,
        odd_names_render_escaped_test,
    )
