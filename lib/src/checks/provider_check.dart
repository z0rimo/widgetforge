import 'package:xml/xml.dart';

import '../models.dart';
import '../project.dart';

const checkProvider = 'provider-xml';

/// A widget provider XML reachable from the manifest, with its layout refs.
class ProviderInfo {
  ProviderInfo(this.xmlRefName, this.layouts);
  final String xmlRefName;
  final List<String> layouts; // layout names referenced (initialLayout/previewLayout)
}

/// WF3001-WF3004. Also returns the layouts referenced, for the RemoteViews check.
(List<Diagnostic>, List<String>) checkProviderXml(AndroidProject p) {
  final out = <Diagnostic>[];
  final layoutNames = <String>[];
  final mainMfRel = p.rel(p.manifestFile);
  final ns = p.namespace;
  final activityNames = [
    ...p.mainComponentNames(['activity', 'activity-alias']),
    ...p.otherComponentNames(['activity', 'activity-alias']),
  ];

  for (final rcv in p.widgetReceivers) {
    final r = rcv.element;
    final mfRel = rcv.file;
    final meta = r
        .findElements('meta-data')
        .where((m) => m.getAttribute('android:name') == 'android.appwidget.provider')
        .firstOrNull;
    if (meta == null) continue;
    final resAttr = meta.getAttribute('android:resource');
    final ref = parseResourceRef(resAttr);
    if (ref == null || ref.type != 'xml') {
      out.add(Diagnostic(
        code: 'WF3001',
        severity: Severity.error,
        title: 'Provider meta-data does not reference an @xml resource',
        message: 'android:resource is ${resAttr == null ? 'missing' : '"$resAttr"'}; expected @xml/<name>.',
        file: mfRel,
        line: lineOf(rcv.text, 'android.appwidget.provider'),
        evidence: resAttr ?? '(no android:resource)',
        fix: 'Set android:resource="@xml/<widget_info>" and create res/xml/<widget_info>.xml.',
      ));
      continue;
    }
    final files = p.resolveResource('xml', ref.name);
    if (files.isEmpty) {
      out.add(Diagnostic(
        code: 'WF3001',
        severity: Severity.error,
        title: 'Widget provider XML not found',
        message: 'Manifest references @xml/${ref.name} but no res/xml*/${ref.name}.xml exists.',
        file: mfRel,
        line: lineOf(rcv.text, resAttr!),
        evidence: resAttr,
        fix:
            'Create android/app/src/main/res/xml/${ref.name}.xml with an <appwidget-provider> root, or correct the android:resource name.',
      ));
      continue;
    }
    for (final f in files) {
      final text = f.readAsStringSync();
      XmlDocument doc;
      try {
        doc = XmlDocument.parse(text);
      } on XmlException catch (e) {
        out.add(Diagnostic(
          code: 'WF3001',
          severity: Severity.error,
          title: 'Widget provider XML is not well-formed',
          message: e.message,
          file: p.rel(f),
          line: null,
          evidence: e.message,
          fix: 'Fix the XML syntax error.',
        ));
        continue;
      }
      final root = doc.rootElement;
      if (root.name.local != 'appwidget-provider') {
        out.add(Diagnostic(
          code: 'WF3001',
          severity: Severity.error,
          title: 'Provider XML root is not <appwidget-provider>',
          message: 'Root element is <${root.name.qualified}>.',
          file: p.rel(f),
          line: 1,
          evidence: '<${root.name.qualified}>',
          fix: 'Make the root element <appwidget-provider>.',
        ));
        continue;
      }
      final initial = root.getAttribute('android:initialLayout');
      if (initial == null) {
        out.add(Diagnostic(
          code: 'WF3002',
          severity: Severity.error,
          title: 'appwidget-provider lacks android:initialLayout',
          message: 'Without android:initialLayout the widget has nothing to inflate and cannot be added.',
          file: p.rel(f),
          line: lineOf(text, '<appwidget-provider'),
          evidence: '<appwidget-provider> (no android:initialLayout)',
          fix: 'Add android:initialLayout="@layout/<your_widget_layout>" and create that layout.',
        ));
      }
      for (final attr in ['android:initialLayout', 'android:previewLayout']) {
        final v = root.getAttribute(attr);
        if (v == null) continue;
        final lr = parseResourceRef(v);
        if (lr == null || lr.type != 'layout' || p.resolveResource('layout', lr.name).isEmpty) {
          out.add(Diagnostic(
            code: 'WF3003',
            severity: Severity.error,
            title: 'Widget layout resource not found',
            message: '$attr="$v" does not resolve to any res/layout*/ file.',
            file: p.rel(f),
            line: lineOf(text, v),
            evidence: '$attr="$v"',
            fix: lr != null && lr.type == 'layout'
                ? 'Create android/app/src/main/res/layout/${lr.name}.xml or correct the reference.'
                : 'Use a @layout/<name> reference.',
          ));
        } else {
          layoutNames.add(lr.name);
        }
      }
      final configure = root.getAttribute('android:configure');
      if (configure != null && !_activityDeclared(configure.trim(), activityNames, ns)) {
        out.add(Diagnostic(
          code: 'WF3004',
          severity: Severity.error,
          title: 'Widget configure activity is not registered in the manifest',
          message:
              'android:configure="$configure" names an activity with no matching <activity> entry in the manifests of '
              'android/app/src/*. Android documents that activities not declared in the manifest "aren\'t seen by the system and never run", '
              'and the widget documentation says to declare the configuration activity with an intent filter for ACTION_APPWIDGET_CONFIGURE. '
              'Matching is by fully-qualified class name (relative manifest names use the module namespace). '
              'Library-provided manifests are not visible to this check.',
          file: p.rel(f),
          line: lineOf(text, configure),
          evidence: 'android:configure="$configure"',
          fix:
              'Declare <activity android:name="$configure" android:exported="true"> with <intent-filter><action android:name="android.appwidget.action.APPWIDGET_CONFIGURE"/></intent-filter> in $mainMfRel '
              '(Android 12+ requires android:exported to be explicit when an intent-filter exists; the widget documentation does not state which value), or remove android:configure.',
        ));
      }
    }
  }
  return (out, layoutNames);
}

/// Is [configure] (an `android:configure` value) declared as an activity?
/// Names are compared as fully-qualified class names; relative manifest names
/// use the module namespace. If the namespace is unknown, a relative name is
/// compared by its trailing name (ambiguous matches count as declared).
bool _activityDeclared(String configure, List<String> manifestNames, String? ns) {
  String? full(String n) {
    if (n.startsWith('.')) return ns == null ? null : '$ns$n';
    if (!n.contains('.')) return ns == null ? null : '$ns.$n';
    return n;
  }

  final want = full(configure);
  for (final raw in manifestNames) {
    final n = raw.trim();
    if (n.contains(r'${')) continue;
    final got = full(n);
    if (want != null && got != null) {
      if (want == got) return true;
    } else {
      // namespace unknown: compare trailing simple names
      if (simpleClassName(n) == simpleClassName(configure)) return true;
    }
  }
  return false;
}
