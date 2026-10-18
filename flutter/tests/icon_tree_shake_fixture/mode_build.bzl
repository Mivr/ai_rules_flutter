"""Configuration transition and font fixture helpers for icon tree-shaking tests."""

load("@rules_dart//dart:utils.bzl", "dart_info_no_package")
load("//flutter/private:flutter_info.bzl", "flutter_info")
load("//flutter/private:flutter_library.bzl", "build_pub_contributions")

_PROFILE_FLAG = str(Label("//flutter:profile"))

def _fastbuild_transition_impl(_settings, _attr):
    return {
        "//command_line_option:compilation_mode": "fastbuild",
        _PROFILE_FLAG: False,
    }

_fastbuild_transition = transition(
    implementation = _fastbuild_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        _PROFILE_FLAG,
    ],
)

def _opt_transition_impl(_settings, _attr):
    return {
        "//command_line_option:compilation_mode": "opt",
        _PROFILE_FLAG: False,
    }

_opt_transition = transition(
    implementation = _opt_transition_impl,
    inputs = [],
    outputs = [
        "//command_line_option:compilation_mode",
        _PROFILE_FLAG,
    ],
)

def _forward_files_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [
        t[DefaultInfo].files
        for t in ctx.attr.targets
    ]))]

fastbuild_build = rule(
    implementation = _forward_files_impl,
    doc = "Forwards the files of `targets`, built with `-c fastbuild`.",
    attrs = {
        "targets": attr.label_list(
            cfg = _fastbuild_transition,
            mandatory = True,
        ),
    },
)

opt_build = rule(
    implementation = _forward_files_impl,
    doc = "Forwards the files of `targets`, built with `-c opt`.",
    attrs = {
        "targets": attr.label_list(
            cfg = _opt_transition,
            mandatory = True,
        ),
    },
)

def _font_fixture_impl(ctx):
    extra_pub_fonts, _, _ = build_pub_contributions(
        ctx.attr.package_name,
        ctx.attr.fonts_json,
        ctx.attr.font_files,
        {},
        {},
    )
    return [
        DefaultInfo(files = depset(ctx.files.font_files)),
        dart_info_no_package(),
        flutter_info(pub_fonts = extra_pub_fonts),
    ]

font_fixture = rule(
    implementation = _font_fixture_impl,
    doc = "Contributes `FlutterInfo.pub_fonts` without registering a Dart package.",
    attrs = {
        "package_name": attr.string(default = ""),
        "fonts_json": attr.string(mandatory = True),
        "font_files": attr.label_keyed_string_dict(
            allow_files = True,
            mandatory = True,
        ),
    },
)
