/// A deliberately small lexer shared by the Kotlin/Java and Dart readers.
///
/// It is NOT a language implementation. It only separates what the checks need
/// to tell apart: comments (dropped), string literals (one token, content kept),
/// identifiers and single-character punctuation. Anything the checks cannot
/// interpret is left for the caller to treat as "unknown", never as an error.
library;

enum TokenKind { ident, str, punct, other }

class Token {
  Token(this.kind, this.text, this.offset, this.line, this.end);
  final TokenKind kind;

  /// Identifier/punctuation text, or the string literal CONTENT (without quotes).
  final String text;
  final int offset;
  final int line;
  final int end; // offset just past the token in the original text

  bool is_(String s) => kind != TokenKind.str && text == s;
  @override
  String toString() => '$kind($text)@$line';
}

enum Lang { kotlin, java, dart }

/// Tokenizes [src]. Comments are skipped, string literals become one [Token]
/// of kind `str`. Offsets and line numbers refer to the original [src].
List<Token> tokenize(String src, Lang lang) {
  final out = <Token>[];
  final n = src.length;
  var i = 0;
  var line = 1;
  final nestedComments = lang != Lang.java;
  final singleQuoteIsString = lang == Lang.dart;

  bool isIdStart(int c) =>
      (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36 || c > 127;
  bool isDigit(int c) => c >= 48 && c <= 57;

  while (i < n) {
    final c = src.codeUnitAt(i);
    if (c == 10) {
      line++;
      i++;
      continue;
    }
    if (c == 32 || c == 9 || c == 13) {
      i++;
      continue;
    }
    // comments
    if (c == 47 /* / */ && i + 1 < n) {
      final d = src.codeUnitAt(i + 1);
      if (d == 47) {
        while (i < n && src.codeUnitAt(i) != 10) {
          i++;
        }
        continue;
      }
      if (d == 42) {
        var depth = 1;
        i += 2;
        while (i < n && depth > 0) {
          final x = src.codeUnitAt(i);
          if (x == 10) line++;
          if (x == 47 && i + 1 < n && src.codeUnitAt(i + 1) == 42 && nestedComments) {
            depth++;
            i += 2;
          } else if (x == 42 && i + 1 < n && src.codeUnitAt(i + 1) == 47) {
            depth--;
            i += 2;
          } else {
            i++;
          }
        }
        continue;
      }
    }
    // Dart raw string prefix r'..' / r".."
    var raw = false;
    var start = i;
    var q = c;
    if (lang == Lang.dart && c == 114 /* r */ && i + 1 < n) {
      final d = src.codeUnitAt(i + 1);
      if (d == 39 || d == 34) {
        raw = true;
        i++;
        q = d;
      }
    }
    final isQuote = q == 34 || (q == 39);
    if (isQuote && (i == start || raw)) {
      // Kotlin/Java single quote = char literal: treat like a (short) string.
      final triple = i + 2 < n &&
          src.codeUnitAt(i + 1) == q &&
          src.codeUnitAt(i + 2) == q &&
          (q == 34 || singleQuoteIsString);
      final startLine = line;
      final tokStart = start;
      final buf = StringBuffer();
      if (triple) {
        i += 3;
        while (i < n) {
          final x = src.codeUnitAt(i);
          if (x == q &&
              i + 2 < n &&
              src.codeUnitAt(i + 1) == q &&
              src.codeUnitAt(i + 2) == q) {
            i += 3;
            break;
          }
          if (x == 10) line++;
          if (x == 92 && !raw && i + 1 < n) {
            buf.writeCharCode(src.codeUnitAt(i + 1));
            i += 2;
            continue;
          }
          buf.writeCharCode(x);
          i++;
        }
      } else {
        i++;
        while (i < n) {
          final x = src.codeUnitAt(i);
          if (x == q) {
            i++;
            break;
          }
          if (x == 10 && q == 39 && !singleQuoteIsString) break; // stray quote
          if (x == 10) line++;
          if (x == 92 && !raw && i + 1 < n) {
            buf.writeCharCode(src.codeUnitAt(i + 1));
            i += 2;
            continue;
          }
          buf.writeCharCode(x);
          i++;
        }
      }
      out.add(Token(TokenKind.str, buf.toString(), tokStart, startLine, i));
      continue;
    }
    i = start;
    if (isIdStart(c)) {
      var j = i + 1;
      while (j < n) {
        final x = src.codeUnitAt(j);
        if (isIdStart(x) || isDigit(x)) {
          j++;
        } else {
          break;
        }
      }
      out.add(Token(TokenKind.ident, src.substring(i, j), i, line, j));
      i = j;
      continue;
    }
    if (c == 96 /* ` */) {
      final j = src.indexOf('`', i + 1);
      if (j > 0) {
        out.add(Token(TokenKind.ident, src.substring(i + 1, j), i, line, j + 1));
        i = j + 1;
        continue;
      }
    }
    if (isDigit(c)) {
      var j = i + 1;
      while (j < n) {
        final x = src.codeUnitAt(j);
        if (isIdStart(x) || isDigit(x) || x == 46) {
          j++;
        } else {
          break;
        }
      }
      out.add(Token(TokenKind.other, src.substring(i, j), i, line, j));
      i = j;
      continue;
    }
    out.add(Token(TokenKind.punct, src[i], i, line, i + 1));
    i++;
  }
  return out;
}

/// Index of the token matching the opener at [open] (`(`/`[`/`{`/`<`), or -1.
/// `<` is only balanced against `>` (callers use it for type arguments).
int matching(List<Token> t, int open) {
  const pairs = {'(': ')', '[': ']', '{': '}', '<': '>'};
  final o = t[open].text;
  final c = pairs[o]!;
  var depth = 0;
  for (var k = open; k < t.length; k++) {
    if (t[k].kind != TokenKind.punct) continue;
    if (t[k].text == o) depth++;
    if (t[k].text == c) {
      depth--;
      if (depth == 0) return k;
    }
    if (o == '<' && (t[k].text == '{' || t[k].text == ';')) return -1;
  }
  return -1;
}
