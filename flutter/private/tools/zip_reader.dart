/// Deterministic ZIP archive readers.
///
/// Decodes the archives written by `zip_writer.dart`: full inflation into
/// `ZipEntry` values, or raw header-only reads into `ZipRawEntry` values
/// for splicing without recompression.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'zip_writer.dart'
    show
        CrcAndSizeSink,
        ZipEntry,
        getUint64LE,
        streamingFileThreshold,
        zip64HeaderId,
        zip64Limit32;

/// Central-directory record fields shared by the ZIP readers.
typedef _CentralRecord = ({
  String path,
  int method,
  int flags,
  int crc,
  int compressedSize,
  int uncompressedSize,
  int externalAttrs,
  int localOffset,
  int nextPos,
});

int _findEocdOffset(ByteData bd, Uint8List zipBytes) {
  // Locate End of Central Directory (0x06054b50).
  for (var i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      return i;
    }
  }
  throw FormatException('Invalid ZIP archive: EOCD signature not found.');
}

/// Applies the ZIP64 End of Central Directory locator when present,
/// returning the authoritative entry count and central-directory offset.
({int entryCount, int cdOffset}) _applyZip64Locator(
  ByteData bd,
  Uint8List zipBytes,
  int eocdOffset,
  int entryCount,
  int cdOffset,
) {
  // Check for ZIP64 End of Central Directory Locator (0x07064b50) immediately
  // preceding the standard EOCD record.
  if (eocdOffset >= 20 &&
      bd.getUint32(eocdOffset - 20, Endian.little) == 0x07064b50) {
    final zip64EocdOffset = getUint64LE(bd, eocdOffset - 20 + 8);
    if (zip64EocdOffset + 56 > zipBytes.length ||
        bd.getUint32(zip64EocdOffset, Endian.little) != 0x06064b50) {
      throw FormatException(
        'Invalid ZIP64 archive: ZIP64 EOCD signature not found at $zip64EocdOffset.',
      );
    }
    return (
      entryCount: getUint64LE(bd, zip64EocdOffset + 32),
      cdOffset: getUint64LE(bd, zip64EocdOffset + 48),
    );
  }
  return (entryCount: entryCount, cdOffset: cdOffset);
}

/// Applies the ZIP64 extended information extra field (`0x0001`) to 32-bit
/// size/offset markers, returning the resolved values and whether the field
/// was present.
({
  int uncompressedSize,
  int compressedSize,
  int localOffset,
  bool found,
})
_applyZip64ExtraField(
  ByteData bd,
  int extraStart,
  int extraEnd,
  int uncompressedSize,
  int compressedSize,
  int localOffset,
) {
  var extraPos = extraStart;
  while (extraPos + 4 <= extraEnd) {
    final headerId = bd.getUint16(extraPos, Endian.little);
    final dataSize = bd.getUint16(extraPos + 2, Endian.little);
    final fieldDataStart = extraPos + 4;
    if (headerId == zip64HeaderId) {
      var fieldPos = fieldDataStart;
      if (uncompressedSize == zip64Limit32 &&
          fieldPos + 8 <= fieldDataStart + dataSize) {
        uncompressedSize = getUint64LE(bd, fieldPos);
        fieldPos += 8;
      }
      if (compressedSize == zip64Limit32 &&
          fieldPos + 8 <= fieldDataStart + dataSize) {
        compressedSize = getUint64LE(bd, fieldPos);
        fieldPos += 8;
      }
      if (localOffset == zip64Limit32 &&
          fieldPos + 8 <= fieldDataStart + dataSize) {
        localOffset = getUint64LE(bd, fieldPos);
        fieldPos += 8;
      }
      return (
        uncompressedSize: uncompressedSize,
        compressedSize: compressedSize,
        localOffset: localOffset,
        found: true,
      );
    }
    extraPos += 4 + dataSize;
  }
  return (
    uncompressedSize: uncompressedSize,
    compressedSize: compressedSize,
    localOffset: localOffset,
    found: false,
  );
}

/// How strictly a central-directory record is validated while parsing.
///
/// The inflating reader is lenient (archives with trailing data descriptors
/// and 64-bit sizes it never needs still read); the raw reader is strict
/// (it refuses anything below the ZIP32 limits it cannot represent).
class _CentralParseOptions {
  const _CentralParseOptions({
    required this.checkBounds,
    required this.flagsOverride,
    required this.strictZip64,
  });

  final bool checkBounds;
  final int? flagsOverride;
  final bool strictZip64;
}

/// Parses one central-directory record at [pos] with ZIP64 size resolution.
///
/// [options] selects the header checks, the flags value, and the ZIP64 policy
/// of the caller; everything else is shared.
_CentralRecord _parseCentralRecord(
  ByteData bd,
  Uint8List zipBytes,
  int pos,
  _CentralParseOptions options,
) {
  if ((options.checkBounds && pos + 46 > zipBytes.length) ||
      bd.getUint32(pos, Endian.little) != 0x02014b50) {
    throw FormatException('Invalid central directory header at $pos.');
  }
  final flags = options.flagsOverride ?? bd.getUint16(pos + 8, Endian.little);
  final method = bd.getUint16(pos + 10, Endian.little);
  final crc = bd.getUint32(pos + 16, Endian.little);
  var compressedSize = bd.getUint32(pos + 20, Endian.little);
  var uncompressedSize = bd.getUint32(pos + 24, Endian.little);
  final nameLen = bd.getUint16(pos + 28, Endian.little);
  final extraLen = bd.getUint16(pos + 30, Endian.little);
  final commentLen = bd.getUint16(pos + 32, Endian.little);
  final externalAttrs = bd.getUint32(pos + 38, Endian.little);
  var localOffset = bd.getUint32(pos + 42, Endian.little);

  if (options.checkBounds && pos + 46 + nameLen > zipBytes.length) {
    throw FormatException('Invalid central directory header at $pos.');
  }
  final path = utf8.decode(zipBytes.sublist(pos + 46, pos + 46 + nameLen));

  if (uncompressedSize == zip64Limit32 ||
      compressedSize == zip64Limit32 ||
      localOffset == zip64Limit32) {
    final extraStart = pos + 46 + nameLen;
    final resolved = _applyZip64ExtraField(
      bd,
      extraStart,
      extraStart + extraLen,
      uncompressedSize,
      compressedSize,
      localOffset,
    );
    uncompressedSize = resolved.uncompressedSize;
    compressedSize = resolved.compressedSize;
    localOffset = resolved.localOffset;
    if (options.strictZip64 &&
        !resolved.found &&
        (uncompressedSize == zip64Limit32 ||
            compressedSize == zip64Limit32 ||
            localOffset == zip64Limit32)) {
      throw FormatException(
        'ZIP64 entry "$path" has no ZIP64 extra field; 64-bit sizes are '
        'not supported here.',
      );
    }
  }

  return (
    path: path,
    method: method,
    flags: flags,
    crc: crc,
    compressedSize: compressedSize,
    uncompressedSize: uncompressedSize,
    externalAttrs: externalAttrs,
    localOffset: localOffset,
    nextPos: pos + 46 + nameLen + extraLen + commentLen,
  );
}

_CentralRecord _parseInflatedCentralRecord(
  ByteData bd,
  Uint8List zipBytes,
  int pos,
) => _parseCentralRecord(
  bd,
  zipBytes,
  pos,
  const _CentralParseOptions(
    checkBounds: false,
    flagsOverride: 0,
    strictZip64: false,
  ),
);

/// Inflates one entry's payload, verifying checksums for large streaming
/// entries without holding them inflated in memory.
({
  Uint8List data,
  int? uncompressedSizeOverride,
  int? crc32Override,
})
_inflateZipPayload(
  ByteData bd,
  Uint8List zipBytes,
  ZLibCodec rawInflate,
  _CentralRecord central,
) {
  if (bd.getUint32(central.localOffset, Endian.little) != 0x04034b50) {
    throw FormatException(
      'Invalid local file header at ${central.localOffset}.',
    );
  }
  final localNameLen = bd.getUint16(central.localOffset + 26, Endian.little);
  final localExtraLen = bd.getUint16(central.localOffset + 28, Endian.little);
  final dataStart = central.localOffset + 30 + localNameLen + localExtraLen;
  final rawPayload = Uint8List.sublistView(
    zipBytes,
    dataStart,
    dataStart + central.compressedSize,
  );

  if (central.method == 0) {
    final data = Uint8List.fromList(rawPayload);
    return (
      data: data,
      uncompressedSizeOverride: central.uncompressedSize != data.length
          ? central.uncompressedSize
          : null,
      crc32Override: central.crc,
    );
  }
  if (central.method == 8) {
    if (central.uncompressedSize > streamingFileThreshold) {
      return _inflateStreamingZipPayload(central, rawPayload);
    }
    final data = Uint8List.fromList(rawInflate.decode(rawPayload));
    return (
      data: data,
      uncompressedSizeOverride: central.uncompressedSize != data.length
          ? central.uncompressedSize
          : null,
      crc32Override: central.crc,
    );
  }
  throw UnsupportedError(
    'Unsupported ZIP compression method: ${central.method}',
  );
}

({
  Uint8List data,
  int? uncompressedSizeOverride,
  int? crc32Override,
})
_inflateStreamingZipPayload(_CentralRecord central, Uint8List rawPayload) {
  final crcSink = CrcAndSizeSink();
  final inflateSink = ZLibDecoder(
    raw: true,
  ).startChunkedConversion(crcSink);
  const step = 1024 * 1024;
  for (var off = 0; off < rawPayload.length; off += step) {
    final end = (off + step < rawPayload.length)
        ? off + step
        : rawPayload.length;
    inflateSink.add(Uint8List.sublistView(rawPayload, off, end));
  }
  inflateSink.close();
  if (crcSink.totalLength != central.uncompressedSize) {
    throw FormatException(
      'ZIP64 inflated length mismatch for "${central.path}": '
      'expected ${central.uncompressedSize}, got ${crcSink.totalLength}.',
    );
  }
  if (crcSink.crc32Value != central.crc) {
    throw FormatException(
      'ZIP64 CRC-32 mismatch for "${central.path}": '
      'expected 0x${central.crc.toRadixString(16)}, '
      'got 0x${crcSink.crc32Value.toRadixString(16)}.',
    );
  }
  return (
    data: Uint8List(0),
    uncompressedSizeOverride: crcSink.totalLength,
    crc32Override: crcSink.crc32Value,
  );
}

({bool isDir, bool isSymlink, bool isExec}) _zipModeFlags(
  int externalAttrs,
  String path,
) {
  final unixMode = (externalAttrs >>> 16) & 0xFFFF;
  final fileType = unixMode & 0xF000;
  final isDir = path.endsWith('/') || fileType == 0x4000;
  final isSymlink = fileType == 0xA000;
  return (
    isDir: isDir,
    isSymlink: isSymlink,
    isExec: !isDir && !isSymlink && ((unixMode & 0x49) != 0),
  );
}

/// Decodes a ZIP or ZIP64 archive produced by [encodeDeterministicZip] (or
/// standard ZIP writers) into a list of [ZipEntry] items for inspection and
/// testing.
List<ZipEntry> readZipEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  final eocdOffset = _findEocdOffset(bd, zipBytes);
  final located = _applyZip64Locator(
    bd,
    zipBytes,
    eocdOffset,
    bd.getUint16(eocdOffset + 10, Endian.little),
    bd.getUint32(eocdOffset + 16, Endian.little),
  );
  final rawInflate = ZLibCodec(raw: true);

  final entries = <ZipEntry>[];
  var pos = located.cdOffset;
  for (var i = 0; i < located.entryCount; i++) {
    final central = _parseInflatedCentralRecord(bd, zipBytes, pos);
    pos = central.nextPos;
    final payload = _inflateZipPayload(bd, zipBytes, rawInflate, central);
    final flags = _zipModeFlags(central.externalAttrs, central.path);
    entries.add(
      ZipEntry(
        path: central.path,
        data: payload.data,
        uncompressedSizeOverride: payload.uncompressedSizeOverride,
        crc32Override: payload.crc32Override,
        isDirectory: flags.isDir,
        isExecutable: flags.isExec,
        isSymlink: flags.isSymlink,
      ),
    );
  }
  return entries;
}

/// A ZIP entry's on-disk payload, without inflating.
///
/// Unlike [readZipEntries], this never inflates deflated data and never drops
/// large entries: [rawData] is a view onto [zipBytes] holding the entry's
/// bytes exactly as stored (deflated bytes when [method] is 8), so entries of
/// any size below the ZIP32 limits can be copied through (for example a
/// stored native library spliced from one archive into another).
class ZipRawEntry {
  /// Archive path, UTF-8 decoded from the central directory.
  final String path;

  /// Compression method: 0 (stored) or 8 (deflated).
  final int method;

  /// CRC-32 of the uncompressed data, from the central directory.
  final int crc;

  /// Uncompressed byte length, with the ZIP64 extra field applied.
  final int uncompressedSize;

  /// The entry's bytes as stored: uncompressed content when [method] is 0,
  /// deflated content when [method] is 8. A view onto the input buffer.
  final Uint8List rawData;
  final bool isDirectory;

  const ZipRawEntry({
    required this.path,
    required this.method,
    required this.crc,
    required this.uncompressedSize,
    required this.rawData,
    required this.isDirectory,
  });
}

/// Reads the central directory of [zipBytes], returning each entry's raw
/// payload without inflating.
///
/// Refuses archives without a readable extra field where a 64-bit size marker
/// appears (writers that need 64-bit sizes must emit the ZIP64 extra fields
/// [encodeDeterministicZip] emits), encrypted entries, and unsupported
/// compression methods. Entries with data descriptors (bit 3) read fine: the
/// central record carries the authoritative sizes. Anything else below the
/// ZIP32 limits reads, at any size.
int _findRawEocdOffset(ByteData bd, Uint8List zipBytes) {
  // Locate End of Central Directory (0x06054b50): the last occurrence that
  // exactly consumes the trailing bytes (signature + comment).
  for (var i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50 &&
        i + 22 + bd.getUint16(i + 20, Endian.little) == zipBytes.length) {
      return i;
    }
    // The EOCD must lie within the last 64 KiB + 22 bytes; stop early.
    if (i < zipBytes.length - 22 - 65536) break;
  }
  throw FormatException('Invalid ZIP archive: EOCD signature not found.');
}

_CentralRecord _parseRawCentralRecord(
  ByteData bd,
  Uint8List zipBytes,
  int pos,
) => _parseCentralRecord(
  bd,
  zipBytes,
  pos,
  const _CentralParseOptions(
    checkBounds: true,
    flagsOverride: null,
    strictZip64: true,
  ),
);

ZipRawEntry _materializeRawEntry(
  ByteData bd,
  Uint8List zipBytes,
  _CentralRecord central,
) {
  if (central.method != 0 && central.method != 8) {
    throw UnsupportedError(
      'Unsupported ZIP compression method ${central.method} for "${central.path}".',
    );
  }
  if ((central.flags & 0x01) != 0) {
    throw FormatException(
      'Encrypted ZIP entries are not supported: ${central.path}.',
    );
  }
  if (central.localOffset + 30 > zipBytes.length ||
      bd.getUint32(central.localOffset, Endian.little) != 0x04034b50) {
    throw FormatException(
      'Invalid local file header at ${central.localOffset}.',
    );
  }
  final localNameLen = bd.getUint16(central.localOffset + 26, Endian.little);
  final localExtraLen = bd.getUint16(central.localOffset + 28, Endian.little);
  final dataStart = central.localOffset + 30 + localNameLen + localExtraLen;
  if (dataStart + central.compressedSize > zipBytes.length) {
    throw FormatException(
      'ZIP entry "${central.path}" overruns the archive '
      '(offset $dataStart, size ${central.compressedSize}).',
    );
  }
  final rawPayload = Uint8List.sublistView(
    zipBytes,
    dataStart,
    dataStart + central.compressedSize,
  );

  final unixMode = (central.externalAttrs >>> 16) & 0xFFFF;
  final fileType = unixMode & 0xF000;
  final isDir = central.path.endsWith('/') || fileType == 0x4000;
  return ZipRawEntry(
    path: central.path,
    method: central.method,
    crc: central.crc,
    uncompressedSize: central.uncompressedSize,
    rawData: rawPayload,
    isDirectory: isDir,
  );
}

/// Reads the central directory of [zipBytes], returning each entry's raw
/// payload without inflating.
///
/// Refuses archives without a readable extra field where a 64-bit size marker
/// appears (writers that need 64-bit sizes must emit the ZIP64 extra fields
/// [encodeDeterministicZip] emits), encrypted entries, and unsupported
/// compression methods. Entries with data descriptors (bit 3) read fine: the
/// central record carries the authoritative sizes. Anything else below the
/// ZIP32 limits reads, at any size.
List<ZipRawEntry> readZipRawEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  final eocdOffset = _findRawEocdOffset(bd, zipBytes);
  final located = _applyZip64Locator(
    bd,
    zipBytes,
    eocdOffset,
    bd.getUint16(eocdOffset + 10, Endian.little),
    bd.getUint32(eocdOffset + 16, Endian.little),
  );

  final entries = <ZipRawEntry>[];
  var pos = located.cdOffset;
  for (var i = 0; i < located.entryCount; i++) {
    final central = _parseRawCentralRecord(bd, zipBytes, pos);
    pos = central.nextPos;
    entries.add(_materializeRawEntry(bd, zipBytes, central));
  }
  return entries;
}
