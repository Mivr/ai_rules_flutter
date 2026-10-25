"""Tests for asset-URI normalization (flutter_tools 3.47.7 parity).

`asset_uri.bzl` is the one module that turns entry text into bundle keys:
`Uri.parse` plus `Uri(pathSegments:)` per segment, checked against the real
Dart SDK. Plain names and `packages`-first entries keep byte-identical keys;
anything else encodes like flutter_tools (`a b.png` bundles as `a%20b.png`,
the key the engine asks for) or is refused as not supported. The through
test runs the whole spoke chain (parse, normalize, expand, spoke dicts,
name check) over spaced names, showing manifest key, copy key and source
file for each entry.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:asset_uri.bzl", "encode_asset_key", "normalize_asset_uri", "normalize_spoke_assets", "normalize_spoke_fonts", "normalize_spoke_shaders", "pub_bundle_key", "spoke_asset_uri_error")
load("//flutter/private:flutter_pub_assets.bzl", "expand_pub_asset_entries")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "build_pkg_assets_dict",
    "build_pkg_shaders_dict",
    "check_spoke_file_names",
    "encode_spoke_fonts",
    "merge_pub_asset_conditions",
)
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block")

# The oracle file name below is built in pieces: the spellchecker reads its
# first three letters as a misspelling and rewrites the expected key, so the
# name is never written whole.
_CAFE_ENTRY = "ca" + "\303\251" + ".png"
_CAFE_KEY = "ca%C3%A9.png"

# The through test uses the spoke's dict builders directly: they are the
# exact comprehensions that turn expanded files into the generated
# `pkg_assets` / `font_files` / `pkg_shaders` attrs, so only they can prove
# the manifest key, copy key and source for each file.

def _check_ok(env, entry, decoded, key, is_dir = False):
    """Assert one entry normalizes to the expected decoded path and key."""
    norm = normalize_asset_uri(entry)
    asserts.true(env, norm.ok, entry)
    asserts.equals(env, decoded, norm.decoded)
    asserts.equals(env, key, norm.key)
    asserts.equals(env, is_dir, norm.is_dir)

def _plain_entry_passes_through_test_impl(ctx):
    """Plain entries keep byte-identical decoded paths and keys."""
    env = unittest.begin(ctx)
    _check_ok(env, "assets/a.png", "assets/a.png", "assets/a.png")
    _check_ok(env, "img/2.0x/logo.png", "img/2.0x/logo.png", "img/2.0x/logo.png")
    return unittest.end(env)

def _spaced_entry_encodes_test_impl(ctx):
    """A space encodes; the decoded path still names the file."""
    env = unittest.begin(ctx)
    _check_ok(env, "a b.png", "a b.png", "a%20b.png")
    _check_ok(env, "fonts/a b.ttf", "fonts/a b.ttf", "fonts/a%20b.ttf")
    _check_ok(env, "img/2.0x/a b.png", "img/2.0x/a b.png", "img/2.0x/a%20b.png")
    return unittest.end(env)

def _dot_entries_resolve_test_impl(ctx):
    """`.` drops and `x/..` resolves before keying, as Dart resolves."""
    env = unittest.begin(ctx)
    _check_ok(env, "./a.png", "a.png", "a.png")
    _check_ok(env, "a/./b.png", "a/b.png", "a/b.png")
    _check_ok(env, "img/../a.png", "a.png", "a.png")
    _check_ok(env, "%2E/a.png", "a.png", "a.png")
    _check_ok(env, "./d/", "d/", "d/", True)
    return unittest.end(env)

def _escapes_decode_first_test_impl(ctx):
    """Escapes decode first: `,` and `~` stay literal, lone `%` encodes."""
    env = unittest.begin(ctx)
    _check_ok(env, "a%2Cb.png", "a,b.png", "a,b.png")
    _check_ok(env, "%7e.png", "~.png", "~.png")
    _check_ok(env, "a%.png", "a%.png", "a%25.png")
    _check_ok(env, "a%2.png", "a%2.png", "a%252.png")
    _check_ok(env, "a%zz.png", "a%zz.png", "a%25zz.png")
    return unittest.end(env)

def _non_ascii_matches_dart_test_impl(ctx):
    """Non-ASCII names encode as UTF-8, exactly what Dart\'s Uri prints."""
    env = unittest.begin(ctx)
    _check_ok(env, _CAFE_ENTRY, _CAFE_ENTRY, _CAFE_KEY)
    _check_ok(env, "\342\202\254.png", "\342\202\254.png", "%E2%82%AC.png")
    _check_ok(env, "\344\270\255.png", "\344\270\255.png", "%E4%B8%AD.png")
    _check_ok(env, "\360\237\230\200.png", "\360\237\230\200.png", "%F0%9F%98%80.png")
    _check_ok(env, "%C3%A9.png", "\303\251.png", "%C3%A9.png")
    return unittest.end(env)

def _packages_first_passes_through_test_impl(ctx):
    """`packages`-first entries stay byte-identical, as on the base."""
    env = unittest.begin(ctx)
    _check_ok(env, "packages/foo/a.png", "packages/foo/a.png", "packages/foo/a.png")
    _check_ok(env, "packages/foo/a b.png", "packages/foo/a b.png", "packages/foo/a b.png")
    return unittest.end(env)

_REFUSALS = [
    ("img/a?.png", "query"),
    ("img/a#.png", "fragment"),
    ("a\\b.png", "backslash"),
    ("/a.png", "absolute"),
    ("a//b.png", "empty segment"),
    ("../a.png", "escapes"),
    ("..", "escapes"),
    (".", "names no file"),
    ("a/..", "names no file"),
    ("a/%2F/b.png", "decodes to `/`"),
    ("a/%FF/b.png", "not valid UTF-8"),
    ("a/%E2%82/b.png", "cut off"),
    ("a/%C0%AF/b.png", "not valid UTF-8"),
    ("a/%ED%A0%80/b.png", "not valid UTF-8"),
    ("a:b.png", "holds a `:`"),
    ("p/q:r.png", "holds a `:`"),
    ("%2e%2e/b.png", "escapes"),
    ("", "null or empty"),
    ("a\001b.png", "control character"),
]

def _refusals_name_the_spelling_test_impl(ctx):
    """Every unsupported spelling is refused, naming what offends."""
    env = unittest.begin(ctx)
    for entry, reason in _REFUSALS:
        norm = normalize_asset_uri(entry)
        asserts.false(env, norm.ok, entry)
        asserts.true(env, reason in norm.reason, entry + " -> " + norm.reason)
    return unittest.end(env)

# Every printable ASCII byte, in order: the test walks each as `v<C>.png`.
_PRINTABLE_ASCII = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~"

# Bytes that stay literal in a key (Dart\'s pchar set, minus `:` which is refused).
_LITERAL_BYTES = "-._~!$&'()*+,;=@ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"

# Bytes that encode, with the exact `%XX` Dart prints (oracle spot checks).
_ENCODED_BYTES = {
    " ": "%20",
    "\"": "%22",
    "%": "%25",
    "<": "%3C",
    ">": "%3E",
    "[": "%5B",
    "]": "%5D",
    "^": "%5E",
    "`": "%60",
    "{": "%7B",
    "|": "%7C",
    "}": "%7D",
}

_REFUSED_BYTES = ["#", "?", ":", "\\"]

def _printable_ascii_round_trip_test_impl(ctx):
    """All 95 printable bytes: exact keys, refusals, stable round trip."""
    env = unittest.begin(ctx)
    for c in _PRINTABLE_ASCII.elems():
        entry = "v" + c + ".png"
        norm = normalize_asset_uri(entry)
        if c in _REFUSED_BYTES:
            asserts.false(env, norm.ok, entry)
            continue
        asserts.true(env, norm.ok, entry)
        asserts.equals(env, entry, norm.decoded)
        if c in _LITERAL_BYTES or c == "/":
            asserts.equals(env, entry, norm.key)
        else:
            asserts.equals(env, "v" + _ENCODED_BYTES[c] + ".png", norm.key)
        again = normalize_asset_uri(norm.key)
        asserts.true(env, again.ok, norm.key)
        asserts.equals(env, norm.decoded, again.decoded)
        asserts.equals(env, norm.key, again.key)
    return unittest.end(env)

def _encode_asset_key_never_refuses_test_impl(ctx):
    """Filesystem truth encodes only: a literal `%` is data, not an escape."""
    env = unittest.begin(ctx)
    asserts.equals(env, "a%20b", encode_asset_key("a b"))
    asserts.equals(env, "a%25b", encode_asset_key("a%b"))
    asserts.equals(env, "2.0x/a%20b.png", encode_asset_key("2.0x/a b.png"))
    asserts.equals(env, "a%3Ab", encode_asset_key("a:b"))
    asserts.equals(env, "p/a:b", encode_asset_key("p/a:b"))
    asserts.equals(env, "ca%C3%A9", encode_asset_key("ca" + "\303\251"))
    return unittest.end(env)

def _pub_bundle_key_test_impl(ctx):
    """The contribution key prefixes the normalized key, idempotently."""
    env = unittest.begin(ctx)
    asserts.equals(env, "packages/pkg/a%20b.png", pub_bundle_key("packages/pkg/", "a b.png"))
    asserts.equals(env, "a.png", pub_bundle_key("", "a.png"))
    asserts.equals(env, "packages/pkg/a%20b.png", pub_bundle_key("packages/pkg/", "a%20b.png"))
    asserts.equals(env, "packages/pkg/a.png", pub_bundle_key("packages/pkg/", "./a.png"))
    return unittest.end(env)

def _spoke_error_names_package_test_impl(ctx):
    """The refusal names the package, its pubspec.yaml and the entry."""
    env = unittest.begin(ctx)
    message = spoke_asset_uri_error("uri_pkg", "a?.png", "it has a query part")
    for want in ["uri_pkg", "pubspec.yaml", "a?.png", "not supported", "it has a query part"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

# -- through the pub package ------------------------------------------------------

_THROUGH_PUBSPEC = """\
name: uri_pkg
flutter:
  assets:
    - ./a.png
    - path: a b.png
      platforms:
        - ios
    - ./d/
  fonts:
    - family: Spaced
      fonts:
        - asset: fonts/a b.ttf
  shaders:
    - shaders/a b.frag
"""

_THROUGH_FILES = {
    "": ["a.png", "a b.png", "2.0x/a.png"],
    "d": ["d/e f.txt"],
}

def _through_list_dir(directory):
    """Fake package listing: the root plus one directory with a spaced file."""
    return struct(files = _THROUGH_FILES.get(directory, []), error = "")

def _through_pub_package_test_impl(ctx):
    """Parse, normalize, expand, spoke dicts: key, copy key and source."""
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_THROUGH_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    assets = normalize_spoke_assets("uri_pkg", parsed.assets)
    fonts = normalize_spoke_fonts("uri_pkg", parsed.fonts)
    shaders = normalize_spoke_shaders("uri_pkg", parsed.shaders)
    result = expand_pub_asset_entries(assets, _through_list_dir, "uri_pkg")
    asserts.equals(env, "", result.error)
    asserts.equals(
        env,
        ["a.png", "2.0x/a.png", "a b.png", "d/e f.txt"],
        [e.path for e in result.expanded],
    )
    asserts.equals(
        env,
        ["a.png", "2.0x/a.png", "a%20b.png", "d/e%20f.txt"],
        [e.key for e in result.expanded],
    )
    pkg_assets = build_pkg_assets_dict(result.expanded)
    for source, key in [
        ("a.png", "a.png"),
        ("2.0x/a.png", "2.0x/a.png"),
        ("a b.png", "a%20b.png"),
        ("d/e f.txt", "d/e%20f.txt"),
    ]:
        asserts.equals(env, key, pkg_assets[":" + source])
    merged = merge_pub_asset_conditions(result.expanded, "uri_pkg")
    asserts.equals(env, "", merged.conflict)
    asserts.equals(env, ["ios"], merged.platforms.get(":a b.png"))
    spoke_fonts = encode_spoke_fonts(fonts)
    asserts.equals(env, {":fonts/a b.ttf": "fonts/a%20b.ttf"}, spoke_fonts.font_files)
    asserts.true(env, "fonts/a%20b.ttf" in spoke_fonts.fonts_json_str, spoke_fonts.fonts_json_str)
    asserts.equals(
        env,
        {":shaders/a b.frag": "shaders/a%20b.frag"},
        build_pkg_shaders_dict(shaders),
    )
    asserts.equals(
        env,
        None,
        check_spoke_file_names(
            "uri_pkg",
            struct(assets = assets, fonts = fonts, shaders = shaders),
            result.expanded,
        ),
    )
    return unittest.end(env)

_REFUSED_PUBSPEC = """\
name: refused_pkg
flutter:
  assets:
    - a?.png
"""

def _through_refusal_test_impl(ctx):
    """A pubspec entry no engine build reads fails as not supported."""
    env = unittest.begin(ctx)
    parsed = parse_flutter_assets_block(_REFUSED_PUBSPEC)
    asserts.equals(env, [], parsed.asset_errors)
    asserts.equals(env, 1, len(parsed.assets))
    norm = normalize_asset_uri(parsed.assets[0].path)
    asserts.false(env, norm.ok, parsed.assets[0].path)
    message = spoke_asset_uri_error("refused_pkg", parsed.assets[0].path, norm.reason)
    for want in ["refused_pkg", "pubspec.yaml", "a?.png", "not supported"]:
        asserts.true(env, want in message, message)
    return unittest.end(env)

_t0_test = unittest.make(_plain_entry_passes_through_test_impl)
_t1_test = unittest.make(_spaced_entry_encodes_test_impl)
_t2_test = unittest.make(_dot_entries_resolve_test_impl)
_t3_test = unittest.make(_escapes_decode_first_test_impl)
_t4_test = unittest.make(_non_ascii_matches_dart_test_impl)
_t5_test = unittest.make(_packages_first_passes_through_test_impl)
_t6_test = unittest.make(_refusals_name_the_spelling_test_impl)
_t7_test = unittest.make(_printable_ascii_round_trip_test_impl)
_t8_test = unittest.make(_encode_asset_key_never_refuses_test_impl)
_t9_test = unittest.make(_pub_bundle_key_test_impl)
_t10_test = unittest.make(_spoke_error_names_package_test_impl)
_t11_test = unittest.make(_through_pub_package_test_impl)
_t12_test = unittest.make(_through_refusal_test_impl)

def asset_uri_test_suite(name):
    """Defines the asset-URI normalization unit and through tests.

    Args:
        name: Name of the resulting test_suite.
    """
    unittest.suite(
        name,
        _t0_test,
        _t1_test,
        _t2_test,
        _t3_test,
        _t4_test,
        _t5_test,
        _t6_test,
        _t7_test,
        _t8_test,
        _t9_test,
        _t10_test,
        _t11_test,
        _t12_test,
    )
