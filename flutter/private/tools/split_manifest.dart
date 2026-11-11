/// Binary `AndroidManifest.xml` for the code-free Dart payload split.
///
/// `adb install-multiple` takes a split APK only when its manifest names the
/// base's package and version code and carries a `split` name. The split holds
/// assets alone, so the manifest is generated here as Android binary XML
/// rather than linked with aapt2: the bytes depend on the package, the version
/// code and the split name only, and are therefore reproducible.
library;

import 'dart:typed_data';

const String _androidNsUri = 'http://schemas.android.com/apk/res/android';

/// Little-endian byte writer for the binary XML chunks below.
class _Le {
  final BytesBuilder bytes = BytesBuilder();

  void u16(int v) => bytes.add([v & 0xFF, (v >> 8) & 0xFF]);

  void u32(int v) => bytes.add([
    v & 0xFF,
    (v >> 8) & 0xFF,
    (v >> 16) & 0xFF,
    (v >> 24) & 0xFF,
  ]);

  void add(List<int> v) => bytes.add(v);

  int get length => bytes.length;
}

/// Wraps [body] in a binary XML chunk: [type], [headerSize], total size.
Uint8List _axmlChunk(int type, int headerSize, _Le body) {
  final out = _Le()
    ..u16(type)
    ..u16(headerSize)
    ..u32(8 + body.length)
    ..add(body.bytes.toBytes());
  return out.bytes.takeBytes();
}

Uint8List _axmlStringPool(List<String> strings) {
  final offsets = _Le();
  final data = _Le();
  for (final s in strings) {
    offsets.u32(data.length);
    data.u16(s.length);
    s.codeUnits.forEach(data.u16);
    data.u16(0);
  }
  if (data.length % 4 != 0) data.u16(0);
  final body = _Le()
    ..u32(strings.length)
    ..u32(0)
    ..u32(0)
    ..u32(28 + offsets.length)
    ..u32(0)
    ..add(offsets.bytes.toBytes())
    ..add(data.bytes.toBytes());
  return _axmlChunk(0x0001, 28, body);
}

/// One attribute of a generated binary XML element. `nsIndex` and `name`
/// index the string pool; a string value sets `rawString`, a typed value
/// sets `dataType` and `data`.
typedef _AxmlAttr = ({
  int nsIndex,
  int name,
  int rawString,
  int dataType,
  int data,
});

Uint8List _axmlNode(
  int type,
  List<int> words, [
  List<_AxmlAttr> attrs = const [],
]) {
  final body = _Le();
  words.forEach(body.u32);
  if (type == 0x0102) {
    body
      ..u16(0x14)
      ..u16(0x14)
      ..u16(attrs.length)
      ..u16(0)
      ..u16(0)
      ..u16(0);
    for (final a in attrs) {
      body
        ..u32(a.nsIndex)
        ..u32(a.name)
        ..u32(a.rawString)
        ..u16(8)
        ..add([0, a.dataType])
        ..u32(a.data);
    }
  }
  return _axmlChunk(type, 16, body);
}

/// Reads the `package` and `android:versionCode` attributes of the
/// `<manifest>` element in [mergedManifest].
({String package, int? versionCode}) _readManifestIdentity(
  String mergedManifest,
) {
  final RegExpMatch? tag = RegExp(
    r'<manifest\b[^>]*>',
    dotAll: true,
  ).firstMatch(mergedManifest);
  final String head = tag?.group(0) ?? '';
  final RegExpMatch? pkg = RegExp(r'\bpackage\s*=\s*"([^"]+)"')
      .firstMatch(head);
  if (pkg == null) {
    throw const FormatException(
      'apk-overlay: the merged manifest has no <manifest package="...">.',
    );
  }
  final RegExpMatch? vc = RegExp(
    r'android:versionCode\s*=\s*"([^"]*)"',
  ).firstMatch(head);
  int? versionCode;
  if (vc != null) {
    versionCode = int.tryParse(vc.group(1)!);
    if (versionCode == null) {
      throw FormatException(
        'apk-overlay: android:versionCode "${vc.group(1)}" in the merged '
        'manifest is not an integer.',
      );
    }
  }
  return (package: pkg.group(1)!, versionCode: versionCode);
}

/// Builds the binary `AndroidManifest.xml` of a code-free split APK named
/// [splitName] for the app described by [mergedManifest]: a `manifest`
/// element carrying `package`, `split` and `android:versionCode`, holding one
/// `application` element with `android:hasCode="false"`.
///
/// `adb install-multiple` accepts the split only when its package and
/// version code equal the base APK's, so both are read from the base's merged
/// manifest. The bytes depend on nothing else, so they are reproducible.
Uint8List buildSplitManifest({
  required String mergedManifest,
  required String splitName,
}) {
  final ({String package, int? versionCode}) id = _readManifestIdentity(
    mergedManifest,
  );
  // Attribute names with resource ids come first, in the order of the
  // resource map.
  final strings = <String>[
    if (id.versionCode != null) 'versionCode',
    'hasCode',
    'android',
    _androidNsUri,
    'manifest',
    'package',
    'split',
    'application',
    id.package,
    splitName,
  ];
  int ix(String s) => strings.indexOf(s);
  final int uri = ix(_androidNsUri);
  const none = 0xFFFFFFFF;
  _AxmlAttr text(String name, String value) => (
    nsIndex: none,
    name: ix(name),
    rawString: ix(value),
    dataType: 3,
    data: ix(value),
  );
  _AxmlAttr typed(String name, int type, int data) => (
    nsIndex: uri,
    name: ix(name),
    rawString: none,
    dataType: type,
    data: data,
  );
  final map = _Le();
  [if (id.versionCode != null) 0x0101021b, 0x0101000c].forEach(map.u32);
  final int android = ix('android');
  const line = 1;
  final out = BytesBuilder()
    ..add(_axmlStringPool(strings))
    ..add(_axmlChunk(0x0180, 8, map))
    ..add(_axmlNode(0x0100, [line, none, android, uri]))
    ..add(
      _axmlNode(
        0x0102,
        [line, none, none, ix('manifest')],
        [
          if (id.versionCode != null)
            typed('versionCode', 0x10, id.versionCode!),
          text('package', id.package),
          text('split', splitName),
        ],
      ),
    )
    ..add(
      _axmlNode(
        0x0102,
        [line, none, none, ix('application')],
        [
          typed('hasCode', 0x12, 0),
        ],
      ),
    )
    ..add(_axmlNode(0x0103, [line, none, none, ix('application')]))
    ..add(_axmlNode(0x0103, [line, none, none, ix('manifest')]))
    ..add(_axmlNode(0x0101, [line, none, android, uri]));
  final Uint8List chunks = out.takeBytes();
  final file = _Le()
    ..u16(0x0003)
    ..u16(8)
    ..u32(8 + chunks.length)
    ..add(chunks);
  return file.bytes.takeBytes();
}
