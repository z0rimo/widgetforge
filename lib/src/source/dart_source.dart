/// Minimal Dart reader: finds TOP-LEVEL function declarations together with
/// the annotations attached to them. Declaration-based, not line-distance
/// based: comments, blank lines and same-line annotations do not matter.
///
/// Not handled: `part`/`part of` merging, conditional exports, generated
/// code. Anything not recognized as a top-level function is simply absent.
library;

import 'dart:io';

import 'lexer.dart';

class DartFunction {
  DartFunction(this.file, this.name, this.line, this.annotations, this.hasEntryPointPragma);
  final File file;
  final String name;
  final int line;
  final List<String> annotations;

  /// `@pragma('vm:entry-point')` or `@pragma('vm:entry-point', true)`.
  final bool hasEntryPointPragma;
}

const _declKeywords = {
  'class', 'mixin', 'enum', 'extension', 'typedef', 'import', 'export', 'part',
  'library', 'abstract', 'base', 'sealed', 'interface', 'final', 'const', 'var',
  'late', 'static',
};

List<DartFunction> parseDartTopLevelFunctions(File f) {
  final t = tokenize(f.readAsStringSync(), Lang.dart);
  final out = <DartFunction>[];
  var i = 0;
  while (i < t.length) {
    // --- one top-level item: annotations, then the declaration ---
    final annotations = <String>[];
    var pragma = false;
    while (i < t.length && t[i].is_('@')) {
      var k = i + 1;
      final nameParts = <String>[];
      while (k < t.length && t[k].kind == TokenKind.ident) {
        nameParts.add(t[k].text);
        k++;
        if (k < t.length && t[k].is_('.')) {
          k++;
          continue;
        }
        break;
      }
      final name = nameParts.join('.');
      var args = <Token>[];
      if (k < t.length && t[k].is_('(')) {
        final e = matching(t, k);
        if (e < 0) {
          k = t.length;
        } else {
          args = t.sublist(k + 1, e);
          k = e + 1;
        }
      }
      annotations.add(name);
      if (name == 'pragma' &&
          args.isNotEmpty &&
          args.first.kind == TokenKind.str &&
          args.first.text == 'vm:entry-point') {
        // Second argument (if present) must not be `false`.
        final second = args.length >= 3 && args[1].is_(',') ? args[2] : null;
        if (second == null || !(second.kind == TokenKind.ident && second.text == 'false')) {
          pragma = true;
        }
      }
      i = k;
    }
    if (i >= t.length) break;

    // --- scan the item up to its end (';' or the '}' closing a body) ---
    final itemStart = i;
    var depth = 0;
    var firstParen = -1;
    var sawEquals = false;
    var j = i;
    var ended = false;
    while (j < t.length && !ended) {
      final x = t[j];
      if (x.kind == TokenKind.punct) {
        switch (x.text) {
          case '(':
            if (depth == 0 && firstParen < 0 && !sawEquals) firstParen = j;
            final e = matching(t, j);
            j = e < 0 ? t.length : e + 1;
            continue;
          case '[':
            final e = matching(t, j);
            j = e < 0 ? t.length : e + 1;
            continue;
          case '{':
            final e = matching(t, j);
            j = e < 0 ? t.length : e + 1;
            if (!sawEquals) ended = true;
            continue;
          case '=':
            // `=>` arrow body is part of a function; plain `=` is an initializer.
            if (!(j + 1 < t.length && t[j + 1].is_('>'))) {
              if (firstParen < 0) sawEquals = true;
            }
            break;
          case ';':
            ended = true;
            j++;
            continue;
        }
      }
      j++;
    }

    if (firstParen > itemStart &&
        t[firstParen - 1].kind == TokenKind.ident &&
        !sawEquals &&
        !_declKeywords.contains(t[itemStart].text)) {
      final name = t[firstParen - 1];
      // A function is `[Type] name (...) {` / `=>` / `async` / `;`(external).
      // Everything before the name must be type-ish tokens.
      var typeish = true;
      for (var k = itemStart; k < firstParen - 1; k++) {
        final y = t[k];
        if (y.kind == TokenKind.ident) continue;
        if (y.kind == TokenKind.punct && (y.text == '<' || y.text == '>' || y.text == ',' || y.text == '?' || y.text == '.')) continue;
        typeish = false;
        break;
      }
      // Keywords such as `if`, `return` can only appear inside bodies, which we skip.
      if (typeish) {
        out.add(DartFunction(f, name.text, name.line, annotations, pragma));
      }
    }
    i = j > i ? j : i + 1;
  }
  return out;
}

/// URIs of `import`/`export`/`part` directives (string literals only; every
/// URI of a conditional directive is returned). `part of` is ignored.
List<String> parseDartDirectives(File f) {
  final t = tokenize(f.readAsStringSync(), Lang.dart);
  final out = <String>[];
  for (var i = 0; i < t.length; i++) {
    final x = t[i];
    if (x.kind != TokenKind.ident || !(x.text == 'import' || x.text == 'export' || x.text == 'part')) continue;
    if (i > 0 && !(t[i - 1].is_(';') || t[i - 1].is_('}') || t[i - 1].is_(')'))) continue;
    if (i + 1 < t.length && t[i + 1].kind == TokenKind.ident && t[i + 1].text == 'of') continue;
    for (var k = i + 1; k < t.length && !t[k].is_(';'); k++) {
      if (t[k].kind == TokenKind.str) out.add(t[k].text);
    }
  }
  return out;
}

/// Files of this project reachable from [root] through import/export/part
/// directives with relative or `package:<packageName>/` URIs. `complete` is
/// false when a directive of this project could not be resolved to a file
/// (so the answer "not reachable" would not be trustworthy).
({Set<String> files, bool complete}) reachableDartFiles(File root, String libDir, String? packageName) {
  final seen = <String>{};
  var complete = true;
  final queue = [root];
  while (queue.isNotEmpty) {
    final f = queue.removeLast();
    if (!seen.add(f.absolute.path)) continue;
    for (final uri in parseDartDirectives(f)) {
      File? target;
      if (uri.startsWith('dart:')) continue;
      if (uri.startsWith('package:')) {
        final pre = packageName == null ? null : 'package:$packageName/';
        if (pre == null || !uri.startsWith(pre)) continue; // another package
        target = File('$libDir/${uri.substring(pre.length)}');
      } else if (uri.contains(':')) {
        continue; // unsupported scheme
      } else {
        target = File(Uri.file(f.parent.path + Platform.pathSeparator).resolve(uri).toFilePath());
      }
      if (target.existsSync()) {
        queue.add(target);
      } else {
        complete = false;
      }
    }
  }
  return (files: seen, complete: complete);
}
