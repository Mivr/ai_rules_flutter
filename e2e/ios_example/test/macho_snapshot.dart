/// Reads the pieces of a Mach-O binary the iOS framework tests inspect.
///
/// Shared by the release and profile framework tests: both read an App
/// framework binary built for a physical device and both read the snapshot
/// features gen_snapshot embedded in it. The parser deliberately uses only
/// `dart:typed_data`; `otool` and `nm` are not consulted.
library;

import 'dart:convert';
import 'dart:typed_data';

/// Mach-O `cputype` of arm64.
const cpuArm64 = 0x0100000c;

/// `LC_BUILD_VERSION` platform number of iOS (7 would be the simulator).
const platformIos = 2;

/// Mach-O magic of a little-endian 64-bit binary.
const _magic64 = 0xfeedfacf;

/// `LC_BUILD_VERSION` load command number.
const _lcBuildVersion = 0x32;

/// `LC_SYMTAB` load command number.
const _lcSymtab = 0x2;

/// `LC_DYSYMTAB` load command number.
const _lcDysymtab = 0xb;

/// `LC_DYLD_INFO_ONLY` load command number.
const _lcDyldInfoOnly = 0x80000022;

/// `LC_DYLD_EXPORTS_TRIE` load command number.
const _lcDyldExportsTrie = 0x80000033;

/// What a test learned from one Mach-O binary.
class MachOInfo {
  /// Creates the parsed view of one Mach-O binary.
  const MachOInfo({
    required this.cpuType,
    required this.platform,
    required this.exportNames,
    required this.localSymbolCount,
    required this.stabSymbolCount,
  });

  /// The header `cputype` (arm64 expected).
  final int cpuType;

  /// The `LC_BUILD_VERSION` platform, or null when the command is absent.
  final int? platform;

  /// Exported symbol names: the `LC_SYMTAB` entries in `LC_DYSYMTAB`'s
  /// external-defined range, plus any dyld export trie entries.
  final Set<String> exportNames;

  /// `LC_DYSYMTAB` `nlocalsym`, or null when the command is absent.
  final int? localSymbolCount;

  /// `LC_SYMTAB` entries whose `n_type` has a stab bit (`& 0xe0 != 0`).
  final int stabSymbolCount;
}

/// Parses the Mach-O header and load commands of [bytes].
///
/// Throws a [FormatException] naming the offset when the bytes are truncated
/// or shaped unexpectedly, so a binary the loader would reject fails the
/// caller's test instead of passing it.
MachOInfo parseMachO(Uint8List bytes) {
  final head = _Reader(bytes);
  final magic = head.u32();
  if (magic != _magic64) {
    throw FormatException(
      'expected a 64-bit Mach-O magic 0x${_magic64.toRadixString(16)}, '
      'found 0x${magic.toRadixString(16)}',
    );
  }
  final cpuType = head.u32();
  head.skip(8);
  final ncmds = head.u32();
  head.skip(12);
  int? platform;
  final exportNames = <String>{};
  int? localSymbolCount;
  var stabSymbolCount = 0;
  int? symtabAt;
  int? dysymtabAt;
  for (var i = 0; i < ncmds; i++) {
    final commandAt = head.offset;
    final command = head.u32();
    final cmdsize = head.u32();
    if (cmdsize < 8 || commandAt + cmdsize > bytes.length) {
      throw FormatException(
        'load command $i runs past the file at $commandAt '
        '(cmdsize $cmdsize of ${bytes.length} bytes)',
      );
    }
    switch (command) {
      case _lcBuildVersion:
        platform ??= _buildVersionPlatform(bytes, commandAt);
      case _lcSymtab:
        symtabAt ??= commandAt;
        stabSymbolCount += _symtabStabCount(bytes, commandAt);
      case _lcDysymtab:
        dysymtabAt ??= commandAt;
        localSymbolCount = _dysymtabLocalCount(bytes, commandAt);
      case _lcDyldInfoOnly:
        exportNames.addAll(_infoTrieNames(bytes, commandAt));
      case _lcDyldExportsTrie:
        exportNames.addAll(_exportsTrieNames(bytes, commandAt));
    }
    head.offset = commandAt + cmdsize;
  }
  if (symtabAt != null && dysymtabAt != null) {
    exportNames.addAll(
      _externalDefinedNames(bytes, symtabAt, dysymtabAt),
    );
  }
  return MachOInfo(
    cpuType: cpuType,
    platform: platform,
    exportNames: exportNames,
    localSymbolCount: localSymbolCount,
    stabSymbolCount: stabSymbolCount,
  );
}

/// The VM features string in [bytes], or empty when the binary holds none.
///
/// The VM embeds a space-separated word list that names the target, for
/// example `product no-asan ... arm64 ios no-compressed-pointers` in a
/// release build or `release no-asan ... arm64 ios ...` in a profile build.
/// It is stored glued to a hash with no separator, so this finds the printable
/// run that names an architecture and a target OS rather than assuming the
/// list starts at the file offset where a particular mode puts it.
String snapshotFeatures(Uint8List bytes) {
  final text = latin1.decode(bytes);
  for (final run in RegExp('[ -~]{16,}').allMatches(text)) {
    final raw = run.group(0)!;
    if (!raw.contains('arm64') || !raw.contains('no-asan')) continue;
    final namesTarget =
        raw.contains(' ios ') ||
        raw.contains(' android ') ||
        raw.contains(' macos ');
    if (!namesTarget) continue;
    for (final marker in ['product ', 'no-product ', 'release ']) {
      final at = raw.indexOf(marker);
      if (at < 0) continue;
      final features = raw.substring(at);
      final words = features.split(' ');
      if (words.contains('arm64') &&
          words.contains('no-asan') &&
          words.any(
            (word) => word == 'ios' || word == 'android' || word == 'macos',
          )) {
        return features;
      }
    }
  }
  return '';
}

/// The platform field of the `LC_BUILD_VERSION` at [commandAt].
int _buildVersionPlatform(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)..offset = commandAt + 8;
  return reader.u32();
}

/// How many `LC_SYMTAB` entries at [commandAt] are debugging (stab) entries.
///
/// An `nlist_64` entry is 16 bytes with `n_type` at offset 4; a stab entry
/// has a bit in the `N_STAB` mask 0xe0 set.
int _symtabStabCount(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)..offset = commandAt + 8;
  final symoff = reader.u32();
  final nsyms = reader.u32();
  reader.skip(8);
  if (symoff + nsyms * 16 > bytes.length) {
    throw FormatException(
      'LC_SYMTAB at $commandAt points past the file '
      '(symbols $symoff+$nsyms)',
    );
  }
  var stabs = 0;
  for (var i = 0; i < nsyms; i++) {
    if (bytes[symoff + i * 16 + 4] & 0xe0 != 0) stabs++;
  }
  return stabs;
}

/// The `LC_DYSYMTAB` `nlocalsym` at [commandAt] (`ilocalsym` is skipped).
int _dysymtabLocalCount(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)
    ..offset = commandAt + 8
    ..skip(4);
  return reader.u32();
}

/// Names of the external defined symbols: the `LC_SYMTAB` entries in the
/// `LC_DYSYMTAB` `iextdefsym .. iextdefsym + nextdefsym` range.
///
/// A range past the table is a [FormatException], never a pass.
Set<String> _externalDefinedNames(
  Uint8List bytes,
  int symtabAt,
  int dysymtabAt,
) {
  final symtab = _Reader(bytes)..offset = symtabAt + 8;
  final symoff = symtab.u32();
  final nsyms = symtab.u32();
  final stroff = symtab.u32();
  final strsize = symtab.u32();
  final dysymtab = _Reader(bytes)
    ..offset = dysymtabAt + 8
    ..skip(8);
  final extdef = dysymtab.u32();
  final ndef = dysymtab.u32();
  if (symoff + nsyms * 16 > bytes.length || stroff + strsize > bytes.length) {
    throw FormatException(
      'LC_SYMTAB at $symtabAt points past the file '
      '(symbols $symoff+$nsyms, strings $stroff+$strsize)',
    );
  }
  if (extdef + ndef > nsyms) {
    throw FormatException(
      'LC_DYSYMTAB external range $extdef+$ndef runs past the $nsyms-entry '
      'LC_SYMTAB at $symtabAt',
    );
  }
  final names = <String>{};
  for (var i = extdef; i < extdef + ndef; i++) {
    final strx = _u32At(bytes, symoff + i * 16);
    names.add(_tableString(bytes, stroff, strsize, strx));
  }
  return names;
}

/// Reads one little-endian u32 at [offset], failing past the end.
int _u32At(Uint8List bytes, int offset) {
  if (offset < 0 || offset + 4 > bytes.length) {
    throw FormatException('u32 at $offset runs past ${bytes.length} bytes');
  }
  return ByteData.sublistView(
    bytes,
    offset,
    offset + 4,
  ).getUint32(0, Endian.little);
}

/// Reads the NUL-terminated string at [tableAt] + [index].
String _tableString(Uint8List bytes, int tableAt, int tableSize, int index) {
  if (index < 0 || tableAt + index >= tableAt + tableSize) {
    throw FormatException(
      'string index $index runs past the $tableSize-byte table at $tableAt',
    );
  }
  var end = tableAt + index;
  while (end < tableAt + tableSize && bytes[end] != 0) {
    end++;
  }
  return utf8.decode(bytes.sublist(tableAt + index, end), allowMalformed: true);
}

/// Export names from the `LC_DYLD_INFO_ONLY` export trie at [commandAt].
Set<String> _infoTrieNames(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)
    ..offset = commandAt + 8
    ..skip(32);
  final dataoff = reader.u32();
  final datasize = reader.u32();
  return _Trie(bytes, dataoff, datasize).names();
}

/// Export names from the `LC_DYLD_EXPORTS_TRIE` at [commandAt].
Set<String> _exportsTrieNames(Uint8List bytes, int commandAt) {
  final reader = _Reader(bytes)..offset = commandAt + 8;
  final dataoff = reader.u32();
  final datasize = reader.u32();
  return _Trie(bytes, dataoff, datasize).names();
}

/// A dyld export trie: child offsets count from the trie's own start.
class _Trie {
  _Trie(this.bytes, this.start, this.size) {
    if (start < 0 || size < 0 || start + size > bytes.length) {
      throw FormatException(
        'export trie at $start runs past the file '
        '(size $size of ${bytes.length} bytes)',
      );
    }
  }

  final Uint8List bytes;
  final int start;
  final int size;

  /// Every exported name in the trie.
  Set<String> names() {
    final out = <String>{};
    _walk(start, '', out);
    return out;
  }

  /// Collects the names under the node at [node], prefixed by [prefix].
  void _walk(int node, String prefix, Set<String> out) {
    if (node < start || node >= start + size) {
      throw FormatException(
        'export trie node at $node runs past the trie at $start '
        '(size $size)',
      );
    }
    final reader = _Reader(bytes)..offset = node;
    final terminalSize = reader.uleb();
    final terminalEnd = reader.offset + terminalSize;
    if (terminalEnd > start + size) {
      throw FormatException(
        'export trie terminal at $node runs past the trie end',
      );
    }
    if (terminalSize > 0) {
      reader.uleb();
      out.add(prefix);
      reader.offset = terminalEnd;
    }
    final children = reader.u8();
    for (var i = 0; i < children; i++) {
      final edge = reader.cstring();
      final child = reader.uleb();
      _walk(start + child, prefix + edge, out);
    }
  }
}

/// A bounds-checked cursor over Mach-O bytes.
class _Reader {
  _Reader(this.bytes);

  final Uint8List bytes;
  int offset = 0;

  /// Skips [count] bytes.
  void skip(int count) {
    _need(count);
    offset += count;
  }

  /// Reads one byte.
  int u8() {
    _need(1);
    return bytes[offset++];
  }

  /// Reads one little-endian u32.
  int u32() {
    _need(4);
    final value = ByteData.sublistView(
      bytes,
      offset,
      offset + 4,
    ).getUint32(0, Endian.little);
    offset += 4;
    return value;
  }

  /// Reads one uleb128 value.
  int uleb() {
    var result = 0;
    var shift = 0;
    while (true) {
      final byte = u8();
      result |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) return result;
      shift += 7;
      if (shift >= 64) {
        throw FormatException('uleb128 overflows at ${offset - 1}');
      }
    }
  }

  /// Reads one NUL-terminated string.
  String cstring() {
    final start = offset;
    while (true) {
      _need(1);
      if (bytes[offset++] == 0) break;
    }
    return utf8.decode(bytes.sublist(start, offset - 1), allowMalformed: true);
  }

  /// Throws a [FormatException] unless [count] bytes are readable.
  void _need(int count) {
    if (offset < 0 || offset + count > bytes.length) {
      throw FormatException(
        'truncated Mach-O at $offset (needs $count of ${bytes.length})',
      );
    }
  }
}
