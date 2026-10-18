@Tags(['runfiles'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../bazel_test_protocol.dart';
import '../flutter_integration_test_runner.dart' as runner;

class _FakePlatformLauncher implements runner.PlatformLauncher {
  _FakePlatformLauncher({required this.onStart});

  final Future<Process> Function(int harnessPort) onStart;
  bool disposed = false;

  @override
  String get platformName => 'web';

  @override
  String get suiteRuntime => 'chrome';

  @override
  String get suiteCompiler => 'dart2js';

  @override
  Future<Process> startTarget(int harnessPort) => onStart(harnessPort);

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  group('buildChromeArguments & buildChromeEnvironment', () {
    test('includes sandbox-safe flags and clears PATH so no host browser can run', () {
      final args = runner.buildChromeArguments(
        url: 'http://127.0.0.1:12345/',
        userDataDir: '/tmp/profile',
      );
      expect(args, contains('--headless'));
      expect(args, contains('--no-sandbox'));
      expect(args, contains('--disable-dev-shm-usage'));
      expect(args.last, 'http://127.0.0.1:12345/');

      final env = runner.buildChromeEnvironment(
        browserBinary: '/runfiles/flutter_chrome_headless_shell/browser/chrome-headless-shell',
        scratchDir: '/tmp/scratch',
        fontconfigFile:
            '/runfiles/flutter_chrome_headless_shell/fonts/fonts.conf',
      );
      expect(env['PATH'], isEmpty);
      expect(
        env['LD_LIBRARY_PATH'],
        '/runfiles/flutter_chrome_headless_shell/browser:'
        '/runfiles/flutter_chrome_headless_shell/sysroot/usr/lib/x86_64-linux-gnu:'
        '/runfiles/flutter_chrome_headless_shell/sysroot/lib/x86_64-linux-gnu',
      );
      expect(
        env['FONTCONFIG_FILE'],
        '/runfiles/flutter_chrome_headless_shell/fonts/fonts.conf',
      );
    });
  });

  group('serveWebBundleRequest', () {
    late Directory tmpDir;
    late HttpServer server;

    setUp(() async {
      tmpDir = Directory.systemTemp.createTempSync('web_bundle_test_');
      Directory('${tmpDir.path}/assets').createSync(recursive: true);
      File('${tmpDir.path}/index.html').writeAsStringSync('<html>ok</html>');
      File('${tmpDir.path}/main.dart.wasm').writeAsBytesSync([0, 97, 115, 109]);
      File('${tmpDir.path}/assets/FontManifest.json').writeAsStringSync('[]');
      File('${tmpDir.path}/Roboto-Regular.ttf').writeAsBytesSync([1, 2, 3, 4]);

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        runner.serveWebBundleRequest(
          req,
          webDir: tmpDir.path,
          robotoFontFile: '${tmpDir.path}/Roboto-Regular.ttf',
        );
      });
    });

    tearDown(() async {
      await server.close(force: true);
      if (tmpDir.existsSync()) {
        tmpDir.deleteSync(recursive: true);
      }
    });

    test(
      'serves index.html, wasm MIME type, and injects local Roboto fallback',
      () async {
        final client = HttpClient();
        try {
          final indexReq = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/'),
          );
          final indexRes = await indexReq.close();
          expect(indexRes.statusCode, HttpStatus.ok);
          expect(
            await utf8.decoder.bind(indexRes).join(),
            '<html>ok</html>',
          );

          final wasmReq = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.port}/main.dart.wasm'),
          );
          final wasmRes = await wasmReq.close();
          expect(wasmRes.statusCode, HttpStatus.ok);
          expect(
            wasmRes.headers.value(HttpHeaders.contentTypeHeader),
            'application/wasm',
          );
          await wasmRes.drain<void>();

          final fontManifestReq = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:${server.port}/assets/FontManifest.json',
            ),
          );
          final fontManifestRes = await fontManifestReq.close();
          final manifestJson = json.decode(
            await utf8.decoder.bind(fontManifestRes).join(),
          ) as List<dynamic>;
          expect(
            manifestJson.any((e) => e is Map && e['family'] == 'Roboto'),
            isTrue,
          );

          final robotoReq = await client.getUrl(
            Uri.parse(
              'http://127.0.0.1:${server.port}/assets/fonts/Roboto-Regular.ttf',
            ),
          );
          final robotoRes = await robotoReq.close();
          expect(robotoRes.statusCode, HttpStatus.ok);
          expect(
            await robotoRes.fold<List<int>>(<int>[], (a, b) => a..addAll(b)),
            [1, 2, 3, 4],
          );
        } finally {
          client.close(force: true);
        }
      },
    );
  });

  group('runIntegrationSuite', () {
    test(
      'reports pass and writes JUnit XML when in-app suite succeeds',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync('integration_xml_');
        final xmlFile = File('${tmpDir.path}/test.xml');
        WebSocket? clientWs;
        try {
          final launcher = _FakePlatformLauncher(
            onStart: (port) async {
              clientWs = await WebSocket.connect(
                'ws://127.0.0.1:$port${runner.integrationWebSocketPath}',
              );
              clientWs!.listen((raw) {
                final list = json.decode(raw as String) as List<dynamic>;
                final id = (list[0] as num).toInt();
                final payload = list[1] as Map<String, dynamic>;
                if (id == 0 && payload['type'] == 'initial') {
                  clientWs!.add(
                    json.encode([
                      0,
                      {
                        'type': 'success',
                        'root': {
                          'type': 'group',
                          'name': '',
                          'entries': [
                            {
                              'type': 'test',
                              'name': 'counter increments to 3',
                              'channel': 2,
                              'metadata': {'skip': false},
                            },
                          ],
                        },
                      },
                    ]),
                  );
                } else if (id == 3 && payload['command'] == 'run') {
                  final replyChannel = (payload['channel'] as num).toInt() + 1;
                  clientWs!.add(
                    json.encode([
                      replyChannel,
                      {'type': 'complete'},
                    ]),
                  );
                }
              });
              return Process.start(Platform.resolvedExecutable, ['--version']);
            },
          );

          final code = await runner.runIntegrationSuite(
            launcher: launcher,
            testPath: 'integration_test/app_test.dart',
            selection: TestSelection(),
            xmlOutput: xmlFile.path,
            bazelTestTimeout: '60',
          );
          expect(code, 0);
          expect(launcher.disposed, isTrue);
          expect(
            xmlFile.readAsStringSync(),
            contains('counter increments to 3'),
          );
        } finally {
          await clientWs?.close();
          if (tmpDir.existsSync()) {
            tmpDir.deleteSync(recursive: true);
          }
        }
      },
    );

    test(
      'fails with non-zero exit and records expected/actual on test failure',
      () async {
        final tmpDir = Directory.systemTemp.createTempSync('integration_fail_');
        final xmlFile = File('${tmpDir.path}/test.xml');
        WebSocket? clientWs;
        try {
          final launcher = _FakePlatformLauncher(
            onStart: (port) async {
              clientWs = await WebSocket.connect(
                'ws://127.0.0.1:$port${runner.integrationWebSocketPath}',
              );
              clientWs!.listen((raw) {
                final list = json.decode(raw as String) as List<dynamic>;
                final id = (list[0] as num).toInt();
                final payload = list[1] as Map<String, dynamic>;
                if (id == 0 && payload['type'] == 'initial') {
                  clientWs!.add(
                    json.encode([
                      0,
                      {
                        'type': 'success',
                        'root': {
                          'type': 'group',
                          'name': '',
                          'entries': [
                            {
                              'type': 'test',
                              'name': 'counter increments to 3',
                              'channel': 2,
                              'metadata': {'skip': false},
                            },
                          ],
                        },
                      },
                    ]),
                  );
                } else if (id == 3 && payload['command'] == 'run') {
                  final replyChannel = (payload['channel'] as num).toInt() + 1;
                  clientWs!.add(
                    json.encode([
                      replyChannel,
                      {
                        'type': 'error',
                        'error': {
                          'type': 'TestFailure',
                          'message': "Expected: '3'\n  Actual: '2'",
                          'stackChain': 'test/app_test.dart 15:5',
                        },
                      },
                    ]),
                  );
                  clientWs!.add(
                    json.encode([
                      replyChannel,
                      {'type': 'complete'},
                    ]),
                  );
                }
              });
              return Process.start(Platform.resolvedExecutable, ['--version']);
            },
          );

          final code = await runner.runIntegrationSuite(
            launcher: launcher,
            testPath: 'integration_test/app_test.dart',
            selection: TestSelection(),
            xmlOutput: xmlFile.path,
            bazelTestTimeout: '60',
          );
          expect(code, 1);
          final xml = xmlFile.readAsStringSync();
          expect(xml, contains('counter increments to 3'));
          expect(xml, contains("Expected: '3'"));
          expect(xml, contains("Actual: '2'"));
        } finally {
          await clientWs?.close();
          if (tmpDir.existsSync()) {
            tmpDir.deleteSync(recursive: true);
          }
        }
      },
    );
  });
}
