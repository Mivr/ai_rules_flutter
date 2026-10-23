/// Huffman bit I/O and block encoding for the raw-deflate compressor.
///
/// A line-by-line port of the non-debug paths of zlib 1.3.2 `trees.c`:
/// `send_bits`, `bi_flush`, `bi_windup`, `gen_codes`, `pqdownheap`,
/// `gen_bitlen`, `build_tree`, `scan_tree`, `send_tree`, `build_bl_tree`,
/// `send_all_trees`, `compress_block`, `_tr_stored_block`, and
/// `_tr_flush_block`, plus the `_tr_tally` symbol writers. Trace output,
/// `ZLIB_DEBUG` accounting (`compressed_len`, `bits_sent`), and data-type
/// detection (whose result never affects the output bytes) are omitted.
library;

import 'zlib_raw_state.dart';
import 'zlib_raw_tables.dart';

/// End-of-block literal code (`END_BLOCK`).
const int zlibEndBlock = 256;

/// Repeat-previous-length code (`REP_3_6`).
const int zlibRep36 = 16;

/// Repeat-zero code, short form (`REPZ_3_10`).
const int zlibRepz310 = 17;

/// Repeat-zero code, long form (`REPZ_11_138`).
const int zlibRepz11138 = 18;

/// Stored block type (`STORED_BLOCK`).
const int zlibStoredBlock = 0;

/// Static-trees block type (`STATIC_TREES`).
const int zlibStaticTrees = 1;

/// Dynamic-trees block type (`DYN_TREES`).
const int zlibDynamicTrees = 2;

/// Maximum bits of any literal/distance code (`MAX_BITS`).
const int zlibMaxBits = 15;

/// Maximum bits of a bit-length code (`MAX_BL_BITS`).
const int zlibMaxBlBits = 7;

/// Literal/length code count (`L_CODES`).
const int zlibLCodes = 286;

/// Distance code count (`D_CODES`).
const int zlibDCodes = 30;

/// Bit-length code count (`BL_CODES`).
const int zlibBlCodes = 19;

/// Heap capacity (`HEAP_SIZE`).
const int zlibHeapSize = 573;

/// Static literal-tree code lengths, indexed by code.
final List<int> _staticLLens = List<int>.generate(
  zlibLCodes,
  (i) => zlibStaticLtree[i].$2,
);

/// Static distance-tree code lengths, indexed by code.
final List<int> _staticDLens = List<int>.generate(
  zlibDCodes,
  (i) => zlibStaticDtree[i].$2,
);

/// Static literal-tree codes, indexed by code.
final List<int> _staticLCodes = List<int>.generate(
  zlibLCodes,
  (i) => zlibStaticLtree[i].$1,
);

/// Static distance-tree codes, indexed by code.
final List<int> _staticDCodes = List<int>.generate(
  zlibDCodes,
  (i) => zlibStaticDtree[i].$1,
);

/// Maps a match distance minus one to a distance code (`d_code`).
int zlibDCode(int dist) =>
    dist < 256 ? zlibDistCode[dist] : zlibDistCode[256 + (dist >> 7)];

/// Reverses the first [len] bits of [code] (`bi_reverse`).
int zlibBiReverse(int code, int len) {
  var res = 0;
  do {
    res |= code & 1;
    code >>= 1;
    res <<= 1;
  } while (--len > 0);
  return res >> 1;
}

/// Appends one byte to the pending output (`put_byte`).
void zlibPutByte(ZlibRawState s, int byte) {
  s.pending.add(byte & 0xff);
}

/// Appends a little-endian 16-bit value (`put_short`).
void zlibPutShort(ZlibRawState s, int value) {
  zlibPutByte(s, value & 0xff);
  zlibPutByte(s, (value >> 8) & 0xff);
}

/// Sends [value] on [length] bits, LSB first (`send_bits`).
///
/// The `(ush)` casts of the C macro are replicated with `& 0xffff` masks;
/// the transient high bits of `bi_buf` are discarded by `put_short` before
/// any read, exactly as in C.
void zlibSendBits(ZlibRawState s, int value, int length) {
  if (s.biValid > 16 - length) {
    final int val = value;
    s.biBuf = (s.biBuf | (((val & 0xffff) << s.biValid))) & 0xffff;
    zlibPutShort(s, s.biBuf);
    s.biBuf = (val & 0xffff) >> (16 - s.biValid);
    s.biValid += length - 16;
  } else {
    s.biBuf = (s.biBuf | ((value & 0xffff) << s.biValid)) & 0xffff;
    s.biValid += length;
  }
}

/// Sends one code of [tree] (`send_code` without `ZLIB_DEBUG`).
void zlibSendCode(ZlibRawState s, int c, List<int> codes, List<int> lens) {
  zlibSendBits(s, codes[c], lens[c]);
}

/// Flushes the bit buffer, keeping at most 7 bits (`bi_flush`).
void zlibBiFlush(ZlibRawState s) {
  if (s.biValid == 16) {
    zlibPutShort(s, s.biBuf);
    s.biBuf = 0;
    s.biValid = 0;
  } else if (s.biValid >= 8) {
    zlibPutByte(s, s.biBuf);
    s.biBuf >>= 8;
    s.biValid -= 8;
  }
}

/// Aligns the output on a byte boundary (`bi_windup`).
void zlibBiWindup(ZlibRawState s) {
  if (s.biValid > 8) {
    zlibPutShort(s, s.biBuf);
  } else if (s.biValid > 0) {
    zlibPutByte(s, s.biBuf);
  }
  s.biUsed = ((s.biValid - 1) & 7) + 1;
  s.biBuf = 0;
  s.biValid = 0;
}

/// Generates the codes for a tree with known bit lengths (`gen_codes`).
void zlibGenCodes(ZlibRawTree tree, int maxCode, List<int> blCount) {
  final List<int> nextCode = List<int>.filled(zlibMaxBits + 1, 0);
  var code = 0;
  for (var bits = 1; bits <= zlibMaxBits; bits++) {
    code = (code + blCount[bits - 1]) << 1;
    nextCode[bits] = code & 0xffff;
  }
  for (var n = 0; n <= maxCode; n++) {
    final int len = tree.len[n];
    if (len == 0) continue;
    tree.code[n] = zlibBiReverse(nextCode[len]++, len);
  }
}

/// Heap ordering with depth as the tie breaker (`smaller`).
bool zlibSmaller(ZlibRawTree tree, List<int> depth, int n, int m) =>
    tree.freq[n] < tree.freq[m] ||
    (tree.freq[n] == tree.freq[m] && depth[n] <= depth[m]);

/// Restores the heap property below node [k] (`pqdownheap`).
void zlibPqdownheap(ZlibRawState s, ZlibRawTree tree, int k) {
  final int v = s.heap[k];
  var j = k << 1;
  while (j <= s.heapLen) {
    if (j < s.heapLen && zlibSmaller(tree, s.depth, s.heap[j + 1], s.heap[j])) {
      j++;
    }
    if (zlibSmaller(tree, s.depth, v, s.heap[j])) break;
    s.heap[k] = s.heap[j];
    k = j;
    j <<= 1;
  }
  s.heap[k] = v;
}

/// Computes optimal bit lengths and updates the block totals (`gen_bitlen`).
///
/// [staticLens] holds the corresponding static-tree lengths, or is null for
/// the bit-length tree (whose `stat_desc.static_tree` is null).
void zlibGenBitlen(
  ZlibRawState s,
  ZlibRawTree tree,
  List<int>? staticLens,
  List<int> extra,
  int extraBase,
  int maxLength,
) {
  final int maxCode = tree.maxCode;
  for (var bits = 0; bits <= zlibMaxBits; bits++) {
    s.blCount[bits] = 0;
  }
  tree.len[s.heap[s.heapMax]] = 0;
  var overflow = 0;
  for (var h = s.heapMax + 1; h < zlibHeapSize; h++) {
    final int n = s.heap[h];
    var bits = tree.len[tree.dad[n]] + 1;
    if (bits > maxLength) {
      bits = maxLength;
      overflow++;
    }
    tree.len[n] = bits;
    if (n > maxCode) continue;
    s.blCount[bits]++;
    var xbits = 0;
    if (n >= extraBase) xbits = extra[n - extraBase];
    final int f = tree.freq[n];
    s.optLen += f * (bits + xbits);
    if (staticLens != null) {
      s.staticLen += f * (staticLens[n] + xbits);
    }
  }
  if (overflow == 0) return;
  var bits = 0;
  do {
    bits = maxLength - 1;
    while (s.blCount[bits] == 0) {
      bits--;
    }
    s.blCount[bits]--;
    s.blCount[bits + 1] += 2;
    s.blCount[maxLength]--;
    overflow -= 2;
  } while (overflow > 0);
  var h = zlibHeapSize;
  for (bits = maxLength; bits != 0; bits--) {
    var n = s.blCount[bits];
    while (n != 0) {
      final int m = s.heap[--h];
      if (m > maxCode) continue;
      if (tree.len[m] != bits) {
        s.optLen += (bits - tree.len[m]) * tree.freq[m];
        tree.len[m] = bits;
      }
      n--;
    }
  }
}

/// Builds one Huffman tree and its codes (`build_tree`).
void zlibBuildTree(
  ZlibRawState s,
  ZlibRawTree tree,
  List<int>? staticLens,
  List<int> extra,
  int extraBase,
  int elems,
  int maxLength,
) {
  s.heapLen = 0;
  s.heapMax = zlibHeapSize;
  var maxCode = -1;
  for (var n = 0; n < elems; n++) {
    if (tree.freq[n] != 0) {
      s.heap[++s.heapLen] = n;
      maxCode = n;
      s.depth[n] = 0;
    } else {
      tree.len[n] = 0;
    }
  }
  while (s.heapLen < 2) {
    final int node;
    if (maxCode < 2) {
      maxCode++;
      node = maxCode;
    } else {
      node = 0;
    }
    s.heap[++s.heapLen] = node;
    tree.freq[node] = 1;
    s.depth[node] = 0;
    s.optLen--;
    if (staticLens != null) s.staticLen -= staticLens[node];
  }
  tree.maxCode = maxCode;
  for (var n = s.heapLen ~/ 2; n >= 1; n--) {
    zlibPqdownheap(s, tree, n);
  }
  var node = elems;
  int n, m;
  do {
    n = s.heap[1];
    s.heap[1] = s.heap[s.heapLen--];
    zlibPqdownheap(s, tree, 1);
    m = s.heap[1];
    s.heap[--s.heapMax] = n;
    s.heap[--s.heapMax] = m;
    tree.freq[node] = tree.freq[n] + tree.freq[m];
    s.depth[node] = (s.depth[n] >= s.depth[m] ? s.depth[n] : s.depth[m]) + 1;
    tree.dad[n] = node;
    tree.dad[m] = node;
    s.heap[1] = node++;
    zlibPqdownheap(s, tree, 1);
  } while (s.heapLen >= 2);
  s.heap[--s.heapMax] = s.heap[1];
  zlibGenBitlen(s, tree, staticLens, extra, extraBase, maxLength);
  zlibGenCodes(tree, maxCode, s.blCount);
}

/// Tallies bit-length frequencies for one tree (`scan_tree`).
void zlibScanTree(ZlibRawState s, ZlibRawTree tree, int maxCode) {
  var prevlen = -1;
  var curlen = 0;
  var nextlen = tree.len[0];
  var count = 0;
  var maxCount = 7;
  var minCount = 4;
  if (nextlen == 0) {
    maxCount = 138;
    minCount = 3;
  }
  tree.len[maxCode + 1] = 0xffff;
  for (var n = 0; n <= maxCode; n++) {
    curlen = nextlen;
    nextlen = tree.len[n + 1];
    if (++count < maxCount && curlen == nextlen) {
      continue;
    } else if (count < minCount) {
      s.blTree.freq[curlen] += count;
    } else if (curlen != 0) {
      if (curlen != prevlen) s.blTree.freq[curlen]++;
      s.blTree.freq[zlibRep36]++;
    } else if (count <= 10) {
      s.blTree.freq[zlibRepz310]++;
    } else {
      s.blTree.freq[zlibRepz11138]++;
    }
    count = 0;
    prevlen = curlen;
    if (nextlen == 0) {
      maxCount = 138;
      minCount = 3;
    } else if (curlen == nextlen) {
      maxCount = 6;
      minCount = 3;
    } else {
      maxCount = 7;
      minCount = 4;
    }
  }
}

/// Sends one tree in compressed form (`send_tree`).
void zlibSendTree(ZlibRawState s, ZlibRawTree tree, int maxCode) {
  var prevlen = -1;
  var curlen = 0;
  var nextlen = tree.len[0];
  var count = 0;
  var maxCount = 7;
  var minCount = 4;
  if (nextlen == 0) {
    maxCount = 138;
    minCount = 3;
  }
  for (var n = 0; n <= maxCode; n++) {
    curlen = nextlen;
    nextlen = tree.len[n + 1];
    if (++count < maxCount && curlen == nextlen) {
      continue;
    } else if (count < minCount) {
      do {
        zlibSendCode(s, curlen, s.blTree.code, s.blTree.len);
      } while (--count != 0);
    } else if (curlen != 0) {
      if (curlen != prevlen) {
        zlibSendCode(s, curlen, s.blTree.code, s.blTree.len);
        count--;
      }
      zlibSendCode(s, zlibRep36, s.blTree.code, s.blTree.len);
      zlibSendBits(s, count - 3, 2);
    } else if (count <= 10) {
      zlibSendCode(s, zlibRepz310, s.blTree.code, s.blTree.len);
      zlibSendBits(s, count - 3, 3);
    } else {
      zlibSendCode(s, zlibRepz11138, s.blTree.code, s.blTree.len);
      zlibSendBits(s, count - 11, 7);
    }
    count = 0;
    prevlen = curlen;
    if (nextlen == 0) {
      maxCount = 138;
      minCount = 3;
    } else if (curlen == nextlen) {
      maxCount = 6;
      minCount = 3;
    } else {
      maxCount = 7;
      minCount = 4;
    }
  }
}

/// Builds the bit-length tree, returning the last send index (`build_bl_tree`).
int zlibBuildBlTree(ZlibRawState s) {
  zlibScanTree(s, s.dynLtree, s.dynLtree.maxCode);
  zlibScanTree(s, s.dynDtree, s.dynDtree.maxCode);
  zlibBuildTree(
    s,
    s.blTree,
    null,
    zlibExtraBlbits,
    0,
    zlibBlCodes,
    zlibMaxBlBits,
  );
  var maxBlindex = zlibBlCodes - 1;
  while (maxBlindex >= 3) {
    if (s.blTree.len[zlibBlOrder[maxBlindex]] != 0) break;
    maxBlindex--;
  }
  s.optLen += 3 * (maxBlindex + 1) + 5 + 5 + 4;
  return maxBlindex;
}

/// Sends the dynamic-block header (`send_all_trees`).
void zlibSendAllTrees(ZlibRawState s, int lcodes, int dcodes, int blcodes) {
  zlibSendBits(s, lcodes - 257, 5);
  zlibSendBits(s, dcodes - 1, 5);
  zlibSendBits(s, blcodes - 4, 4);
  for (var rank = 0; rank < blcodes; rank++) {
    zlibSendBits(s, s.blTree.len[zlibBlOrder[rank]], 3);
  }
  zlibSendTree(s, s.dynLtree, lcodes - 1);
  zlibSendTree(s, s.dynDtree, dcodes - 1);
}

/// Sends the block symbols with the given trees (`compress_block`).
void zlibCompressBlock(
  ZlibRawState s,
  List<int> lCodes,
  List<int> lLens,
  List<int> dCodes,
  List<int> dLens,
) {
  var sx = 0;
  if (s.symNext != 0) {
    do {
      var dist = s.symBuf[sx++] & 0xff;
      dist += (s.symBuf[sx++] & 0xff) << 8;
      final int lc = s.symBuf[sx++] & 0xff;
      if (dist == 0) {
        zlibSendCode(s, lc, lCodes, lLens);
      } else {
        var code = zlibLengthCode[lc];
        zlibSendCode(s, code + 257, lCodes, lLens);
        final int extra = zlibExtraLbits[code];
        if (extra != 0) {
          zlibSendBits(s, lc - zlibBaseLength[code], extra);
        }
        dist--;
        code = zlibDCode(dist);
        zlibSendCode(s, code, dCodes, dLens);
        final int dextra = zlibExtraDbits[code];
        if (dextra != 0) {
          zlibSendBits(s, dist - zlibBaseDist[code], dextra);
        }
      }
    } while (sx < s.symNext);
  }
  zlibSendCode(s, zlibEndBlock, lCodes, lLens);
}

/// Writes one stored block (`_tr_stored_block`).
void zlibTrStoredBlock(ZlibRawState s, int bufStart, int storedLen, int last) {
  zlibSendBits(s, (zlibStoredBlock << 1) + last, 3);
  zlibBiWindup(s);
  zlibPutShort(s, storedLen);
  zlibPutShort(s, ~storedLen);
  for (var i = 0; i < storedLen; i++) {
    s.pending.add(s.window[bufStart + i]);
  }
}

/// Picks the best encoding for the block and writes it (`_tr_flush_block`).
///
/// `bufStart` is the window index of the block data, or negative when the
/// window slid and no stored block is possible (`buf == NULL`). Data-type
/// detection is omitted: its result is only reported, never encoded.
void zlibTrFlushBlock(ZlibRawState s, int bufStart, int storedLen, int last) {
  zlibBuildTree(
    s,
    s.dynLtree,
    _staticLLens,
    zlibExtraLbits,
    257,
    zlibLCodes,
    zlibMaxBits,
  );
  zlibBuildTree(
    s,
    s.dynDtree,
    _staticDLens,
    zlibExtraDbits,
    0,
    zlibDCodes,
    zlibMaxBits,
  );
  final int maxBlindex = zlibBuildBlTree(s);
  final int staticLenb = (s.staticLen + 3 + 7) >> 3;
  var optLenb = (s.optLen + 3 + 7) >> 3;
  if (staticLenb <= optLenb) optLenb = staticLenb;
  if (storedLen + 4 <= optLenb && bufStart >= 0) {
    zlibTrStoredBlock(s, bufStart, storedLen, last);
  } else if (staticLenb == optLenb) {
    zlibSendBits(s, (zlibStaticTrees << 1) + last, 3);
    zlibCompressBlock(
      s,
      _staticLCodes,
      _staticLLens,
      _staticDCodes,
      _staticDLens,
    );
  } else {
    zlibSendBits(s, (zlibDynamicTrees << 1) + last, 3);
    zlibSendAllTrees(
      s,
      s.dynLtree.maxCode + 1,
      s.dynDtree.maxCode + 1,
      maxBlindex + 1,
    );
    zlibCompressBlock(
      s,
      s.dynLtree.code,
      s.dynLtree.len,
      s.dynDtree.code,
      s.dynDtree.len,
    );
  }
  zlibInitBlock(s);
  if (last != 0) zlibBiWindup(s);
}

/// Tallies one literal, returning whether the block is full (`_tr_tally_lit`).
bool zlibTallyLit(ZlibRawState s, int c) {
  s.symBuf[s.symNext++] = 0;
  s.symBuf[s.symNext++] = 0;
  s.symBuf[s.symNext++] = c;
  s.dynLtree.freq[c]++;
  return s.symNext == zlibSymEnd;
}

/// Tallies one match, returning whether the block is full (`_tr_tally_dist`).
///
/// [distance] is the match distance and [length] the match length minus
/// `MIN_MATCH`, matching the `_tr_tally_dist` macro arguments.
bool zlibTallyDist(ZlibRawState s, int distance, int length) {
  s.symBuf[s.symNext++] = distance & 0xff;
  s.symBuf[s.symNext++] = (distance >> 8) & 0xff;
  s.symBuf[s.symNext++] = length & 0xff;
  s.matches++;
  final int dist = distance - 1;
  s.dynLtree.freq[zlibLengthCode[length] + 257]++;
  s.dynDtree.freq[zlibDCode(dist)]++;
  return s.symNext == zlibSymEnd;
}
