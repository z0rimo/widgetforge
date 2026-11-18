/// iOS WidgetKit checks (WF5001-WF5008): positive, negative and boundary
/// fixtures, exact code/file/line/evidence, notes, platform combinations,
/// parsers and the CLI contract for iOS projects.
///
/// Evidence level: static analysis only. None of this was verified with Xcode,
/// a simulator or a device.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:widgettriage/src/ios/pbxproj.dart';
import 'package:widgettriage/src/ios/plist.dart';
import 'package:widgettriage/widgettriage.dart';

Report doctor(String fixture) {
  final loaded = loadProjects(p.join('fixtures', fixture), (m) => fail(m));
  return runDoctor(loaded!.android, ios: loaded.ios, loadNotes: loaded.notes);
}

class Expect {
  const Expect(this.code, this.file, this.line, this.evidence);
  final String code;
  final String file;
  final int line;
  final String evidence;
}

const pbx = 'ios/Runner.xcodeproj/project.pbxproj';

const negatives = <String, List<Expect>>{
  'err_ios_widget_not_embedded': [Expect('WF5001', pbx, 255, 'product not embedded by Runner')],
  'err_ios_info_plist_wrong_extension_point': [
    Expect('WF5002', 'ios/WidgetExt/Info.plist', 7, 'NSExtensionPointIdentifier = com.apple.share-services')
  ],
  'err_ios_info_plist_missing_nsextension': [
    Expect('WF5002', 'ios/WidgetExt/Info.plist', 1, 'NSExtension/NSExtensionPointIdentifier missing')
  ],
  'err_ios_info_plist_file_missing': [Expect('WF5003', pbx, 231, 'INFOPLIST_FILE = WidgetExt/Info.plist')],
  'err_ios_bundle_id_not_prefixed': [Expect('WF5004', pbx, 227, 'com.example.otherwidget (host: com.example.demo')],
  'err_ios_bundle_id_prefix_without_dot': [Expect('WF5004', pbx, 227, 'com.example.demowidget (host: com.example.demo')],
  // variables resolved through the xcconfig files: the finding carries the RESOLVED values
  'err_ios_variable_resolved_bundle_mismatch': [Expect('WF5004', pbx, 229, 'com.example.other.widget (host: com.example.demo')],
  'err_ios_entitlements_file_missing': [
    Expect('WF5005', pbx, 232, 'CODE_SIGN_ENTITLEMENTS = WidgetExt/WidgetExt.entitlements (Debug, Release)')
  ],
  'err_ios_app_group_mismatch': [
    Expect('WF5006', pbx, 232, 'extension {group.com.example.other} vs app {group.com.example.demo}')
  ],
  'err_ios_swift_group_not_entitled': [
    Expect('WF5006', 'ios/WidgetExt/WidgetExt.swift', 12, 'suiteName: "group.com.example.demo"')
  ],
  'err_ios_no_main_entry': [Expect('WF5007', pbx, 256, 'no @main in ios/WidgetExt/WidgetExt.swift')],
  // Xcode 16 folder-based target: the file holding @main is a membership exception, so it is not compiled into the target
  'err_ios_synchronized_folder_main_excluded': [Expect('WF5007', pbx, 262, 'no @main in ios/WidgetExt/WidgetExt.swift')],
  'err_ios_main_only_in_comment_or_string': [Expect('WF5007', pbx, 256, 'no @main')],
  'err_ios_deployment_target_below_14': [Expect('WF5008', pbx, 228, 'IPHONEOS_DEPLOYMENT_TARGET = 13.0 (Debug, Release)')],
  // Target-specific build setting difference: only Release is low.
  'err_ios_release_only_deployment_target': [Expect('WF5008', pbx, 240, 'IPHONEOS_DEPLOYMENT_TARGET = 13.0 (Release)')],
};

void main() {
  final fixtures = Directory('fixtures').listSync().whereType<Directory>().map((d) => p.basename(d.path)).toList()..sort();

  group('positive iOS fixtures produce no diagnostics', () {
    final oks = fixtures.where((f) => f.startsWith('ok_ios_') || f == 'ok_android_ios_project').toList();
    test('expected set exists', () => expect(oks.length, greaterThanOrEqualTo(9)));
    for (final f in oks) {
      test(f, () => expect(doctor(f).diagnostics, isEmpty));
    }
  });

  group('negative iOS fixtures: exact code, file, line, evidence', () {
    for (final e in negatives.entries) {
      test(e.key, () {
        final d = doctor(e.key).diagnostics;
        expect(d.length, e.value.length, reason: '${d.map((x) => '${x.code}@${x.file}:${x.line}').toList()}');
        for (var i = 0; i < d.length; i++) {
          expect(d[i].code, e.value[i].code);
          expect(d[i].file, e.value[i].file);
          expect(d[i].line, e.value[i].line);
          expect(d[i].evidence, contains(e.value[i].evidence));
          expect(d[i].fix, isNotEmpty);
          expect(d[i].docs, 'docs/errors/${d[i].code}.md');
        }
      });
    }
  });

  group('notes (unknown or not applicable is never a finding)', () {
    bool has(String f, String s) => doctor(f).notes.any((n) => n.contains(s));
    test('iOS app without a widget: note, no diagnostics', () {
      final r = doctor('ok_ios_no_widget_extension');
      expect(r.diagnostics, isEmpty);
      expect(has('ok_ios_no_widget_extension', 'no WidgetKit extension target'), isTrue);
    });
    test('an extension that is not a widget (share extension) is not judged', () {
      expect(doctor('ok_ios_other_extension_not_widget').diagnostics, isEmpty);
      expect(has('ok_ios_other_extension_not_widget', 'no WidgetKit extension target'), isTrue);
    });
    test('unresolvable build settings: notes only', () {
      final r = doctor('ok_ios_unresolved_setting');
      expect(r.diagnostics, isEmpty);
      expect(has('ok_ios_unresolved_setting', 'PRODUCT_BUNDLE_IDENTIFIER'), isTrue);
      expect(has('ok_ios_unresolved_setting', 'IPHONEOS_DEPLOYMENT_TARGET'), isTrue);
      // The note names only the target whose setting is unresolved.
      expect(has('ok_ios_unresolved_setting', 'PRODUCT_BUNDLE_IDENTIFIER of "WidgetExt" ('), isTrue);
    });
    test('xcconfig variables are resolved (no note, no finding)', () {
      final r = doctor('ok_ios_build_setting_variables');
      expect(r.diagnostics, isEmpty);
      expect(r.notes, isEmpty);
    });
    test('a widget without any App Group is accepted', () {
      final r = doctor('ok_ios_widget_without_app_group');
      expect(r.diagnostics, isEmpty);
      expect(r.notes, isEmpty);
    });
  });

  group('platform combinations', () {
    test('Android-only project: unchanged checks, no iOS check or note', () {
      final r = doctor('ok_basic');
      expect(r.checksRun, ['manifest-receivers', 'provider-xml', 'remoteviews-supported-views', 'flutter-activity-entrypoint']);
      expect(r.notes, isEmpty);
    });
    test('iOS-only project: only the iOS check runs', () {
      expect(doctor('ok_ios_widget_basic').checksRun, ['ios-widget-extension']);
    });
    test('combined project runs both and reports each platform', () {
      final ok = doctor('ok_android_ios_project');
      expect(ok.checksRun.length, 5);
      expect(ok.diagnostics, isEmpty);
      final bad = doctor('err_android_ios_both_platforms');
      expect(bad.diagnostics.map((d) => d.code).toList(), ['WF2004', 'WF5008']);
    });
    test('a directory with pubspec.yaml but no platform project is not analyzable', () {
      final tmp = Directory.systemTemp.createTempSync('wf_nop_');
      File(p.join(tmp.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');
      String? err;
      final r = loadProjects(tmp.path, (m) => err = m);
      tmp.deleteSync(recursive: true);
      expect(r, isNull);
      expect(err, contains('ios/*.xcodeproj'));
    });
    test('target line points at the PBXNativeTarget, not at a same-named PBXGroup defined earlier', () {
      for (final commented in [true, false]) {
        final tmp = Directory.systemTemp.createTempSync('wf_line_');
        const src = 'fixtures/err_ios_no_main_entry';
        Directory(src).listSync(recursive: true).whereType<File>().forEach((f) {
          File(p.join(tmp.path, p.relative(f.path, from: src)))
            ..createSync(recursive: true)
            ..writeAsBytesSync(f.readAsBytesSync());
        });
        final pbx = File(p.join(tmp.path, 'ios/Runner.xcodeproj/project.pbxproj'));
        const decl = '\t\t00000000000000000000000B = {\n\t\t\tisa = PBXNativeTarget;';
        var text = pbx.readAsStringSync();
        expect(text, contains(decl));
        final label = commented ? ' /* WidgetExt */' : '';
        const group = '\t\t0000000000000000000000FE /* WidgetExt */ = {\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n\t\t\t);\n'
            '\t\t\tname = WidgetExt;\n\t\t\tsourceTree = "<group>";\n\t\t};\n';
        text = text.replaceFirst(decl, '$group\t\t00000000000000000000000B$label = {\n\t\t\tisa = PBXNativeTarget;');
        pbx.writeAsStringSync(text);
        final lines = text.split('\n');
        final expected = lines.indexWhere((l) => l.contains('00000000000000000000000B')) + 1;
        final groupLine = lines.indexWhere((l) => l.contains('0000000000000000000000FE')) + 1;
        expect(groupLine, lessThan(expected));
        final loaded = loadProjects(tmp.path, (m) => fail(m))!;
        final r = runDoctor(loaded.android, ios: loaded.ios, loadNotes: loaded.notes);
        tmp.deleteSync(recursive: true);
        final d = r.diagnostics.single;
        expect(d.code, 'WF5007');
        expect(d.line, expected, reason: 'commented=$commented');
      }
    });
    test('an unparseable pbxproj is reported as not analyzed, Android results survive', () {
      final tmp = Directory.systemTemp.createTempSync('wf_bad_');
      Directory('fixtures/ok_basic').listSync(recursive: true).whereType<File>().forEach((f) {
        final dest = File(p.join(tmp.path, p.relative(f.path, from: 'fixtures/ok_basic')))..createSync(recursive: true);
        f.copySync(dest.path);
      });
      File(p.join(tmp.path, 'ios/Runner.xcodeproj/project.pbxproj'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{ objects = ( ;');
      final loaded = loadProjects(tmp.path, (m) => fail(m))!;
      final r = runDoctor(loaded.android, ios: loaded.ios, loadNotes: loaded.notes);
      tmp.deleteSync(recursive: true);
      expect(loaded.ios, isNull);
      expect(r.diagnostics, isEmpty);
      expect(r.notes.single, contains('could not be parsed'));
      expect(r.checksRun, isNot(contains('ios-widget-extension')));
    });
  });

  group('parsers', () {
    test('ASCII plist: comments, quoted strings, arrays, nested dictionaries', () {
      final v = parseAsciiPlist('''
// !\$*UTF8*\$!
{ a = 1; /* c */ "b c" = "x \\"y\\""; list = ( one, "two", ); d = { k = v; }; }
''') as Map<String, Object>;
      expect(v['a'], '1');
      expect(v['b c'], 'x "y"');
      expect(v['list'], ['one', 'two']);
      expect((v['d'] as Map)['k'], 'v');
    });
    test('malformed ASCII plist throws FormatException', () {
      expect(() => parseAsciiPlist('{ a = ( ;'), throwsFormatException);
      expect(() => parseAsciiPlist('{ a = 1'), throwsFormatException);
    });
    test('xcconfig: includes and settings, comments removed', () {
      final r = parseXcconfig('#include "A.xcconfig"\nFOO = bar // c\n// BAZ = 1\n');
      expect(r.includes, ['A.xcconfig']);
      expect(r.settings, {'FOO': 'bar'});
    });
    test('XML plist and binary plist handling', () {
      expect((parsePlistXml('<plist version="1.0"><dict><key>k</key><array><string>g</string></array></dict></plist>') as Map)['k'], ['g']);
      final f = File('${Directory.systemTemp.path}/wf_b.plist')..writeAsBytesSync([...'bplist00'.codeUnits, 0]);
      expect(() => readPlistFile(f), throwsFormatException);
      f.deleteSync();
    });
  });

  group('CLI contract for iOS projects', () {
    ProcessResult run(List<String> a) => Process.runSync('dart', ['run', 'bin/widgettriage.dart', ...a]);
    test('iOS-only error project: exit 1, single JSON document, empty stderr', () {
      final r = run(['doctor', '--json', p.absolute('fixtures', 'err_ios_widget_not_embedded')]);
      expect(r.exitCode, 1);
      expect(r.stderr, isEmpty);
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      expect(j['schemaVersion'], '1');
      expect((j['diagnostics'] as List).single['code'], 'WF5001');
    });
    test('iOS-only healthy project: exit 0', () {
      final r = run(['doctor', '--json', p.absolute('fixtures', 'ok_ios_widget_basic')]);
      expect(r.exitCode, 0);
      expect((jsonDecode(r.stdout as String) as Map)['summary']['errors'], 0);
    });
    test('read-only: iOS fixtures are not modified', () {
      String snap() => (Directory('fixtures').listSync(recursive: true).whereType<File>().toList()
            ..sort((a, b) => a.path.compareTo(b.path)))
          .map((f) => '${f.path}:${f.lengthSync()}:${f.lastModifiedSync()}')
          .join('\n');
      final before = snap();
      for (final f in fixtures.where((f) => f.contains('ios'))) {
        doctor(f);
      }
      expect(snap(), before);
    });
  });
}
