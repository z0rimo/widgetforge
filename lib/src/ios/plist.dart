import 'dart:io';

import 'package:xml/xml.dart';

/// Reads an XML property list (Info.plist, .entitlements) into Dart values:
/// Map, List, String, int, double, bool. Binary plists are not supported:
/// [readPlistFile] throws a [FormatException] so the caller can say "not analyzed"
/// instead of guessing.
Object parsePlistXml(String text) {
  final doc = XmlDocument.parse(text);
  final root = doc.rootElement;
  if (root.name.local != 'plist') throw const FormatException('root element is not <plist>');
  final first = root.childElements.firstOrNull;
  if (first == null) throw const FormatException('empty plist');
  return _value(first);
}

Object _value(XmlElement e) {
  switch (e.name.local) {
    case 'dict':
      final m = <String, Object>{};
      final kids = e.childElements.toList();
      for (var i = 0; i + 1 < kids.length; i += 2) {
        if (kids[i].name.local != 'key') throw const FormatException('malformed dict');
        m[kids[i].innerText] = _value(kids[i + 1]);
      }
      return m;
    case 'array':
      return [for (final c in e.childElements) _value(c)];
    case 'string':
      return e.innerText;
    case 'integer':
      return int.tryParse(e.innerText.trim()) ?? 0;
    case 'real':
      return double.tryParse(e.innerText.trim()) ?? 0.0;
    case 'true':
      return true;
    case 'false':
      return false;
    default:
      return e.innerText;
  }
}

Map<String, Object> readPlistFile(File f) {
  final bytes = f.readAsBytesSync();
  if (bytes.length >= 6 && String.fromCharCodes(bytes.sublist(0, 6)) == 'bplist') {
    throw const FormatException('binary property list');
  }
  final v = parsePlistXml(String.fromCharCodes(bytes));
  if (v is! Map<String, Object>) throw const FormatException('top-level value is not a dictionary');
  return v;
}
