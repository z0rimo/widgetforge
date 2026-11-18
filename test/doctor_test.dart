import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:widgettriage/widgettriage.dart';

Report doctor(String fixture) {
  final loaded = loadProjects(p.join('fixtures', fixture), (m) => fail(m));
  return runDoctor(loaded!.android, ios: loaded.ios, loadNotes: loaded.notes);
}

/// fixture -> the single diagnostic code it must produce.
const expected = {
  'err_receiver_not_registered': 'WF2001',
  'err_receiver_missing_update_action': 'WF2002',
  'err_receiver_missing_provider_meta': 'WF2003',
  'err_receiver_missing_exported': 'WF2004',
  'err_provider_xml_missing': 'WF3001',
  'err_provider_no_initial_layout': 'WF3002',
  'err_provider_layout_missing': 'WF3003',
  'err_configure_activity_unregistered': 'WF3004',
  'err_entrypoint_missing': 'WF4001',
  'err_entrypoint_no_pragma': 'WF4002',
  'err_activity_not_registered': 'WF4003',
  // iOS (WidgetKit extension) fixtures, one code each
  'err_ios_widget_not_embedded': 'WF5001',
  'err_ios_info_plist_wrong_extension_point': 'WF5002',
  'err_ios_info_plist_file_missing': 'WF5003',
  'err_ios_bundle_id_not_prefixed': 'WF5004',
  'err_ios_entitlements_file_missing': 'WF5005',
  'err_ios_app_group_mismatch': 'WF5006',
  'err_ios_no_main_entry': 'WF5007',
  'err_ios_deployment_target_below_14': 'WF5008',
};

String snapshot(String dir) {
  final files = Directory(dir).listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  return files.map((f) => '${f.path}:${f.lengthSync()}:${f.lastModifiedSync()}').join('\n');
}

void main() {
  test('healthy fixture has no diagnostics', () {
    final r = doctor('ok_basic');
    expect(r.diagnostics, isEmpty);
    expect(r.hasErrors, isFalse);
  });

  for (final e in expected.entries) {
    test('${e.key} -> ${e.value}', () {
      final r = doctor(e.key);
      expect(r.diagnostics.map((d) => d.code).toList(), [e.value]);
      final d = r.diagnostics.single;
      expect(d.file, isNotEmpty);
      expect(d.line, isNotNull);
      expect(d.evidence, isNotEmpty);
      expect(d.fix, isNotEmpty);
    });
  }

  test('unsupported views are all reported with line numbers', () {
    final d = doctor('err_unsupported_view').diagnostics;
    expect(d.map((x) => x.code).toSet(), {'WF1001'});
    expect(d.map((x) => x.evidence).toList(), [
      '<androidx.constraintlayout.widget.ConstraintLayout',
      '<ScrollView',
      '<EditText',
    ]);
    expect(d.map((x) => x.line).toList(), [2, 9, 12]);
  });

  test('WF1001 follows <include> into nested layouts', () {
    final d = doctor('err_unsupported_view_in_include').diagnostics.single;
    expect(d.code, 'WF1001');
    expect(d.file, endsWith('demo_widget_row.xml'));
    expect(d.evidence, contains('MaterialButton'));
  });

  test('doctor is read-only', () {
    final before = snapshot('fixtures');
    for (final d in Directory('fixtures').listSync().whereType<Directory>()) {
      doctor(p.basename(d.path));
    }
    expect(snapshot('fixtures'), before);
  });

  test('every fixture-expected code is in the rule catalog (full consistency: test/catalog_test.dart)', () {
    final catalog = jsonDecode(File('schema/rule-catalog.json').readAsStringSync()) as Map<String, dynamic>;
    final ids = (catalog['rules'] as List).map((r) => (r as Map)['id']).toSet();
    expect(ids, containsAll({...expected.values, 'WF1001'}));
  });

  group('CLI', () {
    ProcessResult run(List<String> args) =>
        Process.runSync('dart', ['run', 'bin/widgettriage.dart', ...args]);

    test('json output on error fixture, exit 1', () {
      final r = run(['doctor', '--json', 'fixtures/err_entrypoint_missing']);
      expect(r.exitCode, 1);
      final j = jsonDecode(r.stdout as String) as Map<String, dynamic>;
      expect(j['schemaVersion'], '1');
      expect(j['summary']['errors'], 1);
      expect(j['diagnostics'][0].keys.toSet(),
          {'code', 'severity', 'title', 'message', 'file', 'line', 'evidence', 'fix', 'docs'});
    });

    test('healthy project exit 0', () {
      expect(run(['doctor', 'fixtures/ok_basic']).exitCode, 0);
    });

    test('non-project directory exit 2', () {
      final r = run(['doctor', '--json', 'docs']);
      expect(r.exitCode, 2);
      expect(r.stderr, contains('pubspec.yaml'));
    });
  });
}
