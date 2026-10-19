"""Unit tests for flutter_pub_package.bzl's generated Android sub-package.

The fixture shapes mirror real pub.dev plugins:

* `record_android` 1.5.1 — Kotlin sources, `android/src/main/res/`
  resources referenced as `R.drawable.ic_mic`, a library manifest
  declaring RECORD_AUDIO, a `build.gradle` with a `namespace` and **no**
  dependencies block (androidx arrives via the Flutter embedding's
  compile classpath, exactly as in Gradle builds).
* `url_launcher_android` — Kotlin sources, no resources, gradle deps.
"""

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load(
    "//flutter/private:flutter_pub_package.bzl",
    "apply_overlay_substitutions",
    "find_hardcoded_hub_dep",
    "find_hardcoded_language_version",
    "make_android_subpackage_build_content",
    "make_flutter_library_build_content",
    "make_flutter_plugin_build_content",
    "parse_android_manifest_package",
    "parse_gradle_android_namespace",
    "render_overlay_deps",
    "resolve_overlay",
    "resolve_overlay_roots",
    "resolve_overlay_template",
)

# Verbatim shape of record_android 1.5.1's android/build.gradle (trimmed):
# Groovy DSL, namespace assignment, no dependencies block at all.
_RECORD_ANDROID_GRADLE = """\
group 'com.llfbandit.record'
version '1.0'

apply plugin: 'com.android.library'
apply plugin: 'kotlin-android'

android {
    namespace = 'com.llfbandit.record'

    compileSdk = flutter.compileSdkVersion

    sourceSets {
        main.java.srcDirs += 'src/main/kotlin'
    }

    defaultConfig {
        minSdk = 23
    }
}
"""

_GRADLE_KTS_NAMESPACE = """\
android {
    namespace = "dev.example.kts_plugin"
}
"""

# Legacy (pre-AGP-8) Groovy namespace method-call syntax, no `=`.
_GRADLE_GROOVY_NAMESPACE_NO_ASSIGN = """\
android {
    namespace 'dev.example.legacy'
}
"""

_RECORD_ANDROID_MANIFEST = """\
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
  package="com.llfbandit.record">

    <uses-permission android:name="android.permission.RECORD_AUDIO" />
</manifest>
"""

_MANIFEST_NO_PACKAGE = """\
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
</manifest>
"""

def _parse_gradle_android_namespace_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "com.llfbandit.record",
        parse_gradle_android_namespace(_RECORD_ANDROID_GRADLE),
    )
    asserts.equals(
        env,
        "dev.example.kts_plugin",
        parse_gradle_android_namespace(_GRADLE_KTS_NAMESPACE),
    )
    asserts.equals(
        env,
        "dev.example.legacy",
        parse_gradle_android_namespace(_GRADLE_GROOVY_NAMESPACE_NO_ASSIGN),
    )
    asserts.equals(env, "", parse_gradle_android_namespace("android {}\n"))

    return unittest.end(env)

parse_gradle_android_namespace_test = unittest.make(_parse_gradle_android_namespace_test_impl)

def _parse_android_manifest_package_test_impl(ctx):
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "com.llfbandit.record",
        parse_android_manifest_package(_RECORD_ANDROID_MANIFEST),
    )
    asserts.equals(env, "", parse_android_manifest_package(_MANIFEST_NO_PACKAGE))
    asserts.equals(env, "", parse_android_manifest_package("not xml"))

    return unittest.end(env)

parse_android_manifest_package_test = unittest.make(_parse_android_manifest_package_test_impl)

def _record_android_subpackage_test_impl(ctx):
    """record_android shape: Kotlin + res/ + manifest + dep-less gradle."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "com.llfbandit.record",
        extra_maven_labels = [],
        android_manifest = "android/src/main/AndroidManifest.xml",
        has_resources = True,
    )

    # Resources must be compiled into the library so R.drawable.* resolves
    # and the drawables merge into the consuming APK.
    asserts.true(
        env,
        'resource_files = glob(["src/main/res/**"], allow_empty = False)' in content,
        "expected resource_files glob in:\n" + content,
    )

    # The R class (and BuildConfig) must be generated against the plugin's
    # own namespace.
    asserts.true(
        env,
        'custom_package = "com.llfbandit.record"' in content,
        "expected custom_package in:\n" + content,
    )
    asserts.true(
        env,
        "_build_config/com/llfbandit/record/BuildConfig.java" in content,
        "expected BuildConfig against the plugin namespace in:\n" + content,
    )
    asserts.true(
        env,
        'load("@bazel_skylib//rules:write_file.bzl", "write_file")' in content,
        content,
    )
    asserts.true(env, "write_file(\n    name = \"_build_config_src\"," in content, content)
    asserts.false(env, "genrule" in content, content)
    asserts.false(env, "cat >" in content, content)

    # The plugin's own manifest is used (RECORD_AUDIO merges into the APK).
    asserts.true(
        env,
        'manifest = "src/main/AndroidManifest.xml"' in content,
        "expected plugin manifest in:\n" + content,
    )
    asserts.true(env, "exports_manifest = 1" in content, content)

    # The androidx compile baseline comes from the engine target's exports
    # (mirroring the Flutter embedding POM), not from a per-plugin list —
    # a dep-less build.gradle still compiles against NotificationCompat etc.
    asserts.true(env, '":_engine",' in content, content)
    asserts.false(
        env,
        "@rules_android_maven//:androidx" in content,
        "androidx deps must flow via the engine's exports, not be " +
        "restated per plugin:\n" + content,
    )

    return unittest.end(env)

record_android_subpackage_test = unittest.make(_record_android_subpackage_test_impl)

def _resources_without_manifest_test_impl(ctx):
    """Resources force a manifest: synthesize one when the plugin ships none."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "dev.example.res_only_manifestless",
        extra_maven_labels = [],
        android_manifest = "",
        has_resources = True,
    )

    asserts.true(
        env,
        'resource_files = glob(["src/main/res/**"], allow_empty = False)' in content,
        content,
    )

    # rules_android requires a manifest whenever resource_files is set;
    # AGP treats a missing library manifest as an empty one, so we
    # synthesize the equivalent.
    asserts.true(env, 'manifest = ":_manifest"' in content, content)
    asserts.true(env, "write_file(\n    name = \"_manifest\"," in content, content)
    asserts.true(
        env,
        'package=\\"dev.example.res_only_manifestless\\"' in content,
        content,
    )
    asserts.false(env, "exports_manifest" in content, content)
    asserts.false(env, "genrule" in content, content)
    asserts.false(env, "cat >" in content, content)

    return unittest.end(env)

resources_without_manifest_test = unittest.make(_resources_without_manifest_test_impl)

def _no_resources_subpackage_test_impl(ctx):
    """url_launcher_android shape: sources + manifest, no res/."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "android/src/main",
        java_package = "io.flutter.plugins.urllauncher",
        extra_maven_labels = ["@rules_android_maven//:androidx_browser_browser"],
        android_manifest = "android/src/main/AndroidManifest.xml",
        has_resources = False,
    )

    asserts.false(env, "resource_files" in content, content)
    asserts.true(
        env,
        '"@rules_android_maven//:androidx_browser_browser",' in content,
        "gradle-declared deps must still be wired:\n" + content,
    )

    return unittest.end(env)

no_resources_subpackage_test = unittest.make(_no_resources_subpackage_test_impl)

def _empty_subpackage_test_impl(ctx):
    """No Android sources and no resources → the empty aggregator stub."""
    env = unittest.begin(ctx)

    content = make_android_subpackage_build_content(
        android_src_dir = "",
        java_package = "",
        extra_maven_labels = [],
    )

    asserts.true(env, "srcs = []" in content, content)
    asserts.false(env, "resource_files" in content, content)
    asserts.false(env, "flutter_android_engine" in content, content)

    return unittest.end(env)

empty_subpackage_test = unittest.make(_empty_subpackage_test_impl)

# The non-Dart remainder of `lib/` — the same partition rules_dart's
# `make_dart_library_build_content` emits. `srcs + resources = lib/**`
# for every spoke, whichever generator ran; a published package's `lib/`
# is addressable as `package:<name>/<path>` whatever the extension, so a
# spoke that keeps only `*.dart` is a package with pieces missing.
_RESOURCES_GLOB = """    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),"""

def _spokes_state_their_resolved_version_test_impl(ctx):
    """Every Flutter spoke shape emits the version pub resolved it at.

    The attribute has one use: when a single package name arrives from two
    hubs, two records stating different versions fail the build instead of the
    first silently standing in for the second. A spoke that omits it is
    invisible to that check, because an unstated version never conflicts — so
    "the value reached the generated BUILD file" is the whole contract, and
    it has to hold for the plugin and library shapes as well as the plain
    `dart_library` one rules_dart emits.

    `e2e/dual_hub` is the other half of this: it pins that two spokes stating
    *different* versions actually fail a build that collects both.
    """
    env = unittest.begin(ctx)

    plugin = make_flutter_plugin_build_content(
        name = "sqlite3_web",
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
        version = "2.2.0",
    )
    asserts.true(env, '\n    version = "2.2.0",' in plugin, plugin)

    library = make_flutter_library_build_content(
        name = "cupertino_icons",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {},
        version = "1.0.8",
    )
    asserts.true(env, '\n    version = "1.0.8",' in library, library)

    return unittest.end(env)

spokes_state_their_resolved_version_test = unittest.make(
    _spokes_state_their_resolved_version_test_impl,
)

def _spoke_without_a_version_states_none_test_impl(ctx):
    """An unknown version emits no attribute rather than an empty one.

    `version = ""` and no `version` at all mean the same thing to the
    agreement check — neither conflicts with anything — so the line is omitted
    rather than written blank, matching what rules_dart's own spoke generator
    does. A spoke that wrote `version = ""` would read as a package asserting
    it has no version, which is not what "we could not resolve one" means.
    """
    env = unittest.begin(ctx)

    library = make_flutter_library_build_content(
        name = "cupertino_icons",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {},
    )

    # The newline and indent matter: a bare `"version = "` also matches
    # `language_version = `, which every spoke states and which this is not
    # about.
    asserts.false(env, "\n    version = " in library, library)

    return unittest.end(env)

spoke_without_a_version_states_none_test = unittest.make(
    _spoke_without_a_version_states_none_test_impl,
)

def _plugin_spoke_carries_resources_test_impl(ctx):
    """A plugin spoke's BUILD partitions lib/ into srcs + resources."""
    env = unittest.begin(ctx)

    content = make_flutter_plugin_build_content(
        name = "sqlite3_web",
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
    )

    asserts.true(env, _RESOURCES_GLOB in content, content)

    return unittest.end(env)

plugin_spoke_carries_resources_test = unittest.make(_plugin_spoke_carries_resources_test_impl)

def _library_spoke_carries_resources_test_impl(ctx):
    """A flutter_library spoke keeps lib/'s non-Dart remainder alongside its declared assets.

    The two channels coexist by design: `resources` says the file is part
    of the package's `lib/` tree (staged wherever the whole package is),
    while `pkg_assets`/`pkg_shaders` say it is bundled into flutter_assets.
    A shader under `lib/` is legitimately both.
    """
    env = unittest.begin(ctx)

    content = make_flutter_library_build_content(
        name = "shader_pkg",
        deps = [],
        language_version = "3.4",
        code_assets = [],
        has_unreplaced_hook = "",
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {":lib/glow.frag": "lib/glow.frag"},
    )

    asserts.true(env, _RESOURCES_GLOB in content, content)
    asserts.true(env, "pkg_shaders" in content, content)

    return unittest.end(env)

library_spoke_carries_resources_test = unittest.make(_library_spoke_carries_resources_test_impl)

def _spoke_with_shaders_declares_their_includes_test_impl(ctx):
    """A spoke with shaders lists its GLSL as what they may `#include`.

    The compile runs sandboxed with only declared inputs, so a shader that
    includes a sibling `.glsl` fails unless the spoke declares it.
    """
    env = unittest.begin(ctx)

    def content(pkg_shaders):
        return make_flutter_library_build_content(
            name = "shader_pkg",
            deps = [],
            language_version = "3.4",
            code_assets = [],
            has_unreplaced_hook = "",
            fonts_json_str = "",
            font_files = {},
            pkg_assets = {},
            pkg_shaders = pkg_shaders,
        )

    with_shaders = content({":shaders/glow.frag": "shaders/glow.frag"})
    asserts.true(env, "shader_includes = glob(" in with_shaders, with_shaders)
    asserts.true(env, '"**/*.glsl"' in with_shaders, with_shaders)
    asserts.false(env, "shader_includes" in content({}))

    return unittest.end(env)

spoke_with_shaders_declares_their_includes_test = unittest.make(_spoke_with_shaders_declares_their_includes_test_impl)

def _overlay_substitutes_the_language_version_test_impl(ctx):
    """An overlay declares the language version by placeholder, never by value.

    The package's own `environment.sdk` is the single source of truth; the
    spoke derives from it and substitutes here. A template that spelled the
    version out would be a second declaration of the same fact, and the
    version ladder makes the two drift silently: `ext/objective_c/9/` matches
    every 9.x, so a release that raises the SDK floor keeps the stale literal.
    """
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = 'flutter_plugin(name = "{PKG}", language_version = "{LANGUAGE_VERSION}", v = "{VERSION}", h = "{HUB_NAME}")',
        hub_name = "hub",
        package_name = "objective_c",
        version = "9.3.0",
        language_version = "3.10",
        deps = "",
    )

    asserts.equals(
        env,
        'flutter_plugin(name = "objective_c", language_version = "3.10", v = "9.3.0", h = "hub")',
        rendered,
    )

    return unittest.end(env)

def _overlay_without_a_language_version_is_left_alone_test_impl(ctx):
    """Not every overlay declares one; substitution must not invent the attribute."""
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = 'cc_library(name = "{PKG}")',
        hub_name = "hub",
        package_name = "jni",
        version = "1.0.0",
        language_version = "3.3",
        deps = "",
    )

    asserts.equals(env, 'cc_library(name = "jni")', rendered)

    return unittest.end(env)

def _hardcoded_language_version_is_rejected_test_impl(ctx):
    """A literal version in an overlay is caught, not silently obeyed.

    Substitution alone only *permits* a single declaration; this is what
    makes a second one impossible. Without it an overlay could keep spelling
    the version out and quietly win over the derived value, which is the
    state this check was written to end.
    """
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "3.3",
        find_hardcoded_language_version('flutter_plugin(\n    language_version = "3.3",\n)'),
    )

    # Whitespace around `=` is a style choice buildifier can change; the
    # check must not be evadable by reformatting.
    asserts.equals(
        env,
        "3.10",
        find_hardcoded_language_version('    language_version="3.10",'),
    )

    # The placeholder is the one accepted spelling.
    asserts.equals(
        env,
        "",
        find_hardcoded_language_version('    language_version = "{LANGUAGE_VERSION}",'),
    )

    # An overlay that declares none is fine.
    asserts.equals(env, "", find_hardcoded_language_version('cc_library(name = "x")'))

    return unittest.end(env)

hardcoded_language_version_is_rejected_test = unittest.make(
    _hardcoded_language_version_is_rejected_test_impl,
)

overlay_substitutes_the_language_version_test = unittest.make(
    _overlay_substitutes_the_language_version_test_impl,
)
overlay_without_a_language_version_is_left_alone_test = unittest.make(
    _overlay_without_a_language_version_is_left_alone_test_impl,
)

def _overlay_substitutes_the_dependencies_test_impl(ctx):
    """An overlay names its dependencies by placeholder, never by hand.

    The package's own pubspec is the single source of truth; the spoke
    intersects it with the lock and substitutes the labels here. The rendered
    body carries the eight-space indent a `deps = [` block sits at, so the
    substituted BUILD file is buildifier-clean.
    """
    env = unittest.begin(ctx)

    rendered = apply_overlay_substitutions(
        content = "flutter_plugin(\n    deps = [\n        {DEPS}\n    ],\n)",
        hub_name = "hub",
        package_name = "objective_c",
        version = "9.6.0",
        language_version = "3.10",
        deps = render_overlay_deps([
            "@hub__ffi//:ffi",
            "@hub__meta//:meta",
        ]),
    )

    asserts.equals(
        env,
        'flutter_plugin(\n    deps = [\n        "@hub__ffi//:ffi",\n        "@hub__meta//:meta",\n    ],\n)',
        rendered,
    )

    # A package with no in-lock dependencies renders an empty list, not a
    # dangling comma or a missing attribute.
    asserts.equals(env, "", render_overlay_deps([]))

    return unittest.end(env)

def _hardcoded_overlay_dependency_is_rejected_test_impl(ctx):
    """A hand-written sibling label in an overlay is caught, not obeyed.

    This is the check that would have caught the `objective_c` break:
    9.5.0 dropped `native_toolchain_c` from its `dependencies`, so the lock
    stopped carrying it and the hub stopped creating the spoke, while
    `ext/objective_c/9/` — one directory for the whole major — kept asking
    for `@<hub>__native_toolchain_c`. The build died on an unknown repo
    naming neither `objective_c` nor the overlay that referenced it.
    """
    env = unittest.begin(ctx)

    asserts.equals(
        env,
        "@{HUB_NAME}__native_toolchain_c//:native_toolchain_c",
        find_hardcoded_hub_dep(
            '    deps = [\n        "@{HUB_NAME}__native_toolchain_c//:native_toolchain_c",\n    ],',
        ),
    )

    # The placeholder is the one accepted spelling.
    asserts.equals(env, "", find_hardcoded_hub_dep("    deps = [\n        {DEPS}\n    ],"))

    # Naming {HUB_NAME} outside a spoke label — a doc comment, say — is not
    # the thing being prohibited.
    asserts.equals(env, "", find_hardcoded_hub_dep("# {HUB_NAME} is substituted here."))

    # A label pointing at another repo entirely stays allowed: only sibling
    # spokes are derivable from the pubspec.
    asserts.equals(
        env,
        "",
        find_hardcoded_hub_dep('    deps = ["@rules_flutter//flutter:material_icons"],'),
    )

    return unittest.end(env)

overlay_substitutes_the_dependencies_test = unittest.make(
    _overlay_substitutes_the_dependencies_test_impl,
)
hardcoded_overlay_dependency_is_rejected_test = unittest.make(
    _hardcoded_overlay_dependency_is_rejected_test_impl,
)

def _make_mock_overlay_ctx(files, root_anchors = None, hub_name = "deps"):
    """Construct a fake repository_ctx recording ctx.watch and ctx.read calls.

    Args:
        files: Dict mapping absolute path string -> file content string.
        root_anchors: Optional dict mapping anchor label string -> absolute
            anchor file path. Defaults to `{"//plugin_overlays:BUILD.bazel":
            "/workspace/plugin_overlays/BUILD.bazel"}`.
        hub_name: Value for `ctx.attr.hub_name`.

    Returns:
        A struct with `.ctx`, `.watched` (list of watched path strings), and
        `.probed` (list of all path strings constructed via `get_child`).
    """
    anchors = root_anchors if root_anchors != None else {
        "//plugin_overlays:BUILD.bazel": "/workspace/plugin_overlays/BUILD.bazel",
    }
    existing_paths = {}
    for anchor_path in anchors.values():
        existing_paths[anchor_path] = True
        parent = anchor_path.rsplit("/", 1)[0] if "/" in anchor_path else ""
        if parent:
            existing_paths[parent] = True
    for file_path in files.keys():
        existing_paths[file_path] = True
        parts = file_path.split("/")
        for i in range(1, len(parts)):
            prefix = "/".join(parts[:i])
            if prefix:
                existing_paths[prefix] = True

    watched = []
    probed = []

    def _make_path(path_str):
        parent_str = path_str.rsplit("/", 1)[0] if "/" in path_str else ""

        def _get_child(segment):
            child_str = path_str + "/" + segment
            probed.append(child_str)
            return _make_path(child_str)

        return struct(
            path = path_str,
            exists = path_str in existing_paths,
            dirname = struct(
                path = parent_str,
                exists = parent_str in existing_paths,
                get_child = lambda seg: _get_child_from(parent_str, seg),
            ) if parent_str else None,
            get_child = _get_child,
        )

    def _get_child_from(base_str, segment):
        child_str = base_str + "/" + segment
        probed.append(child_str)
        return _make_path(child_str)

    def _path(label_or_str):
        key = str(label_or_str)
        resolved = anchors.get(key, key)
        return _make_path(resolved)

    def _watch(path_obj):
        p = path_obj.path if hasattr(path_obj, "path") else str(path_obj)
        watched.append(p)

    def _read(path_obj):
        p = path_obj.path if hasattr(path_obj, "path") else str(path_obj)
        if p not in files:
            fail("mock ctx.read on missing file: " + p)
        return files[p]

    return struct(
        ctx = struct(
            attr = struct(hub_name = hub_name),
            path = _path,
            watch = _watch,
            read = _read,
        ),
        watched = watched,
        probed = probed,
    )

def _overlay_watches_missing_package_and_candidates_test_impl(ctx):
    """Probing an overlay root with no matching package watches the package dir and all version candidates.

    Without `ctx.watch` on the probed paths, adding `<root>/<pkg>/<ver>/BUILD.bazel.tpl`
    after `@<hub>__<pkg>` has been fetched once leaves the spoke repository stale
    on incremental builds.
    """
    env = unittest.begin(ctx)

    mock = _make_mock_overlay_ctx(files = {})
    rendered = resolve_overlay(
        mock.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        ["@deps__meta//:meta"],
    )

    asserts.equals(env, "", rendered)
    asserts.equals(
        env,
        [
            "/workspace/plugin_overlays/BUILD.bazel",
            "/workspace/plugin_overlays",
            "/workspace/plugin_overlays/audio_session",
            "/workspace/plugin_overlays/audio_session/0.1.21",
            "/workspace/plugin_overlays/audio_session/0.1.21/BUILD.bazel.tpl",
            "/workspace/plugin_overlays/audio_session/0.1",
            "/workspace/plugin_overlays/audio_session/0.1/BUILD.bazel.tpl",
            "/workspace/plugin_overlays/audio_session/0",
            "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl",
            "/workspace/plugin_overlays/audio_session/BUILD.bazel.tpl",
        ],
        mock.watched,
    )
    for p in mock.probed:
        asserts.true(
            env,
            p in mock.watched,
            "probed path %s must be watched by ctx.watch, got watched=%s" % (p, mock.watched),
        )

    return unittest.end(env)

overlay_watches_missing_package_and_candidates_test = unittest.make(
    _overlay_watches_missing_package_and_candidates_test_impl,
)

def _overlay_watches_more_specific_version_candidates_test_impl(ctx):
    """Matching `<major>/BUILD.bazel.tpl` still watches `<major>.<minor>.<patch>` and `<major>.<minor>`.

    When a user drops a more specific `<major>.<minor>.<patch>/BUILD.bazel.tpl`
    override alongside an existing `<major>/BUILD.bazel.tpl`, Bazel only
    invalidates the spoke if the higher-precedence candidate paths were watched
    during the initial lookup.
    """
    env = unittest.begin(ctx)

    files = {
        "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl": (
            'flutter_plugin(name = "{PKG}", version = "{VERSION}", language_version = "{LANGUAGE_VERSION}", deps = [\n        {DEPS}\n    ]) # major'
        ),
    }
    mock1 = _make_mock_overlay_ctx(files = files)
    rendered1 = resolve_overlay(
        mock1.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        ["@deps__meta//:meta"],
    )
    asserts.true(env, "# major" in rendered1, rendered1)
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0.1.21/BUILD.bazel.tpl" in mock1.watched,
        "patch candidate must be watched so a later override invalidates the spoke: %s" % mock1.watched,
    )
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0.1/BUILD.bazel.tpl" in mock1.watched,
        "minor candidate must be watched so a later override invalidates the spoke: %s" % mock1.watched,
    )
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl" in mock1.watched,
        "matched major candidate must be watched: %s" % mock1.watched,
    )

    # Simulate adding the patch-specific override on an incremental build: the
    # newly added path must have been in mock1.watched, and re-running resolves
    # the patch-specific template.
    patch_tpl = "/workspace/plugin_overlays/audio_session/0.1.21/BUILD.bazel.tpl"
    asserts.true(env, patch_tpl in mock1.watched)
    files_after = dict(files)
    files_after[patch_tpl] = (
        'flutter_plugin(name = "{PKG}", version = "{VERSION}", language_version = "{LANGUAGE_VERSION}", deps = [\n        {DEPS}\n    ]) # patch'
    )
    mock2 = _make_mock_overlay_ctx(files = files_after)
    rendered2 = resolve_overlay(
        mock2.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        ["@deps__meta//:meta"],
    )
    asserts.true(env, "# patch" in rendered2, rendered2)

    return unittest.end(env)

overlay_watches_more_specific_version_candidates_test = unittest.make(
    _overlay_watches_more_specific_version_candidates_test_impl,
)

def _overlay_watches_android_subpackage_candidates_test_impl(ctx):
    """Looking up `android/BUILD.bazel.tpl` watches all candidate paths along the version ladder.

    When a top-level overlay is present without an `android/BUILD.bazel.tpl`,
    the spoke emits an empty stub `android/BUILD.bazel`. If the user later adds
    `<root>/<pkg>/<ver>/android/BUILD.bazel.tpl` (or upgrades it to a more
    specific version), the spoke must re-evaluate on incremental builds.
    """
    env = unittest.begin(ctx)

    files = {
        "/workspace/plugin_overlays/audio_session/0/BUILD.bazel.tpl": (
            'flutter_plugin(name = "{PKG}", language_version = "{LANGUAGE_VERSION}")'
        ),
    }
    mock1 = _make_mock_overlay_ctx(files = files)
    android1 = resolve_overlay_template(
        mock1.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        [],
        "android/BUILD.bazel.tpl",
    )
    asserts.equals(env, "", android1)
    for expected in [
        "/workspace/plugin_overlays/audio_session/0.1.21/android",
        "/workspace/plugin_overlays/audio_session/0.1.21/android/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/audio_session/0.1/android",
        "/workspace/plugin_overlays/audio_session/0.1/android/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/audio_session/0/android",
        "/workspace/plugin_overlays/audio_session/0/android/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/audio_session/android",
        "/workspace/plugin_overlays/audio_session/android/BUILD.bazel.tpl",
    ]:
        asserts.true(
            env,
            expected in mock1.watched,
            "expected %s in watched %s" % (expected, mock1.watched),
        )

    # Adding `0/android/BUILD.bazel.tpl` touches a path watched during mock1.
    major_android_tpl = "/workspace/plugin_overlays/audio_session/0/android/BUILD.bazel.tpl"
    asserts.true(env, major_android_tpl in mock1.watched)
    files_with_android = dict(files)
    files_with_android[major_android_tpl] = 'kt_android_library(name = "lib", custom_package = "{PKG}")'
    mock2 = _make_mock_overlay_ctx(files = files_with_android)
    android2 = resolve_overlay_template(
        mock2.ctx,
        "//plugin_overlays:BUILD.bazel",
        "audio_session",
        "0.1.21",
        "3.4",
        [],
        "android/BUILD.bazel.tpl",
    )
    asserts.equals(env, 'kt_android_library(name = "lib", custom_package = "audio_session")', android2)
    asserts.true(
        env,
        "/workspace/plugin_overlays/audio_session/0.1.21/android/BUILD.bazel.tpl" in mock2.watched,
    )

    return unittest.end(env)

overlay_watches_android_subpackage_candidates_test = unittest.make(
    _overlay_watches_android_subpackage_candidates_test_impl,
)

def _overlay_multi_root_watches_higher_priority_root_test_impl(ctx):
    """When a lower-priority root matches, higher-priority roots that missed are still watched.

    `flutter.plugin_overlays` prepends user roots ahead of `@rules_flutter//ext:BUILD.bazel`.
    When a package initially resolves from `@rules_flutter//ext`, the user root's
    probed candidate paths must all be watched so dropping a local override into
    the user root invalidates the spoke on the next incremental build.
    """
    env = unittest.begin(ctx)

    anchors = {
        "//plugin_overlays:BUILD.bazel": "/workspace/plugin_overlays/BUILD.bazel",
        "@rules_flutter//ext:BUILD.bazel": "/ext_repo/ext/BUILD.bazel",
    }
    files = {
        "/ext_repo/ext/objective_c/9/BUILD.bazel.tpl": (
            'flutter_plugin(name = "{PKG}", language_version = "{LANGUAGE_VERSION}", deps = [\n        {DEPS}\n    ]) # bundled'
        ),
    }
    mock = _make_mock_overlay_ctx(files = files, root_anchors = anchors)

    overlay_content, overlay_android_content = resolve_overlay_roots(
        mock.ctx,
        ["//plugin_overlays:BUILD.bazel", "@rules_flutter//ext:BUILD.bazel"],
        "objective_c",
        "9.3.0",
        "3.10",
        ["@deps__ffi//:ffi"],
    )

    asserts.true(env, "# bundled" in overlay_content, overlay_content)
    asserts.equals(env, "", overlay_android_content)
    for expected_watched in [
        "/workspace/plugin_overlays/objective_c",
        "/workspace/plugin_overlays/objective_c/9.3.0/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/objective_c/9.3/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/objective_c/9/BUILD.bazel.tpl",
        "/workspace/plugin_overlays/objective_c/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3.0/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3.0/android/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9.3/android/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/9/android/BUILD.bazel.tpl",
        "/ext_repo/ext/objective_c/android/BUILD.bazel.tpl",
    ]:
        asserts.true(
            env,
            expected_watched in mock.watched,
            "expected %s in watched: %s" % (expected_watched, mock.watched),
        )

    return unittest.end(env)

overlay_multi_root_watches_higher_priority_root_test = unittest.make(
    _overlay_multi_root_watches_higher_priority_root_test_impl,
)

def _overlay_rewrites_cat_genrules_to_write_file_test_impl(ctx):
    """Overlay templates using `cat > $@ <<'EOF'` genrules are rewritten to `write_file`."""
    env = unittest.begin(ctx)

    tpl = """\
load("@rules_flutter//flutter:android.bzl", "flutter_android_engine")
load("@rules_java//java:java_library.bzl", "java_library")

genrule(
    name = "_build_config_src",
    outs = ["_build_config/com/ryanheise/audio_session/BuildConfig.java"],
    cmd = "cat > $@ <<'EOF'\\npackage com.ryanheise.audio_session;\\npublic final class BuildConfig {\\n  public static final boolean DEBUG = false;\\n  public static final String LIBRARY_PACKAGE_NAME = \\"com.ryanheise.audio_session\\";\\n  public static final String BUILD_TYPE = \\"release\\";\\n}\\nEOF\\n",
)
"""
    rendered = apply_overlay_substitutions(
        content = tpl,
        hub_name = "deps",
        package_name = "audio_session",
        version = "0.1.21",
        language_version = "3.4",
        deps = "",
    )
    asserts.true(
        env,
        'load("@bazel_skylib//rules:write_file.bzl", "write_file")' in rendered,
        rendered,
    )
    asserts.true(
        env,
        'write_file(\n    name = "_build_config_src",\n    out = "_build_config/com/ryanheise/audio_session/BuildConfig.java",' in rendered,
        rendered,
    )
    asserts.false(env, "genrule" in rendered, rendered)
    asserts.false(env, "cat >" in rendered, rendered)

    return unittest.end(env)

overlay_rewrites_cat_genrules_to_write_file_test = unittest.make(
    _overlay_rewrites_cat_genrules_to_write_file_test_impl,
)

def flutter_pub_package_test_suite(name):
    unittest.suite(
        name,
        spokes_state_their_resolved_version_test,
        spoke_without_a_version_states_none_test,
        hardcoded_language_version_is_rejected_test,
        overlay_substitutes_the_language_version_test,
        overlay_without_a_language_version_is_left_alone_test,
        overlay_substitutes_the_dependencies_test,
        hardcoded_overlay_dependency_is_rejected_test,
        overlay_watches_missing_package_and_candidates_test,
        overlay_watches_more_specific_version_candidates_test,
        overlay_watches_android_subpackage_candidates_test,
        overlay_multi_root_watches_higher_priority_root_test,
        overlay_rewrites_cat_genrules_to_write_file_test,
        parse_gradle_android_namespace_test,
        parse_android_manifest_package_test,
        record_android_subpackage_test,
        resources_without_manifest_test,
        no_resources_subpackage_test,
        empty_subpackage_test,
        plugin_spoke_carries_resources_test,
        library_spoke_carries_resources_test,
        spoke_with_shaders_declares_their_includes_test,
    )
