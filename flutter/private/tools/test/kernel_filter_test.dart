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

    test(
      'rewrites staged flutter_web_plugins dart:ui_web imports during compile and restores symlinks',
      () async {
        final externalDir = Directory('${dir.path}/external_repo')
          ..createSync(recursive: true);
        const originalRegistry =
            "import 'dart:ui_web' as ui_web;\n"
            'void register() => ui_web.setPluginHandler((a, b, c) {});\n';
        const originalUrlStrategy =
            "export 'src/navigation_non_web/url_strategy.dart'\n"
            "    if (dart.library.ui_web) 'src/navigation/url_strategy.dart';\n";
        final extRegistry = File('${externalDir.path}/plugin_registry.dart')
          ..writeAsStringSync(originalRegistry);
        final extUrlStrategy = File('${externalDir.path}/url_strategy.dart')
          ..writeAsStringSync(originalUrlStrategy);

        final stageRoot = Directory('${dir.path}/stage')
          ..createSync(recursive: true);
        File(
          '${stageRoot.path}/app/plugin_web_ui_web_stub.dart',
        ).createSync(recursive: true);

        final stagedWebPluginsDir = Directory(
          '${stageRoot.path}/external/deps__flutter_web_plugins/lib/src',
        )..createSync(recursive: true);
        final stagedRegistryPath =
            '${stagedWebPluginsDir.path}/plugin_registry.dart';
        final stagedUrlStrategyPath =
            '${stageRoot.path}/external/deps__flutter_web_plugins/lib/url_strategy.dart';
        Link(stagedRegistryPath).createSync(extRegistry.path);
        Link(stagedUrlStrategyPath).createSync(extUrlStrategy.path);

        final fakeCompiler = File('${dir.path}/fake_compiler.dart')
          ..writeAsStringSync(
            'import "dart:io";\n'
            'void main() {\n'
            '  final reg = File(r"$stagedRegistryPath").readAsStringSync();\n'
            '  final url = File(r"$stagedUrlStrategyPath").readAsStringSync();\n'
            '  stdout.writeln(reg);\n'
            '  stdout.writeln(url);\n'
            '}\n',
          );

        final out = StringBuffer();
        final err = StringBuffer();
        final code = await runFiltered(
          [
            '--',
            Platform.resolvedExecutable,
            fakeCompiler.path,
            '--filesystem-root',
            stageRoot.path,
            '--filesystem-scheme',
            'org-dartlang-app',
          ],
          out,
          err,
        );

        expect(code, 0);
        expect(
          out.toString(),
          contains(
            "import 'org-dartlang-app:///app/plugin_web_ui_web_stub.dart' as ui_web;",
          ),
        );
        expect(out.toString(), contains('if (dart.library.async)'));

        // External target files were never modified and symlinks are restored.
        expect(extRegistry.readAsStringSync(), originalRegistry);
        expect(extUrlStrategy.readAsStringSync(), originalUrlStrategy);
        expect(Link(stagedRegistryPath).existsSync(), isTrue);
        expect(Link(stagedUrlStrategyPath).existsSync(), isTrue);
        expect(File(stagedRegistryPath).readAsStringSync(), originalRegistry);
        expect(
          File(stagedUrlStrategyPath).readAsStringSync(),
          originalUrlStrategy,
        );
      },
    );
  });
}
