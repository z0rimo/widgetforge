import 'dart:typed_data';

import '../models.dart';
import 'arsc.dart';
import 'axml.dart';
import 'zip_reader.dart';

const checkApkWidget = 'apk-widget-artifact';

String _hex(int v) => '0x${v.toRadixString(16).padLeft(8, '0')}';

/// Verifies the AppWidget wiring that is visible inside a built APK: the final
/// binary AndroidManifest.xml, the provider XML and the initial layout, each
/// resolved through resources.arsc. Reads only; never extracts to disk.
Report verifyApk(ZipReader zip, String displayPath) {
  final diags = <Diagnostic>[];
  final notes = <String>[];
  Report done() => Report(projectPath: displayPath, checksRun: [checkApkWidget], diagnostics: diags, notes: notes);

  const manifestPath = 'AndroidManifest.xml';
  final manifestBytes = zip.read(manifestPath);
  if (manifestBytes == null) throw ArchiveException('not an APK: AndroidManifest.xml is missing');
  AxmlElement manifest;
  try {
    manifest = parseAxml(manifestBytes);
  } on BinaryFormatException catch (e) {
    throw ArchiveException('AndroidManifest.xml could not be read as binary XML: ${e.message}');
  }
  if (manifest.name != 'manifest') throw ArchiveException('not an APK: root element of AndroidManifest.xml is "${manifest.name}"');

  final usesSdk = manifest.childrenNamed('uses-sdk').firstOrNull;
  final targetAttr = usesSdk?.attr('targetSdkVersion');
  final targetSdk = targetAttr != null && targetAttr.isInt ? targetAttr.data : null;

  final app = manifest.childrenNamed('application').firstOrNull;
  final receivers = [
    for (final r in app?.childrenNamed('receiver') ?? const <AxmlElement>[])
      if (_isWidgetReceiver(r)) r
  ];
  if (receivers.isEmpty) {
    notes.add('APK: no AppWidget receiver (APPWIDGET_UPDATE action or android.appwidget.provider meta-data) found in the final '
        'AndroidManifest.xml; there is nothing to verify. This does not say whether the app should contain a widget.');
    _commonNotes(notes);
    return done();
  }

  notes.add('APK: checked ${receivers.length} AppWidget receiver(s): '
      '${receivers.map((r) => r.attr('name')?.describe() ?? '(unnamed)').join(', ')}.');

  ResourceTable? table;
  String? tableProblem;
  final arscBytes = _tryRead(zip, 'resources.arsc', zip.limits.maxReadBytes, (m) => tableProblem = m);
  if (arscBytes != null) {
    try {
      table = ResourceTable.parse(arscBytes);
    } on BinaryFormatException catch (e) {
      tableProblem = e.message;
    }
  } else {
    tableProblem ??= 'resources.arsc is not present';
  }
  if (table == null) {
    notes.add('APK: resource references (provider XML, initial layout) were not resolved because resources.arsc could not be used '
        '($tableProblem); those checks were skipped.');
  }

  for (final r in receivers) {
    final name = r.attr('name')?.describe() ?? '(unnamed)';
    // WF6001 exported
    final exp = r.attr('exported');
    final hasFilter = r.childrenNamed('intent-filter').isNotEmpty;
    if (exp == null && hasFilter) {
      if (targetSdk != null && targetSdk >= 31) {
        diags.add(Diagnostic(
          code: 'WF6001',
          severity: Severity.error,
          title: 'Widget receiver without android:exported in the built APK',
          message: 'The receiver "$name" has an intent filter but no android:exported attribute while targetSdkVersion is $targetSdk (>= 31). '
              'Android 12+ refuses to install an app with such a component.',
          file: manifestPath,
          evidence: '<receiver android:name="$name"> (no android:exported), uses-sdk targetSdkVersion=$targetSdk',
          fix: 'Add android:exported="true" to the widget <receiver> in the source AndroidManifest.xml and rebuild.',
        ));
      } else {
        notes.add('APK: receiver "$name" has an intent filter but no android:exported attribute and targetSdkVersion is '
            '${targetSdk ?? 'unknown'}; the Android 12 install rule was not applied.');
      }
    } else if (exp != null && exp.asBool == null) {
      notes.add('APK: android:exported of receiver "$name" is not a boolean literal (${exp.describe()}); not checked.');
    }

    // provider metadata
    final metas = [for (final m in r.childrenNamed('meta-data')) if (m.attr('name')?.asString == 'android.appwidget.provider') m];
    if (metas.isEmpty) {
      diags.add(Diagnostic(
        code: 'WF6002',
        severity: Severity.error,
        title: 'Widget receiver without android.appwidget.provider meta-data in the built APK',
        message: 'The receiver "$name" declares the APPWIDGET_UPDATE action but has no android.appwidget.provider meta-data, so the launcher '
            'cannot read its widget configuration.',
        file: manifestPath,
        evidence: '<receiver android:name="$name"> with APPWIDGET_UPDATE and no <meta-data android:name="android.appwidget.provider">',
        fix: 'Add <meta-data android:name="android.appwidget.provider" android:resource="@xml/your_widget_info"/> to the receiver and rebuild.',
      ));
      continue;
    }
    final res = metas.first.attr('resource');
    if (res == null || !res.isReference) {
      notes.add('APK: provider meta-data of "$name" has no resource reference; not checked.');
      continue;
    }
    if (table == null) continue;
    final xmlFiles = table.filesById[res.data];
    if (xmlFiles == null || xmlFiles.isEmpty) {
      diags.add(Diagnostic(
        code: 'WF6003',
        severity: Severity.error,
        title: 'Provider XML referenced by the built APK is missing',
        message: 'The android.appwidget.provider meta-data of "$name" points to resource ${_hex(res.data)}, which has no file value in resources.arsc.',
        file: manifestPath,
        evidence: 'android:resource=@${_hex(res.data)} (no file in resources.arsc)',
        fix: 'Make sure the @xml resource named by the meta-data exists in src/main/res/xml and is not removed by resource shrinking, then rebuild.',
      ));
      continue;
    }
    var anyPresent = false;
    for (final path in xmlFiles) {
      if (!zip.entries.containsKey(path)) continue;
      anyPresent = true;
      _checkProviderXml(zip, table, path, name, diags, notes);
    }
    if (!anyPresent) {
      diags.add(Diagnostic(
        code: 'WF6003',
        severity: Severity.error,
        title: 'Provider XML referenced by the built APK is missing',
        message: 'The resource table maps ${_hex(res.data)} to ${xmlFiles.join(', ')}, but that path is not in the APK.',
        file: manifestPath,
        evidence: 'android:resource=@${_hex(res.data)} -> ${xmlFiles.join(', ')} (not in APK)',
        fix: 'Rebuild; if it persists, check resource shrinking / packaging configuration for res/xml.',
      ));
    }
  }
  _commonNotes(notes);
  return done();
}

bool _isWidgetReceiver(AxmlElement r) {
  for (final f in r.childrenNamed('intent-filter')) {
    for (final a in f.childrenNamed('action')) {
      if (a.attr('name')?.asString == 'android.appwidget.action.APPWIDGET_UPDATE') return true;
    }
  }
  return r.childrenNamed('meta-data').any((m) => m.attr('name')?.asString == 'android.appwidget.provider');
}

Uint8List? _tryRead(ZipReader zip, String name, int cap, void Function(String) problem) {
  try {
    return zip.read(name, maxBytes: cap);
  } on ArchiveException catch (e) {
    // A limit violation on an optional entry means "cannot analyze that part", not "invalid APK".
    problem(e.message);
    return null;
  }
}

void _checkProviderXml(ZipReader zip, ResourceTable table, String path, String receiver, List<Diagnostic> diags, List<String> notes) {
  AxmlElement root;
  try {
    root = parseAxml(zip.read(path)!);
  } on BinaryFormatException catch (e) {
    notes.add('APK: $path could not be read as binary XML (${e.message}); not checked.');
    return;
  } on ArchiveException catch (e) {
    notes.add('APK: $path could not be read (${e.message}); not checked.');
    return;
  }
  if (root.name != 'appwidget-provider') {
    notes.add('APK: $path root element is "${root.name}", not appwidget-provider; not checked.');
    return;
  }
  final il = root.attr('initialLayout');
  if (il == null) {
    diags.add(Diagnostic(
      code: 'WF6004',
      severity: Severity.error,
      title: 'Provider XML in the built APK has no android:initialLayout',
      message: 'The appwidget-provider used by "$receiver" has no android:initialLayout, so the launcher has no layout to show before the first update.',
      file: path,
      evidence: '<appwidget-provider> without android:initialLayout',
      fix: 'Add android:initialLayout="@layout/your_widget" to the provider XML and rebuild.',
    ));
    return;
  }
  if (!il.isReference) {
    notes.add('APK: android:initialLayout in $path is not a resource reference (${il.describe()}); not checked.');
    return;
  }
  final files = table.filesById[il.data];
  final present = files == null ? <String>[] : [for (final f in files) if (zip.entries.containsKey(f)) f];
  if (present.isEmpty) {
    diags.add(Diagnostic(
      code: 'WF6005',
      severity: Severity.error,
      title: 'initialLayout referenced by the built APK is missing',
      message: 'android:initialLayout in $path points to resource ${_hex(il.data)}, which has no layout file in the APK.',
      file: path,
      evidence: 'android:initialLayout=@${_hex(il.data)} -> ${files == null || files.isEmpty ? '(no file in resources.arsc)' : '${files.join(', ')} (not in APK)'}',
      fix: 'Make sure the layout exists in src/main/res/layout (or a qualified folder) and is kept by resource shrinking, then rebuild.',
    ));
  }
}

void _commonNotes(List<String> notes) {
  notes.add('APK: only the manifest wiring of AppWidget receivers, provider XML and initialLayout presence were checked. '
      'Not checked: layout contents (RemoteViews classes), configure activities, Dart entrypoints, signature, dex code, split APKs / AAB, '
      'installation or rendering on a device.');
}
