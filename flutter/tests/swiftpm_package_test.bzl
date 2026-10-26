"""Unit tests for SwiftPM target file selection (skip, classify, entry drops)."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:swiftpm_manifest.bzl", "parse_swiftpm_package")
load("//flutter/private:swiftpm_package.bzl", "swiftpm_is_code_file", "swiftpm_select_target_files")

_DOCS = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Docs",
    products: [.library(name: "Docs", targets: ["Docs"])],
    targets: [.target(name: "Docs")],
)
"""

_EXCLUDE = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", exclude: ["Missing", "Ghost.swift", "Sub"])],
)
"""

_SOURCES = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", sources: ["Real.swift", "Ghost.swift"])],
)
"""

_SOURCES_ALL_MISSING = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", sources: ["Ghost.swift"])],
)
"""

_ESCAPE_EXCLUDE = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", exclude: ["../Escape"])],
)
"""

_ESCAPE_SOURCES = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "P",
    products: [.library(name: "P", targets: ["P"])],
    targets: [.target(name: "P", sources: [".."])],
)
"""

_CODE_NAMES = ["a.c", "a.cc", "a.cpp", "a.cxx", "a.m", "a.mm", "a.h", "a.hh", "a.hpp", "a.inc", "a.s", "a.S", "module.modulemap", "Custom.modulemap"]

_SKIPPED_NAMES = ["README.md", "LICENSE", "notes.txt", "logo.png", "data.json", "Guide.markdown", "CHANGELOG", "Makefile", "Docs.swift"]

def _only_target(manifest):
    parsed = parse_swiftpm_package("pkg", manifest)
    if not parsed.ok:
        fail(parsed.error)
    return parsed.model.targets[0]

def _is_code_file_test_impl(ctx):
    env = unittest.begin(ctx)
    for name in _CODE_NAMES:
        asserts.true(env, swiftpm_is_code_file(name))
    for name in _SKIPPED_NAMES:
        asserts.true(env, not swiftpm_is_code_file(name))
    return unittest.end(env)

_CLANG_TARGET = """// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Shims",
    products: [.library(name: "Shims", targets: ["Shims"])],
    targets: [.target(name: "Shims", publicHeadersPath: "include")],
)
"""

def _select(identity, manifest, rel_dir, files, dirs):
    return swiftpm_select_target_files(identity, _only_target(manifest), rel_dir, files, dirs)

def _skips_non_code_files_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_DOCS)
    rel_dir = "pkg/Sources/Docs"
    files = {
        rel_dir + "/Docs.swift": True,
        rel_dir + "/README.md": True,
        rel_dir + "/LICENSE": True,
        rel_dir + "/notes.txt": True,
        rel_dir + "/logo.png": True,
        rel_dir + "/Docs.docc/Documentation.md": True,
    }
    dirs = {rel_dir + "/Docs.docc": True}
    selected = swiftpm_select_target_files("docs", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Docs.swift"], selected.srcs)
    asserts.equals(env, [], selected.c_srcs)
    asserts.equals(env, [], selected.public_hdrs)
    asserts.equals(env, None, selected.explicit_map)
    return unittest.end(env)

def _classifies_c_family_files_test_impl(ctx):
    env = unittest.begin(ctx)
    rel_dir = "pkg/Sources/Shims"
    files = {
        rel_dir + "/Shims.c": True,
        rel_dir + "/extra.cc": True,
        rel_dir + "/include/Shims.h": True,
        rel_dir + "/include/detail.h": True,
        rel_dir + "/Internal/secret.h": True,
        rel_dir + "/include/module.modulemap": True,
        rel_dir + "/README.md": True,
    }
    dirs = {rel_dir + "/include": True, rel_dir + "/Internal": True}
    selected = _select("shims", _CLANG_TARGET, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.srcs)
    asserts.equals(env, [rel_dir + "/Shims.c", rel_dir + "/extra.cc"], selected.c_srcs)
    asserts.equals(env, [rel_dir + "/include/Shims.h", rel_dir + "/include/detail.h"], selected.public_hdrs)
    asserts.equals(env, [rel_dir + "/Internal/secret.h"], selected.private_hdrs)
    asserts.equals(env, rel_dir + "/include/module.modulemap", selected.explicit_map)
    asserts.true(env, selected.map_in_include)
    return unittest.end(env)

def _single_directory_headers_are_public_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_DOCS)
    rel_dir = "pkg/Sources/Docs"
    files = {
        rel_dir + "/Docs.c": True,
        rel_dir + "/Docs.h": True,
        rel_dir + "/Sub/helper.h": True,
        rel_dir + "/module.modulemap": True,
    }
    dirs = {rel_dir + "/Sub": True}
    selected = swiftpm_select_target_files("docs", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Docs.c"], selected.c_srcs)
    asserts.equals(env, [rel_dir + "/Docs.h"], selected.public_hdrs)
    asserts.equals(env, [rel_dir + "/Sub/helper.h"], selected.private_hdrs)
    asserts.equals(env, rel_dir + "/module.modulemap", selected.explicit_map)
    asserts.true(env, not selected.map_in_include)
    return unittest.end(env)

def _stray_module_map_skipped_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_DOCS)
    rel_dir = "pkg/Sources/Docs"
    files = {
        rel_dir + "/Docs.swift": True,
        rel_dir + "/Sub/module.modulemap": True,
        rel_dir + "/Custom.modulemap": True,
    }
    dirs = {rel_dir + "/Sub": True}
    selected = swiftpm_select_target_files("docs", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Docs.swift"], selected.srcs)
    asserts.equals(env, None, selected.explicit_map)
    return unittest.end(env)

def _drops_missing_exclude_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_EXCLUDE)
    rel_dir = "pkg/Sources/P"
    files = {
        rel_dir + "/P.swift": True,
        rel_dir + "/Sub/Extra.swift": True,
    }
    dirs = {rel_dir + "/Sub": True}
    selected = swiftpm_select_target_files("p", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/P.swift"], selected.srcs)
    return unittest.end(env)

def _drops_missing_sources_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_SOURCES)
    rel_dir = "pkg/Sources/P"
    files = {
        rel_dir + "/Real.swift": True,
        rel_dir + "/Other.swift": True,
    }
    selected = swiftpm_select_target_files("p", target, rel_dir, files, {})
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Real.swift"], selected.srcs)
    return unittest.end(env)

def _all_missing_sources_zero_files_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_SOURCES_ALL_MISSING)
    rel_dir = "pkg/Sources/P"
    files = {rel_dir + "/P.swift": True}
    selected = swiftpm_select_target_files("p", target, rel_dir, files, {})
    asserts.true(env, not selected.ok)
    asserts.true(env, "reaches zero Swift files" in selected.error)
    return unittest.end(env)

def _escape_still_refused_test_impl(ctx):
    env = unittest.begin(ctx)
    rel_dir = "pkg/Sources/P"
    files = {rel_dir + "/P.swift": True}
    selected = swiftpm_select_target_files("p", _only_target(_ESCAPE_EXCLUDE), rel_dir, files, {})
    asserts.true(env, not selected.ok)
    asserts.true(env, "escaping" in selected.error)
    selected = swiftpm_select_target_files("p", _only_target(_ESCAPE_SOURCES), rel_dir, files, {})
    asserts.true(env, not selected.ok)
    asserts.true(env, "escaping" in selected.error)
    return unittest.end(env)

def _docc_swift_skipped_test_impl(ctx):
    env = unittest.begin(ctx)
    target = _only_target(_DOCS)
    rel_dir = "pkg/Sources/Docs"
    files = {
        rel_dir + "/Docs.swift": True,
        rel_dir + "/Docs.docc/Snippet.swift": True,
    }
    dirs = {rel_dir + "/Docs.docc": True}
    selected = swiftpm_select_target_files("docs", target, rel_dir, files, dirs)
    asserts.true(env, selected.ok)
    asserts.equals(env, [rel_dir + "/Docs.swift"], selected.srcs)
    return unittest.end(env)

_is_code_file_test = unittest.make(_is_code_file_test_impl)
_skips_non_code_files_test = unittest.make(_skips_non_code_files_test_impl)
_classifies_c_family_files_test = unittest.make(_classifies_c_family_files_test_impl)
_single_directory_headers_are_public_test = unittest.make(_single_directory_headers_are_public_test_impl)
_stray_module_map_skipped_test = unittest.make(_stray_module_map_skipped_test_impl)
_drops_missing_exclude_test = unittest.make(_drops_missing_exclude_test_impl)
_drops_missing_sources_test = unittest.make(_drops_missing_sources_test_impl)
_all_missing_sources_zero_files_test = unittest.make(_all_missing_sources_zero_files_test_impl)
_escape_still_refused_test = unittest.make(_escape_still_refused_test_impl)
_docc_swift_skipped_test = unittest.make(_docc_swift_skipped_test_impl)

def swiftpm_package_test_suite(name):
    """Registers the target file selection unit tests."""
    unittest.suite(
        name + "_unit",
        _is_code_file_test,
        _skips_non_code_files_test,
        _classifies_c_family_files_test,
        _single_directory_headers_are_public_test,
        _stray_module_map_skipped_test,
        _drops_missing_exclude_test,
        _drops_missing_sources_test,
        _all_missing_sources_zero_files_test,
        _escape_still_refused_test,
        _docc_swift_skipped_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )
