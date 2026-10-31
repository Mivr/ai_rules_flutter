"""Unit tests for a plugin manifest's local (same-package) targets."""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//flutter/private:flutter_pub_apple.bzl", "apple_plugin_targets")
load(
    "//flutter/private:flutter_pub_apple_local.bzl",
    "parse_plugin_local_package",
    "plugin_local_targets",
    "render_local_target_blocks",
    "with_apple_local_targets",
)
load("//flutter/private:swiftpm_package.bzl", "swiftpm_select_target_files")

def _setting(kind, name, value = "", platforms = None):
    condition = struct(platforms = platforms) if platforms != None else None
    return struct(category = "c", kind = kind, name = name, value = value, condition = condition, line = 1)

def _target(name, deps = [], path = "", exclude = [], c_settings = [], swift_settings = [], public_headers_path = ""):
    return struct(
        kind = "target",
        name = name,
        deps = deps,
        path = path,
        exclude = exclude,
        sources = None,
        public_headers_path = public_headers_path,
        c_settings = c_settings,
        cxx_settings = [],
        swift_settings = swift_settings,
        linker_settings = [],
        line = 1,
    )

def _same(name, platforms = None):
    condition = struct(platforms = platforms) if platforms != None else None
    return struct(kind = "same", name = name, package = "", condition = condition)

def _product(name, targets):
    return struct(kind = "library", name = name, targets = targets, line = 1)

def _model(products, targets):
    return struct(products = products, targets = targets, pkg_deps = [], modes = [], tools_major = 5, tools_minor = 9)

_IMAGE_PICKER_OBJC = "ios/image_picker_ios/Sources/image_picker_ios_objc"
_IMAGE_PICKER_PRIMARY = "ios/image_picker_ios/Sources/image_picker_ios"

def _image_picker_model():
    objc = _target(
        "image_picker_ios_objc",
        path = "Sources/image_picker_ios_objc",
        exclude = ["include/image_picker_ios.h", "include/ImagePickerPlugin.modulemap"],
        c_settings = [_setting("headerSearchPath", "include/image_picker_ios")],
    )
    primary = _target(
        "image_picker_ios",
        deps = [_same("image_picker_ios_objc")],
        path = "Sources/image_picker_ios",
    )
    return _model([_product("image-picker-ios", ["image_picker_ios"])], [primary, objc])

def _image_picker_selected():
    files = {
        _IMAGE_PICKER_OBJC + "/include/image_picker_ios.h": True,
        _IMAGE_PICKER_OBJC + "/include/ImagePickerPlugin.modulemap": True,
        _IMAGE_PICKER_OBJC + "/include/image_picker_ios/messages.g.h": True,
        _IMAGE_PICKER_OBJC + "/messages.g.m": True,
    }
    dirs = {
        _IMAGE_PICKER_OBJC: True,
        _IMAGE_PICKER_OBJC + "/include": True,
        _IMAGE_PICKER_OBJC + "/include/image_picker_ios": True,
    }
    target = _image_picker_model().targets[1]
    return swiftpm_select_target_files("image_picker_ios", target, _IMAGE_PICKER_OBJC, files, dirs)

def _image_picker_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    locals = plugin_local_targets("image_picker_ios", _image_picker_model(), "ios/image_picker_ios", _IMAGE_PICKER_PRIMARY, "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, 1, len(locals.targets))
    local = locals.targets[0]
    asserts.equals(env, "image_picker_ios_objc", local.name)
    asserts.equals(env, "image_picker_ios_objc", local.module_name)
    asserts.equals(env, _IMAGE_PICKER_OBJC, local.dir)

    selected = _image_picker_selected()
    asserts.true(env, selected.ok)
    asserts.equals(env, [], selected.srcs)
    asserts.equals(env, [_IMAGE_PICKER_OBJC + "/messages.g.m"], selected.c_srcs)
    asserts.equals(env, [_IMAGE_PICKER_OBJC + "/include/image_picker_ios/messages.g.h"], selected.public_hdrs)
    asserts.true(env, _IMAGE_PICKER_OBJC + "/include/image_picker_ios.h" not in selected.public_hdrs)
    asserts.true(env, _IMAGE_PICKER_OBJC + "/include/ImagePickerPlugin.modulemap" not in selected.public_hdrs)

    rendered = render_local_target_blocks("image_picker_ios", "ios", locals.targets, {"image_picker_ios_objc": selected})
    asserts.true(env, rendered.ok)
    asserts.equals(env, [":image_picker_ios_apple_ios__image_picker_ios_objc"], rendered.labels)
    asserts.true(env, "flutter_apple_plugin_objc_library(" in rendered.text)
    asserts.true(env, "module_name = \"image_picker_ios_objc\"" in rendered.text)
    asserts.true(env, _IMAGE_PICKER_OBJC + "/messages.g.m" in rendered.text)
    asserts.true(env, "include/image_picker_ios.h" not in rendered.text)
    asserts.true(env, "include/image_picker_ios\"" in rendered.text)

    content = apple_plugin_targets("image_picker_ios", [_IMAGE_PICKER_PRIMARY], [], "ios")
    patched = with_apple_local_targets(content, "image_picker_ios", "ios", rendered)
    asserts.true(env, "\":image_picker_ios_apple_ios__image_picker_ios_objc\"," in patched)
    asserts.true(env, _IMAGE_PICKER_OBJC + "/messages.g.m" in patched)
    asserts.equals(env, 1, len(patched.split(":image_picker_ios_apple_ios__image_picker_ios_objc")) - 1)
    return unittest.end(env)

def _firebase_core_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    objc = _target(
        "firebase_core_objc",
        path = "Sources/firebase_core_objc",
        c_settings = [_setting("headerSearchPath", "include"), _setting("define", "LIBRARY_NAME", "flutter-fire-core")],
        public_headers_path = "include",
    )
    primary = _target(
        "firebase_core",
        deps = [_same("firebase_core_objc")],
        path = "Sources/firebase_core",
    )
    model = _model([_product("firebase-core", ["firebase_core", "firebase_core_objc"])], [objc, primary])
    locals = plugin_local_targets("firebase_core", model, "ios/firebase_core", "ios/firebase_core/Sources/firebase_core", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, 1, len(locals.targets))
    asserts.equals(env, "firebase_core_objc", locals.targets[0].name)

    selected = struct(ok = True, srcs = [], c_srcs = ["ios/firebase_core/Sources/firebase_core_objc/plugin.m"], public_hdrs = ["ios/firebase_core/Sources/firebase_core_objc/include/plugin.h"], private_hdrs = [], explicit_map = None, map_in_include = False)
    rendered = render_local_target_blocks("firebase_core", "ios", locals.targets, {"firebase_core_objc": selected})
    asserts.true(env, rendered.ok)
    content = apple_plugin_targets("firebase_core", ["ios/firebase_core/Sources/firebase_core"], [], "ios")
    patched = with_apple_local_targets(content, "firebase_core", "ios", rendered)
    asserts.true(env, "name = \"firebase_core_apple_ios\"" in patched)
    asserts.true(env, "name = \"firebase_core_apple_ios__firebase_core_objc\"" in patched)
    asserts.true(env, "\"-DLIBRARY_NAME=flutter-fire-core\"" in rendered.text)
    return unittest.end(env)

def _video_player_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    sibling_headers = "../video_player_avfoundation_objc/include/video_player_avfoundation_objc"
    ios = _target("video_player_avfoundation_ios", path = "Sources/video_player_avfoundation_ios", c_settings = [_setting("headerSearchPath", sibling_headers)])
    macos = _target("video_player_avfoundation_macos", path = "Sources/video_player_avfoundation_macos", c_settings = [_setting("headerSearchPath", sibling_headers)])
    objc = _target(
        "video_player_avfoundation_objc",
        deps = [_same("video_player_avfoundation_ios", ["ios"]), _same("video_player_avfoundation_macos", ["macos"])],
        path = "Sources/video_player_avfoundation_objc",
    )
    primary = _target(
        "video_player_avfoundation",
        deps = [_same("video_player_avfoundation_objc")],
        path = "Sources/video_player_avfoundation",
    )
    manifest = "darwin/video_player_avfoundation"
    model = _model([_product("video-player-avfoundation", ["video_player_avfoundation"])], [primary, objc, ios, macos])
    locals = plugin_local_targets("video_player_avfoundation", model, manifest, manifest + "/Sources/video_player_avfoundation", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, ["video_player_avfoundation_objc", "video_player_avfoundation_ios"], [target.name for target in locals.targets])

    files = {
        "video_player_avfoundation_objc": struct(ok = True, srcs = [], c_srcs = [manifest + "/Sources/video_player_avfoundation_objc/a.m"], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False),
        "video_player_avfoundation_ios": struct(ok = True, srcs = [], c_srcs = [manifest + "/Sources/video_player_avfoundation_ios/a.m"], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False),
    }
    rendered = render_local_target_blocks("video_player_avfoundation", "ios", locals.targets, files)
    asserts.true(env, rendered.ok)
    asserts.true(env, "select({" in rendered.text)
    asserts.true(env, "\"@platforms//os:ios\": [" in rendered.text)
    asserts.true(env, ":video_player_avfoundation_apple_ios__video_player_avfoundation_ios" in rendered.text)
    asserts.true(env, ":video_player_avfoundation_apple_ios__video_player_avfoundation_macos" not in rendered.text)
    asserts.true(env, manifest + "/Sources/video_player_avfoundation_objc/include/video_player_avfoundation_objc" in rendered.text)

    content = apple_plugin_targets("video_player_avfoundation", [manifest + "/Sources/video_player_avfoundation"], [], "ios")
    patched = with_apple_local_targets(content, "video_player_avfoundation", "ios", rendered)
    asserts.true(env, "\":video_player_avfoundation_apple_ios__video_player_avfoundation_ios\"," in patched)
    asserts.true(env, ":video_player_avfoundation_apple_ios__video_player_avfoundation_macos" not in patched)

    macos_locals = plugin_local_targets("video_player_avfoundation", model, manifest, manifest + "/Sources/video_player_avfoundation", "macos")
    asserts.true(env, macos_locals.ok)
    asserts.equals(env, ["video_player_avfoundation_objc", "video_player_avfoundation_macos"], [target.name for target in macos_locals.targets])
    macos_files = {
        "video_player_avfoundation_objc": files["video_player_avfoundation_objc"],
        "video_player_avfoundation_macos": struct(ok = True, srcs = [], c_srcs = [manifest + "/Sources/video_player_avfoundation_macos/a.m"], public_hdrs = [], private_hdrs = [], explicit_map = None, map_in_include = False),
    }
    macos = render_local_target_blocks("video_player_avfoundation", "macos", macos_locals.targets, macos_files)
    asserts.true(env, macos.ok)
    asserts.true(env, "\"@platforms//os:macos\": [" in macos.text)
    asserts.true(env, ":video_player_avfoundation_apple_macos__video_player_avfoundation_macos" in macos.text)
    asserts.true(env, ":video_player_avfoundation_apple_macos__video_player_avfoundation_ios" not in macos.text)
    return unittest.end(env)

def _missing_directory_test_impl(ctx):
    env = unittest.begin(ctx)
    locals = plugin_local_targets("image_picker_ios", _image_picker_model(), "ios/image_picker_ios", _IMAGE_PICKER_PRIMARY, "ios")
    rendered = render_local_target_blocks("image_picker_ios", "ios", locals.targets, {})
    asserts.true(env, not rendered.ok)
    asserts.true(env, "image_picker_ios" in rendered.error)
    asserts.true(env, "image_picker_ios_objc" in rendered.error)
    asserts.true(env, _IMAGE_PICKER_OBJC in rendered.error)
    return unittest.end(env)

def _binary_target_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    binary = struct(kind = "binaryTarget", name = "Blob", deps = [], path = "", exclude = [], sources = None, public_headers_path = "", c_settings = [], cxx_settings = [], swift_settings = [], linker_settings = [], line = 1)
    primary = _target("plugin", path = "Sources/plugin")
    model = _model([_product("plugin", ["plugin", "Blob"])], [primary, binary])
    locals = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "ios")
    asserts.true(env, not locals.ok)
    asserts.equals(env, "binary targets in plugin manifests land in POD-10", locals.error)
    return unittest.end(env)

def _parser_keeps_target_settings_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "image_picker_ios",
    products: [.library(name: "image-picker-ios", targets: ["image_picker_ios"])],
    targets: [
        .target(name: "image_picker_ios", dependencies: ["image_picker_ios_objc"], resources: [.process("Resources")]),
        .target(
            name: "image_picker_ios_objc",
            exclude: ["include/image_picker_ios.h", "include/ImagePickerPlugin.modulemap"],
            cSettings: [.headerSearchPath("include/image_picker_ios")],
            publicHeadersPath: "include",
        ),
    ]
)
"""
    parsed = parse_plugin_local_package("image_picker_ios", manifest)
    asserts.true(env, parsed.ok)
    objc = parsed.model.targets[1]
    asserts.equals(env, ["include/image_picker_ios.h", "include/ImagePickerPlugin.modulemap"], objc.exclude)
    asserts.equals(env, "include", objc.public_headers_path)
    asserts.equals(env, ("headerSearchPath", "include/image_picker_ios"), (objc.c_settings[0].kind, objc.c_settings[0].name))
    return unittest.end(env)

def _parser_skips_untranslated_args_test_impl(ctx):
    env = unittest.begin(ctx)
    manifest = """// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "image_picker_ios",
    defaultLocalization: "en",
    platforms: [
        .iOS("11.0")
    ],
    products: [.library(name: "image-picker-ios", targets: ["image_picker_ios"])],
    targets: [
        .target(
            name: "image_picker_ios",
            dependencies: ["image_picker_ios_objc"],
            resources: [.process("Resources")]
        ),
        .target(
            name: "image_picker_ios_objc",
            packageAccess: true,
            exclude: ["include/image_picker_ios.h"],
            cSettings: [.headerSearchPath("include/image_picker_ios")],
        ),
    ]
)
"""
    parsed = parse_plugin_local_package("image_picker_ios", manifest)
    asserts.true(env, parsed.ok, "parse failed: %s" % parsed.error)
    objc = parsed.model.targets[1]
    asserts.equals(env, ["include/image_picker_ios.h"], objc.exclude)
    asserts.equals(env, ("headerSearchPath", "include/image_picker_ios"), (objc.c_settings[0].kind, objc.c_settings[0].name))
    locals = plugin_local_targets("image_picker_ios", parsed.model, "ios/image_picker_ios", "ios/image_picker_ios/Sources/image_picker_ios", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, ["image_picker_ios_objc"], [target.name for target in locals.targets])
    return unittest.end(env)

def _primary_only_keeps_base_shape_test_impl(ctx):
    env = unittest.begin(ctx)
    primary = _target("plain_plugin", path = "Sources/plain_plugin")
    model = _model([_product("plain-plugin", ["plain_plugin"])], [primary])
    locals = plugin_local_targets("plain_plugin", model, "ios/plain_plugin", "ios/plain_plugin/Sources/plain_plugin", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, [], locals.targets)
    asserts.equals(env, "plain_plugin", locals.primary.name)

    rendered = render_local_target_blocks("plain_plugin", "ios", locals.targets, {})
    asserts.true(env, rendered.ok)
    asserts.equals(env, "", rendered.text)
    content = apple_plugin_targets("plain_plugin", ["ios/plain_plugin/Sources/plain_plugin"], [], "ios")
    asserts.equals(env, content, with_apple_local_targets(content, "plain_plugin", "ios", rendered))
    return unittest.end(env)

def _transitive_default_dirs_test_impl(ctx):
    env = unittest.begin(ctx)
    leaf = _target("leaf")
    middle = _target("middle", deps = [_same("leaf")], path = "Sources/middle")
    primary = _target("root", deps = [_same("middle")], path = "Sources/root")
    model = _model([_product("root", ["root"])], [primary, middle, leaf])
    locals = plugin_local_targets("root", model, "ios/root", "ios/root/Sources/root", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, ["middle", "leaf"], [target.name for target in locals.targets])
    asserts.equals(env, "ios/root/Sources/leaf", locals.targets[1].dir)
    asserts.equals(env, "ios/root/Sources/leaf", locals.targets[1].directory)
    asserts.equals(env, [":root_apple_ios__leaf"], [edge.text for edge in locals.targets[0].edges])
    return unittest.end(env)

def _product_targets_in_manifest_order_test_impl(ctx):
    env = unittest.begin(ctx)
    first_objc = _target("first_objc", path = "Sources/first_objc")
    second_objc = _target("second-objc", path = "Sources/second_objc")
    primary = _target("primary", path = "Sources/primary")
    model = _model(
        [_product("two-objc", ["primary", "first_objc", "second-objc"])],
        [primary, first_objc, second_objc],
    )
    locals = plugin_local_targets("two_objc", model, "ios/two_objc", "ios/two_objc/Sources/primary", "ios")
    asserts.true(env, locals.ok)
    asserts.equals(env, ["first_objc", "second-objc"], [target.name for target in locals.targets])
    asserts.equals(env, ["first_objc", "second_objc"], [target.module_name for target in locals.targets])
    asserts.equals(env, ["target", "target"], [target.kind for target in locals.targets])
    return unittest.end(env)

def _define_and_condition_select_test_impl(ctx):
    env = unittest.begin(ctx)
    local = _target(
        "conditional",
        path = "Sources/conditional",
        c_settings = [
            _setting("define", "ENABLED", "1", platforms = ["ios"]),
            _setting("headerSearchPath", "../conditional/include", platforms = ["macos"]),
        ],
        public_headers_path = "include",
    )
    primary = _target("conditional_plugin", deps = [_same("conditional")], path = "Sources/conditional_plugin")
    model = _model([_product("conditional-plugin", ["conditional_plugin"])], [primary, local])
    locals = plugin_local_targets("conditional_plugin", model, "ios/conditional_plugin", "ios/conditional_plugin/Sources/conditional_plugin", "ios")
    selected = struct(
        ok = True,
        srcs = [],
        c_srcs = ["ios/conditional_plugin/Sources/conditional/a.m"],
        public_hdrs = ["ios/conditional_plugin/Sources/conditional/include/a.h"],
        private_hdrs = [],
        explicit_map = None,
        map_in_include = False,
    )
    rendered = render_local_target_blocks("conditional_plugin", "ios", locals.targets, {"conditional": selected})
    asserts.true(env, rendered.ok)
    asserts.true(env, "conlyopts = select({" in rendered.text)
    asserts.true(env, "\"-DENABLED=1\"," in rendered.text)
    asserts.true(env, "\"@platforms//os:ios\": [" in rendered.text)
    asserts.true(env, "\"@platforms//os:macos\": [" in rendered.text)
    asserts.true(env, "ios/conditional_plugin/Sources/conditional/../conditional/include" not in rendered.text)
    asserts.true(env, "ios/conditional_plugin/Sources/conditional/include" in rendered.text)
    return unittest.end(env)

def _primary_conditional_dep_test_impl(ctx):
    env = unittest.begin(ctx)
    local = _target("plugin_objc", path = "Sources/plugin_objc", public_headers_path = "include")
    primary = _target("plugin", deps = [_same("plugin_objc", ["ios"])], path = "Sources/plugin")
    model = _model([_product("plugin", ["plugin"])], [primary, local])
    ios = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "ios")
    asserts.true(env, ios.ok)
    asserts.equals(env, ["plugin_objc"], [target.name for target in ios.targets])
    selected = struct(
        ok = True,
        srcs = [],
        c_srcs = ["ios/plugin/Sources/plugin_objc/value.m"],
        public_hdrs = ["ios/plugin/Sources/plugin_objc/include/value.h"],
        private_hdrs = [],
        explicit_map = None,
        map_in_include = False,
    )
    rendered = render_local_target_blocks("plugin", "ios", ios.targets, {"plugin_objc": selected})
    asserts.true(env, rendered.ok)
    asserts.equals(env, [":plugin_apple_ios__plugin_objc"], rendered.labels)

    macos = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "macos")
    asserts.true(env, macos.ok)
    asserts.equals(env, [], [target.name for target in macos.targets])
    macos_rendered = render_local_target_blocks("plugin", "macos", macos.targets, {})
    asserts.true(env, macos_rendered.ok)
    asserts.equals(env, "", macos_rendered.text)
    return unittest.end(env)

def _binary_dependency_refusal_test_impl(ctx):
    env = unittest.begin(ctx)
    binary = struct(kind = "binaryTarget", name = "Artifact", deps = [], path = "", exclude = [], sources = None, public_headers_path = "", c_settings = [], cxx_settings = [], swift_settings = [], linker_settings = [], line = 1)
    primary = _target("plugin", deps = [_same("Artifact")], path = "Sources/plugin")
    model = _model([_product("plugin", ["plugin"])], [primary, binary])
    locals = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "ios")
    asserts.true(env, not locals.ok)
    asserts.equals(env, "binary targets in plugin manifests land in POD-10", locals.error)
    return unittest.end(env)

def _xtool_appends_local_files_test_impl(ctx):
    env = unittest.begin(ctx)
    local = _target(
        "plugin_objc",
        path = "Sources/plugin_objc",
        c_settings = [_setting("headerSearchPath", "include")],
        public_headers_path = "include",
    )
    primary = _target("plugin", deps = [_same("plugin_objc")], path = "Sources/plugin")
    model = _model([_product("plugin", ["plugin"])], [primary, local])
    locals = plugin_local_targets("plugin", model, "ios/plugin", "ios/plugin/Sources/plugin", "ios")
    selected = struct(
        ok = True,
        srcs = [],
        c_srcs = ["ios/plugin/Sources/plugin_objc/value.m"],
        public_hdrs = ["ios/plugin/Sources/plugin_objc/include/value.h"],
        private_hdrs = [],
        explicit_map = None,
        map_in_include = False,
    )
    rendered = render_local_target_blocks("plugin", "ios", locals.targets, {"plugin_objc": selected})
    content = apple_plugin_targets("plugin", ["ios/plugin/Sources/plugin"], [], "ios")
    patched = with_apple_local_targets(content, "plugin", "ios", rendered)
    asserts.true(env, ") + [" in patched)
    asserts.true(env, "ios/plugin/Sources/plugin_objc/value.m" in patched)
    asserts.true(env, "ios/plugin/Sources/plugin_objc/include/value.h" in patched)
    asserts.true(env, "\":plugin_apple_ios__plugin_objc\"," in patched)
    return unittest.end(env)

_image_picker_shape_test = unittest.make(_image_picker_shape_test_impl)
_primary_only_keeps_base_shape_test = unittest.make(_primary_only_keeps_base_shape_test_impl)
_transitive_default_dirs_test = unittest.make(_transitive_default_dirs_test_impl)
_product_targets_in_manifest_order_test = unittest.make(_product_targets_in_manifest_order_test_impl)
_define_and_condition_select_test = unittest.make(_define_and_condition_select_test_impl)
_primary_conditional_dep_test = unittest.make(_primary_conditional_dep_test_impl)
_binary_dependency_refusal_test = unittest.make(_binary_dependency_refusal_test_impl)
_xtool_appends_local_files_test = unittest.make(_xtool_appends_local_files_test_impl)
_firebase_core_shape_test = unittest.make(_firebase_core_shape_test_impl)
_video_player_shape_test = unittest.make(_video_player_shape_test_impl)
_missing_directory_test = unittest.make(_missing_directory_test_impl)
_binary_target_refusal_test = unittest.make(_binary_target_refusal_test_impl)
_parser_keeps_target_settings_test = unittest.make(_parser_keeps_target_settings_test_impl)
_parser_skips_untranslated_args_test = unittest.make(_parser_skips_untranslated_args_test_impl)

def swiftpm_plugin_local_test_suite(name):
    """Registers the plugin-local target unit tests."""
    unittest.suite(
        name + "_unit",
        _image_picker_shape_test,
        _firebase_core_shape_test,
        _video_player_shape_test,
        _missing_directory_test,
        _binary_target_refusal_test,
        _parser_keeps_target_settings_test,
        _parser_skips_untranslated_args_test,
        _primary_only_keeps_base_shape_test,
        _transitive_default_dirs_test,
        _product_targets_in_manifest_order_test,
        _define_and_condition_select_test,
        _primary_conditional_dep_test,
        _binary_dependency_refusal_test,
        _xtool_appends_local_files_test,
    )
    native.test_suite(
        name = name,
        tests = [":" + name + "_unit"],
    )
