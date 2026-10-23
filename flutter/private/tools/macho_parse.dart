/// Mach-O load-command parsing.
///
/// Raw [LoadCommand] decoding, the [Segment64Spec] load-command shape, and
/// the payload-floor walk used to find free space for rewritten commands.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'macho_constants.dart';
import 'macho_fat.dart' show isMachO32, isMachO64;

/// Represents a single raw Mach-O load command.
class LoadCommand {
  final int cmd;
  final Uint8List bytes;

  LoadCommand(this.cmd, this.bytes);

  int get cmdsize => bytes.length;
}

/// The fields of a 72-byte `LC_SEGMENT_64` load command with 0 sections.
/// Shared by [buildLcSegment64] and xtool_pack's stub synthesizer so a segment
/// command is described once.
typedef Segment64Spec = ({
  String segname,
  int vmaddr,
  int vmsize,
  int fileoff,
  int filesize,
  int maxprot,
  int initprot,
  int nsects,
  int flags,
});

/// Builds a 72-byte `LC_SEGMENT_64` load command with 0 sections.
LoadCommand buildLcSegment64(Segment64Spec spec) {
  final buf = Uint8List(72);
  final bd = ByteData.sublistView(buf);
  bd.setUint32(0, lcSegment64, Endian.little);
  bd.setUint32(4, 72, Endian.little);
  final nameBytes = ascii.encode(spec.segname);
  buf.setRange(8, 8 + math.min<int>(16, nameBytes.length), nameBytes);
  bd.setUint64(24, spec.vmaddr, Endian.little);
  bd.setUint64(32, spec.vmsize, Endian.little);
  bd.setUint64(40, spec.fileoff, Endian.little);
  bd.setUint64(48, spec.filesize, Endian.little);
  bd.setUint32(56, spec.maxprot, Endian.little);
  bd.setUint32(60, spec.initprot, Endian.little);
  bd.setUint32(64, spec.nsects, Endian.little);
  bd.setUint32(68, spec.flags, Endian.little);
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

/// Tracks the lowest referenced file offset seen so far.
class _PayloadFloor {
  int value;

  _PayloadFloor(this.value);

  void consider(int offset, int size) {
    if (offset > 0 && size > 0 && offset < value) {
      value = offset;
    }
  }
}

/// Folds one load command's referenced file range into [floor].
void _considerCommandPayload(LoadCommand lc, _PayloadFloor floor) {
  final bd = ByteData.sublistView(lc.bytes);
  switch (lc.cmd) {
    case lcSegment64:
      _considerSegmentPayload(lc, bd, floor);
    case lcSymtab:
      if (lc.bytes.length >= 24) {
        floor.consider(
          bd.getUint32(8, Endian.little),
          bd.getUint32(12, Endian.little) * 16,
        );
        floor.consider(
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
        floor.consider(
          bd.getUint32(8, Endian.little),
          bd.getUint32(12, Endian.little),
        );
      }
  }
}

/// Folds a `LC_SEGMENT_64` command's file range and its sections into [floor].
void _considerSegmentPayload(
  LoadCommand lc,
  ByteData bd,
  _PayloadFloor floor,
) {
  if (lc.bytes.length < 72) return;
  final fileoff = bd.getUint64(40, Endian.little);
  final filesize = bd.getUint64(48, Endian.little);
  final nsects = bd.getUint32(64, Endian.little);
  if (fileoff > 0 && filesize > 0) {
    floor.consider(fileoff, filesize);
  }
  // Inspect each section_64 (80 bytes each starting at offset 72).
  for (var s = 0; s < nsects; s++) {
    final sectOff = 72 + s * 80;
    if (sectOff + 80 <= lc.bytes.length) {
      final sSize = bd.getUint64(sectOff + 40, Endian.little);
      final sOffset = bd.getUint32(sectOff + 48, Endian.little);
      floor.consider(sOffset, sSize);
    }
  }
}

/// Finds the lowest non-zero file offset referenced by any segment, section,
/// or linkedit table in the Mach-O binary. Load commands may grow up to this
/// boundary without overwriting section/segment payload bytes.
int findFirstPayloadOffset(List<LoadCommand> commands, int totalLength) {
  final floor = _PayloadFloor(totalLength);
  for (final lc in commands) {
    _considerCommandPayload(lc, floor);
  }
  return floor.value;
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
