import 'package:xml/xml.dart';

import '../models.dart';
import '../project.dart';
import '../registration.dart';

const checkManifest = 'manifest-receivers';

/// Classes whose subclasses are AppWidget broadcast receivers.
const providerRoots = {
  'android.appwidget.AppWidgetProvider',
  'es.antonborri.home_widget.HomeWidgetProvider',
  'androidx.glance.appwidget.GlanceAppWidgetReceiver',
};

/// WF2001-WF2004: AppWidgetProvider registration in AndroidManifest.xml.
List<Diagnostic> checkManifestReceivers(AndroidProject p, [List<String>? notes]) {
  final out = <Diagnostic>[];
  final mfRel = p.rel(p.manifestFile);
  final idx = p.classIndex;
  final names = [
    ...p.mainComponentNames(['receiver']),
    ...p.otherComponentNames(['receiver']),
  ];
  final ns = p.namespace;
  final mainNames = p.mainComponentNames(['receiver']);

  // WF2001: a concrete class that (provably) extends an AppWidget provider
  // base class has no <receiver>. Reported only when the whole inheritance
  // chain resolves inside this project; unknown chains are never errors.
  for (final c in idx.all) {
    if (c.isAbstract) continue;
    if (idx.extendsRoot(c, providerRoots) != true) continue;
    if (idx.hasSubclass(c)) continue; // used as a base class, not registered itself
    if (isRegistered(c, mainNames, ns)) continue;
    if (isRegistered(c, names, ns)) continue; // variant-dependent: see AndroidProject.variantNotes
    final direct = c.supers.isNotEmpty ? c.supers.first.written : 'an AppWidget provider';
    out.add(Diagnostic(
      code: 'WF2001',
      severity: Severity.error,
      title: 'AppWidgetProvider is not registered in AndroidManifest.xml',
      message:
          '${c.name} extends $direct (an AppWidget provider) but no <receiver> in any manifest of '
          'android/app/src/* names ${c.fqcn}, so the widget will not appear in the launcher widget picker. '
          'Only manifests of the project\'s own source sets were read; the merged manifest was not computed.',
      file: p.rel(c.file),
      line: c.line,
      evidence: c.header,
      fix:
          'Add inside <application> of $mfRel: <receiver android:name="${c.fqcn}" android:exported="true">'
          '<intent-filter><action android:name="android.appwidget.action.APPWIDGET_UPDATE"/></intent-filter>'
          '<meta-data android:name="android.appwidget.provider" android:resource="@xml/YOUR_WIDGET_INFO"/></receiver>',
    ));
  }

  // Receivers that look like widget providers: have the provider meta-data
  // or the APPWIDGET_UPDATE action.
  for (final ref in p.widgetReceivers) {
    final r = ref.element;
    final mfRel = ref.file;
    final name = r.getAttribute('android:name') ?? '(unnamed)';
    final metas = r.findElements('meta-data');
    final providerMeta = metas
        .where((m) => m.getAttribute('android:name') == 'android.appwidget.provider')
        .firstOrNull;
    final actions = r
        .findAllElements('action')
        .map((a) => a.getAttribute('android:name'))
        .toList();
    final hasUpdate = actions.contains('android.appwidget.action.APPWIDGET_UPDATE');
    if (providerMeta == null && !hasUpdate) continue;
    final line = lineOf(ref.text, 'android:name="$name"');

    if (!hasUpdate) {
      out.add(Diagnostic(
        code: 'WF2002',
        severity: Severity.error,
        title: 'Widget receiver lacks APPWIDGET_UPDATE intent-filter',
        message:
            'Receiver $name declares the appwidget provider meta-data but no intent-filter '
            'for android.appwidget.action.APPWIDGET_UPDATE; the launcher will not list or update it.',
        file: mfRel,
        line: line,
        evidence: '<receiver android:name="$name">',
        fix:
            'Add <intent-filter><action android:name="android.appwidget.action.APPWIDGET_UPDATE"/></intent-filter> to this <receiver>.',
      ));
    }
    if (providerMeta == null) {
      out.add(Diagnostic(
        code: 'WF2003',
        severity: Severity.error,
        title: 'Widget receiver lacks android.appwidget.provider meta-data',
        message:
            'Receiver $name has the APPWIDGET_UPDATE action but no <meta-data android:name="android.appwidget.provider">, '
            'so Android cannot find the widget size/layout description.',
        file: mfRel,
        line: line,
        evidence: '<receiver android:name="$name">',
        fix:
            'Add <meta-data android:name="android.appwidget.provider" android:resource="@xml/YOUR_WIDGET_INFO"/> to this <receiver> and create res/xml/YOUR_WIDGET_INFO.xml.',
      ));
    }
    final target = p.targetSdk;
    if (r.getAttribute('android:exported') == null &&
        r.findElements('intent-filter').isNotEmpty &&
        target != null &&
        target < 31) {
      notes?.add('targetSdk $target (android/app/build.gradle): android:exported is not required for $name; '
          'the Android 12 requirement applies to apps targeting API 31 or higher (a debug build with targetSdk 30 succeeded).');
    } else if (r.getAttribute('android:exported') == null &&
        r.findElements('intent-filter').isNotEmpty) {
      out.add(Diagnostic(
        code: 'WF2004',
        severity: Severity.error,
        title: 'Widget receiver with intent-filter lacks android:exported',
        message:
            'Apps targeting Android 12 (API 31) or higher must set android:exported explicitly on every component with an intent-filter; '
            'the manifest merger rejected such a build in a test project. (This manifest is judged on its own: another source set may add the attribute.)',
        file: mfRel,
        line: line,
        evidence: '<receiver android:name="$name"> (no android:exported)',
        fix: 'Add android:exported="true" to this <receiver>.',
      ));
    }
  }
  return out;
}
