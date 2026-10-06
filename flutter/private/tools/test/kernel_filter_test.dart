import 'dart:io';

import 'package:test/test.dart';

import '../kernel_filter.dart';

const _id = '53d4fd45-0cd8-4542-bca7-7ba7c9385b70';

void main() {
  group('isBoundaryLine', () {
    test('matches the three lines frontend_server frames a compile with', () {
      expect(isBoundaryLine('result $_id'), isTrue);
      expect(isBoundaryLine(_id), isTrue);
      expect(
        isBoundaryLine('$_id bazel-out/x y/bin/app_flutter.dill 0'),
        isTrue,
      );
    });

    test('keeps everything else', () {
      expect(isBoundaryLine(''), isFalse);
      expect(
        isBoundaryLine('lib/main.dart:3:5: Error: Expected `;`.'),
        isFalse,
      );
      expect(isBoundaryLine('result'), isFalse);
      expect(isBoundaryLine('result $_id extra'), isFalse);
      expect(isBoundaryLine('see $_id'), isFalse);
      expect(isBoundaryLine('$_id out.dill'), isFalse);
    });
  });

  group('runFiltered', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('kernel_filter_'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<({int code, String out, String err})> run(
      String stdoutText,
      int exitCode,
    ) async {
      final script = File('${dir.path}/fake.dart')
        ..writeAsStringSync(
          'import "dart:io";\n'
          'void main() {\n'
          '  stdout.write(r"""$stdoutText""");\n'
          '  stderr.writeln("to stderr");\n'
          '  exit($exitCode);\n'
          '}\n',
        );
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runFiltered(
        ['--', Platform.resolvedExecutable, script.path],
        out,
        err,
      );
      return (code: code, out: '$out', err: '$err');
    }

    test('a successful compile prints nothing', () async {
      final r = await run(
        'result $_id\n$_id\n$_id app_flutter.dill 0\n',
        0,
      );
      expect(r.code, 0);
      expect(r.out.trim(), isEmpty);
    });

    test('a compile error still shows, with its exit code', () async {
      const error = 'lib/main.dart:3:5: Error: Expected `;` after this.';
      final r = await run(
        'result $_id\n$_id\n$error\n$_id app_flutter.dill 1\n',
        1,
      );
      expect(r.code, 1);
      expect(r.out, contains(error));
      expect(r.out, isNot(contains(_id)));
      expect(r.err, contains('to stderr'));
    });

    test('refuses a call with no command', () async {
      final err = StringBuffer();
      expect(await runFiltered(['--'], StringBuffer(), err), 2);
      expect(err.toString(), contains('Usage'));
    });
  });
}
