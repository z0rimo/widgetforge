import 'dart:io';

import 'package:xml/xml.dart';

import '../models.dart';
import '../project.dart';
import '../registration.dart';
import '../source/dart_source.dart';
import '../source/lexer.dart';
import '../source/native_source.dart';

const checkEntrypoint = 'flutter-activity-entrypoint';

/// Classes whose subclasses are Flutter activities with a Dart entrypoint.
const activityRoots = {
  'io.flutter.embedding.android.FlutterActivity',
  'io.flutter.embedding.android.FlutterFragmentActivity',
};

// Manifest meta-data keys (FlutterActivityLaunchConfigs in flutter.jar, 3.32.0).
const _metaEntrypoint = 'io.flutter.Entrypoint';
const _metaEntrypointUri = 'io.flutter.EntrypointUri';

/// Result of looking for an override of a no-argument String method.
class _Override {
  _Override.none()
      : found = false,
        literal = null,
        literalToken = null;
  _Override(this.literal, this.literalToken) : found = true;
  final bool found;

  /// The returned string when the body is exactly one string literal;
  /// null when it is anything else (constant, call, concatenation, ...).
  final String? literal;
  final Token? literalToken;
}

/// WF4001-WF4003: separate FlutterActivity subclasses and their Dart entrypoints.
///
/// Decision order mirrors the FlutterActivity documentation: an override of
/// getDartEntrypointFunctionName()/getDartEntrypointLibraryUri() replaces the
/// manifest meta-data (io.flutter.Entrypoint / io.flutter.EntrypointUri), which
/// replaces the default (`main`, root library). Intent extras and cached
/// engines are runtime facts that cannot be seen here: when a cached/own
/// engine override exists, the entrypoint is not checked at all.
List<Diagnostic> checkEntrypoints(AndroidProject p, [List<String>? notes]) {
  final out = <Diagnostic>[];
  final seen = <String>{};
  void add(Diagnostic d) {
    if (seen.add('${d.code}|${d.file}|${d.line}|${d.evidence}')) out.add(d);
  }

  final mfRel = p.rel(p.manifestFile);
  final idx = p.classIndex;
  final ns = p.namespace;
  final activityNames = [
    ...p.mainComponentNames(['activity', 'activity-alias']),
    ...p.otherComponentNames(['activity', 'activity-alias']),
  ];
  Diagnostic mk(String code, String title, String message, String fix, String file, int? line, String evidence) =>
      Diagnostic(
          code: code,
          severity: Severity.error,
          title: title,
          message: message,
          file: file,
          line: line,
          evidence: evidence,
          fix: fix);
  final reach = _Reach(p);
  final dartFns = <File, List<DartFunction>>{};
  List<DartFunction> fnsOf(File f) => dartFns.putIfAbsent(f, () => parseDartTopLevelFunctions(f));

  for (final c in idx.all) {
    if (c.isAbstract) continue;
    if (idx.extendsRoot(c, activityRoots) != true) continue;
    if (idx.hasSubclass(c)) continue; // base class: its leaves are evaluated

    if (!isRegistered(c, activityNames, ns)) {
      add(Diagnostic(
        code: 'WF4003',
        severity: Severity.error,
        title: 'FlutterActivity subclass is not registered in AndroidManifest.xml',
        message:
            '${c.name} extends ${c.supers.first.written} but no <activity> in any manifest of android/app/src/* names ${c.fqcn}; '
            'startActivity() with an explicit intent for it cannot be resolved. '
            'Only manifests of the project\'s own source sets were read; the merged manifest was not computed.',
        file: p.rel(c.file),
        line: c.line,
        evidence: c.header,
        fix:
            'Add <activity android:name="${c.fqcn}" android:exported="false" android:theme="@style/LaunchTheme" android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode" android:hardwareAccelerated="true" android:windowSoftInputMode="adjustResize"/> to $mfRel.',
      ));
    }

    // An own/cached engine makes the entrypoint override irrelevant: skip.
    if (_findOverride(idx, c, 'provideFlutterEngine').found ||
        _findOverride(idx, c, 'getCachedEngineId').found ||
        _findOverride(idx, c, 'getCachedEngineGroupId').found) {
      continue;
    }

    // ---- entrypoint function name ----
    final fnOv = _findOverride(idx, c, 'getDartEntrypointFunctionName');
    final meta = _manifestMeta(p, c, ns);
    String? fn;
    String evidence;
    String locFile;
    int? locLine;
    if (fnOv.found) {
      if (fnOv.literal == null) continue; // dynamic: cannot verify statically
      fn = fnOv.literal;
      evidence = 'getDartEntrypointFunctionName() -> "$fn"';
      locFile = p.rel(c.file);
      locLine = fnOv.literalToken!.line;
    } else if (meta[_metaEntrypoint] != null) {
      fn = meta[_metaEntrypoint];
      evidence = '<meta-data android:name="$_metaEntrypoint" android:value="$fn">';
      locFile = mfRel;
      locLine = lineOf(p.manifestText, 'android:value="$fn"') ?? lineOf(p.manifestText, _metaEntrypoint);
    } else {
      continue; // default entrypoint `main`
    }
    if (fn == null || fn.isEmpty) continue;

    // ---- which Dart library? ----
    final uriOv = _findOverride(idx, c, 'getDartEntrypointLibraryUri');
    String? uri;
    if (uriOv.found) {
      if (uriOv.literal == null) continue; // dynamic library: unknown
      uri = uriOv.literal;
    } else {
      uri = meta[_metaEntrypointUri];
    }
    List<File> candidates;
    if (uri == null || uri.isEmpty) {
      candidates = p.dartSources; // root library: any library of this project
    } else {
      final target = _projectFileForUri(p, uri);
      if (target == null) continue; // other package / unsupported URI: not verifiable
      candidates = [target];
    }

    final decls = [
      for (final f in candidates)
        for (final d in fnsOf(f))
          if (d.name == fn) d
    ];
    if (decls.isEmpty) {
      final where = uri == null || uri.isEmpty
          ? 'under lib/ or bin/'
          : 'in the library "$uri"';
      add(mk(
        'WF4001',
        'Dart entrypoint named by FlutterActivity not found',
        '${c.name} requests Dart entrypoint "$fn" but no top-level function $fn() was found $where. '
            'Without it the Dart VM has no function to run for this activity. '
            '(Intent extras, cached engines and generated code are not visible to this check.)',
        "Add to a Dart file under lib/: @pragma('vm:entry-point') void $fn() { runApp(...); } — or fix the name returned by getDartEntrypointFunctionName() / the io.flutter.Entrypoint meta-data.",
        locFile,
        locLine,
        evidence,
      ));
      continue;
    }
    // Reachability: a library that main.dart never imports (directly or
    // transitively) is not part of the compiled program (observed: the function
    // was absent from the release libapp.so). The root is assumed to be
    // lib/main.dart; this is a note, not a finding, because the build target
    // (`flutter build -t`) is not known.
    _reachabilityNote(p, decls, fn, c, notes, reach);
    if (decls.any((d) => d.hasEntryPointPragma)) continue;
    final d = decls.first;
    add(mk(
      'WF4002',
      "Dart entrypoint lacks @pragma('vm:entry-point')",
      '$fn() is declared but not annotated; the Flutter documentation requires the annotation so a non-main entrypoint is not tree-shaken in AOT builds '
          '(observed with a release build of an isolated sample on Flutter 3.32.0: the unannotated function was absent from libapp.so).',
      "Add @pragma('vm:entry-point') to the declaration of $fn().",
      p.rel(d.file),
      d.line,
      '$fn() without @pragma',
    ));
  }
  return out;
}

/// Meta-data values of the `<activity>` elements that denote [c].
Map<String, String> _manifestMeta(AndroidProject p, NativeClass c, String? ns) {
  final out = <String, String>{};
  final conflicts = <String>{};
  void scan(XmlDocument d) {
    for (final a in d.findAllElements('activity')) {
      final n = a.getAttribute('android:name');
      if (n == null || !nameDenotes(c, n.trim(), ns)) continue;
      for (final m in a.findElements('meta-data')) {
        final k = m.getAttribute('android:name');
        final v = m.getAttribute('android:value');
        if (k != _metaEntrypoint && k != _metaEntrypointUri) continue;
        if (v == null) continue;
        if (out.containsKey(k) && out[k] != v) conflicts.add(k!);
        out[k!] = v;
      }
    }
  }

  scan(p.manifest);
  for (final d in p.otherManifests) {
    scan(d);
  }
  for (final k in conflicts) {
    out.remove(k);
  }
  return out;
}

/// Maps a Dart library URI to a file of THIS project, or null.
File? _projectFileForUri(AndroidProject p, String uri) {
  final name = p.pubspecName;
  final pre = name == null ? null : 'package:$name/';
  if (pre != null && uri.startsWith(pre)) {
    final f = File('${p.root.path}/lib/${uri.substring(pre.length)}');
    // A missing file is still "ours": the library cannot be found at all.
    return f;
  }
  return null;
}

/// Finds an override named [name] declared in [c] or its project ancestors.
_Override _findOverride(ClassIndex idx, NativeClass c, String name, [Set<String>? seen]) {
  seen ??= {};
  if (!seen.add(c.fqcn)) return _Override.none();
  final own = _overrideIn(c, name);
  if (own.found) return own;
  for (final s in c.supers) {
    for (final cand in s.candidates) {
      final sc = idx.byFqcn[cand];
      if (sc == null) continue;
      final r = _findOverride(idx, sc, name, seen);
      if (r.found) return r;
    }
  }
  return _Override.none();
}

_Override _overrideIn(NativeClass c, String name) {
  if (c.bodyStart < 0) return _Override.none();
  final t = c.tokens;
  var depth = 0;
  for (var i = c.bodyStart; i < c.bodyEnd; i++) {
    final x = t[i];
    if (x.kind == TokenKind.punct) {
      if (x.text == '{') depth++;
      if (x.text == '}') depth--;
      continue;
    }
    if (depth != 0 || x.kind != TokenKind.ident || x.text != name) continue;
    if (i == 0 || i + 1 >= t.length || !t[i + 1].is_('(')) continue;
    final prev = t[i - 1];
    if (prev.kind != TokenKind.ident) continue; // `.name(` / `super.name(` are calls
    if (const {'return', 'new', 'super', 'this', 'throw', 'else'}.contains(prev.text)) continue;
    final close = matching(t, i + 1);
    if (close < 0) continue;
    var k = close + 1;
    // Kotlin return type, Java throws clause
    while (k < c.bodyEnd && !t[k].is_('=') && !t[k].is_('{') && !t[k].is_(';')) {
      k++;
    }
    if (k >= c.bodyEnd) return _Override(null, null);
    if (t[k].is_(';')) return _Override(null, null); // abstract/interface: unknown
    if (t[k].is_('=')) {
      final v = k + 1;
      if (v < c.bodyEnd && t[v].kind == TokenKind.str) {
        final n = v + 1;
        final single = n >= c.bodyEnd || t[n].line > t[v].line || t[n].is_(';') || t[n].is_('}');
        if (single) return _Override(t[v].text, t[v]);
      }
      return _Override(null, null);
    }
    // block body: accept exactly `return "x" [;]`
    final end = matching(t, k);
    if (end < 0) return _Override(null, null);
    final inner = t.sublist(k + 1, end);
    if (inner.isNotEmpty && inner.first.is_('return') && inner.length >= 2 && inner[1].kind == TokenKind.str) {
      final rest = inner.sublist(2);
      if (rest.isEmpty || (rest.length == 1 && rest.first.is_(';'))) {
        return _Override(inner[1].text, inner[1]);
      }
    }
    return _Override(null, null);
  }
  return _Override.none();
}

class _Reach {
  _Reach(this.p);
  final AndroidProject p;
  ({Set<String> files, bool complete})? _r;
  File get mainFile => File('${p.root.path}/lib/main.dart');
  ({Set<String> files, bool complete})? get result {
    if (!mainFile.existsSync()) return null;
    return _r ??= reachableDartFiles(mainFile, '${p.root.path}/lib', p.pubspecName);
  }
}

void _reachabilityNote(AndroidProject p, List<DartFunction> decls, String fn, NativeClass c,
    List<String>? notes, _Reach reach) {
  if (notes == null) return;
  final r = reach.result;
  if (r == null) {
    notes.add('Dart entrypoint $fn() (used by ${c.name}) was not checked for reachability: lib/main.dart does not exist.');
    return;
  }
  final reachable = decls.where((d) => r.files.contains(d.file.absolute.path)).toList();
  if (reachable.isNotEmpty) return;
  if (!r.complete) {
    notes.add('Dart entrypoint $fn() (used by ${c.name}) is declared in ${decls.map((d) => p.rel(d.file)).join(', ')}, which was not found '
        'through the import graph of lib/main.dart, but some import/export/part URIs could not be resolved, so reachability is UNKNOWN.');
    return;
  }
  notes.add('Dart entrypoint $fn() (used by ${c.name}) is declared in ${decls.map((d) => p.rel(d.file)).join(', ')}, which lib/main.dart '
      'does not import or export (directly or transitively). A library that main never reaches is not part of the compiled program: '
      'in a release build of an isolated sample the function was absent from libapp.so until the file was imported. '
      'Not reported as a finding because the build target (flutter build -t) is not known; add an import to lib/main.dart if main.dart is the target.');
}
