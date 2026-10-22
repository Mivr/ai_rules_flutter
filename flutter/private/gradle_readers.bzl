"""Namespace, native-build and ProGuard readers for the plugin Gradle build.

Every reader folds the shared statement model (`gradle_model.bzl`): the
same lexed statements, the same `apply from:` scripts, the same depth
and cycle limits the dependency reader (`gradle_deps.bzl`) sees. No
reader scans raw text or single lines.

Never silent: a statement that names the reader's keyword in code (never
in a comment or a string) but whose value the model cannot determine is
reported for refusal, and the repository rule fails the fetch naming the
plugin, the file and the statement. A plugin overlay
(`flutter.plugin_overlays`) stays the escape for builds no model covers.
"""

load(
    ":gradle_deps.bzl",
    _deps_maven_labels_for_gradle = "maven_labels_for_gradle",
)
load(
    ":gradle_lex.bzl",
    _lex_language_of = "gradle_language_of",
    _lex_lex = "gradle_lex",
)
load(
    ":gradle_model.bzl",
    _model_block_name = "gradle_block_name",
    _model_code_text = "gradle_code_text",
    _model_collect_files = "gradle_collect_files",
    _model_has_word = "gradle_has_word",
    _model_segments = "gradle_segments",
)
load(
    ":gradle_parse.bzl",
    _parse_leading_word = "gradle_leading_word",
)

def _gradle_package_reader(ctx):
    """A `read_script` callback confined to the spoke's `android/` tree."""
    def _read_package_script(path):
        gradle_file = ctx.path("android/" + path)
        if not gradle_file.exists:
            return None
        return ctx.read(gradle_file)

    return _read_package_script

def _gradle_string_value(literal, language):
    """Plain string value of one literal span; `(value, ok)`.

    Single-quoted Groovy holds its text raw (`$` never interpolates
    there); every other quoted, slashy or dollar-slashy form with a `$`
    may interpolate and is not plain. Kotlin single-quoted is a `Char`,
    never a string. Anything less than a whole literal — a variable, a
    catalog ref, concatenation residue — is not plain either.
    """
    if literal[:2] == "$/":
        if len(literal) < 4 or literal[len(literal) - 2:] != "/$":
            return (None, False)
        inner = literal[2:len(literal) - 2]
        if "$" in inner:
            return (None, False)
        return (inner, True)
    if literal[:1] == "/":
        if len(literal) < 2 or literal[len(literal) - 1:] != "/":
            return (None, False)
        inner = literal[1:len(literal) - 1]
        if "$" in inner or "\\" in inner:
            return (None, False)
        return (inner, True)
    q = literal[:1]
    if q != "'" and q != '"':
        return (None, False)
    if q == "'" and language == "kotlin":
        return (None, False)
    if literal[:3] == q + q + q:
        if len(literal) < 6 or literal[len(literal) - 3:] != q + q + q:
            return (None, False)
        inner = literal[3:len(literal) - 3]
        if q == '"' and "$" in inner:
            return (None, False)
        return (inner, True)
    if len(literal) < 2 or literal[len(literal) - 1:] != q:
        return (None, False)
    inner = literal[1:len(literal) - 1]
    if q == '"' and "$" in inner:
        return (None, False)
    return (inner, True)

def _gradle_namespace_result(statement, value, literal):
    """One namespace declaration: `value` with its `literal` flag."""
    return struct(statement = statement, value = value, literal = literal)

def _gradle_namespace_forms(stmt, segs, compact, forms, language):
    """File one namespace-shaped statement as good, bad or ignored."""
    literals = [s.text for s in segs if not s.code]
    if len(literals) == 0:
        # A bare reference (`namespace`, `android.namespace`) reads
        # nothing; any other declaration-shaped statement without a
        # literal has a non-literal value.
        if compact in ("namespace", "android.namespace"):
            return None
        return _gradle_namespace_result(stmt, "", False)
    if len(literals) != 1 or compact not in forms:
        return _gradle_namespace_result(stmt, "", False)
    (inner, ok) = _gradle_string_value(literals[0], language)
    if not ok:
        return _gradle_namespace_result(stmt, "", False)
    return _gradle_namespace_result(stmt, inner, True)

def _gradle_parse_namespace_stmt(stmt, stack, language):
    """Parse one lexed statement as an Android namespace declaration.

    A declaration is a `namespace` assignment or call whose innermost
    block is `android` (at any nesting depth, including the
    `android.apply { ... }` and `configure<LibraryExtension> { ... }`
    receiver shapes), or a qualified `android.namespace = ...` at any
    depth (nested self-delegation, deferred `afterEvaluate { ... }`
    configuration). Anything else — including a `namespace` word inside
    a nested non-`android` block — declares nothing. Comments never reach
    this function (the lexer drops them) and string contents arrive as
    literal segments, so neither can count.

    Args:
        stmt: One statement from `gradle_lex`.
        stack: The block-name stack around the statement.
        language: `"groovy"` or `"kotlin"`.

    Returns:
        None when the statement declares no namespace, else
        `struct(statement, value, literal)`; `literal` is False when the
        statement names a namespace but its value is not one plain
        string literal.
    """
    segs = _model_segments(stmt, language)
    code = "".join([s.text for s in segs if s.code])
    compact = code.replace(" ", "").replace("\t", "").replace("\r", "").replace("\n", "")
    word = _parse_leading_word(code.strip())
    if word == "namespace":
        if not stack or _model_block_name(stack[len(stack) - 1]) != "android":
            return None
        return _gradle_namespace_forms(stmt, segs, compact, (
            "namespace=",
            "namespace",
            "namespace()",
            "namespace.set()",
        ), language)
    if word == "android":
        if len(compact) < 17 or compact[:17] != "android.namespace":
            return None
        tail = compact[17:]
        if tail != "" and tail[0] not in "=(.":
            return None
        return _gradle_namespace_forms(stmt, segs, compact, (
            "android.namespace=",
        ), language)
    return None

def _gradle_namespaces_of_events(events, language, file):
    """Namespace declarations among one script's events, tagged with `file`."""
    found = []
    stack = []
    for e in events:
        if e.kind == "open":
            stack.append(e.text)
        elif e.kind == "close":
            if stack:
                stack.pop()
        elif e.kind == "stmt":
            parsed = _gradle_parse_namespace_stmt(e.text, stack, language)
            if parsed != None:
                found.append(struct(
                    file = file,
                    statement = parsed.statement,
                    value = parsed.value,
                    literal = parsed.literal,
                ))
    return found

def gradle_scan_namespaces(files):
    """Namespace declarations across collected scripts, in source order.

    Gradle applies assignments in order, so the last literal one wins.

    Args:
        files: Collected scripts (`struct(path, language, events)`).
    """
    found = []
    for f in files:
        found.extend(_gradle_namespaces_of_events(f.events, f.language, f.path))
    return found

def gradle_android_namespaces(content, language = "groovy"):
    """List every Android namespace declaration in one Gradle script.

    Walks the same lexed statement model the dependency reader uses, so
    layout is insignificant and comments and string contents never count.
    Several assignments each appear; Gradle applies them in order, so the
    last one wins.

    Args:
        content: The `build.gradle` / `build.gradle.kts` file content.
        language: `"groovy"` or `"kotlin"`, from the file extension.

    Returns:
        The `struct(statement, value, literal)` list in source order.
    """
    found = []
    stack = []
    for e in _lex_lex(content, language):
        if e.kind == "open":
            stack.append(e.text)
        elif e.kind == "close":
            if stack:
                stack.pop()
        elif e.kind == "stmt":
            parsed = _gradle_parse_namespace_stmt(e.text, stack, language)
            if parsed != None:
                found.append(parsed)
    return found

def parse_gradle_android_namespace(content, language = "groovy"):
    """Extract `android.namespace` from a Gradle build script.

    Reads the same lexed statement model as the dependency parser: a
    `namespace` assignment or call whose innermost block is `android`
    (even on one line, even nested inside other blocks), or a qualified
    `android.namespace = ...` at any depth. Comments and string contents
    never count. When several assignments exist the last one wins, the
    way Gradle applies them.

    Args:
        content: The `build.gradle` / `build.gradle.kts` file content.
        language: `"groovy"` or `"kotlin"`, from the file extension.

    Returns:
        The declared namespace, or empty string when the script
        declares none. A declaration whose value is not one plain string
        literal is reported through `gradle_android_namespaces` and
        refused by the repository rule; here it reads as no namespace.
    """
    value = ""
    for ns in gradle_android_namespaces(content, language):
        if ns.literal and ns.value:
            value = ns.value
    return value

def detect_android_namespace(ctx, build_file, build_content):
    """Resolve the plugin's Android namespace the way AGP does.

    AGP determines a library's namespace from `android.namespace` in the
    project's build scripts, falling back to the manifest's `package`
    attribute for pre-AGP-8 projects. The namespace is where the
    generated `R` and `BuildConfig` classes live, so resource
    references like `R.drawable.ic_mic` only resolve when we use the
    same one. `build_file` / `build_content` are the spoke's single
    Gradle build (see `plugin_android_build`); applied scripts are read
    the same way the dependency reader reads them.

    Several assignments resolve last-wins, the way Gradle applies them. A
    declaration whose value is not one plain string literal fails the
    fetch, naming the plugin, the file and the statement. Returns empty
    string when the plugin declares no namespace anywhere.

    Args:
        ctx: the spoke repository context (package name, manifest read).
        build_file: the spoke-relative Gradle build path, for errors.
        build_content: the text of the spoke's single Gradle build.

    Returns:
        The Android namespace, or "" when the plugin declares none.
    """
    if build_content:
        collected = _model_collect_files(
            build_file,
            build_content,
            _lex_language_of(build_file),
            _gradle_package_reader(ctx),
        )
        value = ""
        for ns in gradle_scan_namespaces(collected.files):
            if not ns.literal:
                fail((
                    "flutter.pub spoke for \"{pkg}\": {gradle} sets the Android " +
                    "namespace to {stmt}, which is not one plain string literal " +
                    "(expected namespace = 'com.example.plugin'). A namespace " +
                    "read from a variable, a catalog or an expression cannot " +
                    "be resolved to a Java package at fetch time."
                ).format(
                    pkg = ctx.attr.package_name,
                    gradle = ns.file,
                    stmt = repr(ns.statement),
                ))
            if ns.value:
                value = ns.value
        if value:
            return value
    manifest_path = ctx.path("android/src/main/AndroidManifest.xml")
    if manifest_path.exists:
        return parse_android_manifest_package(ctx.read(manifest_path))
    return ""

def gradle_scan_native(files):
    """Every `(file, statement)` mentioning `externalNativeBuild` in code.

    Comments and string contents never reach the check (the lexer drops
    the former, the segment model blanks the latter), so only a real
    reference counts — wherever in the collected scripts it stands,
    including applied scripts.

    Args:
        files: Collected scripts (`struct(path, language, events)`).
    """
    found = []
    for f in files:
        for e in f.events:
            if e.kind != "stmt" and e.kind != "open":
                continue
            if _model_has_word(e.text, f.language, "externalNativeBuild"):
                found.append(struct(file = f.path, statement = e.text))
    return found

def detect_android_native_build(ctx, build_file, build_content):
    """Find the plugin's NDK build wherever its Gradle scripts declare it.

    Gradle-built Flutter plugins declare `externalNativeBuild` in the
    project's build scripts to compile C/C++ sources (CMake / ndk-build)
    into a shared library the APK must carry — e.g.
    package:jni's libdartjni.so. rules_flutter has no generic translation
    for those builds; packages that need one ship a curated overlay
    (bundled under `@rules_flutter//ext/` or user-supplied via
    `flutter.plugin_overlays`). Detection lets the generated android/
    sub-package fail loudly instead of silently producing an APK missing
    the library. Applied scripts are read the same way the dependency
    reader reads them, so factoring the NDK stanza into an applied
    script cannot hide it.

    Args:
        ctx: the spoke repository context (path, exists and read).
        build_file: the spoke-relative Gradle build path, for messages.
        build_content: The spoke's single Gradle build text (see
            `plugin_android_build`); "" when the plugin ships no build
            file.

    Returns:
        `struct(file, statement)` for the first reference, or None when
        the scripts never mention `externalNativeBuild` in code.
    """
    if not build_content:
        return None
    collected = _model_collect_files(
        build_file,
        build_content,
        _lex_language_of(build_file),
        _gradle_package_reader(ctx),
    )
    found = gradle_scan_native(collected.files)
    if found:
        return found[0]
    return None

def _gradle_proguard_residue(code):
    """Non-path remainder of a `consumerProguardFiles` call; "" when plain.

    Past the keyword a plain call holds only string literals, parens,
    commas and the `file(...)` / `files(...)` wrappers. Anything else — a
    bare variable, concatenation, a method result — means the rule files
    cannot be resolved at fetch time.
    """
    rest = code.split("consumerProguardFiles", 1)[1]
    words = []
    for tok in rest.replace("(", " ").replace(")", " ").replace(",", " ").split(" "):
        t = tok.strip()
        if t and t != "file" and t != "files":
            words.append(t)
    return " ".join(words)

def _gradle_visit_proguard_stmt(text, language, file, paths, bad):
    """File one statement's `consumerProguardFiles` paths or its refusal."""
    if not _model_has_word(text, language, "consumerProguardFiles"):
        return
    got = []
    plain = True
    for s in _model_segments(text, language):
        if s.code:
            continue
        (value, ok) = _gradle_string_value(s.text, language)
        if ok:
            got.append(value)
        else:
            plain = False
    if not plain or not got or _gradle_proguard_residue(_model_code_text(text, language)):
        bad.append(struct(file = file, statement = text))
        return
    for p in got:
        paths[p] = True

def gradle_scan_proguard(files):
    """Consumer keep-rule files across collected scripts.

    Multi-line calls and several files per call resolve like the
    single-line form; a variable argument, an interpolated path, or an
    empty call cannot resolve and is reported for refusal.

    Args:
        files: Collected scripts (`struct(path, language, events)`).

    Returns:
        `struct(paths, bad)`: `paths` the sorted distinct rule files,
        `bad` the `(file, statement)` refusals.
    """
    paths = {}
    bad = []
    for f in files:
        for e in f.events:
            if e.kind != "stmt" and e.kind != "open":
                continue
            _gradle_visit_proguard_stmt(e.text, f.language, f.path, paths, bad)
    return struct(paths = sorted(paths.keys()), bad = bad)

def detect_consumer_proguard_specs(ctx, build_file, build_content):
    """Find the plugin's `consumer-rules.pro` files, declared via Gradle.

    Reads the spoke's Gradle build scripts (see `plugin_android_build`)
    through the shared statement model — multi-line calls, several files
    per call and applied scripts included — and returns paths relative to
    the spoke's `android/` sub-package, only for files that actually
    exist on disk. Empty when the plugin doesn't ship consumer rules. AGP
    propagates these into the consuming app's R8 invocation;
    rules_android does the same when they appear in
    `kt_android_library(proguard_specs = [...])` and the binary has
    R8 enabled. A declaration whose files cannot be resolved fails the
    fetch, naming the plugin, the file and the statement.

    Args:
        ctx: the spoke repository context (file existence checks).
        build_file: the spoke-relative Gradle build path, for errors.
        build_content: the text of the spoke's single Gradle build.

    Returns:
        Spoke-`android/`-relative paths of existing consumer rule files.
    """
    paths = []
    if build_content:
        collected = _model_collect_files(
            build_file,
            build_content,
            _lex_language_of(build_file),
            _gradle_package_reader(ctx),
        )
        scanned = gradle_scan_proguard(collected.files)
        for refusal in scanned.bad:
            fail((
                "flutter.pub spoke for \"{pkg}\": {gradle} declares " +
                "consumerProguardFiles as {stmt}, which is not one or more " +
                "plain string literals (expected consumerProguardFiles " +
                "'consumer-rules.pro'). A declaration routed through a " +
                "variable or an expression cannot be resolved to keep-rule " +
                "files at fetch time; spell the literals out or cover the " +
                "package with a plugin overlay (flutter.plugin_overlays)."
            ).format(
                pkg = ctx.attr.package_name,
                gradle = refusal.file,
                stmt = repr(refusal.statement),
            ))
        for relpath in scanned.paths:
            if ctx.path("android/" + relpath).exists:
                paths.append(relpath)
    return paths

def resolve_plugin_maven_deps(ctx, build_file, build_content):
    """Translate the spoke's Android build deps to Bazel labels.

    Reads the spoke's single Gradle build (see `plugin_android_build`;
    `build_file` is its path for messages, `build_content` its text) and
    reduces its runtime dependencies to Maven coordinates
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

    Args:
        ctx: the spoke repository context (attrs, path, exists and read).
        build_file: the spoke-relative Gradle build path, for messages.
        build_content: the text of the spoke's single Gradle build.

    Returns:
        A sorted list of distinct `@rules_android_maven//:...` labels.
    """
    if not build_content:
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

    result = _deps_maven_labels_for_gradle(
        build_content,
        ctx.attr.android_maven_deps,
        ctx.attr.android_maven_ignore,
        _gradle_package_reader(ctx),
        _lex_language_of(build_file),
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
