/// Parser for the ASCII ("old-style") property-list format used by Xcode's
/// `project.pbxproj` and by `.xcconfig` files (the latter via [parseXcconfig]).
///
/// Only what the iOS checks need: dictionaries, arrays and strings. Comments
/// (`/* */`, `//`) are skipped. A project that does not parse yields a
/// [FormatException]; callers must report that as "not analyzed", never as valid.
library;

class _P {
  _P(this.s);
  final String s;
  int i = 0;

  void ws() {
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c == 32 || c == 9 || c == 10 || c == 13) {
        i++;
      } else if (c == 47 && i + 1 < s.length && s.codeUnitAt(i + 1) == 42) {
        final e = s.indexOf('*/', i + 2);
        if (e < 0) throw const FormatException('unterminated comment');
        i = e + 2;
      } else if (c == 47 && i + 1 < s.length && s.codeUnitAt(i + 1) == 47) {
        while (i < s.length && s.codeUnitAt(i) != 10) {
          i++;
        }
      } else {
        break;
      }
    }
  }

  Object parseValue() {
    ws();
    if (i >= s.length) throw const FormatException('unexpected end');
    final c = s[i];
    if (c == '{') return parseDict();
    if (c == '(') return parseArray();
    return parseString();
  }

  Map<String, Object> parseDict() {
    i++; // {
    final m = <String, Object>{};
    while (true) {
      ws();
      if (i >= s.length) throw const FormatException('unterminated dictionary');
      if (s[i] == '}') {
        i++;
        return m;
      }
      final k = parseString();
      ws();
      if (i >= s.length || s[i] != '=') throw FormatException('expected "=" after key $k');
      i++;
      final v = parseValue();
      ws();
      if (i < s.length && s[i] == ';') i++;
      m[k] = v;
    }
  }

  List<Object> parseArray() {
    i++; // (
    final l = <Object>[];
    while (true) {
      ws();
      if (i >= s.length) throw const FormatException('unterminated array');
      if (s[i] == ')') {
        i++;
        return l;
      }
      l.add(parseValue());
      ws();
      if (i < s.length && s[i] == ',') i++;
    }
  }

  String parseString() {
    ws();
    if (i >= s.length) throw const FormatException('unexpected end');
    if (s[i] == '"') {
      i++;
      final b = StringBuffer();
      while (i < s.length && s[i] != '"') {
        if (s[i] == '\\' && i + 1 < s.length) {
          final n = s[i + 1];
          b.write(n == 'n' ? '\n' : n == 't' ? '\t' : n);
          i += 2;
        } else {
          b.write(s[i]);
          i++;
        }
      }
      if (i >= s.length) throw const FormatException('unterminated string');
      i++;
      return b.toString();
    }
    final st = i;
    while (i < s.length && RegExp(r'[A-Za-z0-9_./$:+@\-\\*]').hasMatch(s[i])) {
      i++;
    }
    if (i == st) throw FormatException('unexpected character "${s[i]}" at offset $i');
    return s.substring(st, i);
  }
}

/// Parses an ASCII property list into Map/List/String.
Object parseAsciiPlist(String text) {
  final p = _P(text);
  final v = p.parseValue();
  return v;
}

/// Parses `KEY = VALUE` lines and `#include "file"` of an .xcconfig file.
/// Returns settings and the included file names (resolved by the caller).
({Map<String, String> settings, List<String> includes}) parseXcconfig(String text) {
  final settings = <String, String>{};
  final includes = <String>[];
  for (var line in text.split('\n')) {
    final c = line.indexOf('//');
    if (c >= 0) line = line.substring(0, c);
    line = line.trim();
    if (line.isEmpty) continue;
    final inc = RegExp(r'^#include\??\s+"([^"]+)"').firstMatch(line);
    if (inc != null) {
      includes.add(inc.group(1)!);
      continue;
    }
    final m = RegExp(r'^([A-Za-z0-9_]+(?:\[[^\]]*\])*)\s*=\s*(.*)$').firstMatch(line);
    if (m != null && !m.group(1)!.contains('[')) settings[m.group(1)!] = m.group(2)!.trim();
  }
  return (settings: settings, includes: includes);
}
