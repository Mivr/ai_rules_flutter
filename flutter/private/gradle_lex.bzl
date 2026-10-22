"""Groovy / Kotlin-DSL Gradle lexer shared by every plugin-build reader.

States mirror the historical single-file lexer one-to-one for every input
it modelled (0 code, 1/2 comments at depth 0, 3/4 short strings, 5/6
triple-quoted strings, 7/8 comments inside brackets), so statements split
exactly where they always did. Three states cover what it missed:

- 9, Groovy slashy strings (`/.../`, contextual: after `= ( , [ :`,
  `return`, or at statement start — anywhere else `/` is division);
- 10, Groovy dollar-slashy strings (`$/.../$`, closed by the first
  `/$`, with the `$$` escape, spanning lines like brackets do);
- 11/12, Kotlin nested block comments (`.kts` only; Groovy block
  comments do not nest).

Literals splice whole into the pending statement, so comment openers and
braces inside them never split the model. An unterminated short string
flushes at its newline; an unterminated slashy pours back as code text;
a trailing unbalanced bracket emits an `unbalanced` event, reported
unreadable downstream and never silently ignored.
"""

def gradle_language_of(path):
    """The Gradle dialect from a build-file path: `"kotlin"` or `"groovy"`."""
    if path.endswith(".kts"):
        return "kotlin"
    return "groovy"

def _gradle_flush(events, buf, kind):
    """Move `buf`'s text into `events` as `kind` and clear `buf`."""
    text = "".join(buf)
    for _ in range(len(buf)):
        buf.pop()
    text = text.strip()
    if text or kind == "open":
        events.append(struct(kind = kind, text = text))

def _gradle_comment_state(language, two, depth):
    """The comment state for an opener at bracket depth `depth`."""
    if two == "//":
        if depth > 0:
            return 7
        return 1
    if language == "kotlin":
        if depth > 0:
            return 12
        return 11
    if depth > 0:
        return 8
    return 2

def _gradle_slashy_opens(buf):
    """True when a `/` in code opens a slashy string, not division."""
    i = len(buf) - 1
    for _ in range(len(buf)):
        if i < 0:
            break
        c = buf[i]
        if c == " " or c == "\t" or c == "\r":
            i -= 1
        else:
            break
    if i < 0:
        return True
    c = buf[i]
    if c == "=" or c == "(" or c == "[" or c == ":" or c == ",":
        return True
    word = []
    for _ in range(len(buf)):
        if i < 0:
            break
        c = buf[i]
        if ("a" <= c and c <= "z") or ("A" <= c and c <= "Z") or c == "_":
            word.append(c)
            i -= 1
        else:
            break
    return "".join(word) == "nruter"

def _gradle_code_step(content, i, buf, events, depth, language):
    """Lex one code-state character; return `(state, next_i, depth)`."""
    two = content[i:i + 2]
    if two == "//" or two == "/*":
        state = _gradle_comment_state(language, two, depth)
        if state == 1:
            _gradle_flush(events, buf, "stmt")
            return (1, i + 2, depth)
        return (state, i + 2, depth)
    c = content[i:i + 1]
    if c == "$" and content[i + 1:i + 2] == "/":
        buf.append("$")
        buf.append("/")
        return (10, i + 2, depth)
    if c == "/" and _gradle_slashy_opens(buf):
        buf.append(c)
        return (9, i + 1, depth)
    if c == "'" or c == '"':
        return _gradle_string_open(content, i, buf, depth)
    if c == "(" or c == "[":
        buf.append(c)
        return (0, i + 1, depth + 1)
    if c == ")" or c == "]":
        buf.append(c)
        if depth > 0:
            depth -= 1
        return (0, i + 1, depth)
    if c == "\n" or c == ";" or c == "\r":
        if depth > 0:
            buf.append(" ")
            return (0, i + 1, depth)
        _gradle_flush(events, buf, "stmt")
        return (0, i + 1, depth)
    if c == "{":
        _gradle_flush(events, buf, "open")
        return (0, i + 1, depth)
    if c == "}":
        _gradle_flush(events, buf, "stmt")
        events.append(struct(kind = "close", text = ""))
        return (0, i + 1, depth)
    buf.append(c)
    return (0, i + 1, depth)

def _gradle_string_open(content, i, buf, depth):
    """Enter the string state for the quote at `i`; return `(state, next_i, depth)`."""
    if content[i:i + 3] == "'''":
        buf.extend(["'", "'", "'"])
        return (5, i + 3, depth)
    if content[i:i + 3] == '"""':
        buf.extend(['"', '"', '"'])
        return (6, i + 3, depth)
    c = content[i:i + 1]
    buf.append(c)
    if c == "'":
        return (3, i + 1, depth)
    return (4, i + 1, depth)

def _gradle_short_string_step(content, n, i, buf, events, quote):
    """Lex one char inside a single-line string; return `(state, next_i)`."""
    c = content[i:i + 1]
    buf.append(c)
    if c == "\\" and i + 1 < n:
        buf.append(content[i + 1:i + 2])
        return (3 if quote == "'" else 4, i + 2)
    if c == quote:
        return (0, i + 1)
    if c == "\n":
        _gradle_flush(events, buf, "stmt")
        return (0, i + 1)
    return (3 if quote == "'" else 4, i + 1)

def _gradle_long_string_step(content, n, i, buf, quote3):
    """Lex one char inside a triple-quoted string; return `(state, next_i)`."""
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

def _gradle_slashy_step(content, n, i, splice):
    """Lex one char inside a `/.../` string; return `(state, next_i, pour)`."""
    c = content[i:i + 1]
    splice.append(c)
    if c == "\\" and i + 1 < n:
        splice.append(content[i + 1:i + 2])
        return (9, i + 2, False)
    if c == "/":
        return (0, i + 1, False)
    if c == "\n":
        return (0, i, True)
    return (9, i + 1, False)

def _gradle_dollar_slashy_step(content, i, splice):
    """Lex one char inside a `$/.../$` string; return `(state, next_i)`."""
    c = content[i:i + 1]
    if c == "/" and content[i + 1:i + 2] == "$":
        splice.append(c)
        splice.append("$")
        return (0, i + 2)
    if c == "$" and content[i + 1:i + 2] == "$":
        splice.append("$")
        splice.append("$")
        return (10, i + 2)
    splice.append(c)
    if c == "\n":
        splice[len(splice) - 1] = " "
    return (10, i + 1)

def _gradle_nested_comment_step(content, i, nest, spaced):
    """Lex one char of a Kotlin nested comment; return `(state, next_i, nest)`."""
    two = content[i:i + 2]
    if two == "/*":
        return (12 if spaced else 11, i + 2, nest + 1)
    if two == "*/":
        if nest <= 1:
            return (0, i + 2, 0)
        return (12 if spaced else 11, i + 2, nest - 1)
    return (12 if spaced else 11, i + 1, nest)

def _gradle_splice_commit(buf, splice):
    """Move a closed literal splice into `buf` and clear `splice`."""
    buf.extend(splice)
    for _ in range(len(splice)):
        splice.pop()

def _gradle_lex_events(content, language, events, buf, splice):
    """Run the lexer states over `content`; return the end-of-input state."""
    n = len(content)
    state = 0
    depth = 0
    nest = 0
    spaced = False
    i = 0
    for _ in range(n + 2):
        if i >= n:
            break
        c = content[i:i + 1]
        two = content[i:i + 2]
        if state == 0:
            (state, i, depth) = _gradle_code_step(content, i, buf, events, depth, language)
            if state == 11 or state == 12:
                nest = 1
                spaced = state == 12
        elif state == 1:
            if c == "\n":
                _gradle_flush(events, buf, "stmt")
                state = 0
            i += 1
        elif state == 2:
            if two == "*/":
                state = 0
                i += 2
            else:
                i += 1
        elif state == 3:
            (state, i) = _gradle_short_string_step(content, n, i, buf, events, "'")
        elif state == 4:
            (state, i) = _gradle_short_string_step(content, n, i, buf, events, '"')
        elif state == 5:
            (state, i) = _gradle_long_string_step(content, n, i, buf, "'''")
        elif state == 6:
            (state, i) = _gradle_long_string_step(content, n, i, buf, '"""')
        elif state == 7:
            if c == "\n":
                buf.append(" ")
                state = 0
            i += 1
        elif state == 8:
            if two == "*/":
                buf.append(" ")
                state = 0
                i += 2
            else:
                i += 1
        elif state == 9:
            (state, ni, pour) = _gradle_slashy_step(content, n, i, splice)
            if pour:
                _gradle_splice_commit(buf, splice)
            elif state == 0:
                _gradle_splice_commit(buf, splice)
            i = ni
        elif state == 10:
            (state, ni) = _gradle_dollar_slashy_step(content, i, splice)
            if state == 0:
                _gradle_splice_commit(buf, splice)
            i = ni
        else:
            (state, ni, nest) = _gradle_nested_comment_step(content, i, nest, spaced)
            if state == 0 and spaced:
                buf.append(" ")
            i = ni
    if splice:
        _gradle_splice_commit(buf, splice)
    return (state, depth)

def gradle_lex(content, language = "groovy"):
    """Split Gradle script text into statement and brace events.

    String-aware: `//` and `/* */` comments drop only outside literals
    (single-, double-, triple-quoted, slashy and dollar-slashy), and
    newlines, `;`, `{` and `}` split statements only outside literals. A
    backslash escapes the next character inside short, long and slashy
    strings. Kotlin block comments nest; Groovy ones do not.

    Bracket-aware: newlines, `;` and `\\r` inside `(...)` / `[...]` are
    layout, so a parenthesised call spanning lines lexes as one statement.
    Statements end at a newline or `;` at bracket depth 0, and at `{` /
    `}`. An unbalanced bracket at end of input emits an `unbalanced`
    event, reported unreadable downstream and never silently ignored.

    Args:
        content: The Gradle build-file or applied-script text.
        language: `"groovy"` or `"kotlin"`, from the file extension.

    Returns:
        A list of structs: `struct(kind = "stmt", text)` for statements,
        `struct(kind = "open", text)` for a block header (the text before
        `{`), `struct(kind = "close", text = "")` for a block end, and
        `struct(kind = "unbalanced", text)` for a trailing unbalanced
        bracket fragment.
    """
    events = []
    buf = []
    splice = []
    (_, depth) = _gradle_lex_events(content, language, events, buf, splice)
    if depth > 0:
        _gradle_flush(events, buf, "unbalanced")
        if len(events) == 0 or events[len(events) - 1].kind != "unbalanced":
            events.append(struct(kind = "unbalanced", text = "unbalanced bracket"))
    else:
        _gradle_flush(events, buf, "stmt")
    return events
