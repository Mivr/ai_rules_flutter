"""One Gradle model for a plugin's Android build.

All Gradle-reading helpers live here (lexer, statement walker,
dependency resolution, apply-from, namespace, native-build and
ProGuard detection) so every reader shares one consistent model.
`flutter_pub_package.bzl` loads this file and re-exports the
long-standing entry points (`maven_labels_for_gradle`,
`parse_gradle_android_namespace`).
"""
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

def detect_android_namespace(ctx):
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
def detect_android_native_build(ctx):
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

def detect_consumer_proguard_specs(ctx):
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

def resolve_plugin_maven_deps(ctx):
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
