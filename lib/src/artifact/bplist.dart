import 'dart:convert';
import 'dart:typed_data';

import '../ios/plist.dart';
import 'axml.dart' show BinaryFormatException;

/// Parses an Info.plist / entitlements plist that is either XML or binary
/// ("bplist00"). Returns Map/List/String/int/double/bool values. Dates and data
/// become strings / null. Throws [BinaryFormatException] or [FormatException].
Object parsePlistAny(Uint8List b) {
  if (b.length >= 8 && String.fromCharCodes(b.sublist(0, 8)) == 'bplist00') return _Bplist(b).parse();
  if (b.length >= 6 && String.fromCharCodes(b.sublist(0, 6)) == 'bplist') {
    throw BinaryFormatException('unsupported binary plist version');
  }
  return parsePlistXml(utf8.decode(b, allowMalformed: true));
}

class _Bplist {
  _Bplist(this.b) : bd = ByteData.sublistView(b);
  final Uint8List b;
  final ByteData bd;
  late int offSize, refSize, numObjects, offTable;
  int _visited = 0;

  Object parse() {
    if (b.length < 40) throw BinaryFormatException('binary plist too short');
    final t = b.length - 32;
    offSize = b[t + 6];
    refSize = b[t + 7];
    numObjects = _uint(t + 8, 8);
    final top = _uint(t + 16, 8);
    offTable = _uint(t + 24, 8);
    if (offSize < 1 || offSize > 8 || refSize < 1 || refSize > 8) throw BinaryFormatException('bad plist trailer');
    if (numObjects > 1000000 || top >= numObjects || offTable + numObjects * offSize > t) {
      throw BinaryFormatException('bad plist trailer');
    }
    return _obj(top, 0);
  }

  int _uint(int o, int n) {
    if (o < 0 || o + n > b.length) throw BinaryFormatException('plist out of range');
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 8) | b[o + i];
    }
    return v;
  }

  Object _obj(int idx, int depth) {
    if (depth > 64) throw BinaryFormatException('plist nesting too deep');
    if (++_visited > 2000000) throw BinaryFormatException('plist too large');
    var o = _uint(offTable + idx * offSize, offSize);
    if (o >= b.length - 32) throw BinaryFormatException('plist offset out of range');
    final m = b[o];
    final hi = m >> 4, lo = m & 0xf;
    o++;
    int count() {
      if (lo != 0xf) return lo;
      final im = b[o];
      if (im >> 4 != 1) throw BinaryFormatException('bad plist length');
      final n = 1 << (im & 0xf);
      final v = _uint(o + 1, n);
      o += 1 + n;
      return v;
    }

    switch (hi) {
      case 0x0:
        return lo == 9; // 8 false, 9 true, others (null/fill) -> false
      case 0x1:
        final n = 1 << lo;
        if (n > 8) throw BinaryFormatException('plist integer too large');
        return _uint(o, n);
      case 0x2:
        return lo == 3 ? bd.getFloat64(o, Endian.big) : bd.getFloat32(o, Endian.big);
      case 0x3:
        return '';
      case 0x4:
        return '';
      case 0x5:
        final n = count();
        if (o + n > b.length) throw BinaryFormatException('plist string out of range');
        return latin1.decode(b.sublist(o, o + n));
      case 0x6:
        final n = count();
        if (o + n * 2 > b.length) throw BinaryFormatException('plist string out of range');
        return String.fromCharCodes([for (var i = 0; i < n; i++) (b[o + i * 2] << 8) | b[o + i * 2 + 1]]);
      case 0xa:
        final n = count();
        return [for (var i = 0; i < n; i++) _obj(_uint(o + i * refSize, refSize), depth + 1)];
      case 0xd:
        final n = count();
        final m2 = <String, Object>{};
        for (var i = 0; i < n; i++) {
          final k = _obj(_uint(o + i * refSize, refSize), depth + 1);
          final v = _obj(_uint(o + (n + i) * refSize, refSize), depth + 1);
          if (k is String) m2[k] = v;
        }
        return m2;
      default:
        return '';
    }
  }
}
