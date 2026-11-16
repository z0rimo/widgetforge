import 'source/native_source.dart';

/// Does any manifest `android:name` in [names] denote class [c]?
///
/// Relative names (`.Foo`, `Foo`) resolve against [namespace]. When the
/// namespace is unknown, a relative name matches EVERY class with that
/// trailing name: an ambiguous match is treated as "registered" so that no
/// error is reported without evidence.
bool isRegistered(NativeClass c, Iterable<String> names, String? namespace) {
  for (final raw in names) {
    final n = raw.trim();
    if (n.isEmpty || n.contains(r'${')) continue;
    if (n.startsWith('.') || !n.contains('.')) {
      final rel = n.startsWith('.') ? n : '.$n';
      if (namespace != null) {
        if (c.fqcn == '$namespace$rel') return true;
      } else if (c.fqcn.endsWith(rel) || c.fqcn == rel.substring(1)) {
        return true;
      }
    } else if (c.fqcn == n) {
      return true;
    }
  }
  return false;
}

/// Does the single manifest name [raw] denote class [c]? (same rules as above)
bool nameDenotes(NativeClass c, String raw, String? namespace) =>
    isRegistered(c, [raw], namespace);
