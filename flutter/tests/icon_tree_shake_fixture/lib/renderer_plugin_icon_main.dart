import 'package:flutter/material.dart';

const IconData rendererSelectedIcon =
    bool.fromEnvironment('FLUTTER_WEB_USE_SKWASM')
    ? Icons.b
    : (bool.fromEnvironment('FLUTTER_WEB_USE_SKIA') ? Icons.c : Icons.d);

@pragma('vm:entry-point')
void main() {
  final keep = <Object?>[
    rendererSelectedIcon,
    rendererSelectedIcon.fontFamily,
    rendererSelectedIcon.codePoint,
  ];
  if (keep.isEmpty) {
    throw StateError('unreachable');
  }
}
