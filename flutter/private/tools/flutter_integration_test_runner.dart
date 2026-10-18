/// Bazel-side driver for `flutter_integration_test`.
///
/// Launches a built Flutter application on the target platform (starting with
/// `web`, designed so `linux` and `android` share the harness), hosts a
/// localhost WebSocket + HTTP server, and drives the in-app `RemoteListener`
/// suite compiled into the application entrypoint.
///
/// Fails (exits non-zero) on:
/// - any test expectation failure (printing test name, expected, and actual),
/// - any uncaught Dart/Flutter/JS error,
/// - browser or target process crash / unexpected exit,
/// - dial-back or per-test timeout.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';

import 'bazel_test_protocol.dart';

/// WebSocket upgrade path the in-app bootstrap dials on the harness server.
const String integrationWebSocketPath = '/__flutter_integration_ws__';

void main(List<String> args) async {
  if (args.isNotEmpty) {
    stderr.writeln(
      'flutter_integration_test runner: unrecognised arguments: '
      '${args.join(" ")}',
    );
    exit(64);
  }

  final r = Runfiles.create();
  final platform =
      Platform.environment['FLUTTER_INTEGRATION_TEST_PLATFORM'] ?? 'web';
  final testPath =
      Platform.environment['FLUTTER_INTEGRATION_TEST_PATH'] ??
      'integration_test.dart';

  final TestSelection selection;
  try {
    selection = TestSelection.fromEnvironment(Platform.environment);
  } on FormatException catch (e) {
    stderr.writeln('flutter_integration_test runner: ${e.message}');
    exit(64);
  }

  final shardStatus = Platform.environment['TEST_SHARD_STATUS_FILE'];
  if (shardStatus != null) {
    File(shardStatus).writeAsStringSync('');
  }

  final PlatformLauncher launcher;
  try {
    launcher = createPlatformLauncher(platform, Platform.environment, r);
  } on FormatException catch (e) {
    stderr.writeln('flutter_integration_test runner: ${e.message}');
    exit(64);
  }

  exitCode = await runIntegrationSuite(
    launcher: launcher,
    testPath: testPath,
    selection: selection,
    xmlOutput: Platform.environment['XML_OUTPUT_FILE'],
    bazelTestTimeout: Platform.environment['TEST_TIMEOUT'],
  );
}

/// Creates the [PlatformLauncher] for [platform] from environment variables.
PlatformLauncher createPlatformLauncher(
  String platform,
  Map<String, String> env,
  Runfiles r,
) {
  switch (platform) {
    case 'web':
      final webDirKey = env['FLUTTER_INTEGRATION_TEST_WEB_DIR'];
      final browserKey = env['FLUTTER_INTEGRATION_TEST_BROWSER'];
      final fontconfigKey = env['FLUTTER_INTEGRATION_TEST_FONTCONFIG'];
      if (webDirKey == null || webDirKey.isEmpty) {
        throw const FormatException(
          'FLUTTER_INTEGRATION_TEST_WEB_DIR must be set for platform="web".',
        );
      }
      if (browserKey == null || browserKey.isEmpty) {
        throw const FormatException(
          'FLUTTER_INTEGRATION_TEST_BROWSER must be set for platform="web".',
        );
      }
      final webDir = r.rlocation(webDirKey);
      final browserBinary = r.rlocation(browserKey);
      final fontconfigFile = (fontconfigKey == null || fontconfigKey.isEmpty)
          ? null
          : r.rlocation(fontconfigKey);
      final robotoKey = env['FLUTTER_INTEGRATION_TEST_ROBOTO_FONT'];
      final robotoFont = (robotoKey == null || robotoKey.isEmpty)
          ? null
          : r.rlocation(robotoKey);
      return WebPlatformLauncher(
        webDir: webDir,
        browserBinary: browserBinary,
        fontconfigFile: fontconfigFile,
        robotoFontFile: robotoFont,
        baseTempDir: env['TEST_TMPDIR'] ?? Directory.systemTemp.path,
      );
    default:
      throw FormatException(
        'Unsupported integration test platform "$platform". '
        'Supported platforms: web.',
      );
  }
}

/// Per-test timeout ceiling inside Bazel's outer `TEST_TIMEOUT`.
Duration testCeiling(String? bazelTestTimeout) {
  final seconds = int.tryParse(bazelTestTimeout ?? '');
  if (seconds == null || seconds <= 0) return const Duration(minutes: 5);
  final margin = seconds ~/ 20;
  return Duration(seconds: seconds - (margin < 10 ? 10 : margin));
}

/// Suite default timeout serialized as `package:test_api` `Metadata` expects.
Object suiteTimeout(String? bazelTestTimeout) {
  final seconds = int.tryParse(bazelTestTimeout ?? '');
  if (seconds == null || seconds <= 0) return 'none';
  return {
    'duration': Duration(seconds: seconds).inMicroseconds,
    'scaleFactor': null,
  };
}

/// Builds the command-line flags passed to the hermetic `chrome-headless-shell`.
List<String> buildChromeArguments({
  required String url,
  required String userDataDir,
}) {
  return <String>[
    '--headless',
    '--no-sandbox',
    '--disable-dev-shm-usage',
    '--disable-gpu',
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-background-networking',
    '--disable-extensions',
    '--disable-sync',
    '--disable-translate',
    '--metrics-recording-only',
    '--mute-audio',
    '--window-size=800,600',
    '--user-data-dir=$userDataDir',
    url,
  ];
}

/// Builds the hermetic environment for `chrome-headless-shell`.
///
/// Clears `PATH` so no host browser or binary on `PATH` can ever be invoked,
/// and sets `LD_LIBRARY_PATH` exclusively to the pinned runtime library
/// directories in runfiles.
Map<String, String> buildChromeEnvironment({
  required String browserBinary,
  required String scratchDir,
  String? fontconfigFile,
}) {
  final browserFile = File(browserBinary);
  final browserDir = browserFile.parent.path;
  final repoRoot = browserFile.parent.parent.path;
  final libDirs = <String>[
    browserDir,
    '$repoRoot/sysroot/usr/lib/x86_64-linux-gnu',
    '$repoRoot/sysroot/lib/x86_64-linux-gnu',
  ];

  return <String, String>{
    'PATH': '',
    'LD_LIBRARY_PATH': libDirs.join(':'),
    'HOME': scratchDir,
    'TMPDIR': scratchDir,
    'XDG_CONFIG_HOME': '$scratchDir/.config',
    'XDG_CACHE_HOME': '$scratchDir/.cache',
    if (fontconfigFile != null) ...{
      'FONTCONFIG_FILE': fontconfigFile,
      'FONTCONFIG_PATH': File(fontconfigFile).parent.path,
    },
  };
}

/// Abstraction over how a target platform starts the compiled app and serves
/// any platform-specific HTTP endpoints on the harness [HttpServer].
abstract class PlatformLauncher {
  /// Platform identifier (`'web'`, `'linux'`, `'android'`).
  String get platformName;

  /// Runtime identifier for `package:test_api` `SuitePlatform`.
  String get suiteRuntime;

  /// Compiler identifier for `package:test_api` `SuitePlatform`.
  String get suiteCompiler;

  /// Handles a non-WebSocket HTTP request arriving on the harness server.
  Future<void> handleHttpRequest(HttpRequest request);

  /// Starts the target process against a harness listening on [harnessPort].
  Future<Process> startTarget(int harnessPort);

  /// Cleans up any temporary directories created for the target process.
  Future<void> dispose();
}

/// Launches the built Flutter web bundle in the pinned `chrome-headless-shell`
/// and serves the bundle over localhost HTTP.
class WebPlatformLauncher implements PlatformLauncher {
  WebPlatformLauncher({
    required this.webDir,
    required this.browserBinary,
    required this.baseTempDir,
    this.fontconfigFile,
    this.robotoFontFile,
  });

  final String webDir;
  final String browserBinary;
  final String baseTempDir;
  final String? fontconfigFile;
  final String? robotoFontFile;

  Directory? _scratchDir;

  @override
  String get platformName => 'web';

  @override
  String get suiteRuntime => 'chrome';

  @override
  String get suiteCompiler => 'dart2js';

  @override
  Future<Process> startTarget(int harnessPort) async {
    if (!File(browserBinary).existsSync()) {
      throw StateError(
        'Pinned chrome-headless-shell binary not found at "$browserBinary".',
      );
    }
    if (!Directory(webDir).existsSync()) {
      throw StateError('Built web bundle directory not found at "$webDir".');
    }

    final scratch = Directory(
      '$baseTempDir/chrome_integration_${pid}_${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    _scratchDir = scratch;
    final userDataDir = Directory('${scratch.path}/profile')
      ..createSync(recursive: true);
    Directory('${scratch.path}/.config').createSync(recursive: true);
    Directory('${scratch.path}/.cache').createSync(recursive: true);
    Directory('${scratch.path}/fontconfig-cache').createSync(recursive: true);

    final url = 'http://127.0.0.1:$harnessPort/';
    final args = buildChromeArguments(
      url: url,
      userDataDir: userDataDir.path,
    );
    final env = buildChromeEnvironment(
      browserBinary: browserBinary,
      scratchDir: scratch.path,
      fontconfigFile: fontconfigFile,
    );

    return Process.start(
      browserBinary,
      args,
      environment: env,
      includeParentEnvironment: false,
    );
  }

  @override
  Future<void> handleHttpRequest(HttpRequest request) async {
    await serveWebBundleRequest(
      request,
      webDir: webDir,
      robotoFontFile: robotoFontFile,
    );
  }

  @override
  Future<void> dispose() async {
    final dir = _scratchDir;
    _scratchDir = null;
    if (dir != null && dir.existsSync()) {
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    }
  }
}

/// Serves a single static file request from [webDir].
///
/// Injects a local `Roboto` fallback entry into `assets/FontManifest.json` when
/// [robotoFontFile] is provided and the app's manifest does not already define
/// `Roboto`, so CanvasKit and Skwasm never attempt to fetch Roboto from
/// `fonts.gstatic.com` inside the network-isolated Bazel test sandbox.
Future<void> serveWebBundleRequest(
  HttpRequest request, {
  required String webDir,
  String? robotoFontFile,
}) async {
  final response = request.response;
  try {
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    var relPath = Uri.decodeComponent(request.uri.path);
    if (relPath == '/' || relPath.isEmpty) {
      relPath = 'index.html';
    } else if (relPath.startsWith('/')) {
      relPath = relPath.substring(1);
    }

    final segments = relPath.split('/');
    if (segments.contains('..') || segments.contains('.')) {
      response.statusCode = HttpStatus.forbidden;
      await response.close();
      return;
    }

    if (relPath == 'assets/FontManifest.json' &&
        robotoFontFile != null &&
        File(robotoFontFile).existsSync()) {
      final manifestFile = File('$webDir/assets/FontManifest.json');
      List<dynamic> families = <dynamic>[];
      if (manifestFile.existsSync()) {
        final decoded = json.decode(manifestFile.readAsStringSync());
        if (decoded is List) {
          families = List<dynamic>.from(decoded);
        }
      }
      final hasRoboto = families.any(
        (entry) => entry is Map && entry['family'] == 'Roboto',
      );
      if (!hasRoboto) {
        families.add(<String, Object>{
          'family': 'Roboto',
          'fonts': <Map<String, String>>[
            <String, String>{'asset': 'fonts/Roboto-Regular.ttf'},
          ],
        });
      }
      final body = utf8.encode(json.encode(families));
      response.statusCode = HttpStatus.ok;
      response.headers.set(
        HttpHeaders.contentTypeHeader,
        'application/json; charset=utf-8',
      );
      response.headers.contentLength = body.length;
      if (request.method != 'HEAD') {
        response.add(body);
      }
      await response.close();
      return;
    }

    var file = File('$webDir/$relPath');
    if (!file.existsSync() &&
        relPath == 'assets/fonts/Roboto-Regular.ttf' &&
        robotoFontFile != null) {
      file = File(robotoFontFile);
    }

    if (!file.existsSync()) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }

    final bytes = file.readAsBytesSync();
    response.statusCode = HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      contentTypeForPath(relPath),
    );
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.headers.contentLength = bytes.length;
    if (request.method != 'HEAD') {
      response.add(bytes);
    }
    await response.close();
  } catch (_) {
    try {
      response.statusCode = HttpStatus.internalServerError;
      await response.close();
    } catch (_) {}
  }
}

/// MIME type for a served bundle asset path.
String contentTypeForPath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.html')) return 'text/html; charset=utf-8';
  if (lower.endsWith('.js') || lower.endsWith('.mjs')) {
    return 'application/javascript; charset=utf-8';
  }
  if (lower.endsWith('.wasm')) return 'application/wasm';
  if (lower.endsWith('.json')) return 'application/json; charset=utf-8';
  if (lower.endsWith('.css')) return 'text/css; charset=utf-8';
  if (lower.endsWith('.png')) return 'image/png';
  if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
  if (lower.endsWith('.gif')) return 'image/gif';
  if (lower.endsWith('.svg')) return 'image/svg+xml';
  if (lower.endsWith('.ttf')) return 'font/ttf';
  if (lower.endsWith('.otf')) return 'font/otf';
  if (lower.endsWith('.woff2')) return 'font/woff2';
  return 'application/octet-stream';
}

/// Runs the integration test suite end-to-end using [launcher].
Future<int> runIntegrationSuite({
  required PlatformLauncher launcher,
  required String testPath,
  required TestSelection selection,
  required String? xmlOutput,
  required String? bazelTestTimeout,
  Duration dialBackBound = const Duration(seconds: 45),
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final harness = _IntegrationHarness(
    server: server,
    launcher: launcher,
    dialBackBound: dialBackBound,
  );
  try {
    return await harness.run(
      testPath: testPath,
      selection: selection,
      xmlOutput: xmlOutput,
      bazelTestTimeout: bazelTestTimeout,
    );
  } finally {
    await harness.dispose();
  }
}

class _IntegrationHarness {
  _IntegrationHarness({
    required HttpServer server,
    required PlatformLauncher launcher,
    required Duration dialBackBound,
  }) : _server = server,
       _launcher = launcher,
       _dialBackBound = dialBackBound;

  final HttpServer _server;
  final PlatformLauncher _launcher;
  final Duration _dialBackBound;

  Process? _process;
  WebSocket? _ws;
  bool _socketClosed = false;
  StreamSubscription<HttpRequest>? _httpSub;
  final Completer<WebSocket> _wsConnected = Completer<WebSocket>();

  final Map<int, void Function(Object?)> _inbound = {};
  final Map<int, Completer<void>> _pendingTests = {};
  int _nextId = 1;

  ({int outputId, int inputId}) _allocChannel() {
    final out = _nextId;
    final inp = _nextId + 1;
    _nextId += 2;
    return (outputId: out, inputId: inp);
  }

  void _send(int outputId, Object? data) {
    if (_socketClosed || _ws == null) return;
    _ws!.add(json.encode([outputId, data]));
  }

  Future<void> dispose() async {
    try {
      await _ws?.close();
    } catch (_) {}
    try {
      await _httpSub?.cancel();
    } catch (_) {}
    _process?.kill(ProcessSignal.sigkill);
    try {
      await _server.close(force: true);
    } catch (_) {}
    await _launcher.dispose();
  }

  Future<int> run({
    required String testPath,
    required TestSelection selection,
    required String? xmlOutput,
    required String? bazelTestTimeout,
  }) async {
    _httpSub = _server.listen((HttpRequest request) async {
      if (request.uri.path == integrationWebSocketPath &&
          WebSocketTransformer.isUpgradeRequest(request)) {
        try {
          final socket = await WebSocketTransformer.upgrade(request);
          if (!_wsConnected.isCompleted) {
            _wsConnected.complete(socket);
          } else {
            await socket.close();
          }
        } catch (e) {
          if (!_wsConnected.isCompleted) {
            _wsConnected.completeError(e);
          }
        }
        return;
      }
      await _launcher.handleHttpRequest(request);
    });

    try {
      _process = await _launcher.startTarget(_server.port);
    } catch (e) {
      stderr.writeln(
        'flutter_integration_test: failed to start ${_launcher.platformName} '
        'target: $e',
      );
      return 1;
    }

    final processLogs = <String>[];
    void recordProcessLine(String streamName, String line) {
      if (processLogs.length < 200) {
        processLogs.add('[$streamName] $line');
      }
    }

    _process!.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => recordProcessLine('stdout', line));
    _process!.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => recordProcessLine('stderr', line));

    switch (await _awaitDialBack()) {
      case _TargetExited(:final exitCode):
        stderr.writeln(
          'flutter_integration_test: ${_launcher.platformName} target exited '
          'with code $exitCode before connecting to the test harness.',
        );
        for (final line in processLogs) {
          stderr.writeln('  $line');
        }
        return exitCode == 0 ? 1 : exitCode;
      case _DialBackTimedOut():
        stderr.writeln(
          'flutter_integration_test: ${_launcher.platformName} target did not '
          'connect to the harness within ${_dialBackBound.inSeconds}s; '
          'killing it.',
        );
        for (final line in processLogs) {
          stderr.writeln('  $line');
        }
        return 1;
      case _BootstrapConnected(:final socket):
        _ws = socket;
    }

    final results = _Results();
    final suiteReady = Completer<Map<String, dynamic>?>();

    _inbound[0] = (data) {
      final msg = (data as Map).cast<String, dynamic>();
      switch (msg['type']) {
        case 'success':
          if (!suiteReady.isCompleted) {
            suiteReady.complete((msg['root'] as Map).cast<String, dynamic>());
          }
        case 'loadException':
          results.recordError('load failure — ${msg['message']}');
          if (!suiteReady.isCompleted) suiteReady.complete(null);
        case 'error':
          final err = (msg['error'] as Map).cast<String, dynamic>();
          results.recordError(
            'uncaught error — ${err['message']}\n${err['stackChain']}',
          );
          if (!suiteReady.isCompleted) suiteReady.complete(null);
        case 'uncaughtError':
          results.recordError(
            'uncaught error — ${msg['message']}\n${msg['stack'] ?? ''}',
          );
          if (!suiteReady.isCompleted) suiteReady.complete(null);
        case 'print':
          stdout.writeln(msg['line']);
      }
    };

    _ws!.listen(
      _onSocketMessage,
      onDone: () {
        _socketClosed = true;
        if (!suiteReady.isCompleted) suiteReady.complete(null);
        for (final c in _pendingTests.values) {
          if (!c.isCompleted) c.complete();
        }
        _pendingTests.clear();
      },
    );

    _send(0, _initialMessage(testPath, bazelTestTimeout));

    final ceiling = testCeiling(bazelTestTimeout);
    final root = await suiteReady.future.timeout(
      ceiling,
      onTimeout: () => null,
    );

    if (root != null) {
      final selected = selection.select(root);
      if (selected != null) {
        await _runGroup(selected, results, ceiling);
      } else if (selection.narrows) {
        stdout.writeln(
          'flutter_integration_test: no test case in this suite matches '
          'this run\'s --test_filter or shard.',
        );
      }
    } else {
      results.recordError('suite did not load');
      for (final line in processLogs) {
        stderr.writeln('  $line');
      }
    }

    if (xmlOutput != null) {
      await File(
        xmlOutput,
      ).writeAsString(junitXml(results.cases, suiteName: testPath));
    }

    _send(0, {'type': 'close'});
    try {
      await _ws?.close();
    } catch (_) {}

    _process?.kill(ProcessSignal.sigkill);
    await _process!.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => 0,
    );

    stdout.writeln(results.summary());
    return results.hasFailure ? 1 : 0;
  }

  Future<_DialBack> _awaitDialBack() async {
    final outcome = await Future.any<_DialBack?>([
      _wsConnected.future.then<_DialBack?>(_BootstrapConnected.new),
      _process!.exitCode.then<_DialBack?>(_TargetExited.new),
    ]).timeout(_dialBackBound, onTimeout: () => null);
    return outcome ?? const _DialBackTimedOut();
  }

  void _onSocketMessage(dynamic raw) {
    final decoded = json.decode(raw as String);
    if (decoded is Map && decoded['type'] == 'uncaughtError') {
      final handler = _inbound[0];
      if (handler != null) {
        handler(decoded);
      }
      for (final c in _pendingTests.values) {
        if (!c.isCompleted) c.complete();
      }
      return;
    }
    final list = decoded as List;
    final id = (list[0] as num).toInt();
    if (list.length == 1) {
      _inbound.remove(id);
      return;
    }
    final handler = _inbound[id];
    if (handler != null) {
      handler(list[1]);
    }
  }

  Future<void> _runGroup(
    Map<String, dynamic> group,
    _Results results,
    Duration ceiling,
  ) async {
    final setUpAll = group['setUpAll'] as Map?;
    if (setUpAll != null) {
      await _runTest(
        setUpAll.cast<String, dynamic>(),
        results,
        ceiling,
        fixture: true,
      );
    }

    final entries = group['entries'] as List? ?? const [];
    for (final entry in entries) {
      final m = (entry as Map).cast<String, dynamic>();
      if (m['type'] == 'group') {
        await _runGroup(m, results, ceiling);
      } else {
        await _runTest(m, results, ceiling);
      }
    }

    final tearDownAll = group['tearDownAll'] as Map?;
    if (tearDownAll != null) {
      await _runTest(
        tearDownAll.cast<String, dynamic>(),
        results,
        ceiling,
        fixture: true,
      );
    }
  }

  Future<void> _runTest(
    Map<String, dynamic> test,
    _Results results,
    Duration ceiling, {
    bool fixture = false,
  }) async {
    final testChannelId = (test['channel'] as num).toInt();
    final reportName = test['name'] as String? ?? '';

    final metadata = test['metadata'] as Map?;
    final skipReason = metadata == null ? null : metadata['skipReason'];
    final skipFlag = metadata == null
        ? false
        : (metadata['skip'] as bool? ?? false);
    if (!fixture && skipFlag) {
      results.recordSkipped(reportName, skipReason as String?);
      return;
    }

    if (_socketClosed) {
      results.recordFailure(
        reportName,
        _TestFailureSummary(
          message:
              '${_launcher.platformName} target disconnected before this test ran',
          type: 'TestDeviceException',
          stackChain: '',
        ),
        Duration.zero,
        '',
      );
      return;
    }

    final ch = _allocChannel();
    final completer = Completer<void>();
    final started = Stopwatch()..start();
    final output = StringBuffer();
    _pendingTests[ch.inputId] = completer;
    _TestFailureSummary? failure;

    _inbound[ch.inputId] = (data) {
      final msg = (data as Map).cast<String, dynamic>();
      switch (msg['type']) {
        case 'state-change':
          break;
        case 'error':
          final err = (msg['error'] as Map).cast<String, dynamic>();
          failure ??= _TestFailureSummary(
            message:
                err['message'] as String? ?? err['toString'] as String? ?? '',
            type: err['type'] as String? ?? 'TestFailure',
            stackChain: err['stackChain'] as String? ?? '',
          );
        case 'message':
          final mtype = msg['message-type'] as String? ?? 'print';
          final text = msg['text'] as String? ?? '';
          final line = mtype == 'print' ? text : '[$mtype] $text';
          stdout.writeln(line);
          output.writeln(line);
        case 'complete':
          if (!completer.isCompleted) completer.complete();
      }
    };

    _send(testChannelId + 1, {'command': 'run', 'channel': ch.outputId});

    await completer.future.timeout(
      ceiling,
      onTimeout: () {
        final msg =
            'test "$reportName" timed out after ${ceiling.inSeconds}s; '
            'killing ${_launcher.platformName} target.';
        stderr.writeln('flutter_integration_test: $msg');
        failure ??= _TestFailureSummary(
          message: msg,
          type: 'TimeoutException',
          stackChain: '',
        );
        _socketClosed = true;
        _process?.kill(ProcessSignal.sigkill);
      },
    );
    _pendingTests.remove(ch.inputId);
    _inbound.remove(ch.inputId);

    if (_socketClosed && failure == null) {
      failure = _TestFailureSummary(
        message:
            '${_launcher.platformName} target disconnected mid-test '
            '(or crashed)',
        type: 'TestDeviceException',
        stackChain: '',
      );
    }

    started.stop();
    if (failure != null) {
      results.recordFailure(
        reportName,
        failure!,
        started.elapsed,
        output.toString(),
      );
    } else if (!fixture) {
      results.recordSuccess(reportName, started.elapsed, output.toString());
    }
  }

  Map<String, dynamic> _initialMessage(
    String testPath,
    String? bazelTestTimeout,
  ) {
    return {
      'type': 'initial',
      'metadata': _defaultMetadata(suiteTimeout(bazelTestTimeout)),
      'platform': {
        'runtime': _launcher.suiteRuntime,
        'compiler': _launcher.suiteCompiler,
        'os': _launcher.suiteRuntime == 'chrome' ? 'none' : _osIdentifier(),
        'inGoogle': false,
      },
      'platformVariables': const <String>[],
      'collectTraces': true,
      'noRetry': true,
      'allowDuplicateTestNames': true,
      'foldTraceExcept': const <String>[],
      'foldTraceOnly': const <String>[],
      'path': testPath,
      'asciiGlyphs': !stdout.supportsAnsiEscapes,
      'ignoreTimeouts': false,
    };
  }

  static Map<String, Object?> _defaultMetadata(Object timeout) {
    return {
      'testOn': null,
      'timeout': timeout,
      'skip': null,
      'skipReason': null,
      'verboseTrace': null,
      'chainStackTraces': null,
      'retry': null,
      'tags': const <String>[],
      'onPlatform': const <List<Object>>[],
      'forTag': const <String, Object?>{},
      'languageVersionComment': null,
    };
  }

  static String _osIdentifier() {
    if (Platform.isMacOS) return 'mac-os';
    if (Platform.isLinux) return 'linux';
    if (Platform.isWindows) return 'windows';
    return 'none';
  }
}

sealed class _DialBack {
  const _DialBack();
}

final class _BootstrapConnected extends _DialBack {
  const _BootstrapConnected(this.socket);
  final WebSocket socket;
}

final class _TargetExited extends _DialBack {
  const _TargetExited(this.exitCode);
  final int exitCode;
}

final class _DialBackTimedOut extends _DialBack {
  const _DialBackTimedOut();
}

class _TestFailureSummary {
  _TestFailureSummary({
    required this.message,
    required this.type,
    required this.stackChain,
  });

  final String message;
  final String type;
  final String stackChain;

  @override
  String toString() {
    final buf = StringBuffer()..writeln('$type: $message');
    if (stackChain.isNotEmpty) {
      buf.write(stackChain);
    }
    return buf.toString();
  }
}

class _Results {
  int passed = 0;
  int failed = 0;
  int skipped = 0;
  bool _suiteError = false;

  final List<TestCaseResult> cases = [];

  void recordSuccess(String name, Duration elapsed, String output) {
    passed++;
    cases.add(TestCaseResult.passed(name, elapsed, output));
    stdout.writeln('  PASS  $name');
  }

  void recordFailure(
    String name,
    _TestFailureSummary summary,
    Duration elapsed,
    String output,
  ) {
    failed++;
    final formatted = summary.toString();
    cases.add(
      TestCaseResult.failed(
        name,
        elapsed,
        output,
        failureType: summary.type,
        message: summary.message,
        detail: formatted,
      ),
    );
    stdout.writeln('  FAIL  $name');
    stdout.writeln(_indent(formatted, '        '));
  }

  void recordSkipped(String name, String? reason) {
    skipped++;
    cases.add(TestCaseResult.skipped(name));
    stdout.writeln(
      reason == null ? '  SKIP  $name' : '  SKIP  $name (${reason.trim()})',
    );
  }

  void recordError(String message) {
    _suiteError = true;
    stdout.writeln('  FAIL  (suite error): $message');
    stderr.writeln('flutter_integration_test: $message');
  }

  bool get hasFailure => failed > 0 || _suiteError;

  String summary() {
    final pieces = <String>[
      if (passed > 0) '$passed passed',
      if (failed > 0) '$failed failed',
      if (skipped > 0) '$skipped skipped',
    ];
    final body = pieces.isEmpty ? 'no tests' : pieces.join(', ');
    return '\n$body${_suiteError ? ' (suite error)' : ''}';
  }
}

String _indent(String body, String prefix) {
  return body.split('\n').map((l) => l.isEmpty ? l : '$prefix$l').join('\n');
}
