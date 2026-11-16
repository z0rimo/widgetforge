import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import 'source/native_source.dart';

/// Read-only view of a Flutter project's Android side.
class AndroidProject {
  AndroidProject._(this.root, this.mainDir, this.manifestFile, this.manifest,
      this.manifestText);

  final Directory root;
  final Directory mainDir; // android/app/src/main
  final File manifestFile;
  final XmlDocument manifest;
  final String manifestText;

  /// Returns null (with [error] set) if [root] is not a Flutter project
  /// with a parseable AndroidManifest.
  static AndroidProject? load(String path, void Function(String) error) {
    final root = Directory(path).absolute;
    if (!File(p.join(root.path, 'pubspec.yaml')).existsSync()) {
      error('No pubspec.yaml in ${root.path}; not a Flutter project root.');
      return null;
    }
    final mainDir = Directory(p.join(root.path, 'android', 'app', 'src', 'main'));
    final mf = File(p.join(mainDir.path, 'AndroidManifest.xml'));
    if (!mf.existsSync()) {
      error('Missing android/app/src/main/AndroidManifest.xml.');
      return null;
    }
    final text = mf.readAsStringSync();
    try {
      return AndroidProject._(root, mainDir, mf, XmlDocument.parse(text), text);
    } on XmlException catch (e) {
      error('AndroidManifest.xml is not well-formed XML: ${e.message}');
      return null;
    }
  }

  /// Parsed Kotlin/Java declarations of every source set (lazy, cached).
  late final ClassIndex classIndex =
      ClassIndex([for (final f in nativeSources) parseNativeFile(f)]);

  String rel(File f) => p.relative(f.path, from: root.path).replaceAll('\\', '/');

  Directory get resDir => Directory(p.join(mainDir.path, 'res'));

  /// All files that define resource `@type/name` (any qualifier directory,
  /// e.g. `layout`, `layout-v31`).
  List<File> resolveResource(String type, String name) {
    if (!resDir.existsSync()) return [];
    final out = <File>[];
    for (final d in resDir.listSync().whereType<Directory>()) {
      final base = p.basename(d.path);
      if (base == type || base.startsWith('$type-')) {
        final f = File(p.join(d.path, '$name.xml'));
        if (f.existsSync()) out.add(f);
      }
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// Source-set directories under android/app/src (main, debug, release, flavors).
  List<Directory> get sourceSets {
    final src = Directory(p.join(root.path, 'android', 'app', 'src'));
    if (!src.existsSync()) return [mainDir];
    final out = src.listSync().whereType<Directory>().toList()
      ..sort((a, b) {
        // main first, then alphabetical (deterministic).
        final am = p.basename(a.path) == 'main' ? 0 : 1;
        final bm = p.basename(b.path) == 'main' ? 0 : 1;
        return am != bm ? am - bm : a.path.compareTo(b.path);
      });
    return out;
  }

  /// Kotlin/Java sources of every source set under android/app/src.
  List<File> get nativeSources {
    final out = <File>[];
    for (final set in sourceSets) {
      for (final sub in ['kotlin', 'java']) {
        final d = Directory(p.join(set.path, sub));
        if (!d.existsSync()) continue;
        out.addAll(d.listSync(recursive: true).whereType<File>().where(
            (f) => f.path.endsWith('.kt') || f.path.endsWith('.java')));
      }
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// Manifests of source sets other than `main` (merged-manifest results are
  /// NOT computed; these are only consulted to avoid false "not registered").
  List<XmlDocument> get otherManifests {
    final out = <XmlDocument>[];
    for (final set in sourceSets) {
      if (p.basename(set.path) == 'main') continue;
      final f = File(p.join(set.path, 'AndroidManifest.xml'));
      if (!f.existsSync()) continue;
      try {
        out.add(XmlDocument.parse(f.readAsStringSync()));
      } on XmlException {
        // unparseable: cannot prove anything about it
      }
    }
    return out;
  }

  /// Raw `android:name` values of [tags] in the main manifest.
  List<String> mainComponentNames(Iterable<String> tags) =>
      _componentNames(manifest, tags);

  /// Same for the manifests of all other source sets.
  List<String> otherComponentNames(Iterable<String> tags) =>
      [for (final d in otherManifests) ..._componentNames(d, tags)];

  static List<String> _componentNames(XmlDocument d, Iterable<String> tags) {
    final out = <String>[];
    for (final tag in tags) {
      for (final e in d.findAllElements(tag)) {
        final n = e.getAttribute('android:name');
        if (n != null) out.add(n.trim());
        final t = e.getAttribute('android:targetActivity');
        if (t != null) out.add(t.trim());
      }
    }
    return out;
  }

  /// Application namespace (relative class names in the manifest resolve
  /// against it). From `namespace` in android/app/build.gradle(.kts), else the
  /// manifest `package` attribute; null when neither can be read statically.
  String? get namespace {
    for (final n in ['build.gradle.kts', 'build.gradle']) {
      final f = File(p.join(root.path, 'android', 'app', n));
      if (!f.existsSync()) continue;
      final m = RegExp(r'namespace\s*=?\s*["' "'" r']([\w.]+)["' "'" r']')
          .firstMatch(f.readAsStringSync());
      if (m != null) return m.group(1);
    }
    final pkg = manifest.rootElement.getAttribute('package');
    return (pkg == null || pkg.isEmpty) ? null : pkg;
  }

  /// `name:` of the project's pubspec.yaml (used to resolve package: URIs).
  String? get pubspecName {
    final f = File(p.join(root.path, 'pubspec.yaml'));
    final m = RegExp(r'^name:\s*([\w.]+)', multiLine: true).firstMatch(f.readAsStringSync());
    return m?.group(1);
  }

  List<File> get dartSources {
    final out = <File>[];
    for (final sub in ['lib', 'bin']) {
      final d = Directory(p.join(root.path, sub));
      if (!d.existsSync()) continue;
      out.addAll(d
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')));
    }
    out.sort((a, b) => a.path.compareTo(b.path));
    return out;
  }

  /// Receivers to run the widget checks on: every `<receiver>` of the main
  /// manifest, plus receivers that exist ONLY in the manifest of another source
  /// set (debug, release, a flavor). Each is judged on its own declaration;
  /// declarations are never summed across source sets and no single variant's
  /// merge result is assumed. `tools:node="remove"` markers are not declarations.
  List<ReceiverRef> get widgetReceivers {
    final out = <ReceiverRef>[];
    final mainNames = <String>{};
    for (final r in receivers) {
      if (_removed(r)) continue;
      out.add(ReceiverRef(r, p.relative(manifestFile.path, from: root.path).replaceAll('\\', '/'), manifestText, true));
      mainNames.add(r.getAttribute('android:name') ?? '');
    }
    for (final set in sourceSets) {
      if (p.basename(set.path) == 'main') continue;
      final f = File(p.join(set.path, 'AndroidManifest.xml'));
      if (!f.existsSync()) continue;
      final text = f.readAsStringSync();
      XmlDocument d;
      try {
        d = XmlDocument.parse(text);
      } on XmlException {
        continue;
      }
      for (final r in d.findAllElements('receiver')) {
        if (_removed(r)) continue;
        final n = r.getAttribute('android:name') ?? '';
        if (mainNames.contains(n)) continue; // merged with the main declaration
        out.add(ReceiverRef(r, rel(f), text, false));
      }
    }
    return out;
  }

  /// Receivers named in a non-main manifest only / removed by a tools marker,
  /// as human-readable notes (variant-dependent, not judged).
  List<String> get variantNotes {
    final notes = <String>[];
    for (final r in widgetReceivers.where((r) => !r.isMain)) {
      notes.add('Receiver ${r.name} is declared only in ${r.file}; build variants without that source set do not contain it '
          '(observed with Gradle: debug-only receiver absent from the release APK). WidgetForge does not select a build variant.');
    }
    for (final set in sourceSets) {
      if (p.basename(set.path) == 'main') continue;
      final f = File(p.join(set.path, 'AndroidManifest.xml'));
      if (!f.existsSync()) continue;
      try {
        for (final r in XmlDocument.parse(f.readAsStringSync()).findAllElements('receiver')) {
          if (_removed(r)) {
            notes.add('${rel(f)} removes receiver ${r.getAttribute('android:name')} with tools:node; '
                'the main-manifest declaration does not apply to variants using that source set.');
          }
        }
      } on XmlException {
        // ignored
      }
    }
    return notes;
  }

  /// Numeric `targetSdk` from android/app/build.gradle(.kts), or null when it
  /// is not a plain integer (e.g. `flutter.targetSdkVersion`) or not found.
  /// Flavor/build-type specific overrides are not read.
  int? get targetSdk {
    for (final n in ['build.gradle.kts', 'build.gradle']) {
      final f = File(p.join(root.path, 'android', 'app', n));
      if (!f.existsSync()) continue;
      final m = RegExp(r'targetSdk(?:Version)?\s*=?\s*(\d+)\b').firstMatch(f.readAsStringSync());
      if (m != null) return int.parse(m.group(1)!);
    }
    return null;
  }

  XmlElement? get application =>
      manifest.rootElement.findElements('application').firstOrNull;

  Iterable<XmlElement> get receivers =>
      application?.findElements('receiver') ?? const [];
  Iterable<XmlElement> get activities =>
      application?.findElements('activity') ?? const [];
}

/// A `<receiver>` element together with the manifest it was read from.
class ReceiverRef {
  ReceiverRef(this.element, this.file, this.text, this.isMain);
  final XmlElement element;

  /// Manifest path relative to the project root.
  final String file;
  final String text;
  final bool isMain;
  String get name => element.getAttribute('android:name') ?? '(unnamed)';
}

bool _removed(XmlElement e) {
  final n = e.attributes.where((a) => a.name.local == 'node' && a.name.prefix == 'tools').firstOrNull?.value;
  return n == 'remove' || n == 'removeAll';
}

/// Parses `@type/name` resource references.
({String type, String name})? parseResourceRef(String? value) {
  if (value == null) return null;
  final m = RegExp(r'^@(?:\+)?(?:\w+:)?(\w+)/([\w.]+)$').firstMatch(value.trim());
  if (m == null) return null;
  return (type: m.group(1)!, name: m.group(2)!);
}

/// Last segment of a (possibly relative `.Foo` or fully qualified) class name.
String simpleClassName(String name) => name.split('.').where((s) => s.isNotEmpty).last;

/// 1-based line of the first occurrence of [needle] in [text] at/after [from].
int? lineOf(String text, String needle, [int from = 0]) {
  final i = text.indexOf(needle, from);
  if (i < 0) return null;
  return '\n'.allMatches(text.substring(0, i)).length + 1;
}
