/// Library-level `@Tags` of a test entrypoint, for the test runners.
///
/// `package:test` reads a suite's `@Tags` off its source with the analyzer
/// (`test_core`'s `parseMetadata`, first directive's metadata only) and hands
/// them to the test isolate in the `RemoteListener` initial message, where
/// they become the root group's metadata and every test inherits them. Under
/// Bazel no analyzer runs at test time, so this tool runs at build time over
/// the test's `main` and writes the tags for the runner to send instead. Only
/// the entrypoint file's own annotations count, as upstream: `@Tags` on files
/// it imports applies to nothing.
///
/// Usage: `extract_library_tags <test.dart> <tags.json>`, writing
/// `{"tags": [...]}` (sorted, so the output bytes are deterministic).
library;

import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln(
      'extract_library_tags: usage: extract_library_tags <test.dart> <tags.json>',
    );
    exit(64);
  }
  late final Set<String> tags;
  try {
    tags = extractLibraryTags(File(args[0]).readAsStringSync());
  } on TagsParseException catch (e) {
    stderr.writeln('extract_library_tags: ${args[0]}:${e.line}: ${e.message}');
    exit(1);
  }
  final sorted = tags.toList()..sort();
  File(args[1]).writeAsStringSync('${json.encode({'tags': sorted})}\n');
}

/// A `@Tags(...)` annotation holding something `test_core`'s `parseMetadata`
/// would not accept, with the 1-based line of the offending construct.
final class TagsParseException implements Exception {
  TagsParseException(this.line, this.message);

  final int line;
  final String message;

  @override
  String toString() => 'line $line: $message';
}

/// The `@Tags` string literals attached to [source]'s first directive, as
/// `test_core`'s `parseMetadata` reads `directives.first.metadata`.
///
/// A hand scanner rather than the analyzer: the tools here cannot import it,
/// and only string lists are of interest. It accepts exactly what upstream
/// accepts — a typed or untyped list literal of plain string literals, with an
/// optional `const`, adjacent and raw strings, trailing commas and comments —
/// and throws [TagsParseException] for anything else in a `@Tags(...)`, as
/// upstream throws `SourceSpanFormatException`: a non-list argument, a
/// non-string element (including one with interpolation, whose value is not
/// constant), or a second `@Tags` annotation.
Set<String> extractLibraryTags(String source) {
  // A script tag (`#!/usr/bin/env dart`) may open the file; the analyzer's
  // scanner skips it before the first directive, so this scan does too.
  var i = 0;
  if (source.startsWith('#!')) {
    final newline = source.indexOf('\n');
    i = newline < 0 ? source.length : newline + 1;
  }
  final found = <String>[];
  var seenTags = false;
  while (true) {
    i = _skipTrivia(source, i);
    if (i >= source.length) return const {};
    if (source[i] == '@') {
      // Upstream rejects a second `@Tags` before reading it.
      if (_isTagsAnnotation(source, i)) {
        if (seenTags) {
          throw TagsParseException(
            _lineOf(source, i),
            'Only a single Tags may be used.',
          );
        }
        seenTags = true;
      }
      final annotation = _parseAnnotation(source, i);
      i = annotation.end;
      found.addAll(annotation.tags);
    } else if (_isDirective(source, i)) {
      // The first directive ends the hunt: annotations after it attach to a
      // later directive, which upstream does not read.
      i = _skipDirective(source, i);
      return found.toSet();
    } else {
      // A declaration before any directive: the file has no directives, so
      // upstream reads no annotations either.
      return const {};
    }
  }
}

/// Whether the annotation at [i] invokes something named `Tags`, as
/// [_parseAnnotation] reads it: a dotted name ending in `Tags` with an argument
/// list.
bool _isTagsAnnotation(String source, int i) {
  final name = _parseDottedName(source, i + 1);
  if (name.segments.isEmpty || name.segments.last != 'Tags') return false;
  final j = _skipTrivia(source, name.end);
  return j < source.length && source[j] == '(';
}

/// The end offset of the annotation at [i] and any `@Tags` strings it carries.
///
/// A `Tags` annotation's argument is parsed strictly by [_parseTagsArgument];
/// anything else is skipped over, strings and comments included.
({int end, List<String> tags}) _parseAnnotation(String source, int i) {
  final name = _parseDottedName(source, i + 1);
  var j = _skipTrivia(source, name.end);
  if (name.segments.isEmpty ||
      name.segments.last != 'Tags' ||
      j >= source.length ||
      source[j] != '(') {
    return (end: _skipAnnotationTail(source, i), tags: const []);
  }
  final argument = _parseTagsArgument(source, j);
  return (end: argument.end, tags: argument.tags);
}

/// The `@Tags(...)` argument list opening at [i] (the `(`) and the tags in it.
///
/// After an optional `const` and optional type arguments (as in
/// `@Tags(<String>['a'])`, still a `ListLiteral` upstream) must come the list
/// of plain string literals. Anything else throws [TagsParseException] with
/// upstream's wording where upstream has words for it (`Expected a List.`,
/// `Expected only literal elements.`, `Expected a String literal.`).
({int end, List<String> tags}) _parseTagsArgument(String source, int i) {
  var j = _skipTrivia(source, i + 1);
  if (_readsKeyword(source, j, 'const')) j = _skipTrivia(source, j + 5);
  if (j < source.length && source[j] == '<') {
    j = _skipTypeArguments(source, j);
  }
  if (j >= source.length || source[j] != '[') {
    throw TagsParseException(_lineOf(source, j), 'Expected a List.');
  }
  final tags = <String>[];
  j++;
  while (true) {
    j = _skipTrivia(source, j);
    if (j >= source.length) {
      throw TagsParseException(
        _lineOf(source, j),
        'Unterminated list in @Tags.',
      );
    }
    if (source[j] == ']') {
      j = _skipTrivia(source, j + 1);
      if (j >= source.length || source[j] != ')') {
        throw TagsParseException(
          _lineOf(source, j),
          'Expected ) to close @Tags.',
        );
      }
      return (end: j + 1, tags: tags);
    }
    if (_readsKeyword(source, j, 'const')) j = _skipTrivia(source, j + 5);
    final literal = _parseString(source, j, strict: true);
    if (literal == null) {
      // Upstream distinguishes collection elements (spreads, `if` and `for`
      // elements) from other non-strings; both are errors here.
      if (source.startsWith('...', j) ||
          _readsKeyword(source, j, 'if') ||
          _readsKeyword(source, j, 'for')) {
        throw TagsParseException(
          _lineOf(source, j),
          'Expected only literal elements.',
        );
      }
      throw TagsParseException(
        _lineOf(source, j),
        'Expected a String literal.',
      );
    }
    tags.add(literal.value);
    j = _skipTrivia(source, literal.end);
    if (j < source.length && source[j] == ',') {
      j++;
    } else if (j >= source.length || source[j] != ']') {
      throw TagsParseException(
        _lineOf(source, j),
        'Expected , or ] in @Tags.',
      );
    }
  }
}

/// Past the `<...>` type arguments opening at [i]. Type arguments hold no
/// directive punctuation, so meeting any — or the end of the file — throws
/// rather than wandering the rest of the file.
int _skipTypeArguments(String source, int i) {
  var depth = 0;
  var j = i;
  while (j < source.length) {
    final c = source[j];
    if (c == '<') {
      depth++;
      j++;
    } else if (c == '>') {
      depth--;
      j++;
      if (depth == 0) return j;
    } else if (c == '/' &&
        j + 1 < source.length &&
        (source[j + 1] == '/' || source[j + 1] == '*')) {
      j = _skipTrivia(source, j);
    } else if (c == "'" ||
        c == '"' ||
        (c == 'r' &&
            j + 1 < source.length &&
            (source[j + 1] == "'" || source[j + 1] == '"'))) {
      final literal = _parseString(source, j);
      j = literal == null ? j + 1 : literal.end;
    } else if (c == ';' ||
        c == '(' ||
        c == ')' ||
        c == '[' ||
        c == ']' ||
        c == '{' ||
        c == '}' ||
        c == '@') {
      throw TagsParseException(
        _lineOf(source, j),
        'Unterminated type arguments in @Tags.',
      );
    } else {
      j++;
    }
  }
  throw TagsParseException(
    _lineOf(source, i),
    'Unterminated type arguments in @Tags.',
  );
}

/// The 1-based line number of [offset] in [source], for error messages.
int _lineOf(String source, int offset) {
  var line = 1;
  final end = offset < source.length ? offset : source.length;
  for (var k = 0; k < end; k++) {
    if (source[k] == '\n') line++;
  }
  return line;
}

/// Whether the word at [i] opens a directive (`library`, `import`, `export`,
/// or `part`), as opposed to a declaration that happens to start with those
/// letters. A directive keyword is never followed by `(`, while a declaration
/// naming a function `import` is.
bool _isDirective(String source, int i) {
  for (final keyword in const ['library', 'import', 'export', 'part']) {
    if (!_readsKeyword(source, i, keyword)) continue;
    var j = _skipTrivia(source, i + keyword.length);
    if (keyword == 'part') {
      // `part of ...;` or `part '...';`; `part(` is a declaration.
      if (_readsKeyword(source, j, 'of')) return true;
      if (j < source.length && (source[j] == "'" || source[j] == '"')) {
        return true;
      }
      return false;
    }
    if (j < source.length && source[j] == '(') return false;
    return true;
  }
  return false;
}

/// Whether [word] sits at [i] with a non-identifier character on each side.
bool _readsKeyword(String source, int i, String word) {
  if (i > 0 && _isIdentifierChar(source[i - 1])) return false;
  if (!source.startsWith(word, i)) return false;
  final after = i + word.length;
  return after >= source.length || !_isIdentifierChar(source[after]);
}

bool _isIdentifierChar(String c) {
  return c == '_' ||
      c == r'$' ||
      (c.compareTo('a') >= 0 && c.compareTo('z') <= 0) ||
      (c.compareTo('A') >= 0 && c.compareTo('Z') <= 0) ||
      (c.compareTo('0') >= 0 && c.compareTo('9') <= 0);
}

/// The dotted name at [i] (`Tags`, or `prefix.Tags`).
({int end, List<String> segments}) _parseDottedName(String source, int i) {
  final segments = <String>[];
  var j = i;
  while (true) {
    final start = j;
    while (j < source.length && _isIdentifierChar(source[j])) {
      j++;
    }
    if (j == start) break;
    segments.add(source.substring(start, j));
    if (j >= source.length || source[j] != '.') break;
    j++;
  }
  return (end: j, segments: segments);
}

/// Past an annotation whose name is not `Tags`: its argument list if it has
/// one, which may hold strings and comments that must not scan as code.
int _skipAnnotationTail(String source, int i) {
  final name = _parseDottedName(source, i + 1);
  var j = _skipTrivia(source, name.end);
  if (j < source.length && source[j] == '(') {
    return _skipBalanced(source, j, '(', ')');
  }
  return j;
}

/// Past the balanced [open]..[close] pair opening at [i], over strings and
/// comments. Past the end when unbalanced.
int _skipBalanced(String source, int i, String open, String close) {
  var depth = 0;
  var j = i;
  while (j < source.length) {
    final c = source[j];
    if (c == open) {
      depth++;
      j++;
    } else if (c == close) {
      depth--;
      j++;
      if (depth == 0) return j;
    } else if (c == '/' &&
        j + 1 < source.length &&
        (source[j + 1] == '/' || source[j + 1] == '*')) {
      j = _skipTrivia(source, j);
    } else if (c == "'" ||
        c == '"' ||
        (c == 'r' &&
            j + 1 < source.length &&
            (source[j + 1] == "'" || source[j + 1] == '"'))) {
      final literal = _parseString(source, j);
      j = literal == null ? j + 1 : literal.end;
    } else {
      j++;
    }
  }
  return j;
}

/// Past the directive opening at [i]: through its `;` at depth zero, over
/// strings, comments and parenthesised configuration (`if (cond) 'uri'`).
int _skipDirective(String source, int i) {
  var depth = 0;
  var j = i;
  while (j < source.length) {
    final c = source[j];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
      j++;
    } else if (c == ')' || c == ']' || c == '}') {
      if (depth > 0) depth--;
      j++;
    } else if (c == ';' && depth == 0) {
      return j + 1;
    } else if (c == '/' &&
        j + 1 < source.length &&
        (source[j + 1] == '/' || source[j + 1] == '*')) {
      j = _skipTrivia(source, j);
    } else if (c == "'" ||
        c == '"' ||
        (c == 'r' &&
            j + 1 < source.length &&
            (source[j + 1] == "'" || source[j + 1] == '"'))) {
      final literal = _parseString(source, j);
      j = literal == null ? j + 1 : literal.end;
    } else {
      j++;
    }
  }
  return j;
}

/// The string literal (with `r` prefix and adjacent concatenation) at [i], or
/// null when none opens there. With [strict], an interpolation throws
/// [TagsParseException]: it has no constant value, so upstream's
/// `parseMetadata` rejects it with `Expected a String literal.` Without it,
/// interpolations are skipped, not evaluated, for scans over code whose
/// strings never become tags.
({int end, String value})? _parseString(
  String source,
  int i, {
  bool strict = false,
}) {
  var j = i;
  var raw = false;
  if (source[j] == 'r') {
    raw = true;
    j++;
  }
  if (j >= source.length || (source[j] != "'" && source[j] != '"')) {
    return null;
  }
  final quote = source[j];
  var triple = false;
  if (source.startsWith(quote * 3, j)) {
    triple = true;
    j += 3;
  } else {
    j++;
  }
  final close = triple ? quote * 3 : quote;
  final value = StringBuffer();
  while (j < source.length) {
    if (source.startsWith(close, j)) {
      j += close.length;
      // Adjacent literals concatenate, as upstream's `_parseString` joins
      // them. The recursive call already folds longer chains, so the string
      // is complete here: returning, not continuing, is what keeps a comma
      // or a following annotation out of the value.
      final next = _skipTrivia(source, j);
      final continued = _parseString(source, next, strict: strict);
      if (continued != null) {
        value.write(continued.value);
        return (end: continued.end, value: value.toString());
      }
      return (end: j, value: value.toString());
    }
    final c = source[j];
    if (!raw && c == r'\') {
      final escape = _parseEscape(source, j);
      value.write(escape.value);
      j = escape.end;
    } else if (!raw && c == r'$') {
      if (strict) {
        throw TagsParseException(
          _lineOf(source, j),
          'Expected a String literal.',
        );
      }
      final interpolation = _skipInterpolation(source, j);
      // A placeholder no tag can equal: the file does not compile, so this
      // value is never compared against a selection.
      value.write('\u{0}');
      j = interpolation;
    } else if (!triple && (c == '\n' || c == '\r')) {
      return null;
    } else {
      value.write(c);
      j++;
    }
  }
  return null;
}

/// The escape opening at [i] (`\` plus its sequence) and the character it
/// stands for. Unknown escapes are kept literally.
({int end, String value}) _parseEscape(String source, int i) {
  final j = i + 1;
  if (j >= source.length) return (end: j, value: r'\');
  final c = source[j];
  switch (c) {
    case 'n':
      return (end: j + 1, value: '\n');
    case 'r':
      return (end: j + 1, value: '\r');
    case 't':
      return (end: j + 1, value: '\t');
    case 'b':
      return (end: j + 1, value: '\b');
    case 'f':
      return (end: j + 1, value: '\f');
    case 'v':
      return (end: j + 1, value: '\v');
    case '0':
      return (end: j + 1, value: '\0');
    case 'x':
      final hex = _parseHex(source, j + 1, 2);
      return (end: hex.end, value: hex.value);
    case 'u':
      if (j + 1 < source.length && source[j + 1] == '{') {
        final end = source.indexOf('}', j + 2);
        if (end < 0) return (end: j + 1, value: 'u');
        final code = int.tryParse(source.substring(j + 2, end), radix: 16);
        if (code == null) return (end: j + 1, value: 'u');
        return (end: end + 1, value: String.fromCharCode(code));
      }
      final hex = _parseHex(source, j + 1, 4);
      return (end: hex.end, value: hex.value);
    default:
      return (end: j + 1, value: c);
  }
}

/// Up to [digits] hex digits at [i] as the character they encode, or a literal
/// read when none follow.
({int end, String value}) _parseHex(String source, int i, int digits) {
  final hex = RegExp(r'^[0-9a-fA-F]+').stringMatch(source.substring(i));
  if (hex == null || hex.isEmpty) return (end: i, value: '');
  final take = hex.length < digits ? hex.length : digits;
  return (
    end: i + take,
    value: String.fromCharCode(int.parse(hex.substring(0, take), radix: 16)),
  );
}

/// Past the `$name` or `${...}` interpolation opening at [i], over nested
/// braces, strings and comments.
int _skipInterpolation(String source, int i) {
  if (i + 1 < source.length && source[i + 1] == '{') {
    return _skipBalanced(source, i + 1, '{', '}');
  }
  var j = i + 1;
  while (j < source.length && _isIdentifierChar(source[j])) {
    j++;
  }
  return j;
}

/// Past whitespace and comments from [i].
int _skipTrivia(String source, int i) {
  var j = i;
  while (j < source.length) {
    final c = source[j];
    if (c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f') {
      j++;
    } else if (c == '/' && j + 1 < source.length && source[j + 1] == '/') {
      final end = source.indexOf('\n', j + 2);
      j = end < 0 ? source.length : end + 1;
    } else if (c == '/' && j + 1 < source.length && source[j + 1] == '*') {
      final end = source.indexOf('*/', j + 2);
      j = end < 0 ? source.length : end + 2;
    } else {
      break;
    }
  }
  return j;
}
