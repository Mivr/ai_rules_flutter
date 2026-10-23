"""Unit tests for the spoke BUILD escaping helper (`starlark_literal.bzl`).

The spoke generators paste pubspec-declared and file-system-walked names
into generated BUILD files. Each test below pins that the helper's output
is a literal the Starlark parser reads back to the exact input: the
expected value is written as a literal in this file, so equality means the
emitted text parses back to the input. A final test pins that a
quote-named asset renders escaped (not spliced raw) in a generated
`flutter_library` spoke.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_package.bzl", "make_flutter_library_build_content")
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
    """The refusal names the package, the declaring entry and the file."""
    env = unittest.begin(ctx)

    err = spoke_file_name_error("mypkg", "assets/", "assets/a:b.txt")
    asserts.true(env, "mypkg" in err, err)
    asserts.true(env, "assets/" in err, err)
    asserts.true(env, "assets/a:b.txt" in err, err)

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

def _generated_dict_escapes_quote_test_impl(ctx):
    """A quote-named asset renders escaped in a generated spoke, not raw."""
    env = unittest.begin(ctx)

    content = make_flutter_library_build_content(
        name = "quote_assets",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {':assets/say"hi.txt': 'assets/say"hi.txt'},
        pkg_shaders = {},
        version = "0.1.0",
    )

    asserts.true(env, '":assets/say\\"hi.txt": "assets/say\\"hi.txt",' in content, content)
    asserts.false(env, '":assets/say"hi.txt"' in content, content)

    return unittest.end(env)

generated_dict_escapes_quote_test = unittest.make(
    _generated_dict_escapes_quote_test_impl,
)

def starlark_literal_test_suite(name):
    unittest.suite(
        name,
        literal_round_trip_test,
        odd_name_error_names_all_three_test,
        ordinary_name_passes_test,
        generated_dict_escapes_quote_test,
    )
