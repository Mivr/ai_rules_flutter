/// Post-link APK payload injection for `flutter_android_app`.
///
/// `android_binary` feeds its `assets` through aapt2 resource linking and its
/// Java deps (including the jar that carries `libapp.so`) through the
/// dex/multidex chain, so every Dart edit re-runs resource linking, desugaring
/// and dexing even though their outputs do not change. `flutter_android_app`
/// instead builds a base APK without the Flutter payload and injects it here,
/// the way the flutter tool adds Flutter files after resource linking:
///
///   - native libraries (`lib/<abi>/libapp.so`, plugin and FFI `.so` files,
///     read from the bundle's `native_libs.jar`) are stored uncompressed so
///     `zipalign -P 16` can page-align them and the runtime can load them
///     directly from the APK;
///   - `flutter_assets/` (including `kernel_blob.bin` in debug builds) is
///     added under `assets/flutter_assets/`, deflated like aapt2 would except
///     for aapt2's default no-compress extensions.
///
/// The splice copies the base APK's local file sections and central directory
/// records byte-for-byte and appends the payload entries, so every pre-existing
/// entry keeps its exact bytes, compression and timestamps. The caller then
/// runs the stock `zipalign` and `apksigner` steps over the result, exactly as
/// `android_binary` would have. Entry order differs from an `android_binary`
/// that packaged the payload itself (payload entries come last); entry
/// content, alignment and signature validity are unchanged.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'xtool_pack.dart' show ZipRawEntry, crc32, readZipRawEntries;

/// DOS timestamp used for injected entries: 2010-01-01 00:00:00, matching
/// singlejar `--normalize` output surrounding them.
const int _overlayDosTime = 0x0000;
const int _overlayDosDate = 0x3C21;

/// File extensions (without the dot) that aapt2 leaves uncompressed by
/// default (`kDefaultNoCompressExtensions`). Payload files with these
/// extensions are stored, like the `.ap_` an `android_binary` with the same
/// assets would have produced. Matching is case-sensitive, like aapt2.
const Set<String> _aaptNoCompressExtensions = {
  'jpg',
  'jpeg',
  'png',
  'gif',
  'wav',
  'mp2',
  'mp3',
  'ogg',
  'aac',
  'mpg',
  'mpeg',
  'mid',
  'midi',
  'smf',
  'jet',
  'rtttl',
  'imy',
  'xmf',
  'mp4',
  'm4a',
  'm4v',
  '3gp',
  '3gpp',
  '3g2',
  '3gpp2',
  'amr',
  'awb',
  'wma',
  'wmv',
  'webm',
  'mkv',
  'webp',
};

/// Fixed Unix mode for injected regular files (`0644`), never inherited from
/// the host checkout's umask.
const int _overlayFileMode = 0x81A4;

int _getUint16LE(ByteData bd, int offset) =>
    bd.getUint16(offset, Endian.little);

int _getUint32LE(ByteData bd, int offset) =>
    bd.getUint32(offset, Endian.little);

void _setUint16LE(ByteData bd, int offset, int value) =>
    bd.setUint16(offset, value, Endian.little);

void _setUint32LE(ByteData bd, int offset, int value) =>
    bd.setUint32(offset, value, Endian.little);

/// A pending payload entry: archive [path] holding [data] with CRC-32 [crc].
///
/// [crc] is the jar-recorded checksum for entries copied out of
/// `native_libs.jar` (verified on read, reused here so large libraries are
/// checksummed once); entries collected from `flutter_assets/` compute it
/// when encoded.
class _PayloadEntry {
  final String path;
  final Uint8List data;
  final int? crc;

  _PayloadEntry(this.path, this.data, {this.crc});
}

/// Locates the End of Central Directory record in [bytes], returning its
/// offset. Handles an optional archive comment.
int _findEocd(Uint8List bytes) {
  final bd = ByteData.sublistView(bytes);
  for (var i = bytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      return i;
    }
    // The EOCD must lie within the last 64 KiB + 22 bytes; stop early.
    if (i < bytes.length - 22 - 65536) break;
  }
  throw FormatException('apk-overlay: EOCD signature not found.');
}

/// Reads the central directory of [bytes], returning the record name set
/// (for collision checks), the concatenated verbatim record bytes, and the
/// central directory offset.
({Set<String> names, Uint8List records, int cdOffset, int count}) _readCentral(
  Uint8List bytes,
) {
  final bd = ByteData.sublistView(bytes);
  final eocd = _findEocd(bytes);
  final count = _getUint16LE(bd, eocd + 8);
  // entryCount == 0xFFFF would mean ZIP64; APKs never use it.
  if (count == 0xFFFF ||
      _getUint32LE(bd, eocd + 12) == 0xFFFFFFFF ||
      _getUint32LE(bd, eocd + 16) == 0xFFFFFFFF) {
    throw FormatException('apk-overlay: ZIP64 archives are not supported.');
  }
  final cdOffset = _getUint32LE(bd, eocd + 16);
  if (bytes.length < cdOffset + 4 || _getUint32LE(bd, cdOffset) != 0x02014b50) {
    throw FormatException(
      'apk-overlay: central directory not found at offset $cdOffset.',
    );
  }
  final names = <String>{};
  final records = BytesBuilder(copy: false);
  var pos = cdOffset;
  for (var i = 0; i < count; i++) {
    if (_getUint32LE(bd, pos) != 0x02014b50) {
      throw FormatException(
        'apk-overlay: invalid central directory header at $pos.',
      );
    }
    final flags = _getUint16LE(bd, pos + 8);
    // Entries with data descriptors (bit 3, e.g. the merged classes.dex
    // singlejar emits) need no special handling: the splice copies the whole
    // local-file region byte-for-byte, descriptors ride along untouched, and
    // the central record — which carries the authoritative sizes — is copied
    // verbatim too. Only refuse what the offset math cannot survive.
    if ((flags & 0x01) != 0) {
      throw FormatException(
        'apk-overlay: encrypted entries are not supported.',
      );
    }
    final nameLen = _getUint16LE(bd, pos + 28);
    final extraLen = _getUint16LE(bd, pos + 30);
    final commentLen = _getUint16LE(bd, pos + 32);
    final recordLen = 46 + nameLen + extraLen + commentLen;
    names.add(utf8.decode(bytes.sublist(pos + 46, pos + 46 + nameLen)));
    records.add(Uint8List.sublistView(bytes, pos, pos + recordLen));
    pos += recordLen;
  }
  return (
    names: names,
    records: records.takeBytes(),
    cdOffset: cdOffset,
    count: count,
  );
}

/// Collects `(archive path, file bytes)` pairs from [jarBytes], a
/// `native_libs.jar` whose entries already carry their APK paths
/// (`lib/<abi>/<name>`). Every entry is stored uncompressed in the APK so
/// zipalign can page-align it.
///
/// Stored entries are copied as raw bytes with their recorded CRC — never
/// inflated — so libraries of any size below the ZIP32 limits pass through
/// (the jar writer stores `.so` files for exactly this reason). A deflated
/// entry from an older jar is inflated as a fallback.
List<_PayloadEntry> _payloadFromNativeLibsJar(Uint8List jarBytes) {
  final payload = <_PayloadEntry>[];
  for (final ZipRawEntry entry in readZipRawEntries(jarBytes)) {
    if (entry.isDirectory) continue;
    if (entry.method == 0) {
      if (entry.rawData.length != entry.uncompressedSize) {
        throw FormatException(
          'apk-overlay: entry ${entry.path} size mismatch: central '
          'directory says ${entry.uncompressedSize}, found '
          '${entry.rawData.length}.',
        );
      }
      if (crc32(entry.rawData) != entry.crc) {
        throw FormatException(
          'apk-overlay: entry ${entry.path} CRC mismatch.',
        );
      }
      payload.add(_PayloadEntry(entry.path, entry.rawData, crc: entry.crc));
    } else {
      final data = Uint8List.fromList(
        ZLibDecoder(raw: true).convert(entry.rawData),
      );
      if (data.length != entry.uncompressedSize) {
        throw FormatException(
          'apk-overlay: entry ${entry.path} was not fully read: central '
          'directory says ${entry.uncompressedSize}, got ${data.length}.',
        );
      }
      if (crc32(data) != entry.crc) {
        throw FormatException(
          'apk-overlay: entry ${entry.path} CRC mismatch.',
        );
      }
      payload.add(_PayloadEntry(entry.path, data, crc: entry.crc));
    }
  }
  return payload;
}

/// Collects `(archive path, file bytes)` pairs from the `flutter_assets`
/// directory [assetsDir], archived under `assets/flutter_assets/`.
List<_PayloadEntry> _payloadFromFlutterAssets(Directory assetsDir) {
  final collected = <_PayloadEntry>[];

  void walk(Directory dir, String relPrefix) {
    final children = dir.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in children) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final relPath = relPrefix.isEmpty ? name : '$relPrefix/$name';
      if (entity is Directory) {
        walk(entity, relPath);
      } else if (entity is File) {
        collected.add(
          _PayloadEntry(
            'assets/flutter_assets/$relPath',
            entity.readAsBytesSync(),
          ),
        );
      } else if (entity is Link) {
        final resolved = entity.resolveSymbolicLinksSync();
        if (FileSystemEntity.isDirectorySync(resolved)) {
          throw ArgumentError(
            'apk-overlay: directory symlink not supported: ${entity.path}.',
          );
        }
        collected.add(
          _PayloadEntry(
            'assets/flutter_assets/$relPath',
            File(resolved).readAsBytesSync(),
          ),
        );
      }
    }
  }

  walk(assetsDir, '');
  return collected;
}

/// Whether the payload file at archive [path] is stored uncompressed:
/// `.so` files (zipalign page-aligns them) and the aapt2 default no-compress
/// extensions, plus the caller's `nocompress_extensions`.
///
/// Every comparison is a case-sensitive suffix match, like aapt2: each
/// extension matches `.<ext>` at the end of the path. A user extension may
/// carry its own leading dot.
bool _storeUncompressedByName(String path, Set<String> extraNoCompress) {
  bool suffix(String ext) => ext.isNotEmpty && path.endsWith('.$ext');
  if (suffix('so')) return true;
  for (final ext in _aaptNoCompressExtensions) {
    if (suffix(ext)) return true;
  }
  for (var ext in extraNoCompress) {
    if (ext.startsWith('.')) ext = ext.substring(1);
    if (suffix(ext)) return true;
  }
  return false;
}

/// ZIP32 field limit: values at or above it need ZIP64, which APKs never use.
const int _zip32Limit = 0xFFFFFFFF;

/// Encodes one local file header plus payload and its central directory
/// record for [path] holding [data].
///
/// Entries that [_storeUncompressedByName] selects are written stored without
/// ever deflating (which is also what keeps large `.so` files fast);
/// anything else is deflated unless that would grow it. [crc] reuses a
/// verified checksum (jar entries); otherwise it is computed here.
({Uint8List local, Uint8List central}) _encodeEntry(
  String path,
  Uint8List data, {
  int? crc,
  Set<String> extraNoCompress = const {},
}) {
  final nameBytes = utf8.encode(path);
  if (nameBytes.length >= 0xFFFF) {
    throw FormatException(
      'apk-overlay: entry name too long for ZIP32: $path.',
    );
  }
  if (data.length >= _zip32Limit) {
    throw FormatException(
      'apk-overlay: entry $path is ${data.length} bytes, larger than the '
      'ZIP32 limit; ZIP64 archives are not supported.',
    );
  }
  final mustStore = _storeUncompressedByName(path, extraNoCompress);
  final Uint8List payload;
  final int method;
  if (mustStore) {
    payload = data;
    method = 0;
  } else {
    final deflated = Uint8List.fromList(ZLibEncoder(raw: true).convert(data));
    if (deflated.length >= _zip32Limit) {
      throw FormatException(
        'apk-overlay: compressed entry $path is ${deflated.length} bytes, '
        'larger than the ZIP32 limit; ZIP64 archives are not supported.',
      );
    }
    if (deflated.length >= data.length) {
      payload = data;
      method = 0;
    } else {
      payload = deflated;
      method = 8;
    }
  }
  final checksum = crc ?? crc32(data);

  final localBytes = BytesBuilder(copy: false)
    ..add(
      _localFileHeader(
        nameBytes,
        method,
        checksum,
        payload.length,
        data.length,
      ),
    )
    ..add(payload);
  return (
    local: localBytes.takeBytes(),
    central: _centralRecord(
      nameBytes,
      method,
      checksum,
      payload.length,
      data.length,
    ),
  );
}

/// The local file header for an entry with [nameBytes] holding [payloadLen]
/// of [dataLen] bytes with [checksum], before its payload.
Uint8List _localFileHeader(
  List<int> nameBytes,
  int method,
  int checksum,
  int payloadLen,
  int dataLen,
) {
  final local = ByteData(30 + nameBytes.length);
  _setUint32LE(local, 0, 0x04034b50);
  _setUint16LE(local, 4, 20);
  _setUint16LE(local, 6, 0x0800);
  _setUint16LE(local, 8, method);
  _setUint16LE(local, 10, _overlayDosTime);
  _setUint16LE(local, 12, _overlayDosDate);
  _setUint32LE(local, 14, checksum);
  _setUint32LE(local, 18, payloadLen);
  _setUint32LE(local, 22, dataLen);
  _setUint16LE(local, 26, nameBytes.length);
  _setUint16LE(local, 28, 0);
  local.buffer.asUint8List().setRange(30, 30 + nameBytes.length, nameBytes);
  return local.buffer.asUint8List();
}

/// The central directory record for an entry with [nameBytes] holding
/// [payloadLen] of [dataLen] bytes with [checksum].
///
/// The local header offset is patched by the caller.
Uint8List _centralRecord(
  List<int> nameBytes,
  int method,
  int checksum,
  int payloadLen,
  int dataLen,
) {
  final central = ByteData(46 + nameBytes.length);
  _setUint32LE(central, 0, 0x02014b50);
  _setUint16LE(central, 4, (3 << 8) | 20);
  _setUint16LE(central, 6, 20);
  _setUint16LE(central, 8, 0x0800);
  _setUint16LE(central, 10, method);
  _setUint16LE(central, 12, _overlayDosTime);
  _setUint16LE(central, 14, _overlayDosDate);
  _setUint32LE(central, 16, checksum);
  _setUint32LE(central, 20, payloadLen);
  _setUint32LE(central, 24, dataLen);
  _setUint16LE(central, 28, nameBytes.length);
  _setUint16LE(central, 30, 0);
  _setUint16LE(central, 32, 0);
  _setUint16LE(central, 34, 0);
  _setUint16LE(central, 36, 0);
  _setUint32LE(central, 38, (_overlayFileMode << 16));
  central.buffer.asUint8List().setRange(46, 46 + nameBytes.length, nameBytes);
  return central.buffer.asUint8List();
}

/// Injects the Flutter payload into a copy of the unsigned base APK.
///
/// [baseApkPath] must be an unsigned APK: no v1 signature files
/// (`META-INF/*.SF/*.RSA/*.DSA/*.EC`) and no APK Signing Block. (A bare
/// `META-INF/MANIFEST.MF` is fine — singlejar adds one to every unsigned
/// APK.) Injecting into a signed APK would silently invalidate its
/// signatures. The caller signs the returned archive with `apksigner`.
///
/// [nocompressExtensions] stores additional payload files uncompressed,
/// mirroring `android_binary(nocompress_extensions = ...)`; the aapt2
/// defaults always apply. Matching is a case-sensitive suffix match.
void spliceApkOverlay({
  required String baseApkPath,
  required String nativeLibsJarPath,
  required String flutterAssetsDirPath,
  required String outputApkPath,
  Set<String> nocompressExtensions = const {},
}) {
  final base = File(baseApkPath).readAsBytesSync();
  final central = _readCentral(base);

  final payload = <_PayloadEntry>[
    ..._payloadFromNativeLibsJar(File(nativeLibsJarPath).readAsBytesSync()),
    ..._payloadFromFlutterAssets(Directory(flutterAssetsDirPath)),
  ];
  for (final entry in payload) {
    if (central.names.contains(entry.path)) {
      throw ArgumentError(
        'apk-overlay: payload entry ${entry.path} already exists in the '
        'base APK. Build the base android_binary without the Flutter payload.',
      );
    }
  }
  _refuseSignedBase(base, central);

  final out = BytesBuilder(copy: false)
    ..add(Uint8List.sublistView(base, 0, central.cdOffset));
  final newCentral = BytesBuilder(copy: false);
  final offset = _appendPayloadEntries(
    out: out,
    newCentral: newCentral,
    offset: central.cdOffset,
    payload: payload,
    nocompressExtensions: nocompressExtensions,
  );

  final totalCount = central.count + payload.length;
  if (totalCount >= 0xFFFF) {
    throw ArgumentError('apk-overlay: too many entries for a ZIP archive.');
  }
  final newCentralBytes = newCentral.takeBytes();
  out.add(central.records);
  out.add(newCentralBytes);

  final cdOffset = offset;
  final cdSize = central.records.length + newCentralBytes.length;
  if (cdOffset >= _zip32Limit) {
    throw FormatException(
      'apk-overlay: central directory offset $cdOffset exceeds the ZIP32 '
      'limit; ZIP64 archives are not supported.',
    );
  }
  if (cdSize >= _zip32Limit) {
    throw FormatException(
      'apk-overlay: central directory size $cdSize exceeds the ZIP32 '
      'limit; ZIP64 archives are not supported.',
    );
  }
  out.add(_encodeEndOfCentralDirectory(totalCount, cdSize, cdOffset));

  final output = File(outputApkPath);
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(out.takeBytes(), flush: true);
}

/// Refuses a [base] APK that already carries signatures.
///
/// Injecting into a signed APK would silently invalidate its signatures: a
/// bare `META-INF/MANIFEST.MF` is fine — singlejar adds one to every unsigned
/// APK — but the signature files apksigner adds (`.SF`/`.RSA`/`.DSA`/`.EC`)
/// and the APK Signing Block prove signing.
void _refuseSignedBase(
  Uint8List base,
  ({Set<String> names, Uint8List records, int cdOffset, int count}) central,
) {
  for (final signedMarker in [
    // NB: META-INF/MANIFEST.MF alone is NOT a signature marker — singlejar
    // adds a bare manifest to every unsigned APK it builds. Only the
    // signature files apksigner adds (.SF/.RSA/.DSA/.EC) prove signing.
    'META-INF/CERT.SF',
    'META-INF/CERT.RSA',
    'META-INF/CERT.DSA',
    'META-INF/CERT.EC',
  ]) {
    if (central.names.contains(signedMarker)) {
      throw ArgumentError(
        'apk-overlay: base APK looks signed (contains $signedMarker). '
        'Pass the unsigned APK instead; the caller signs after injection.',
      );
    }
  }
  // A v2/v3-signed APK carries no META-INF signature files when v1 signing
  // is disabled; its APK Signing Block sits between the local entries and
  // the central directory. Injecting into it would silently invalidate the
  // block signature, so refuse: the 16-byte magic ends exactly where the
  // central directory begins.
  const signingBlockMagic = 'APK Sig Block 42';
  if (central.cdOffset >= 16) {
    final magicBytes = base.sublist(
      central.cdOffset - 16,
      central.cdOffset,
    );
    // Byte-wise: the preceding bytes are arbitrary zip content, usually not
    // valid UTF-8, so decode-then-compare would throw on innocent APKs.
    final expected = utf8.encode(signingBlockMagic);
    var matches = magicBytes.length == expected.length;
    for (var i = 0; matches && i < expected.length; i++) {
      if (magicBytes[i] != expected[i]) matches = false;
    }
    if (matches) {
      throw ArgumentError(
        'apk-overlay: base APK looks v2-signed (APK Signing Block present). '
        'Pass the unsigned APK instead; the caller signs after injection.',
      );
    }
  }
}

/// Appends [payload] entries to [out] and their records to [newCentral],
/// patching each record's local header offset; returns the offset past the
/// last entry written.
int _appendPayloadEntries({
  required BytesBuilder out,
  required BytesBuilder newCentral,
  required int offset,
  required List<_PayloadEntry> payload,
  required Set<String> nocompressExtensions,
}) {
  var cursor = offset;
  for (final entry in payload) {
    if (cursor >= _zip32Limit) {
      throw FormatException(
        'apk-overlay: local header offset $cursor for ${entry.path} '
        'exceeds the ZIP32 limit; ZIP64 archives are not supported.',
      );
    }
    final encoded = _encodeEntry(
      entry.path,
      entry.data,
      crc: entry.crc,
      extraNoCompress: nocompressExtensions,
    );
    final centralBd = ByteData.sublistView(encoded.central);
    _setUint32LE(centralBd, 42, cursor);
    out.add(encoded.local);
    newCentral.add(encoded.central);
    cursor += encoded.local.length;
  }
  return cursor;
}

/// The End of Central Directory record for [totalCount] entries whose central
/// directory holds [cdSize] bytes at [cdOffset].
Uint8List _encodeEndOfCentralDirectory(
  int totalCount,
  int cdSize,
  int cdOffset,
) {
  final eocd = ByteData(22);
  _setUint32LE(eocd, 0, 0x06054b50);
  _setUint16LE(eocd, 4, 0);
  _setUint16LE(eocd, 6, 0);
  _setUint16LE(eocd, 8, totalCount);
  _setUint16LE(eocd, 10, totalCount);
  _setUint32LE(eocd, 12, cdSize);
  _setUint32LE(eocd, 16, cdOffset);
  _setUint16LE(eocd, 20, 0);
  return eocd.buffer.asUint8List();
}

/// Dispatches the CLI arguments for the `apk-overlay` subcommand.
void runApkOverlay(List<String> args) {
  String? base;
  String? nativeLibsJar;
  String? flutterAssets;
  String? output;
  final nocompressExtensions = <String>{};

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--base':
        if (i + 1 >= args.length) throw ArgumentError('Missing value for $arg');
        base = args[++i];
      case '--native-libs-jar':
        if (i + 1 >= args.length) throw ArgumentError('Missing value for $arg');
        nativeLibsJar = args[++i];
      case '--flutter-assets':
        if (i + 1 >= args.length) throw ArgumentError('Missing value for $arg');
        flutterAssets = args[++i];
      case '--output':
        if (i + 1 >= args.length) throw ArgumentError('Missing value for $arg');
        output = args[++i];
      case '--nocompress-extensions':
        if (i + 1 >= args.length) throw ArgumentError('Missing value for $arg');
        nocompressExtensions.addAll(
          args[++i].split(',').where((e) => e.isNotEmpty),
        );
      default:
        throw ArgumentError('Unknown option for apk-overlay: $arg');
    }
  }

  if (base == null ||
      nativeLibsJar == null ||
      flutterAssets == null ||
      output == null) {
    throw ArgumentError(
      'Usage: android_bundle.dart apk-overlay --base <unsigned.apk> '
      '--native-libs-jar <jar> --flutter-assets <dir> --output <unsigned.apk> '
      '[--nocompress-extensions <csv>]',
    );
  }

  spliceApkOverlay(
    baseApkPath: base,
    nativeLibsJarPath: nativeLibsJar,
    flutterAssetsDirPath: flutterAssets,
    outputApkPath: output,
    nocompressExtensions: nocompressExtensions,
  );
}
