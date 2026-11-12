/// Guards the wave-1 project lints in the root analysis configuration.
///
/// `analysis_options.yaml` must enable the four wave-1 rules, and
/// `analysis_baseline.json` must stay sorted, hold only positive integer
/// counts, hold no empty file maps and hold no `no_stdout_in_worker` entry.
library;

import 'dart:convert';
import 'dart:io';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _wave1Rules = [
  'no_home_env_reads',
  'no_stdout_in_worker',
  'no_wall_clock_in_actions',
  'process_requires_environment',
];

String _read(String variable) {
  final String? rlocation = Platform.environment[variable];
  if (rlocation == null || rlocation.isEmpty) {
    throw StateError('$variable is not set');
  }
  return File(Runfiles.create().rlocation(rlocation)).readAsStringSync();
}

bool _sorted(List<String> keys) {
  for (var i = 1; i < keys.length; i++) {
    if (keys[i - 1].compareTo(keys[i]) >= 0) {
      return false;
    }
  }
  return true;
}

void main() {
  final Map<String, Object?> baseline = (jsonDecode(
    _read('ANALYSIS_BASELINE_RLOCATION'),
  ) as Map).cast<String, Object?>();

  test('analysis_options.yaml enables the wave-1 project lints', () {
    final options = loadYaml(_read('ANALYSIS_OPTIONS_RLOCATION')) as YamlMap;
    final rules = (options['linter'] as YamlMap)['rules'] as YamlMap;
    for (final String rule in _wave1Rules) {
      expect(rules[rule], isTrue, reason: '$rule must be enabled');
    }
  });

  test('analysis_baseline.json files and rules are strictly sorted', () {
    expect(_sorted(baseline.keys.toList()), isTrue);
    for (final MapEntry<String, Object?> file in baseline.entries) {
      final Map<Object?, Object?> rules = file.value! as Map;
      expect(
        _sorted(rules.keys.cast<String>().toList()),
        isTrue,
        reason: 'rule keys of ${file.key}',
      );
    }
  });

  test('analysis_baseline.json counts are positive and maps non-empty', () {
    for (final MapEntry<String, Object?> file in baseline.entries) {
      final Map<Object?, Object?> rules = file.value! as Map;
      expect(rules, isNotEmpty, reason: '${file.key} has an empty map');
      for (final MapEntry<Object?, Object?> rule in rules.entries) {
        expect(rule.value, isA<int>(), reason: '${file.key}#${rule.key}');
        expect(rule.value! as int, greaterThan(0));
      }
    }
  });

  test('analysis_baseline.json has no no_stdout_in_worker entry', () {
    for (final MapEntry<String, Object?> file in baseline.entries) {
      expect(
        (file.value! as Map).containsKey('no_stdout_in_worker'),
        isFalse,
        reason: file.key,
      );
    }
  });
}
