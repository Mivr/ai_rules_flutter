// Library-level `@Tags` extraction for the test runners.
import 'package:test/test.dart';

import '../extract_library_tags.dart';

void main() {
  group('extractLibraryTags', () {
    test('reads tags off the first directive', () {
      expect(
        extractLibraryTags(
          "@Tags(['golden', 'slow'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          '\n'
          'void main() {}\n',
        ),
        {'golden', 'slow'},
      );
    });

    test('reads tags off a library directive', () {
      expect(
        extractLibraryTags(
          "@Tags(['golden'])\n"
          'library;\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('a file without tags has none', () {
      expect(
        extractLibraryTags(
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('annotations after the first directive do not count', () {
      expect(
        extractLibraryTags(
          "import 'package:flutter_test/flutter_test.dart';\n"
          "@Tags(['golden'])\n"
          "import 'package:test/test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('annotations on declarations do not count', () {
      expect(
        extractLibraryTags(
          "import 'package:flutter_test/flutter_test.dart';\n"
          "@Tags(['golden'])\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('reads prefixed tags and const lists with trailing commas', () {
      expect(
        extractLibraryTags(
          "@test.Tags(const ['golden',])\n"
          "import 'package:flutter_test/flutter_test.dart' as test;\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('ignores other annotations', () {
      expect(
        extractLibraryTags(
          "@TestOn('vm')\n"
          "@Tags(['golden'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('ignores tags hidden in comments and strings', () {
      expect(
        extractLibraryTags(
          "// @Tags(['comment'])\n"
          "/* @Tags(['comment']) */\n"
          "import 'package:flutter_test/flutter_test.dart'; // @Tags(['comment'])\n"
          "const marker = \"@Tags(['string'])\";\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('skips directives with configurations and combinators', () {
      expect(
        extractLibraryTags(
          "@Tags(['golden'])\n"
          "import 'a.dart' if (dart.library.io) 'b.dart' show a hide b;\n"
          'void main() {}\n',
        ),
        {'golden'},
      );
    });

    test('concatenates adjacent strings and unescapes', () {
      expect(
        extractLibraryTags(
          "@Tags(['gol' 'den', 's\\\\low', 'sp ace'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'golden', r's\low', 'sp ace'},
      );
    });

    test('a declaration before any directive means no directives', () {
      expect(extractLibraryTags('void main() {}\n'), isEmpty);
    });

    test('an empty file has no tags', () {
      expect(extractLibraryTags(''), isEmpty);
    });

    test('reads a typed list literal', () {
      expect(
        extractLibraryTags(
          "@Tags(<String>['a', 'b'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'a', 'b'},
      );
    });

    test('reads a const typed list literal', () {
      expect(
        extractLibraryTags(
          "@Tags(const <String>['a'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        {'a'},
      );
    });

    test('reads tags after a script tag', () {
      expect(
        extractLibraryTags(
          '#!/usr/bin/env dart\n'
          "@Tags(['she'])\n"
          'library;\n'
          'void main() {}\n',
        ),
        {'she'},
      );
    });

    test('an empty list has no tags', () {
      expect(
        extractLibraryTags(
          '@Tags([])\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        isEmpty,
      );
    });

    test('a const identifier argument is an error, not an empty result', () {
      expect(
        () => extractLibraryTags(
          '@Tags(kTags)\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>()
              .having((e) => e.line, 'line', 1)
              .having((e) => e.message, 'message', 'Expected a List.'),
        ),
      );
    });

    test('an interpolated element is an error', () {
      expect(
        () => extractLibraryTags(
          r"@Tags(['a${1}'])"
          '\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>()
              .having((e) => e.line, 'line', 1)
              .having(
                (e) => e.message,
                'message',
                'Expected a String literal.',
              ),
        ),
      );
      expect(
        () => extractLibraryTags(
          r"@Tags(['a$b'])"
          '\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(isA<TagsParseException>()),
      );
    });

    test('a non-string element is an error', () {
      expect(
        () => extractLibraryTags(
          '@Tags([42])\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having(
            (e) => e.message,
            'message',
            'Expected a String literal.',
          ),
        ),
      );
    });

    test('a set literal argument is an error', () {
      expect(
        () => extractLibraryTags(
          "@Tags(const {'a'})\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having(
            (e) => e.message,
            'message',
            'Expected a List.',
          ),
        ),
      );
    });

    test('a spread element is an error', () {
      expect(
        () => extractLibraryTags(
          '@Tags([...kTags])\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having(
            (e) => e.message,
            'message',
            'Expected only literal elements.',
          ),
        ),
      );
    });

    test('a second Tags annotation is an error', () {
      expect(
        () => extractLibraryTags(
          "@Tags(['a'])\n"
          "@Tags(['b'])\n"
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>()
              .having((e) => e.line, 'line', 2)
              .having(
                (e) => e.message,
                'message',
                'Only a single Tags may be used.',
              ),
        ),
      );
    });

    test('the error names the line of the bad annotation', () {
      expect(
        () => extractLibraryTags(
          "@TestOn('vm')\n"
          '// a comment\n'
          '@Tags(kTags)\n'
          "import 'package:flutter_test/flutter_test.dart';\n"
          'void main() {}\n',
        ),
        throwsA(
          isA<TagsParseException>().having((e) => e.line, 'line', 3),
        ),
      );
    });
  });
}
