/// Minimal Kotlin/Java declaration reader: classes, their supertypes and
/// (for the entrypoint check) the bodies of overrides.
///
/// Scope (deliberate): top-level and nested `class`/`interface` declarations,
/// package + imports, supertype lists. Not handled: type aliases, import
/// aliases (`import a.B as C`), generics-based inference, annotation
/// processors/generated code, Kotlin scripts. Whatever cannot be resolved
/// from the project's own sources is reported as "unknown" to callers, who
/// must then NOT emit an error.
library;

import 'dart:io';

import 'lexer.dart';

class SuperRef {
  SuperRef(this.written, this.candidates);

  /// As written in the source (e.g. `AppWidgetProvider`, `a.b.Base`).
  final String written;

  /// Fully-qualified names this reference could denote (explicit import,
  /// same package, wildcard imports). Empty when nothing can be inferred.
  final List<String> candidates;
}

class NativeClass {
  NativeClass({
    required this.file,
    required this.name,
    required this.fqcn,
    required this.line,
    required this.isAbstract,
    required this.isInterface,
    required this.supers,
    required this.header,
    required this.bodyStart,
    required this.bodyEnd,
    required this.tokens,
    required this.nested,
  });
  final File file;
  final String name;
  final String fqcn; // nested classes use `Outer$Inner` (manifest style)
  final int line;
  final bool isAbstract;
  final bool isInterface;
  final bool nested;
  final List<SuperRef> supers;

  /// Source text from `class` up to the end of the supertype list.
  final String header;

  /// Token index range [bodyStart, bodyEnd) of the class body, or -1/-1.
  final int bodyStart;
  final int bodyEnd;
  final List<Token> tokens; // tokens of the whole file (shared)
}

class NativeFile {
  NativeFile(this.file, this.text, this.tokens, this.package, this.classes);
  final File file;
  final String text;
  final List<Token> tokens;
  final String package;
  final List<NativeClass> classes;
}

const _modifiers = {
  'abstract', 'open', 'final', 'sealed', 'data', 'inner', 'private', 'public',
  'internal', 'protected', 'static', 'enum', 'annotation', 'fun', 'value',
  'strictfp', 'expect', 'actual',
};

NativeFile parseNativeFile(File f) {
  final text = f.readAsStringSync();
  final lang = f.path.endsWith('.java') ? Lang.java : Lang.kotlin;
  final t = tokenize(text, lang);
  var package = '';
  final explicit = <String, String>{}; // simple -> fqcn
  final wildcards = <String>[]; // package prefixes

  String dotted(int from, [int? stopBefore]) {
    final b = StringBuffer();
    var k = from;
    while (k < t.length) {
      if (t[k].kind == TokenKind.ident) {
        b.write(t[k].text);
        k++;
        if (k < t.length && t[k].is_('.') && k + 1 < t.length) {
          if (t[k + 1].is_('*')) {
            b.write('.*');
            k += 2;
            break;
          }
          b.write('.');
          k++;
          continue;
        }
      }
      break;
    }
    return b.toString();
  }

  // package / imports (header region only: stop at first class-like keyword)
  for (var i = 0; i < t.length; i++) {
    if (t[i].kind != TokenKind.ident) continue;
    if (t[i].text == 'package' && i + 1 < t.length) {
      package = dotted(i + 1);
    } else if (t[i].text == 'import' && i + 1 < t.length) {
      var k = i + 1;
      if (t[k].text == 'static') k++;
      final q = dotted(k);
      if (q.endsWith('.*')) {
        wildcards.add(q.substring(0, q.length - 2));
      } else if (q.isNotEmpty) {
        // `import a.B as C` is not supported: record under the imported name.
        explicit[q.split('.').last] = q;
      }
    } else if (t[i].text == 'class' || t[i].text == 'interface') {
      break;
    }
  }

  final classes = <NativeClass>[];
  // stack of (fqcn, index of '{' that closes the class body)
  final stack = <(String, int)>[];
  var depth = 0;
  final bodyDepthStack = <int>[];
  for (var i = 0; i < t.length; i++) {
    final tok = t[i];
    if (tok.kind == TokenKind.punct) {
      if (tok.text == '{') depth++;
      if (tok.text == '}') {
        depth--;
        while (bodyDepthStack.isNotEmpty && bodyDepthStack.last > depth) {
          bodyDepthStack.removeLast();
          stack.removeLast();
        }
      }
      continue;
    }
    if (tok.kind != TokenKind.ident) continue;
    if (tok.text != 'class' && tok.text != 'interface') continue;
    // `Foo::class` (Kotlin), `Foo.class` (Java): not a declaration.
    if (i > 0 && t[i - 1].kind == TokenKind.punct && (t[i - 1].text == ':' || t[i - 1].text == '.')) {
      if (t[i - 1].text == '.' || (i > 1 && t[i - 2].is_(':'))) continue;
    }
    if (i + 1 >= t.length || t[i + 1].kind != TokenKind.ident) continue;
    final name = t[i + 1].text;

    // modifiers directly before the keyword
    final mods = <String>{};
    var m = i - 1;
    while (m >= 0 && t[m].kind == TokenKind.ident && _modifiers.contains(t[m].text)) {
      mods.add(t[m].text);
      m--;
    }

    var k = i + 2;
    if (k < t.length && t[k].is_('<')) {
      final e = matching(t, k);
      if (e > 0) k = e + 1;
    }
    if (k < t.length && t[k].is_('(')) {
      final e = matching(t, k);
      if (e > 0) k = e + 1;
    }
    final supers = <SuperRef>[];
    var headerEnd = k > 0 ? t[k - 1].end : tok.end;

    SuperRef? readSuper() {
      if (k >= t.length || t[k].kind != TokenKind.ident) return null;
      // skip annotations are not expected here
      final q = dotted(k);
      if (q.isEmpty) return null;
      // advance k past the dotted name
      var parts = q.split('.').length;
      var kk = k;
      while (parts > 0) {
        kk++;
        parts--;
        if (parts > 0) kk++; // the dot
      }
      k = kk;
      if (k < t.length && t[k].is_('<')) {
        final e = matching(t, k);
        if (e > 0) k = e + 1;
      }
      if (k < t.length && t[k].is_('(')) {
        final e = matching(t, k);
        if (e > 0) k = e + 1;
      }
      headerEnd = t[k - 1].end;
      return SuperRef(q, _candidates(q, package, explicit, wildcards));
    }

    if (k < t.length && t[k].is_(':')) {
      // Kotlin supertypes
      k++;
      while (true) {
        final s = readSuper();
        if (s == null) break;
        supers.add(s);
        if (k < t.length && t[k].is_('by')) break;
        if (k < t.length && t[k].is_(',')) {
          k++;
          continue;
        }
        break;
      }
    } else {
      // Java: extends X [implements A, B] / interface extends A, B
      while (k < t.length && t[k].kind == TokenKind.ident && (t[k].text == 'extends' || t[k].text == 'implements')) {
        k++;
        while (true) {
          final s = readSuper();
          if (s == null) break;
          supers.add(s);
          if (k < t.length && t[k].is_(',')) {
            k++;
            continue;
          }
          break;
        }
      }
    }

    // optional Kotlin `where` clause is ignored; look for the body.
    var bodyStart = -1, bodyEnd = -1;
    var kb = k;
    if (kb < t.length && t[kb].is_('{')) {
      final e = matching(t, kb);
      if (e > 0) {
        bodyStart = kb + 1;
        bodyEnd = e;
      }
    }

    final outer = stack.isEmpty ? null : stack.last.$1;
    final fqcn = outer != null
        ? '$outer\$$name'
        : (package.isEmpty ? name : '$package.$name');
    classes.add(NativeClass(
      file: f,
      name: name,
      fqcn: fqcn,
      line: tok.line,
      isAbstract: mods.contains('abstract') || tok.text == 'interface' || mods.contains('sealed'),
      isInterface: tok.text == 'interface',
      supers: supers,
      header: text.substring(tok.offset, headerEnd).replaceAll(RegExp(r'\s+'), ' '),
      bodyStart: bodyStart,
      bodyEnd: bodyEnd,
      tokens: t,
      nested: outer != null,
    ));
    if (bodyStart >= 0) {
      stack.add((fqcn, bodyEnd));
      // body brace is token kb: the '{' increments depth when visited later.
      bodyDepthStack.add(depth + 1);
    }
  }
  return NativeFile(f, text, t, package, classes);
}

List<String> _candidates(String q, String package, Map<String, String> explicit, List<String> wildcards) {
  final first = q.split('.').first;
  final rest = q.contains('.') ? q.substring(first.length) : '';
  final out = <String>[];
  // fully qualified as written (lower-case first segment = package)
  if (q.contains('.') && first[0].toLowerCase() == first[0]) out.add(q);
  if (explicit.containsKey(first)) out.add('${explicit[first]}$rest');
  if (package.isNotEmpty) out.add('$package.$q');
  for (final w in wildcards) {
    out.add('$w.$q');
  }
  if (package.isEmpty) out.add(q);
  return out;
}

/// All classes of a project, with inheritance queries.
class ClassIndex {
  ClassIndex(this.files) {
    for (final f in files) {
      for (final c in f.classes) {
        byFqcn.putIfAbsent(c.fqcn, () => c);
        all.add(c);
      }
    }
  }
  final List<NativeFile> files;
  final byFqcn = <String, NativeClass>{};
  final all = <NativeClass>[];

  /// Does [c] (transitively, through classes of this project) extend one of
  /// [roots] (fully-qualified names)?
  ///  true  = a chain of resolvable supertypes reaches a root
  ///  false = every supertype resolved to a project class or a non-root
  ///          and none leads to a root
  ///  null  = some supertype could not be resolved (library/unknown):
  ///          the answer is unknown, callers must not report an error.
  bool? extendsRoot(NativeClass c, Set<String> roots, [Set<String>? seen]) {
    seen ??= {};
    if (!seen.add(c.fqcn)) return false;
    var unknown = false;
    for (final s in c.supers) {
      final root = s.candidates.where(roots.contains).toList();
      if (root.isNotEmpty) {
        // A root name only counts when no project class shadows it.
        if (!s.candidates.any((x) => byFqcn.containsKey(x) && !roots.contains(x))) return true;
      }
      final hits = s.candidates.where(byFqcn.containsKey).toList();
      if (hits.isEmpty) {
        // Unresolved: a library class or an unsupported construct.
        unknown = true;
        continue;
      }
      for (final h in hits) {
        final r = extendsRoot(byFqcn[h]!, roots, seen);
        if (r == true) return true;
        if (r == null) unknown = true;
      }
    }
    return unknown ? null : false;
  }

  /// True when some other project class lists [c] among its supertypes.
  bool hasSubclass(NativeClass c) {
    for (final o in all) {
      if (identical(o, c)) continue;
      for (final s in o.supers) {
        if (s.candidates.contains(c.fqcn)) return true;
      }
    }
    return false;
  }
}
