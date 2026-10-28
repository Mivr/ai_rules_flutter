"""Add-to-app iOS xcframework assembly (private implementation).

Produces the xcframework set an existing Xcode app links for Flutter's
documented add-to-app path:

- `App.xcframework`: a device arm64 slice and an arm64/x86_64 simulator slice,
  both assembled from `flutter_ios_framework`;
- `Flutter.xcframework`: the pinned iOS engine the rules already select for the
  build configuration, symlinked file for file (never copied);
- `FlutterPluginRegistrant.xcframework`: a dynamic framework linked from the
  application's generated `GeneratedPluginRegistrant.swift`;
- one `<Plugin>.xcframework` per native iOS plugin in the application's
  transitive graph.

Layout and every `Info.plist` are written by the Starlark rule. No
`xcodebuild -create-xcframework` runs, and the only tools the actions use are
the `macho_edit` host tool the Apple targets already need and the runner's
existing Swift toolchain.

The public macro lives in `flutter/ios.bzl`; usage is documented there and in
`docs/ios-add-to-app.md`.
"""

load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@rules_swift//swift:swift.bzl", "swift_binary")
load("//flutter:providers.bzl", "FlutterApplicationInfo", "resolve_exec_dart_vm")
load("//flutter/private:constants.bzl", "IOS_MINIMUM_OS_VERSION")
load("//flutter/private:flutter_apple_plugins_aggregator.bzl", _flutter_apple_plugins_aggregator = "flutter_apple_plugins_aggregator")
load("//flutter/private:flutter_ios_application.bzl", _flutter_ios_framework_rule = "flutter_ios_framework")
load("//flutter/private:flutter_ios_registrant.bzl", _flutter_ios_registrant_rule = "flutter_ios_registrant")
load("//flutter/private:ios_app.bzl", _flutter_ios_engine = "flutter_ios_engine")
load("//flutter/private:validation.bzl", "validate_minimum_os_version")

_IOS_DEVICE = "ios-arm64"
_IOS_SIMULATOR = "ios-arm64_x86_64-simulator"
_DEVICE_ARCHITECTURES = ["arm64"]
_SIMULATOR_ARCHITECTURES = ["arm64", "x86_64"]
_RESERVED_FRAMEWORKS = ["App", "Flutter", "FlutterPluginRegistrant"]

def _xcframework_transition_impl(platform_label):
    """Builds a transition to one iOS platform in release mode.

    Add-to-app xcframeworks are shipping artifacts: the device and simulator
    slices are AOT snapshots, so the transition forces `-c opt` and clears the
    profile flag rather than inheriting whatever the calling build used.
    """
    return {
        "//command_line_option:compilation_mode": "opt",
        "//command_line_option:platforms": str(platform_label),
        str(Label("//flutter:profile")): False,
    }

def _ios_device_transition_impl(_settings, _attr):
    return _xcframework_transition_impl(Label("//flutter/platforms:ios_arm64"))

def _ios_sim_arm64_transition_impl(_settings, _attr):
    return _xcframework_transition_impl(Label("//flutter/private:ios_sim_arm64"))

def _ios_sim_x64_transition_impl(_settings, _attr):
    return _xcframework_transition_impl(Label("//flutter/platforms:ios_x64"))

_ios_device_transition = transition(
    implementation = _ios_device_transition_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
)

_ios_sim_arm64_transition = transition(
    implementation = _ios_sim_arm64_transition_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
)

_ios_sim_x64_transition = transition(
    implementation = _ios_sim_x64_transition_impl,
    inputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
    outputs = [
        "//command_line_option:compilation_mode",
        "//command_line_option:platforms",
        str(Label("//flutter:profile")),
    ],
)

def validate_xcframework_application(application):
    """Fails with the macro's own message when `application` is missing.

    Args:
        application: The caller's `application` value.
    """
    if not application:
        fail(
            "flutter_ios_xcframeworks: application is required; pass a " +
            "flutter_application target whose xcframeworks an Xcode app links.",
        )

def _framework_members(target, framework_name):
    """Returns the files under one `.framework` directory keyed by relative path."""
    marker = "/%s.framework/" % framework_name
    members = {}
    for f in target[DefaultInfo].files.to_list():
        if marker in f.path:
            members[f.path.rsplit(marker, 1)[1]] = f
    if "Info.plist" not in members:
        fail(
            "flutter_ios_xcframeworks: %s has no %s.framework/Info.plist; " % (
                target.label,
                framework_name,
            ) + "expected a flutter_ios_framework output.",
        )
    return members

def _declare_symlink(ctx, path, source):
    """Declares `path` as a symlink to `source` and returns the output file."""
    out = ctx.actions.declare_file(path)
    ctx.actions.symlink(output = out, target_file = source)
    return out

def _copy_tree(ctx, dart_exe, dart_vm_files, source, path):
    """Copies a framework's tree artifact into this xcframework slice."""
    out = ctx.actions.declare_directory(path)
    ctx.actions.run(
        executable = dart_exe,
        arguments = [
            ctx.executable._macho_edit.path,
            "copy-assets",
            "--src",
            source.path,
            "--dst",
            out.path,
        ],
        inputs = depset(
            direct = [source, ctx.executable._macho_edit],
            transitive = [dart_vm_files],
        ),
        outputs = [out],
        mnemonic = "FlutterIOSXcframeworkAssets",
        progress_message = "Copying App.framework assets into %s" % ctx.label,
    )
    return out

def _fat_binary(ctx, dart_exe, dart_vm_files, arm64, x86_64, output):
    """Builds one universal simulator Mach-O from its two thin slices."""
    ctx.actions.run(
        executable = dart_exe,
        arguments = [
            ctx.executable._macho_edit.path,
            "fat",
            "--output",
            output.path,
            arm64.path,
            x86_64.path,
        ],
        inputs = depset(
            direct = [arm64, x86_64, ctx.executable._macho_edit],
            transitive = [dart_vm_files],
        ),
        outputs = [output],
        mnemonic = "FlutterIOSXcframeworkFat",
        progress_message = "Building universal simulator binary for %s" % ctx.label,
    )

def _patch_binary(ctx, dart_exe, dart_vm_files, source, output, platform, minimum_os_version, install_name):
    """Retags one linked binary as an iOS framework executable."""
    ctx.actions.run(
        executable = dart_exe,
        arguments = [
            ctx.executable._macho_edit.path,
            "patch",
            "--input",
            source.path,
            "--output",
            output.path,
            "--platform",
            platform,
            "--min-os",
            minimum_os_version,
            "--sdk-version",
            minimum_os_version,
            "--install-name",
            install_name,
        ],
        inputs = depset(
            direct = [source, ctx.executable._macho_edit],
            transitive = [dart_vm_files],
        ),
        outputs = [output],
        mnemonic = "FlutterIOSXcframeworkPatch",
        progress_message = "Retagging %s for %s" % (source.basename, platform),
    )

def _single_binary(target):
    """Returns the one linkable binary a target produced."""
    files = [f for f in target[DefaultInfo].files.to_list() if not f.is_directory]
    for f in files:
        if f.extension in ("dylib", "so"):
            return f
    for f in files:
        if f.basename in ("App", target.label.name):
            return f
    if len(files) == 1:
        return files[0]
    fail(
        "flutter_ios_xcframeworks: %s produced %d files and none is a " % (
            target.label,
            len(files),
        ) + "dynamic library; expected the registrant's linked binary.",
    )

def _framework_info_plist(name, minimum_os_version, bundle_id):
    """Renders the `Info.plist` every framework slice carries."""
    return "\n".join([
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "    <key>CFBundleDevelopmentRegion</key>",
        "    <string>en</string>",
        "    <key>CFBundleExecutable</key>",
        "    <string>%s</string>" % name,
        "    <key>CFBundleIdentifier</key>",
        "    <string>%s</string>" % bundle_id,
        "    <key>CFBundleInfoDictionaryVersion</key>",
        "    <string>6.0</string>",
        "    <key>CFBundleName</key>",
        "    <string>%s</string>" % name,
        "    <key>CFBundlePackageType</key>",
        "    <string>FMWK</string>",
        "    <key>CFBundleShortVersionString</key>",
        "    <string>1.0</string>",
        "    <key>CFBundleVersion</key>",
        "    <string>1.0</string>",
        "    <key>MinimumOSVersion</key>",
        "    <string>%s</string>" % minimum_os_version,
        "</dict>",
        "</plist>",
        "",
    ])

def _library_entry(path, identifier, architectures, variant):
    """Builds one `AvailableLibraries` entry."""
    lines = [
        "        <dict>",
        "            <key>LibraryIdentifier</key>",
        "            <string>%s</string>" % identifier,
        "            <key>LibraryPath</key>",
        "            <string>%s</string>" % path,
        "            <key>SupportedArchitectures</key>",
        "            <array>",
    ]
    for arch in architectures:
        lines.extend(["                <string>%s</string>" % arch])
    lines.extend([
        "            </array>",
        "            <key>SupportedPlatform</key>",
        "            <string>ios</string>",
    ])
    if variant:
        lines.extend([
            "            <key>SupportedPlatformVariant</key>",
            "            <string>%s</string>" % variant,
        ])
    lines.append("        </dict>")
    return lines

def _xcframework_info_plist(entries):
    """Renders the xcframework-level `Info.plist` from its library entries."""
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
        '<plist version="1.0">',
        "<dict>",
        "    <key>AvailableLibraries</key>",
        "    <array>",
    ]
    for entry in entries:
        lines.extend(entry)
    lines.extend([
        "    </array>",
        "    <key>CFBundlePackageType</key>",
        "    <string>XFWK</string>",
        "    <key>XCFrameworkFormatVersion</key>",
        "    <string>1.0</string>",
        "</dict>",
        "</plist>",
        "",
    ])
    return "\n".join(lines)

def _device_and_simulator_entries(framework_name):
    """The two library entries every add-to-app xcframework carries."""
    return [
        _library_entry(
            "%s/%s.framework" % (_IOS_DEVICE, framework_name),
            _IOS_DEVICE,
            _DEVICE_ARCHITECTURES,
            "",
        ),
        _library_entry(
            "%s/%s.framework" % (_IOS_SIMULATOR, framework_name),
            _IOS_SIMULATOR,
            _SIMULATOR_ARCHITECTURES,
            "simulator",
        ),
    ]

def _app_xcframework(ctx):
    """Declares App.xcframework and returns its outputs and runfiles."""
    device = _framework_members(ctx.attr.device_app_framework, "App")
    sim_arm64 = _framework_members(ctx.attr.sim_arm64_app_framework, "App")
    sim_x64 = _framework_members(ctx.attr.sim_x64_app_framework, "App")

    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    root = ctx.label.name + "/App.xcframework"
    outputs = []

    device_dir = root + "/%s/App.framework" % _IOS_DEVICE
    device_binary = _declare_symlink(ctx, device_dir + "/App", device["App"])
    outputs.append(device_binary)
    outputs.append(_declare_symlink(ctx, device_dir + "/Info.plist", device["Info.plist"]))
    outputs.append(_copy_tree(ctx, dart_exe, dart_vm_files, device["flutter_assets"], device_dir + "/flutter_assets"))

    sim_dir = root + "/%s/App.framework" % _IOS_SIMULATOR
    sim_binary = ctx.actions.declare_file(sim_dir + "/App")
    _fat_binary(ctx, dart_exe, dart_vm_files, sim_arm64["App"], sim_x64["App"], sim_binary)
    outputs.append(sim_binary)
    outputs.append(_declare_symlink(ctx, sim_dir + "/Info.plist", sim_arm64["Info.plist"]))
    outputs.append(_copy_tree(ctx, dart_exe, dart_vm_files, sim_arm64["flutter_assets"], sim_dir + "/flutter_assets"))

    info_plist = ctx.actions.declare_file(root + "/Info.plist")
    ctx.actions.write(info_plist, _xcframework_info_plist(_device_and_simulator_entries("App")))
    outputs.append(info_plist)
    return outputs

def _flutter_xcframework(ctx):
    """Declares Flutter.xcframework by symlinking the pinned engine's files."""
    files = ctx.attr.engine[DefaultInfo].files.to_list()
    marker = "/Flutter.xcframework/"
    root = ctx.label.name + "/Flutter.xcframework"
    outputs = []
    for f in files:
        if marker not in f.path:
            continue
        relative = f.path.rsplit(marker, 1)[1]
        outputs.append(_declare_symlink(ctx, root + "/" + relative, f))
    if not any([o.basename == "Info.plist" for o in outputs]):
        fail(
            "flutter_ios_xcframeworks: engine %s has no Flutter.xcframework/Info.plist; " % ctx.attr.engine.label +
            "expected the pinned Flutter.xcframework filegroup.",
        )
    return outputs

def _registrant_xcframework(ctx):
    """Declares FlutterPluginRegistrant.xcframework from linked registrants."""
    dart_exe, dart_vm_files = resolve_exec_dart_vm(ctx)
    root = ctx.label.name + "/FlutterPluginRegistrant.xcframework"
    device_patched = ctx.actions.declare_file("__%s_registrant_device" % ctx.label.name)
    arm64_patched = ctx.actions.declare_file("__%s_registrant_sim_arm64" % ctx.label.name)
    x64_patched = ctx.actions.declare_file("__%s_registrant_sim_x64" % ctx.label.name)
    install_name = "@rpath/FlutterPluginRegistrant.framework/FlutterPluginRegistrant"
    _patch_binary(ctx, dart_exe, dart_vm_files, _single_binary(ctx.attr.device_registrant), device_patched, "ios", ctx.attr.minimum_os_version, install_name)
    _patch_binary(ctx, dart_exe, dart_vm_files, _single_binary(ctx.attr.sim_arm64_registrant), arm64_patched, "iossim", ctx.attr.minimum_os_version, install_name)
    _patch_binary(ctx, dart_exe, dart_vm_files, _single_binary(ctx.attr.sim_x64_registrant), x64_patched, "iossim", ctx.attr.minimum_os_version, install_name)

    outputs = []
    device_dir = root + "/%s/FlutterPluginRegistrant.framework" % _IOS_DEVICE
    outputs.append(_declare_symlink(ctx, device_dir + "/FlutterPluginRegistrant", device_patched))
    outputs.append(_write_framework_plist(ctx, device_dir, "FlutterPluginRegistrant", ctx.attr.minimum_os_version))

    sim_dir = root + "/%s/FlutterPluginRegistrant.framework" % _IOS_SIMULATOR
    sim_binary = ctx.actions.declare_file(sim_dir + "/FlutterPluginRegistrant")
    _fat_binary(ctx, dart_exe, dart_vm_files, arm64_patched, x64_patched, sim_binary)
    outputs.append(sim_binary)
    outputs.append(_write_framework_plist(ctx, sim_dir, "FlutterPluginRegistrant", ctx.attr.minimum_os_version))

    info_plist = ctx.actions.declare_file(root + "/Info.plist")
    ctx.actions.write(info_plist, _xcframework_info_plist(_device_and_simulator_entries("FlutterPluginRegistrant")))
    outputs.append(info_plist)
    return outputs

def _write_framework_plist(ctx, directory, name, minimum_os_version):
    """Writes the framework `Info.plist` inside one slice and returns it."""
    out = ctx.actions.declare_file(directory + "/Info.plist")
    ctx.actions.write(out, _framework_info_plist(
        name,
        minimum_os_version,
        "io.flutter.flutter.plugin.%s" % name.lower().replace("_", "-"),
    ))
    return out

def _plugin_name(entry):
    """Returns the framework name for one plugin library entry."""
    if entry.package:
        return entry.package
    return entry.label.name

def _plugin_binary(entry):
    """Returns the compiled plugin file that becomes the framework binary."""
    files = [f for f in entry.files.to_list() if not f.is_directory]
    for f in files:
        if f.extension in ("a", "dylib"):
            return f
    if files:
        return files[0]
    fail(
        "flutter_ios_xcframeworks: plugin %s has no compiled files; " % entry.label +
        "expected an ios_libs/flutter_apple_plugin_library target with sources.",
    )

def _plugin_xcframeworks(ctx):
    """Declares one xcframework per native iOS plugin in the application graph."""
    entries = ctx.attr.application[FlutterApplicationInfo].apple_plugin_libraries.to_list()
    seen = {}
    outputs = []
    for entry in entries:
        if entry.platform != "ios":
            continue
        name = _plugin_name(entry)
        if name in seen:
            continue
        if name in _RESERVED_FRAMEWORKS:
            fail(
                "flutter_ios_xcframeworks: plugin framework name %r collides " % name +
                "with the add-to-app framework of the same name; rename the plugin package.",
            )
        seen[name] = True
        binary = _plugin_binary(entry)
        root = "%s/%s.xcframework" % (ctx.label.name, name)
        for identifier in (_IOS_DEVICE, _IOS_SIMULATOR):
            directory = "%s/%s/%s.framework" % (root, identifier, name)
            outputs.append(_declare_symlink(ctx, directory + "/" + name, binary))
            outputs.append(_write_framework_plist(ctx, directory, name, ctx.attr.minimum_os_version))
        info_plist = ctx.actions.declare_file(root + "/Info.plist")
        ctx.actions.write(info_plist, _xcframework_info_plist(_device_and_simulator_entries(name)))
        outputs.append(info_plist)
    return outputs

def _flutter_ios_xcframework_impl(ctx):
    """Assembles the App, Flutter, registrant and plugin xcframeworks."""
    outputs = _app_xcframework(ctx)
    outputs.extend(_flutter_xcframework(ctx))
    outputs.extend(_registrant_xcframework(ctx))
    outputs.extend(_plugin_xcframeworks(ctx))

    transitive = [
        target[DefaultInfo].files
        for target in [
            ctx.attr.device_app_framework,
            ctx.attr.sim_arm64_app_framework,
            ctx.attr.sim_x64_app_framework,
            ctx.attr.device_registrant,
            ctx.attr.sim_arm64_registrant,
            ctx.attr.sim_x64_registrant,
            ctx.attr.engine,
        ]
    ]
    for entry in ctx.attr.application[FlutterApplicationInfo].apple_plugin_libraries.to_list():
        transitive.append(entry.files)
    return [DefaultInfo(
        files = depset(outputs),
        runfiles = ctx.runfiles(transitive_files = depset(transitive = transitive)),
    )]

flutter_ios_xcframework = rule(
    implementation = _flutter_ios_xcframework_impl,
    attrs = dicts.add({
        "application": attr.label(
            doc = "A flutter_application target whose plugins become xcframeworks, read in the device configuration so its iOS plugin libraries are selected.",
            mandatory = True,
            providers = [FlutterApplicationInfo],
            cfg = _ios_device_transition,
        ),
        "device_app_framework": attr.label(
            doc = "The device arm64 App.framework target, built through the device transition.",
            mandatory = True,
            cfg = _ios_device_transition,
        ),
        "sim_arm64_app_framework": attr.label(
            doc = "The simulator arm64 App.framework target, built through the simulator transition.",
            mandatory = True,
            cfg = _ios_sim_arm64_transition,
        ),
        "sim_x64_app_framework": attr.label(
            doc = "The simulator x86_64 App.framework target, built through the simulator transition.",
            mandatory = True,
            cfg = _ios_sim_x64_transition,
        ),
        "device_registrant": attr.label(
            doc = "The device arm64 linked GeneratedPluginRegistrant dynamic library.",
            mandatory = True,
            cfg = _ios_device_transition,
        ),
        "sim_arm64_registrant": attr.label(
            doc = "The simulator arm64 linked GeneratedPluginRegistrant dynamic library.",
            mandatory = True,
            cfg = _ios_sim_arm64_transition,
        ),
        "sim_x64_registrant": attr.label(
            doc = "The simulator x86_64 linked GeneratedPluginRegistrant dynamic library.",
            mandatory = True,
            cfg = _ios_sim_x64_transition,
        ),
        "engine": attr.label(
            doc = "The pinned Flutter.xcframework filegroup for the active configuration.",
            mandatory = True,
            allow_files = True,
        ),
        "minimum_os_version": attr.string(
            doc = "Minimum iOS deployment target written into every new framework plist.",
            default = IOS_MINIMUM_OS_VERSION,
        ),
        "_macho_edit": attr.label(
            default = Label("//flutter/private/tools:macho_edit"),
            executable = True,
            cfg = "exec",
            doc = "The `macho_edit` host tool that retags and fuses Mach-O slices.",
        ),
    }),
    toolchains = [
        "@rules_flutter//flutter:toolchain_type",
        config_common.toolchain_type("@rules_dart//dart:exec_tools_toolchain_type", mandatory = False),
    ],
    doc = "Assembles App, Flutter, plugin-registrant and plugin xcframeworks for add-to-app.",
)

def flutter_ios_xcframeworks(name, application = None, minimum_os_version = IOS_MINIMUM_OS_VERSION, **kwargs):
    """Builds the xcframework set an existing Xcode app links (add-to-app).

    See `flutter/ios.bzl` for the public documentation of every argument.

    Args:
        name: Target name; its files are the xcframework set.
        application: A `flutter_application` target (required).
        minimum_os_version: Minimum iOS deployment target.
        **kwargs: Common target attributes (e.g. `visibility`, `tags`,
            `target_compatible_with`).
    """
    validate_xcframework_application(application)
    validate_minimum_os_version(
        "flutter_ios_xcframeworks",
        name,
        minimum_os_version,
        IOS_MINIMUM_OS_VERSION,
        "iOS",
    )

    tags = kwargs.pop("tags", ["manual"])
    internal_tags = tags if "manual" in tags else tags + ["manual"]
    visibility = kwargs.pop("visibility", None)
    target_compatible_with = kwargs.pop("target_compatible_with", ["@platforms//os:macos"])

    for suffix, platform in [
        ("device_app_framework", "device"),
        ("sim_arm64_app_framework", "simulator"),
        ("sim_x64_app_framework", "simulator"),
    ]:
        _flutter_ios_framework_rule(
            name = "__%s_%s" % (name, suffix),
            application = application,
            minimum_os_version = minimum_os_version,
            allow_simulator_aot = platform == "simulator",
            tags = internal_tags,
        )

    _flutter_ios_registrant_rule(
        name = "__%s_registrant" % name,
        application = application,
        tags = internal_tags,
    )
    _flutter_ios_engine(
        name = "__%s_engine" % name,
        tags = internal_tags,
    )
    _flutter_apple_plugins_aggregator(
        name = "__%s_plugins" % name,
        application = application,
        platform = "ios",
        tags = internal_tags,
    )
    swift_binary(
        name = "__%s_registrant_binary" % name,
        srcs = [":__%s_registrant" % name],
        module_name = "GeneratedPluginRegistrant",
        deps = [
            ":__%s_engine" % name,
            ":__%s_plugins" % name,
        ],
        linkshared = True,
        tags = internal_tags,
    )

    flutter_ios_xcframework(
        name = name,
        application = application,
        device_app_framework = ":__%s_device_app_framework" % name,
        sim_arm64_app_framework = ":__%s_sim_arm64_app_framework" % name,
        sim_x64_app_framework = ":__%s_sim_x64_app_framework" % name,
        device_registrant = ":__%s_registrant_binary" % name,
        sim_arm64_registrant = ":__%s_registrant_binary" % name,
        sim_x64_registrant = ":__%s_registrant_binary" % name,
        engine = select({
            Label("@rules_flutter//flutter/private:dbg"): Label("@flutter_ios_engine//:Flutter_xcframework_debug"),
            Label("@rules_flutter//flutter/private:profile"): Label("@flutter_ios_engine_profile//:Flutter_xcframework"),
            "//conditions:default": Label("@flutter_ios_engine//:Flutter_xcframework"),
        }),
        minimum_os_version = minimum_os_version,
        tags = tags,
        visibility = visibility,
        target_compatible_with = target_compatible_with,
        **kwargs
    )
