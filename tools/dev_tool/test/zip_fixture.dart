/// Hermetic zip fixtures for dev_tool tests.
///
/// The host may not have a `zip` binary, so tests build their archives
/// in-process instead of spawning one: [writeTestZip] walks a directory the
/// test already laid out and writes a minimal deterministic zip (stored or
/// deflated entries, fixed DOS timestamp) with `dart:io`'s raw deflate and a
/// small CRC-32. Entry names, contents and compression methods match what
/// `zip -r` would have written for the same tree.
library;

import 'dart:io';
import 'dart:typed_data';

/// Writes the directory [member] under [root] to [outPath], like running
/// `zip -r <out> <member>` with [root] as the working directory. Directory
/// entries are included, names use `/` separators, and the output is
/// deterministic (sorted entries, fixed timestamp). With [deflate] false every
/// entry is stored, like `zip -0`; otherwise entries are deflated when the
/// deflated form is shorter, like `zip`'s default.
void writeTestZip({
  required String outPath,
  required Directory root,
  required String member,
  bool deflate = true,
}) {
  final entries = <_Entry>[];
  _collect(entries, root, member);
  File(outPath).writeAsBytesSync(_encodeZip(entries, deflate: deflate));
}

class _Entry {
  final String name;
  final Uint8List data;
  final bool isDirectory;

  _Entry(this.name, this.data, this.isDirectory);
}

void _collect(List<_Entry> entries, Directory root, String rel) {
  final path = '${root.path}/$rel';
  switch (FileSystemEntity.typeSync(path, followLinks: false)) {
    case FileSystemEntityType.directory:
      entries.add(_Entry('$rel/', Uint8List(0), true));
      final children = Directory(path).listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final child in children) {
        final name = child.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
        _collect(entries, root, '$rel/$name');
      }
    case FileSystemEntityType.file:
      entries.add(_Entry(rel, File(path).readAsBytesSync(), false));
    case FileSystemEntityType.link:
      throw ArgumentError('zip fixture cannot archive symlink: $path');
    case FileSystemEntityType.notFound:
      throw ArgumentError('zip fixture has no such entry: $path');
  }
}

/// IEEE 802.3 CRC-32, computed bit by bit: fixtures are kilobytes, so no
/// lookup table is worth carrying.
int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1;
    }
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

const _dosTime = 0x0000;
const _dosDate = 0x0021; // 1980-01-01, the deterministic-zip epoch.

Uint8List _encodeZip(List<_Entry> entries, {required bool deflate}) {
  final local = BytesBuilder(copy: false);
  final central = BytesBuilder(copy: false);
  final offsets = <int>[];
  var offset = 0;
  for (final entry in entries) {
    final name = Uint8List.fromList(entry.name.codeUnits);
    final crc = entry.isDirectory ? 0 : _crc32(entry.data);
    var method = 0;
    var payload = entry.data;
    if (deflate && !entry.isDirectory && entry.data.isNotEmpty) {
      final compressed = Uint8List.fromList(
        ZLibEncoder(raw: true).convert(entry.data),
      );
      if (compressed.length < entry.data.length) {
        method = 8;
        payload = compressed;
      }
    }
    offsets.add(offset);
    offset += _writeLocal(local, name, payload, method, crc, entry.data.length);
    _writeCentral(
      central,
      name,
      payload.length,
      entry.data.length,
      method,
      crc,
      entry.isDirectory,
      offsets.last,
    );
  }
  final centralBytes = central.takeBytes();
  final end = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, entries.length, Endian.little)
    ..setUint16(10, entries.length, Endian.little)
    ..setUint32(12, centralBytes.length, Endian.little)
    ..setUint32(16, offset, Endian.little);
  return Uint8List.fromList([
    ...local.takeBytes(),
    ...centralBytes,
    ...end.buffer.asUint8List(),
  ]);
}

/// Appends a local file header plus [payload]; answers the bytes appended.
int _writeLocal(
  BytesBuilder out,
  Uint8List name,
  Uint8List payload,
  int method,
  int crc,
  int uncompressedSize,
) {
  final header = ByteData(30 + name.length)
    ..setUint32(0, 0x04034b50, Endian.little)
    ..setUint16(4, 20, Endian.little)
    ..setUint16(6, 0x0800, Endian.little)
    ..setUint16(8, method, Endian.little)
    ..setUint16(10, _dosTime, Endian.little)
    ..setUint16(12, _dosDate, Endian.little)
    ..setUint32(14, crc, Endian.little)
    ..setUint32(18, payload.length, Endian.little)
    ..setUint32(22, uncompressedSize, Endian.little)
    ..setUint16(26, name.length, Endian.little);
  header.buffer.asUint8List().setRange(30, 30 + name.length, name);
  out.add(header.buffer.asUint8List());
  out.add(payload);
  return 30 + name.length + payload.length;
}

void _writeCentral(
  BytesBuilder out,
  Uint8List name,
  int compressedSize,
  int uncompressedSize,
  int method,
  int crc,
  bool isDirectory,
  int localOffset,
) {
  final externalAttrs = isDirectory ? (0x41ED << 16) | 0x10 : (0x81A4 << 16);
  final header = ByteData(46 + name.length)
    ..setUint32(0, 0x02014b50, Endian.little)
    ..setUint16(4, (3 << 8) | 20, Endian.little)
    ..setUint16(6, 20, Endian.little)
    ..setUint16(8, 0x0800, Endian.little)
    ..setUint16(10, method, Endian.little)
    ..setUint16(12, _dosTime, Endian.little)
    ..setUint16(14, _dosDate, Endian.little)
    ..setUint32(16, crc, Endian.little)
    ..setUint32(20, compressedSize, Endian.little)
    ..setUint32(24, uncompressedSize, Endian.little)
    ..setUint16(28, name.length, Endian.little)
    ..setUint32(38, externalAttrs, Endian.little)
    ..setUint32(42, localOffset, Endian.little);
  header.buffer.asUint8List().setRange(46, 46 + name.length, name);
  out.add(header.buffer.asUint8List());
}
