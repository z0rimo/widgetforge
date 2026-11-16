import 'package:xml/xml.dart';

import 'checks/entrypoint_check.dart';
import 'checks/ios_widget_check.dart';
import 'ios/ios_project.dart';
import 'checks/manifest_check.dart';
import 'checks/provider_check.dart';
import 'checks/remoteviews_check.dart';
import 'models.dart';
import 'project.dart';

/// Runs all checks. Never writes to the project.
///
/// [android] and [ios] are the platforms that exist in the project; either may
/// be null, not both. With only [android] the result is identical to the
/// Android-only versions of WidgetForge.
Report runDoctor(AndroidProject? android, {IosProject? ios, List<String> loadNotes = const []}) {
  final diags = <Diagnostic>[];
  final notes = <String>[...loadNotes];
  final checks = <String>[];
  final root = (android?.root ?? ios!.root).path;

  if (android != null) {
    final p = android;
    diags.addAll(checkManifestReceivers(p, notes));
    final (provDiags, layouts) = checkProviderXml(p);
    diags.addAll(provDiags);
    diags.addAll(checkRemoteViewsLayouts(p, layouts));
    diags.addAll(checkEntrypoints(p, notes));
    notes.addAll(p.variantNotes);
    if (p.widgetReceivers.every((r) => r.element
        .findElements('meta-data')
        .every((m) => m.getAttribute('android:name') != 'android.appwidget.provider'))) {
      notes.add('No <receiver> with android.appwidget.provider meta-data found; '
          'layout checks were skipped because no widget layout is referenced.');
    }
    checks.addAll([checkManifest, checkProvider, checkRemoteViews, checkEntrypoint]);
  }
  if (ios != null) {
    diags.addAll(checkIosWidgets(ios, ios.dartSources, notes));
    checks.add(checkIosWidget);
  }

  const order = {Severity.error: 0, Severity.warning: 1, Severity.info: 2};
  diags.sort((a, b) {
    final s = order[a.severity]!.compareTo(order[b.severity]!);
    if (s != 0) return s;
    final c = a.code.compareTo(b.code);
    if (c != 0) return c;
    return a.file.compareTo(b.file);
  });
  return Report(
    projectPath: root,
    checksRun: checks,
    diagnostics: diags,
    notes: notes.toSet().toList(),
  );
}

String formatHuman(Report r, {String command = 'doctor'}) {
  final b = StringBuffer('WidgetForge $command: ${r.projectPath}\n\n');
  for (final d in r.diagnostics) {
    b.writeln('[${d.severity.name.toUpperCase()}] ${d.code} ${d.title}');
    b.writeln('  at ${d.file}${d.line != null ? ':${d.line}' : ''}');
    b.writeln('  evidence: ${d.evidence}');
    b.writeln('  ${d.message}');
    b.writeln('  fix: ${d.fix}');
    b.writeln('  docs: ${d.docs}\n');
  }
  for (final n in r.notes) {
    b.writeln('note: $n');
  }
  b.writeln('${r.count(Severity.error)} error(s), ${r.count(Severity.warning)} warning(s).');
  return b.toString();
}
