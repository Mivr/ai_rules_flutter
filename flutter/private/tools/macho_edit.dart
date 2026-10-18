// Pure-Dart Mach-O 64-bit binary patcher and stub generator.
//
// Replaces macOS-only `xcrun vtool`, `xcrun install_name_tool`, and
// `xcrun clang -dynamiclib` (for empty debug stub dylibs) so Apple framework
// packaging and Mach-O post-processing work identically on Linux and macOS.
//
// Zero external pub dependencies (only `dart:convert`, `dart:io`,
// `dart:math`, `dart:typed_data`).
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// Mach-O 32-bit, 64-bit, and Universal (Fat) constants.
const int mhMagic32 = 0xfeedface;
const int mhCigam32 = 0xcefaedfe;
const int mhMagic64 = 0xfeedfacf;
const int mhCigam64 = 0xcffaedfe;
const int fatMagic = 0xcafebabe;
const int fatCigam = 0xbebafeca;
const int fatMagic64 = 0xcafebabf;
const int fatCigam64 = 0xbfbafeca;
const int mhHeaderSize64 = 32;

const int cpuArchAbi64 = 0x01000000;
const int cpuTypeI386 = 0x00000007;
const int cpuTypeX86_64 = cpuTypeI386 | cpuArchAbi64; // 0x01000007
const int cpuSubtypeX86_64All = 3;
const int cpuTypeArm = 0x0000000c;
const int cpuTypeArm64 = cpuTypeArm | cpuArchAbi64; // 0x0100000c
const int cpuSubtypeArm64All = 0;

const int mhExecute = 0x2;
const int mhDylib = 0x6;
const int mhNoundefs = 0x00000001;
const int mhDyldlink = 0x00000004;
const int mhTwolevel = 0x00000080;
const int mhNoReexportedDylibs = 0x00100000;
const int mhPie = 0x00200000;

// Load command constants.
const int lcReqDyld = 0x80000000;
const int lcSymtab = 0x02;
const int lcDysymtab = 0x0b;
const int lcIdDylib = 0x0d;
const int lcSegment64 = 0x19;
const int lcUuid = 0x1b;
const int lcRpath = 0x1c | lcReqDyld; // 0x8000001c
const int lcCodeSignature = 0x1d;
const int lcDyldInfo = 0x22;
const int lcDyldInfoOnly = 0x22 | lcReqDyld; // 0x80000022
const int lcVersionMinMacosx = 0x24;
const int lcVersionMinIphoneos = 0x25;
const int lcFunctionStarts = 0x26;
const int lcDataInCode = 0x29;
const int lcVersionMinTvos = 0x2f;
const int lcVersionMinWatchos = 0x30;
const int lcBuildVersion = 0x32;
const int lcDyldExportsTrie = 0x33 | lcReqDyld;
const int lcDyldChainedFixups = 0x34 | lcReqDyld;

// Platform constants for LC_BUILD_VERSION.
const int platformMacos = 1;
const int platformIos = 2;
const int platformIosSimulator = 7;

// Code signature constants (big-endian in Mach-O).
const int csMagicEmbeddedSignature = 0xfade0cc0;
const int csMagicCodeDirectory = 0xfade0c02;
const int csHashTypeSha256 = 2;

void main(List<String> args) {
  if (args.isEmpty) {
    _usageError(
      'Expected subcommand: "patch", "stub", "fat", "verify", "copy-assets", '
      '"assemble-macos-framework", or "copy-files".',
    );
  }
  final subcommand = args.first;
  final rest = args.sublist(1);
  switch (subcommand) {
    case 'patch':
      _runPatch(rest);
    case 'stub':
      _runStub(rest);
    case 'fat':
      _runFat(rest);
    case 'verify':
      _runVerify(rest);
    case 'copy-assets':
      _runCopyAssets(rest);
    case 'assemble-macos-framework':
      _runAssembleMacosFramework(rest);
    case 'copy-files':
      _runCopyFiles(rest);
    default:
      _usageError(
        'Unknown subcommand "$subcommand". Expected "patch", "stub", "fat", '
        '"verify", "copy-assets", "assemble-macos-framework", or "copy-files".',
      );
  }
}

Never _usageError(String message) {
  stderr.writeln('macho_edit: $message');
  exit(64);
}

String _basename(String path) {
  final normalized = path.replaceAll(r'\', '/');
  final parts = normalized.split('/').where((s) => s.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String _stripExtension(String name) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// Checks whether a non-Mach-O or 32-bit binary is explicitly named in [allowList].
bool _isAllowedNonMacho(
  Set<String> allowList, {
  required String inputPath,
  String? outputPath,
  String? installName,
}) {
  if (allowList.isEmpty) return false;
  if (allowList.contains('*')) return true;

  final candidates = <String>{};
  void addPathCandidates(String? p) {
    if (p == null || p.isEmpty) return;
    candidates.add(p);
    final base = _basename(p);
    candidates.add(base);
    final stem = _stripExtension(base);
    candidates.add(stem);
    if (stem.startsWith('lib') && stem.length > 3) {
      candidates.add(stem.substring(3));
    }
    for (final seg in p.replaceAll(r'\', '/').split('/')) {
      if (seg.endsWith('.framework')) {
        candidates.add(seg);
        candidates.add(seg.substring(0, seg.length - '.framework'.length));
      }
    }
  }

  addPathCandidates(inputPath);
  addPathCandidates(outputPath);
  addPathCandidates(installName);
  return candidates.any(allowList.contains);
}

void _runPatch(List<String> args) {
  String? inputPath;
  String? outputPath;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? installName;
  String? arch;
  final rpaths = <String>[];
  final allowNonMacho = <String>{};

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--allow-non-macho=')) {
      final value = arg.substring('--allow-non-macho='.length);
      for (final part in value.split(',')) {
        if (part.isNotEmpty) allowNonMacho.add(part);
      }
      continue;
    }
    switch (arg) {
      case '--input':
        if (++i >= args.length) _usageError('--input requires a value');
        inputPath = args[i];
      case '--output':
        if (++i >= args.length) _usageError('--output requires a value');
        outputPath = args[i];
      case '--platform':
        if (++i >= args.length) _usageError('--platform requires a value');
        platformName = args[i];
      case '--min-os':
        if (++i >= args.length) _usageError('--min-os requires a value');
        minOsStr = args[i];
      case '--sdk-version':
        if (++i >= args.length) _usageError('--sdk-version requires a value');
        sdkVersionStr = args[i];
      case '--install-name':
        if (++i >= args.length) _usageError('--install-name requires a value');
        installName = args[i];
      case '--arch':
        if (++i >= args.length) _usageError('--arch requires a value');
        arch = args[i];
      case '--rpath':
        if (++i >= args.length) _usageError('--rpath requires a value');
        for (final part in args[i].split(',')) {
          if (part.isNotEmpty) rpaths.add(part);
        }
      case '--allow-non-macho':
        if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
          _usageError(
            '--allow-non-macho requires an explicit binary or framework name',
          );
        }
        i++;
        for (final part in args[i].split(',')) {
          if (part.isNotEmpty) allowNonMacho.add(part);
        }
      default:
        _usageError('Unknown flag for patch: $arg');
    }
  }

  if (inputPath == null || outputPath == null) {
    _usageError('patch requires --input and --output');
  }

  int? platform;
  int? minOs;
  int? sdkVersion;
  if (platformName != null || minOsStr != null) {
    if (platformName == null || minOsStr == null) {
      _usageError('--platform and --min-os must be provided together');
    }
    platform = parsePlatform(platformName);
    minOs = parsePackedVersion(minOsStr);
    sdkVersion = sdkVersionStr != null
        ? parsePackedVersion(sdkVersionStr)
        : minOs;
  }

  final inputBytes = File(inputPath).readAsBytesSync();
  final isAllowed = _isAllowedNonMacho(
    allowNonMacho,
    inputPath: inputPath,
    outputPath: outputPath,
    installName: installName,
  );

  if (!isMachO64(inputBytes) && !isFatMachO(inputBytes)) {
    if (isAllowed) {
      final outFile = File(outputPath);
      outFile.parent.createSync(recursive: true);
      outFile.writeAsBytesSync(inputBytes);
      return;
    }
    if (isMachO32(inputBytes)) {
      throw FormatException(
        'Input file "$inputPath" is an unsupported 32-bit Mach-O binary '
        '(0xfeedface). Only 64-bit Mach-O binaries are supported unless '
        'explicitly listed in allow_non_macho.',
      );
    }
    throw FormatException(
      'Input file "$inputPath" is a non-Mach-O file (not a 64-bit or '
      'universal Mach-O binary). Only Mach-O binaries are permitted unless '
      'explicitly listed in allow_non_macho.',
    );
  }

  final Uint8List patched;
  try {
    patched = patchMachO(
      inputBytes,
      platform: platform,
      minOs: minOs,
      sdkVersion: sdkVersion,
      installName: installName,
      rpaths: rpaths,
      arch: arch,
    );
  } on FormatException catch (e) {
    if (isAllowed) {
      final outFile = File(outputPath);
      outFile.parent.createSync(recursive: true);
      outFile.writeAsBytesSync(inputBytes);
      return;
    }
    throw FormatException('Input file "$inputPath": ${e.message}');
  }

  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(patched);
}

void _runStub(List<String> args) {
  String? outputPath;
  String? arch;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? installName;
  var typeStr = 'dylib';

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--output':
        if (++i >= args.length) _usageError('--output requires a value');
        outputPath = args[i];
      case '--arch':
        if (++i >= args.length) _usageError('--arch requires a value');
        arch = args[i];
      case '--platform':
        if (++i >= args.length) _usageError('--platform requires a value');
        platformName = args[i];
      case '--min-os':
        if (++i >= args.length) _usageError('--min-os requires a value');
        minOsStr = args[i];
      case '--sdk-version':
        if (++i >= args.length) _usageError('--sdk-version requires a value');
        sdkVersionStr = args[i];
      case '--install-name':
        if (++i >= args.length) _usageError('--install-name requires a value');
        installName = args[i];
      case '--type':
        if (++i >= args.length) _usageError('--type requires a value');
        typeStr = args[i];
      default:
        _usageError('Unknown flag for stub: $arg');
    }
  }

  if (typeStr != 'dylib' && typeStr != 'execute') {
    _usageError('--type must be "dylib" or "execute", got "$typeStr"');
  }

  if (outputPath == null ||
      arch == null ||
      platformName == null ||
      minOsStr == null ||
      (typeStr == 'dylib' && installName == null)) {
    _usageError(
      'stub requires --output, --arch, --platform, --min-os, and --install-name',
    );
  }

  final platform = parsePlatform(platformName);
  final minOs = parsePackedVersion(minOsStr);
  final sdkVersion = sdkVersionStr != null
      ? parsePackedVersion(sdkVersionStr)
      : minOs;

  final bytes = generateStubMachO(
    arch: arch,
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersion,
    installName: installName ?? '',
    fileType: typeStr == 'execute' ? mhExecute : mhDylib,
  );

  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(bytes);
}

void _copyDirDereferencingSync(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  if (!src.existsSync()) return;
  final children = src.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in children) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final destPath = '${dst.path}/$name';
    if (entity is Link) {
      final resolved = entity.resolveSymbolicLinksSync();
      if (FileSystemEntity.isDirectorySync(resolved)) {
        _copyDirDereferencingSync(Directory(resolved), Directory(destPath));
      } else {
        File(resolved).copySync(destPath);
      }
    } else if (entity is Directory) {
      _copyDirDereferencingSync(entity, Directory(destPath));
    } else if (entity is File) {
      entity.copySync(destPath);
    }
  }
}

void _runCopyAssets(List<String> args) {
  String? srcPath;
  String? dstPath;
  String? kernelBlobPath;
  String? vmSnapshotPath;
  String? isolateSnapshotPath;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--src':
        if (++i >= args.length) _usageError('--src requires a value');
        srcPath = args[i];
      case '--dst':
        if (++i >= args.length) _usageError('--dst requires a value');
        dstPath = args[i];
      case '--kernel-blob':
        if (++i >= args.length) _usageError('--kernel-blob requires a value');
        kernelBlobPath = args[i];
      case '--vm-snapshot-data':
        if (++i >= args.length) {
          _usageError('--vm-snapshot-data requires a value');
        }
        vmSnapshotPath = args[i];
      case '--isolate-snapshot-data':
        if (++i >= args.length) {
          _usageError('--isolate-snapshot-data requires a value');
        }
        isolateSnapshotPath = args[i];
      default:
        _usageError('Unknown flag for copy-assets: $arg');
    }
  }

  if (srcPath == null || dstPath == null) {
    _usageError('copy-assets requires --src and --dst');
  }

  final dstDir = Directory(dstPath);
  _copyDirDereferencingSync(Directory(srcPath), dstDir);

  if (kernelBlobPath != null && kernelBlobPath.isNotEmpty) {
    File(kernelBlobPath).copySync('${dstDir.path}/kernel_blob.bin');
  }
  if (vmSnapshotPath != null && vmSnapshotPath.isNotEmpty) {
    File(vmSnapshotPath).copySync('${dstDir.path}/vm_snapshot_data');
  }
  if (isolateSnapshotPath != null && isolateSnapshotPath.isNotEmpty) {
    File(isolateSnapshotPath).copySync('${dstDir.path}/isolate_snapshot_data');
  }
}

void _createSymlinkReplacingSync(String linkPath, String target) {
  final link = Link(linkPath);
  if (FileSystemEntity.typeSync(linkPath, followLinks: false) !=
      FileSystemEntityType.notFound) {
    link.deleteSync();
  }
  link.createSync(target);
}

final Uint32List _crc32Table = () {
  final table = Uint32List(256);
  for (var i = 0; i < 256; i++) {
    var c = i;
    for (var k = 0; k < 8; k++) {
      if ((c & 1) != 0) {
        c = 0xEDB88320 ^ (c >>> 1);
      } else {
        c = c >>> 1;
      }
    }
    table[i] = c;
  }
  return table;
}();

int _crc32(List<int> bytes) {
  var c = 0xFFFFFFFF;
  for (var i = 0; i < bytes.length; i++) {
    c = _crc32Table[(c ^ bytes[i]) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// An entry in a deterministic framework ZIP archive.
class FrameworkZipEntry {
  final String path;
  final Uint8List data;
  final bool isExecutable;
  final bool isSymlink;

  const FrameworkZipEntry({
    required this.path,
    required this.data,
    this.isExecutable = false,
    this.isSymlink = false,
  });
}

/// Builds a deterministic ZIP archive for [frameworkDir] (e.g. `App.framework`)
/// suitable for `rules_apple`'s `AppleBundleInfo.archive` (`bundle_merge_zips`).
///
/// Only file and symlink entries are emitted (no directory entries), matching
/// `rules_apple`'s `imported_dynamic_framework_processor.py` and `bundletool.py`.
/// Symbolic links are stored with Unix mode `0120777` (`S_IFLNK`) and
/// uncompressed target bytes; [executableRelPaths] receive `0100755`.
Uint8List createFrameworkZipBytes(
  Directory frameworkDir, {
  required String archiveRootName,
  Set<String> executableRelPaths = const {},
}) {
  final entries = <FrameworkZipEntry>[];

  void walk(Directory dir, String relPrefix) {
    final children = dir.listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entity in children) {
      final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final relPath = '$relPrefix/$name';
      if (entity is Link) {
        final target = entity.targetSync();
        entries.add(
          FrameworkZipEntry(
            path: relPath,
            data: Uint8List.fromList(utf8.encode(target)),
            isSymlink: true,
          ),
        );
      } else if (entity is Directory) {
        walk(entity, relPath);
      } else if (entity is File) {
        final stat = entity.statSync();
        final isExec =
            executableRelPaths.contains(relPath) || ((stat.mode & 0x49) != 0);
        entries.add(
          FrameworkZipEntry(
            path: relPath,
            data: entity.readAsBytesSync(),
            isExecutable: isExec,
          ),
        );
      }
    }
  }

  walk(frameworkDir, archiveRootName);
  entries.sort((a, b) => a.path.compareTo(b.path));

  final localParts = BytesBuilder(copy: false);
  final centralParts = BytesBuilder(copy: false);
  final rawDeflate = ZLibCodec(raw: true);

  const dosTime = 0x0000;
  const dosDate = 0x0021;
  const versionMadeBy = (3 << 8) | 20;
  const versionNeeded = 20;

  var offset = 0;
  for (final entry in entries) {
    final nameBytes = utf8.encode(entry.path);
    final uncompressed = entry.data;
    final crc = _crc32(uncompressed);

    var compressionMethod = 0;
    var payload = uncompressed;
    if (!entry.isSymlink && uncompressed.isNotEmpty) {
      final deflated = Uint8List.fromList(rawDeflate.encode(uncompressed));
      if (deflated.length < uncompressed.length) {
        compressionMethod = 8;
        payload = deflated;
      }
    }

    final int externalAttrs;
    if (entry.isSymlink) {
      externalAttrs = 0xA1FF << 16; // lrwxrwxrwx (0120777)
    } else if (entry.isExecutable) {
      externalAttrs = 0x81ED << 16; // -rwxr-xr-x (0100755)
    } else {
      externalAttrs = 0x81A4 << 16; // -rw-r--r-- (0100644)
    }

    final localHeader = ByteData(30 + nameBytes.length);
    localHeader.setUint32(0, 0x04034b50, Endian.little);
    localHeader.setUint16(4, versionNeeded, Endian.little);
    localHeader.setUint16(6, 0x0800, Endian.little);
    localHeader.setUint16(8, compressionMethod, Endian.little);
    localHeader.setUint16(10, dosTime, Endian.little);
    localHeader.setUint16(12, dosDate, Endian.little);
    localHeader.setUint32(14, crc, Endian.little);
    localHeader.setUint32(18, payload.length, Endian.little);
    localHeader.setUint32(22, uncompressed.length, Endian.little);
    localHeader.setUint16(26, nameBytes.length, Endian.little);
    localHeader.setUint16(28, 0, Endian.little);
    localHeader.buffer.asUint8List().setRange(
      30,
      30 + nameBytes.length,
      nameBytes,
    );

    localParts.add(localHeader.buffer.asUint8List());
    localParts.add(payload);

    final centralHeader = ByteData(46 + nameBytes.length);
    centralHeader.setUint32(0, 0x02014b50, Endian.little);
    centralHeader.setUint16(4, versionMadeBy, Endian.little);
    centralHeader.setUint16(6, versionNeeded, Endian.little);
    centralHeader.setUint16(8, 0x0800, Endian.little);
    centralHeader.setUint16(10, compressionMethod, Endian.little);
    centralHeader.setUint16(12, dosTime, Endian.little);
    centralHeader.setUint16(14, dosDate, Endian.little);
    centralHeader.setUint32(16, crc, Endian.little);
    centralHeader.setUint32(20, payload.length, Endian.little);
    centralHeader.setUint32(24, uncompressed.length, Endian.little);
    centralHeader.setUint16(28, nameBytes.length, Endian.little);
    centralHeader.setUint16(30, 0, Endian.little);
    centralHeader.setUint16(32, 0, Endian.little);
    centralHeader.setUint16(34, 0, Endian.little);
    centralHeader.setUint16(36, 0, Endian.little);
    centralHeader.setUint32(38, externalAttrs, Endian.little);
    centralHeader.setUint32(42, offset, Endian.little);
    centralHeader.buffer.asUint8List().setRange(
      46,
      46 + nameBytes.length,
      nameBytes,
    );

    centralParts.add(centralHeader.buffer.asUint8List());
    offset += 30 + nameBytes.length + payload.length;
  }

  final centralBytes = centralParts.takeBytes();
  final eocd = ByteData(22);
  eocd.setUint32(0, 0x06054b50, Endian.little);
  eocd.setUint16(4, 0, Endian.little);
  eocd.setUint16(6, 0, Endian.little);
  eocd.setUint16(8, entries.length, Endian.little);
  eocd.setUint16(10, entries.length, Endian.little);
  eocd.setUint32(12, centralBytes.length, Endian.little);
  eocd.setUint32(16, offset, Endian.little);
  eocd.setUint16(20, 0, Endian.little);

  localParts.add(centralBytes);
  localParts.add(eocd.buffer.asUint8List());
  return localParts.takeBytes();
}

/// Decodes a ZIP archive into [FrameworkZipEntry] items for inspection/testing.
List<FrameworkZipEntry> readFrameworkZipEntries(Uint8List zipBytes) {
  final bd = ByteData.sublistView(zipBytes);
  var eocdOffset = -1;
  for (var i = zipBytes.length - 22; i >= 0; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocdOffset = i;
      break;
    }
  }
  if (eocdOffset == -1) {
    throw const FormatException('Invalid ZIP archive: EOCD not found.');
  }
  final entryCount = bd.getUint16(eocdOffset + 10, Endian.little);
  final cdOffset = bd.getUint32(eocdOffset + 16, Endian.little);
  final rawInflate = ZLibCodec(raw: true);

  final entries = <FrameworkZipEntry>[];
  var pos = cdOffset;
  for (var i = 0; i < entryCount; i++) {
    if (bd.getUint32(pos, Endian.little) != 0x02014b50) {
      throw FormatException('Invalid central directory header at $pos.');
    }
    final method = bd.getUint16(pos + 10, Endian.little);
    final compressedSize = bd.getUint32(pos + 20, Endian.little);
    final nameLen = bd.getUint16(pos + 28, Endian.little);
    final extraLen = bd.getUint16(pos + 30, Endian.little);
    final commentLen = bd.getUint16(pos + 32, Endian.little);
    final externalAttrs = bd.getUint32(pos + 38, Endian.little);
    final localOffset = bd.getUint32(pos + 42, Endian.little);

    final path = utf8.decode(zipBytes.sublist(pos + 46, pos + 46 + nameLen));
    pos += 46 + nameLen + extraLen + commentLen;

    final localNameLen = bd.getUint16(localOffset + 26, Endian.little);
    final localExtraLen = bd.getUint16(localOffset + 28, Endian.little);
    final dataStart = localOffset + 30 + localNameLen + localExtraLen;
    final rawPayload = zipBytes.sublist(dataStart, dataStart + compressedSize);

    final Uint8List data;
    if (method == 0) {
      data = Uint8List.fromList(rawPayload);
    } else if (method == 8) {
      data = Uint8List.fromList(rawInflate.decode(rawPayload));
    } else {
      throw UnsupportedError('Unsupported ZIP compression method: $method');
    }

    final unixMode = (externalAttrs >>> 16) & 0xFFFF;
    final fileType = unixMode & 0xF000;
    final isSymlink = fileType == 0xA000;
    final isExec = !isSymlink && ((unixMode & 0x49) != 0);

    entries.add(
      FrameworkZipEntry(
        path: path,
        data: data,
        isExecutable: isExec,
        isSymlink: isSymlink,
      ),
    );
  }
  return entries;
}

void _runAssembleMacosFramework(List<String> args) {
  String? binaryPath;
  String? infoPlistPath;
  String? assetsPath;
  String? outputDirPath;
  String? outputZipPath;
  String? kernelBlobPath;
  String? vmSnapshotPath;
  String? isolateSnapshotPath;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--binary':
        if (++i >= args.length) _usageError('--binary requires a value');
        binaryPath = args[i];
      case '--info-plist':
        if (++i >= args.length) _usageError('--info-plist requires a value');
        infoPlistPath = args[i];
      case '--assets':
        if (++i >= args.length) _usageError('--assets requires a value');
        assetsPath = args[i];
      case '--output-dir':
        if (++i >= args.length) _usageError('--output-dir requires a value');
        outputDirPath = args[i];
      case '--output-zip':
        if (++i >= args.length) _usageError('--output-zip requires a value');
        outputZipPath = args[i];
      case '--kernel-blob':
        if (++i >= args.length) _usageError('--kernel-blob requires a value');
        kernelBlobPath = args[i];
      case '--vm-snapshot-data':
        if (++i >= args.length) {
          _usageError('--vm-snapshot-data requires a value');
        }
        vmSnapshotPath = args[i];
      case '--isolate-snapshot-data':
        if (++i >= args.length) {
          _usageError('--isolate-snapshot-data requires a value');
        }
        isolateSnapshotPath = args[i];
      default:
        _usageError('Unknown flag for assemble-macos-framework: $arg');
    }
  }

  if (binaryPath == null ||
      infoPlistPath == null ||
      assetsPath == null ||
      outputDirPath == null) {
    _usageError(
      'assemble-macos-framework requires --binary, --info-plist, --assets, '
      'and --output-dir',
    );
  }

  final fwDir = outputDirPath.endsWith('.framework')
      ? Directory(outputDirPath)
      : Directory('$outputDirPath/App.framework');
  final fwDirName = fwDir.uri.pathSegments.where((s) => s.isNotEmpty).last;
  final fwName = fwDirName.substring(0, fwDirName.length - '.framework'.length);
  final versionADir = Directory('${fwDir.path}/Versions/A');
  final resourcesDir = Directory('${versionADir.path}/Resources');
  final assetsDestDir = Directory('${resourcesDir.path}/flutter_assets');
  assetsDestDir.createSync(recursive: true);

  File(binaryPath).copySync('${versionADir.path}/$fwName');
  File(infoPlistPath).copySync('${resourcesDir.path}/Info.plist');
  _copyDirDereferencingSync(Directory(assetsPath), assetsDestDir);

  if (kernelBlobPath != null && kernelBlobPath.isNotEmpty) {
    File(kernelBlobPath).copySync('${assetsDestDir.path}/kernel_blob.bin');
  }
  if (vmSnapshotPath != null && vmSnapshotPath.isNotEmpty) {
    File(vmSnapshotPath).copySync('${assetsDestDir.path}/vm_snapshot_data');
  }
  if (isolateSnapshotPath != null && isolateSnapshotPath.isNotEmpty) {
    File(
      isolateSnapshotPath,
    ).copySync('${assetsDestDir.path}/isolate_snapshot_data');
  }

  _createSymlinkReplacingSync('${fwDir.path}/Versions/Current', 'A');
  _createSymlinkReplacingSync(
    '${fwDir.path}/$fwName',
    'Versions/Current/$fwName',
  );
  _createSymlinkReplacingSync(
    '${fwDir.path}/Resources',
    'Versions/Current/Resources',
  );

  if (outputZipPath != null && outputZipPath.isNotEmpty) {
    final zipBytes = createFrameworkZipBytes(
      fwDir,
      archiveRootName: fwDirName,
      executableRelPaths: {'$fwDirName/Versions/A/$fwName'},
    );
    final zipFile = File(outputZipPath);
    zipFile.parent.createSync(recursive: true);
    zipFile.writeAsBytesSync(zipBytes);
  }
}

void _runCopyFiles(List<String> args) {
  String? outputDirPath;
  String? platformName;
  String? minOsStr;
  String? sdkVersionStr;
  String? arch;
  final allowNonMacho = <String>{};
  final positional = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('--allow-non-macho=')) {
      final value = arg.substring('--allow-non-macho='.length);
      for (final part in value.split(',')) {
        if (part.isNotEmpty) allowNonMacho.add(part);
      }
    } else if (arg == '--output-dir') {
      if (++i >= args.length) _usageError('--output-dir requires a value');
      outputDirPath = args[i];
    } else if (arg == '--platform') {
      if (++i >= args.length) _usageError('--platform requires a value');
      platformName = args[i];
    } else if (arg == '--min-os') {
      if (++i >= args.length) _usageError('--min-os requires a value');
      minOsStr = args[i];
    } else if (arg == '--sdk-version') {
      if (++i >= args.length) _usageError('--sdk-version requires a value');
      sdkVersionStr = args[i];
    } else if (arg == '--arch') {
      if (++i >= args.length) _usageError('--arch requires a value');
      arch = args[i];
    } else if (arg == '--allow-non-macho') {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        _usageError(
          '--allow-non-macho requires an explicit binary or framework name',
        );
      }
      i++;
      for (final part in args[i].split(',')) {
        if (part.isNotEmpty) allowNonMacho.add(part);
      }
    } else if (arg.startsWith('--')) {
      _usageError('Unknown flag for copy-files: $arg');
    } else {
      positional.add(arg);
    }
  }

  if (outputDirPath == null) {
    _usageError('copy-files requires --output-dir');
  }

  int? platform;
  int? minOs;
  int? sdkVersion;
  if (platformName != null || minOsStr != null) {
    if (platformName == null || minOsStr == null) {
      _usageError('--platform and --min-os must be provided together');
    }
    platform = parsePlatform(platformName);
    minOs = parsePackedVersion(minOsStr);
    sdkVersion = sdkVersionStr != null
        ? parsePackedVersion(sdkVersionStr)
        : minOs;
  }

  final outDir = Directory(outputDirPath)..createSync(recursive: true);
  var i = 0;
  while (i < positional.length) {
    final srcPath = positional[i];
    final String destName;
    if (i + 1 < positional.length &&
        !positional[i + 1].contains('/') &&
        !positional[i + 1].contains(r'\')) {
      destName = positional[i + 1];
      i += 2;
    } else {
      destName = Uri.file(
        srcPath,
      ).pathSegments.where((s) => s.isNotEmpty).last;
      i += 1;
    }
    final destPath = '${outDir.path}/$destName';
    if (platform != null && minOs != null) {
      final inputBytes = File(srcPath).readAsBytesSync();
      final isAllowed = _isAllowedNonMacho(
        allowNonMacho,
        inputPath: srcPath,
        outputPath: destName,
      );
      if (!isMachO64(inputBytes) && !isFatMachO(inputBytes)) {
        if (isAllowed) {
          File(destPath).writeAsBytesSync(inputBytes);
          continue;
        }
        if (isMachO32(inputBytes)) {
          throw FormatException(
            'Input file "$srcPath" ("$destName") is an unsupported 32-bit '
            'Mach-O binary (0xfeedface). Only 64-bit Mach-O binaries are '
            'supported unless explicitly listed in allow_non_macho.',
          );
        }
        throw FormatException(
          'Input file "$srcPath" ("$destName") is a non-Mach-O file (not a '
          '64-bit or universal Mach-O binary). Only Mach-O binaries are '
          'permitted unless explicitly listed in allow_non_macho.',
        );
      }
      try {
        final patched = patchMachO(
          inputBytes,
          platform: platform,
          minOs: minOs,
          sdkVersion: sdkVersion,
          arch: arch,
        );
        File(destPath).writeAsBytesSync(patched);
      } on FormatException catch (e) {
        if (isAllowed) {
          File(destPath).writeAsBytesSync(inputBytes);
          continue;
        }
        throw FormatException(
          'Input file "$srcPath" ("$destName"): ${e.message}',
        );
      }
    } else {
      File(srcPath).copySync(destPath);
    }
  }
}

void _runFat(List<String> args) {
  String? outputPath;
  final slicePaths = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--output') {
      if (++i >= args.length) _usageError('--output requires a value');
      outputPath = args[i];
    } else if (arg.startsWith('--')) {
      _usageError('Unknown flag for fat: $arg');
    } else {
      slicePaths.add(arg);
    }
  }

  if (outputPath == null || slicePaths.isEmpty) {
    _usageError('fat requires --output and at least one input slice path');
  }

  final slices = <FatSlice>[];
  for (final p in slicePaths) {
    final bytes = File(p).readAsBytesSync();
    if (!isMachO64(bytes) && !isMachO32(bytes)) {
      throw FormatException('Input slice "$p" is not a thin Mach-O binary.');
    }
    final bd = ByteData.sublistView(bytes);
    final cputype = bd.getUint32(4, Endian.little);
    final cpusubtype = bd.getUint32(8, Endian.little);
    slices.add(
      FatSlice(cputype: cputype, cpusubtype: cpusubtype, bytes: bytes),
    );
  }

  final out = buildFatMachO(slices);
  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(out);
}

void _verifyMachODylibBytes(Uint8List bytes, String description) {
  if (!isMachO64(bytes) && !isFatMachO(bytes)) {
    throw FormatException(
      '$description is not a 64-bit or universal Mach-O binary.',
    );
  }
  final slices = isFatMachO(bytes)
      ? extractFatSlices(bytes).map((s) => s.bytes).toList()
      : <Uint8List>[bytes];
  for (final slice in slices) {
    final bd = ByteData.sublistView(slice);
    final filetype = bd.getUint32(12, Endian.little);
    if (filetype != mhDylib) {
      throw FormatException(
        '$description has Mach-O filetype 0x${filetype.toRadixString(16)}, '
        'expected MH_DYLIB (0x6).',
      );
    }
    parseLoadCommands(slice);
  }
}

void _verifyFrameworkInfoPlistXml(
  String plistXml,
  String frameworkName,
  String sourceDesc,
) {
  final pkgTypeMatch = RegExp(
    r'<key>\s*CFBundlePackageType\s*</key>\s*<string>\s*([^<\s]+)\s*</string>',
  ).firstMatch(plistXml);
  if (pkgTypeMatch == null || pkgTypeMatch.group(1) != 'FMWK') {
    throw FormatException(
      '$sourceDesc must declare CFBundlePackageType = FMWK, got: '
      '${pkgTypeMatch?.group(1)}',
    );
  }
  final execMatch = RegExp(
    r'<key>\s*CFBundleExecutable\s*</key>\s*<string>\s*([^<\s]+)\s*</string>',
  ).firstMatch(plistXml);
  if (execMatch == null || execMatch.group(1) != frameworkName) {
    throw FormatException(
      '$sourceDesc must declare CFBundleExecutable = $frameworkName, got: '
      '${execMatch?.group(1)}',
    );
  }
}

/// Verifies that a macOS `.framework` directory (and optional `AppleBundleInfo`
/// `.framework.zip` archive) has the canonical versioned layout required by
/// macOS `codesign`:
///   - `Versions/A/<binary>` (Mach-O `MH_DYLIB`),
///   - `Versions/A/Resources/Info.plist` (`CFBundlePackageType = FMWK`),
///   - `Versions/Current -> A` symlink,
///   - top-level symlinks `<binary> -> Versions/Current/<binary>` and
///     `Resources -> Versions/Current/Resources`,
///   - no unversioned regular files or directories at the framework root.
void verifyMacosFramework(
  String frameworkOrWrapperPath, {
  String frameworkName = 'App',
  String? frameworkZipPath,
}) {
  var fwDir = frameworkOrWrapperPath.endsWith('.framework')
      ? Directory(frameworkOrWrapperPath)
      : Directory('$frameworkOrWrapperPath/$frameworkName.framework');
  if (!fwDir.existsSync()) {
    throw StateError('macOS framework directory not found: ${fwDir.path}');
  }

  // When Bazel's sandbox or runfiles tree materializes a tree artifact by
  // symlinking its leaf files into the execroot, unwrap to the underlying
  // tree artifact directory in the execroot so we inspect the real entries.
  final probeBinary = '${fwDir.path}/Versions/A/$frameworkName';
  if (FileSystemEntity.typeSync(probeBinary, followLinks: false) ==
      FileSystemEntityType.link) {
    final target = Link(probeBinary).targetSync().replaceAll('\\', '/');
    final suffix = '/$frameworkName.framework/Versions/A/$frameworkName';
    if (target.startsWith('/') && target.endsWith(suffix)) {
      fwDir = Directory(
        target.substring(
          0,
          target.length - '/Versions/A/$frameworkName'.length,
        ),
      );
    }
  }

  final versionABinary = File('${fwDir.path}/Versions/A/$frameworkName');
  final versionAPlist = File('${fwDir.path}/Versions/A/Resources/Info.plist');
  if (FileSystemEntity.typeSync(versionABinary.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError(
      'Expected regular file at ${versionABinary.path}, found '
      '${FileSystemEntity.typeSync(versionABinary.path, followLinks: false)}',
    );
  }
  if (FileSystemEntity.typeSync(versionAPlist.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw StateError(
      'Expected regular file at ${versionAPlist.path}, found '
      '${FileSystemEntity.typeSync(versionAPlist.path, followLinks: false)}',
    );
  }

  final currentLinkPath = '${fwDir.path}/Versions/Current';
  if (FileSystemEntity.typeSync(currentLinkPath, followLinks: false) !=
      FileSystemEntityType.link) {
    throw StateError(
      'Expected symlink at $currentLinkPath, found '
      '${FileSystemEntity.typeSync(currentLinkPath, followLinks: false)}',
    );
  }
  final currentTarget = Link(currentLinkPath).targetSync();
  if (currentTarget != 'A') {
    throw StateError(
      'Expected $currentLinkPath -> "A", got "$currentTarget"',
    );
  }

  final topBinaryLinkPath = '${fwDir.path}/$frameworkName';
  if (FileSystemEntity.typeSync(topBinaryLinkPath, followLinks: false) !=
      FileSystemEntityType.link) {
    throw StateError(
      'Expected top-level symlink at $topBinaryLinkPath, found '
      '${FileSystemEntity.typeSync(topBinaryLinkPath, followLinks: false)}',
    );
  }
  final topBinaryTarget = Link(topBinaryLinkPath).targetSync();
  if (topBinaryTarget != 'Versions/Current/$frameworkName') {
    throw StateError(
      'Expected $topBinaryLinkPath -> "Versions/Current/$frameworkName", '
      'got "$topBinaryTarget"',
    );
  }

  final topResourcesLinkPath = '${fwDir.path}/Resources';
  if (FileSystemEntity.typeSync(topResourcesLinkPath, followLinks: false) !=
      FileSystemEntityType.link) {
    throw StateError(
      'Expected top-level symlink at $topResourcesLinkPath, found '
      '${FileSystemEntity.typeSync(topResourcesLinkPath, followLinks: false)}',
    );
  }
  final topResourcesTarget = Link(topResourcesLinkPath).targetSync();
  if (topResourcesTarget != 'Versions/Current/Resources') {
    throw StateError(
      'Expected $topResourcesLinkPath -> "Versions/Current/Resources", '
      'got "$topResourcesTarget"',
    );
  }

  // Ensure no unsealed files or non-Versions directories exist at framework root.
  final allowedTopSymlinks = <String>{
    frameworkName,
    'Resources',
    'Headers',
    'Modules',
  };
  for (final entity in fwDir.listSync(followLinks: false)) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name == 'Versions') {
      if (entity is! Directory || entity is Link) {
        throw StateError('Expected Versions to be a real directory.');
      }
      continue;
    }
    if (entity is! Link || !allowedTopSymlinks.contains(name)) {
      throw StateError(
        'Ambiguous unsealed entry "$name" (${entity.runtimeType}) at root of '
        '${fwDir.path}; macOS codesign requires only Versions/ and top-level '
        'symlinks into Versions/Current/.',
      );
    }
  }

  for (final entity in Directory('${fwDir.path}/Versions').listSync(
    followLinks: false,
  )) {
    final name = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
    if (name != 'A' && name != 'Current') {
      throw StateError(
        'Unexpected entry "$name" inside ${fwDir.path}/Versions.',
      );
    }
  }

  if (File(topBinaryLinkPath).resolveSymbolicLinksSync() !=
      versionABinary.resolveSymbolicLinksSync()) {
    throw StateError(
      '$topBinaryLinkPath does not resolve to ${versionABinary.path}.',
    );
  }
  if (File('$topResourcesLinkPath/Info.plist').resolveSymbolicLinksSync() !=
      versionAPlist.resolveSymbolicLinksSync()) {
    throw StateError(
      '$topResourcesLinkPath/Info.plist does not resolve to ${versionAPlist.path}.',
    );
  }

  final binaryBytes = versionABinary.readAsBytesSync();
  _verifyMachODylibBytes(binaryBytes, versionABinary.path);
  _verifyFrameworkInfoPlistXml(
    versionAPlist.readAsStringSync(),
    frameworkName,
    versionAPlist.path,
  );

  if (frameworkZipPath != null && frameworkZipPath.isNotEmpty) {
    final zipFile = File(frameworkZipPath);
    if (!zipFile.existsSync()) {
      throw StateError('Framework zip archive not found: $frameworkZipPath');
    }
    final entries = {
      for (final e in readFrameworkZipEntries(zipFile.readAsBytesSync()))
        e.path: e,
    };
    final prefix = '$frameworkName.framework';
    final binEntry = entries['$prefix/Versions/A/$frameworkName'];
    if (binEntry == null || binEntry.isSymlink || !binEntry.isExecutable) {
      throw StateError(
        'Expected executable Mach-O entry "$prefix/Versions/A/$frameworkName" '
        'in $frameworkZipPath, got: $binEntry',
      );
    }
    _verifyMachODylibBytes(
      binEntry.data,
      '$frameworkZipPath:$prefix/Versions/A/$frameworkName',
    );

    final plistEntry = entries['$prefix/Versions/A/Resources/Info.plist'];
    if (plistEntry == null || plistEntry.isSymlink) {
      throw StateError(
        'Expected regular file entry "$prefix/Versions/A/Resources/Info.plist" '
        'in $frameworkZipPath',
      );
    }
    _verifyFrameworkInfoPlistXml(
      utf8.decode(plistEntry.data),
      frameworkName,
      '$frameworkZipPath:$prefix/Versions/A/Resources/Info.plist',
    );

    final expectedLinks = <String, String>{
      '$prefix/Versions/Current': 'A',
      '$prefix/$frameworkName': 'Versions/Current/$frameworkName',
      '$prefix/Resources': 'Versions/Current/Resources',
    };
    for (final expected in expectedLinks.entries) {
      final entry = entries[expected.key];
      if (entry == null || !entry.isSymlink) {
        throw StateError(
          'Expected symlink entry "${expected.key}" in $frameworkZipPath, '
          'found: ${entry == null ? "missing" : "regular file"}',
        );
      }
      final target = utf8.decode(entry.data);
      if (target != expected.value) {
        throw StateError(
          'Expected symlink "${expected.key}" -> "${expected.value}" in '
          '$frameworkZipPath, got "$target"',
        );
      }
    }
  }
}

void _runVerify(List<String> args) {
  String? inputPath;
  String? binaryRelpath;
  String? frameworkZipPath;
  String? objdumpPath;
  String? outputPath;
  final expectedSubstrings = <String>[];

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    switch (arg) {
      case '--input':
        if (++i >= args.length) _usageError('--input requires a value');
        inputPath = args[i];
      case '--binary-relpath':
        if (++i >= args.length) {
          _usageError('--binary-relpath requires a value');
        }
        binaryRelpath = args[i];
      case '--framework-zip':
        if (++i >= args.length) {
          _usageError('--framework-zip requires a value');
        }
        frameworkZipPath = args[i];
      case '--objdump':
        if (++i >= args.length) _usageError('--objdump requires a value');
        objdumpPath = args[i];
      case '--expect':
        if (++i >= args.length) _usageError('--expect requires a value');
        expectedSubstrings.add(args[i]);
      case '--output':
        if (++i >= args.length) _usageError('--output requires a value');
        outputPath = args[i];
      default:
        _usageError('Unknown flag for verify: $arg');
    }
  }

  if (inputPath == null || outputPath == null) {
    _usageError('verify requires --input and --output');
  }

  if ((binaryRelpath != null &&
          binaryRelpath.contains('.framework/Versions/')) ||
      (frameworkZipPath != null && frameworkZipPath.isNotEmpty)) {
    var fwName = 'App';
    if (binaryRelpath != null && binaryRelpath.contains('.framework/')) {
      final seg = binaryRelpath
          .split('/')
          .firstWhere((s) => s.endsWith('.framework'));
      fwName = seg.substring(0, seg.length - '.framework'.length);
    }
    verifyMacosFramework(
      inputPath,
      frameworkName: fwName,
      frameworkZipPath: frameworkZipPath,
    );
  }

  final targetPath = binaryRelpath != null && binaryRelpath.isNotEmpty
      ? '$inputPath/$binaryRelpath'
      : inputPath;
  final bytes = File(targetPath).readAsBytesSync();
  if (!isMachO64(bytes) && !isFatMachO(bytes)) {
    throw FormatException(
      'File "$targetPath" is not a 64-bit or universal Mach-O binary.',
    );
  }
  if (isFatMachO(bytes)) {
    for (final s in extractFatSlices(bytes)) {
      parseLoadCommands(s.bytes);
    }
  } else {
    parseLoadCommands(bytes);
  }

  if (objdumpPath != null && objdumpPath.isNotEmpty) {
    final res = Process.runSync(objdumpPath, [
      '--macho',
      '--private-headers',
      '--dylib-id',
      '--arch=all',
      targetPath,
    ]);
    if (res.exitCode != 0) {
      throw StateError(
        'llvm-objdump failed on "$targetPath" (exit ${res.exitCode}):\n'
        '${res.stderr}',
      );
    }
    final stdoutStr = res.stdout as String;
    for (final expected in expectedSubstrings) {
      if (!stdoutStr.contains(expected)) {
        throw StateError(
          'Expected substring "$expected" not found in llvm-objdump output for '
          '"$targetPath":\n$stdoutStr',
        );
      }
    }
  }

  final outFile = File(outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync('verified\n');
}

/// Returns true if [bytes] begins with a 64-bit little-endian Mach-O header.
bool isMachO64(Uint8List bytes) {
  if (bytes.length < mhHeaderSize64) return false;
  final bd = ByteData.sublistView(bytes);
  return bd.getUint32(0, Endian.little) == mhMagic64;
}

/// Returns true if [bytes] begins with a 32-bit Mach-O magic (`MH_MAGIC` or `MH_CIGAM`).
bool isMachO32(Uint8List bytes) {
  if (bytes.length < 4) return false;
  final bd = ByteData.sublistView(bytes);
  final magic = bd.getUint32(0, Endian.little);
  return magic == mhMagic32 || magic == mhCigam32;
}

/// Returns true if [bytes] begins with a Universal (Fat) Mach-O header
/// (`FAT_MAGIC` `0xcafebabe` or `FAT_MAGIC_64` `0xcafebabf`).
bool isFatMachO(Uint8List bytes) {
  if (bytes.length < 8) return false;
  final bd = ByteData.sublistView(bytes);
  final magicBE = bd.getUint32(0, Endian.big);
  if (magicBE == fatMagic || magicBE == fatMagic64) {
    final nfat = bd.getUint32(4, Endian.big);
    return nfat >= 1 && nfat <= 32;
  }
  final magicLE = bd.getUint32(0, Endian.little);
  if (magicLE == fatMagic || magicLE == fatMagic64) {
    final nfat = bd.getUint32(4, Endian.little);
    return nfat >= 1 && nfat <= 32;
  }
  return false;
}

/// Represents a single architecture slice inside a universal (fat) Mach-O binary.
class FatSlice {
  final int cputype;
  final int cpusubtype;
  final int align;
  final Uint8List bytes;

  FatSlice({
    required this.cputype,
    required this.cpusubtype,
    required this.bytes,
    int? align,
  }) : align = align ?? (cputype == cpuTypeArm64 ? 14 : 12);
}

/// Extracts all architecture slices from a universal (fat) Mach-O binary.
List<FatSlice> extractFatSlices(Uint8List bytes) {
  if (bytes.length < 8) {
    throw const FormatException('Not a universal (fat) Mach-O binary.');
  }
  final bd = ByteData.sublistView(bytes);
  final magicBE = bd.getUint32(0, Endian.big);
  final magicLE = bd.getUint32(0, Endian.little);
  late final Endian headerEndian;
  late final bool is64;
  if (magicBE == fatMagic) {
    headerEndian = Endian.big;
    is64 = false;
  } else if (magicBE == fatMagic64) {
    headerEndian = Endian.big;
    is64 = true;
  } else if (magicLE == fatMagic) {
    headerEndian = Endian.little;
    is64 = false;
  } else if (magicLE == fatMagic64) {
    headerEndian = Endian.little;
    is64 = true;
  } else {
    throw const FormatException('Not a universal (fat) Mach-O binary.');
  }

  final nfatArch = bd.getUint32(4, headerEndian);
  if (nfatArch == 0 || nfatArch > 32) {
    throw FormatException('Invalid fat Mach-O nfat_arch count: $nfatArch.');
  }
  final archEntrySize = is64 ? 32 : 20;
  final tableEnd = 8 + nfatArch * archEntrySize;
  if (tableEnd > bytes.length) {
    throw const FormatException('Truncated fat Mach-O architecture table.');
  }

  final slices = <FatSlice>[];
  for (var i = 0; i < nfatArch; i++) {
    final entryOff = 8 + i * archEntrySize;
    final cputype = bd.getUint32(entryOff, headerEndian);
    final cpusubtype = bd.getUint32(entryOff + 4, headerEndian);
    final sliceOffset = is64
        ? bd.getUint64(entryOff + 8, headerEndian)
        : bd.getUint32(entryOff + 8, headerEndian);
    final sliceSize = is64
        ? bd.getUint64(entryOff + 16, headerEndian)
        : bd.getUint32(entryOff + 12, headerEndian);
    final align = is64
        ? bd.getUint32(entryOff + 24, headerEndian)
        : bd.getUint32(entryOff + 16, headerEndian);
    if (sliceOffset < tableEnd ||
        sliceSize == 0 ||
        sliceOffset + sliceSize > bytes.length) {
      throw FormatException(
        'Fat Mach-O slice $i (offset $sliceOffset, size $sliceSize) is out of '
        'bounds (file length ${bytes.length}).',
      );
    }
    slices.add(
      FatSlice(
        cputype: cputype,
        cpusubtype: cpusubtype,
        align: align,
        bytes: Uint8List.fromList(
          bytes.sublist(sliceOffset, sliceOffset + sliceSize),
        ),
      ),
    );
  }
  return slices;
}

/// Builds a universal (fat) Mach-O binary from [slices].
Uint8List buildFatMachO(List<FatSlice> slices, {bool fat64 = false}) {
  if (slices.isEmpty) {
    throw ArgumentError.value(
      slices,
      'slices',
      'Must contain at least one slice.',
    );
  }
  final archEntrySize = fat64 ? 32 : 20;
  final headerAndTableSize = 8 + slices.length * archEntrySize;
  final sliceOffsets = <int>[];
  var currentOffset = headerAndTableSize;
  for (final s in slices) {
    final effAlign = s.align.clamp(0, 20);
    final alignment = 1 << effAlign;
    currentOffset = (currentOffset + alignment - 1) & ~(alignment - 1);
    sliceOffsets.add(currentOffset);
    currentOffset += s.bytes.length;
  }

  final out = Uint8List(currentOffset);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, fat64 ? fatMagic64 : fatMagic, Endian.big);
  bd.setUint32(4, slices.length, Endian.big);
  for (var i = 0; i < slices.length; i++) {
    final s = slices[i];
    final entryOff = 8 + i * archEntrySize;
    final off = sliceOffsets[i];
    bd.setUint32(entryOff, s.cputype, Endian.big);
    bd.setUint32(entryOff + 4, s.cpusubtype, Endian.big);
    if (fat64) {
      bd.setUint64(entryOff + 8, off, Endian.big);
      bd.setUint64(entryOff + 16, s.bytes.length, Endian.big);
      bd.setUint32(entryOff + 24, s.align, Endian.big);
      bd.setUint32(entryOff + 28, 0, Endian.big);
    } else {
      bd.setUint32(entryOff + 8, off, Endian.big);
      bd.setUint32(entryOff + 12, s.bytes.length, Endian.big);
      bd.setUint32(entryOff + 16, s.align, Endian.big);
    }
    out.setRange(off, off + s.bytes.length, s.bytes);
  }
  return out;
}

int _cpuTypeForArch(String arch) {
  switch (arch) {
    case 'arm64':
      return cpuTypeArm64;
    case 'x86_64':
      return cpuTypeX86_64;
    default:
      throw ArgumentError.value(arch, 'arch', 'Expected "arm64" or "x86_64".');
  }
}

/// Extracts the single 64-bit Mach-O slice matching [arch] (`arm64` or `x86_64`)
/// from a universal (fat) Mach-O binary.
Uint8List thinFatMachO(Uint8List bytes, String arch) {
  final targetCpuType = _cpuTypeForArch(arch);
  final slices = extractFatSlices(bytes);
  for (final s in slices) {
    if (s.cputype == targetCpuType) {
      if (isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0) {
        throw FormatException(
          'Fat Mach-O slice for "$arch" is an unsupported 32-bit Mach-O binary.',
        );
      }
      if (!isMachO64(s.bytes)) {
        throw FormatException(
          'Fat Mach-O slice for "$arch" is not a valid 64-bit Mach-O binary.',
        );
      }
      return s.bytes;
    }
  }
  final has32Bit = slices.any(
    (s) => isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0,
  );
  if (has32Bit) {
    throw FormatException(
      'Fat Mach-O binary contains unsupported 32-bit Mach-O slice(s) and no '
      '64-bit slice for architecture "$arch".',
    );
  }
  throw FormatException(
    'Fat Mach-O binary does not contain a slice for architecture "$arch".',
  );
}

/// Parses a platform name (`ios`, `iossim`, `macos`) into its Mach-O constant.
int parsePlatform(String name) {
  switch (name) {
    case 'macos':
      return platformMacos;
    case 'ios':
      return platformIos;
    case 'iossim':
      return platformIosSimulator;
    default:
      throw ArgumentError.value(
        name,
        'platform',
        'Expected "ios", "iossim", or "macos".',
      );
  }
}

/// Encodes `"major[.minor[.patch]]"` into `(major << 16) | (minor << 8) | patch`.
int parsePackedVersion(String version) {
  final parts = version.split('.');
  if (parts.isEmpty || parts.length > 3) {
    throw FormatException('Invalid version string "$version"');
  }
  final major = int.parse(parts[0]);
  final minor = parts.length > 1 ? int.parse(parts[1]) : 0;
  final patch = parts.length > 2 ? int.parse(parts[2]) : 0;
  if (major < 0 ||
      major > 0xffff ||
      minor < 0 ||
      minor > 0xff ||
      patch < 0 ||
      patch > 0xff) {
    throw FormatException('Version component out of range in "$version"');
  }
  return (major << 16) | (minor << 8) | patch;
}

/// Represents a single raw Mach-O load command.
class LoadCommand {
  final int cmd;
  final Uint8List bytes;

  LoadCommand(this.cmd, this.bytes);

  int get cmdsize => bytes.length;
}

/// Builds a 72-byte `LC_SEGMENT_64` load command with 0 sections.
LoadCommand buildLcSegment64({
  required String segname,
  required int vmaddr,
  required int vmsize,
  required int fileoff,
  required int filesize,
  required int maxprot,
  required int initprot,
  int nsects = 0,
  int flags = 0,
}) {
  final buf = Uint8List(72);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcSegment64, Endian.little);
  bd.setUint32(4, 72, Endian.little);
  final nameBytes = ascii.encode(segname);
  buf.setRange(8, 8 + math.min<int>(16, nameBytes.length), nameBytes);
  bd.setUint64(24, vmaddr, Endian.little);
  bd.setUint64(32, vmsize, Endian.little);
  bd.setUint64(40, fileoff, Endian.little);
  bd.setUint64(48, filesize, Endian.little);
  bd.setUint32(56, maxprot, Endian.little);
  bd.setUint32(60, initprot, Endian.little);
  bd.setUint32(64, nsects, Endian.little);
  bd.setUint32(68, flags, Endian.little);
  return LoadCommand(lcSegment64, buf);
}

/// Builds a 24-byte `LC_SYMTAB` load command.
LoadCommand buildLcSymtab({
  required int symoff,
  required int nsyms,
  required int stroff,
  required int strsize,
}) {
  final buf = Uint8List(24);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcSymtab, Endian.little);
  bd.setUint32(4, 24, Endian.little);
  bd.setUint32(8, symoff, Endian.little);
  bd.setUint32(12, nsyms, Endian.little);
  bd.setUint32(16, stroff, Endian.little);
  bd.setUint32(20, strsize, Endian.little);
  return LoadCommand(lcSymtab, buf);
}

/// Builds an 80-byte `LC_DYSYMTAB` load command with empty symbol tables.
LoadCommand buildLcDysymtab() {
  final buf = Uint8List(80);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcDysymtab, Endian.little);
  bd.setUint32(4, 80, Endian.little);
  return LoadCommand(lcDysymtab, buf);
}

/// Builds a 24-byte `LC_UUID` load command with the given 16-byte [uuid].
LoadCommand buildLcUuid(Uint8List uuid) {
  if (uuid.length != 16) {
    throw ArgumentError.value(uuid.length, 'uuid.length', 'Must be 16 bytes.');
  }
  final buf = Uint8List(24);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcUuid, Endian.little);
  bd.setUint32(4, 24, Endian.little);
  buf.setRange(8, 24, uuid);
  return LoadCommand(lcUuid, buf);
}

/// Builds a 24-byte `LC_BUILD_VERSION` load command (`ntools = 0`).
LoadCommand buildLcBuildVersion({
  required int platform,
  required int minos,
  required int sdk,
}) {
  final buf = Uint8List(24);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcBuildVersion, Endian.little);
  bd.setUint32(4, 24, Endian.little);
  bd.setUint32(8, platform, Endian.little);
  bd.setUint32(12, minos, Endian.little);
  bd.setUint32(16, sdk, Endian.little);
  bd.setUint32(20, 0, Endian.little); // ntools = 0
  return LoadCommand(lcBuildVersion, buf);
}

/// Builds an 8-byte-aligned `LC_ID_DYLIB` load command.
LoadCommand buildLcIdDylib(
  String installName, {
  int timestamp = 2,
  int currentVersion = 0x00010000,
  int compatibilityVersion = 0x00010000,
}) {
  final strBytes = utf8.encode(installName);
  // dylib_command is 24 bytes header + string + NUL + padding to 8-byte boundary.
  final unalignedSize = 24 + strBytes.length + 1;
  final cmdsize = (unalignedSize + 7) & ~7;
  final buf = Uint8List(cmdsize);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcIdDylib, Endian.little);
  bd.setUint32(4, cmdsize, Endian.little);
  bd.setUint32(8, 24, Endian.little); // name.offset = 24
  bd.setUint32(12, timestamp, Endian.little);
  bd.setUint32(16, currentVersion, Endian.little);
  bd.setUint32(20, compatibilityVersion, Endian.little);
  buf.setRange(24, 24 + strBytes.length, strBytes);
  return LoadCommand(lcIdDylib, buf);
}

/// Builds an 8-byte-aligned `LC_RPATH` load command.
LoadCommand buildLcRpath(String rpath) {
  final strBytes = utf8.encode(rpath);
  // rpath_command is 12 bytes header + string + NUL + padding to 8-byte boundary.
  final unalignedSize = 12 + strBytes.length + 1;
  final cmdsize = (unalignedSize + 7) & ~7;
  final buf = Uint8List(cmdsize);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcRpath, Endian.little);
  bd.setUint32(4, cmdsize, Endian.little);
  bd.setUint32(8, 12, Endian.little); // path.offset = 12
  buf.setRange(12, 12 + strBytes.length, strBytes);
  return LoadCommand(lcRpath, buf);
}

/// Extracts the NUL-terminated string starting at [offset] in [bytes].
String _readLcString(Uint8List bytes, int offset) {
  if (offset < 0 || offset >= bytes.length) return '';
  var end = offset;
  while (end < bytes.length && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(offset, end), allowMalformed: true);
}

/// Parses the load commands from a 64-bit Mach-O binary.
List<LoadCommand> parseLoadCommands(Uint8List bytes) {
  if (!isMachO64(bytes)) {
    if (isMachO32(bytes)) {
      throw const FormatException(
        'Unsupported 32-bit Mach-O binary; expected 64-bit Mach-O.',
      );
    }
    throw const FormatException('Not a 64-bit little-endian Mach-O binary.');
  }
  final bd = ByteData.sublistView(bytes);
  final ncmds = bd.getUint32(16, Endian.little);
  final sizeofcmds = bd.getUint32(20, Endian.little);
  if (mhHeaderSize64 + sizeofcmds > bytes.length) {
    throw const FormatException('Truncated Mach-O load commands.');
  }
  final commands = <LoadCommand>[];
  var offset = mhHeaderSize64;
  for (var i = 0; i < ncmds; i++) {
    if (offset + 8 > mhHeaderSize64 + sizeofcmds) {
      throw const FormatException(
        'Load command header extends past sizeofcmds.',
      );
    }
    final cmd = bd.getUint32(offset, Endian.little);
    final cmdsize = bd.getUint32(offset + 4, Endian.little);
    if (cmdsize < 8 || offset + cmdsize > mhHeaderSize64 + sizeofcmds) {
      throw FormatException('Invalid cmdsize $cmdsize at offset $offset.');
    }
    commands.add(
      LoadCommand(
        cmd,
        Uint8List.fromList(bytes.sublist(offset, offset + cmdsize)),
      ),
    );
    offset += cmdsize;
  }
  return commands;
}

/// Finds the lowest non-zero file offset referenced by any segment, section,
/// or linkedit table in the Mach-O binary. Load commands may grow up to this
/// boundary without overwriting section/segment payload bytes.
int _findFirstPayloadOffset(List<LoadCommand> commands, int totalLength) {
  var minOffset = totalLength;

  void consider(int offset, int size) {
    if (offset > 0 && size > 0 && offset < minOffset) {
      minOffset = offset;
    }
  }

  for (final lc in commands) {
    final bd = ByteData.sublistView(lc.bytes);
    switch (lc.cmd) {
      case lcSegment64:
        if (lc.bytes.length >= 72) {
          final fileoff = bd.getUint64(40, Endian.little);
          final filesize = bd.getUint64(48, Endian.little);
          final nsects = bd.getUint32(64, Endian.little);
          if (fileoff > 0 && filesize > 0) {
            consider(fileoff, filesize);
          }
          // Inspect each section_64 (80 bytes each starting at offset 72).
          for (var s = 0; s < nsects; s++) {
            final sectOff = 72 + s * 80;
            if (sectOff + 80 <= lc.bytes.length) {
              final sSize = bd.getUint64(sectOff + 40, Endian.little);
              final sOffset = bd.getUint32(sectOff + 48, Endian.little);
              consider(sOffset, sSize);
            }
          }
        }
      case lcSymtab:
        if (lc.bytes.length >= 24) {
          consider(
            bd.getUint32(8, Endian.little),
            bd.getUint32(12, Endian.little) * 16,
          );
          consider(
            bd.getUint32(16, Endian.little),
            bd.getUint32(20, Endian.little),
          );
        }
      case lcFunctionStarts:
      case lcDataInCode:
      case lcCodeSignature:
      case lcDyldExportsTrie:
      case lcDyldChainedFixups:
        if (lc.bytes.length >= 16) {
          consider(
            bd.getUint32(8, Endian.little),
            bd.getUint32(12, Endian.little),
          );
        }
    }
  }
  return minOffset;
}

/// Patches a 64-bit or universal (fat) Mach-O binary in memory and recomputes
/// its embedded `LC_CODE_SIGNATURE` SHA-256 page hashes if present.
///
/// When [inputBytes] is a universal (fat) Mach-O binary:
/// - If [arch] is provided (`"arm64"` or `"x86_64"`), the fat binary is thinned
///   to that slice and the slice is patched.
/// - Otherwise, every slice in the fat binary is patched and reassembled into
///   a universal (fat) Mach-O binary.
///
/// Throws [FormatException] if [inputBytes] (or any slice being patched) is a
/// 32-bit Mach-O binary or non-Mach-O data.
Uint8List patchMachO(
  Uint8List inputBytes, {
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? installName,
  List<String> rpaths = const [],
  String? arch,
}) {
  if (isFatMachO(inputBytes)) {
    if (arch != null) {
      final thinSlice = thinFatMachO(inputBytes, arch);
      return _patchSingleMachO64(
        thinSlice,
        platform: platform,
        minOs: minOs,
        sdkVersion: sdkVersion,
        installName: installName,
        rpaths: rpaths,
      );
    }
    final slices = extractFatSlices(inputBytes);
    final bd = ByteData.sublistView(inputBytes);
    final isFat64 =
        bd.getUint32(0, Endian.big) == fatMagic64 ||
        bd.getUint32(0, Endian.little) == fatMagic64;
    final patchedSlices = <FatSlice>[];
    for (var i = 0; i < slices.length; i++) {
      final s = slices[i];
      if (isMachO32(s.bytes) || (s.cputype & cpuArchAbi64) == 0) {
        throw FormatException(
          'Fat Mach-O slice $i (cputype 0x${s.cputype.toRadixString(16)}) is '
          'an unsupported 32-bit Mach-O binary.',
        );
      }
      if (!isMachO64(s.bytes)) {
        throw FormatException(
          'Fat Mach-O slice $i is not a valid 64-bit Mach-O binary.',
        );
      }
      final patchedBytes = _patchSingleMachO64(
        s.bytes,
        platform: platform,
        minOs: minOs,
        sdkVersion: sdkVersion,
        installName: installName,
        rpaths: rpaths,
      );
      patchedSlices.add(
        FatSlice(
          cputype: s.cputype,
          cpusubtype: s.cpusubtype,
          align: s.align,
          bytes: patchedBytes,
        ),
      );
    }
    return buildFatMachO(patchedSlices, fat64: isFat64);
  }

  if (isMachO32(inputBytes)) {
    throw const FormatException(
      'Unsupported 32-bit Mach-O binary (0xfeedface); only 64-bit Mach-O '
      'binaries are supported.',
    );
  }

  if (!isMachO64(inputBytes)) {
    throw const FormatException(
      'Not a Mach-O binary (expected 64-bit or universal Mach-O).',
    );
  }

  if (arch != null) {
    final targetCpu = _cpuTypeForArch(arch);
    final actualCpu = ByteData.sublistView(
      inputBytes,
    ).getUint32(4, Endian.little);
    if (actualCpu != targetCpu) {
      throw FormatException(
        'Mach-O cputype 0x${actualCpu.toRadixString(16)} does not match '
        'requested architecture "$arch".',
      );
    }
  }

  return _patchSingleMachO64(
    inputBytes,
    platform: platform,
    minOs: minOs,
    sdkVersion: sdkVersion,
    installName: installName,
    rpaths: rpaths,
  );
}

Uint8List _patchSingleMachO64(
  Uint8List inputBytes, {
  int? platform,
  int? minOs,
  int? sdkVersion,
  String? installName,
  List<String> rpaths = const [],
}) {
  final bdIn = ByteData.sublistView(inputBytes);
  final oldSizeofcmds = bdIn.getUint32(20, Endian.little);
  final originalCommands = parseLoadCommands(inputBytes);
  final maxLoadCommandEnd = _findFirstPayloadOffset(
    originalCommands,
    inputBytes.length,
  );

  final updatedCommands = <LoadCommand>[];
  var wroteBuildVersion = false;
  var wroteIdDylib = false;
  final existingRpaths = <String>{};
  LoadCommand? codeSigCommand;

  for (final lc in originalCommands) {
    // Strip legacy LC_VERSION_MIN_* commands when setting LC_BUILD_VERSION.
    if (platform != null &&
        (lc.cmd == lcVersionMinMacosx ||
            lc.cmd == lcVersionMinIphoneos ||
            lc.cmd == lcVersionMinTvos ||
            lc.cmd == lcVersionMinWatchos)) {
      continue;
    }

    if (lc.cmd == lcBuildVersion && platform != null && minOs != null) {
      if (!wroteBuildVersion) {
        updatedCommands.add(
          buildLcBuildVersion(
            platform: platform,
            minos: minOs,
            sdk: sdkVersion ?? minOs,
          ),
        );
        wroteBuildVersion = true;
      }
      continue;
    }

    if (lc.cmd == lcIdDylib && installName != null) {
      if (!wroteIdDylib) {
        int timestamp = 2;
        int currentVersion = 0x00010000;
        int compatibilityVersion = 0x00010000;
        if (lc.bytes.length >= 24) {
          final lcBd = ByteData.sublistView(lc.bytes);
          timestamp = lcBd.getUint32(12, Endian.little);
          currentVersion = lcBd.getUint32(16, Endian.little);
          compatibilityVersion = lcBd.getUint32(20, Endian.little);
        }
        updatedCommands.add(
          buildLcIdDylib(
            installName,
            timestamp: timestamp,
            currentVersion: currentVersion,
            compatibilityVersion: compatibilityVersion,
          ),
        );
        wroteIdDylib = true;
      }
      continue;
    }

    if (lc.cmd == lcRpath && lc.bytes.length >= 12) {
      final lcBd = ByteData.sublistView(lc.bytes);
      final pathOffset = lcBd.getUint32(8, Endian.little);
      existingRpaths.add(_readLcString(lc.bytes, pathOffset));
      updatedCommands.add(lc);
      continue;
    }

    // Hold LC_CODE_SIGNATURE so any newly added load commands are placed
    // before LC_CODE_SIGNATURE (matching ld64 / vtool conventions).
    if (lc.cmd == lcCodeSignature && codeSigCommand == null) {
      codeSigCommand = lc;
      continue;
    }

    updatedCommands.add(lc);
  }

  if (platform != null && minOs != null && !wroteBuildVersion) {
    updatedCommands.add(
      buildLcBuildVersion(
        platform: platform,
        minos: minOs,
        sdk: sdkVersion ?? minOs,
      ),
    );
  }

  if (installName != null && !wroteIdDylib) {
    updatedCommands.add(buildLcIdDylib(installName));
  }

  for (final rpath in rpaths) {
    if (existingRpaths.add(rpath)) {
      updatedCommands.add(buildLcRpath(rpath));
    }
  }

  if (codeSigCommand != null) {
    updatedCommands.add(codeSigCommand);
  }

  var newSizeofcmds = 0;
  for (final lc in updatedCommands) {
    newSizeofcmds += lc.cmdsize;
  }

  final newLoadCmdEnd = mhHeaderSize64 + newSizeofcmds;
  // If the file has no payload sections/segments at all (header-only fixture)
  // and grows past EOF, extend the buffer; otherwise verify we fit before
  // the first payload offset.
  final bool isHeaderOnly =
      maxLoadCommandEnd == inputBytes.length &&
      mhHeaderSize64 + oldSizeofcmds == inputBytes.length;

  if (!isHeaderOnly && newLoadCmdEnd > maxLoadCommandEnd) {
    throw StateError(
      'Not enough header padding for load commands: need $newLoadCmdEnd bytes, '
      'first payload is at $maxLoadCommandEnd.',
    );
  }

  final outLength = isHeaderOnly
      ? math.max<int>(inputBytes.length, newLoadCmdEnd)
      : inputBytes.length;
  final out = Uint8List(outLength);
  out.setRange(0, inputBytes.length, inputBytes);

  // Zero the old load command region first so any shrinkage leaves clean zeroes.
  final clearEnd = math.min<int>(
    out.length,
    mhHeaderSize64 + math.max<int>(oldSizeofcmds, newSizeofcmds),
  );
  out.fillRange(mhHeaderSize64, clearEnd, 0);

  // Write updated header fields (ncmds, sizeofcmds) and load commands.
  final bdOut = ByteData.sublistView(out);
  bdOut.setUint32(16, updatedCommands.length, Endian.little);
  bdOut.setUint32(20, newSizeofcmds, Endian.little);

  var writeOffset = mhHeaderSize64;
  for (final lc in updatedCommands) {
    out.setRange(writeOffset, writeOffset + lc.cmdsize, lc.bytes);
    writeOffset += lc.cmdsize;
  }

  if (codeSigCommand != null) {
    _resignEmbeddedCodeSignature(out, codeSigCommand);
  }

  return out;
}

/// Recomputes SHA-256 page hashes inside `LC_CODE_SIGNATURE`'s `CS_CodeDirectory`
/// blob if present.
void _resignEmbeddedCodeSignature(Uint8List bytes, LoadCommand codeSigLc) {
  if (codeSigLc.bytes.length < 16) return;
  final lcBd = ByteData.sublistView(codeSigLc.bytes);
  final dataoff = lcBd.getUint32(8, Endian.little);
  final datasize = lcBd.getUint32(12, Endian.little);
  if (dataoff == 0 || datasize < 12 || dataoff + datasize > bytes.length) {
    return;
  }

  final bd = ByteData.sublistView(bytes);
  final superMagic = bd.getUint32(dataoff, Endian.big);
  if (superMagic != csMagicEmbeddedSignature) {
    return;
  }
  final blobCount = bd.getUint32(dataoff + 8, Endian.big);
  for (var i = 0; i < blobCount; i++) {
    final indexOff = dataoff + 12 + i * 8;
    if (indexOff + 8 > dataoff + datasize) break;
    final blobOffset = bd.getUint32(indexOff + 4, Endian.big);
    final cdOff = dataoff + blobOffset;
    if (cdOff + 44 > dataoff + datasize) continue;

    final blobMagic = bd.getUint32(cdOff, Endian.big);
    if (blobMagic != csMagicCodeDirectory) continue;

    final cdLength = bd.getUint32(cdOff + 4, Endian.big);
    final hashOffset = bd.getUint32(cdOff + 16, Endian.big);
    final nCodeSlots = bd.getUint32(cdOff + 28, Endian.big);
    final codeLimit = bd.getUint32(cdOff + 32, Endian.big);
    final hashSize = bd.getUint8(cdOff + 36);
    final hashType = bd.getUint8(cdOff + 37);
    final pageSizeShift = bd.getUint8(cdOff + 39);

    if (hashType != csHashTypeSha256 || hashSize != 32) {
      continue;
    }
    final pageSize = pageSizeShift > 0 ? (1 << pageSizeShift) : codeLimit;
    final hashesStart = cdOff + hashOffset;
    if (hashesStart + nCodeSlots * 32 > cdOff + cdLength ||
        hashesStart + nCodeSlots * 32 > bytes.length) {
      continue;
    }

    for (var slot = 0; slot < nCodeSlots; slot++) {
      final pageStart = slot * pageSize;
      final pageEnd = math.min<int>(pageStart + pageSize, codeLimit);
      if (pageStart >= bytes.length ||
          pageEnd > bytes.length ||
          pageStart >= pageEnd) {
        break;
      }
      final digest = sha256(Uint8List.sublistView(bytes, pageStart, pageEnd));
      bytes.setRange(
        hashesStart + slot * 32,
        hashesStart + (slot + 1) * 32,
        digest,
      );
    }
  }
}

/// Synthesizes a well-formed 64-bit Mach-O `MH_DYLIB` or `MH_EXECUTE` stub binary.
///
/// Includes `__TEXT` and `__LINKEDIT` segments, `LC_ID_DYLIB` (for `MH_DYLIB`),
/// `LC_SYMTAB`, `LC_DYSYMTAB`, a deterministic content-derived `LC_UUID`,
/// `LC_BUILD_VERSION`, and `MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL` flags
/// so Apple tools (`codesign`, `otool`, `ld64`, `llvm-objdump`) accept it.
Uint8List generateStubMachO({
  required String arch,
  required int platform,
  required int minOs,
  required int sdkVersion,
  required String installName,
  int fileType = mhDylib,
}) {
  final int cputype;
  final int cpusubtype;
  switch (arch) {
    case 'arm64':
      cputype = cpuTypeArm64;
      cpusubtype = cpuSubtypeArm64All;
    case 'x86_64':
      cputype = cpuTypeX86_64;
      cpusubtype = cpuSubtypeX86_64All;
    default:
      throw ArgumentError.value(arch, 'arch', 'Expected "arm64" or "x86_64".');
  }

  // Page size: 16 KB (0x4000) for arm64, 4 KB (0x1000) for x86_64.
  final pageSize = arch == 'arm64' ? 0x4000 : 0x1000;
  // 8-byte aligned empty string table (" \0" padded to 8 bytes) in __LINKEDIT.
  const linkeditFileSize = 8;

  // LC_SEGMENT_64 (__TEXT) - 72 bytes (0 sections).
  final textSeg = buildLcSegment64(
    segname: '__TEXT',
    vmaddr: 0,
    vmsize: pageSize,
    fileoff: 0,
    filesize: pageSize,
    maxprot: 5, // VM_PROT_READ | VM_PROT_EXECUTE
    initprot: 5, // VM_PROT_READ | VM_PROT_EXECUTE
  );

  // LC_SEGMENT_64 (__LINKEDIT) - 72 bytes (0 sections).
  final linkeditSeg = buildLcSegment64(
    segname: '__LINKEDIT',
    vmaddr: pageSize,
    vmsize: pageSize,
    fileoff: pageSize,
    filesize: linkeditFileSize,
    maxprot: 1, // VM_PROT_READ
    initprot: 1, // VM_PROT_READ
  );

  // LC_SYMTAB and LC_DYSYMTAB pointing into __LINKEDIT.
  final symtab = buildLcSymtab(
    symoff: pageSize,
    nsyms: 0,
    stroff: pageSize,
    strsize: linkeditFileSize,
  );
  final dysymtab = buildLcDysymtab();
  final placeholderUuid = buildLcUuid(Uint8List(16));
  final buildVersion = buildLcBuildVersion(
    platform: platform,
    minos: minOs,
    sdk: sdkVersion,
  );

  final commands = <LoadCommand>[
    textSeg,
    linkeditSeg,
    if (fileType == mhDylib && installName.isNotEmpty)
      buildLcIdDylib(installName),
    symtab,
    dysymtab,
    placeholderUuid,
    buildVersion,
    if (fileType == mhExecute)
      buildLcRpath(
        platform == platformMacos
            ? '@executable_path/../Frameworks'
            : '@executable_path/Frameworks',
      ),
  ];

  var sizeofcmds = 0;
  for (final lc in commands) {
    sizeofcmds += lc.cmdsize;
  }

  final flags =
      mhNoundefs |
      mhDyldlink |
      mhTwolevel |
      (fileType == mhExecute ? mhPie : mhNoReexportedDylibs);

  final out = Uint8List(pageSize + linkeditFileSize);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, mhMagic64, Endian.little);
  bd.setUint32(4, cputype, Endian.little);
  bd.setUint32(8, cpusubtype, Endian.little);
  bd.setUint32(12, fileType, Endian.little);
  bd.setUint32(16, commands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, flags, Endian.little);
  bd.setUint32(28, 0, Endian.little);

  var offset = mhHeaderSize64;
  var uuidDataOffset = -1;
  for (final lc in commands) {
    if (lc.cmd == lcUuid) {
      uuidDataOffset = offset + 8;
    }
    out.setRange(offset, offset + lc.cmdsize, lc.bytes);
    offset += lc.cmdsize;
  }

  // Standard Mach-O string table begins with a leading space and NUL byte.
  out[pageSize] = 0x20;
  out[pageSize + 1] = 0x00;

  // Compute deterministic UUID from the binary content (with UUID bytes zeroed),
  // formatted as an RFC 4122 v5 UUID (matching ld64 / ld64.lld).
  if (uuidDataOffset >= 0) {
    final digest = sha256(out);
    final uuid = Uint8List.fromList(digest.sublist(0, 16));
    uuid[6] = (uuid[6] & 0x0f) | 0x50;
    uuid[8] = (uuid[8] & 0x3f) | 0x80;
    out.setRange(uuidDataOffset, uuidDataOffset + 16, uuid);
  }

  return out;
}

// Pure-Dart FIPS 180-4 SHA-256 implementation.
const List<int> _sha256K = <int>[
  0x428a2f98,
  0x71374491,
  0xb5c0fbcf,
  0xe9b5dba5,
  0x3956c25b,
  0x59f111f1,
  0x923f82a4,
  0xab1c5ed5,
  0xd807aa98,
  0x12835b01,
  0x243185be,
  0x550c7dc3,
  0x72be5d74,
  0x80deb1fe,
  0x9bdc06a7,
  0xc19bf174,
  0xe49b69c1,
  0xefbe4786,
  0x0fc19dc6,
  0x240ca1cc,
  0x2de92c6f,
  0x4a7484aa,
  0x5cb0a9dc,
  0x76f988da,
  0x983e5152,
  0xa831c66d,
  0xb00327c8,
  0xbf597fc7,
  0xc6e00bf3,
  0xd5a79147,
  0x06ca6351,
  0x14292967,
  0x27b70a85,
  0x2e1b2138,
  0x4d2c6dfc,
  0x53380d13,
  0x650a7354,
  0x766a0abb,
  0x81c2c92e,
  0x92722c85,
  0xa2bfe8a1,
  0xa81a664b,
  0xc24b8b70,
  0xc76c51a3,
  0xd192e819,
  0xd6990624,
  0xf40e3585,
  0x106aa070,
  0x19a4c116,
  0x1e376c08,
  0x2748774c,
  0x34b0bcb5,
  0x391c0cb3,
  0x4ed8aa4a,
  0x5b9cca4f,
  0x682e6ff3,
  0x748f82ee,
  0x78a5636f,
  0x84c87814,
  0x8cc70208,
  0x90befffa,
  0xa4506ceb,
  0xbef9a3f7,
  0xc67178f2,
];

int _rotr32(int x, int n) => ((x >>> n) | (x << (32 - n))) & 0xffffffff;

/// Computes the 32-byte SHA-256 digest of [data].
Uint8List sha256(Uint8List data) {
  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final bitLength = data.length * 8;
  // Message + 0x80 + zero padding + 8-byte big-endian bit length.
  final paddedLength = ((data.length + 9 + 63) ~/ 64) * 64;
  final padded = Uint8List(paddedLength);
  padded.setRange(0, data.length, data);
  padded[data.length] = 0x80;
  final paddedBd = ByteData.sublistView(padded);
  paddedBd.setUint64(paddedLength - 8, bitLength, Endian.big);

  final w = Uint32List(64);

  for (var chunkOffset = 0; chunkOffset < paddedLength; chunkOffset += 64) {
    for (var i = 0; i < 16; i++) {
      w[i] = paddedBd.getUint32(chunkOffset + i * 4, Endian.big);
    }
    for (var i = 16; i < 64; i++) {
      final w15 = w[i - 15];
      final s0 = _rotr32(w15, 7) ^ _rotr32(w15, 18) ^ (w15 >>> 3);
      final w2 = w[i - 2];
      final s1 = _rotr32(w2, 17) ^ _rotr32(w2, 19) ^ (w2 >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr32(e, 6) ^ _rotr32(e, 11) ^ _rotr32(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + s1 + ch + _sha256K[i] + w[i]) & 0xffffffff;
      final s0 = _rotr32(a, 2) ^ _rotr32(a, 13) ^ _rotr32(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    h0 = (h0 + a) & 0xffffffff;
    h1 = (h1 + b) & 0xffffffff;
    h2 = (h2 + c) & 0xffffffff;
    h3 = (h3 + d) & 0xffffffff;
    h4 = (h4 + e) & 0xffffffff;
    h5 = (h5 + f) & 0xffffffff;
    h6 = (h6 + g) & 0xffffffff;
    h7 = (h7 + h) & 0xffffffff;
  }

  final digest = Uint8List(32);
  final digestBd = ByteData.sublistView(digest);
  digestBd.setUint32(0, h0, Endian.big);
  digestBd.setUint32(4, h1, Endian.big);
  digestBd.setUint32(8, h2, Endian.big);
  digestBd.setUint32(12, h3, Endian.big);
  digestBd.setUint32(16, h4, Endian.big);
  digestBd.setUint32(20, h5, Endian.big);
  digestBd.setUint32(24, h6, Endian.big);
  digestBd.setUint32(28, h7, Endian.big);
  return digest;
}
