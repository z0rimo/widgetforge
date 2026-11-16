import 'dart:typed_data';

import 'axml.dart';

/// Resource id -> file paths, read from resources.arsc. Only values of type
/// string whose text looks like a path inside the archive are kept (that is how
/// aapt2 stores file-based resources such as layouts and res/xml files).
class ResourceTable {
  ResourceTable(this.filesById, this.packageNames);
  final Map<int, List<String>> filesById;
  final List<String> packageNames;

  static ResourceTable parse(Uint8List b) {
    final bd = ByteData.sublistView(b);
    if (b.length < 12 || bd.getUint16(0, Endian.little) != 0x0002) throw BinaryFormatException('not a resource table');
    final headerSize = bd.getUint16(2, Endian.little);
    final total = bd.getUint32(4, Endian.little);
    final end = total < b.length ? total : b.length;
    var p = headerSize;
    StringPool? global;
    final files = <int, List<String>>{};
    final pkgs = <String>[];
    while (p + 8 <= end) {
      final type = bd.getUint16(p, Endian.little);
      final size = bd.getUint32(p + 4, Endian.little);
      if (size < 8 || p + size > end) throw BinaryFormatException('table chunk out of range');
      if (type == 0x0001 && global == null) {
        global = StringPool.parse(b, p);
      } else if (type == 0x0200) {
        if (global == null) throw BinaryFormatException('package before string pool');
        _package(b, bd, p, size, global, files, pkgs);
      }
      p += size;
    }
    return ResourceTable(files, pkgs);
  }

  static void _package(Uint8List b, ByteData bd, int start, int size, StringPool global, Map<int, List<String>> files, List<String> pkgs) {
    final pkgId = bd.getUint32(start + 8, Endian.little);
    final units = <int>[];
    for (var i = 0; i < 128; i++) {
      final u = bd.getUint16(start + 12 + i * 2, Endian.little);
      if (u == 0) break;
      units.add(u);
    }
    pkgs.add(String.fromCharCodes(units));
    var p = start + bd.getUint16(start + 2, Endian.little);
    final end = start + size;
    while (p + 8 <= end) {
      final type = bd.getUint16(p, Endian.little);
      final csize = bd.getUint32(p + 4, Endian.little);
      if (csize < 8 || p + csize > end) throw BinaryFormatException('package chunk out of range');
      if (type == 0x0201) _typeChunk(b, bd, p, csize, pkgId, global, files);
      p += csize;
    }
  }

  static void _typeChunk(Uint8List b, ByteData bd, int p, int csize, int pkgId, StringPool global, Map<int, List<String>> files) {
    final hsize = bd.getUint16(p + 2, Endian.little);
    final typeId = b[p + 8];
    final flags = b[p + 9];
    final count = bd.getUint32(p + 12, Endian.little);
    final entriesStart = bd.getUint32(p + 16, Endian.little);
    final sparse = flags & 0x01 != 0;
    final offset16 = flags & 0x02 != 0;
    if (count > 0x10000) throw BinaryFormatException('too many entries');
    final tableAt = p + hsize;
    final dataBase = p + entriesStart;
    for (var i = 0; i < count; i++) {
      int entryIdx;
      int off;
      if (sparse) {
        final q = tableAt + i * 4;
        if (q + 4 > p + csize) throw BinaryFormatException('entry table out of range');
        entryIdx = bd.getUint16(q, Endian.little);
        off = bd.getUint16(q + 2, Endian.little) * 4;
      } else if (offset16) {
        final q = tableAt + i * 2;
        if (q + 2 > p + csize) throw BinaryFormatException('entry table out of range');
        final o = bd.getUint16(q, Endian.little);
        if (o == 0xffff) continue;
        entryIdx = i;
        off = o * 4;
      } else {
        final q = tableAt + i * 4;
        if (q + 4 > p + csize) throw BinaryFormatException('entry table out of range');
        final o = bd.getUint32(q, Endian.little);
        if (o == 0xffffffff) continue;
        entryIdx = i;
        off = o;
      }
      final e = dataBase + off;
      if (e + 16 > p + csize) throw BinaryFormatException('entry out of range');
      final eflags = bd.getUint16(e + 2, Endian.little);
      if (eflags & 0x0001 != 0) continue; // complex (map) entry
      final vType = b[e + 8 + 3];
      final vData = bd.getUint32(e + 8 + 4, Endian.little);
      if (vType != typeString) continue;
      final s = global.at(vData);
      if (s == null || !s.contains('/')) continue;
      final id = (pkgId << 24) | (typeId << 16) | entryIdx;
      files.putIfAbsent(id, () => []).add(s);
    }
  }
}
