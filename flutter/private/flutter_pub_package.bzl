"""flutter_pub_package — the `flutter pub get` analog for a single hosted
Flutter pub.dev package.

For each package in a Flutter app's pubspec.lock this rule:
  1. Downloads the same `pub.dev/api/packages/<name>/versions/<version>.tar.gz`
     archive that rules_dart's `pub_lock_package` would.
  2. Reads the package's pubspec.yaml.
  3. Parses `flutter.plugin.platforms` via `parse_flutter_plugin_block`.
  4. Scans the extracted package tree for per-platform Apple source layouts
     (modern SwiftPM `<platform>/<pkg>/Sources/<pkg>/`, shared-darwin
     `darwin/Classes/`, legacy `<platform>/Classes/`).
  5. Branches on whether a `flutter.plugin` block is present:
       - Absent → emit a plain `dart_library` via rules_dart's
         `make_dart_library_build_content`. Pure-Dart pub packages reach
         consumers exactly as they do under `pub.pub()`.
       - Present → emit a `flutter_plugin` whose `plugin_platforms_json`
         carries the parsed metadata, plus per-platform sub-targets:
         `:<pkg>_apple_macos` / `:<pkg>_apple_ios` `flutter_apple_plugin_library`
         when Apple sources are detected for the corresponding
         `flutter.plugin.platforms.<plat>` entry.

This is the rules_flutter sibling of rules_dart's `pub_lock_package`. The
two rules never run for the same package: `flutter.pub()` always invokes
this one for hosted pub packages; `pub.pub()` (in non-Flutter modules)
keeps using `pub_lock_package`. Both share the same archive download +
extract pattern (replicated, not abstracted, to keep the cross-repo
surface small).
"""

load("@rules_dart//dart/pub:pub_lock_package.bzl", "derive_language_version", "make_dart_library_build_content", "trim_gzip_trailing_nulls")
load("@rules_dart//dart/pub:yaml_parser.bzl", "parse_pubspec_deps", "parse_pubspec_sdk_constraint")
load("//flutter/private:artifact_urls.bzl", "require_sha256")
load("//flutter/private:download.bzl", "pinned_download")
load("//flutter/private:flutter_pubspec.bzl", "parse_flutter_assets_block", "parse_flutter_plugin_block")

# Apple source extensions we sweep into the per-platform plugin library.
_APPLE_SRC_EXTENSIONS = ("swift", "m", "mm", "h")

# C/C++ source extensions for Linux/Windows plugin libraries.
_DESKTOP_SRC_EXTENSIONS = ("cc", "cpp", "c", "h", "hh", "hpp")

# Kotlin/Java source extensions for Android plugin libraries.
_ANDROID_SRC_EXTENSIONS = ("kt", "java")

def _has_files_under(ctx, relative_path, extensions = None):
    """Check `<package>/<relative_path>` for source files.

    Returns True if the directory exists and contains at least one file
    matching one of `extensions` (any file when `extensions` is None).
    `ctx.path(p).readdir()` is the documented repo-rule way to walk a
    directory; recursing in Starlark keeps the logic local instead of
    forking out to `find`.
    """
    root = ctx.path(relative_path)
    if not root.exists:
        return False

    stack = [root]
    for _ in range(10000):  # bound the walk; pub packages are not deep
        if not stack:
            break
        d = stack.pop()
        if not d.exists:
            continue
        for entry in d.readdir():
            if entry.is_dir:
                stack.append(entry)
            else:
                if extensions == None:
                    return True
                name = entry.basename
                ext = name.rsplit(".", 1)[-1] if "." in name else ""
                if ext in extensions:
                    return True
    return False

def _detect_apple_source_dirs(ctx, package_name, platform, shared_darwin_source):
    """List Apple source directory globs for the given platform.

    Returns the relative-to-package-root directories that contain Apple
    sources for `platform`. Empty list when no sources are detected.
    """
    candidates = []

    # Modern SwiftPM layout: <platform>/<pkg>/Sources/<pkg>/...
    swiftpm_dir = "{plat}/{pkg}/Sources/{pkg}".format(plat = platform, pkg = package_name)
    if _has_files_under(ctx, swiftpm_dir, _APPLE_SRC_EXTENSIONS):
        candidates.append(swiftpm_dir)

    # Shared darwin source layout: darwin/Classes/...
    if shared_darwin_source:
        darwin_dir = "darwin/Classes"
        if _has_files_under(ctx, darwin_dir, _APPLE_SRC_EXTENSIONS):
            candidates.append(darwin_dir)

        # Legacy darwin SwiftPM (older path_provider_foundation versions).
        darwin_swiftpm_dir = "darwin/{pkg}/Sources/{pkg}".format(pkg = package_name)
        if _has_files_under(ctx, darwin_swiftpm_dir, _APPLE_SRC_EXTENSIONS):
            candidates.append(darwin_swiftpm_dir)

    # Legacy split layout: <platform>/Classes/...
    legacy_dir = "{plat}/Classes".format(plat = platform)
    if _has_files_under(ctx, legacy_dir, _APPLE_SRC_EXTENSIONS):
        candidates.append(legacy_dir)

    return candidates

def _detect_apple_include_dirs(ctx, source_dirs, package_name):
    """Collect SwiftPM-canonical public-header directories for the given Apple sources.

    SwiftPM's `publicHeadersPath: "include"` (the default) places public
    headers at `Sources/<Target>/include/[<Module>/]Foo.h` and adds the
    `include` directory to the lib's own header search path. Plugins
    relying on this convention `#import "Foo.h"` (bare basename) from
    sibling `.m` files; without an explicit `-I` flag clang can't find
    the header. Mirror SwiftPM by adding both `include` and the
    `include/<pkg>` nested subdirectory (when present) — covers
    headers placed directly under `include/` and the more common
    umbrella-style layout.
    """
    include_dirs = []
    for src_dir in source_dirs:
        include_root = src_dir + "/include"
        include_root_path = ctx.path(include_root)
        if include_root_path.exists:
            include_dirs.append(include_root)
            nested = include_root + "/" + package_name
            if ctx.path(nested).exists:
                include_dirs.append(nested)
    return include_dirs

def _detect_apple_privacy_manifests(ctx, source_dirs):
    """Find each plugin source dir's `PrivacyInfo.xcprivacy` file.

    Apple requires every framework to ship a privacy manifest since
    iOS 17.4 / macOS 14.4; App Store submission walks the bundle for
    `*.xcprivacy` files and aggregates them into the app's privacy
    report. CocoaPods/SwiftPM bundle them automatically as framework
    resources; we mirror by collecting them here and threading them
    through to `flutter_apple_plugin_library`'s `privacy_manifests`
    attr (which forwards to the inner objc/swift_library `data`).

    Two layouts occur in real plugins:

    * **Pattern A** (e.g. `package_info_plus`, `share_plus`):
      `<source_dir>/PrivacyInfo.xcprivacy`.
    * **Pattern B** (e.g. `path_provider_foundation`, `record_ios`,
      `webview_flutter_wkwebview`):
      `<source_dir>/Resources/PrivacyInfo.xcprivacy`.

    Returns a sorted, deduplicated list of relative paths.
    """
    manifests = {}
    for src_dir in source_dirs:
        for relpath in (
            src_dir + "/PrivacyInfo.xcprivacy",
            src_dir + "/Resources/PrivacyInfo.xcprivacy",
        ):
            if ctx.path(relpath).exists:
                manifests[relpath] = True
    return sorted(manifests.keys())

def _detect_desktop_source_dir(ctx, platform):
    """Return the Linux/Windows source dir if it contains C/C++ files.

    Pub plugins put Linux sources at `linux/` and Windows sources at
    `windows/`. We surface a single source dir per platform (the
    plugin's own conventions); subdirectories like `linux/include/` are
    swept by the resulting glob.
    """
    if _has_files_under(ctx, platform, _DESKTOP_SRC_EXTENSIONS):
        return platform
    return ""

def _detect_android_source_dir(ctx):
    """Return the Android source dir if it contains Kotlin/Java files.

    Pub plugins use the standard Android directory layout
    `android/src/main/{kotlin,java}/`.
    """
    if _has_files_under(ctx, "android/src/main", _ANDROID_SRC_EXTENSIONS):
        return "android/src/main"
    return ""

def _detect_android_resources(ctx):
    """True when the plugin ships Android resources at `android/src/main/res/`.

    The standard AGP resource location. Detected resources are compiled
    into the generated `kt_android_library` via `resource_files` so the
    plugin's `R` class resolves and the resources merge into the
    consuming APK — same as any Gradle-built Android library.
    """
    return _has_files_under(ctx, "android/src/main/res")

def parse_gradle_android_namespace(content):
    """Extract `android.namespace` from a Gradle build script.

    Handles the AGP-8 assignment forms
    `namespace = 'com.example'` (Groovy) / `namespace = "com.example"`
    (Kotlin DSL) and the Groovy method-call form `namespace 'com.example'`.

    Args:
        content: The `build.gradle` / `build.gradle.kts` file content.

    Returns:
        The declared namespace, or empty string when the script
        declares none.
    """
    for raw_line in content.split("\n"):
        line = raw_line.strip()
        if not line.startswith("namespace"):
            continue
        rest = line[len("namespace"):].strip()
        if rest.startswith("="):
            rest = rest[1:].strip()
        for quote in ("'", '"'):
            if rest.startswith(quote):
                end = rest.find(quote, 1)
                if end > 0:
                    return rest[1:end]
    return ""

def parse_android_manifest_package(content):
    """Extract the `package` attribute from an AndroidManifest.xml.

    The pre-AGP-8 way for a library to declare its namespace.

    Args:
        content: The AndroidManifest.xml file content.

    Returns:
        The `package` attribute of the `<manifest>` element, or empty
        string when the manifest carries none.
    """
    start = content.find("<manifest")
    if start < 0:
        return ""
    end = content.find(">", start)
    if end < 0:
        return ""
    tag = content[start:end]
    for quote in ('"', "'"):
        marker = "package=" + quote
        idx = tag.find(marker)
        if idx >= 0:
            close = tag.find(quote, idx + len(marker))
            if close >= 0:
                return tag[idx + len(marker):close]
    return ""

def _detect_android_namespace(ctx):
    """Resolve the plugin's Android namespace the way AGP does.

    AGP determines a library's namespace from `android.namespace` in
    `build.gradle(.kts)`, falling back to the manifest's `package`
    attribute for pre-AGP-8 projects. The namespace is where the
    generated `R` and `BuildConfig` classes live, so resource
    references like `R.drawable.ic_mic` only resolve when we use the
    same one. Returns empty string when the plugin declares neither.
    """
    for filename in ("android/build.gradle", "android/build.gradle.kts"):
        p = ctx.path(filename)
        if p.exists:
            namespace = parse_gradle_android_namespace(ctx.read(p))
            if namespace:
                return namespace
    manifest_path = ctx.path("android/src/main/AndroidManifest.xml")
    if manifest_path.exists:
        return parse_android_manifest_package(ctx.read(manifest_path))
    return ""

def _detect_android_manifest(ctx):
    """Return the plugin's `android/src/main/AndroidManifest.xml` path if present.

    AGP's `ManifestMerger2` combines each Android library's manifest into
    the consuming app's final AndroidManifest.xml at build time. Plugins
    routinely declare `<activity>`, `<service>`, `<receiver>`,
    `<provider>`, `<uses-permission>`, and `<queries>` entries this way
    (e.g. url_launcher_android's WebViewActivity, record_android's
    RECORD_AUDIO permission). `rules_android`'s `android_binary` runs
    the equivalent merger over its dep graph; a `kt_android_library`
    (which extends `android_library`) participates if it sets
    `manifest = "..."`. Returns the path relative to the spoke root, or
    empty when the plugin ships no manifest.
    """
    if ctx.path("android/src/main/AndroidManifest.xml").exists:
        return "android/src/main/AndroidManifest.xml"
    return ""

def _detect_android_native_build(ctx):
    """True when the plugin's Gradle build compiles native code with the NDK.

    Gradle-built Flutter plugins declare `externalNativeBuild` in
    `android/build.gradle*` to compile C/C++ sources (CMake / ndk-build)
    into a shared library the APK must carry — e.g. package:jni's
    libdartjni.so. rules_flutter has no generic translation for those
    builds; packages that need one ship a curated overlay (bundled under
    `@rules_flutter//ext/` or user-supplied via `flutter.plugin_overlays`).
    Detection lets the generated android/ sub-package fail loudly instead
    of silently producing an APK missing the library.
    """
    for filename in ("android/build.gradle", "android/build.gradle.kts"):
        p = ctx.path(filename)
        if p.exists and "externalNativeBuild" in ctx.read(p):
            return True
    return False

def _make_android_native_build_unsupported_content(package_name, version):
    """Generate an `android/BUILD.bazel` that fails at load time.

    Emitted for plugins whose Gradle build compiles native code for Android
    (externalNativeBuild) when no overlay provides a Bazel translation.
    Android builds load this file through the hub's
    `android/all_android_plugin_libs` aggregator and fail with a clear
    message; non-Android platforms never load it and are unaffected.
    """
    message = (
        "package:{pkg} {version} compiles native code for Android via " +
        "Gradle's externalNativeBuild, which rules_flutter cannot " +
        "translate automatically. An APK built without that library would " +
        "crash at plugin registration, so this is a hard error. Provide a " +
        "plugin overlay for {pkg} (flutter.plugin_overlays in MODULE.bazel) " +
        "that compiles the package's native sources with cc_shared_library " +
        "and ships them through flutter_plugin.native_deps — see " +
        "@rules_flutter//ext/jni for the canonical example."
    ).format(pkg = package_name, version = version)
    return 'fail("' + message + '")\n'

def _parse_consumer_proguard_files(content):
    """Extract `consumerProguardFiles` paths from a Gradle build script.

    AGP plugins declare reflection-keep rules they need consumers to
    apply via:
      consumerProguardFiles 'consumer-rules.pro'         (Groovy)
      consumerProguardFiles "consumer-rules.pro"         (Groovy)
      consumerProguardFiles("consumer-rules.pro")        (Kotlin DSL)
    Multiple files per declaration are comma-separated. Returns a sorted,
    deduplicated list of paths. Permissive matching by design: false
    positives in comments / strings are filtered out by the existence
    check downstream.
    """
    paths = {}
    for raw_line in content.split("\n"):
        line = raw_line.strip()
        if "consumerProguardFiles" not in line:
            continue

        # Snip everything after the keyword and pull paths out of the
        # quoted segments. Supports both Groovy ('...') and Kotlin DSL
        # ("..."), and handles comma-separated multi-arg invocations.
        rest = line.split("consumerProguardFiles", 1)[1]
        for quote in ("'", '"'):
            idx = 0
            for _ in range(rest.count(quote) // 2):
                start = rest.find(quote, idx)
                if start < 0:
                    break
                end = rest.find(quote, start + 1)
                if end < 0:
                    break
                paths[rest[start + 1:end]] = True
                idx = end + 1
    return sorted(paths.keys())

def _detect_consumer_proguard_specs(ctx):
    """Find the plugin's `consumer-rules.pro` files, declared via Gradle.

    Reads `android/build.gradle` (or `android/build.gradle.kts`),
    parses `consumerProguardFiles` declarations, and returns paths
    relative to the spoke's `android/` sub-package — only for files
    that actually exist on disk. Empty when the plugin doesn't ship
    consumer rules. AGP propagates these into the consuming app's R8
    invocation; rules_android does the same when they appear in
    `kt_android_library(proguard_specs = [...])` and the binary has
    R8 enabled.
    """
    paths = []
    for filename in ("build.gradle", "build.gradle.kts"):
        gradle_path = ctx.path("android/" + filename)
        if gradle_path.exists:
            for relpath in _parse_consumer_proguard_files(ctx.read(gradle_path)):
                if ctx.path("android/" + relpath).exists:
                    paths.append(relpath)
    return paths

# Map well-known maven coordinates the plugin's `build.gradle` may pull
# in to labels under `@rules_android_maven`. We translate
# `implementation("group:artifact:version")` declarations into Bazel
# dep labels by looking up the `group:artifact` here. The user's
# workspace `maven.install` must include matching artifacts; the bundle
# of androidx + jetbrains coordinates Flutter plugins typically use is
# documented in `docs/TESTING.md` § Plugin verification matrix.
_MAVEN_COORD_TO_LABEL = {
    "androidx.annotation:annotation": "@rules_android_maven//:androidx_annotation_annotation",
    "androidx.lifecycle:lifecycle-common": "@rules_android_maven//:androidx_lifecycle_lifecycle_common",
    "androidx.lifecycle:lifecycle-runtime": "@rules_android_maven//:androidx_lifecycle_lifecycle_runtime",
    "androidx.media:media": "@rules_android_maven//:androidx_media_media",
    "androidx.window:window": "@rules_android_maven//:androidx_window_window",
    "androidx.core:core": "@rules_android_maven//:androidx_core_core",
    "androidx.browser:browser": "@rules_android_maven//:androidx_browser_browser",
    "androidx.fragment:fragment": "@rules_android_maven//:androidx_fragment_fragment",
    "androidx.activity:activity": "@rules_android_maven//:androidx_activity_activity",
    "com.google.android.material:material": "@rules_android_maven//:com_google_android_material_material",
    "com.getkeepsafe.relinker:relinker": "@rules_android_maven//:com_getkeepsafe_relinker_relinker",
}

# Coordinates we deliberately ignore — provided by the kt_android_library
# rule itself or out-of-band. Listing them avoids the parser falling back
# to "drop unknown" silently for things we do recognize.
_MAVEN_COORDS_PROVIDED = {
    "org.jetbrains.kotlin:kotlin-stdlib": True,
    "org.jetbrains.kotlin:kotlin-stdlib-jdk7": True,
    "org.jetbrains.kotlin:kotlin-stdlib-jdk8": True,
}

# Dependency configurations that land on the app's runtime classpath, in both
# DSLs. Groovy spells them bare (`implementation 'group:artifact:version'`)
# and Kotlin DSL parenthesised (`implementation("group:artifact:version")`);
# both reduce to the same leading identifier, so one table covers both.
# `compile` is the pre-Gradle-3.0 spelling of `implementation` / `api`, kept
# so an old plugin still resolves. Variant-prefixed siblings
# (`debugImplementation`, `releaseApi`, ...) share the `Implementation` /
# `Api` / `RuntimeOnly` suffix and match the same way: a dep shipped in one
# variant but not another is still a runtime dep of the APK.
_MAVEN_RUNTIME_CONFIGS = ("implementation", "api", "runtimeOnly", "compile")
_MAVEN_RUNTIME_SUFFIXES = ("Implementation", "Api", "RuntimeOnly")

def _gradle_coord_from_inner(inner):
    """Reduce a dependency-notation string's inner text to `group:artifact`.

    `inner` is the text between one pair of quotes (or an `add()` notation
    argument). Anything without a `group:artifact` pair — a version-catalog
    ref, a variable, a local path, a Gradle map — yields "".

    Args:
        inner: The unquoted notation text.

    Returns:
        `group:artifact`, or "" when it has none.
    """
    parts = inner.split(":")
    if len(parts) < 2:
        return ""
    for part in (parts[0], parts[1]):
        if not part:
            return ""
        for i in range(len(part)):
            c = part[i:i + 1]
            if c in " \t/$'\"{}()":
                return ""
    return parts[0] + ":" + parts[1]

def _gradle_coord_of(rest):
    """Reduce dependency notation to `group:artifact`, or "" when it has none.

    `implementation("androidx.browser:browser:1.9.0")` reduces to
    `androidx.browser:browser`; anything without a quoted `group:artifact`
    pair — a version-catalog ref (`libs.foo`), a variable, a local
    `files(...)` / `fileTree(...)` jar, a Gradle map
    (`group: ..., name: ...`) — yields "". The version part may carry Gradle
    templates (`$kotlin_version`); only `group:artifact` is validated, so
    those still reduce. Callers report "" as unreadable unless the notation
    is a `project()` sibling-module reference, which is left out.
    """
    quote_idx = -1
    quote_char = ""
    for q in ('"', "'"):
        idx = rest.find(q)
        if idx >= 0 and (quote_idx < 0 or idx < quote_idx):
            quote_idx = idx
            quote_char = q
    if quote_idx < 0:
        return ""
    end = rest.find(quote_char, quote_idx + 1)
    if end < 0:
        return ""
    return _gradle_coord_from_inner(rest[quote_idx + 1:end])

def _maven_add_coord(coord, merged, ignored, labels, unknown):
    """File one coordinate into `labels` or `unknown` (provided coords pass)."""
    if coord in _MAVEN_COORDS_PROVIDED:
        return
    label = merged.get(coord)
    if label:
        labels[label] = True
    elif coord not in ignored:
        unknown[coord] = True

def is_java_package_name(value):
    """True when `value` is a well-formed Java package name.

    Each dot-separated segment must start with a letter or underscore and
    continue with letters, digits or underscores. Used to refuse a hostile
    plugin-controlled Android namespace before it reaches generated BUILD
    text.

    Args:
        value: The candidate package name.

    Returns:
        True for names like `com.example.plugin`, False for "", for empty
        segments, and for anything holding quotes, dashes, spaces or `$`.
    """
    if not value:
        return False
    for part in value.split("."):
        if not part:
            return False
        for i in range(len(part)):
            c = part[i:i + 1]
            is_start = ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or c == "_"
            is_part = is_start or ("0" <= c and c <= "9")
            if not (is_part if i else is_start):
                return False
    return True

def is_maven_dep_label(value):
    """True when `value` is a plausible Bazel label for `android_maven_deps`.

    The value must look like a label in another repository (`@...`) or an
    absolute label (`//...`), and must not hold a quote, a backslash or a
    newline that could break out of the generated `deps` list.

    Args:
        value: The candidate label string.

    Returns:
        True when the value has a label shape and no quoting characters.
    """
    if not value:
        return False
    if not (value.startswith("@") or value.startswith("//")):
        return False
    for i in range(len(value)):
        c = value[i:i + 1]
        if c == '"' or c == "'" or c == "\\" or c == "\n" or c == "\r":
            return False
    return True

# Cap on `apply from:` script nesting. A chain deeper than this is a cycle
# in disguise (or a plugin no one can read); the exceeding statement is
# reported unreadable instead of recursing forever.
_GRADLE_APPLY_MAX_DEPTH = 10

def _gradle_flush_to(events, buf, kind):
    """Move `buf`'s text into `events` as a `kind` entry and clear `buf`.

    Args:
        events: The event list being built.
        buf: The character accumulator for the current segment.
        kind: `"stmt"` for a statement, `"open"` for a block header.
    """
    s = "".join(buf)
    for _ in range(len(buf)):
        buf.pop()
    s = s.strip()
    if s or kind == "open":
        events.append(struct(kind = kind, text = s))

def _gradle_lex_comment(content, i, buf, events):
    """Consume a `//` or `/* */` comment; return the `(state, next_i)` pair."""
    if content[i:i + 2] == "//":
        _gradle_flush_to(events, buf, "stmt")
        return (1, i + 2)
    return (2, i + 2)

def _gradle_lex_string_open(content, i, buf):
    """Enter the string state for the quote at `i`; return `(state, next_i)`."""
    if content[i:i + 3] == "'''":
        buf.extend(["'", "'", "'"])
        return (5, i + 3)
    if content[i:i + 3] == '"""':
        buf.extend(['"', '"', '"'])
        return (6, i + 3)
    c = content[i:i + 1]
    buf.append(c)
    if c == "'":
        return (3, i + 1)
    return (4, i + 1)

def _gradle_lex_code(content, i, buf, events):
    """Lex one code-state character; return the `(state, next_i)` pair."""
    two = content[i:i + 2]
    if two == "//" or two == "/*":
        return _gradle_lex_comment(content, i, buf, events)
    c = content[i:i + 1]
    if c == "'" or c == '"':
        return _gradle_lex_string_open(content, i, buf)
    if c == "\n" or c == ";" or c == "\r":
        _gradle_flush_to(events, buf, "stmt")
        return (0, i + 1)
    if c == "{":
        _gradle_flush_to(events, buf, "open")
        return (0, i + 1)
    if c == "}":
        _gradle_flush_to(events, buf, "stmt")
        events.append(struct(kind = "close", text = ""))
        return (0, i + 1)
    buf.append(c)
    return (0, i + 1)

def _gradle_lex_short_string(content, n, i, buf, events, quote):
    """Lex one character inside a single-line string; return `(state, next_i)`."""
    c = content[i:i + 1]
    buf.append(c)
    if c == "\\" and i + 1 < n:
        buf.append(content[i + 1:i + 2])
        return (3 if quote == "'" else 4, i + 2)
    if c == quote:
        return (0, i + 1)
    if c == "\n":
        # An unterminated single-line string ends at the newline: the
        # fragment flushes as a statement (unreadable downstream) instead
        # of swallowing the rest of the file into a string.
        _gradle_flush_to(events, buf, "stmt")
        return (0, i + 1)
    return (3 if quote == "'" else 4, i + 1)

def _gradle_lex_long_string(content, n, i, buf, quote3):
    """Lex one character inside a triple-quoted string; return `(state, next_i)`."""
    if content[i:i + 3] == quote3:
        buf.extend([quote3[0:1], quote3[0:1], quote3[0:1]])
        return (0, i + 3)
    c = content[i:i + 1]
    buf.append(c)
    if c == "\\" and i + 1 < n:
        buf.append(content[i + 1:i + 2])
        return (5 if quote3[0:1] == "'" else 6, i + 2)
    if quote3[0:1] == "'":
        return (5, i + 1)
    return (6, i + 1)

def _gradle_lex(content):
    """Split Gradle script text into statement and brace events.

    String-aware: `//` and `/* */` comments are dropped only outside
    string literals (single, double or triple quoted), and newlines, `;`,
    `{` and `}` split statements only outside strings. A backslash escapes
    the next character inside a string.

    Args:
        content: The Gradle build-file or applied-script text.

    Returns:
        A list of structs: `struct(kind = "stmt", text)` for statements,
        `struct(kind = "open", text)` for a block header (the text before
        `{`), and `struct(kind = "close", text = "")` for `}`.
    """
    events = []
    buf = []
    n = len(content)
    state = 0
    i = 0
    for _ in range(n + 2):
        if i >= n:
            break
        c = content[i:i + 1]
        two = content[i:i + 2]
        if state == 0:
            (state, i) = _gradle_lex_code(content, i, buf, events)
        elif state == 1:
            if c == "\n":
                _gradle_flush_to(events, buf, "stmt")
                state = 0
            i += 1
        elif state == 2:
            if two == "*/":
                state = 0
                i += 2
            else:
                i += 1
        elif state == 3:
            (state, i) = _gradle_lex_short_string(content, n, i, buf, events, "'")
        elif state == 4:
            (state, i) = _gradle_lex_short_string(content, n, i, buf, events, '"')
        elif state == 5:
            (state, i) = _gradle_lex_long_string(content, n, i, buf, "'''")
        else:
            (state, i) = _gradle_lex_long_string(content, n, i, buf, '"""')
    _gradle_flush_to(events, buf, "stmt")
    return events

def _gradle_leading_word(text):
    """Return the leading `[A-Za-z0-9_]` word of `text` ("" when none)."""
    out = []
    for i in range(len(text)):
        c = text[i:i + 1]
        if ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or ("0" <= c and c <= "9") or c == "_":
            out.append(c)
        else:
            break
    return "".join(out)

def _gradle_stmt_token(stmt):
    """Return the leading identifier of a statement, dots kept.

    `project.dependencies.add(...)` yields one dotted token so the `.`
    rule can tell a method path from a bare configuration name.
    """
    out = []
    for i in range(len(stmt)):
        c = stmt[i:i + 1]
        if ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or ("0" <= c and c <= "9") or c == "_" or c == "." or c == "$":
            out.append(c)
        else:
            break
    return "".join(out)

def _gradle_is_runtime_config(token):
    """True for configurations that land on the app's runtime classpath."""
    if token in _MAVEN_RUNTIME_CONFIGS:
        return True
    for suffix in _MAVEN_RUNTIME_SUFFIXES:
        if token.endswith(suffix):
            return True
    return False

def _gradle_is_nonruntime_config(token):
    """True for test-source-set and `compileOnly` configurations."""
    if token == "compileOnly" or token.endswith("CompileOnly"):
        return True
    if token.startswith("test"):
        return True
    if "Test" in token:
        return True
    return False

def _gradle_skip_ws(text, pos):
    """Return the first position at or after `pos` that is not blank."""
    n = len(text)
    for _ in range(n + 1):
        if pos >= n:
            break
        if text[pos:pos + 1] in " \t\r":
            pos += 1
        else:
            break
    return pos

def _gradle_quoted_at(text, pos):
    """Read the quoted literal at `pos`; return `(inner, end)` or `(None, pos)`.

    Only single- and double-quoted literals count; anything else (a
    variable, a catalog ref, string concatenation) is not a literal.
    """
    q = text[pos:pos + 1]
    if q != "'" and q != '"':
        return (None, pos)
    out = []
    n = len(text)
    i = pos + 1
    for _ in range(n + 1):
        if i >= n:
            return (None, pos)
        c = text[i:i + 1]
        if c == "\\" and i + 1 < n:
            out.append(c)
            out.append(text[i + 1:i + 2])
            i += 2
        elif c == q:
            return ("".join(out), i + 1)
        else:
            out.append(c)
            i += 1
    return (None, pos)

def _gradle_bad_add():
    """The shared "not a modellable `add()` call" parse result."""
    return struct(kind = "bad", config = "", notation = "", project = False)

def _gradle_parse_add_tail(stmt, pos, paren, config):
    """Parse the `(notation)` tail of an `add(config, ...)` statement."""
    pos = _gradle_skip_ws(stmt, pos)
    if stmt[pos:pos + 7] == "project" and stmt[pos + 7:pos + 8] == "(":
        end = _gradle_match_paren(stmt, pos + 7)
        if end < 0:
            return _gradle_bad_add()
        pos = _gradle_skip_ws(stmt, end + 1)
        if paren:
            if stmt[pos:pos + 1] != ")":
                return _gradle_bad_add()
            pos = _gradle_skip_ws(stmt, pos + 1)
        if pos != len(stmt):
            return _gradle_bad_add()
        return struct(kind = "project", config = config, notation = "", project = True)
    (notation, end) = _gradle_quoted_at(stmt, pos)
    if notation == None:
        return _gradle_bad_add()
    pos = _gradle_skip_ws(stmt, end)
    if paren:
        if stmt[pos:pos + 1] != ")":
            return _gradle_bad_add()
        pos = _gradle_skip_ws(stmt, pos + 1)
    if pos != len(stmt):
        return _gradle_bad_add()
    return struct(kind = "dep", config = config, notation = notation, project = False)

def _parse_gradle_add(stmt):
    """Parse a bare `add(config, notation)` dependency statement.

    Covers `add('implementation', 'g:a:1')` and the double-quoted
    spelling, with or without parentheses. A `project(...)` notation
    parses as a project reference.

    Args:
        stmt: The statement text; its leading word must be `add`.

    Returns:
        A struct: `kind` is `"dep"` (with `config` and `notation`),
        `"project"` (with `config`), or `"bad"` for anything else.
    """
    pos = _gradle_skip_ws(stmt, 3)
    paren = False
    if stmt[pos:pos + 1] == "(":
        paren = True
        pos = _gradle_skip_ws(stmt, pos + 1)
    (config, end) = _gradle_quoted_at(stmt, pos)
    if config == None:
        return _gradle_bad_add()
    pos = _gradle_skip_ws(stmt, end)
    if stmt[pos:pos + 1] != ",":
        return _gradle_bad_add()
    return _gradle_parse_add_tail(stmt, pos + 1, paren, config)

def _gradle_match_paren(text, open_pos):
    """Return the index of the `)` matching the `(` at `open_pos`, or -1."""
    depth = 0
    n = len(text)
    i = open_pos
    for _ in range(n + 1):
        if i >= n:
            return -1
        c = text[i:i + 1]
        if c == "(":
            depth += 1
            i += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
            i += 1
        elif c == "'" or c == '"':
            (_, end) = _gradle_quoted_at(text, i)
            if end <= i:
                return -1
            i = end
        else:
            i += 1
    return -1

def _gradle_apply_result(kind, path):
    """Build the shared `apply`-parse result struct."""
    return struct(kind = kind, path = path)

def _gradle_skip_arg_value(stmt, j):
    """Skip one Kotlin arg value at `j` (a literal or a word); return new pos."""
    c2 = stmt[j:j + 1]
    if c2 == "'" or c2 == '"':
        (_, end) = _gradle_quoted_at(stmt, j)
        return end if end > j else (j + 1)
    w2 = _gradle_leading_word(stmt[j:])
    return j + len(w2) if w2 else (j + 1)

def _parse_gradle_apply_kwargs(stmt, pos):
    """Parse Kotlin `apply(...)` args; return the `from` path struct."""
    n = len(stmt)
    j = pos
    for _ in range(n + 1):
        j = _gradle_skip_ws(stmt, j)
        if j >= n:
            break
        c = stmt[j:j + 1]
        if c == ")":
            break
        if c == ",":
            j += 1
        elif c == "'" or c == '"':
            # A positional string (a plugin id): not an applied script.
            j = _gradle_skip_arg_value(stmt, j)
        else:
            w = _gradle_leading_word(stmt[j:])
            if not w:
                j += 1
            elif w == "from":
                j2 = _gradle_skip_ws(stmt, j + 4)
                if stmt[j2:j2 + 1] != "=":
                    return _gradle_apply_result("bad", "")
                j3 = _gradle_skip_ws(stmt, j2 + 1)
                (path, _) = _gradle_quoted_at(stmt, j3)
                if path == None:
                    return _gradle_apply_result("bad", "")
                return _gradle_apply_result("path", path)
            else:
                j = _gradle_skip_ws(stmt, j + len(w))
                if stmt[j:j + 1] == "=":
                    j = _gradle_skip_arg_value(stmt, _gradle_skip_ws(stmt, j + 1))
    return _gradle_apply_result("none", "")

def _parse_gradle_apply(stmt):
    """Parse an `apply from:` statement; return a kind/path struct.

    `kind` is `"path"` (with the literal script path) for the Groovy
    `apply from: 'x.gradle'` and Kotlin `apply(from = "x.gradle.kts")`
    spellings, `"bad"` for an `apply` whose `from` is missing or not a
    plain quoted literal, and `"none"` for anything else (`apply plugin:`
    and non-`apply` statements).

    Args:
        stmt: The stripped statement text.

    Returns:
        `struct(kind, path)`.
    """
    if _gradle_leading_word(stmt) != "apply":
        return _gradle_apply_result("none", "")
    pos = _gradle_skip_ws(stmt, 5)
    if stmt[pos:pos + 1] == "(":
        return _parse_gradle_apply_kwargs(stmt, pos + 1)
    if _gradle_leading_word(stmt[pos:]) != "from":
        return _gradle_apply_result("none", "")
    j = _gradle_skip_ws(stmt, pos + 4)
    if stmt[j:j + 1] != ":":
        return _gradle_apply_result("bad", "")
    j = _gradle_skip_ws(stmt, j + 1)
    (path, end) = _gradle_quoted_at(stmt, j)
    if path == None:
        return _gradle_apply_result("bad", "")
    j = _gradle_skip_ws(stmt, end)
    if j < len(stmt) and stmt[j:j + 1] != ",":
        # String concatenation or another expression: not a literal path.
        return _gradle_apply_result("bad", "")
    return _gradle_apply_result("path", path)

def _gradle_normalize_apply_path(path):
    """Resolve an applied-script path inside the package; "" when refused.

    Dots collapse, `..` pops, and popping past the package root, a URL
    scheme, an absolute path, an empty path or `$` interpolation refuses
    the path (""), so the caller reports the statement unreadable.

    Args:
        path: The literal path from the `apply from:` statement.

    Returns:
        The package-relative path, or "" when it escapes or is not plain.
    """
    if not path or "$" in path:
        return ""
    for i in range(len(path)):
        c = path[i:i + 1]
        if c == "/":
            break
        if c == ":":
            return ""
    if path.startswith("/"):
        return ""
    out = []
    for seg in path.split("/"):
        if seg == "" or seg == ".":
            continue
        if seg == "..":
            if not out:
                return ""
            out.pop()
        else:
            out.append(seg)
    if not out:
        return ""
    return "/".join(out)

def _gradle_code_without_strings(text):
    """Return `text` with every quoted literal blanked to `""`.

    Lets the `dependencies`-mention check see references (`project.dependencies.add`) while a prose string that merely names dependencies stays invisible.
    """
    out = []
    n = len(text)
    i = 0
    for _ in range(n + 1):
        if i >= n:
            break
        c = text[i:i + 1]
        if c == "'" or c == '"':
            (_, end) = _gradle_quoted_at(text, i)
            if end <= i:
                out.append(c)
                i += 1
            else:
                i = end
        else:
            out.append(c)
            i += 1
    return "".join(out)

def _maven_visit_add_stmt(text, merged, ignored, labels, unknown, unreadable):
    """File one bare `add(config, notation)` statement."""
    parsed = _parse_gradle_add(text)
    if parsed.kind == "bad":
        unreadable[text] = True
        return
    if parsed.kind == "project":
        if _gradle_is_nonruntime_config(parsed.config) or _gradle_is_runtime_config(parsed.config):
            return
        unreadable[text] = True
        return
    if _gradle_is_nonruntime_config(parsed.config):
        return
    if _gradle_is_runtime_config(parsed.config):
        coord = _gradle_coord_from_inner(parsed.notation)
        if coord:
            _maven_add_coord(coord, merged, ignored, labels, unknown)
        else:
            unreadable[text] = True
        return
    unreadable[text] = True

def _maven_visit_dep_stmt(text, merged, ignored, labels, unknown, unreadable):
    """File one statement inside a non-`buildscript` `dependencies` block."""
    token = _gradle_stmt_token(text)
    if token == "add":
        _maven_visit_add_stmt(text, merged, ignored, labels, unknown, unreadable)
        return
    if not token or "." in token:
        unreadable[text] = True
        return
    if _gradle_is_nonruntime_config(token):
        return
    if _gradle_is_runtime_config(token):
        rest = text[len(token):].strip()
        coord = _gradle_coord_of(rest)
        if coord:
            _maven_add_coord(coord, merged, ignored, labels, unknown)
        elif "project(" in rest:
            pass
        else:
            unreadable[text] = True
        return
    if "project(" in text:
        return
    unreadable[text] = True

def _maven_resolve_apply(path, stmt_text, unreadable, read_script, seen, depth, pending):
    """Resolve one `apply from:` path: validate, read, queue for parsing."""
    norm = _gradle_normalize_apply_path(path)
    if not norm or norm in seen:
        unreadable[stmt_text] = True
        return
    if depth >= _GRADLE_APPLY_MAX_DEPTH or read_script == None:
        unreadable[stmt_text] = True
        return
    sub_seen = dict(seen)
    sub_seen[norm] = True
    sub = read_script(norm)
    if sub == None:
        unreadable[stmt_text] = True
    else:
        pending.append((sub, sub_seen, depth + 1))

def _maven_visit_gradle_stmt(text, stack, merged, ignored, labels, unknown, unreadable, read_script, seen, depth, pending):
    """File one statement with its block context."""
    tainted = False
    in_buildscript = False
    for name in stack:
        if name == "!":
            tainted = True
        if name == "buildscript":
            in_buildscript = True
    if tainted:
        # Inside a nested block already reported unreadable (for example
        # `constraints {}` in a `dependencies` block): everything it holds
        # is unmodellable too, so nothing in here resolves.
        unreadable[text] = True
        return
    if in_buildscript:
        return
    applied = _parse_gradle_apply(text)
    if applied.kind == "path":
        _maven_resolve_apply(applied.path, text, unreadable, read_script, seen, depth, pending)
        return
    if applied.kind == "bad":
        unreadable[text] = True
        return
    if stack and stack[len(stack) - 1] == "dependencies":
        _maven_visit_dep_stmt(text, merged, ignored, labels, unknown, unreadable)
        return
    if "dependencies" in _gradle_code_without_strings(text).lower():
        unreadable[text] = True

def _maven_visit_open(header, stack, unreadable):
    """Push one block header, reporting nested and stray `dependencies`."""
    in_deps = False
    in_buildscript = False
    for name in stack:
        if name == "dependencies":
            in_deps = True
        if name == "buildscript":
            in_buildscript = True
    if in_deps and not in_buildscript:
        # A block nested in a `dependencies` block (for example
        # `constraints {}`) is unmodellable: report the header and taint
        # the interior (pushed as "!") so nothing in it resolves either.
        unreadable[header if header else "{"] = True
        stack.append("!")
    else:
        if header and header != "dependencies" and "dependencies" in _gradle_code_without_strings(header).lower():
            unreadable[header] = True
        stack.append(_gradle_leading_word(header))

def _maven_walk_gradle(content, merged, ignored, labels, unknown, unreadable, read_script, seen, depth, pending):
    """Walk one Gradle script's lexed events, filing deps and refusals."""
    stack = []
    for e in _gradle_lex(content):
        if e.kind == "open":
            _maven_visit_open(e.text, stack, unreadable)
        elif e.kind == "close":
            if stack:
                stack.pop()
        else:
            _maven_visit_gradle_stmt(e.text, stack, merged, ignored, labels, unknown, unreadable, read_script, seen, depth, pending)

def maven_labels_for_gradle(content, mapping, ignore, read_script = None):
    """Translate a Gradle build file's runtime deps to Bazel labels.

    Pure and loadable from another .bzl: `content` is the `build.gradle` /
    `build.gradle.kts` text, `mapping` is a caller-supplied
    `{group:artifact: label}` dict layered over the built-in
    `_MAVEN_COORD_TO_LABEL` (`mapping` wins on collision), and `ignore` is a
    list of `group:artifact` coordinates that need no label.

    The script is lexed string-aware (`//` and `/* */` comments strip only
    outside single-, double- and triple-quoted literals) and split into
    statements on newlines, `;`, `{` and `}` outside strings, so layout is
    insignificant: a single-line `dependencies { implementation 'g:a:1' }`,
    two declarations on one line separated by `;`, and Gradle's public
    `add('implementation', 'g:a:1')` (single- or double-quoted) resolve
    exactly like one declaration per line. Only statements inside a
    `dependencies` block that is not inside `buildscript` count
    (`buildscript` dependencies are build classpath, never packaged).

    Covers the configurations that put code on the app's runtime classpath —
    `implementation`, `api`, `runtimeOnly` and legacy `compile` — in both
    Groovy (bare, single-quoted) and Kotlin DSL (parenthesised,
    double-quoted) spellings, including variant-prefixed siblings
    (`debugImplementation`, ...). `compileOnly` is provided-scope (Gradle
    never packages it; the plugin's compile classpath already carries the
    equivalent in the neverlink engine target) and test-source-set
    configurations (`testImplementation`, `androidTest...`, ...) exercise
    the plugin's own unit tests, never the APK — both are left out of every
    list rather than reported. `project()` references name a sibling Gradle
    module, not an external artifact, and are left out the same way.

    `apply from:` scripts in both DSL spellings (`apply from: 'x.gradle'`
    and `apply(from = "x.gradle.kts")`) resolve when the path stays inside
    the package: the script is read through `read_script` and parsed the
    same way, recursively, with cycle detection and a depth cap of 10.

    Refusals (each reported in `unreadable`, failing the spoke fetch):
    statements in a `dependencies` block that are neither recognised
    runtime nor non-runtime declarations nor `project()` references
    (version-catalog `libs.*` refs, variables, local `files(...)` jars,
    Gradle maps, interpolated coordinates, multi-line calls, nested blocks
    such as `constraints {}`); `dependencies` mentions outside the block
    form (`project.dependencies.add(...)`, `dependencies.implementation
    ...`); `apply from:` with a URL, an absolute path, a path escaping the
    package, a missing file, or a non-literal argument (or when no
    `read_script` is given).

    Args:
        content: The Gradle build-file text.
        mapping: Dict from `group:artifact` to Bazel label string.
        ignore: List of `group:artifact` coordinates that need no label.
        read_script: Optional callback taking a package-relative applied
            script path and returning its text, or None when the file is
            missing. The repository rule passes a reader confined to the
            package; without one, applied scripts are unreadable.

    Returns:
        `struct(labels, unknown, unreadable)`: `labels` is the sorted,
        distinct Bazel labels for recognised coordinates; `unknown` is the
        sorted coordinates found in neither table and not in `ignore` (nor
        already provided, e.g. `kotlin-stdlib`); `unreadable` is the sorted
        dependency declarations no coordinate could be reduced from.
    """
    merged = dict(_MAVEN_COORD_TO_LABEL)
    if mapping:
        merged.update(mapping)
    ignored = {}
    for coord in (ignore or []):
        ignored[coord] = True
    labels = {}
    unknown = {}
    unreadable = {}

    # Starlark forbids recursion, so applied scripts queue here: each entry
    # carries its own cycle chain (`seen`) and nesting depth. The queue is
    # bounded; exhausting it fails closed rather than hanging.
    pending = [(content, {}, 0)]
    for _ in range(512):
        if not pending:
            break
        (sub, seen, depth) = pending.pop()
        _maven_walk_gradle(sub, merged, ignored, labels, unknown, unreadable, read_script, seen, depth, pending)
    if pending:
        unreadable["applied Gradle scripts exceed the parse budget"] = True
    return struct(
        labels = sorted(labels.keys()),
        unknown = sorted(unknown.keys()),
        unreadable = sorted(unreadable.keys()),
    )

def _resolve_plugin_maven_deps(ctx):
    """Translate the spoke's `android/build.gradle*` deps to Bazel labels.

    Reads the package's Gradle build file (Groovy `.gradle` or Kotlin
    `.gradle.kts`) and reduces its runtime dependencies to Maven coordinates
    with `maven_labels_for_gradle` — layering the user's
    `flutter.pub(android_maven_deps)` over the built-in table and honouring
    `flutter.pub(android_maven_ignore)` — then maps them to
    `@rules_android_maven//:...` labels.

    Fail-closed: coordinates found in neither table, and declarations no
    coordinate can be reduced from, fail the fetch with a message naming the
    package, the build file, every offending entry, and both attributes with
    an example. A plugin whose native dependency is missing can otherwise
    still compile — a reflection-only or run-time-only dep — and then crash
    on the device, so dropping them silently is not an option.

    Returns a sorted list of distinct labels.
    """
    candidates = (
        "android/build.gradle.kts",
        "android/build.gradle",
    )
    build_file = ""
    content = ""
    for cand in candidates:
        p = ctx.path(cand)
        if p.exists:
            build_file = cand
            content = ctx.read(p)
            break
    if not content:
        return []

    # The workspace owner's label mapping is trusted like hand-written
    # BUILD text, but a broken-out value would still poison the generated
    # deps list; refuse it here (naming the package and the key) the way
    # the extension refuses it at eval time.
    for _coord_key in ctx.attr.android_maven_deps.keys():
        _label_value = ctx.attr.android_maven_deps[_coord_key]
        if not is_maven_dep_label(_label_value):
            fail((
                "flutter.pub spoke for \"{pkg}\": android_maven_deps[{key}] " +
                "is not a valid Bazel label ({label}). Map the coordinate " +
                "to a label in another repository (\"@...\" ) or an absolute " +
                "label (\"//...\") with no quotes, backslashes or newlines."
            ).format(
                pkg = ctx.attr.package_name,
                key = _coord_key,
                label = _label_value,
            ))

    def _read_package_script(path):
        gradle_file = ctx.path("android/" + path)
        if not gradle_file.exists:
            return None
        return ctx.read(gradle_file)

    result = maven_labels_for_gradle(
        content,
        ctx.attr.android_maven_deps,
        ctx.attr.android_maven_ignore,
        _read_package_script,
    )
    if result.unknown or result.unreadable:
        details = []
        if result.unknown:
            details.append("unknown Maven coordinates: " + ", ".join(result.unknown))
        if result.unreadable:
            details.append("unreadable dependency declarations: " + ", ".join(result.unreadable))
        fail(
            ('flutter.pub spoke for "{pkg}": {gradle} declares Android ' +
             "dependencies rules_flutter cannot translate to Bazel labels " +
             "({details}). Map each external artifact in MODULE.bazel, e.g. " +
             'flutter.pub(android_maven_deps = {{"com.example:thing": ' +
             '"@rules_android_maven//:com_example_thing_thing"}}), or silence ' +
             "a coordinate that needs no label with " +
             'flutter.pub(android_maven_ignore = ["com.example:thing"]). ' +
             "Declarations that are not Maven coordinates (version-catalog " +
             "`libs.*` refs, variables, local jars) need a plugin overlay " +
             "instead - see flutter.plugin_overlays.").format(
                pkg = ctx.attr.package_name,
                gradle = build_file,
                details = "; ".join(details),
            ),
        )
    return result.labels

def _glob_block(srcs_dirs, extensions):
    """Format a `glob([...])` expression covering the given extensions.

    Each directory in `srcs_dirs` is recursively swept for files matching
    any extension in `extensions`. `test/` and `example/` subtrees are
    excluded — pub plugins routinely ship integration tests next to
    their plugin source, but those should never be linked into the
    runner.
    """
    patterns = []
    excludes = []
    for d in srcs_dirs:
        for ext in extensions:
            patterns.append("{}/**/*.{}".format(d, ext))
        excludes.append("{}/test/**".format(d))
        excludes.append("{}/example/**".format(d))
    quoted = ['        "%s",' % p for p in patterns]
    excl_quoted = ['        "%s",' % e for e in excludes]
    return "glob(\n        [\n{}\n        ],\n        exclude = [\n{}\n        ],\n        allow_empty = True,\n    )".format("\n".join(quoted), "\n".join(excl_quoted))

def _split_glob_block(srcs_dirs, src_exts, hdr_exts):
    """Format separate srcs/hdrs glob expressions for desktop plugins.

    Returns (srcs_glob, hdrs_glob) so the spoke can pass the lists to
    flutter_linux_plugin_library / flutter_windows_plugin_library
    separately — those rules require .h/.hh/.hpp on `hdrs` and the
    compilable extensions on `srcs`.
    """
    return _glob_block(srcs_dirs, src_exts), _glob_block(srcs_dirs, hdr_exts)

_DESKTOP_HDR_EXTS = ("h", "hh", "hpp")
_DESKTOP_C_EXTS = ("cc", "cpp", "c")

def _readdir_files_recursive(ctx, rel_dir):
    """Recursively walk `<package>/<rel_dir>` and return file paths.

    Returns a list of package-relative paths (e.g. `data/locales.json`).
    Used to expand directory entries from `flutter.assets:` (which Flutter
    treats as "include every file under this directory").
    """
    out = []
    base = ctx.path(rel_dir)
    if not base.exists:
        return out
    queue = [base]
    for _ in range(10000):  # bounded loop to satisfy Starlark's no-while constraint
        if not queue:
            break
        cur = queue.pop()
        for child in cur.readdir():
            if child.is_dir:
                queue.append(child)
            else:
                # Reconstruct package-relative path. ctx.path() basis is the
                # repository root, so child.basename + walking up gets us
                # what we want — but readdir paths already include the
                # trailing component. Use child path's segments past the
                # spoke root.
                rel = str(child)

                # Trim the spoke-root prefix; what's left is the relative
                # path we want.
                pkg_root = str(ctx.path("."))
                if rel.startswith(pkg_root + "/"):
                    out.append(rel[len(pkg_root) + 1:])
                else:
                    out.append(rel)
    return out

def _encode_fonts_json(parsed_fonts):
    """Convert parse_flutter_assets_block().fonts to the JSON shape flutter_library expects."""
    fonts_for_json = []
    for entry in parsed_fonts:
        fonts_list = []
        for font in entry.fonts:
            d = {"asset": font.asset}
            if font.weight != None:
                d["weight"] = font.weight
            if font.style != None:
                d["style"] = font.style
            fonts_list.append(d)
        fonts_for_json.append({"family": entry.family, "fonts": fonts_list})
    return json.encode(fonts_for_json) if fonts_for_json else ""

def _build_font_files_dict(parsed_fonts):
    """Build the `font_files` label_keyed_string_dict literal — {":path": "path", ...}."""
    out = {}
    for entry in parsed_fonts:
        for font in entry.fonts:
            out[":" + font.asset] = font.asset
    return out

def _build_pkg_assets_dict(ctx, parsed_assets):
    """Build the `pkg_assets` dict, expanding directory entries.

    Flutter's `flutter.assets:` accepts paths and trailing-slash directory
    prefixes. Bazel needs an explicit label per file, so we walk each
    directory at repo-rule time and emit one entry per discovered file.
    """
    out = {}
    for entry in parsed_assets:
        path = entry.path
        if path.endswith("/"):
            for f in _readdir_files_recursive(ctx, path.rstrip("/")):
                out[":" + f] = f
        else:
            out[":" + path] = path
    return out

def _build_pkg_shaders_dict(parsed_shaders):
    """Build the `pkg_shaders` dict — same shape as pkg_assets, no directories."""
    out = {}
    for entry in parsed_shaders:
        out[":" + entry.path] = entry.path
    return out

def _format_label_dict_literal(d, indent = "        "):
    """Render `{":foo": "foo", ":bar": "bar"}` as a multi-line BUILD source dict."""
    if not d:
        return "{}"
    keys = sorted(d.keys())
    lines = ['{indent}"{k}": "{v}",'.format(indent = indent, k = k, v = d[k]) for k in keys]
    return "{\n" + "\n".join(lines) + "\n" + indent[:-4] + "}"

_SHADER_INCLUDES_GLOB = """    shader_includes = glob(
        ["**/*.glsl", "**/*.frag", "**/*.vert"],
        allow_empty = True,
    ),"""

def _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders):
    """Render the four pub-asset attrs as BUILD source, omitting empty ones."""
    parts = []
    if fonts_json_str:
        parts.append("    fonts_json = {},".format(repr(fonts_json_str)))
    if font_files:
        parts.append("    font_files = {},".format(_format_label_dict_literal(font_files)))
    if pkg_assets:
        parts.append("    pkg_assets = {},".format(_format_label_dict_literal(pkg_assets)))
    if pkg_shaders:
        parts.append("    pkg_shaders = {},".format(_format_label_dict_literal(pkg_shaders)))

        # What the shaders may `#include`: a package's GLSL anywhere in it,
        # since an include can reach `../`.
        parts.append(_SHADER_INCLUDES_GLOB)
    return ("\n".join(parts) + "\n") if parts else ""

def _format_code_asset_attrs(code_assets, has_unreplaced_hook):
    """Render the `code_assets` / `has_unreplaced_hook` attrs for a spoke.

    Shared by the `flutter_library` and `flutter_plugin` generators so the two
    emit an identical shape; the `dart_library` branch gets the equivalent from
    rules_dart's own `make_dart_library_build_content`.
    """
    block = ""
    if code_assets:
        lines = ['        "{}",'.format(a) for a in code_assets]
        block += "    code_assets = [\n{}\n    ],\n".format("\n".join(lines))
    if has_unreplaced_hook:
        block += '    has_unreplaced_hook = "{}",\n'.format(has_unreplaced_hook)
    return block

# The non-Dart remainder of `lib/`, emitted verbatim by both spoke
# generators below — the same partition rules_dart's
# `make_dart_library_build_content` uses, so `srcs + resources = lib/**`
# holds for every spoke whichever generator ran. A published package's
# `lib/` is addressable as `package:<name>/<path>` whatever the extension;
# a spoke that keeps only `*.dart` is a package with pieces missing.
# `resources` is orthogonal to the declared-asset attrs (`pkg_assets` /
# `pkg_shaders` / `font_files`): those name what is transformed and bundled
# into flutter_assets, while `resources` names membership in the staged
# package tree. A shader under `lib/` is legitimately both.
_RESOURCES_GLOB_BLOCK = """    resources = glob(
        ["lib/**"],
        exclude = ["lib/**/*.dart"],
        allow_empty = True,
    ),
"""

def _format_version_attr(version):
    """The `version` attr line for a spoke, or nothing when it is unknown.

    Omitted rather than written empty, matching
    `make_dart_library_build_content`. The attribute's only use is agreement
    checking between two records for one package name, and an unstated version
    never conflicts — so a spoke with nothing to say says nothing.

    Args:
        version: The resolved package version, or "".

    Returns:
        A BUILD attribute line, or "".
    """
    return '    version = "{}",\n'.format(version) if version else ""

def make_flutter_library_build_content(
        name,
        deps,
        language_version,
        code_assets,
        has_unreplaced_hook,
        fonts_json_str,
        font_files,
        pkg_assets,
        pkg_shaders,
        version = ""):
    """Generate BUILD content for a non-plugin Flutter spoke shipping fonts/assets/shaders.

    Counterpart to `make_dart_library_build_content` — used when the spoke
    declares anything under `flutter:` other than `plugin:` (e.g.
    cupertino_icons declaring `flutter.fonts`). The same shape a user
    would write by hand: `flutter_library` with the new pub-asset attrs,
    plus the non-Dart `lib/` remainder as `resources`.

    Args:
        name: Target name (also the `package_name`).
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.4"`).
        code_assets: `dart_code_asset` label strings replacing this
            package's build hook output.
        has_unreplaced_hook: Path of a build hook nothing replaces, or "".
        fonts_json_str: JSON-encoded `flutter.fonts` declarations, or "".
        font_files: Dict of font file label -> package-relative path.
        pkg_assets: Dict of asset file label -> package-relative path.
        pkg_shaders: Dict of shader file label -> package-relative path.
        version: The resolved package version this spoke was fetched at, or
            empty. Emitted only when known, matching
            `make_dart_library_build_content`: its sole use is agreement
            checking when one package name arrives from two hubs, and an
            unstated version never conflicts with a stated one.

    Returns:
        BUILD.bazel content as a string.
    """
    deps_block = ""
    if deps:
        dep_lines = ['        "{}",'.format(dep) for dep in deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    pub_attrs = _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_library")

flutter_library(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}{deps}    package_name = "{name}",
    language_version = "{language_version}",
{version}{asset_attrs}{pub_attrs}    visibility = ["//visibility:public"],
)
""".format(
        name = name,
        resources = _RESOURCES_GLOB_BLOCK,
        deps = deps_block,
        language_version = language_version,
        version = _format_version_attr(version),
        asset_attrs = _format_code_asset_attrs(code_assets, has_unreplaced_hook),
        pub_attrs = pub_attrs,
    )

def make_flutter_plugin_build_content(
        name,
        deps,
        language_version,
        code_assets,
        has_unreplaced_hook,
        plugin_platforms_json,
        apple_macos_srcs_dirs,
        apple_ios_srcs_dirs,
        apple_macos_include_dirs,
        apple_ios_include_dirs,
        apple_macos_privacy_manifests,
        apple_ios_privacy_manifests,
        linux_src_dir,
        windows_src_dir,
        fonts_json_str = "",
        font_files = {},
        pkg_assets = {},
        pkg_shaders = {},
        version = ""):
    """Generate BUILD content for a Flutter plugin spoke.

    Emits a `flutter_plugin` plus optional per-platform
    `flutter_apple_plugin_library` (Apple) /
    `flutter_linux_plugin_library` /
    `flutter_windows_plugin_library` sub-targets.

    Android Kotlin/Java sources are exposed via a sibling `android/`
    sub-package (see `make_android_subpackage_build_content`). The
    sub-package is loaded only when something queries
    `@<spoke>//android:lib` — non-Android workspaces don't pay the
    `@rules_android` / `@rules_kotlin` cost.

    Args:
        name: Target name (also the `package_name`).
        deps: Fully-qualified Bazel label strings for sibling spokes.
        language_version: Dart language version string (e.g. `"3.4"`).
        code_assets: `dart_code_asset` label strings replacing this
            package's build hook output.
        has_unreplaced_hook: Path of a build hook nothing replaces, or "".
        plugin_platforms_json: JSON-encoded `flutter.plugin.platforms` dict.
        apple_macos_srcs_dirs: Detected macOS Apple source dirs.
        apple_ios_srcs_dirs: Detected iOS Apple source dirs.
        apple_macos_include_dirs: SwiftPM-style public-header dirs (macOS).
        apple_ios_include_dirs: SwiftPM-style public-header dirs (iOS).
        apple_macos_privacy_manifests: `PrivacyInfo.xcprivacy` paths (macOS).
        apple_ios_privacy_manifests: `PrivacyInfo.xcprivacy` paths (iOS).
        linux_src_dir: Linux C/C++ source dir, or "".
        windows_src_dir: Windows C/C++ source dir, or "".
        fonts_json_str: JSON-encoded `flutter.fonts` declarations, or "".
        font_files: Dict of font file label -> package-relative path.
        pkg_assets: Dict of asset file label -> package-relative path.
        pkg_shaders: Dict of shader file label -> package-relative path.
        version: The resolved package version this spoke was fetched at, or
            empty. Emitted only when known, matching
            `make_dart_library_build_content`: its sole use is agreement
            checking when one package name arrives from two hubs, and an
            unstated version never conflicts with a stated one.

    Returns:
        BUILD.bazel content as a string.
    """
    deps_block = ""
    if deps:
        dep_lines = ['        "{}",'.format(dep) for dep in deps]
        deps_block = "    deps = [\n{}\n    ],\n".format("\n".join(dep_lines))

    extra_loads = []
    extra_targets = []
    apple_libs_arg = ""
    linux_libs_arg = ""
    windows_libs_arg = ""

    if apple_macos_srcs_dirs or apple_ios_srcs_dirs:
        extra_loads.append('load("@rules_flutter//flutter:macos.bzl", "flutter_apple_plugin_library")')
    if linux_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:linux.bzl", "flutter_linux_plugin_library")')
    if windows_src_dir:
        extra_loads.append('load("@rules_flutter//flutter:windows.bzl", "flutter_windows_plugin_library")')

    # NOTE: Android Kotlin/Java sources are NOT compiled in the top-level
    # spoke BUILD. Instead, they're exposed via a sibling `android/`
    # sub-package (see make_android_subpackage_build_content) which loads
    # @rules_android + @rules_kotlin lazily — only when something queries
    # `@<spoke>//android:lib`. Mac-only / web-only workspaces never trigger
    # the parse and don't pay the @rules_android / @rules_kotlin cost.
    # The application-side `flutter_android_app` macro depends on the hub's
    # `android/all_android_plugin_libs` aggregator, which deps on every
    # spoke's `android:lib` — so Android-targeted builds pick up all
    # plugin libraries automatically.

    if apple_macos_srcs_dirs:
        extra_targets.append("""
flutter_apple_plugin_library(
    name = "{name}_apple_macos",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "macos",
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "{name}_apple_macos_xtool",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "macos",
    backend = "xtool",
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = _glob_block(apple_macos_srcs_dirs, _APPLE_SRC_EXTENSIONS),
            includes = repr(apple_macos_include_dirs),
        ))

    if apple_ios_srcs_dirs:
        extra_targets.append("""
flutter_apple_plugin_library(
    name = "{name}_apple_ios",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "ios",
    visibility = ["//visibility:public"],
)

flutter_apple_plugin_library(
    name = "{name}_apple_ios_xtool",
    srcs = {srcs},
    includes = {includes},
    module_name = "{name}",
    platform = "ios",
    backend = "xtool",
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = _glob_block(apple_ios_srcs_dirs, _APPLE_SRC_EXTENSIONS),
            includes = repr(apple_ios_include_dirs),
        ))

    if linux_src_dir:
        linux_srcs, linux_hdrs = _split_glob_block([linux_src_dir], _DESKTOP_C_EXTS, _DESKTOP_HDR_EXTS)
        extra_targets.append("""
flutter_linux_plugin_library(
    name = "{name}_linux",
    srcs = {srcs},
    hdrs = {hdrs},
    includes = ["linux/include"],
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = linux_srcs,
            hdrs = linux_hdrs,
        ))

    if windows_src_dir:
        win_srcs, win_hdrs = _split_glob_block([windows_src_dir], _DESKTOP_C_EXTS, _DESKTOP_HDR_EXTS)
        extra_targets.append("""
flutter_windows_plugin_library(
    name = "{name}_windows",
    srcs = {srcs},
    hdrs = {hdrs},
    includes = ["windows/include"],
    visibility = ["//visibility:public"],
)""".format(
            name = name,
            srcs = win_srcs,
            hdrs = win_hdrs,
        ))

    # NB: Android sources are no longer surfaced via a top-level filegroup.
    # See `make_android_subpackage_build_content` — the spoke's `android/`
    # sub-package wraps them in a kt_android_library that the hub's
    # aggregator (`@<hub>//android:all_android_plugin_libs`) depends on.

    if apple_macos_srcs_dirs or apple_ios_srcs_dirs:
        macos_branch = '            ":{name}_apple_macos",'.format(name = name) if apple_macos_srcs_dirs else ""
        macos_xtool_branch = '            ":{name}_apple_macos_xtool",'.format(name = name) if apple_macos_srcs_dirs else ""
        ios_branch = '            ":{name}_apple_ios",'.format(name = name) if apple_ios_srcs_dirs else ""
        ios_xtool_branch = '            ":{name}_apple_ios_xtool",'.format(name = name) if apple_ios_srcs_dirs else ""
        apple_libs_arg = """    apple_libs = select({{
        "@rules_flutter//flutter/settings:macos_xtool_backend": [
{macos_xtool_branch}
        ],
        "@platforms//os:macos": [
{macos_branch}
        ],
        "@rules_flutter//flutter/settings:ios_xtool_backend": [
{ios_xtool_branch}
        ],
        "@platforms//os:ios": [
{ios_branch}
        ],
        "//conditions:default": [],
    }}),
""".format(
            macos_branch = macos_branch,
            macos_xtool_branch = macos_xtool_branch,
            ios_branch = ios_branch,
            ios_xtool_branch = ios_xtool_branch,
        )

    if linux_src_dir:
        linux_libs_arg = '    linux_libs = [":{name}_linux"],\n'.format(name = name)

    if windows_src_dir:
        windows_libs_arg = '    windows_libs = [":{name}_windows"],\n'.format(name = name)

    # Android sources travel through a sibling `android/` sub-package, which
    # the hub's `all_android_plugin_libs` deps on and the application macro
    # adds to `binary_deps`. See `make_android_subpackage_build_content`.
    # Nothing rides a provider: the wiring happens at macro-load time, where
    # providers cannot be read.

    # Apple PrivacyInfo.xcprivacy files: thread through `apple_privacy_files`
    # on the flutter_plugin so they propagate via FlutterInfo to the platform
    # application rule, which bundles them via Resources/. Split per-platform
    # via select() so the macOS bundle never picks up iOS-only manifests
    # (and vice versa) — different platforms can declare different privacy
    # uses, and Apple's submission validator aggregates whatever it finds in
    # the per-platform bundle.
    apple_privacy_files_arg = ""
    if apple_macos_privacy_manifests or apple_ios_privacy_manifests:
        macos_lines = "\n".join(['            "{}",'.format(p) for p in apple_macos_privacy_manifests])
        ios_lines = "\n".join(['            "{}",'.format(p) for p in apple_ios_privacy_manifests])
        apple_privacy_files_arg = """    apple_privacy_files = select({{
        "@platforms//os:macos": [
{macos_lines}
        ],
        "@platforms//os:ios": [
{ios_lines}
        ],
        "//conditions:default": [],
    }}),
""".format(
            macos_lines = macos_lines,
            ios_lines = ios_lines,
        )

    pub_attrs = _format_pub_asset_attrs(fonts_json_str, font_files, pkg_assets, pkg_shaders)

    return """\
load("@rules_flutter//flutter:defs.bzl", "flutter_plugin")
{extra_loads}
flutter_plugin(
    name = "{name}",
    srcs = glob(["lib/**/*.dart"], allow_empty = True),
{resources}{deps}    package_name = "{name}",
    plugin_platforms_json = {plugin_platforms_json_literal},
    language_version = "{language_version}",
{version}{apple_libs_arg}{linux_libs_arg}{windows_libs_arg}{apple_privacy_files_arg}{asset_attrs}{pub_attrs}    visibility = ["//visibility:public"],
)
{extra_targets}
""".format(
        name = name,
        version = _format_version_attr(version),
        asset_attrs = _format_code_asset_attrs(code_assets, has_unreplaced_hook),
        resources = _RESOURCES_GLOB_BLOCK,
        deps = deps_block,
        language_version = language_version,
        plugin_platforms_json_literal = repr(plugin_platforms_json),
        extra_loads = "\n".join(extra_loads),
        extra_targets = "\n".join(extra_targets),
        apple_libs_arg = apple_libs_arg,
        linux_libs_arg = linux_libs_arg,
        windows_libs_arg = windows_libs_arg,
        apple_privacy_files_arg = apple_privacy_files_arg,
        pub_attrs = pub_attrs,
    )

def _android_manifest_build_args(android_manifest, java_package, has_resources):
    """Return the `(manifest_arg, synthesized_manifest)` BUILD fragments.

    `manifest = "..."` lets `android_binary`'s `ManifestMerger2` pick up
    the plugin's entries transitively; `exports_manifest = 1` opts into
    the merger (rules_android defaults to no, AGP to yes). rules_android
    requires *some* manifest whenever `resource_files` is set, so a
    res-bearing plugin with no manifest gets a synthesized namespaced
    empty one, the way AGP treats a missing library manifest.
    """
    if android_manifest:
        sub_manifest = android_manifest
        if sub_manifest.startswith("android/"):
            sub_manifest = sub_manifest[len("android/"):]
        return ("    manifest = %s,\n    exports_manifest = 1,\n" % repr(sub_manifest), "")
    if not has_resources:
        return ("", "")
    manifest_lines = [
        "<manifest xmlns:android=\"http://schemas.android.com/apk/res/android\"",
        "    package=\"" + java_package + "\">",
        "</manifest>",
        "",
    ]
    manifest_content = "\n".join(["        %s," % repr(line) for line in manifest_lines])
    synthesized = """
# Minimal manifest for resource processing. AGP treats a missing library
# manifest as an empty one; rules_android requires an explicit file when
# resource_files is set.
write_file(
    name = "_manifest",
    out = "_manifest/AndroidManifest.xml",
    content = [
{content}
    ],
    newline = "unix",
)
""".format(content = manifest_content)
    return ('    manifest = ":_manifest",\n', synthesized)

def _android_build_config_block(bc_package):
    """Return the `(out, content)` fragments of the BuildConfig stub.

    Gradle synthesizes BuildConfig per Android module (matching
    `android.namespace`); rules_android does not, so the spoke hand-emits
    a minimal one. `DEBUG = false` is the safe default — the engine ABI /
    mode is decided elsewhere.
    """
    bc_lines = [
        "package " + bc_package + ";",
        "public final class BuildConfig {",
        "  public static final boolean DEBUG = false;",
        "  public static final String LIBRARY_PACKAGE_NAME = \"" + bc_package + "\";",
        "  public static final String BUILD_TYPE = \"release\";",
        "}",
        "",
    ]
    return (
        repr("_build_config/" + bc_package.replace(".", "/") + "/BuildConfig.java"),
        "\n".join(["        %s," % repr(line) for line in bc_lines]),
    )

def _fail_on_invalid_android_namespace(package_name, java_package):
    """Fail the spoke fetch when the resolved namespace is not a package."""
    if java_package and not is_java_package_name(java_package):
        fail((
            "flutter.pub spoke for \"{pkg}\": the Android namespace " +
            "{ns} is not a valid Java package name (checked " +
            "android.namespace in build.gradle(.kts), the " +
            "AndroidManifest.xml package attribute, and " +
            "flutter.plugin.platforms.android.package in " +
            "pubspec.yaml). Refusing it rather than emitting it " +
            "into the generated android/BUILD.bazel."
        ).format(
            pkg = package_name,
            ns = repr(java_package),
        ))

def make_android_subpackage_build_content(
        android_src_dir,
        java_package,
        extra_maven_labels,
        android_manifest = "",
        consumer_proguard_specs = [],
        has_resources = False):
    """Generate `android/BUILD.bazel` content for a Flutter plugin spoke.

    Always emits a `kt_android_library(name = "lib", ...)`. The aggregator
    in the hub's `android/all_android_plugin_libs` depends on `:lib` for
    every spoke; spokes without Android sources still contribute an empty
    library (a no-op at link time).

    Loaded lazily — Bazel only parses this file when something queries
    `@<spoke>//android:lib`. Non-Android workspaces never trigger it and
    don't pay the `@rules_android` / `@rules_kotlin` cost.

    The `_engine` target gives the plugin's Kotlin/Java source access to
    the FlutterPlugin SPI on the compile classpath. It is `neverlink`, as
    Gradle gives a plugin the embedding with `compileOnly`: the app
    packages its own engine, of the ABI its
    `flutter_android_app(android_abi = ...)` names. The plugin's is the
    arm64 one whatever the app's ABI, since Java bytecode is
    ABI-independent, and packaged it would put an arm64 engine in an x64
    APK. The engine also exports the embedding's
    androidx dependencies (see `_ANDROIDX_EMBEDDING_DEPS` in
    `flutter/android.bzl`), so a plugin whose `build.gradle` declares no
    dependencies still compiles against `NotificationCompat` & co. —
    exactly the compile classpath Gradle gives it via the
    `io.flutter:flutter_embedding_*` POM.

    BuildConfig.java is generated from the plugin's `java_package`. Many
    Flutter plugins reference `BuildConfig.DEBUG`, which Gradle synthesizes
    automatically; rules_android does not. We emit a minimal stub so the
    plugin's source compiles. `DEBUG = false` is the safe default —
    Flutter's Bazel build is release-by-default; debug runtime semantics
    are governed by `flutter_android_engine`'s engine selection, not by
    `BuildConfig.DEBUG`.

    Args:
        android_src_dir: Source dir under the package root (e.g.
            `android/src/main`) when the spoke has Android sources, or
            empty when it doesn't.
        java_package: The plugin's Android namespace — resolved the way
            AGP resolves it (`android.namespace` in `build.gradle(.kts)`,
            else the manifest's `package` attribute), falling back to
            `flutter.plugin.platforms.android.package` from the spoke's
            pubspec.yaml. Used as `custom_package` on the
            `kt_android_library` so the generated `R` and `BuildConfig`
            classes land in the package the plugin's sources expect.
        extra_maven_labels: Additional `@rules_android_maven//:...`
            labels parsed from the plugin's `build.gradle*` and translated
            via `maven_labels_for_gradle` (the built-in table plus
            `flutter.pub(android_maven_deps)`).
        android_manifest: Path to the plugin's
            `android/src/main/AndroidManifest.xml` if it ships one, or
            empty. When set, the generated `kt_android_library` declares
            `manifest = ...` so `android_binary`'s manifest merger
            (`ManifestMerger2`) picks the plugin's `<activity>` /
            `<service>` / `<uses-permission>` / etc. entries up
            transitively — same shape AGP uses inside `flutter build apk`.
        consumer_proguard_specs: Paths (relative to the spoke's
            `android/` sub-package) to ProGuard / R8 keep-rule files
            the plugin declared via `consumerProguardFiles` in its
            `build.gradle`. Threaded through as `proguard_specs = [...]`
            on the generated `kt_android_library`; rules_android
            propagates them transitively to the consuming
            `android_binary`'s R8 invocation, mirroring AGP's
            `consumerProguardFiles` flow.
        has_resources: True when the plugin ships resources at
            `android/src/main/res/`. Compiled via `resource_files` so the
            plugin's `R` class is generated against `java_package` and
            the resources merge into the consuming APK.

    Returns:
        Generated BUILD content as a string.

    Every string below renders with `repr()`, never `"..." % value`: the
    namespace, manifest paths and labels arrive from plugin files and user
    attributes, and a hostile value must at worst land inert inside a
    string literal, never break out of one. A non-empty `java_package`
    that is not a Java package name (see `is_java_package_name`) fails
    instead of rendering at all.
    """
    if java_package and not is_java_package_name(java_package):
        fail(
            "make_android_subpackage_build_content: java_package " +
            repr(java_package) + " is not a valid Java package name.",
        )
    if not android_src_dir and not has_resources:
        # Empty kt_android_library is valid in rules_kotlin. The hub's
        # aggregator depends on this spoke's `:lib` unconditionally, so
        # this no-op contribution keeps the deps list mechanical.
        return """\
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

kt_android_library(
    name = "lib",
    srcs = [],
    visibility = ["//visibility:public"],
)
"""

    if has_resources and not java_package:
        fail(
            "Plugin ships Android resources (android/src/main/res/) but " +
            "declares no namespace — checked android.namespace in " +
            "build.gradle(.kts), the AndroidManifest.xml package " +
            "attribute, and flutter.plugin.platforms.android.package in " +
            "pubspec.yaml. Without a namespace the R class cannot be " +
            "generated, so the resources would not compile.",
        )

    if android_src_dir:
        # Source dir is relative to the package root; the sub-package
        # itself lives at `android/`, so strip that prefix.
        if android_src_dir.startswith("android/"):
            sub_src = android_src_dir[len("android/"):]
        else:
            sub_src = android_src_dir
        srcs_attr = "glob([{kt}, {java}], allow_empty = True)".format(
            kt = repr(sub_src + "/**/*.kt"),
            java = repr(sub_src + "/**/*.java"),
        )
    else:
        srcs_attr = "[]"

    custom_package_arg = ""
    if java_package:
        custom_package_arg = "    custom_package = %s,\n" % repr(java_package)

    # `manifest = "..."` lets `android_binary`'s `ManifestMerger2` pick
    # up the plugin's `<activity>` / `<service>` / `<uses-permission>`
    # / etc. entries transitively — same shape AGP uses inside
    # `flutter build apk`. Paths are relative to the `android/`
    # sub-package, so the prefix is stripped there.
    (manifest_arg, synthesized_manifest) = _android_manifest_build_args(
        android_manifest,
        java_package,
        has_resources,
    )

    # Resources are compiled into the library so the plugin's `R` class
    # resolves at compile time and the resources merge into the consuming
    # APK. `allow_empty = False` — resource detection already saw files
    # here, so an empty glob means the layout assumption broke.
    resource_files_arg = ""
    if has_resources:
        resource_files_arg = '    resource_files = glob(["src/main/res/**"], allow_empty = False),\n'

    # `proguard_specs = [...]` lets `android_binary`'s R8 step pick up
    # the plugin's keep rules transitively — same shape AGP uses for
    # `consumerProguardFiles`. The paths are relative to the `android/`
    # sub-package, which is where the spoke lives in our layout.
    proguard_specs_arg = ""
    if consumer_proguard_specs:
        spec_lines = ", ".join([repr(path) for path in consumer_proguard_specs])
        proguard_specs_arg = "    proguard_specs = [%s],\n" % spec_lines

    # Base deps every plugin spoke gets: the engine (which carries the
    # FlutterPlugin SPI plus the embedding's androidx compile classpath
    # via its exports) and the BuildConfig stub. Plugin-specific maven
    # deps from `extra_maven_labels` are appended, de-duped.
    base_labels = [
        ":_engine",
        ":_build_config",
    ]
    seen = {label: True for label in base_labels}
    all_labels = list(base_labels)
    for lbl in extra_maven_labels:
        if lbl not in seen:
            seen[lbl] = True
            all_labels.append(lbl)
    deps_block = "\n        ".join([repr(label) + "," for label in all_labels])

    # BuildConfig.java stub — Gradle generates this implicitly per
    # plugin's namespace. rules_android does not, so we hand-emit one.
    bc_package = java_package if java_package else "_unknown"
    (bc_out, bc_content) = _android_build_config_block(bc_package)

    return """\
load("@bazel_skylib//rules:write_file.bzl", "write_file")
load("@rules_flutter//flutter:android.bzl", "flutter_android_engine")
load("@rules_java//java:java_library.bzl", "java_library")
load("@rules_kotlin//kotlin:android.bzl", "kt_android_library")

# Private engine target — gives the plugin's Kotlin/Java the FlutterPlugin
# SPI plus the embedding's androidx dependencies (via the engine's
# exports) on the compile classpath. Always arm64; Java bytecode is
# ABI-independent. neverlink, so the APK carries only the app's engine, of
# the ABI flutter_android_app(android_abi=...) names.
flutter_android_engine(
    name = "_engine",
    neverlink = True,
    visibility = ["//visibility:private"],
)

# BuildConfig.java stub. Gradle synthesizes this per Android module
# (matching `android.namespace`). rules_android doesn't, so we generate
# a minimal one — `DEBUG = false`, which is correct for release builds
# and harmless for debug (the engine ABI / mode is decided elsewhere).
write_file(
    name = "_build_config_src",
    out = {bc_out},
    content = [
{bc_content}
    ],
    newline = "unix",
)

java_library(
    name = "_build_config",
    srcs = [":_build_config_src"],
    visibility = ["//visibility:private"],
)
{synthesized_manifest}
kt_android_library(
    name = "lib",
    srcs = {srcs},
{custom_package}{manifest}{resource_files}{proguard_specs}    visibility = ["//visibility:public"],
    deps = [
        {deps}
    ],
)
""".format(
        srcs = srcs_attr,
        custom_package = custom_package_arg,
        manifest = manifest_arg,
        resource_files = resource_files_arg,
        proguard_specs = proguard_specs_arg,
        deps = deps_block,
        bc_out = bc_out,
        bc_content = bc_content,
        synthesized_manifest = synthesized_manifest,
    )

# The hook entrypoints upstream Dart defines (`package:hooks` — `build` and
# `link`). A package shipping one produces native libraries by running Dart at
# build time, which Bazel cannot do hermetically; something must stand in for it.
_DART_BUILD_HOOKS = ["hook/build.dart", "hook/link.dart"]

def _detect_unreplaced_hook(ctx):
    """Return the path of a build hook nothing replaces, or "".

    Recording rather than failing here is deliberate, and matches rules_dart:
    the whole lock is materialised, including packages nothing depends on, so
    failing at repo generation would break builds over packages never reached.
    The application that actually depends on one fails instead.
    """
    if ctx.attr.code_assets or ctx.attr.ignore_hook:
        return ""
    for candidate in _DART_BUILD_HOOKS:
        if ctx.path(candidate).exists:
            return candidate
    return ""

_LANGUAGE_VERSION_PLACEHOLDER = "{LANGUAGE_VERSION}"
_DEPS_PLACEHOLDER = "{DEPS}"

# The prefix a spoke label takes in an overlay template before substitution.
# Finding one means the template names a sibling package by hand.
_HUB_DEP_PREFIX = "@{HUB_NAME}__"

def find_hardcoded_language_version(content):
    """Return the literal language version an overlay spells out, or `""`.

    A package's `environment.sdk` is the only place its language version is
    declared; the spoke derives from it and substitutes
    `{LANGUAGE_VERSION}`. A template that writes the version out instead is a
    second declaration of the same fact, and the one that wins — the overlay
    replaces generated content wholesale. The two then drift silently,
    because the overlay ladder is version-ranged: `ext/objective_c/9/` serves
    every 9.x, so a release that raises the SDK floor keeps the old literal.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending literal (e.g. `"3.3"`), or `""` when the template
        either uses the placeholder or declares no language version.
    """
    marker = "language_version"
    idx = content.find(marker)
    for _ in range(len(content)):
        if idx == -1:
            return ""
        rest = content[idx + len(marker):].lstrip(" ")
        if rest.startswith("="):
            value = rest[1:].lstrip(" ")
            if value.startswith('"'):
                end = value.find('"', 1)
                if end > 0:
                    literal = value[1:end]
                    if literal != _LANGUAGE_VERSION_PLACEHOLDER:
                        return literal
        idx = content.find(marker, idx + len(marker))
    return ""

def find_hardcoded_hub_dep(content):
    """Return the first hand-written sibling-spoke label an overlay names, or `""`.

    A package's dependencies are declared once, by its own pubspec, and the
    spoke derives the Bazel labels from it — intersected with the lock, so a
    generated spoke can never name a repo the hub did not create. An overlay
    that spells the list out instead declares the same fact twice, and this
    copy wins, because an overlay replaces generated content wholesale.

    The two then drift on the package's next release, and the drift is not
    a stale-but-working list: `objective_c` 9.5.0 dropped `native_toolchain_c`
    from `dependencies` (its build hook stopped using it), so the lock stopped
    carrying that package, while `ext/objective_c/9/` — one directory for the
    whole major — kept asking for `@<hub>__native_toolchain_c`. The build died
    on an unknown repo naming neither `objective_c` nor the overlay.

    Args:
        content: Raw template text, before substitution.

    Returns:
        The offending label (e.g. `"@{HUB_NAME}__ffi//:ffi"`), or `""`.
    """
    idx = content.find(_HUB_DEP_PREFIX)
    if idx == -1:
        return ""
    end = content.find('"', idx)
    return content[idx:end] if end > 0 else content[idx:]

def render_overlay_deps(dep_labels):
    """Render `dep_labels` as the body of an overlay's `deps = [...]`.

    Emits one quoted, comma-terminated label per line at the eight-space
    indent a template's `deps = [` block sits at, so the substituted BUILD
    file comes out buildifier-clean.

    Args:
        dep_labels: Fully-qualified labels, in the order they should appear.

    Returns:
        The list body, without the enclosing brackets.
    """
    return "\n        ".join(['"%s",' % label for label in dep_labels])

_WRITE_FILE_LOAD = 'load("@bazel_skylib//rules:write_file.bzl", "write_file")\n'
_CAT_HEREDOC_PREFIX = "    cmd = \"cat > $@ <<'EOF'\\n"
_CAT_HEREDOC_SUFFIX = "\\nEOF\\n\",\n)"

def _rewrite_cat_genrules(content):
    """Rewrite heredoc `cat` `genrule` targets in overlay templates to `write_file`."""
    if _CAT_HEREDOC_PREFIX not in content:
        return content
    out_chunks = []
    rest = content
    for _ in range(16):
        idx = rest.find("genrule(\n")
        if idx < 0:
            break
        end_idx = rest.find(_CAT_HEREDOC_SUFFIX, idx)
        if end_idx < 0:
            break
        block = rest[idx:end_idx + len(_CAT_HEREDOC_SUFFIX)]
        cmd_idx = block.find(_CAT_HEREDOC_PREFIX)
        if cmd_idx < 0:
            out_chunks.append(rest[:idx + len("genrule(\n")])
            rest = rest[idx + len("genrule(\n"):]
            continue
        header = block[:cmd_idx]
        body = block[cmd_idx + len(_CAT_HEREDOC_PREFIX):len(block) - len(_CAT_HEREDOC_SUFFIX)]
        name_val = ""
        out_val = ""
        for hline in header.split("\n"):
            s = hline.strip()
            if s.startswith('name = "') and s.endswith('",'):
                name_val = s[len('name = "'):-2]
            elif s.startswith('outs = ["') and s.endswith('"],'):
                out_val = s[len('outs = ["'):-3]
        if not name_val or not out_val:
            out_chunks.append(rest[:idx + len("genrule(\n")])
            rest = rest[idx + len("genrule(\n"):]
            continue
        body_lines = body.split("\\n") + [""]
        content_entries = "\n".join(['        "%s",' % line for line in body_lines])
        replacement = (
            "write_file(\n" +
            '    name = "%s",\n' % name_val +
            '    out = "%s",\n' % out_val +
            "    content = [\n" +
            content_entries + "\n" +
            "    ],\n" +
            '    newline = "unix",\n' +
            ")"
        )
        out_chunks.append(rest[:idx])
        out_chunks.append(replacement)
        rest = rest[end_idx + len(_CAT_HEREDOC_SUFFIX):]
    out_chunks.append(rest)
    rewritten = "".join(out_chunks)
    if _WRITE_FILE_LOAD not in rewritten:
        load_idx = rewritten.find("load(")
        if load_idx >= 0:
            rewritten = rewritten[:load_idx] + _WRITE_FILE_LOAD + rewritten[load_idx:]
        else:
            rewritten = _WRITE_FILE_LOAD + rewritten
    return rewritten

def apply_overlay_substitutions(content, hub_name, package_name, version, language_version, deps):
    """Fill an overlay template's placeholders.

    Args:
        content: Raw template text.
        hub_name: Value for `{HUB_NAME}`.
        package_name: Value for `{PKG}`.
        version: Value for `{VERSION}`.
        language_version: Value for `{LANGUAGE_VERSION}`, derived from the
            package's own pubspec.
        deps: Rendered list body for `{DEPS}` (see `render_overlay_deps`),
            derived from the same pubspec-and-lock intersection a generated
            spoke uses.

    Returns:
        The substituted content.
    """
    substituted = content.replace(
        "{HUB_NAME}",
        hub_name,
    ).replace(
        "{PKG}",
        package_name,
    ).replace(
        "{VERSION}",
        version,
    ).replace(
        _LANGUAGE_VERSION_PLACEHOLDER,
        language_version,
    ).replace(
        _DEPS_PLACEHOLDER,
        deps,
    )
    return _rewrite_cat_genrules(substituted)

def _resolve_overlay_template(ctx, overlay_root_label, package_name, version, language_version, dep_labels, relpath, guard_hub_deps = False):
    """Look up an overlay template at `<root>/<package>/<version-ladder>/<relpath>`.

    Walks the version-specificity ladder
    `<major>.<minor>.<patch>/`, `<major>.<minor>/`, `<major>/`, bare
    `<package>/`, and returns the templated content (with `{HUB_NAME}`,
    `{PKG}`, `{VERSION}`, `{LANGUAGE_VERSION}` and `{DEPS}` substitutions
    applied) on first match. Returns empty string when no template is found.

    `dep_labels` are the spoke labels the package's own pubspec resolves to,
    which `{DEPS}` expands into. `guard_hub_deps` rejects a template that
    hand-writes those labels instead — see `find_hardcoded_hub_dep`. Only the
    top-level BUILD sets it: `{DEPS}` is a Dart dependency list, so it is not
    the right substitute for a sibling label in an `android/` sub-package.

    Currently called for two relpaths:

    * `BUILD.bazel.tpl` — the spoke's top-level BUILD that fully
      replaces the auto-generated content.
    * `android/BUILD.bazel.tpl` — the Android sub-package BUILD,
      replacing the empty-stub `kt_android_library(srcs=[])` that
      otherwise fires when a top-level overlay short-circuits the
      regular auto-gen path. Plugins whose Android side needs real
      sources / extra maven labels (e.g. ones whose Java references
      transitive deps not in the curated `_MAVEN_COORD_TO_LABEL`)
      ship this alongside the top-level overlay.
    """
    anchor = ctx.path(overlay_root_label)
    ctx.watch(anchor)
    root = anchor.dirname
    ctx.watch(root)
    pkg_dir = root.get_child(package_name)
    ctx.watch(pkg_dir)

    # Build the version ladder.
    parts = version.split(".")
    candidates = []
    if len(parts) >= 3:
        candidates.append("{}.{}.{}".format(parts[0], parts[1], parts[2]))
    if len(parts) >= 2:
        candidates.append("{}.{}".format(parts[0], parts[1]))
    if len(parts) >= 1 and parts[0]:
        candidates.append(parts[0])
    candidates.append("")  # bare <pkg>/<relpath>

    relpath_parts = relpath.split("/")
    for candidate in candidates:
        cand_dir = pkg_dir.get_child(candidate) if candidate else pkg_dir
        if candidate:
            ctx.watch(cand_dir)
        tpl = cand_dir
        for part in relpath_parts:
            tpl = tpl.get_child(part)
            ctx.watch(tpl)
        if tpl.exists:
            content = ctx.read(tpl)
            hardcoded_dep = find_hardcoded_hub_dep(content) if guard_hub_deps else ""
            if hardcoded_dep:
                fail((
                    "overlay template {tpl} hand-writes the dependency " +
                    "`{dep}`.\n" +
                    "A package's dependencies are declared once, by its own " +
                    "pubspec; the spoke derives the labels from it — " +
                    "intersected with the lock, so it can never name a repo " +
                    "the hub did not create. Listing them here declares the " +
                    "same fact twice, and this copy wins, because an overlay " +
                    "replaces generated content wholesale. Because the " +
                    "overlay ladder is version-ranged, a release that changes " +
                    "the package's dependencies then fails on an unknown " +
                    "repo that names neither the package nor this file.\n" +
                    "Write `deps = [\n        {placeholder}\n    ],` instead."
                ).format(
                    tpl = str(tpl),
                    dep = hardcoded_dep,
                    placeholder = _DEPS_PLACEHOLDER,
                ))
            hardcoded = find_hardcoded_language_version(content)
            if hardcoded:
                fail((
                    "overlay template {tpl} sets language_version = \"{value}\".\n" +
                    "A package's language version is declared once, by its own " +
                    "pubspec `environment.sdk`; the spoke derives it and fills in " +
                    "{placeholder}. Spelling it out here declares the same fact " +
                    "twice, and this copy wins — an overlay replaces generated " +
                    "content wholesale. Because the overlay ladder is " +
                    "version-ranged, the two then drift without a build error.\n" +
                    "Write `language_version = \"{placeholder}\"` instead."
                ).format(
                    tpl = str(tpl),
                    value = hardcoded,
                    placeholder = _LANGUAGE_VERSION_PLACEHOLDER,
                ))
            return apply_overlay_substitutions(
                content = content,
                hub_name = ctx.attr.hub_name,
                package_name = package_name,
                version = version,
                language_version = language_version,
                deps = render_overlay_deps(dep_labels),
            )
    return ""

resolve_overlay_template = _resolve_overlay_template

def _resolve_overlay(ctx, overlay_root_label, package_name, version, language_version, dep_labels):
    """Resolve the top-level BUILD.bazel.tpl overlay.

    Equivalent to `_resolve_overlay_template(..., "BUILD.bazel.tpl")`.
    Kept as a separate helper because the top-level lookup is the most
    common call shape; consumers wanting the Android sub-package
    template call `_resolve_overlay_template` directly.
    """
    return _resolve_overlay_template(
        ctx,
        overlay_root_label,
        package_name,
        version,
        language_version,
        dep_labels,
        "BUILD.bazel.tpl",
        guard_hub_deps = True,
    )

resolve_overlay = _resolve_overlay

def resolve_overlay_roots(ctx, overlay_roots, package_name, version, language_version, dep_labels):
    """Resolve `(overlay_content, overlay_android_content)` across `overlay_roots`.

    Walks `overlay_roots` in order and stops on the first root that supplies a
    top-level `BUILD.bazel.tpl` for `package_name` at `version`, then looks up
    the matching `android/BUILD.bazel.tpl` from that same root.

    Args:
        ctx: The repository rule context (`repository_ctx`).
        overlay_roots: Anchor labels for candidate overlay trees, ordered by precedence.
        package_name: The pub package name to look up.
        version: The resolved package version string.
        language_version: The Dart language version derived from the package's pubspec.
        dep_labels: Sibling spoke label strings for `{DEPS}` substitution.

    Returns:
        A `(overlay_content, overlay_android_content)` tuple of substituted
        BUILD contents (each `""` when no matching template was found).
    """
    overlay_content = ""
    overlay_android_content = ""
    for overlay_label in overlay_roots:
        overlay_content = _resolve_overlay(
            ctx,
            overlay_label,
            package_name,
            version,
            language_version,
            dep_labels,
        )
        if overlay_content:
            # Look up the matching `android/BUILD.bazel.tpl` from the same
            # overlay root. Plugins whose Android side has real sources
            # ship one alongside the top-level BUILD; plugins that don't
            # leave it absent and the empty-stub fallback fires below.
            overlay_android_content = _resolve_overlay_template(
                ctx,
                overlay_label,
                package_name,
                version,
                language_version,
                dep_labels,
                "android/BUILD.bazel.tpl",
            )
            break
    return overlay_content, overlay_android_content

def _flutter_pub_package_impl(ctx):
    url = "{base}/packages/{name}/versions/{version}.tar.gz".format(
        base = ctx.attr.base_url,
        name = ctx.attr.package_name,
        version = ctx.attr.version,
    )

    # Match `pub_lock_package`'s download/extract semantics: verify sha256 on
    # download, strip any trailing NUL padding past the RFC 1952 gzip trailer,
    # and unpack with `ctx.extract`.
    pinned_download(
        ctx,
        url = url,
        output = "_archive.tar.gz",
        sha256 = require_sha256(ctx.attr.sha256, url),
    )
    raw_archive = ctx.read("_archive.tar.gz", watch = "no")
    trimmed_archive = trim_gzip_trailing_nulls(raw_archive)
    if trimmed_archive != raw_archive:
        ctx.delete("_archive.tar.gz")
        ctx.file("_archive.tar.gz", trimmed_archive, executable = False)
    ctx.extract("_archive.tar.gz")
    ctx.delete("_archive.tar.gz")

    bazel_deps = []
    language_version = ""
    plugin_block = struct(
        present = False,
        platforms = {},
        implements = "",
        ffi_plugin = False,
    )
    asset_block = struct(
        fonts = [],
        assets = [],
        shaders = [],
        uses_material_design = False,
    )
    pubspec_path = ctx.path("pubspec.yaml")
    if pubspec_path.exists:
        pubspec_content = ctx.read(pubspec_path)
        all_deps = parse_pubspec_deps(pubspec_content)
        available = {p: True for p in ctx.attr.lock_packages}
        bazel_deps = sorted([d for d in all_deps if d in available])
        language_version = derive_language_version(
            parse_pubspec_sdk_constraint(pubspec_content),
        )
        plugin_block = parse_flutter_plugin_block(pubspec_content)
        asset_block = parse_flutter_assets_block(pubspec_content)

    # Build full label strings for sibling spoke repos.
    dep_labels = [
        "@{hub}__{dep}//:{dep}".format(hub = ctx.attr.hub_name, dep = dep)
        for dep in bazel_deps
    ]

    # If the pubspec declares `uses-material-design: true`, the spoke
    # depends on @rules_flutter//flutter:material_icons so the bundled
    # font travels through the deps graph automatically — same channel
    # any other pub package's font flows through. Cross-package mismatch
    # (app says false, pub dep says true) becomes structurally impossible.
    if asset_block.uses_material_design:
        dep_labels = dep_labels + ["@rules_flutter//flutter:material_icons"]

    # Pre-compute the pub-asset attr inputs once. Used by either branch
    # below (plugin vs library).
    fonts_json_str = _encode_fonts_json(asset_block.fonts)
    font_files = _build_font_files_dict(asset_block.fonts)
    pkg_assets_dict = _build_pkg_assets_dict(ctx, asset_block.assets)
    pkg_shaders_dict = _build_pkg_shaders_dict(asset_block.shaders)
    has_asset_contributions = (
        bool(asset_block.fonts) or bool(asset_block.assets) or bool(asset_block.shaders)
    )

    # Computed once, before the branch: which generator runs depends on the
    # pubspec, but a build hook is a property of the package either way.
    unreplaced_hook = _detect_unreplaced_hook(ctx)

    # Try overlays first (user-supplied roots win over the bundled
    # `@rules_flutter//ext/` tree). On match, the overlay replaces
    # auto-generation entirely; the user takes responsibility for the
    # spoke's BUILD content.
    overlay_content, overlay_android_content = resolve_overlay_roots(
        ctx,
        ctx.attr.overlay_roots,
        ctx.attr.package_name,
        ctx.attr.version,
        language_version,
        dep_labels,
    )

    if overlay_content:
        ctx.file("BUILD.bazel", overlay_content)

        # When the overlay ships an `android/BUILD.bazel.tpl`, use it
        # verbatim. Otherwise emit an empty stub so the hub's
        # `android/all_android_plugin_libs` aggregator can depend on
        # `@<spoke>//android:lib` uniformly across overlay-and-no-Android
        # plugins (audio_session declares Android sources and ships the
        # full sub-package; objective_c is pure Apple and gets the stub).
        if overlay_android_content:
            ctx.file("android/BUILD.bazel", overlay_android_content)
        else:
            ctx.file(
                "android/BUILD.bazel",
                make_android_subpackage_build_content(
                    android_src_dir = "",
                    java_package = "",
                    extra_maven_labels = [],
                ),
            )
        return

    if plugin_block.present:
        # Detect Apple sources per platform when pluginClass is set.
        apple_macos_srcs_dirs = []
        apple_ios_srcs_dirs = []

        macos_info = plugin_block.platforms.get("macos", {})
        ios_info = plugin_block.platforms.get("ios", {})
        linux_info = plugin_block.platforms.get("linux", {})
        windows_info = plugin_block.platforms.get("windows", {})

        macos_shared_darwin = macos_info.get("sharedDarwinSource", False) if macos_info else False
        ios_shared_darwin = ios_info.get("sharedDarwinSource", False) if ios_info else False

        apple_macos_include_dirs = []
        apple_ios_include_dirs = []
        apple_macos_privacy_manifests = []
        apple_ios_privacy_manifests = []

        if macos_info and macos_info.get("pluginClass", ""):
            apple_macos_srcs_dirs = _detect_apple_source_dirs(
                ctx,
                ctx.attr.package_name,
                "macos",
                macos_shared_darwin,
            )
            apple_macos_include_dirs = _detect_apple_include_dirs(
                ctx,
                apple_macos_srcs_dirs,
                ctx.attr.package_name,
            )
            apple_macos_privacy_manifests = _detect_apple_privacy_manifests(
                ctx,
                apple_macos_srcs_dirs,
            )

        if ios_info and ios_info.get("pluginClass", ""):
            apple_ios_srcs_dirs = _detect_apple_source_dirs(
                ctx,
                ctx.attr.package_name,
                "ios",
                ios_shared_darwin,
            )
            apple_ios_include_dirs = _detect_apple_include_dirs(
                ctx,
                apple_ios_srcs_dirs,
                ctx.attr.package_name,
            )
            apple_ios_privacy_manifests = _detect_apple_privacy_manifests(
                ctx,
                apple_ios_srcs_dirs,
            )

        # Linux/Windows desktop sources: scan whenever pluginClass is
        # set on that platform. The plugin's own `linux/`/`windows/`
        # directory is the canonical location.
        linux_src_dir = ""
        windows_src_dir = ""
        if linux_info and linux_info.get("pluginClass", ""):
            linux_src_dir = _detect_desktop_source_dir(ctx, "linux")
        if windows_info and windows_info.get("pluginClass", ""):
            windows_src_dir = _detect_desktop_source_dir(ctx, "windows")

        # Android sources: scan when pluginClass is set on android.
        android_info = plugin_block.platforms.get("android", {})
        android_src_dir = ""
        android_java_package = ""
        android_extra_maven_labels = []
        android_manifest = ""
        android_consumer_proguard_specs = []
        android_has_resources = False
        android_native_build = False
        if android_info:
            android_native_build = _detect_android_native_build(ctx)
        if android_info and android_info.get("pluginClass", ""):
            android_src_dir = _detect_android_source_dir(ctx)
            android_has_resources = _detect_android_resources(ctx)

            # Namespace resolution mirrors AGP (gradle `android.namespace`,
            # else the manifest `package` attribute). The pubspec's
            # `package` field locates the plugin class for the registrant;
            # it only stands in for the namespace when the plugin declares
            # none of its own.
            android_java_package = (
                _detect_android_namespace(ctx) or
                android_info.get("package", "") or
                ""
            )
            _fail_on_invalid_android_namespace(ctx.attr.package_name, android_java_package)
            if android_src_dir or android_has_resources:
                android_extra_maven_labels = _resolve_plugin_maven_deps(ctx)
                android_manifest = _detect_android_manifest(ctx)
                android_consumer_proguard_specs = _detect_consumer_proguard_specs(ctx)

        plugin_platforms_json = json.encode(plugin_block.platforms)
        build_content = make_flutter_plugin_build_content(
            name = ctx.attr.package_name,
            deps = dep_labels,
            language_version = language_version,
            version = ctx.attr.version,
            code_assets = ctx.attr.code_assets,
            has_unreplaced_hook = unreplaced_hook,
            plugin_platforms_json = plugin_platforms_json,
            apple_macos_srcs_dirs = apple_macos_srcs_dirs,
            apple_ios_srcs_dirs = apple_ios_srcs_dirs,
            apple_macos_include_dirs = apple_macos_include_dirs,
            apple_ios_include_dirs = apple_ios_include_dirs,
            apple_macos_privacy_manifests = apple_macos_privacy_manifests,
            apple_ios_privacy_manifests = apple_ios_privacy_manifests,
            linux_src_dir = linux_src_dir,
            windows_src_dir = windows_src_dir,
            fonts_json_str = fonts_json_str,
            font_files = font_files,
            pkg_assets = pkg_assets_dict,
            pkg_shaders = pkg_shaders_dict,
        )
    elif has_asset_contributions:
        # No plugin block, but the pubspec has flutter.fonts/assets/shaders.
        # Emit a flutter_library (rather than dart_library) so the metadata
        # propagates via FlutterInfo.pub_fonts/pub_assets/pub_shaders to the
        # consuming app's bundle aggregator.
        build_content = make_flutter_library_build_content(
            name = ctx.attr.package_name,
            deps = dep_labels,
            language_version = language_version,
            version = ctx.attr.version,
            code_assets = ctx.attr.code_assets,
            has_unreplaced_hook = unreplaced_hook,
            fonts_json_str = fonts_json_str,
            font_files = font_files,
            pkg_assets = pkg_assets_dict,
            pkg_shaders = pkg_shaders_dict,
        )
        android_src_dir = ""
        android_java_package = ""
        android_extra_maven_labels = []
        android_manifest = ""
        android_consumer_proguard_specs = []
        android_has_resources = False
        android_native_build = False
    else:
        build_content = make_dart_library_build_content(
            name = ctx.attr.package_name,
            deps = dep_labels,
            language_version = language_version,
            code_assets = ctx.attr.code_assets,
            has_unreplaced_hook = unreplaced_hook,
            version = ctx.attr.version,
        )
        if ctx.attr.package_name == "test":
            ctx.file("flutter_test_package.bzl", _FLUTTER_TEST_PACKAGE_BZL_CONTENT)
            build_content = build_content.replace(
                '    "dart_test_package",\n',
                "",
            ).replace(
                "dart_test_package(",
                'load(":flutter_test_package.bzl", "flutter_test_package")\n\nflutter_test_package(',
            )
        android_src_dir = ""
        android_java_package = ""
        android_extra_maven_labels = []
        android_manifest = ""
        android_consumer_proguard_specs = []
        android_has_resources = False
        android_native_build = False

    ctx.file("BUILD.bazel", build_content)

    # Always emit `android/BUILD.bazel`. Bazel only loads it when something
    # queries `@<spoke>//android:lib`, so non-Android workspaces don't pay
    # the @rules_android / @rules_kotlin cost. Plugins whose Gradle build
    # compiles native Android code that autogen cannot translate get a
    # load-time fail() here instead — Android builds break loudly rather
    # than shipping an APK missing the library.
    if android_native_build:
        android_build_content = _make_android_native_build_unsupported_content(
            ctx.attr.package_name,
            ctx.attr.version,
        )
    else:
        android_build_content = make_android_subpackage_build_content(
            android_src_dir = android_src_dir,
            java_package = android_java_package,
            extra_maven_labels = android_extra_maven_labels,
            android_manifest = android_manifest,
            consumer_proguard_specs = android_consumer_proguard_specs,
            has_resources = android_has_resources,
        )
    ctx.file("android/BUILD.bazel", android_build_content)

_FLUTTER_TEST_PACKAGE_BZL_CONTENT = """\
load("@rules_dart//dart:providers.bzl", "DartInfo")
load(
    "@rules_dart//dart/private:dart_test_runner.bzl",
    "DartTestRunnerInfo",
    "DartTestRunnerSnapshotInfo",
)

def _flutter_test_package_impl(ctx):
    library = ctx.attr.library
    dills = [f for f in ctx.attr.runner[DefaultInfo].files.to_list() if f.extension == "dill"]
    if len(dills) != 1:
        fail("%s: `runner` must produce exactly one `.dill`, got %s" % (ctx.label, dills))
    runner = dills[0]
    if ctx.attr.snapshot != None:
        snapshot = ctx.attr.snapshot[DartTestRunnerSnapshotInfo].snapshot
        if snapshot != None:
            runner = snapshot
    return [
        library[DefaultInfo],
        library[DartInfo],
        DartTestRunnerInfo(runner = runner),
    ]

flutter_test_package = rule(
    implementation = _flutter_test_package_impl,
    attrs = {
        "library": attr.label(
            doc = "The `package:test` `dart_library`.",
            mandatory = True,
            providers = [DartInfo],
        ),
        "runner": attr.label(
            doc = "A kernel-mode `dart_binary` built from `library`.",
            mandatory = True,
        ),
        "snapshot": attr.label(
            doc = "A `dart_test_runner_snapshot` of `runner`. Its snapshot runs in place of the kernel when one was built.",
            providers = [DartTestRunnerSnapshotInfo],
        ),
    },
    doc = "`package:test` as a dependency, carrying the runner built from it.",
)
"""

flutter_pub_package = repository_rule(
    implementation = _flutter_pub_package_impl,
    attrs = {
        "package_name": attr.string(
            doc = "The pub.dev package name.",
            mandatory = True,
        ),
        "version": attr.string(
            doc = "The package version to download.",
            mandatory = True,
        ),
        "sha256": attr.string(
            doc = "SHA256 hash of the package archive. Taken from the hosted lock entry; an empty value fails the fetch.",
            default = "",
        ),
        "base_url": attr.string(
            doc = "Base URL for the pub repository.",
            default = "https://pub.dev",
        ),
        "hub_name": attr.string(
            doc = "Name of the hub repo (for constructing cross-spoke dep labels).",
            mandatory = True,
        ),
        "lock_packages": attr.string_list(
            doc = "All hosted package names in the lock file (for dep filtering).",
            default = [],
        ),
        "code_assets": attr.string_list(
            doc = "Labels of `dart_code_asset` targets standing in for this " +
                  "package's build hook. Resolved by the extension from " +
                  "rules_dart's curated registry, so a user depending on, say, " +
                  "`drift` never names `sqlite3`. Attached to the generated " +
                  "package target rather than to the application, which is what " +
                  "makes them propagate the way pub's own assets do.",
            default = [],
        ),
        "ignore_hook": attr.bool(
            doc = "Treat this package's build hook as irrelevant. Without it, a " +
                  "package shipping a hook that nothing replaces is recorded and " +
                  "the application that reaches it fails, rather than building " +
                  "cleanly and dying at runtime on an unresolved native symbol.",
            default = False,
        ),
        "android_maven_deps": attr.string_dict(
            doc = "`group:artifact` -> Bazel label additions to the built-in " +
                  "Gradle-to-`@rules_android_maven` mapping, from " +
                  "`flutter.pub(android_maven_deps)`. A plugin's " +
                  "`android/build.gradle*` runtime dependency whose " +
                  "coordinate is in neither table fails the fetch; mapping " +
                  "it here is the fix for external artifacts.",
            default = {},
        ),
        "android_maven_ignore": attr.string_list(
            doc = "`group:artifact` coordinates that need no Bazel label, " +
                  "from `flutter.pub(android_maven_ignore)`. A coordinate " +
                  "listed here is left out of the spoke's deps instead of " +
                  "failing the fetch as unknown. This is a declaration you " +
                  "make deliberately; it is never a default.",
            default = [],
        ),
        "overlay_roots": attr.label_list(
            doc = "BUILD.bazel anchors for overlay trees. Each label points at " +
                  "an `ext/BUILD.bazel` (or equivalent) that anchors a directory " +
                  "tree of `<package>/<version>/BUILD.bazel.tpl` overrides. The " +
                  "rule walks the roots in order and uses the first match. " +
                  "User-supplied roots come before the bundled " +
                  "`@rules_flutter//ext:BUILD.bazel`.",
            allow_files = True,
            default = [],
        ),
    },
    doc = "Downloads a single Flutter pub package and emits a `flutter_plugin` (when `flutter.plugin` is present) or a plain `dart_library` (otherwise). When Apple sources are detected, also emits per-platform `flutter_apple_plugin_library` sub-targets. Honors per-package overlay BUILD.bazel.tpl overrides under `overlay_roots`. The `flutter pub get` analog of `pub_lock_package`.",
)
