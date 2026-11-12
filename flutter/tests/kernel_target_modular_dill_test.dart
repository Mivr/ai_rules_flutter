// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:runfiles/runfiles.dart';
import 'package:test/test.dart';

const int _componentMagic = 0x90ABCDEF;
const String _registrantUri =
    'org-dartlang-app:///_flutter_debug_agent/plugin_registrant.dart';
const String _agentUri =
    'org-dartlang-app:///_flutter_debug_agent/agent_extensions.dart';
const String _nativeAgentUri =
    'org-dartlang-app:///_flutter_debug_agent/native_agent_extensions.dart';
const String _sdkRegistrantUri =
    'package:flutter/src/dart_plugin_registrant.dart';

/// Splits a concatenated `.dill` into the latin1 view of each sub-component.
List<String> _readSubComponents(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  final ranges = <(int, int)>[];
  int end = bytes.length;
  while (end >= 48) {
    final int size = bd.getUint32(end - 4);
    if (size < 48 || size > end) {
      throw StateError('Invalid sub-component size $size at $end');
    }
    final int start = end - size;
    final int magic = bd.getUint32(start);
    if (magic != _componentMagic) {
      throw StateError('Invalid kernel magic 0x${magic.toRadixString(16)}');
    }
    ranges.add((start, end));
    end = start;
  }
  if (end != 0) {
    throw StateError('Trailing bytes before offset $end');
  }
  return <String>[
    for (final (int start, int stop) in ranges.reversed)
      latin1.decode(Uint8List.sublistView(bytes, start, stop)),
  ];
}

void main() {
  test(
    'linked modular debug dill holds constant-URI registrant, agents, plugin, and resolved SDK constant',
    () {
      final String path = Runfiles.create().rlocation(
        Platform.environment['MODULAR_DEBUG_DILL']!,
      );
      final List<String> components = _readSubComponents(
        File(path).readAsBytesSync(),
      );

      // platform_strong.dill + entry + SDK flutter SCCs + plugin SCC.
      expect(components.length, greaterThanOrEqualTo(4));

      final String entry = components[1];
      expect(entry, contains(_registrantUri));
      expect(entry, contains(_agentUri));
      expect(entry, contains(_nativeAgentUri));
      expect(entry, contains('registerRulesFlutterAgentExtensions'));
      expect(entry, contains('registerRulesFlutterNativeAgentExtensions'));
      expect(entry, contains('ModularFixturePlugin'));

      final List<String> depComponents = components.skip(2).toList();
      final List<String> sdkRegistrantComponents = depComponents
          .where((String c) => c.contains('dartPluginRegistrantLibrary'))
          .toList();
      expect(
        sdkRegistrantComponents,
        hasLength(1),
        reason:
            '$_sdkRegistrantUri SCC from the twin must be linked into the dill',
      );
      expect(sdkRegistrantComponents.single, contains(_sdkRegistrantUri));
      expect(
        sdkRegistrantComponents.single,
        contains(_registrantUri),
        reason:
            'dartPluginRegistrantLibrary in the linked twin SCC must resolve to $_registrantUri',
      );
    },
  );
}
