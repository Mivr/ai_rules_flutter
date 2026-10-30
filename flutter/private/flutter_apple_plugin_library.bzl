"""Compile a Flutter plugin's Apple sources into a swift_library or xtool plugin library.

This is the rules_flutter analog of the Podfile-driven CocoaPods build a
Flutter plugin author would otherwise rely on. It wraps `swift_library`
with the platform's Flutter framework as a dep on the `rules_apple` backend,
and selects a host-agnostic `flutter_xtool_apple_plugin_library` on the
`xtool` backend so Linux -> iOS/macOS cross-builds do not require an
Apple host `@rules_swift` toolchain.

Public Tier-2 API: re-exported from `flutter/macos.bzl` and
`flutter/ios.bzl` so users can wire a monorepo plugin's BUILD.bazel
without going through the `ext/` overlay system.

Usage:

    flutter_apple_plugin_library(
        name = "my_plugin_apple_macos",
        srcs = glob(["macos/Classes/**/*.swift"]),
        module_name = "my_plugin",
        platform = "macos",
    )
"""

load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_apple//apple:apple.bzl", "apple_dynamic_framework_import", "apple_dynamic_xcframework_import")
load("@rules_cc//cc:objc_library.bzl", "objc_library")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_swift//swift:swift.bzl", "SwiftInfo", "swift_library")
load("//flutter:providers.bzl", "FlutterDarwinFrameworkInfo", _FlutterApplePluginInfo = "FlutterApplePluginInfo")
load(":flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugin_bundle = "flutter_apple_plugin_bundle")
load(":flutter_xtool_bundle.bzl", "flutter_darwin_xcframework_import")

FlutterApplePluginInfo = _FlutterApplePluginInfo

def _split_srcs(srcs):
    """Split srcs into (swift_files, objc_files, headers).

    Returns lists by extension so we can route ObjC through objc_library
    while keeping Swift on swift_library.
    """
    swift_files = []
    objc_files = []
    headers = []
    for f in srcs:
        if f.endswith(".swift"):
            swift_files.append(f)
        elif f.endswith(".m") or f.endswith(".mm"):
            objc_files.append(f)
        elif f.endswith(".h"):
            headers.append(f)
    return swift_files, objc_files, headers

def _classify_plugin_srcs(files):
    """Split rule srcs into a struct of swift, objc and header Files plus include dirs."""
    swift_files = []
    objc_files = []
    headers = []
    include_dirs = {}
    for f in files:
        if f.path.endswith(".swift"):
            swift_files.append(f)
        elif f.path.endswith(".m") or f.path.endswith(".mm") or f.path.endswith(".c") or f.path.endswith(".cc") or f.path.endswith(".cpp"):
            objc_files.append(f)
        elif f.path.endswith(".h"):
            headers.append(f)
            include_dirs[f.dirname] = True
    return struct(swift = swift_files, objc = objc_files, headers = headers, include_dirs = include_dirs)

def _plugin_include_dirs(package, includes, include_dirs):
    """Fold package-relative `includes` into the header-dir set from sources."""
    for inc in includes:
        if package:
            include_dirs["%s/%s" % (package, inc)] = True
        else:
            include_dirs[inc] = True
    return include_dirs

def _write_plugin_modulemap(ctx, module_name, headers):
    """Write the plugin's modulemap covering its headers."""
    modulemap_file = ctx.actions.declare_file("%s.modulemap" % ctx.label.name)
    mm_lines = ["module %s {" % module_name]
    for h in headers:
        mm_lines.append('  header "%s"' % h.basename)
    mm_lines.append("  export *")
    mm_lines.append("}")
    ctx.actions.write(
        output = modulemap_file,
        content = "\n".join(mm_lines) + "\n",
    )
    return modulemap_file

def _collect_plugin_dep_infos(ctx):
    """Collect CcInfo, SwiftInfo and framework files from the plugin's deps."""
    return struct(
        cc_infos = [dep[CcInfo] for dep in ctx.attr.deps if CcInfo in dep],
        swift_infos = [dep[SwiftInfo] for dep in ctx.attr.deps if SwiftInfo in dep],
        framework_files = [
            dep[FlutterDarwinFrameworkInfo].framework_files
            for dep in ctx.attr.deps
            if FlutterDarwinFrameworkInfo in dep and not dep.label.name.endswith("__flutter_framework")
        ],
    )

def _merge_plugin_sdk_lists(ctx, sdk_frameworks, sdk_dylibs):
    """Union the rule's SDK frameworks/dylibs with the ones plugin deps declare."""
    frameworks = list(sdk_frameworks)
    dylibs = list(sdk_dylibs)
    for dep in ctx.attr.deps:
        if FlutterApplePluginInfo in dep:
            for fw in dep[FlutterApplePluginInfo].sdk_frameworks:
                if fw not in frameworks:
                    frameworks.append(fw)
            for dylib in dep[FlutterApplePluginInfo].sdk_dylibs:
                if dylib not in dylibs:
                    dylibs.append(dylib)
    return frameworks, dylibs

def _flutter_xtool_apple_plugin_library_impl(ctx):
    if ctx.attr.plugin_defines:
        fail(plugin_defines_xtool_refusal(ctx.label.name))
    srcs = _classify_plugin_srcs(ctx.files.srcs)
    include_dirs = _plugin_include_dirs(ctx.label.package, ctx.attr.includes, srcs.include_dirs)

    module_name = ctx.attr.module_name if ctx.attr.module_name else ctx.label.name
    modulemap_file = _write_plugin_modulemap(ctx, module_name, srcs.headers)

    all_plugin_files = srcs.swift + srcs.objc + srcs.headers + [modulemap_file]
    own_cc_info = CcInfo(
        compilation_context = cc_common.create_compilation_context(
            headers = depset(all_plugin_files),
            direct_public_headers = srcs.headers,
            direct_textual_headers = srcs.swift + srcs.objc + [modulemap_file],
            includes = depset(include_dirs.keys()),
        ),
    )
    dep_infos = _collect_plugin_dep_infos(ctx)
    merged_cc_info = cc_common.merge_cc_infos(
        direct_cc_infos = [own_cc_info],
        cc_infos = dep_infos.cc_infos,
    )
    sdk_frameworks, sdk_dylibs = _merge_plugin_sdk_lists(ctx, ctx.attr.sdk_frameworks, ctx.attr.sdk_dylibs)

    return [
        DefaultInfo(files = depset(all_plugin_files, transitive = dep_infos.framework_files)),
        merged_cc_info,
        SwiftInfo(swift_infos = dep_infos.swift_infos),
        FlutterApplePluginInfo(
            module_name = module_name,
            platform = ctx.attr.platform,
            swift_srcs = depset(srcs.swift),
            objc_srcs = depset(srcs.objc),
            headers = depset(srcs.headers),
            modulemap = modulemap_file,
            sdk_frameworks = tuple(sdk_frameworks),
            sdk_dylibs = tuple(sdk_dylibs),
        ),
    ]

flutter_xtool_apple_plugin_library = rule(
    implementation = _flutter_xtool_apple_plugin_library_impl,
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            default = [],
            doc = "Swift, Objective-C, and header source files for the plugin.",
        ),
        "module_name": attr.string(
            default = "",
            doc = "Module name for the plugin.",
        ),
        "platform": attr.string(
            default = "macos",
            values = ["macos", "ios"],
            doc = "Target Apple platform ('ios' or 'macos').",
        ),
        "includes": attr.string_list(
            default = [],
            doc = "Header search paths relative to the package.",
        ),
        "sdk_frameworks": attr.string_list(
            default = [],
            doc = "Apple SDK frameworks to link.",
        ),
        "sdk_dylibs": attr.string_list(
            default = [],
            doc = "Apple SDK dynamic libraries to link.",
        ),
        "deps": attr.label_list(
            default = [],
            doc = "Dependencies providing CcInfo or SwiftInfo.",
        ),
        "plugin_defines": attr.string_list(
            default = [],
            doc = "Preprocessor defines for the plugin's Apple libraries. " +
                  "The xtool backend refuses a non-empty list because it " +
                  "compiles every source in one swiftc invocation with no " +
                  "define flags.",
        ),
    },
    provides = [
        DefaultInfo,
        CcInfo,
        SwiftInfo,
        FlutterApplePluginInfo,
    ],
    doc = "Host-agnostic Apple plugin library rule for the xtool backend.",
)

def _apple_plugin_engine_imports(platform, engine):
    """The Flutter framework import labels for an Apple plugin platform."""
    if platform == "macos":
        return [engine] if engine else [Label("@flutter_macos_engine//:engine_library")]
    return [engine] if engine else [Label("@flutter_ios_engine//:Flutter_xcframework")]

def _emit_xtool_plugin_branch(spec):
    flutter_darwin_xcframework_import(
        name = spec.framework_target,
        framework_name = "FlutterMacOS" if spec.platform == "macos" else "Flutter",
        xcframework_imports = spec.engine_imports,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    flutter_xtool_apple_plugin_library(
        name = spec.name,
        srcs = spec.srcs,
        module_name = spec.module_name,
        platform = spec.platform,
        includes = spec.includes,
        sdk_frameworks = spec.sdk_frameworks,
        sdk_dylibs = spec.sdk_dylibs,
        deps = [":" + spec.framework_target] + list(spec.deps),
        plugin_defines = spec.plugin_defines,
        tags = spec.tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = spec.visibility,
    )

def _emit_apple_framework_import(spec):
    if spec.platform == "macos":
        apple_dynamic_framework_import(
            name = spec.framework_target,
            framework_imports = spec.engine_imports,
            tags = spec.internal_tags,
            target_compatible_with = spec.target_compatible_with,
            visibility = ["//visibility:private"],
        )
    else:
        apple_dynamic_xcframework_import(
            name = spec.framework_target,
            xcframework_imports = spec.engine_imports,
            tags = spec.internal_tags,
            target_compatible_with = spec.target_compatible_with,
            visibility = ["//visibility:private"],
        )

def objc_copts_xtool_refusal(name):
    """The message for `objc_copts` on the `xtool` backend, naming the plugin target."""
    return (
        "flutter_apple_plugin_library: %s: objc_copts is not supported on the xtool backend; " % name +
        "the backend compiles every source in one swiftc invocation, so there is no " +
        "separate ObjC compile to pass them to"
    )

def plugin_defines_xtool_refusal(name):
    """The message for `plugin_defines` on the `xtool` backend, naming the plugin target."""
    return (
        "flutter_apple_plugin_library: %s: plugin_defines is not supported on the xtool backend; " % name +
        "it compiles every source in one swiftc invocation with no define flags. " +
        "Remove flutter.pub(ios_plugin_defines = ...), or build with backend = \"rules_apple\"."
    )

def _plugin_define_copts(defines):
    """The C-family `-D` flags for a plugin's define entries, in order."""
    return ["-D" + define for define in defines]

def _plugin_swift_define_copts(defines):
    """The Swift `-D` flags: only value-less entries, because a condition has no value."""
    return ["-D" + define for define in defines if "=" not in define]

def _emit_plugin_objc_target(spec, objc_files, headers):
    """Emit the inner `objc_library`; return `(objc_module_name, dep_label_or_None)`."""
    if not objc_files:
        return "", None
    objc_target = "_%s__objc" % spec.name
    objc_module_name = "%s_objc" % spec.module_name
    objc_library(
        name = objc_target,
        srcs = objc_files,
        hdrs = headers,
        includes = spec.includes,
        sdk_frameworks = spec.sdk_frameworks,
        sdk_dylibs = spec.sdk_dylibs,
        module_name = objc_module_name,
        enable_modules = True,
        copts = list(spec.copts) + list(spec.objc_copts) + _plugin_define_copts(spec.plugin_defines),
        deps = [":" + spec.framework_target] + list(spec.deps),
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return objc_module_name, ":" + objc_target

def _emit_plugin_objc_module_target(spec, headers):
    """Emit the headers-only ObjC module the Swift half imports.

    The module carries the plugin's public headers under
    `<module_name>_objc`, so Swift can `import "<module_name>_objc"` without
    depending on the implementation library that needs the Swift header.
    """
    target = "_%s__objc_module" % spec.name
    objc_library(
        name = target,
        hdrs = headers,
        includes = spec.includes,
        module_name = "%s_objc" % spec.module_name,
        enable_modules = True,
        deps = [":" + spec.framework_target],
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return ":" + target

def _swift_generated_header_include_impl(ctx):
    """Publish the generated header's directory as a quote include path."""
    headers = [
        header
        for header in ctx.attr.swift[CcInfo].compilation_context.headers.to_list()
        if header.basename == ctx.attr.header_name
    ]
    if len(headers) != 1:
        fail(
            "flutter_apple_plugin_library: expected exactly one generated header %s on %s, got %s" % (
                ctx.attr.header_name,
                ctx.attr.swift.label,
                [header.path for header in headers],
            ),
        )
    return [CcInfo(
        compilation_context = cc_common.create_compilation_context(
            quote_includes = depset([headers[0].dirname]),
        ),
    )]

_swift_generated_header_include = rule(
    implementation = _swift_generated_header_include_impl,
    attrs = {
        "header_name": attr.string(
            mandatory = True,
            doc = "Basename of the Swift module's generated Objective-C header.",
        ),
        "swift": attr.label(
            mandatory = True,
            providers = [CcInfo],
            doc = "The `swift_library` whose generated header the ObjC sources import.",
        ),
    },
    doc = "Adds the directory of a Swift module's generated header to the quote " +
          "include path, so ObjC sources import it by its plain basename.",
)

def _emit_plugin_swift_header_include_target(spec, swift_target):
    """Emit the target that makes `<module_name>-Swift.h` findable by basename."""
    target = "_%s__swift_include" % spec.name
    _swift_generated_header_include(
        name = target,
        header_name = "%s-Swift.h" % spec.module_name,
        swift = swift_target,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return ":" + target

def _emit_plugin_mixed_objc_target(spec, objc_files, headers, swift_deps):
    """Emit the ObjC half of a mixed plugin; it depends on the Swift module.

    Depending on the Swift library makes `<module_name>-Swift.h` a declared
    input of every ObjC compile; the companion include target contributes the
    header's directory as a quote include path, so
    `#import "<module_name>-Swift.h"` resolves by its basename from a source
    `.m`/`.mm` file. The implementation library deliberately has no Clang
    module of its own: `<module_name>_objc` names the headers-only module the
    Swift half imports, and two targets cannot publish the same module name.
    """
    target = "_%s__objc" % spec.name
    objc_library(
        name = target,
        srcs = objc_files,
        hdrs = headers,
        includes = spec.includes,
        sdk_frameworks = spec.sdk_frameworks,
        sdk_dylibs = spec.sdk_dylibs,
        copts = list(spec.copts) + list(spec.objc_copts) + _plugin_define_copts(spec.plugin_defines),
        deps = [":" + spec.framework_target] + swift_deps,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = ["//visibility:private"],
    )
    return ":" + target

def _plugin_bridging_copts(spec, headers):
    """Find the `<module>-Bridging-Header.h` and return `(header_or_None, copts)`.

    A found header also gets the Clang includes a CocoaPods prefix header
    supplies: `Foundation/Foundation.h`, then `UIKit/UIKit.h` on iOS or
    `AppKit/AppKit.h` on macOS, so a plugin header that names `NSObject` or a
    view class without importing the framework still parses. A plugin with no
    bridging header gets its own copts unchanged.
    """
    extra_copts = list(spec.copts) + _plugin_swift_define_copts(spec.plugin_defines)
    for h in headers:
        if h.endswith("%s-Bridging-Header.h" % spec.module_name):
            if spec.platform == "ios":
                framework_header = "UIKit/UIKit.h"
            elif spec.platform == "macos":
                framework_header = "AppKit/AppKit.h"
            else:
                fail(
                    "flutter_apple_plugin_library: platform must be 'ios' or 'macos', got '%s'" % spec.platform,
                )
            extra_copts.extend([
                "-Xcc",
                "-include",
                "-Xcc",
                "Foundation/Foundation.h",
                "-Xcc",
                "-include",
                "-Xcc",
                framework_header,
                "-import-objc-header",
                "$(execpath %s)" % h,
            ])
            return h, extra_copts
    return None, extra_copts

def _plugin_swift_srcs(spec, swift_files, objc_module_name):
    """Return the swift_library srcs, emitting a re-export placeholder when empty."""
    if swift_files:
        return swift_files
    placeholder_target = "_%s__swift_placeholder" % spec.name
    placeholder_file = "_%s__placeholder.swift" % spec.name
    placeholder_content = ["// GENERATED — re-exports the ObjC module so Swift `import %s` works." % spec.module_name]
    if objc_module_name:
        placeholder_content.append("@_exported import %s" % objc_module_name)
    write_file(
        name = placeholder_target,
        out = placeholder_file,
        content = placeholder_content,
        tags = spec.internal_tags,
        target_compatible_with = spec.target_compatible_with,
    )
    return [":" + placeholder_target]

def _emit_plugin_swift_target(
        spec,
        target_name,
        swift_files,
        deps,
        extra_copts,
        bridging_header,
        generates_header,
        kwargs):
    """Emit a plugin `swift_library`, optionally publishing its ObjC header.

    Args:
        spec: The plugin's struct of shared attributes.
        target_name: Name for the `swift_library`.
        swift_files: Swift source files (or the placeholder target).
        deps: Labels the Swift compile depends on.
        extra_copts: The plugin's copts plus any bridging-header flags.
        bridging_header: The `<module>-Bridging-Header.h`, or `None`.
        generates_header: Whether to publish `<module_name>-Swift.h`.
        kwargs: Extra attributes forwarded from the public macro.
    """
    swift_kwargs = dict(kwargs)
    if generates_header:
        swift_kwargs["generates_header"] = True
        swift_kwargs["generated_header_name"] = "%s-Swift.h" % spec.module_name

    swift_library(
        name = target_name,
        srcs = swift_files,
        module_name = spec.module_name,
        copts = extra_copts,
        deps = deps,
        swiftc_inputs = [bridging_header] if bridging_header else [],
        tags = spec.tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = spec.visibility,
        **swift_kwargs
    )

def _emit_plugin_bundle_target(spec, deps, swift_files, objc_files, headers):
    """Emit the public target that merges the Swift and ObjC halves."""
    _flutter_apple_plugin_bundle(
        name = spec.name,
        deps = deps,
        module_name = spec.module_name,
        platform = spec.platform,
        swift_srcs = swift_files,
        objc_srcs = objc_files,
        headers = headers,
        sdk_frameworks = spec.sdk_frameworks,
        sdk_dylibs = spec.sdk_dylibs,
        tags = spec.tags,
        target_compatible_with = spec.target_compatible_with,
        visibility = spec.visibility,
    )

def _emit_mixed_plugin(spec, swift_files, objc_files, headers, kwargs):
    """Emit the two-layer ObjC/Swift build for a plugin with both halves."""
    objc_module = _emit_plugin_objc_module_target(spec, headers)
    bridging_header, extra_copts = _plugin_bridging_copts(spec, headers)

    swift_target = "_%s__swift" % spec.name
    swift_deps = [":" + spec.framework_target, objc_module] + list(spec.deps)
    _emit_plugin_swift_target(
        spec,
        swift_target,
        swift_files,
        swift_deps,
        extra_copts,
        bridging_header,
        True,
        kwargs,
    )

    swift_include = _emit_plugin_swift_header_include_target(spec, ":" + swift_target)
    objc_target = _emit_plugin_mixed_objc_target(
        spec,
        objc_files,
        headers,
        [":" + swift_target, swift_include],
    )
    _emit_plugin_bundle_target(spec, [":" + swift_target, objc_target], swift_files, objc_files, headers)

def flutter_apple_plugin_library(
        name,
        srcs = [],
        module_name = None,
        platform = "macos",
        deps = [],
        copts = [],
        objc_copts = [],
        plugin_defines = [],
        includes = [],
        sdk_frameworks = [],
        sdk_dylibs = [],
        engine = None,
        backend = "rules_apple",
        visibility = None,
        tags = None,
        **kwargs):
    """Build a Flutter plugin's Apple sources into a swift_library.

    Auto-routes `.m`/`.mm` files through an internal `objc_library` and
    feeds it into the `swift_library` as a dep.

    Args:
        name: Target name. Pass to runner deps (or via the aspect-based
            aggregator that discovers them automatically).
        srcs: Swift, ObjC, and header source files.
        module_name: Swift module name. Defaults to `name`.
        platform: `"macos"` or `"ios"`. Picks the Flutter framework dep.
        deps: Additional swift_library / cc_library deps (other plugins), also
            given to the inner `objc_library` so its sources see their public
            headers and modules.
        copts: Additional Swift compile options, also passed to the inner
            `objc_library` as today.
        objc_copts: C and ObjC compile options for the inner `objc_library`
            only, appended after `copts`. They never reach the `swift_library`.
            The `xtool` backend refuses a non-empty list, because it has no
            separate ObjC compile.
        plugin_defines: Preprocessor defines for that plugin's Apple
            libraries, each `NAME` or `NAME=VALUE`. Every entry reaches the
            C-family compile as `-D<entry>`; only a value-less `NAME` reaches
            the Swift compile, as `-D<NAME>`, because a Swift condition has no
            value. The `xtool` backend refuses a non-empty list.
        includes: Header search paths forwarded to the inner `objc_library`.
        sdk_frameworks: Apple SDK frameworks to link (e.g. `["AVFoundation"]`).
        sdk_dylibs: Apple SDK dynamic libraries to link (e.g. `["c++"]`,
            `["sqlite3"]`).
        engine: Optional override for the Flutter engine framework label.
        backend: Apple bundling backend: `"rules_apple"` (default) or
            `"xtool"` (explicit opt-in).
        visibility: Target visibility.
        tags: Bazel tags. Defaults to `["manual"]` so the spoke target
            is only built when something depends on it.
        **kwargs: Forwarded to the underlying swift_library.
    """
    if platform not in ("macos", "ios"):
        fail("flutter_apple_plugin_library: platform must be 'macos' or 'ios', got '%s'" % platform)
    if backend not in ("rules_apple", "xtool"):
        fail("flutter_apple_plugin_library: backend must be 'rules_apple' or 'xtool', got %r" % backend)
    if backend == "xtool" and objc_copts:
        fail(objc_copts_xtool_refusal(name))

    if tags == None:
        tags = ["manual"]
    internal_tags = tags if "manual" in tags else tags + ["manual"]

    if module_name == None:
        module_name = name

    target_compatible_with = kwargs.pop(
        "target_compatible_with",
        ["@platforms//os:%s" % platform],
    )

    spec = struct(
        name = name,
        srcs = srcs,
        module_name = module_name,
        platform = platform,
        deps = deps,
        copts = copts,
        objc_copts = objc_copts,
        plugin_defines = plugin_defines,
        includes = includes,
        sdk_frameworks = sdk_frameworks,
        sdk_dylibs = sdk_dylibs,
        engine_imports = _apple_plugin_engine_imports(platform, engine),
        framework_target = "_%s__flutter_framework" % name,
        internal_tags = internal_tags,
        target_compatible_with = target_compatible_with,
        visibility = visibility,
        tags = tags,
    )

    if backend == "xtool":
        _emit_xtool_plugin_branch(spec)
        return

    swift_files, objc_files, headers = _split_srcs(srcs)
    _emit_apple_framework_import(spec)

    if swift_files and objc_files:
        _emit_mixed_plugin(spec, swift_files, objc_files, headers, kwargs)
        return

    swift_deps = [":" + spec.framework_target] + list(deps)

    objc_module_name, objc_dep = _emit_plugin_objc_target(spec, objc_files, headers)
    if objc_dep:
        swift_deps.append(objc_dep)

    bridging_header, extra_copts = _plugin_bridging_copts(spec, headers)

    # A header-less ObjC target gets no clang module, so there is nothing to re-export.
    swift_files = _plugin_swift_srcs(spec, swift_files, objc_module_name if headers else "")

    _emit_plugin_swift_target(
        spec,
        name,
        swift_files,
        swift_deps,
        extra_copts,
        bridging_header,
        False,
        kwargs,
    )
