/// Test-only writers for synthetic archives. Output models the *format*; it is
/// not produced by Android or Apple tooling (see test/artifact_test.dart for
/// the real-build fixtures).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:widgetforge/src/artifact/zip_reader.dart' show crc32;

// ---- ZIP -------------------------------------------------------------------

class ZipFile {
  ZipFile(this.name, this.data, {this.deflate = true, this.flags = 0, this.declaredSize, this.method, this.crc, this.localName, this.localFlags});
  final String name;
  final List<int> data;
  final bool deflate;
  final int flags;
  final int? declaredSize;
  final int? method;
  final int? crc;
  final int? localFlags;
  final String? localName; // name written in the local header, if different from the central one
}

Uint8List buildZip(List<ZipFile> files, {int? eocdTotal}) {
  final out = BytesBuilder();
  final cd = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255]);
  void u32(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  for (final f in files) {
    final raw = Uint8List.fromList(f.data);
    final comp = f.deflate ? Uint8List.fromList(ZLibCodec(raw: true, level: 9).encode(raw)) : raw;
    final method = f.method ?? (f.deflate ? 8 : 0);
    final nameBytes = utf8.encode(f.name);
    final localBytes = utf8.encode(f.localName ?? f.name);
    final off = out.length;
    u32(out, 0x04034b50);
    u16(out, 20);
    u16(out, f.localFlags ?? f.flags);
    u16(out, method);
    u32(out, 0);
    u32(out, f.crc ?? crc32(raw));
    u32(out, comp.length);
    u32(out, f.declaredSize ?? raw.length);
    u16(out, localBytes.length);
    u16(out, 0);
    out.add(localBytes);
    out.add(comp);
    u32(cd, 0x02014b50);
    u16(cd, 20);
    u16(cd, 20);
    u16(cd, f.flags);
    u16(cd, method);
    u32(cd, 0);
    u32(cd, f.crc ?? crc32(raw));
    u32(cd, comp.length);
    u32(cd, f.declaredSize ?? raw.length);
    u16(cd, nameBytes.length);
    u16(cd, 0);
    u16(cd, 0);
    u16(cd, 0);
    u16(cd, 0);
    u32(cd, 0);
    u32(cd, off);
    cd.add(nameBytes);
  }
  final cdOff = out.length;
  final cdBytes = cd.takeBytes();
  out.add(cdBytes);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, eocdTotal ?? files.length);
  u16(out, eocdTotal ?? files.length);
  u32(out, cdBytes.length);
  u32(out, cdOff);
  u16(out, 0);
  return out.takeBytes();
}

String writeTemp(Directory dir, String name, List<int> bytes) {
  final f = File('${dir.path}/$name')..writeAsBytesSync(bytes);
  return f.path;
}

// ---- Binary XML (AXML) -------------------------------------------------------

class A {
  A.str(this.ns, this.name, String v)
      : type = 3,
        data = 0,
        str = v;
  A.bool(this.ns, this.name, bool v)
      : type = 0x12,
        data = v ? 0xffffffff : 0,
        str = null;
  A.int(this.ns, this.name, this.data)
      : type = 0x10,
        str = null;
  A.ref(this.ns, this.name, this.data)
      : type = 1,
        str = null;
  final bool ns; // android namespace?
  final String name;
  final int type;
  final int data;
  final String? str;
}

class E {
  E(this.name, [this.attrs = const [], this.children = const []]);
  final String name;
  final List<A> attrs;
  final List<E> children;
}

const androidNs = 'http://schemas.android.com/apk/res/android';

Uint8List buildAxml(E root, {bool utf8Pool = false}) {
  final strings = <String>[];
  int idx(String s) {
    var i = strings.indexOf(s);
    if (i < 0) {
      strings.add(s);
      i = strings.length - 1;
    }
    return i;
  }

  final nsIdx = idx(androidNs);
  final prefixIdx = idx('android');
  final body = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255]);
  void u32(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  void chunk(int type, int header, List<int> payload, {int extra = 0}) {
    u16(body, type);
    u16(body, header);
    u32(body, 8 + payload.length);
    body.add(payload);
  }

  Uint8List le32(List<int> vs) {
    final b = BytesBuilder();
    for (final v in vs) {
      u32(b, v);
    }
    return b.takeBytes();
  }

  void writeElement(E e, bool first) {
    final attrs = BytesBuilder();
    for (final a in e.attrs) {
      u32(attrs, a.ns ? nsIdx : 0xffffffff);
      u32(attrs, idx(a.name));
      u32(attrs, a.str != null ? idx(a.str!) : 0xffffffff);
      u16(attrs, 8);
      attrs.add([0, a.type]);
      u32(attrs, a.str != null ? idx(a.str!) : a.data);
    }
    final p = BytesBuilder();
    u32(p, 1); // line
    u32(p, 0xffffffff); // comment
    u32(p, 0xffffffff); // ns
    u32(p, idx(e.name));
    u16(p, 20);
    u16(p, 20);
    u16(p, e.attrs.length);
    u16(p, 0);
    u16(p, 0);
    u16(p, 0);
    p.add(attrs.takeBytes());
    chunk(0x0102, 16, p.takeBytes());
    for (final c in e.children) {
      writeElement(c, false);
    }
    final q = BytesBuilder();
    u32(q, 1);
    u32(q, 0xffffffff);
    u32(q, 0xffffffff);
    u32(q, idx(e.name));
    chunk(0x0103, 16, q.takeBytes());
  }

  // namespace start
  chunk(0x0100, 16, le32([1, 0xffffffff, prefixIdx, nsIdx]));
  writeElement(root, true);
  chunk(0x0101, 16, le32([1, 0xffffffff, prefixIdx, nsIdx]));

  final pool = _stringPool(strings, utf8Pool);
  final all = BytesBuilder();
  u16(all, 0x0003);
  u16(all, 8);
  u32(all, 8 + pool.length + body.length);
  all.add(pool);
  all.add(body.takeBytes());
  return all.takeBytes();
}

Uint8List _stringPool(List<String> strings, bool utf8Pool) {
  void u16(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255]);
  void u32(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  final data = BytesBuilder();
  final offs = <int>[];
  for (final s in strings) {
    offs.add(data.length);
    if (utf8Pool) {
      final b = utf8.encode(s);
      data.add([s.length, b.length]);
      data.add(b);
      data.add([0]);
    } else {
      u16(data, s.length);
      for (final c in s.codeUnits) {
        u16(data, c);
      }
      u16(data, 0);
    }
  }
  while (data.length % 4 != 0) {
    data.add([0]);
  }
  final header = 28;
  final stringsStart = header + strings.length * 4;
  final out = BytesBuilder();
  u16(out, 0x0001);
  u16(out, header);
  u32(out, stringsStart + data.length);
  u32(out, strings.length);
  u32(out, 0);
  u32(out, utf8Pool ? 0x100 : 0);
  u32(out, stringsStart);
  u32(out, 0);
  for (final o in offs) {
    u32(out, o);
  }
  out.add(data.takeBytes());
  return out.takeBytes();
}

// ---- resources.arsc ------------------------------------------------------------

/// [files]: resource id -> file path.
Uint8List buildArsc(Map<int, String> files, {String package = 'com.example', Set<int> intValued = const {}}) {
  void u16(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255]);
  void u32(BytesBuilder b, int v) => b.add([v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255]);
  final paths = files.values.toSet().toList();
  final global = _stringPool(paths, true);
  // group by (type)
  final byType = <int, Map<int, int>>{}; // type -> entry -> string idx
  files.forEach((id, path) {
    byType.putIfAbsent((id >> 16) & 0xff, () => {})[id & 0xffff] = paths.indexOf(path);
  });
  final pkg = BytesBuilder();
  final typeChunks = BytesBuilder();
  byType.forEach((type, entries) {
    final maxEntry = entries.keys.reduce((a, b) => a > b ? a : b) + 1;
    final offsets = BytesBuilder();
    final data = BytesBuilder();
    for (var i = 0; i < maxEntry; i++) {
      final s = entries[i];
      if (s == null) {
        u32(offsets, 0xffffffff);
        continue;
      }
      u32(offsets, data.length);
      u16(data, 8);
      u16(data, 0);
      u32(data, 0); // key
      u16(data, 8);
      data.add([0, intValued.contains((0x7f << 24) | (type << 16) | i) ? 0x10 : 3]);
      u32(data, s);
    }
    final header = 20 + 64; // ResTable_type: header 20 + config(64)
    final entriesStart = header + maxEntry * 4;
    final c = BytesBuilder();
    u16(c, 0x0201);
    u16(c, header);
    u32(c, entriesStart + data.length);
    c.add([type, 0]);
    u16(c, 0);
    u32(c, maxEntry);
    u32(c, entriesStart);
    u32(c, 64); // config size
    c.add(List.filled(60, 0));
    c.add(offsets.takeBytes());
    c.add(data.takeBytes());
    typeChunks.add(c.takeBytes());
  });
  final pkgHeader = 288;
  final tc = typeChunks.takeBytes();
  u16(pkg, 0x0200);
  u16(pkg, pkgHeader);
  u32(pkg, pkgHeader + tc.length);
  u32(pkg, 0x7f);
  final name = BytesBuilder();
  for (final cu in package.codeUnits) {
    u16(name, cu);
  }
  final nb = name.takeBytes();
  pkg.add(nb);
  pkg.add(List.filled(256 - nb.length, 0));
  pkg.add(List.filled(pkgHeader - 8 - 4 - 256, 0));
  pkg.add(tc);
  final all = BytesBuilder();
  u16(all, 0x0002);
  u16(all, 12);
  u32(all, 12 + global.length + pkg.length);
  u32(all, 1);
  all.add(global);
  all.add(pkg.takeBytes());
  return all.takeBytes();
}

// ---- binary plist ----------------------------------------------------------------

Uint8List buildBplist(Object root) {
  final objs = <List<int>>[];
  final out = BytesBuilder();
  out.add(ascii.encode('bplist00'));
  final offsets = <int>[];
  int write(Object v) {
    // returns object index; objects are written in post-order with 1-byte refs (<256 objects)
    List<int> body;
    if (v is bool) {
      body = [v ? 0x09 : 0x08];
    } else if (v is int) {
      body = [0x10, v & 255];
      if (v > 255) body = [0x11, (v >> 8) & 255, v & 255];
    } else if (v is String) {
      final b = ascii.encode(v);
      body = b.length < 15 ? [0x50 | b.length, ...b] : [0x5f, 0x10, b.length, ...b];
    } else if (v is List) {
      final refs = [for (final e in v) write(e)];
      body = [0xa0 | refs.length, ...refs];
    } else if (v is Map) {
      final ks = [for (final k in v.keys) write(k as String)];
      final vs = [for (final x in v.values) write(x as Object)];
      body = [0xd0 | ks.length, ...ks, ...vs];
    } else {
      throw ArgumentError('unsupported $v');
    }
    offsets.add(out.length);
    out.add(body);
    objs.add(body);
    return offsets.length - 1;
  }

  final top = write(root);
  final tableOff = out.length;
  for (final o in offsets) {
    out.add([o]);
  }
  final t = Uint8List(32);
  t[6] = 1;
  t[7] = 1;
  t[15] = offsets.length;
  t[23] = top;
  t[31] = tableOff;
  if (tableOff > 255) throw StateError('test bplist too large');
  out.add(t);
  return out.takeBytes();
}

String xmlPlist(Map<String, Object> m) {
  String v(Object o) {
    if (o is String) return '<string>$o</string>';
    if (o is bool) return o ? '<true/>' : '<false/>';
    if (o is Map<String, Object>) return '<dict>${o.entries.map((e) => '<key>${e.key}</key>${v(e.value)}').join()}</dict>';
    throw ArgumentError('$o');
  }

  return '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0">${v(m)}</plist>';
}
