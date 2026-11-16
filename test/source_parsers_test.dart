/// Unit tests for the small Kotlin/Java and Dart readers (lib/src/source).
/// They document what the readers deliberately do and do NOT understand.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:widgetforge/src/source/dart_source.dart';
import 'package:widgetforge/src/source/lexer.dart';
import 'package:widgetforge/src/source/native_source.dart';

late Directory tmp;

File write(String name, String text) {
  final f = File('${tmp.path}/$name')..writeAsStringSync(text);
  return f;
}

void main() {
  setUp(() => tmp = Directory.systemTemp.createTempSync('wf_src_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('lexer', () {
    test('comments are dropped, strings become one token, lines are kept', () {
      final t = tokenize('a // x "y"\n/* b /* nested */ c */ d "e f" \'g\'', Lang.kotlin);
      expect(t.map((x) => x.text).toList(), ['a', 'd', 'e f', 'g']);
      expect(t[1].line, 2);
    });
    test('Java block comments do not nest', () {
      final t = tokenize('a /* b /* c */ d */ e', Lang.java);
      expect(t.map((x) => x.text).toList(), ['a', 'd', '*', '/', 'e']);
    });
    test('raw and triple-quoted strings hide their content', () {
      final t = tokenize('x = """class A : B()""" ; y = r\'void f(){}\'', Lang.dart);
      expect(t.where((x) => x.kind == TokenKind.ident).map((x) => x.text), ['x', 'y']);
    });
  });

  group('Kotlin/Java classes', () {
    test('constructor arguments, generics, nested classes and Java extends', () {
      final f = write('A.kt', '''
package p.q

import android.appwidget.AppWidgetProvider
import a.b.*

class A<T : Any>(val x: Int, y: String = "z") : AppWidgetProvider(), Runnable {
    class Inner : AppWidgetProvider()
    val k = A::class
}
abstract class B : A<Int>(1, "")
''');
      final nf = parseNativeFile(f);
      final byName = {for (final c in nf.classes) c.name: c};
      expect(byName.keys, containsAll(['A', 'Inner', 'B']));
      expect(byName['A']!.fqcn, 'p.q.A');
      expect(byName['Inner']!.fqcn, r'p.q.A$Inner');
      expect(byName['B']!.isAbstract, isTrue);
      expect(byName['A']!.supers.map((s) => s.written), ['AppWidgetProvider', 'Runnable']);
      expect(byName['A']!.supers.first.candidates, contains('android.appwidget.AppWidgetProvider'));
      expect(nf.classes.length, 3, reason: '`A::class` is not a declaration');
    });
    test('Java class literal and implements list', () {
      final f = write('J.java', '''
package p;
public abstract class J extends Base implements X, Y {
  Class<?> c = J.class;
}
''');
      final c = parseNativeFile(f).classes.single;
      expect(c.isAbstract, isTrue);
      expect(c.supers.map((s) => s.written), ['Base', 'X', 'Y']);
    });
    test('unresolvable supertype yields an unknown (null) answer, never false', () {
      final a = write('U.kt', 'package p\nimport lib.Unknown\nclass U : Unknown()\n');
      final idx = ClassIndex([parseNativeFile(a)]);
      expect(idx.extendsRoot(idx.all.single, {'android.appwidget.AppWidgetProvider'}), isNull);
    });
    test('a project class shadowing a root name is not the root', () {
      final a = write('S.kt', 'package p\nclass AppWidgetProvider\nclass S : AppWidgetProvider()\n');
      final idx = ClassIndex([parseNativeFile(a)]);
      final s = idx.all.firstWhere((c) => c.name == 'S');
      expect(idx.extendsRoot(s, {'p.AppWidgetProvider'}), isTrue,
          reason: 'only the same fully-qualified name counts');
      expect(idx.extendsRoot(s, {'android.appwidget.AppWidgetProvider'}), isFalse);
    });
  });

  group('Dart top-level functions', () {
    List<DartFunction> parse(String src) => parseDartTopLevelFunctions(write('x.dart', src));

    test('pragma on the same line, with comments and blank lines in between', () {
      final fns = parse('''
@pragma('vm:entry-point') void a() {}

@pragma('vm:entry-point')

// comment

/// doc
Future<void> b() async {}

@pragma("vm:entry-point", true)
void c() => 1;

@pragma('vm:entry-point', false)
void d() {}

void e() {}
''');
      final m = {for (final f in fns) f.name: f.hasEntryPointPragma};
      expect(m, {'a': true, 'b': true, 'c': true, 'd': false, 'e': false});
    });
    test('only top-level functions: methods, variables and comments are ignored', () {
      final fns = parse('''
// void commented() {}
const s = \'\'\'
void inString() {}
\'\'\';
final x = compute();
class K { static void method() {} }
void real() {}
''');
      expect(fns.map((f) => f.name), ['real']);
    });
    test('reports the declaration line', () {
      final fns = parse('\n\n@pragma(\'vm:entry-point\')\nvoid w() {}\n');
      expect(fns.single.line, 4);
    });
  });
}
