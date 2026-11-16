import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Safety limits for untrusted archives. See docs/verify-contract.md.
class ArchiveLimits {
  const ArchiveLimits({
    this.maxArchiveBytes = 2 * 1024 * 1024 * 1024,
    this.maxEntries = 65534,
    this.maxEntryNameBytes = 1024,
    this.maxReadBytes = 128 * 1024 * 1024,
    this.maxSmallReadBytes = 8 * 1024 * 1024,
    this.maxRatio = 1100,
    this.timeout = const Duration(seconds: 30),
  });

  /// Archive file size (the archive itself is never fully loaded).
  final int maxArchiveBytes;

  /// Central-directory entries.
  final int maxEntries;
  final int maxEntryNameBytes;

  /// Largest decompressed size of any single entry that is read (resources.arsc).
  final int maxReadBytes;

  /// Largest decompressed size for XML / plist entries.
  final int maxSmallReadBytes;

  /// Decompressed/compressed ratio allowed for a read entry (deflate's own maximum is ~1032).
  final int maxRatio;

  /// Wall-clock budget for one verify run.
  final Duration timeout;
}

/// The archive cannot be analyzed safely or at all (maps to exit code 2).
class ArchiveException implements Exception {
  ArchiveException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ZipEntry {
  ZipEntry(this.name, this.method, this.flags, this.compressedSize, this.size, this.localOffset, this.crc);
  final String name;
  final int method;
  final int flags;
  final int compressedSize;
  final int size;
  final int localOffset;
  final int crc;
  bool get isDirectory => name.endsWith('/');
}

/// Read-only random-access ZIP reader. Only the central directory is parsed up
/// front; entry data is inflated on demand into memory under hard size caps.
/// Nothing is written to disk and no archive content is executed.
class ZipReader {
  ZipReader._(this._raf, this.length, this.entries, this.limits, this._clock);

  final RandomAccessFile _raf;
  final int length;
  final Map<String, ZipEntry> entries;
  final ArchiveLimits limits;
  final Stopwatch _clock;

  static ZipReader open(String path, {ArchiveLimits limits = const ArchiveLimits()}) {
    final clock = Stopwatch()..start();
    final f = File(path);
    if (!f.existsSync()) throw ArchiveException('file not found: $path');
    final len = f.lengthSync();
    if (len > limits.maxArchiveBytes) {
      throw ArchiveException('archive is $len bytes, larger than the limit of ${limits.maxArchiveBytes}');
    }
    if (len < 22) throw ArchiveException('not a ZIP archive (too small)');
    final raf = f.openSync();
    try {
      final r = ZipReader._(raf, len, {}, limits, clock);
      r._parseCentralDirectory();
      return r;
    } catch (_) {
      raf.closeSync();
      rethrow;
    }
  }

  void close() => _raf.closeSync();

  void _checkTime() {
    if (_clock.elapsed > limits.timeout) {
      throw ArchiveException('timeout: analysis exceeded ${limits.timeout.inSeconds}s');
    }
  }

  Uint8List _readAt(int off, int n) {
    _raf.setPositionSync(off);
    final b = _raf.readSync(n);
    if (b.length != n) throw ArchiveException('truncated archive');
    return b;
  }

  static int _u16(Uint8List b, int o) => b[o] | (b[o + 1] << 8);
  static int _u32(Uint8List b, int o) => b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24);

  void _parseCentralDirectory() {
    // End of central directory: search the last 64 KiB + 22 bytes.
    final tail = length < 65557 ? length : 65557;
    final buf = _readAt(length - tail, tail);
    var eocd = -1;
    for (var i = tail - 22; i >= 0; i--) {
      if (buf[i] == 0x50 && buf[i + 1] == 0x4b && buf[i + 2] == 5 && buf[i + 3] == 6) {
        eocd = i;
        break;
      }
    }
    if (eocd < 0) throw ArchiveException('not a ZIP archive (end of central directory not found)');
    final disk = _u16(buf, eocd + 4);
    final total = _u16(buf, eocd + 10);
    final cdSize = _u32(buf, eocd + 12);
    final cdOff = _u32(buf, eocd + 16);
    if (disk != 0 || _u16(buf, eocd + 6) != 0) throw ArchiveException('multi-disk ZIP archives are not supported');
    if (total == 0xffff || cdSize == 0xffffffff || cdOff == 0xffffffff) {
      throw ArchiveException('ZIP64 archives are not supported');
    }
    if (total > limits.maxEntries) {
      throw ArchiveException('archive has $total entries, more than the limit of ${limits.maxEntries}');
    }
    if (cdOff + cdSize > length) throw ArchiveException('corrupt ZIP: central directory out of range');
    final cd = _readAt(cdOff, cdSize);
    var p = 0;
    for (var i = 0; i < total; i++) {
      if (i % 1024 == 0) _checkTime();
      if (p + 46 > cd.length || _u32(cd, p) != 0x02014b50) throw ArchiveException('corrupt ZIP: bad central directory entry');
      final flags = _u16(cd, p + 8);
      final method = _u16(cd, p + 10);
      final crc = _u32(cd, p + 16);
      final csize = _u32(cd, p + 20);
      final usize = _u32(cd, p + 24);
      final nlen = _u16(cd, p + 28);
      final elen = _u16(cd, p + 30);
      final clen = _u16(cd, p + 32);
      final loff = _u32(cd, p + 42);
      if (nlen > limits.maxEntryNameBytes) throw ArchiveException('entry name longer than ${limits.maxEntryNameBytes} bytes');
      if (p + 46 + nlen + elen + clen > cd.length) throw ArchiveException('corrupt ZIP: entry overruns central directory');
      final raw = cd.sublist(p + 46, p + 46 + nlen);
      String name;
      try {
        name = utf8.decode(raw);
      } on FormatException {
        name = latin1.decode(raw);
      }
      _validateName(name);
      if (flags & 1 != 0) throw ArchiveException('encrypted archives are not supported (entry "$name")');
      if (entries.containsKey(name)) throw ArchiveException('duplicate entry path "$name" (ambiguous archive)');
      if (csize == 0xffffffff || usize == 0xffffffff || loff == 0xffffffff) throw ArchiveException('ZIP64 entries are not supported');
      entries[name] = ZipEntry(name, method, flags, csize, usize, loff, crc);
      p += 46 + nlen + elen + clen;
    }
  }

  static void _validateName(String n) {
    if (n.isEmpty) throw ArchiveException('empty entry path');
    if (n.contains('\u0000')) throw ArchiveException('entry path contains NUL');
    if (n.contains('\\')) throw ArchiveException('entry path contains a backslash: "$n"');
    if (n.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(n)) throw ArchiveException('absolute entry path: "$n"');
    final segs = n.endsWith('/') ? n.substring(0, n.length - 1).split('/') : n.split('/');
    if (segs.any((s) => s == '..')) throw ArchiveException('path traversal in entry path: "$n"');
    // "a//b" and "./a" would collide with "a/b" / "a" after normalization (ambiguous archive).
    if (segs.any((s) => s.isEmpty || s == '.')) throw ArchiveException('non-canonical entry path: "$n"');
  }

  /// Decompresses [name] into memory. Throws [ArchiveException] for limit
  /// violations, unsupported methods and corruption. Returns null if absent.
  Uint8List? read(String name, {int? maxBytes}) {
    final e = entries[name];
    if (e == null) return null;
    final cap = maxBytes ?? limits.maxSmallReadBytes;
    _checkTime();
    if (e.size > cap) throw ArchiveException('entry "$name" is ${e.size} bytes uncompressed, larger than the limit of $cap');
    if (e.compressedSize > 0 && e.size / e.compressedSize > limits.maxRatio) {
      throw ArchiveException('entry "$name" has an implausible compression ratio (possible ZIP bomb)');
    }
    final lh = _readAt(e.localOffset, 30);
    if (_u32(lh, 0) != 0x04034b50) throw ArchiveException('corrupt ZIP: bad local header for "$name"');
    final lnLen = _u16(lh, 26);
    if (_u16(lh, 6) & 1 != 0) throw ArchiveException('encrypted archives are not supported (entry "$name")');
    if (!_sameBytes(_readAt(e.localOffset + 30, lnLen), name)) {
      throw ArchiveException('corrupt ZIP: local header of "$name" does not match the central directory');
    }
    final start = e.localOffset + 30 + lnLen + _u16(lh, 28);
    if (start + e.compressedSize > length) throw ArchiveException('corrupt ZIP: data of "$name" out of range');
    if (e.method == 0) {
      if (e.compressedSize != e.size) throw ArchiveException('corrupt ZIP: stored entry "$name" size mismatch');
      return _checkCrc(_readAt(start, e.size), e);
    }
    if (e.method != 8) throw ArchiveException('unsupported compression method ${e.method} for "$name"');
    final out = BytesBuilder(copy: false);
    final sink = _CapSink(out, e.size, name);
    final conv = ZLibDecoder(raw: true).startChunkedConversion(sink);
    var pos = 0;
    try {
      while (pos < e.compressedSize) {
        final n = e.compressedSize - pos < 16384 ? e.compressedSize - pos : 16384;
        conv.add(_readAt(start + pos, n));
        pos += n;
        _checkTime();
      }
      conv.close();
    } on ArchiveException {
      rethrow;
    } catch (_) {
      throw ArchiveException('corrupt ZIP: cannot inflate "$name"');
    }
    final bytes = out.takeBytes();
    if (bytes.length != e.size) throw ArchiveException('corrupt ZIP: size mismatch inflating "$name"');
    return _checkCrc(bytes, e);
  }

  Uint8List _checkCrc(Uint8List bytes, ZipEntry e) {
    if (crc32(bytes) != e.crc) throw ArchiveException('corrupt ZIP: CRC-32 mismatch for "${e.name}"');
    return bytes;
  }

  static bool _sameBytes(Uint8List raw, String name) {
    String s;
    try {
      s = utf8.decode(raw);
    } on FormatException {
      s = latin1.decode(raw);
    }
    return s == name;
  }
}

class _CapSink implements Sink<List<int>> {
  _CapSink(this._out, this._max, this._name);
  final BytesBuilder _out;
  final int _max;
  final String _name;
  @override
  void add(List<int> data) {
    _out.add(data);
    if (_out.length > _max) throw ArchiveException('entry "$_name" inflates beyond its declared size (possible ZIP bomb)');
  }

  @override
  void close() {}
}

final List<int> _crcTable = () {
  final t = List<int>.filled(256, 0);
  for (var n = 0; n < 256; n++) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (0xedb88320 ^ (c >>> 1)) : (c >>> 1);
    }
    t[n] = c;
  }
  return t;
}();

/// CRC-32 (IEEE) as used by ZIP.
int crc32(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c = _crcTable[(c ^ b) & 0xff] ^ (c >>> 8);
  }
  return (c ^ 0xffffffff) & 0xffffffff;
}
