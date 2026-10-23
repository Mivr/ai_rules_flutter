/// Hermetic Apple application bundle and archive packager for the `xtool`
/// cross-compilation backend.
///
/// Assembles unsigned iOS `.ipa` (`Payload/<AppName>.app/...`) and macOS
/// `.app.zip` (`<AppName>.app/Contents/...`) archives on any host OS (Linux or
/// macOS) without requiring Xcode, `actool`, `ibtool`, `codesign`, or external
/// system zip utilities, or signs them when `zsign` is provided.
///
/// Capabilities:
///   1. XML `Info.plist` merging, variable substitution (`$(EXECUTABLE_NAME)`,
///      `${PRODUCT_BUNDLE_IDENTIFIER}`, `${MACOSX_DEPLOYMENT_TARGET}`, etc.),
///      and standard Apple bundle metadata injection.
///   2. Framework resolution from `.framework` directories, wrapper tree
///      artifacts containing `*.framework`, or `.xcframework` bundles (selecting
///      the appropriate slice for `ios`, `ios_sim`, or `macos`).
///   3. Pure-Dart SHA-1 (RFC 3174) and SHA-256 (FIPS 180-4) digest computation
///      and Apple `_CodeSignature/CodeResources` XML property list generation
///      when signing with `zsign`.
///   4. Optional `zsign` invocation when a `zsign` binary is provided; unsigned
///      bundles omit `_CodeSignature/`.
///   5. Pure-Dart deterministic ZIP archive writer with Unix permission bits
///      (`0755` for executables and framework dylibs, `0644` for resources,
///      `0120777` for symbolic links) and fixed DOS epoch timestamps.
///
/// Usage:
///   dart xtool_pack.dart bundle \
///     --platform <ios|ios_sim|macos> \
///     --app-name <AppName> \
///     --bundle-id <com.example.app> \
///     --executable <path> \
///     --minimum-os-version <version> \
///     [--info-plist <path> ...] \
///     [--define <KEY=VALUE> ...] \
///     [--framework <path> ...] \
///     [--resource <src[=dest_rel]> ...] \
///     [--provisioning-profile <path>] \
///     [--entitlements <path>] \
///     [--zsign <path>] \
///     [--certificate <path>] \
///     [--certificate-password-file <path>] \
///     [--certificate-password-env <ENV_VAR>] \
///     [--temp-dir <path>] \
///     [--output-archive <path>] \
///     [--output-app-dir <path>]
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'macho_edit.dart' show Segment64Spec;
import 'xtool_bundle.dart';
import 'xtool_framework.dart';
import 'xtool_hash.dart';
import 'zip_writer.dart';

export 'code_resources.dart';
export 'xtool_bundle.dart';
export 'xtool_framework.dart';
export 'plist_info.dart';
export 'zip_reader.dart';
export 'zip_writer.dart';
export 'plist_parse.dart';
export 'xtool_hash.dart';

// ---------------------------------------------------------------------------
// 7. Darwin SDK resolution and Mach-O MH_EXECUTE runner compilation
// ---------------------------------------------------------------------------

int _packMachOVersion(String version) {
  final parts = version.split('.');
  final major = parts.isNotEmpty ? (int.tryParse(parts[0]) ?? 0) : 0;
  final minor = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
  final patch = parts.length > 2 ? (int.tryParse(parts[2]) ?? 0) : 0;
  return ((major & 0xffff) << 16) | ((minor & 0xff) << 8) | (patch & 0xff);
}

int _machOPlatformConstant(String platform) {
  switch (platform) {
    case 'macos':
      return 1; // PLATFORM_MACOS
    case 'ios':
      return 2; // PLATFORM_IOS
    case 'ios_sim':
      return 7; // PLATFORM_IOSSIMULATOR
    default:
      throw ArgumentError('Unsupported platform: $platform');
  }
}

Uint8List _encodeMachOSegment64Command(Segment64Spec spec) {
  final bytes = Uint8List(72);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x19, Endian.little); // LC_SEGMENT_64
  bd.setUint32(4, 72, Endian.little);
  final nameBytes = ascii.encode(spec.segname);
  bytes.setRange(
    8,
    8 + (nameBytes.length > 16 ? 16 : nameBytes.length),
    nameBytes,
  );
  setUint64LE(bd, 24, spec.vmaddr);
  setUint64LE(bd, 32, spec.vmsize);
  setUint64LE(bd, 40, spec.fileoff);
  setUint64LE(bd, 48, spec.filesize);
  bd.setInt32(56, spec.maxprot, Endian.little);
  bd.setInt32(60, spec.initprot, Endian.little);
  bd.setUint32(64, spec.nsects, Endian.little); // nsects
  bd.setUint32(68, spec.flags, Endian.little); // flags
  return bytes;
}

Uint8List _encodeMachOSymtabCommand({
  required int symoff,
  required int nsyms,
  required int stroff,
  required int strsize,
}) {
  final bytes = Uint8List(24);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x02, Endian.little); // LC_SYMTAB
  bd.setUint32(4, 24, Endian.little);
  bd.setUint32(8, symoff, Endian.little);
  bd.setUint32(12, nsyms, Endian.little);
  bd.setUint32(16, stroff, Endian.little);
  bd.setUint32(20, strsize, Endian.little);
  return bytes;
}

Uint8List _encodeMachODysymtabCommand() {
  final bytes = Uint8List(80);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x0b, Endian.little); // LC_DYSYMTAB
  bd.setUint32(4, 80, Endian.little);
  return bytes;
}

Uint8List _encodeMachOUuidCommand(Uint8List uuid16) {
  final bytes = Uint8List(24);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x1b, Endian.little); // LC_UUID
  bd.setUint32(4, 24, Endian.little);
  bytes.setRange(8, 24, uuid16);
  return bytes;
}

Uint8List _encodeMachOLoadDylibCommand(String installName) {
  final nameBytes = utf8.encode(installName);
  const headerSize = 24;
  final unpadded = headerSize + nameBytes.length + 1;
  final cmdSize = (unpadded + 7) & ~7;
  final bytes = Uint8List(cmdSize);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x0c, Endian.little); // LC_LOAD_DYLIB
  bd.setUint32(4, cmdSize, Endian.little);
  bd.setUint32(8, headerSize, Endian.little); // name offset
  bd.setUint32(12, 2, Endian.little); // timestamp
  bd.setUint32(16, 0x00010000, Endian.little); // current_version 1.0.0
  bd.setUint32(20, 0x00010000, Endian.little); // compatibility_version 1.0.0
  bytes.setRange(headerSize, headerSize + nameBytes.length, nameBytes);
  return bytes;
}

Uint8List _encodeMachOBuildVersionCommand({
  required int platform,
  required int minos,
  required int sdk,
}) {
  final bytes = Uint8List(24);
  final bd = ByteData.sublistView(bytes);
  bd.setUint32(0, 0x32, Endian.little); // LC_BUILD_VERSION
  bd.setUint32(4, 24, Endian.little); // cmdsize
  bd.setUint32(8, platform, Endian.little);
  bd.setUint32(12, minos, Endian.little);
  bd.setUint32(16, sdk, Endian.little);
  bd.setUint32(20, 0, Endian.little); // ntools = 0
  return bytes;
}

({int cpuType, int cpuSubtype, int pageSize}) _stubArchParams(String arch) {
  switch (arch) {
    case 'arm64':
      // CPU_TYPE_ARM64 / CPU_SUBTYPE_ARM64_ALL, 16 KiB pages.
      return (cpuType: 0x0100000c, cpuSubtype: 0, pageSize: 0x4000);
    case 'x86_64':
      // CPU_TYPE_X86_64 / CPU_SUBTYPE_X86_64_ALL, 4 KiB pages.
      return (cpuType: 0x01000007, cpuSubtype: 3, pageSize: 0x1000);
    default:
      throw ArgumentError('Unsupported architecture "$arch".');
  }
}

List<Uint8List> _stubLoadCommands(
  StubRunnerSpec spec,
  int versionPacked,
  int pageSize,
  int linkeditFileSize,
) {
  final platform = spec.platform;
  return [
    _encodeMachOBuildVersionCommand(
      platform: _machOPlatformConstant(platform),
      minos: versionPacked,
      sdk: versionPacked,
    ),
    _encodeMachOSegment64Command((
      segname: '__TEXT',
      vmaddr: 0,
      vmsize: pageSize,
      fileoff: 0,
      filesize: pageSize,
      maxprot: 5,
      initprot: 5,
      nsects: 0,
      flags: 0,
    )),
    _encodeMachOSegment64Command((
      segname: '__LINKEDIT',
      vmaddr: pageSize,
      vmsize: pageSize,
      fileoff: pageSize,
      filesize: linkeditFileSize,
      maxprot: 1,
      initprot: 1,
      nsects: 0,
      flags: 0,
    )),
    _encodeMachOSymtabCommand(
      symoff: pageSize,
      nsyms: 0,
      stroff: pageSize,
      strsize: linkeditFileSize,
    ),
    _encodeMachODysymtabCommand(),
    _encodeMachOUuidCommand(Uint8List(16)),
    encodeMachORpathCommand('@executable_path/Frameworks'),
    if (platform == 'macos')
      encodeMachORpathCommand('@executable_path/../Frameworks'),
    for (final fw in spec.linkedFrameworkNames)
      _encodeMachOLoadDylibCommand('@rpath/$fw.framework/$fw'),
    for (final sdkFw in spec.sdkFrameworks)
      _encodeMachOLoadDylibCommand(
        platform == 'macos'
            ? '/System/Library/Frameworks/$sdkFw.framework/Versions/A/$sdkFw'
            : '/System/Library/Frameworks/$sdkFw.framework/$sdkFw',
      ),
    for (final dylib in spec.sdkDylibs)
      _encodeMachOLoadDylibCommand(
        '/usr/lib/${dylib.startsWith('lib') ? dylib : 'lib$dylib'}.dylib',
      ),
  ];
}

/// Writes [loadCommands] after the Mach-O header, returning the file offset
/// of the `LC_UUID` payload for later stamping.
int _writeStubCommands(Uint8List out, List<Uint8List> loadCommands) {
  var offset = 32;
  var uuidDataOffset = -1;
  for (final cmd in loadCommands) {
    final cmdId = ByteData.sublistView(cmd).getUint32(0, Endian.little);
    if (cmdId == 0x1b) {
      uuidDataOffset = offset + 8;
    }
    out.setRange(offset, offset + cmd.length, cmd);
    offset += cmd.length;
  }
  return uuidDataOffset;
}

void _stampStubUuid(Uint8List out, int uuidDataOffset) {
  if (uuidDataOffset < 0) return;
  final digest = sha256Bytes(out);
  final uuid = Uint8List.fromList(digest.sublist(0, 16));
  uuid[6] = (uuid[6] & 0x0f) | 0x50;
  uuid[8] = (uuid[8] & 0x3f) | 0x80;
  out.setRange(uuidDataOffset, uuidDataOffset + 16, uuid);
}

/// The inputs for synthesizing a stub runner Mach-O binary: target platform
/// and version plus linked frameworks, libraries, and metadata. Grouped so
/// the stub entry points stay small.
class StubRunnerSpec {
  const StubRunnerSpec({
    required this.platform,
    this.arch = 'arm64',
    required this.minimumOsVersion,
    this.linkedFrameworkNames = const [],
    this.sdkFrameworks = const [],
    this.sdkDylibs = const [],
    this.metadataEntries = const [],
  });

  /// The target platform (`ios`, `ios_sim`, or `macos`).
  final String platform;

  /// The target architecture (`arm64` or `x86_64`).
  final String arch;

  /// The minimum-OS version string.
  final String minimumOsVersion;

  /// The embedded frameworks to `LC_LOAD_DYLIB`.
  final List<String> linkedFrameworkNames;

  /// The system frameworks to `LC_LOAD_DYLIB`.
  final List<String> sdkFrameworks;

  /// The `/usr/lib` libraries to `LC_LOAD_DYLIB`.
  final List<String> sdkDylibs;

  /// The metadata lines embedded in `__TEXT`.
  final List<String> metadataEntries;
}

/// Synthesizes a 64-bit Mach-O `MH_EXECUTE` runner binary with
/// `LC_BUILD_VERSION`, `__TEXT` / `__LINKEDIT` segments, `LC_SYMTAB`,
/// `LC_DYSYMTAB`, `LC_UUID`, `LC_RPATH`, and `LC_LOAD_DYLIB` commands.
Uint8List generateStubExecutableMachO(StubRunnerSpec spec) {
  final archParams = _stubArchParams(spec.arch);
  final pageSize = archParams.pageSize;
  const linkeditFileSize = 8;
  final versionPacked = _packMachOVersion(spec.minimumOsVersion);

  final loadCommands = _stubLoadCommands(
    spec,
    versionPacked,
    pageSize,
    linkeditFileSize,
  );
  final sizeofcmds = loadCommands.fold<int>(0, (s, c) => s + c.length);
  final metadataText = spec.metadataEntries.isEmpty
      ? ''
      : '${spec.metadataEntries.join('\n')}\n';
  final metadataBytes = utf8.encode(metadataText);

  final totalSize = pageSize + linkeditFileSize;
  final out = Uint8List(totalSize);
  final bd = ByteData.sublistView(out);
  bd.setUint32(0, 0xfeedfacf, Endian.little); // MH_MAGIC_64
  bd.setInt32(4, archParams.cpuType, Endian.little);
  bd.setInt32(8, archParams.cpuSubtype, Endian.little);
  bd.setUint32(12, 0x2, Endian.little); // MH_EXECUTE
  bd.setUint32(16, loadCommands.length, Endian.little);
  bd.setUint32(20, sizeofcmds, Endian.little);
  bd.setUint32(24, 0x00200001, Endian.little); // MH_NOUNDEFS | MH_PIE
  bd.setUint32(28, 0, Endian.little); // reserved

  final uuidDataOffset = _writeStubCommands(out, loadCommands);

  // Leave 64 bytes of zero padding after load commands before writing metadata
  // inside __TEXT so any subsequent load-command patching has room.
  final metaStart = 32 + sizeofcmds + 64;
  if (metadataBytes.isNotEmpty &&
      metaStart + metadataBytes.length <= pageSize) {
    out.setRange(metaStart, metaStart + metadataBytes.length, metadataBytes);
  }

  // Standard Mach-O string table in __LINKEDIT begins with " \0".
  out[pageSize] = 0x20;
  out[pageSize + 1] = 0x00;

  _stampStubUuid(out, uuidDataOffset);
  return out;
}

({String sdkPrefix, String defaultDirName}) _sdkNamesForPlatform(
  String platform,
) {
  switch (platform) {
    case 'ios':
      return (sdkPrefix: 'iphoneos', defaultDirName: 'iPhoneOS.sdk');
    case 'ios_sim':
      return (
        sdkPrefix: 'iphonesimulator',
        defaultDirName: 'iPhoneSimulator.sdk',
      );
    case 'macos':
      return (sdkPrefix: 'macosx', defaultDirName: 'MacOSX.sdk');
    default:
      throw ArgumentError('Unsupported platform "$platform".');
  }
}

/// Searches an `info.json` artifact bundle for a variant whose key or path
/// names the [sdkPrefix], returning its directory when it exists.
Directory? _findSdkInArtifactInfo(
  Directory sdkRoot,
  Object? decoded,
  String sdkPrefix,
) {
  if (decoded is! Map<String, Object?>) return null;
  final artifacts = decoded['artifacts'];
  if (artifacts is! Map<String, Object?>) return null;
  for (final entry in artifacts.entries) {
    final candidate = _matchSdkVariant(
      sdkRoot,
      entry.key,
      entry.value,
      sdkPrefix,
    );
    if (candidate != null) return candidate;
  }
  return null;
}

Directory? _matchSdkVariant(
  Directory sdkRoot,
  String key,
  Object? val,
  String sdkPrefix,
) {
  if (val is! Map<String, Object?>) return null;
  final variants = val['variants'];
  if (variants is! List<Object?>) return null;
  final keyLower = key.toLowerCase();
  for (final v in variants) {
    if (v is! Map<String, Object?>) continue;
    final path = v['path'];
    if (path is! String) continue;
    if (keyLower.startsWith(sdkPrefix) ||
        path.toLowerCase().contains(sdkPrefix)) {
      final candidate = Directory('${sdkRoot.path}/$path');
      if (candidate.existsSync()) {
        return candidate;
      }
    }
  }
  return null;
}

/// Resolves the platform `.sdk` directory inside a `darwin.artifactbundle`
/// directory for [platform] (`ios`, `ios_sim`, or `macos`).
Directory resolveDarwinSdkPathFromArtifactBundle(
  Directory sdkRoot,
  String platform,
) {
  if (!sdkRoot.existsSync()) {
    throw ArgumentError('SDK root directory does not exist: ${sdkRoot.path}');
  }
  final names = _sdkNamesForPlatform(platform);

  final infoJsonFile = File('${sdkRoot.path}/info.json');
  if (infoJsonFile.existsSync()) {
    final decoded = jsonDecode(infoJsonFile.readAsStringSync());
    final fromInfo = _findSdkInArtifactInfo(sdkRoot, decoded, names.sdkPrefix);
    if (fromInfo != null) return fromInfo;
  }

  final fallback = Directory('${sdkRoot.path}/${names.defaultDirName}');
  if (fallback.existsSync()) {
    return fallback;
  }

  throw ArgumentError(
    'Could not resolve Darwin SDK for platform "$platform" in ${sdkRoot.path}',
  );
}

/// Configuration for compiling or synthesizing an iOS/macOS runner binary.
class RunnerCompileConfig {
  final String platform; // 'ios', 'ios_sim', or 'macos'
  final String arch; // 'arm64' or 'x86_64'
  final String appName;
  final String minimumOsVersion;
  final bool sdkAvailable;
  final String? sdkRootPath;
  final String? swiftcPath;
  final String? clangPath;
  final List<String> sourcePaths;
  final List<String> headerPaths;
  final List<String> modulemapPaths;
  final List<String> frameworkPaths;
  final List<String> sdkFrameworks;
  final List<String> sdkDylibs;
  final String outputPath;

  const RunnerCompileConfig({
    required this.platform,
    this.arch = 'arm64',
    required this.appName,
    required this.minimumOsVersion,
    this.sdkAvailable = false,
    this.sdkRootPath,
    this.swiftcPath,
    this.clangPath,
    this.sourcePaths = const [],
    this.headerPaths = const [],
    this.modulemapPaths = const [],
    this.frameworkPaths = const [],
    this.sdkFrameworks = const [],
    this.sdkDylibs = const [],
    required this.outputPath,
  });
}

void _checkRunnerPlatform(RunnerCompileConfig config) {
  if (config.platform != 'ios' &&
      config.platform != 'ios_sim' &&
      config.platform != 'macos') {
    throw ArgumentError(
      'Unsupported platform "${config.platform}". Expected ios, ios_sim, or macos.',
    );
  }
}

void _requireRunnerFilesExist(List<String> paths, String kind) {
  for (final path in paths) {
    if (!File(path).existsSync()) {
      throw ArgumentError('Runner $kind file does not exist: $path');
    }
  }
}

/// Resolves `--framework` inputs to framework directories and their link
/// names, extracting `.framework.zip` archives beside the runner output.
({
  List<Directory> dirs,
  List<String> names,
})
_resolveRunnerFrameworks(RunnerCompileConfig config) {
  final resolvedFrameworkDirs = <Directory>[];
  final linkedFrameworkNames = <String>[];
  Directory? frameworksScratch;
  for (final fwInput in config.frameworkPaths) {
    final List<Directory> dirs;
    if (fwInput.endsWith('.framework.zip')) {
      // Same archive form as bundle embedding (see above): extract beside
      // the declared runner output so the linker gets a real directory.
      frameworksScratch ??= Directory('${config.outputPath}.frameworks')
        ..createSync(recursive: true);
      dirs = [extractFrameworkArchive(fwInput, frameworksScratch)];
    } else {
      dirs = resolveFrameworkDirectories(fwInput, config.platform);
    }
    for (final d in dirs) {
      resolvedFrameworkDirs.add(d);
      final base = d.uri.pathSegments.where((s) => s.isNotEmpty).last;
      final fwName = base.endsWith('.framework')
          ? base.substring(0, base.length - '.framework'.length)
          : base;
      if (!linkedFrameworkNames.contains(fwName)) {
        linkedFrameworkNames.add(fwName);
      }
    }
  }
  return (dirs: resolvedFrameworkDirs, names: linkedFrameworkNames);
}

List<String> _dedupeNonEmpty(List<String> values) {
  final deduped = <String>[];
  for (final value in values) {
    if (value.isNotEmpty && !deduped.contains(value)) {
      deduped.add(value);
    }
  }
  return deduped;
}

Directory? _resolveRunnerSdkDir(RunnerCompileConfig config) {
  if (config.sdkAvailable &&
      config.sdkRootPath != null &&
      config.sdkRootPath!.isNotEmpty) {
    return resolveDarwinSdkPathFromArtifactBundle(
      Directory(config.sdkRootPath!),
      config.platform,
    );
  }
  return null;
}

String _runnerTargetTriple(RunnerCompileConfig config) {
  switch (config.platform) {
    case 'ios':
      return '${config.arch}-apple-ios${config.minimumOsVersion}';
    case 'ios_sim':
      return '${config.arch}-apple-ios${config.minimumOsVersion}-simulator';
    case 'macos':
      return '${config.arch}-apple-macos${config.minimumOsVersion}';
    default:
      throw StateError('Unreachable');
  }
}

List<String> _buildSwiftcArgs(
  RunnerCompileConfig config,
  Directory? resolvedSdkDir,
  List<Directory> resolvedFrameworkDirs,
  List<String> linkedFrameworkNames,
  List<String> sdkFrameworks,
  List<String> sdkDylibs,
) {
  final swiftcArgs = <String>[
    '-target',
    _runnerTargetTriple(config),
    if (resolvedSdkDir != null) ...['-sdk', resolvedSdkDir.path],
    '-Xlinker',
    '-rpath',
    '-Xlinker',
    '@executable_path/Frameworks',
    if (config.platform == 'macos') ...[
      '-Xlinker',
      '-rpath',
      '-Xlinker',
      '@executable_path/../Frameworks',
    ],
  ];

  final seenFwParents = <String>{};
  for (final fwDir in resolvedFrameworkDirs) {
    final parentPath = fwDir.parent.path;
    if (seenFwParents.add(parentPath)) {
      swiftcArgs.addAll(['-F', parentPath]);
    }
  }
  for (final fwName in linkedFrameworkNames) {
    swiftcArgs.addAll(['-framework', fwName]);
  }
  for (final sdkFw in sdkFrameworks) {
    swiftcArgs.addAll(['-framework', sdkFw]);
  }
  for (final dylib in sdkDylibs) {
    final libArg = dylib.startsWith('lib') ? dylib.substring(3) : dylib;
    swiftcArgs.add('-l$libArg');
  }

  final seenHeaderDirs = <String>{};
  for (final hdr in config.headerPaths) {
    final dirPath = File(hdr).parent.path;
    if (seenHeaderDirs.add(dirPath)) {
      swiftcArgs.addAll(['-I', dirPath]);
    }
  }
  for (final mm in config.modulemapPaths) {
    swiftcArgs.addAll(['-Xcc', '-fmodule-map-file=$mm']);
  }

  swiftcArgs.addAll([
    ...config.sourcePaths,
    '-emit-executable',
    '-o',
    config.outputPath,
  ]);
  return swiftcArgs;
}

void _runSwiftc(RunnerCompileConfig config, List<String> swiftcArgs) {
  File(config.outputPath).parent.createSync(recursive: true);
  final result = Process.runSync(
    config.swiftcPath!,
    swiftcArgs,
    environment: const {'PATH': '/usr/bin:/bin'},
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw ProcessException(
      config.swiftcPath!,
      swiftcArgs,
      'swiftc failed (exit ${result.exitCode}):\n${result.stderr}',
      result.exitCode,
    );
  }
}

void _synthesizeRunnerBinary(
  RunnerCompileConfig config,
  Directory? resolvedSdkDir,
  List<String> linkedFrameworkNames,
  List<String> sdkFrameworks,
  List<String> sdkDylibs,
) {
  final metadataEntries = <String>[
    'app=${config.appName}',
    'platform=${config.platform}',
    'arch=${config.arch}',
    'sdk_available=${config.sdkAvailable}',
    if (resolvedSdkDir != null)
      'sdk=${resolvedSdkDir.uri.pathSegments.where((s) => s.isNotEmpty).last}',
    for (final src in config.sourcePaths)
      'source=${Uri.file(src).pathSegments.where((s) => s.isNotEmpty).last}',
    for (final hdr in config.headerPaths)
      'header=${Uri.file(hdr).pathSegments.where((s) => s.isNotEmpty).last}',
    for (final mm in config.modulemapPaths)
      'modulemap=${Uri.file(mm).pathSegments.where((s) => s.isNotEmpty).last}',
    for (final fw in linkedFrameworkNames) 'framework=$fw',
    for (final sdkFw in sdkFrameworks) 'sdk_framework=$sdkFw',
    for (final dylib in sdkDylibs) 'sdk_dylib=$dylib',
  ];

  final machoBytes = generateStubExecutableMachO(
    StubRunnerSpec(
      platform: config.platform,
      arch: config.arch,
      minimumOsVersion: config.minimumOsVersion,
      linkedFrameworkNames: linkedFrameworkNames,
      sdkFrameworks: sdkFrameworks,
      sdkDylibs: sdkDylibs,
      metadataEntries: metadataEntries,
    ),
  );
  final outFile = File(config.outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsBytesSync(machoBytes);
}

/// Compiles or synthesizes a Mach-O `MH_EXECUTE` runner binary from
/// [RunnerCompileConfig].
void compileRunner(RunnerCompileConfig config) {
  _checkRunnerPlatform(config);
  _requireRunnerFilesExist(config.sourcePaths, 'source');
  _requireRunnerFilesExist(config.headerPaths, 'header');
  _requireRunnerFilesExist(config.modulemapPaths, 'modulemap');

  final resolved = _resolveRunnerFrameworks(config);
  final sdkFrameworks = _dedupeNonEmpty(config.sdkFrameworks);
  final sdkDylibs = _dedupeNonEmpty(config.sdkDylibs);
  final resolvedSdkDir = _resolveRunnerSdkDir(config);

  if (config.sdkAvailable &&
      config.swiftcPath != null &&
      config.swiftcPath!.isNotEmpty) {
    _runSwiftc(
      config,
      _buildSwiftcArgs(
        config,
        resolvedSdkDir,
        resolved.dirs,
        resolved.names,
        sdkFrameworks,
        sdkDylibs,
      ),
    );
    return;
  }

  _synthesizeRunnerBinary(
    config,
    resolvedSdkDir,
    resolved.names,
    sdkFrameworks,
    sdkDylibs,
  );
}

/// Reads the `BUILD_EMBED_LABEL` value from a Bazel `stable-status.txt` file,
/// falling back to [fallbackBuildLabel] when absent.
String? _readBuildEmbedLabel(
  String? stableStatusPath,
  String fallbackBuildLabel,
) {
  String? embedLabel;
  if (stableStatusPath != null &&
      stableStatusPath.isNotEmpty &&
      File(stableStatusPath).existsSync()) {
    for (final line in File(stableStatusPath).readAsLinesSync()) {
      if (line.startsWith('BUILD_EMBED_LABEL ')) {
        final val = line.substring('BUILD_EMBED_LABEL '.length).trim();
        if (val.isNotEmpty) {
          embedLabel = val;
        }
        break;
      }
    }
  }
  if ((embedLabel == null || embedLabel.isEmpty) &&
      fallbackBuildLabel.isNotEmpty) {
    embedLabel = fallbackBuildLabel;
  }
  return embedLabel;
}

/// Matches [embedLabel] against [buildLabelPattern]'s `{name}` placeholders,
/// returning the captured group values.
Map<String, String> _matchLabelGroups(
  String buildLabelPattern,
  Map<String, String> captureGroups,
  String embedLabel,
) {
  final groupNames = <String>[];
  final regexPattern = buildLabelPattern.replaceAllMapped(
    RegExp(r'\{([A-Za-z0-9_]+)\}'),
    (m) {
      final name = m.group(1)!;
      final groupRegex = captureGroups[name];
      if (groupRegex == null) {
        throw ArgumentError(
          'Placeholder "{$name}" in build_label_pattern is not present in capture_groups.',
        );
      }
      groupNames.add(name);
      return '($groupRegex)';
    },
  );
  final match = RegExp('^$regexPattern\$').firstMatch(embedLabel);
  if (match == null) {
    throw ArgumentError(
      'Build label "$embedLabel" did not match build_label_pattern "$buildLabelPattern".',
    );
  }
  final values = <String, String>{};
  for (var i = 0; i < groupNames.length; i++) {
    values[groupNames[i]] = match.group(i + 1) ?? '';
  }
  return values;
}

String _substituteLabelGroups(String template, Map<String, String> values) {
  return template.replaceAllMapped(RegExp(r'\{([A-Za-z0-9_]+)\}'), (m) {
    final name = m.group(1)!;
    return values[name] ?? m.group(0)!;
  });
}

/// The inputs for resolving bundle versions from a build label: templates,
/// label-matching rules, and the output path. Grouped so the resolver entry
/// point stays small.
class BundleVersionRequest {
  const BundleVersionRequest({
    required this.buildVersion,
    this.shortVersionString = '',
    this.buildLabelPattern = '',
    this.fallbackBuildLabel = '',
    this.captureGroups = const {},
    this.stableStatusPath,
    required this.outputPath,
  });

  /// The `build_version` template.
  final String buildVersion;

  /// The `short_version_string` template (defaults to [buildVersion]).
  final String shortVersionString;

  /// The regex the `BUILD_EMBED_LABEL` must match, if any.
  final String buildLabelPattern;

  /// The label used when no `stable-status.txt` entry exists.
  final String fallbackBuildLabel;

  /// The named capture-group patterns for label substitution.
  final Map<String, String> captureGroups;

  /// The `stable-status.txt` path, if any.
  final String? stableStatusPath;

  /// Where to write the resolved version JSON.
  final String outputPath;
}

/// Resolves `build_version` and `short_version_string` from a Bazel
/// `stable-status.txt` `BUILD_EMBED_LABEL` (or the request's fallback build
/// label) and the request's build-label pattern / capture groups, writing
/// JSON to the request's output path.
void resolveBundleVersion(BundleVersionRequest request) {
  final buildVersion = request.buildVersion;
  final buildLabelPattern = request.buildLabelPattern;
  var resolvedShort = request.shortVersionString.isNotEmpty
      ? request.shortVersionString
      : buildVersion;
  var resolvedBuild = buildVersion;

  if (buildLabelPattern.isNotEmpty) {
    final embedLabel = _readBuildEmbedLabel(
      request.stableStatusPath,
      request.fallbackBuildLabel,
    );
    if (embedLabel != null && embedLabel.isNotEmpty) {
      final values = _matchLabelGroups(
        buildLabelPattern,
        request.captureGroups,
        embedLabel,
      );
      resolvedBuild = _substituteLabelGroups(resolvedBuild, values);
      resolvedShort = _substituteLabelGroups(resolvedShort, values);
    }
  }

  final outFile = File(request.outputPath);
  outFile.parent.createSync(recursive: true);
  outFile.writeAsStringSync(
    '${jsonEncode({'build_version': resolvedBuild, 'short_version_string': resolvedShort})}\n',
  );
}

// ---------------------------------------------------------------------------
// CLI entrypoint
// ---------------------------------------------------------------------------

Never _usageError(String message) {
  stderr.writeln(message);
  stderr.writeln(
    'Usage:\n'
    '  dart xtool_pack.dart bundle \\\n'
    '    --platform <ios|ios_sim|macos> \\\n'
    '    --app-name <AppName> \\\n'
    '    --bundle-id <com.example.app> \\\n'
    '    --executable <path> \\\n'
    '    --minimum-os-version <version> \\\n'
    '    [--family <iphone|ipad> ...] \\\n'
    '    [--version-file <path>] \\\n'
    '    [--info-plist <path> ...] \\\n'
    '    [--define <KEY=VALUE> ...] \\\n'
    '    [--framework <path> ...] \\\n'
    '    [--native-lib <path> ...] \\\n'
    '    [--resource <src[=dest_rel]> ...] \\\n'
    '    [--additional-content <subdir=src> ...] \\\n'
    '    [--provisioning-profile <path>] \\\n'
    '    [--entitlements <path>] \\\n'
    '    [--zsign <path>] \\\n'
    '    [--certificate <path>] \\\n'
    '    [--certificate-password-file <path>] \\\n'
    '    [--certificate-password-env <ENV_VAR>] \\\n'
    '    [--temp-dir <path>] \\\n'
    '    [--output-archive <path>] \\\n'
    '    [--output-app-dir <path>]',
  );
  exit(1);
}

/// Mutable parse state for `resolve-version` CLI arguments.
class _ResolveVersionArgState {
  String buildVersion = '1.0';
  String shortVersionString = '';
  String buildLabelPattern = '';
  String fallbackBuildLabel = '';
  final captureGroups = <String, String>{};
  String? stableStatusPath;
  String? outputPath;

  int apply(List<String> args, int i) {
    final arg = args[i];
    String nextVal() {
      if (i + 1 >= args.length) {
        _usageError('Missing value for $arg.');
      }
      return args[++i];
    }

    switch (arg) {
      case '--control':
        _applyControlFile(nextVal());
      case '--build-version':
        buildVersion = nextVal();
      case '--short-version-string':
        shortVersionString = nextVal();
      case '--build-label-pattern':
        buildLabelPattern = nextVal();
      case '--fallback-build-label':
        fallbackBuildLabel = nextVal();
      case '--capture-group':
        _applyCaptureGroup(nextVal());
      case '--stable-status':
        stableStatusPath = nextVal();
      case '--output':
        outputPath = nextVal();
      default:
        _usageError('Unrecognized argument for resolve-version: $arg');
    }
    return i;
  }

  void _applyControlFile(String controlPath) {
    final decoded = jsonDecode(File(controlPath).readAsStringSync());
    if (decoded is! Map) {
      _usageError('Control file $controlPath must contain a JSON object.');
    }
    buildVersion =
        (decoded['build_version_pattern'] as String?) ?? buildVersion;
    shortVersionString =
        (decoded['short_version_string_pattern'] as String?) ??
        shortVersionString;
    buildLabelPattern =
        (decoded['build_label_pattern'] as String?) ?? buildLabelPattern;
    fallbackBuildLabel =
        (decoded['fallback_build_label'] as String?) ?? fallbackBuildLabel;
    stableStatusPath =
        (decoded['build_info_path'] as String?) ?? stableStatusPath;
    final cg = decoded['capture_groups'];
    if (cg is Map) {
      for (final entry in cg.entries) {
        captureGroups[entry.key.toString()] = entry.value.toString();
      }
    }
  }

  void _applyCaptureGroup(String kv) {
    final eq = kv.indexOf('=');
    if (eq == -1) {
      _usageError('Expected KEY=REGEX for --capture-group, got "$kv".');
    }
    captureGroups[kv.substring(0, eq)] = kv.substring(eq + 1);
  }
}

void _runResolveVersionCli(List<String> args) {
  final state = _ResolveVersionArgState();
  for (var i = 0; i < args.length; i++) {
    i = state.apply(args, i);
  }
  final outputPath = state.outputPath;
  if (outputPath == null) {
    _usageError('Required flag for resolve-version: --output.');
  }

  try {
    resolveBundleVersion(
      BundleVersionRequest(
        buildVersion: state.buildVersion,
        shortVersionString: state.shortVersionString,
        buildLabelPattern: state.buildLabelPattern,
        fallbackBuildLabel: state.fallbackBuildLabel,
        captureGroups: state.captureGroups,
        stableStatusPath: state.stableStatusPath,
        outputPath: outputPath,
      ),
    );
  } on Object catch (e) {
    stderr.writeln('xtool_pack resolve-version failed: $e');
    exit(1);
  }
}

/// Mutable parse state for `compile-runner` CLI arguments.
class _CompileRunnerArgState {
  String? platform;
  String arch = 'arm64';
  String? appName;
  String minimumOsVersion = '14.0';
  bool sdkAvailable = false;
  String? sdkRootPath;
  String? swiftcPath;
  String? clangPath;
  final sourcePaths = <String>[];
  final headerPaths = <String>[];
  final modulemapPaths = <String>[];
  final frameworkPaths = <String>[];
  final sdkFrameworks = <String>[];
  final sdkDylibs = <String>[];
  String? outputPath;

  int apply(List<String> args, int i) {
    final arg = args[i];
    String nextVal() {
      if (i + 1 >= args.length) {
        _usageError('Missing value for $arg.');
      }
      return args[++i];
    }

    switch (arg) {
      case '--platform':
        platform = nextVal();
      case '--arch':
        arch = nextVal();
      case '--app-name':
        appName = nextVal();
      case '--minimum-os-version':
        minimumOsVersion = nextVal();
      case '--sdk-available':
        sdkAvailable = nextVal().toLowerCase() == 'true';
      case '--sdk-root':
        sdkRootPath = nextVal();
      case '--swiftc':
        swiftcPath = nextVal();
      case '--clang':
        clangPath = nextVal();
      case '--source':
        sourcePaths.add(nextVal());
      case '--header':
        headerPaths.add(nextVal());
      case '--modulemap':
        modulemapPaths.add(nextVal());
      case '--framework':
        frameworkPaths.add(nextVal());
      case '--sdk-framework':
        sdkFrameworks.add(nextVal());
      case '--sdk-dylib':
        sdkDylibs.add(nextVal());
      case '--output':
        outputPath = nextVal();
      default:
        _usageError('Unrecognized argument for compile-runner: $arg');
    }
    return i;
  }

  RunnerCompileConfig build() {
    if (platform == null || appName == null || outputPath == null) {
      _usageError(
        'Required flags for compile-runner: --platform, --app-name, --output.',
      );
    }
    return RunnerCompileConfig(
      platform: platform!,
      arch: arch,
      appName: appName!,
      minimumOsVersion: minimumOsVersion,
      sdkAvailable: sdkAvailable,
      sdkRootPath: sdkRootPath,
      swiftcPath: swiftcPath,
      clangPath: clangPath,
      sourcePaths: sourcePaths,
      headerPaths: headerPaths,
      modulemapPaths: modulemapPaths,
      frameworkPaths: frameworkPaths,
      sdkFrameworks: sdkFrameworks,
      sdkDylibs: sdkDylibs,
      outputPath: outputPath!,
    );
  }
}

void _runCompileRunnerCli(List<String> args) {
  final state = _CompileRunnerArgState();
  for (var i = 0; i < args.length; i++) {
    i = state.apply(args, i);
  }

  try {
    compileRunner(state.build());
  } on Object catch (e) {
    stderr.writeln('xtool_pack compile-runner failed: $e');
    exit(1);
  }
}

/// Mutable parse state for `bundle` CLI arguments.
class _BundleArgState {
  String? platform;
  String? appName;
  String? bundleId;
  String? executablePath;
  String minimumOsVersion = '14.0';
  final families = <String>[];
  String? versionFilePath;
  final infoPlistPaths = <String>[];
  final defines = <String, String>{};
  final frameworkPaths = <String>[];
  final nativeLibPaths = <String>[];
  final resourceSpecs = <String>[];
  final additionalContentSpecs = <String>[];
  String? provisioningProfilePath;
  String? entitlementsPath;
  String? zsignPath;
  String? certificatePath;
  String? certificatePasswordFilePath;
  String? certificatePasswordEnv;
  var isolatedEnv = false;
  final declaredEnvVars = <String>{};
  String? tempDirPath;
  String? outputArchivePath;
  String? outputAppDirPath;

  int apply(List<String> args, int i) {
    final arg = args[i];
    if (arg == '--certificate-password' ||
        arg.startsWith('--certificate-password=')) {
      throw ArgumentError(
        '--certificate-password is not permitted because command-line '
        'arguments are visible in process listings and build logs. '
        'Use --certificate-password-file <path> or '
        '--certificate-password-env <ENV_VAR> instead.',
      );
    }

    String nextVal() {
      if (i + 1 >= args.length) {
        throw ArgumentError('Missing value for $arg.');
      }
      return args[++i];
    }

    if (_applyIdentityFlag(arg, nextVal)) return i;
    if (_applySigningFlag(arg, nextVal)) return i;
    switch (arg) {
      case '--define':
        final kv = nextVal();
        final eq = kv.indexOf('=');
        if (eq == -1) {
          throw ArgumentError('Expected KEY=VALUE for --define, got "$kv".');
        }
        defines[kv.substring(0, eq)] = kv.substring(eq + 1);
      case '--isolated-env':
        isolatedEnv = true;
      case '--declared-env':
        declaredEnvVars.add(nextVal());
      default:
        throw ArgumentError('Unrecognized argument: $arg');
    }
    return i;
  }

  bool _applyIdentityFlag(String arg, String Function() nextVal) {
    switch (arg) {
      case '--platform':
        platform = nextVal();
      case '--app-name':
        appName = nextVal();
      case '--bundle-id':
        bundleId = nextVal();
      case '--executable':
        executablePath = nextVal();
      case '--minimum-os-version':
        minimumOsVersion = nextVal();
      case '--family':
        families.add(nextVal());
      case '--version-file':
        versionFilePath = nextVal();
      case '--info-plist':
        infoPlistPaths.add(nextVal());
      case '--framework':
        frameworkPaths.add(nextVal());
      case '--native-lib':
        nativeLibPaths.add(nextVal());
      case '--resource':
        resourceSpecs.add(nextVal());
      case '--additional-content':
        additionalContentSpecs.add(nextVal());
      default:
        return false;
    }
    return true;
  }

  bool _applySigningFlag(String arg, String Function() nextVal) {
    switch (arg) {
      case '--provisioning-profile':
        provisioningProfilePath = nextVal();
      case '--entitlements':
        entitlementsPath = nextVal();
      case '--zsign':
        zsignPath = nextVal();
      case '--certificate':
        certificatePath = nextVal();
      case '--certificate-password-file':
        certificatePasswordFilePath = nextVal();
      case '--certificate-password-env':
        certificatePasswordEnv = nextVal();
      case '--temp-dir':
        tempDirPath = nextVal();
      case '--output-archive':
        outputArchivePath = nextVal();
      case '--output-app-dir':
        outputAppDirPath = nextVal();
      default:
        return false;
    }
    return true;
  }

  Map<String, String> _buildResolvedEnv() {
    final resolvedEnv = <String, String>{};
    if (isolatedEnv) {
      for (final key in declaredEnvVars) {
        if (key == 'TMPDIR' || key == 'TEST_TMPDIR') continue;
        final val = Platform.environment[key];
        if (val != null) {
          resolvedEnv[key] = val;
        }
      }
      if (certificatePasswordEnv != null &&
          certificatePasswordEnv!.isNotEmpty) {
        resolvedEnv.putIfAbsent(certificatePasswordEnv!, () => '');
      }
      return resolvedEnv;
    }
    for (final entry in Platform.environment.entries) {
      if (ambientHostEnvVars.contains(entry.key) &&
          !declaredEnvVars.contains(entry.key)) {
        continue;
      }
      if (entry.key == 'TMPDIR' || entry.key == 'TEST_TMPDIR') {
        continue;
      }
      resolvedEnv[entry.key] = entry.value;
    }
    if (certificatePasswordEnv == 'TMPDIR' ||
        certificatePasswordEnv == 'TEST_TMPDIR') {
      resolvedEnv[certificatePasswordEnv!] = '';
    }
    return resolvedEnv;
  }

  BundleConfig build() {
    if (platform == null ||
        appName == null ||
        bundleId == null ||
        executablePath == null ||
        (outputArchivePath == null && outputAppDirPath == null)) {
      throw ArgumentError(
        'Required flags: --platform, --app-name, --bundle-id, --executable, '
        'and at least one of --output-archive or --output-app-dir.',
      );
    }
    return BundleConfig(
      platform: platform!,
      appName: appName!,
      bundleId: bundleId!,
      executablePath: executablePath!,
      minimumOsVersion: minimumOsVersion,
      families: families,
      versionFilePath: versionFilePath,
      infoPlistPaths: infoPlistPaths,
      defines: defines,
      frameworkPaths: frameworkPaths,
      nativeLibPaths: nativeLibPaths,
      resourceSpecs: resourceSpecs,
      additionalContentSpecs: additionalContentSpecs,
      provisioningProfilePath: provisioningProfilePath,
      entitlementsPath: entitlementsPath,
      zsignPath: zsignPath,
      certificatePath: certificatePath,
      certificatePasswordFilePath: certificatePasswordFilePath,
      certificatePasswordEnv: certificatePasswordEnv,
      tempDirPath: tempDirPath,
      outputArchivePath: outputArchivePath,
      outputAppDirPath: outputAppDirPath,
      environment: _buildResolvedEnv(),
    );
  }
}

/// Parses `bundle` CLI arguments into a [BundleConfig], throwing [ArgumentError]
/// on invalid or forbidden flags (such as plain-text `--certificate-password`).
BundleConfig parseBundleCliArgs(List<String> args) {
  final state = _BundleArgState();
  for (var i = 0; i < args.length; i++) {
    i = state.apply(args, i);
  }
  return state.build();
}

void main(List<String> args) {
  if (args.isEmpty) {
    _usageError(
      'Missing subcommand (expected "bundle", "compile-runner", or "resolve-version").',
    );
  }

  final subcommand = args.first;
  if (subcommand == 'compile-runner') {
    _runCompileRunnerCli(args.sublist(1));
    return;
  }
  if (subcommand == 'resolve-version') {
    _runResolveVersionCli(args.sublist(1));
    return;
  }
  if (subcommand != 'bundle') {
    _usageError(
      'Unknown subcommand "$subcommand" (expected "bundle", "compile-runner", or "resolve-version").',
    );
  }

  final BundleConfig config;
  try {
    config = parseBundleCliArgs(args.sublist(1));
  } on ArgumentError catch (e) {
    _usageError('${e.message}');
  }

  try {
    assembleBundle(config);
  } on Object catch (e) {
    stderr.writeln('xtool_pack failed: $e');
    exit(1);
  }
}
