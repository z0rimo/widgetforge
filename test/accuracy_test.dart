/// Regression tests for the accuracy audit (false positives / false negatives)
/// of WF1001, WF2001, WF4001, WF4002 and WF4003.
///
/// Every `ok_*` fixture is a configuration that previously produced (or could
/// produce) a false positive and must stay clean. Every entry in [negatives]
/// asserts the exact code, file, line and evidence of the finding, so a test
/// cannot pass by reporting the right code at the wrong place.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:widgettriage/widgettriage.dart';

Report doctor(String fixture) {
  final loaded = loadProjects(p.join('fixtures', fixture), (m) => fail(m));
  return runDoctor(loaded!.android, ios: loaded.ios, loadNotes: loaded.notes);
}

class Expect {
  const Expect(this.code, this.file, this.line, this.evidence);
  final String code;
  final String file; // path suffix
  final int line;
  final String evidence; // substring
}

const k = 'android/app/src/main/kotlin/com/example/';
const res = 'android/app/src/main/res/layout/';

const negatives = <String, List<Expect>>{
  // WF2001 -- false negatives that were reproduced before the fix
  'err_provider_ctor_args': [
    Expect('WF2001', '${k}demo/DemoWidgetProvider.kt', 5, 'class DemoWidgetProvider(private val label'),
  ],
  'err_provider_indirect_subclass': [
    Expect('WF2001', '${k}demo/DemoWidgetProvider.kt', 7, 'class DemoWidgetProvider : BaseProvider()'),
  ],
  'err_provider_same_name_other_package': [
    Expect('WF2001', '${k}other/DemoWidgetProvider.kt', 5, 'class DemoWidgetProvider : AppWidgetProvider()'),
  ],
  // WF4001 / WF4002 / WF4003
  'err_entrypoint_library_uri_function_elsewhere': [
    Expect('WF4001', '${k}demo/WidgetActivity.kt', 6, 'getDartEntrypointFunctionName() -> "widgetMain"'),
  ],
  'err_entrypoint_manifest_meta_missing': [
    Expect('WF4001', 'android/app/src/main/AndroidManifest.xml', 13, 'io.flutter.Entrypoint'),
  ],
  'err_entrypoint_only_in_comment': [
    Expect('WF4001', '${k}demo/WidgetActivity.kt', 6, '"widgetMain"'),
  ],
  'err_entrypoint_two_activities_one_file': [
    // exactly one finding: PlainActivity (no override) must not be blamed,
    // and the three activities share one declaration.
    Expect('WF4002', 'lib/main.dart', 5, 'widgetMain() without @pragma'),
  ],
  // source sets / targetSdk / configure activity (pre-release gate)
  'err_receiver_debug_only_missing_exported': [
    Expect('WF2004', 'android/app/src/debug/AndroidManifest.xml', 3, '<receiver android:name=".DemoWidgetProvider">'),
  ],
  'err_receiver_debug_only_unsupported_view': [
    Expect('WF1001', '${res}demo_widget.xml', 5, '<ScrollView'),
  ],
  'err_receiver_target_sdk_31': [
    Expect('WF2004', 'android/app/src/main/AndroidManifest.xml', 12, '<receiver android:name=".DemoWidgetProvider">'),
  ],
  'err_configure_activity_same_name_other_package': [
    Expect('WF3004', 'android/app/src/main/res/xml/demo_widget_info.xml', 9, 'com.example.other.WidgetConfigActivity'),
  ],
  // WF1001
  'err_remoteviews_space_view': [
    Expect('WF1001', '${res}demo_widget.xml', 5, '<Space'),
    Expect('WF1001', '${res}demo_widget.xml', 6, '<View'),
  ],
  'err_remoteviews_viewstub_layout': [
    Expect('WF1001', '${res}stub_bad.xml', 5, '<EditText'),
  ],
  'err_remoteviews_subclass_and_comment': [
    Expect('WF1001', '${res}demo_widget.xml', 7, '<androidx.appcompat.widget.AppCompatTextView'),
    Expect('WF1001', '${res}demo_widget.xml', 10, '<view class="androidx.cardview.widget.CardView"'),
  ],
};

List<Map<String, dynamic>> diagnosticsJson(String fixture) =>
    (doctor(fixture).toJson()['diagnostics'] as List).cast<Map<String, dynamic>>();

/// Validates [value] against the subset of JSON Schema the report schema uses
/// (type, const, enum, pattern, required, properties, additionalProperties, items, minimum).
List<String> validate(Object? value, Map<String, dynamic> schema, String at) {
  final errs = <String>[];
  if (schema.containsKey('const') && value != schema['const']) errs.add('$at: const');
  if (schema.containsKey('enum') && !(schema['enum'] as List).contains(value)) errs.add('$at: enum $value');
  final type = schema['type'];
  if (type != null) {
    final types = type is List ? type.cast<String>() : [type as String];
    bool ok(String t) => switch (t) {
          'object' => value is Map,
          'array' => value is List,
          'string' => value is String,
          'integer' => value is int,
          'null' => value == null,
          _ => true,
        };
    if (!types.any(ok)) errs.add('$at: type $types, got ${value.runtimeType}');
  }
  if (schema.containsKey('pattern') && value is String && !RegExp(schema['pattern'] as String).hasMatch(value)) {
    errs.add('$at: pattern');
  }
  if (schema.containsKey('minimum') && value is num && value < (schema['minimum'] as num)) {
    errs.add('$at: minimum');
  }
  if (value is Map) {
    for (final r in (schema['required'] as List? ?? const [])) {
      if (!value.containsKey(r)) errs.add('$at: missing $r');
    }
    final props = (schema['properties'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final e in value.entries) {
      if (props.containsKey(e.key)) {
        errs.addAll(validate(e.value, props[e.key] as Map<String, dynamic>, '$at.${e.key}'));
      } else if (schema['additionalProperties'] == false) {
        errs.add('$at: unexpected ${e.key}');
      }
    }
  }
  if (value is List && schema['items'] != null) {
    for (var i = 0; i < value.length; i++) {
      errs.addAll(validate(value[i], schema['items'] as Map<String, dynamic>, '$at[$i]'));
    }
  }
  return errs;
}

void main() {
  final fixtures = Directory('fixtures')
      .listSync()
      .whereType<Directory>()
      .map((d) => p.basename(d.path))
      .toList()
    ..sort();

  group('positive fixtures stay clean (previous or potential false positives)', () {
    final oks = fixtures.where((f) => f.startsWith('ok_')).toList();
    test('the expected set of ok_ fixtures exists', () {
      expect(oks.length, greaterThanOrEqualTo(25));
    });
    for (final f in oks) {
      test(f, () => expect(doctor(f).diagnostics, isEmpty));
    }
  });

  group('negative fixtures report the exact code, file, line and evidence', () {
    for (final e in negatives.entries) {
      test(e.key, () {
        final d = doctor(e.key).diagnostics;
        expect(d.length, e.value.length,
            reason: 'unexpected findings: ${d.map((x) => '${x.code}@${x.file}:${x.line}').toList()}');
        for (var i = 0; i < d.length; i++) {
          final want = e.value[i];
          expect(d[i].code, want.code);
          expect(d[i].file, endsWith(want.file));
          expect(d[i].line, want.line);
          expect(d[i].evidence, contains(want.evidence));
          expect(d[i].fix, isNotEmpty);
        }
      });
    }
  });

  group('every fixture report validates against the unchanged JSON schema', () {
    final schema = jsonDecode(File('schema/diagnostic-report.schema.json').readAsStringSync())
        as Map<String, dynamic>;
    for (final f in fixtures) {
      test(f, () {
        final json = jsonDecode(jsonEncode(doctor(f).toJson()));
        expect(validate(json, schema, r'$'), isEmpty);
      });
    }
  });

  group('golden diagnostics (project path removed)', () {
    // Goldens were generated from reviewed output (lines checked against the
    // fixture sources). To update: print the `diagnostics` array of
    // `dart run bin/widgettriage.dart doctor --json fixtures/<name>` into
    // test/golden/<name>.json and review the diff.
    for (final f in ['err_provider_indirect_subclass', 'err_entrypoint_two_activities_one_file', 'err_remoteviews_subclass_and_comment']) {
      test(f, () {
        final golden = jsonDecode(File('test/golden/$f.json').readAsStringSync());
        expect(jsonDecode(jsonEncode(diagnosticsJson(f))), golden);
      });
    }
  });

  group('notes carry the unverifiable / variant-dependent statements', () {
    List<String> notes(String f) => doctor(f).notes;
    bool has(String f, String needle) => notes(f).any((n) => n.contains(needle));

    test('receiver only in a non-main source set: no finding, note names the file', () {
      expect(doctor('ok_receiver_debug_only_manifest').diagnostics, isEmpty);
      expect(has('ok_receiver_debug_only_manifest', 'declared only in android/app/src/debug/AndroidManifest.xml'), isTrue);
      expect(has('ok_receiver_debug_only_manifest', 'does not select a build variant'), isTrue);
    });
    test('receiver declared in main is not annotated', () {
      expect(notes('ok_basic'), isEmpty);
    });
    test('tools:node=remove in another source set is a note, not a registration', () {
      expect(has('ok_receiver_removed_in_debug', 'removes receiver .DemoWidgetProvider'), isTrue);
    });
    test('targetSdk 30: WF2004 is suppressed and explained', () {
      expect(doctor('ok_receiver_target_sdk_30').diagnostics, isEmpty);
      expect(has('ok_receiver_target_sdk_30', 'targetSdk 30'), isTrue);
    });
    test('entrypoint library not imported by main.dart: note, never a pass or an error', () {
      expect(doctor('ok_entrypoint_library_not_imported').diagnostics, isEmpty);
      expect(has('ok_entrypoint_library_not_imported', 'does not import or export'), isTrue);
      expect(has('ok_entrypoint_library_not_imported', 'Not reported as a finding'), isTrue);
    });
    test('entrypoint library imported (directly or through export): no reachability note', () {
      for (final f in ['ok_entrypoint_library_imported', 'ok_entrypoint_library_imported_via_export_chain']) {
        expect(has(f, 'does not import or export'), isFalse, reason: f);
      }
    });
  });

  group('behavioural boundaries', () {
    test('WF2001 message names only manifests of the own source sets', () {
      final m = doctor('err_provider_ctor_args').diagnostics.single.message;
      expect(m, contains('merged manifest was not computed'));
    });
    test('WF1001 message does not claim a runtime observation', () {
      final m = doctor('err_remoteviews_space_view').diagnostics.first.message;
      expect(m, contains('not run on a device'));
      expect(m, isNot(contains('Problem loading widget')));
    });
    test('findings are deduplicated and deterministic', () {
      final a = jsonEncode(diagnosticsJson('err_entrypoint_two_activities_one_file'));
      final b = jsonEncode(diagnosticsJson('err_entrypoint_two_activities_one_file'));
      expect(a, b);
    });
  });
}
