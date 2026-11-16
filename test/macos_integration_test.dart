/// Optional macOS/Xcode integration test (skipped everywhere else, including Linux CI).
///
/// Run on a Mac after creating samples with Xcode (see the private validation runbook):
///   WIDGETFORGE_XCODE_GOOD_SAMPLES=/path/a:/path/b dart test test/macos_integration_test.dart
///   WIDGETFORGE_XCODE_BAD_SAMPLES=/path/c=WF5001,/path/d=WF5004 ...
/// GOOD samples are projects Xcode created and builds: WidgetForge must report NO diagnostics
/// (any finding is a false positive until proven otherwise). BAD samples map a project to the
/// single code it must report. Nothing here runs xcodebuild; building is done by the runbook scripts.
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:widgetforge/widgetforge.dart';

Report doctorAt(String path) {
  final loaded = loadProjects(path, (m) => fail(m));
  return runDoctor(loaded!.android, ios: loaded.ios, loadNotes: loaded.notes);
}

void main() {
  final good = (Platform.environment['WIDGETFORGE_XCODE_GOOD_SAMPLES'] ?? '').split(':').where((s) => s.isNotEmpty).toList();
  final bad = (Platform.environment['WIDGETFORGE_XCODE_BAD_SAMPLES'] ?? '').split(',').where((s) => s.contains('=')).toList();
  final enabled = Platform.isMacOS && (good.isNotEmpty || bad.isNotEmpty);
  const why = 'Opt-in: macOS with WIDGETFORGE_XCODE_GOOD_SAMPLES / WIDGETFORGE_XCODE_BAD_SAMPLES set.';

  test('macOS/Xcode samples configured', () {}, skip: enabled ? false : why);

  group('Xcode-created healthy samples produce no diagnostics', skip: enabled ? false : why, () {
    for (final path in good) {
      test(path, () => expect(doctorAt(path).diagnostics.map((d) => '${d.code} ${d.file}:${d.line} ${d.evidence}').toList(), isEmpty));
    }
  });
  group('broken samples report exactly the expected code', skip: enabled ? false : why, () {
    for (final entry in bad) {
      final i = entry.lastIndexOf('=');
      final path = entry.substring(0, i);
      final code = entry.substring(i + 1);
      test(path, () => expect(doctorAt(path).diagnostics.map((d) => d.code).toList(), [code]));
    }
  });
}
