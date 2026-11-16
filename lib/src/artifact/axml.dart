import 'dart:convert';
import 'dart:typed_data';

/// Thrown for binary resource data that is malformed or uses an unsupported layout.
class BinaryFormatException implements Exception {
  BinaryFormatException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Android resource value types used here.
const typeReference = 0x01;
const typeString = 0x03;
const typeIntDec = 0x10;
const typeIntHex = 0x11;
const typeBoolean = 0x12;

class AxmlAttr {
  AxmlAttr(this.namespace, this.name, this.rawString, this.dataType, this.data);
  final String? namespace;
  final String name;
  final String? rawString;
  final int dataType;
  final int data;

  bool get isAndroid => namespace == 'http://schemas.android.com/apk/res/android';
  bool get isReference => dataType == typeReference;
  bool get isInt => dataType == typeIntDec || dataType == typeIntHex;

  /// Boolean attribute; null if not a boolean literal.
  bool? get asBool => dataType == typeBoolean ? data != 0 : null;

  /// String value (literal strings only).
  String? get asString => dataType == typeString ? rawString : null;

  String describe() {
    switch (dataType) {
      case typeString:
        return rawString ?? '';
      case typeBoolean:
        return data != 0 ? 'true' : 'false';
      case typeReference:
        return '@0x${data.toRadixString(16).padLeft(8, '0')}';
      case typeIntDec:
        return '${data.toSigned(32)}';
      case typeIntHex:
        return '0x${data.toRadixString(16)}';
      default:
        return rawString ?? 'type0x${dataType.toRadixString(16)}:0x${data.toRadixString(16)}';
    }
  }
}

class AxmlElement {
  AxmlElement(this.name, this.attrs);
  final String name;
  final List<AxmlAttr> attrs;
  final List<AxmlElement> children = [];

  /// Attribute in the android namespace (or, if no such attribute, an un-namespaced one).
  AxmlAttr? attr(String n) {
    for (final a in attrs) {
      if (a.name == n && a.isAndroid) return a;
    }
    for (final a in attrs) {
      if (a.name == n && a.namespace == null) return a;
    }
    return null;
  }

  Iterable<AxmlElement> childrenNamed(String n) => children.where((c) => c.name == n);
}

class StringPool {
  StringPool(this.strings);
  final List<String> strings;
  String? at(int i) => i < 0 || i >= strings.length ? null : strings[i];

  static StringPool parse(Uint8List b, int chunkStart) {
    final bd = ByteData.sublistView(b);
    final count = bd.getUint32(chunkStart + 8, Endian.little);
    final flags = bd.getUint32(chunkStart + 16, Endian.little);
    final stringsStart = bd.getUint32(chunkStart + 20, Endian.little);
    final headerSize = bd.getUint16(chunkStart + 2, Endian.little);
    final chunkSize = bd.getUint32(chunkStart + 4, Endian.little);
    final utf8Flag = flags & 0x100 != 0;
    if (count > 4000000 || chunkStart + chunkSize > b.length || chunkStart + headerSize + count * 4 > b.length) {
      throw BinaryFormatException('string pool out of range');
    }
    final out = <String>[];
    final base = chunkStart + stringsStart;
    for (var i = 0; i < count; i++) {
      final off = base + bd.getUint32(chunkStart + headerSize + i * 4, Endian.little);
      if (off >= chunkStart + chunkSize || off >= b.length) throw BinaryFormatException('string offset out of range');
      out.add(utf8Flag ? _utf8At(b, off, chunkStart + chunkSize) : _utf16At(b, off, chunkStart + chunkSize));
    }
    return StringPool(out);
  }

  static String _utf8At(Uint8List b, int off, int end) {
    var p = off;
    int len8() {
      var l = b[p++];
      if (l & 0x80 != 0) l = ((l & 0x7f) << 8) | b[p++];
      return l;
    }

    len8(); // char count
    final n = len8(); // byte count
    if (p + n > end) throw BinaryFormatException('string out of range');
    return utf8.decode(b.sublist(p, p + n), allowMalformed: true);
  }

  static String _utf16At(Uint8List b, int off, int end) {
    var p = off;
    var l = b[p] | (b[p + 1] << 8);
    p += 2;
    if (l & 0x8000 != 0) {
      l = ((l & 0x7fff) << 16) | (b[p] | (b[p + 1] << 8));
      p += 2;
    }
    if (p + l * 2 > end) throw BinaryFormatException('string out of range');
    final units = <int>[for (var i = 0; i < l; i++) b[p + i * 2] | (b[p + i * 2 + 1] << 8)];
    return String.fromCharCodes(units);
  }
}

/// Minimal reader of Android binary XML (compiled AndroidManifest.xml, res/xml/*.xml).
/// Returns the root element. Unknown chunk types are skipped.
AxmlElement parseAxml(Uint8List b) {
  if (b.length < 8) throw BinaryFormatException('not binary XML (too short)');
  final bd = ByteData.sublistView(b);
  if (bd.getUint16(0, Endian.little) != 0x0003) throw BinaryFormatException('not binary XML (bad magic)');
  final total = bd.getUint32(4, Endian.little);
  final end = total < b.length ? total : b.length;
  var p = bd.getUint16(2, Endian.little);
  StringPool? pool;
  final stack = <AxmlElement>[];
  AxmlElement? root;
  final nsUri = <int, int>{}; // prefix idx -> uri idx (unused but kept simple)
  while (p + 8 <= end) {
    final type = bd.getUint16(p, Endian.little);
    final hsize = bd.getUint16(p + 2, Endian.little);
    final size = bd.getUint32(p + 4, Endian.little);
    if (size < 8 || p + size > end) throw BinaryFormatException('chunk out of range');
    switch (type) {
      case 0x0001:
        pool = StringPool.parse(b, p);
        break;
      case 0x0100:
        nsUri[bd.getUint32(p + 16, Endian.little)] = bd.getUint32(p + 20, Endian.little);
        break;
      case 0x0102:
        if (pool == null) throw BinaryFormatException('element before string pool');
        final name = pool.at(bd.getUint32(p + 20, Endian.little)) ?? '';
        final attrStart = bd.getUint16(p + 24, Endian.little);
        final attrSize = bd.getUint16(p + 26, Endian.little);
        final attrCount = bd.getUint16(p + 28, Endian.little);
        if (attrSize < 20) throw BinaryFormatException('bad attribute size');
        final attrs = <AxmlAttr>[];
        for (var i = 0; i < attrCount; i++) {
          final a = p + 16 + attrStart + i * attrSize;
          if (a + 20 > p + size) throw BinaryFormatException('attribute out of range');
          final ns = bd.getInt32(a, Endian.little);
          final nm = bd.getUint32(a + 4, Endian.little);
          final raw = bd.getInt32(a + 8, Endian.little);
          final dt = b[a + 15];
          final data = bd.getUint32(a + 16, Endian.little);
          attrs.add(AxmlAttr(ns < 0 ? null : pool.at(ns), pool.at(nm) ?? '', raw < 0 ? null : pool.at(raw), dt, data));
        }
        final el = AxmlElement(name, attrs);
        if (stack.isEmpty) {
          root ??= el;
        } else {
          stack.last.children.add(el);
        }
        stack.add(el);
        break;
      case 0x0103:
        if (stack.isNotEmpty) stack.removeLast();
        break;
      default:
        break;
    }
    p += size;
    if (hsize == 0) break;
  }
  if (root == null) throw BinaryFormatException('no root element');
  return root;
}
