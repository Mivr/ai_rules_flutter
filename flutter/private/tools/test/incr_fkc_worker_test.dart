// Tagged `runfiles`: the worker imports `kernel_filter.dart`, which imports
// `package:rules_dart_guard`, supplied via the `@rules_dart//dart/guard`
// dep its `dart_test` declares. A bare `dart test` resolves only this
// package's pubspec, where that import does not exist.
// Coverage comes from //flutter/private/tools:incr_fkc_worker_test.
@Tags(['runfiles'])
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../incr_fkc_server.dart';
import '../incr_fkc_worker.dart';
import '../kernel_filter.dart';
import '../sha256.dart';

class FakeSession implements CompilerSession {
  FakeSession({
    required this.fullDill,
    required this.dillBytes,
    List<CompileResult> script = const [],
    Queue<CompileResult>? shared,
  }) : _script = shared ?? Queue.of(script);

  final String fullDill;
  final List<int> dillBytes;
  final Queue<CompileResult> _script;
  final List<String> commands = [];
  bool closed = false;
  bool dead = false;

  CompileResult _next(String command) {
    commands.add(command);
    File(fullDill).parent.createSync(recursive: true);
    File(fullDill).writeAsBytesSync(dillBytes);
    if (_script.isNotEmpty) return _script.removeFirst();
    return (errors: 0, diagnostics: const [], depLines: const []);
  }

  @override
  Future<CompileResult> compile(String entry) async => _next('compile $entry');

  @override
  Future<CompileResult> recompile(
    String entry,
    List<String> uris, {
    bool resetFirst = false,
  }) async => _next(
    '${resetFirst ? 'reset+' : ''}recompile $entry [${uris.join(',')}]',
  );

  @override
  Future<void> accept() async {
    commands.add('accept');
  }

  @override
  Future<void> reject() async {
    commands.add('reject');
  }

  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  bool get alive => !dead && !closed;
}

/// A workspace with a manifest, sources, staged copies, and the files the
/// compiler may read, all under a fresh temp dir used as the worker's cwd.
class Harness {
  Harness(this.dir);

  final Directory dir;
  String get cwd => dir.path;

  void write(String rel, String content) {
    File('${dir.path}/$rel')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  void writeManifest() {
    write(
      'manifest.txt',
      [
        'lib/main.dart',
        'lib/a.dart',
        '# staged',
        'stage/lib/main.dart',
        'stage/lib/a.dart',
        '# allowed-reads',
        'pkg_config.json',
        'platform.dill',
        '# filesystem-roots',
        'stage',
        '# output',
        'out/app.dill',
      ].join('\n'),
    );
  }

  void writeCleanSources() {
    write('lib/main.dart', "import 'a.dart';\nvoid main() {}\n");
    write('lib/a.dart', 'int get answer => 42;\n');
    write('stage/lib/main.dart', "import 'a.dart';\nvoid main() {}\n");
    write('stage/lib/a.dart', 'int get answer => 42;\n');
    write('pkg_config.json', '{}\n');
    write('platform.dill', 'platform\n');
  }

  List<String> get argv => [
    '--declared-inputs',
    'manifest.txt',
    '--',
    'fake-vm',
    '--output-dill',
    'out/app.dill',
    '--filesystem-root',
    'stage',
    '--packages',
    'pkg_config.json',
    'package:app/main.dart',
  ];

  /// A copy of [argv] with the `--filesystem-root` value replaced by [root].
  List<String> argvWithRoot(String root) {
    final args = argv;
    args[args.indexOf('--filesystem-root') + 1] = root;
    return args;
  }

  List<String> get inputs => [
    'manifest.txt',
    'lib/main.dart',
    'lib/a.dart',
    'stage/lib/main.dart',
    'stage/lib/a.dart',
    'pkg_config.json',
    'platform.dill',
  ];

  List<String> depLines() => [
    '+file://$cwd/lib/main.dart',
    '+file://$cwd/lib/a.dart',
    '+file://$cwd/stage/lib/main.dart',
    '+file://$cwd/stage/lib/a.dart',
    '+file://$cwd/pkg_config.json',
    '+file://$cwd/platform.dill',
  ];

  CompileResult ok() =>
      (errors: 0, diagnostics: const [], depLines: depLines());
}

/// Whether [parent] holds a surviving `incr_fkc_*` worker temp directory.
bool hasWorkerTemp(Directory parent) =>
    parent.listSync().whereType<Directory>().any(
      (d) => d.path.split(Platform.pathSeparator).last.startsWith('incr_fkc_'),
    );

void main() {
  group('sha256Hex', () {
    test('matches the standard vectors', () {
      expect(
        sha256Hex(const []),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
    });
  });

  group('expandWorkerFlagfiles', () {
    test('expands @ files in order and skips empty lines', () {
      final dir = Directory.systemTemp.createTempSync('incr_flagfile_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/args').writeAsStringSync('--a\n\n--b=1\n');
      expect(
        expandWorkerFlagfiles(['--x', '@${dir.path}/args', '--y']),
        ['--x', '--a', '--b=1', '--y'],
      );
    });

    test('unwraps single-quoted lines and leaves the rest literal', () {
      final dir = Directory.systemTemp.createTempSync('incr_flagfile_q_');
      addTearDown(() => dir.deleteSync(recursive: true));
      File(
        '${dir.path}/args',
      ).writeAsStringSync("'-Dname=a b'\n--c\n'a'b\n");
      expect(
        expandWorkerFlagfiles(['@${dir.path}/args']),
        ['-Dname=a b', '--c', "'a'b"],
      );
    });

    test('expands a define flagfile named by the parameter file', () {
      final dir = Directory.systemTemp.createTempSync('incr_nested_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final inner = File('${dir.path}/inner.defines')
        ..writeAsStringSync('-DSECOND=two\n');
      final nested = File('${dir.path}/nested.defines')
        ..writeAsStringSync('-DFIRST=one\n@${inner.path}\n');
      File(
        '${dir.path}/args',
      ).writeAsStringSync('--sentinel\n@${nested.path}\n');
      expect(
        expandWorkerFlagfiles(['@${dir.path}/args']),
        ['--sentinel', '-DFIRST=one', '-DSECOND=two'],
      );
    });

    test('refuses a nested line that is not a define, with its number', () {
      final dir = Directory.systemTemp.createTempSync('incr_badline_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final bad = File('${dir.path}/bad.defines')
        ..writeAsStringSync('\n-DOK=1\nNOT_A_DEFINE\n');
      File('${dir.path}/args').writeAsStringSync('@${bad.path}\n');
      expect(
        () => expandWorkerFlagfiles(['@${dir.path}/args']),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains(bad.path) &&
                error.message.contains('line 3'),
            'names the flagfile and the 1-based line',
          ),
        ),
      );
    });

    test('refuses a missing nested flagfile with the chain', () {
      final dir = Directory.systemTemp.createTempSync('incr_missing_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final missing = File('${dir.path}/missing.defines');
      final outer = File('${dir.path}/args')
        ..writeAsStringSync('@${missing.path}\n');
      expect(
        () => expandWorkerFlagfiles(['@${outer.path}']),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains(outer.path) &&
                error.message.contains(missing.path),
            'names the chain of files',
          ),
        ),
      );
    });

    test('refuses an unreadable nested flagfile with the chain', () {
      final dir = Directory.systemTemp.createTempSync('incr_unreadable_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final outer = '${dir.path}/args';
      final secret = '${dir.path}/secret.defines';
      expect(
        () => expandWorkerFlagfiles(
          ['@$outer'],
          readFile: (path) {
            if (path == secret) {
              throw FileSystemException('denied', path);
            }
            return ['@$secret'];
          },
        ),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains(outer) &&
                error.message.contains(secret) &&
                error.message.contains('denied'),
            'names the chain of files',
          ),
        ),
      );
    });

    test('refuses a nested cycle with the chain', () {
      final dir = Directory.systemTemp.createTempSync('incr_cycle_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final first = File('${dir.path}/first.defines')
        ..writeAsStringSync('@${dir.path}/second.defines\n');
      final second = File('${dir.path}/second.defines')
        ..writeAsStringSync('@${dir.path}/first.defines\n');
      File('${dir.path}/args').writeAsStringSync('@${first.path}\n');
      expect(
        () => expandWorkerFlagfiles(['@${dir.path}/args']),
        throwsA(
          predicate(
            (Object? error) =>
                error is FormatException &&
                error.message.contains('cycle') &&
                error.message.contains(first.path) &&
                error.message.contains(second.path),
            'names the cycle chain',
          ),
        ),
      );
    });
  });

  group('splitWorkerArgv', () {
    test('drops a leading tool path, keeps flags and flagfiles', () {
      expect(stripWorkerArgv0(['--declared-inputs', 'm']), [
        '--declared-inputs',
        'm',
      ]);
      expect(stripWorkerArgv0(['@args']), ['@args']);
      expect(stripWorkerArgv0(['/tool/worker', '--declared-inputs', 'm']), [
        '--declared-inputs',
        'm',
      ]);
      expect(stripWorkerArgv0([]), isEmpty);
    });
    test('splits the manifest from the compiler command', () {
      final split = splitWorkerArgv([
        '--declared-inputs',
        'm.txt',
        '--',
        'vm',
        'snap.snapshot',
        'entry.dart',
      ]);
      expect(split.manifestPath, 'm.txt');
      expect(split.command, ['vm', 'snap.snapshot', 'entry.dart']);
    });

    test('rejects a missing manifest flag and stray args', () {
      expect(() => splitWorkerArgv(['--', 'vm']), throwsFormatException);
      expect(
        () => splitWorkerArgv(['--bogus', 'x', '--', 'vm']),
        throwsFormatException,
      );
      expect(
        () => splitWorkerArgv(['--declared-inputs', 'm']),
        throwsFormatException,
      );
    });
  });

  group('configurationKey', () {
    List<String> fs(String out) => [
      'vm',
      '--output-dill',
      out,
      '--enable-asserts',
      'entry.dart',
    ];

    test('ignores the output path but nothing else', () {
      expect(
        configurationKey(fs('a.dill'), sha256Hex),
        configurationKey(fs('b.dill'), sha256Hex),
      );
      expect(
        configurationKey(fs('a.dill'), sha256Hex),
        isNot(configurationKey([...fs('a.dill'), '--x'], sha256Hex)),
      );
    });
  });

  group('incrementalFlagIndex', () {
    test('inserts after the snapshot, or after the script without one', () {
      expect(
        incrementalFlagIndex(['vm', '--x=1', 'fs.snapshot', '--y', 'e.dart']),
        2,
      );
      expect(
        incrementalFlagIndex(['vm', 'script.dart', '--y', 'e.dart']),
        1,
      );
    });
  });

  group('uriOfStaged and classifyChanged', () {
    test('maps staged paths under a root to the app scheme', () {
      expect(
        uriOfStaged('stage/lib/a.dart', ['stage']),
        'org-dartlang-app:///lib/a.dart',
      );
      expect(uriOfStaged('lib/a.dart', ['stage']), isNull);
      // The mount world reads sources in place: under an exec-root mount an
      // in-place path carries its own URI, so no staged twin is needed.
      expect(
        uriOfStaged('stage/lib/a.dart', ['.', '']),
        'org-dartlang-app:///stage/lib/a.dart',
      );
    });

    test('staged dart files become URIs, their source twins are skipped', () {
      final classified = classifyChanged(
        ['lib/a.dart', 'stage/lib/a.dart'],
        ['stage'],
        {'lib/main.dart', 'lib/a.dart'},
      );
      expect(classified.restartReason, isNull);
      expect(classified.uris, ['org-dartlang-app:///lib/a.dart']);
    });

    test('a changed package config restarts cold', () {
      final classified = classifyChanged(
        ['pkg_config.json'],
        ['stage'],
        {'lib/main.dart'},
      );
      expect(classified.restartReason, 'pkg_config.json');
    });

    test('an unstaged dart file outside the manifest restarts cold', () {
      final classified = classifyChanged(
        ['tool/gen.dart'],
        ['stage'],
        {'lib/main.dart'},
      );
      expect(classified.restartReason, 'tool/gen.dart');
    });

    test('a deleted staged dart file still invalidates by URI', () {
      final classified = classifyChanged(
        ['stage/lib/gone.dart'],
        ['stage'],
        {'lib/main.dart'},
      );
      expect(classified.restartReason, isNull);
      expect(classified.uris, ['org-dartlang-app:///lib/gone.dart']);
    });

    test('in-place sources map under an exec-root mount', () {
      expect(
        uriOfStaged('lib/a.dart', ['gen.stage', '.']),
        'org-dartlang-app:///lib/a.dart',
      );
      expect(mountsExecRoot(['gen.stage', '.']), isTrue);
      expect(mountsExecRoot(['gen.stage']), isFalse);
      expect(isInPlacePath('lib/a.dart'), isTrue);
      expect(isInPlacePath('../escape.dart'), isFalse);
      expect(isInPlacePath('/abs/a.dart'), isFalse);
    });

    test('a generated file keys the same URI in place and staged', () {
      // The in-place `bazel-out/<config>/bin/` path strips to the
      // workspace-relative path it is staged at ...
      expect(
        inPlaceSourceKey('bazel-out/k8-fastbuild/bin/gen/foo.dart'),
        'gen/foo.dart',
      );
      expect(inPlaceSourceKey('lib/a.dart'), 'lib/a.dart');
      expect(
        uriOfStaged('bazel-out/k8-fastbuild/bin/gen/foo.dart', [
          'gen.stage',
          '.',
        ]),
        'org-dartlang-app:///gen/foo.dart',
      );
      // ... so the pair dedupes to one delta URI.
      final classified = classifyChanged(
        ['bazel-out/k8-fastbuild/bin/gen/foo.dart', 'gen.stage/gen/foo.dart'],
        ['gen.stage', '.'],
        {'bazel-out/k8-fastbuild/bin/gen/foo.dart'},
      );
      expect(classified.restartReason, isNull);
      expect(classified.uris, ['org-dartlang-app:///gen/foo.dart']);
    });

    test('a source beside its staged twin recompiles once', () {
      final classified = classifyChanged(
        ['lib/a.dart', 'gen.stage/lib/a.dart'],
        ['gen.stage', '.'],
        {'lib/a.dart'},
      );
      expect(classified.restartReason, isNull);
      expect(classified.uris, ['org-dartlang-app:///lib/a.dart']);
    });

    test('an unmappable dart file still restarts cold', () {
      expect(uriOfStaged('../escape.dart', ['.']), isNull);
      final classified = classifyChanged(
        ['../escape.dart'],
        ['.'],
        {'lib/main.dart'},
      );
      expect(classified.restartReason, '../escape.dart');
    });
  });

  group('kernelMountContract', () {
    // Goal G pins the mount order (the stage, then the exec root, then the
    // filesystem_roots): a path under the stage maps through the stage even
    // with the exec root mounted.
    test('the stage wins over the exec root for a staged path', () {
      expect(
        uriOfStaged('gen.stage/gen/foo.dart', ['gen.stage', '.', 'sdk-root']),
        'org-dartlang-app:///gen/foo.dart',
      );
      expect(mountsExecRoot(['gen.stage', '.', 'sdk-root']), isTrue);
    });
  });

  group('foldDepLines', () {
    test('additions join and removals leave the cumulative set', () {
      final current = <String>{};
      foldDepLines(current, ['+file:///a.dart', '+file:///b.dart']);
      foldDepLines(current, ['-file:///a.dart', '+file:///c.dart']);
      expect(current, {'file:///b.dart', 'file:///c.dart'});
    });
  });

  group('GuardCache', () {
    test('reuses the cached result until a content digest changes', () {
      var runs = 0;
      final cache = GuardCache(
        runGuard: (sources, roots) {
          runs++;
          return const <String>[];
        },
      );
      final hashes = {'lib/main.dart': 'h1'};
      expect(cache.check(['lib/main.dart'], ['stage'], hashes), isEmpty);
      expect(cache.check(['lib/main.dart'], ['stage'], hashes), isEmpty);
      expect(runs, 1);
      expect(
        cache.check(['lib/main.dart'], ['stage'], {'lib/main.dart': 'h2'}),
        isEmpty,
      );
      expect(runs, 2);
    });
  });

  group('handleRequest two-phase state machine', () {
    late Harness h;
    late List<FakeSession> sessions;
    late IncrWorker worker;
    late Directory savedCwd;

    SessionFactory factoryFor(List<CompileResult> Function() scriptOf) {
      // One script shared by every server: a restarted server continues the
      // same phase order, so multi-request tests stage cold, warm and error
      // phases in order.
      final shared = Queue.of(scriptOf());
      return (fs, full, inc, cwd) async {
        final s = FakeSession(
          fullDill: full,
          dillBytes: utf8.encode('dill-bytes'),
          shared: shared,
        );
        sessions.add(s);
        return s;
      };
    }

    setUp(() {
      savedCwd = Directory.current;
      h = Harness(Directory.systemTemp.createTempSync('incr_worker_'));
      // The shared read-set check resolves `+file://` lines against the
      // process working directory, which is the exec root in production.
      Directory.current = h.cwd;
      addTearDown(() => h.dir.deleteSync(recursive: true));
      h.writeManifest();
      h.writeCleanSources();
      sessions = [];
    });

    tearDown(() async {
      Directory.current = savedCwd.path;
      await worker.closeAll();
    });

    test('cold: compile, accept, then reset plus an empty recompile', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(() => [h.ok(), h.ok()]),
      );
      final result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 0, reason: result.output);
      expect(result.output, isEmpty);
      expect(sessions, hasLength(1));
      expect(sessions.single.commands, [
        'compile package:app/main.dart',
        'accept',
        'reset+recompile package:app/main.dart []',
        'accept',
      ]);
      expect(File('${h.cwd}/out/app.dill').readAsStringSync(), 'dill-bytes');
    });

    test(
      'warm: only staged dart deltas recompile, then the empty reset',
      () async {
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
        );
        var result = await worker.handleRequest(h.argv, h.inputs);
        expect(result.exitCode, 0, reason: result.output);
        h.write('stage/lib/a.dart', 'int get answer => 43;\n');
        h.write('lib/a.dart', 'int get answer => 43;\n');
        result = await worker.handleRequest(h.argv, h.inputs);
        expect(result.exitCode, 0, reason: result.output);
        expect(sessions, hasLength(1));
        expect(sessions.single.commands, [
          'compile package:app/main.dart',
          'accept',
          'reset+recompile package:app/main.dart []',
          'accept',
          'recompile package:app/main.dart [org-dartlang-app:///lib/a.dart]',
          'accept',
          'reset+recompile package:app/main.dart []',
          'accept',
        ]);
      },
    );

    test(
      'warm: an in-place-only edit recompiles with no staged twin',
      () async {
        // The mount world: the manifest stages generated files only and the
        // roots mount the stage plus the exec root (`.`), so an edit to a
        // source read in place carries its own URI.
        h.write('gen.stage/gen/foo.dart', 'int get foo => 1;\n');
        h.write(
          'manifest.txt',
          [
            'lib/main.dart',
            'lib/a.dart',
            '# staged',
            'gen.stage/gen/foo.dart',
            '# allowed-reads',
            'pkg_config.json',
            'platform.dill',
            '# filesystem-roots',
            'gen.stage',
            '.',
            '# entrypoint',
            'lib/main.dart',
            '# output',
            'out/app.dill',
          ].join('\n'),
        );
        final reads = [
          '+file://${h.cwd}/lib/main.dart',
          '+file://${h.cwd}/lib/a.dart',
          '+file://${h.cwd}/gen.stage/gen/foo.dart',
          '+file://${h.cwd}/pkg_config.json',
          '+file://${h.cwd}/platform.dill',
        ];
        CompileResult readOk() =>
            (errors: 0, diagnostics: const [], depLines: reads);
        final argv = [
          '--declared-inputs',
          'manifest.txt',
          '--',
          'fake-vm',
          '--output-dill',
          'out/app.dill',
          '--filesystem-root',
          'gen.stage',
          '--filesystem-root',
          '.',
          '--packages',
          'pkg_config.json',
          'package:app/main.dart',
        ];
        final inputs = [
          'manifest.txt',
          'lib/main.dart',
          'lib/a.dart',
          'gen.stage/gen/foo.dart',
          'pkg_config.json',
          'platform.dill',
        ];
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: factoryFor(() => [readOk(), readOk(), readOk(), readOk()]),
        );
        var result = await worker.handleRequest(argv, inputs);
        expect(result.exitCode, 0, reason: result.output);
        // Only the in-place source changes: there is no staged twin to edit.
        h.write('lib/a.dart', 'int get answer => 43;\n');
        result = await worker.handleRequest(argv, inputs);
        expect(result.exitCode, 0, reason: result.output);
        expect(sessions, hasLength(1));
        expect(sessions.single.commands, [
          'compile package:app/main.dart',
          'accept',
          'reset+recompile package:app/main.dart []',
          'accept',
          'recompile package:app/main.dart [org-dartlang-app:///lib/a.dart]',
          'accept',
          'reset+recompile package:app/main.dart []',
          'accept',
        ]);
      },
    );

    test(
      'each request lands in its own --output-dill, one warm server',
      () async {
        // The harness (and Bazel strategies) give every request a private
        // output path: requests differing only there share the server, and each
        // finished dill lands in the requesting file.
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
        );
        var result = await worker.handleRequest(h.argv, h.inputs);
        expect(result.exitCode, 0, reason: result.output);
        final argv2 = [
          for (final a in h.argv) a == 'out/app.dill' ? 'out/other.dill' : a,
        ];
        result = await worker.handleRequest(argv2, h.inputs);
        expect(result.exitCode, 0, reason: result.output);
        expect(sessions, hasLength(1));
        expect(File('${h.cwd}/out/app.dill').readAsStringSync(), 'dill-bytes');
        expect(
          File('${h.cwd}/out/other.dill').readAsStringSync(),
          'dill-bytes',
        );
      },
    );

    test('content change with no digest input is still detected', () async {
      // The harness's --inject-digest-lie sends a stale digest for a changed
      // file. The worker never reads request digests — handleRequest takes
      // only paths — so the lie has nothing to hold onto.
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
      );
      var result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 0, reason: result.output);
      h.write('stage/lib/a.dart', '// a comment\nint get answer => 42;\n');
      h.write('lib/a.dart', '// a comment\nint get answer => 42;\n');
      result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 0, reason: result.output);
      expect(
        sessions.single.commands.where((c) => c.contains('lib/a.dart')),
        hasLength(1),
      );
    });

    test('a changed package config restarts the server cold', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
      );
      var result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 0, reason: result.output);
      h.write('pkg_config.json', '{"v":2}\n');
      result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 0, reason: result.output);
      expect(sessions, hasLength(2));
      expect(sessions[0].closed, isTrue);
      expect(sessions[1].commands.first, 'compile package:app/main.dart');
    });

    test(
      'a compile error rejects and the next request re-invalidates',
      () async {
        const error = 'lib/a.dart:1:5: Error: Expected `;`.';
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: factoryFor(
            () => [
              h.ok(),
              h.ok(),
              (errors: 1, diagnostics: [error], depLines: []),
              h.ok(),
              h.ok(),
            ],
          ),
        );
        var result = await worker.handleRequest(h.argv, h.inputs);
        expect(result.exitCode, 0, reason: result.output);
        h.write('stage/lib/a.dart', 'broken syntax (((');
        h.write('lib/a.dart', 'broken syntax (((');
        result = await worker.handleRequest(h.argv, h.inputs);
        expect(result.exitCode, 1);
        expect(result.output, contains(error));
        expect(sessions.single.commands, contains('reject'));
        // The failed request keeps the last accepted hashes ...
        h.write('stage/lib/a.dart', 'int get answer => 44;\n');
        h.write('lib/a.dart', 'int get answer => 44;\n');
        result = await worker.handleRequest(h.argv, h.inputs);
        expect(result.exitCode, 0, reason: result.output);
        // ... so the repair still recompiles the file (never accepted
        // broken): one failed attempt plus the repair.
        expect(
          sessions.single.commands.where(
            (c) => c.contains('org-dartlang-app:///lib/a.dart'),
          ),
          hasLength(2),
        );
        expect(sessions, hasLength(1));
      },
    );

    test('a reset-phase error drops the server', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(
          () => [
            h.ok(),
            (errors: 1, diagnostics: ['reset blew up'], depLines: []),
            h.ok(),
            h.ok(),
          ],
        ),
      );
      final result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 1);
      expect(result.output, contains('reset blew up'));
      expect(sessions.single.closed, isTrue);
      final retry = await worker.handleRequest(h.argv, h.inputs);
      expect(retry.exitCode, 0, reason: retry.output);
      expect(sessions, hasLength(2));
    });

    test('a dead server restarts cold', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: factoryFor(() => [h.ok(), h.ok(), h.ok(), h.ok()]),
      );
      var result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 0, reason: result.output);
      sessions.single.dead = true;
      result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 0, reason: result.output);
      expect(sessions, hasLength(2));
    });
  });

  group('handleRequest guard and read-set parity', () {
    late Harness h;
    late List<FakeSession> sessions;
    late IncrWorker worker;
    late Directory savedCwd;

    setUp(() {
      savedCwd = Directory.current;
      h = Harness(Directory.systemTemp.createTempSync('incr_guard_'));
      Directory.current = h.cwd;
      addTearDown(() => h.dir.deleteSync(recursive: true));
      h.writeManifest();
      h.writeCleanSources();
      sessions = [];
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: (fs, full, inc, cwd) async {
          final s = FakeSession(
            fullDill: full,
            dillBytes: utf8.encode('dill'),
            script: [h.ok(), h.ok()],
          );
          sessions.add(s);
          return s;
        },
      );
    });

    tearDown(() async {
      Directory.current = savedCwd.path;
      await worker.closeAll();
    });

    test('a disallowed directive fails before the compiler runs', () async {
      h.write('lib/main.dart', "import 'file:///etc/hostname';\n");
      h.write('stage/lib/main.dart', "import 'file:///etc/hostname';\n");
      final result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 1);
      expect(result.output, contains('lib/main.dart'));
      expect(result.output, contains('is not a declared input'));
      expect(sessions, isEmpty);
    });

    test('an undeclared read is refused with the batch message', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: (fs, full, inc, cwd) async {
          final s = FakeSession(
            fullDill: full,
            dillBytes: utf8.encode('dill'),
            script: [
              (
                errors: 0,
                diagnostics: const [],
                depLines: [...h.depLines(), '+file:///etc/hostname'],
              ),
              h.ok(),
            ],
          );
          sessions.add(s);
          return s;
        },
      );
      final result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 1);
      expect(
        result.output,
        contains(undeclaredReadMessage('+file:///etc/hostname')),
      );
      expect(File('${h.cwd}/out/app.dill').existsSync(), isFalse);
    });

    test(
      'a read under a root that only the argv names is refused',
      () async {
        // The argv mounts the mirror via `--filesystem-root`, but the
        // manifest names no such read: allowances come only from the
        // manifest, so the mount buys the compile no read.
        final mirrorDir = Directory.systemTemp.createTempSync('incr_mirror_');
        addTearDown(() => mirrorDir.deleteSync(recursive: true));
        final mirror = mirrorDir.path;
        for (final rel in ['lib/main.dart', 'lib/a.dart', 'lib/new.dart']) {
          File('$mirror/$rel')
            ..createSync(recursive: true)
            ..writeAsStringSync('int get fresh => 7;\n');
        }
        for (final rel in ['lib/main.dart', 'lib/a.dart']) {
          File('$mirror/$rel').writeAsStringSync(
            File('${h.cwd}/$rel').readAsStringSync(),
          );
        }
        // lib/new.dart is a created library: mirrored like the build would
        // stage it, but declared in no manifest section.
        final mirrorReads = [
          '+file://$mirror/lib/main.dart',
          '+file://$mirror/lib/a.dart',
          '+file://$mirror/lib/new.dart',
          '+file://${h.cwd}/lib/main.dart',
          '+file://${h.cwd}/lib/a.dart',
          '+file://${h.cwd}/pkg_config.json',
          '+file://${h.cwd}/platform.dill',
        ];
        worker = IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: (fs, full, inc, cwd) async {
            final s = FakeSession(
              fullDill: full,
              dillBytes: utf8.encode('dill'),
              script: [
                (errors: 0, diagnostics: const [], depLines: mirrorReads),
                (errors: 0, diagnostics: const [], depLines: mirrorReads),
              ],
            );
            sessions.add(s);
            return s;
          },
        );
        final result = await worker.handleRequest(
          h.argvWithRoot(mirror),
          h.inputs,
        );
        expect(result.exitCode, 1);
        expect(
          result.output,
          contains(undeclaredReadMessage('+file://$mirror/lib/new.dart')),
        );
        expect(File('${h.cwd}/out/app.dill').existsSync(), isFalse);
      },
    );

    test(
      'a rejected compile still contributes its reads to the refusal',
      () async {
        worker = IncrWorker(
          cwd: h.cwd,
          sessions: (fs, full, inc, cwd) async {
            final s = FakeSession(
              fullDill: full,
              dillBytes: utf8.encode('dill'),
              script: [
                h.ok(),
                h.ok(),
                (
                  errors: 1,
                  diagnostics: ['boom'],
                  depLines: [...h.depLines(), '+file:///etc/sneak.dart'],
                ),
              ],
            );
            sessions.add(s);
            return s;
          },
        );
        var result = await worker.handleRequest(h.argv, h.inputs);
        expect(result.exitCode, 0, reason: result.output);
        h.write('stage/lib/a.dart', 'int get answer => 45;\n');
        h.write('lib/a.dart', 'int get answer => 45;\n');
        result = await worker.handleRequest(h.argv, h.inputs);
        expect(result.exitCode, 1);
        expect(
          result.output,
          contains(undeclaredReadMessage('+file:///etc/sneak.dart')),
        );
      },
    );

    test('zero reads fail closed with the batch message', () async {
      worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        sessions: (fs, full, inc, cwd) async {
          final s = FakeSession(
            fullDill: full,
            dillBytes: utf8.encode('dill'),
            script: [
              (errors: 0, diagnostics: const [], depLines: const []),
              (errors: 0, diagnostics: const [], depLines: const []),
            ],
          );
          sessions.add(s);
          return s;
        },
      );
      final result = await worker.handleRequest(h.argv, h.inputs);
      expect(result.exitCode, 1);
      expect(result.output, contains(noDependencyReadsMessage()));
    });
  });

  group('server LRU', () {
    test('evicts the least recently used server over the cap', () async {
      final savedCwd = Directory.current;
      final h = Harness(Directory.systemTemp.createTempSync('incr_lru_'));
      Directory.current = h.cwd;
      addTearDown(() => h.dir.deleteSync(recursive: true));
      h.writeManifest();
      h.writeCleanSources();
      final sessions = <FakeSession>[];
      final worker = IncrWorker(
        cwd: h.cwd,
        tempParent: h.cwd,
        maxServers: 1,
        sessions: (fs, full, inc, cwd) async {
          final s = FakeSession(
            fullDill: full,
            dillBytes: utf8.encode('dill'),
            script: [h.ok(), h.ok()],
          );
          sessions.add(s);
          return s;
        },
      );
      addTearDown(worker.closeAll);
      final other = [
        ...h.argv.sublist(0, h.argv.indexOf('--packages')),
        '--packages',
        'other_config.json',
        'package:app/main.dart',
      ];
      h.write('other_config.json', '{}\n');
      var result = await worker.handleRequest(h.argv, [...h.inputs]);
      expect(result.exitCode, 0, reason: result.output);
      result = await worker.handleRequest(other, [
        ...h.inputs,
        'other_config.json',
      ]);
      expect(result.exitCode, 0, reason: result.output);
      expect(sessions, hasLength(2));
      expect(sessions[0].closed, isTrue);
      expect(sessions[1].closed, isFalse);
      Directory.current = savedCwd.path;
    });
  });

  group('worker temp cleanup on every exit path', () {
    late Harness h;
    late Directory savedCwd;

    SessionFactory oneScript(List<CompileResult> Function() scriptOf) {
      return (fs, full, inc, cwd) async => FakeSession(
        fullDill: full,
        dillBytes: utf8.encode('dill-bytes'),
        script: scriptOf(),
      );
    }

    setUp(() {
      savedCwd = Directory.current;
      h = Harness(Directory.systemTemp.createTempSync('incr_exit_'));
      Directory.current = h.cwd;
      h.writeManifest();
      h.writeCleanSources();
    });

    tearDown(() {
      Directory.current = savedCwd.path;
      h.dir.deleteSync(recursive: true);
    });

    test('a one-shot success leaves no incr_fkc_ dir', () async {
      final code = await runOneShotWorker(
        h.argv,
        createWorker: () => IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: oneScript(() => [h.ok(), h.ok()]),
        ),
      );
      expect(code, 0);
      expect(File('${h.cwd}/out/app.dill').readAsStringSync(), 'dill-bytes');
      expect(hasWorkerTemp(h.dir), isFalse);
    });

    test('a one-shot failure leaves no incr_fkc_ dir', () async {
      const error = 'lib/a.dart:1:5: Error: Expected `;`.';
      final code = await runOneShotWorker(
        h.argv,
        createWorker: () => IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: oneScript(
            () => [
              (
                errors: 1,
                diagnostics: [error],
                depLines: const [],
              ),
            ],
          ),
        ),
      );
      expect(code, 1);
      expect(File('${h.cwd}/out/app.dill').existsSync(), isFalse);
      expect(hasWorkerTemp(h.dir), isFalse);
    });

    test('persistent stdin EOF deletes the temp dir', () async {
      final request = jsonEncode({
        'requestId': 7,
        'arguments': h.argv,
        'inputs': [
          for (final i in h.inputs) {'path': i},
        ],
      });
      final responses = StringBuffer();
      await runPersistentWorker(
        createWorker: () => IncrWorker(
          cwd: h.cwd,
          tempParent: h.cwd,
          sessions: oneScript(() => [h.ok(), h.ok()]),
        ),
        stdinBytes: Stream.value(utf8.encode('$request\n')),
        responseSink: responses,
      );
      final lines = responses
          .toString()
          .split('\n')
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines, hasLength(1));
      final reply = jsonDecode(lines.single) as Map<String, dynamic>;
      expect(reply['exitCode'], 0);
      expect(reply['requestId'], 7);
      expect(hasWorkerTemp(h.dir), isFalse);
    });

    test('a signal closes the worker and deletes the temp dir', () async {
      // The watcher is wired to a real process signal: delivering the test
      // runner its own SIGUSR1 exercises the listener, the `closeAll` and
      // the status report through the production path. SIGTERM/SIGINT are
      // spoken for by the test runner (a self-sent SIGTERM aborts the run
      // whichever listener is attached), so the test watches SIGUSR1, whose
      // signum travels with the pair exactly like the production SIGTERM
      // (143) and SIGINT (130) pairs it stands in for. Attaching a listener
      // suppresses the default kill-the-process action, and `onSignal`
      // records the status instead of exiting, so the runner survives. The
      // worker serves no requests here: construction alone creates the temp
      // dir to delete.
      final worker = IncrWorker(cwd: h.cwd, tempParent: h.cwd);
      final statuses = <int>[];
      final subs = watchWorkerSignals(
        worker,
        onSignal: statuses.add,
        signals: [(signal: ProcessSignal.sigusr1, status: 999)],
      );
      if (subs.isEmpty) {
        markTestSkipped('this platform delivers no watched signal');
      }
      addTearDown(() => cancelWorkerSignals(subs));
      expect(hasWorkerTemp(h.dir), isTrue);
      expect(Process.killPid(pid, ProcessSignal.sigusr1), isTrue);
      for (var i = 0; i < 200 && statuses.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(statuses, [999]);
      expect(hasWorkerTemp(h.dir), isFalse);
    });
  });

  group('FrontendServerSession protocol', () {
    test(
      'round-trips compile, recompile, accept, reject against a fake',
      () async {
        final dir = Directory.systemTemp.createTempSync('incr_proto_');
        addTearDown(() => dir.deleteSync(recursive: true));
        const uuid = '11111111-2222-3333-4444-555555555555';
        File('${dir.path}/fake_server.dart').writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
void respond() {
  stdout.writeln('result $uuid');
  stdout.writeln('$uuid');
  stdout.writeln('+file://\${Directory.current.path}/lib/main.dart');
  stdout.writeln('$uuid out.dill 0');
}
void main() async {
  final lines = stdin.transform(utf8.decoder).transform(const LineSplitter());
  var pending = false;
  await for (final line in lines) {
    if (line.startsWith('compile ')) {
      respond();
      continue;
    }
    if (line.startsWith('recompile ')) {
      pending = true;
      continue;
    }
    if (line == 'kk' && pending) {
      pending = false;
      respond();
      continue;
    }
    if (line == 'reset' || line == 'accept') continue;
    if (line == 'reject') {
      stdout.writeln('rejected');
      stdout.writeln('ok');
      continue;
    }
    if (line == 'quit') return;
  }
}
''');
        final session = await FrontendServerSession.start(
          [
            Platform.resolvedExecutable,
            '${dir.path}/fake_server.dart',
            '--output-dill',
            'out/app.dill',
            'package:app/main.dart',
          ],
          '${dir.path}/full.dill',
          '${dir.path}/inc.dill',
          cwd: dir.path,
        );
        addTearDown(session.close);
        final compiled = await session.compile('package:app/main.dart');
        expect(compiled.errors, 0);
        expect(compiled.depLines, hasLength(1));
        await session.accept();
        final delta = await session.recompile('package:app/main.dart', [
          'org-dartlang-app:///lib/a.dart',
        ]);
        expect(delta.errors, 0);
        await session.accept();
        final reset = await session.recompile(
          'package:app/main.dart',
          [],
          resetFirst: true,
        );
        expect(reset.errors, 0);
        await session.accept();
        await session.reject();
        expect(session.alive, isTrue);
        await session.close();
      },
    );
  });
}
