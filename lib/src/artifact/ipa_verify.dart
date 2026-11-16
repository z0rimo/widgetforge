import 'axml.dart' show BinaryFormatException;
import '../models.dart';
import 'bplist.dart';
import 'zip_reader.dart';

const checkIpaStructure = 'ipa-widget-structure';

/// Extension point identifier WidgetForge treats as a WidgetKit extension.
/// Listed as a possible value on Apple's NSExtensionPointIdentifier page; its use for widget
/// extensions is not described there and was not confirmed with a real build (see docs/errors/WF5002.md).
const widgetExtensionPoint = 'com.apple.widgetkit-extension';

/// Structural verification of a built .ipa: `Payload/<App>.app`, PlugIns/*.appex,
/// their Info.plist files (XML or binary) and the executables they name.
/// Code signatures, entitlements and App Groups live in the Mach-O binaries and
/// are NOT analyzed. A synthetic archive is not a real Apple build.
Report verifyIpa(ZipReader zip, String displayPath) {
  final diags = <Diagnostic>[];
  final notes = <String>[];
  Report done() => Report(projectPath: displayPath, checksRun: [checkIpaStructure], diagnostics: diags, notes: notes);

  final appDirs = <String>{};
  for (final n in zip.entries.keys) {
    final m = RegExp(r'^Payload/([^/]+\.app)/').firstMatch(n);
    if (m != null) appDirs.add(m.group(1)!);
  }
  if (appDirs.isEmpty) throw ArchiveException('not an IPA: no Payload/<name>.app/ directory');
  if (appDirs.length > 1) throw ArchiveException('unsupported IPA: more than one .app in Payload/ (${(appDirs.toList()..sort()).join(', ')})');
  final appName = appDirs.first;
  final appRoot = 'Payload/$appName';

  final appPlist = _plist(zip, '$appRoot/Info.plist', diags);
  String? appId;
  if (appPlist != null) {
    appId = appPlist['CFBundleIdentifier'] is String ? appPlist['CFBundleIdentifier'] as String : null;
    if (appId == null || appId.isEmpty) {
      diags.add(_d7001('$appRoot/Info.plist', 'CFBundleIdentifier is missing', 'Info.plist of the app has no CFBundleIdentifier.'));
    }
  }

  final appexDirs = <String>{};
  for (final n in zip.entries.keys) {
    final m = RegExp('^${RegExp.escape(appRoot)}/PlugIns/([^/]+\\.appex)/').firstMatch(n);
    if (m != null) appexDirs.add(m.group(1)!);
  }
  if (appexDirs.isEmpty) {
    notes.add('IPA: no PlugIns/*.appex in $appName; no app extension (and so no widget extension) is embedded in this archive.');
  }
  var widgets = 0;
  for (final ext in (appexDirs.toList()..sort())) {
    final root = '$appRoot/PlugIns/$ext';
    final plist = _plist(zip, '$root/Info.plist', diags);
    if (plist == null) continue;
    final nsx = plist['NSExtension'];
    final point = nsx is Map ? nsx['NSExtensionPointIdentifier'] : null;
    if (point is! String || point.isEmpty) {
      diags.add(_d7001('$root/Info.plist', 'NSExtension / NSExtensionPointIdentifier is missing',
          'Info.plist of $ext has no NSExtension > NSExtensionPointIdentifier, so it is not a valid app extension.'));
      continue;
    }
    if (point != widgetExtensionPoint) {
      notes.add('IPA: $ext has extension point "$point"; it is not treated as a WidgetKit extension.');
      continue;
    }
    widgets++;
    final id = plist['CFBundleIdentifier'];
    if (appId != null && appId.isNotEmpty) {
      if (id is! String || !id.startsWith('$appId.')) {
        diags.add(Diagnostic(
          code: 'WF7002',
          severity: Severity.warning,
          title: 'Widget extension bundle identifier is not prefixed with the app bundle identifier (IPA)',
          message: 'The widget extension $ext has CFBundleIdentifier "${id ?? '(none)'}" but an embedded extension\'s identifier is expected to start with '
              '"$appId.". UNVERIFIED: this convention is not stated on the Apple documentation pages that could be read and was not tested with Xcode or a real IPA, '
              'so this is a warning. Do not change identifiers on this basis alone; confirm with a real Xcode archive / install.',
          file: '$root/Info.plist',
          evidence: 'CFBundleIdentifier=${id ?? '(none)'}; app CFBundleIdentifier=$appId (unverified convention)',
          fix: 'Set the widget extension PRODUCT_BUNDLE_IDENTIFIER to "<app bundle id>.<suffix>" in the Xcode project and rebuild the IPA.',
        ));
      }
    }
    final exe = plist['CFBundleExecutable'];
    if (exe is! String || exe.isEmpty || !zip.entries.containsKey('$root/$exe')) {
      diags.add(Diagnostic(
        code: 'WF7003',
        severity: Severity.error,
        title: 'Widget extension executable is missing from the IPA',
        message: 'Info.plist of $ext names CFBundleExecutable "${exe ?? '(none)'}" but no such file exists in the extension bundle.',
        file: '$root/Info.plist',
        evidence: 'CFBundleExecutable=${exe ?? '(none)'}; $root/${exe ?? ''} not in archive',
        fix: 'Rebuild and re-export the IPA; make sure the widget extension target builds its product.',
      ));
    }
    final minOs = plist['MinimumOSVersion'];
    if (minOs is String) {
      final major = int.tryParse(minOs.split('.').first);
      if (major != null && major < 14) {
        diags.add(Diagnostic(
          code: 'WF7004',
          severity: Severity.warning,
          title: 'Widget extension MinimumOSVersion is below iOS 14 (IPA)',
          message: 'MinimumOSVersion of $ext is $minOs. Apple documentation metadata lists WidgetKit as introduced in iOS 14.0, but that a lower value makes a build or '
              'install fail was not verified (no Xcode, no real IPA), so this is a warning. Do not change the deployment target on this basis alone.',
          file: '$root/Info.plist',
          evidence: 'MinimumOSVersion=$minOs (WidgetKit introduced in iOS 14.0; failure below 14 unverified)',
          fix: 'Set the widget extension IPHONEOS_DEPLOYMENT_TARGET to 14.0 or higher and rebuild the IPA.',
        ));
      }
    } else {
      notes.add('IPA: $ext has no MinimumOSVersion; the deployment target was not checked.');
    }
  }
  if (appexDirs.isNotEmpty && widgets == 0) {
    notes.add('IPA: no embedded extension has the WidgetKit extension point; if the app should contain a widget, the extension is missing from this IPA.');
  }
  notes.add('IPA: only the bundle structure, extension Info.plist keys, bundle identifier prefix, executable presence and MinimumOSVersion were checked. '
      'Not checked: code signature, provisioning profile, entitlements and App Groups (stored in signed Mach-O data), Swift code, timelines, '
      'installation or rendering on a device or simulator. This was not verified with Xcode.');
  return done();
}

Diagnostic _d7001(String file, String evidence, String message) => Diagnostic(
      code: 'WF7001',
      severity: Severity.error,
      title: 'Info.plist in the IPA is missing, unreadable or lacks a required key',
      message: message,
      file: file,
      evidence: evidence,
      fix: 'Check the target\'s Info.plist and build settings in Xcode, then rebuild and re-export the IPA.',
    );

Map<String, Object>? _plist(ZipReader zip, String path, List<Diagnostic> diags) {
  if (!zip.entries.containsKey(path)) {
    diags.add(_d7001(path, 'file not in archive', '$path does not exist in the archive.'));
    return null;
  }
  try {
    final v = parsePlistAny(zip.read(path)!);
    if (v is Map<String, Object>) return v;
    diags.add(_d7001(path, 'top-level value is not a dictionary', '$path is not a property list dictionary.'));
  } on BinaryFormatException catch (e) {
    diags.add(_d7001(path, e.message, '$path could not be parsed as a property list: ${e.message}.'));
  } on FormatException catch (e) {
    diags.add(_d7001(path, e.message, '$path could not be parsed as a property list: ${e.message}.'));
  } on ArchiveException {
    rethrow;
  } catch (e) {
    diags.add(_d7001(path, 'parse error', '$path could not be parsed as a property list.'));
  }
  return null;
}
