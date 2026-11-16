import 'dart:io';

import '../ios/ios_project.dart';
import '../ios/plist.dart';
import '../models.dart';
import '../project.dart' show lineOf;
import '../source/lexer.dart';

const checkIosWidget = 'ios-widget-extension';

const _widgetKitPoint = 'com.apple.widgetkit-extension';
const _groupsKey = 'com.apple.security.application-groups';
const _pluginsSpec = '13'; // PBXCopyFilesBuildPhase dstSubfolderSpec for PlugIns / Foundation Extensions

class _Swift {
  _Swift(this.file, this.tokens);
  final File file;
  final List<Token> tokens;
  bool get importsWidgetKit {
    for (var i = 0; i + 1 < tokens.length; i++) {
      if (tokens[i].is_('import') && tokens[i + 1].kind == TokenKind.ident && tokens[i + 1].text == 'WidgetKit') {
        return true;
      }
    }
    return false;
  }
}

class _GroupUse {
  _GroupUse(this.group, this.file, this.line, this.evidence);
  final String group;
  final File file;
  final int line;
  final String evidence;
}

/// iOS WidgetKit checks (WF5001-WF5008).
///
/// Everything here is static and was NOT verified with Xcode or on a
/// simulator/device. Settings are read from the pbxproj and the xcconfig files
/// it references; whatever cannot be resolved is reported as a note, never as
/// a finding. Each rule documents the Apple/Flutter source it rests on.
List<Diagnostic> checkIosWidgets(IosProject ios, List<String> dartFiles, List<String> notes) {
  final out = <Diagnostic>[];
  final pbxRel = ios.rel(ios.pbxFile.path);
  final pbxText = ios.pbxFile.readAsStringSync();
  final seen = <String>{};
  void add(Diagnostic d) {
    if (seen.add('${d.code}|${d.file}|${d.line}|${d.evidence}')) out.add(d);
  }

  void note(String s) {
    if (!notes.contains(s)) notes.add(s);
  }

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

  /// Line of `KEY = ...` inside the build configuration [config] of [t] in the
  /// project file; null when the key is not set there (inherited from the project
  /// level or an .xcconfig file).
  int? settingLine(IosTarget t, String config, String key) {
    final id = ios.configurations(t).where((e) => e.key == config).map((e) => e.value).firstOrNull;
    if (id == null) return null;
    final m = RegExp('${RegExp.escape(id)}\\s*(?:/\\*[^*]*\\*/)?\\s*=\\s*\\{').firstMatch(pbxText);
    if (m == null) return null;
    final end = pbxText.indexOf('\n\t\t};', m.start);
    final k = pbxText.indexOf('$key = ', m.start);
    if (k < 0 || (end >= 0 && k > end)) return null;
    return '\n'.allMatches(pbxText.substring(0, k)).length + 1;
  }

  final targets = ios.targets;
  final apps = targets.where((t) => t.isApp).toList();
  final swiftCache = <String, List<_Swift>>{};
  List<_Swift> swiftOf(IosTarget t) => swiftCache.putIfAbsent(t.id, () {
        final s = ios.sources(t);
        return [
          for (final f in s.files)
            if (f.path.endsWith('.swift')) _Swift(f, tokenize(f.readAsStringSync(), Lang.kotlin))
        ];
      });

  // ---- identify widget extensions -------------------------------------
  final widgets = <IosTarget>[];
  for (final t in targets.where((t) => t.isAppExtension)) {
    var isWidget = swiftOf(t).any((s) => s.importsWidgetKit);
    if (!isWidget) {
      for (final c in ios.configurations(t)) {
        final v = ios.setting(t, c.key, 'INFOPLIST_FILE');
        if (v.value == null || v.unknown) continue;
        final f = File(_abs(ios, v.value!));
        if (!f.existsSync()) continue;
        try {
          final ext = readPlistFile(f)['NSExtension'];
          if (ext is Map && ext['NSExtensionPointIdentifier'] == _widgetKitPoint) isWidget = true;
        } on FormatException {
          // judged below only for targets that are widgets
        } on Exception {
          // unreadable: not identifiable
        }
      }
    }
    if (isWidget) widgets.add(t);
  }
  if (widgets.isEmpty) {
    note('iOS: no WidgetKit extension target was found in $pbxRel (no app-extension target imports WidgetKit or declares '
        '$_widgetKitPoint); iOS widget checks were skipped. An app without an iOS widget needs none.');
    return out;
  }

  // ---- Flutter-side group ids (home_widget's setAppGroupId, literal only) ----
  final dartGroups = <_GroupUse>[];
  for (final path in dartFiles) {
    final f = File(path);
    final toks = tokenize(f.readAsStringSync(), Lang.dart);
    for (var i = 0; i + 2 < toks.length; i++) {
      if (toks[i].kind == TokenKind.ident &&
          toks[i].text == 'setAppGroupId' &&
          toks[i + 1].is_('(') &&
          toks[i + 2].kind == TokenKind.str) {
        dartGroups.add(_GroupUse(toks[i + 2].text, f, toks[i + 2].line, "setAppGroupId('${toks[i + 2].text}')"));
      }
    }
  }

  for (final w in widgets) {
    final configs = ios.configurations(w).map((e) => e.key).toList();
    // Line of the target's own object declaration (`<id> /* name */ = {`), found by object id so that a
    // PBXGroup or another object with the same name is never mistaken for it.
    final wDecl = RegExp('(?:^|\\n)[ \\t]*${RegExp.escape(w.id)}\\s*(?:/\\*[^*]*\\*/)?\\s*=\\s*\\{').firstMatch(pbxText);
    final wLine = wDecl != null
        ? '\n'.allMatches(pbxText.substring(0, wDecl.end)).length + 1
        : lineOf(pbxText, 'name = ${w.name};');

    // host app: the app target that embeds the widget; else a single app / "Runner"
    IosTarget? host;
    final productRef = w.productReference;
    for (final a in apps) {
      for (final phaseId in a.buildPhaseIds) {
        final ph = ios.obj(phaseId);
        if (ph?['isa'] != 'PBXCopyFilesBuildPhase' || '${ph?['dstSubfolderSpec']}' != _pluginsSpec) continue;
        for (final bf in (ph!['files'] as List? ?? const [])) {
          if (ios.obj(bf as String)?['fileRef'] == productRef) host = a;
        }
      }
    }
    // ---- WF5001 -------------------------------------------------------
    if (host == null && apps.isNotEmpty && productRef != null) {
      add(mk(
        'WF5001',
        'Widget extension is not embedded in an app target',
        'Target "${w.name}" is a WidgetKit extension, but its product is not in an "Embed Foundation Extensions" / PlugIns '
            '(destination 13) copy-files build phase of any app target (${apps.map((a) => a.name).join(', ')}). '
            'An extension that is not embedded is not part of the built app. This is judged from the project file only; '
            'other ways of embedding (for example a script phase) are not recognized.',
        'In Xcode, select the app target > Build Phases > Embed Foundation Extensions and add ${w.name}.appex '
            '(and keep that phase above "Run Script"/"Thin Binary" as the Flutter extension guide describes).',
        pbxRel,
        wLine,
        'PBXNativeTarget "${w.name}" (app-extension): product not embedded by ${apps.map((a) => a.name).join('/')}',
      ));
    }
    host ??= apps.where((a) => a.name == 'Runner').firstOrNull ?? (apps.length == 1 ? apps.first : null);
    if (host == null) {
      note('iOS: no host app target found for widget extension "${w.name}"; bundle identifier, entitlement and embedding '
          'checks that compare with the app were skipped.');
    }

    // ---- WF5003 / WF5002: Info.plist ---------------------------------------
    final infoByValue = <String, List<String>>{}; // INFOPLIST_FILE -> configs
    var generated = false;
    for (final c in configs) {
      final v = ios.setting(w, c, 'INFOPLIST_FILE');
      final gen = ios.setting(w, c, 'GENERATE_INFOPLIST_FILE');
      if (gen.value == 'YES') generated = true;
      if (v.unknown) {
        note('iOS: INFOPLIST_FILE of "${w.name}" ($c) depends on a setting WidgetForge cannot resolve; its Info.plist was not checked.');
      } else if (v.value != null) {
        infoByValue.putIfAbsent(v.value!, () => []).add(c);
      }
    }
    if (infoByValue.isEmpty) {
      if (generated) {
        note('iOS: "${w.name}" uses GENERATE_INFOPLIST_FILE without an INFOPLIST_FILE; NSExtension could not be checked.');
      } else if (!configs.any((c) => ios.setting(w, c, 'INFOPLIST_FILE').unknown)) {
        add(mk(
          'WF5003',
          'Widget extension has no Info.plist',
          'Target "${w.name}" has no INFOPLIST_FILE and does not generate an Info.plist, so the extension has no '
              'NSExtension declaration.',
          'Add an Info.plist with NSExtension > NSExtensionPointIdentifier = $_widgetKitPoint and set INFOPLIST_FILE.',
          pbxRel,
          wLine,
          'PBXNativeTarget "${w.name}": INFOPLIST_FILE not set',
        ));
      }
    }
    for (final e in infoByValue.entries) {
      final path = _abs(ios, e.key);
      final f = File(path);
      final cfgs = e.value.join(', ');
      final line = settingLine(w, e.value.first, 'INFOPLIST_FILE') ?? wLine;
      if (!f.existsSync()) {
        add(mk(
          'WF5003',
          'Widget extension Info.plist not found',
          'INFOPLIST_FILE of target "${w.name}" points to a file that does not exist ($cfgs).',
          'Create the file or correct INFOPLIST_FILE.',
          pbxRel,
          line,
          'INFOPLIST_FILE = ${e.key}',
        ));
        continue;
      }
      Map<String, Object> plist;
      try {
        plist = readPlistFile(f);
      } on FormatException catch (ex) {
        if (ex.message.contains('binary')) {
          note('iOS: ${ios.rel(path)} is a binary property list; it was not checked.');
        } else {
          add(mk('WF5003', 'Widget extension Info.plist is not a valid property list', ex.message,
              'Fix the XML property list syntax.', ios.rel(path), 1, ex.message));
        }
        continue;
      } on Exception catch (ex) {
        add(mk('WF5003', 'Widget extension Info.plist is not well-formed', '$ex',
            'Fix the XML property list syntax.', ios.rel(path), 1, '$ex'.split('\n').first));
        continue;
      }
      final plistText = f.readAsStringSync();
      final ext = plist['NSExtension'];
      final point = ext is Map ? ext['NSExtensionPointIdentifier'] : null;
      if (point != _widgetKitPoint) {
        add(mk(
          'WF5002',
          'Widget extension Info.plist does not declare the WidgetKit extension point',
          point == null
              ? 'Info.plist of "${w.name}" has no NSExtension > NSExtensionPointIdentifier. A WidgetKit extension is '
                  'declared with NSExtensionPointIdentifier = $_widgetKitPoint (the value used by Xcode\'s Widget Extension template; '
                  'not stated on the Apple pages that could be read).'
              : 'NSExtensionPointIdentifier is "$point", but target "${w.name}" is a WidgetKit extension '
                  '(expected $_widgetKitPoint, the Xcode Widget Extension template value).',
          'Set NSExtension > NSExtensionPointIdentifier to $_widgetKitPoint in ${ios.rel(path)}.',
          ios.rel(path),
          lineOf(plistText, 'NSExtensionPointIdentifier') ?? lineOf(plistText, 'NSExtension') ?? 1,
          point == null ? 'NSExtension/NSExtensionPointIdentifier missing' : 'NSExtensionPointIdentifier = $point',
        ));
      }
    }

    // ---- WF5004: bundle identifier prefix --------------------------------------
    if (host != null) {
      final bad = <String, List<String>>{}; // "ext|host" -> configurations
      for (final c in configs) {
        final wb = ios.setting(w, c, 'PRODUCT_BUNDLE_IDENTIFIER');
        final hb = ios.setting(host, c, 'PRODUCT_BUNDLE_IDENTIFIER');
        if (wb.unknown || hb.unknown || wb.value == null || hb.value == null ||
            wb.value!.contains(r'$(') || hb.value!.contains(r'$(')) {
          bool bad0(SettingValue s) => s.unknown || s.value == null || s.value!.contains(r'$(');
          final which = [if (bad0(wb)) '"${w.name}"', if (bad0(hb)) '"${host.name}"'].join(' and ');
          note('iOS: PRODUCT_BUNDLE_IDENTIFIER of $which ($c) depends on a setting WidgetForge cannot resolve; '
              'the bundle identifier prefix was not checked for that configuration.');
          continue;
        }
        if (!wb.value!.startsWith('${hb.value}.')) bad.putIfAbsent('${wb.value}|${hb.value}', () => []).add(c);
      }
      for (final e in bad.entries) {
        final parts = e.key.split('|');
        add(mk(
          'WF5004',
          'Widget extension bundle identifier is not prefixed with the app bundle identifier',
          'The extension "${w.name}" has PRODUCT_BUNDLE_IDENTIFIER "${parts[0]}" but its host app "${host.name}" has '
              '"${parts[1]}" (${e.value.join(', ')}). An app extension\'s bundle identifier must start with the containing app\'s bundle '
              'identifier followed by a dot (Apple app-extension requirement; not stated on the pages that could be read, '
              'not verified with Xcode).',
          'Use "${parts[1]}.<extension suffix>" for the extension\'s PRODUCT_BUNDLE_IDENTIFIER.',
          pbxRel,
          settingLine(w, e.value.first, 'PRODUCT_BUNDLE_IDENTIFIER') ?? wLine,
          'PRODUCT_BUNDLE_IDENTIFIER = ${parts[0]} (host: ${parts[1]}; ${e.value.join(', ')})',
        ));
      }
    }

    // ---- WF5008: deployment target ----------------------------------------------
    final low = <String, List<String>>{}; // value -> configurations
    for (final c in configs) {
      final d = ios.setting(w, c, 'IPHONEOS_DEPLOYMENT_TARGET');
      if (d.unknown) {
        note('iOS: IPHONEOS_DEPLOYMENT_TARGET of "${w.name}" ($c) depends on a setting WidgetForge cannot resolve; it was not checked.');
        continue;
      }
      if (d.value == null) continue;
      final major = double.tryParse(d.value!.split('.').first);
      if (major != null && major < 14) low.putIfAbsent(d.value!, () => []).add(c);
    }
    for (final e in low.entries) {
      add(mk(
        'WF5008',
        'Widget extension deployment target is below iOS 14',
        'IPHONEOS_DEPLOYMENT_TARGET of "${w.name}" is ${e.key} (${e.value.join(', ')}). WidgetKit requires iOS 14.0 or newer '
            '(API availability of WidgetKit; not stated on the pages that could be read, not verified with Xcode).',
        'Set IPHONEOS_DEPLOYMENT_TARGET of the widget extension to 14.0 or higher.',
        pbxRel,
        settingLine(w, e.value.first, 'IPHONEOS_DEPLOYMENT_TARGET') ?? wLine,
        'IPHONEOS_DEPLOYMENT_TARGET = ${e.key} (${e.value.join(', ')})',
      ));
    }

    // ---- WF5005 / WF5006: entitlements and App Groups ---------------------------
    final missingEnt = <String, (IosTarget, String, List<String>)>{};
    Map<String, Set<String>?> groupsOf(IosTarget t) {
      final res = <String, Set<String>?>{};
      for (final c in ios.configurations(t).map((e) => e.key)) {
        final v = ios.setting(t, c, 'CODE_SIGN_ENTITLEMENTS');
        if (v.unknown) {
          res[c] = null;
          continue;
        }
        if (v.value == null) {
          res[c] = <String>{}; // no entitlements file: no groups
          continue;
        }
        final f = File(_abs(ios, v.value!));
        if (!f.existsSync()) {
          missingEnt.putIfAbsent('${t.id}|${v.value}', () => (t, v.value!, <String>[])).$3.add(c);
          res[c] = null;
          continue;
        }
        try {
          final g = readPlistFile(f)[_groupsKey];
          res[c] = g is List ? {for (final x in g) if (x is String) x} : <String>{};
        } on Exception {
          note('iOS: ${ios.rel(f.path)} could not be read as an XML property list; its App Groups were not checked.');
          res[c] = null;
        }
      }
      return res;
    }

    final wGroups = groupsOf(w);
    final hGroups = host == null ? <String, Set<String>?>{} : groupsOf(host);
    for (final e in missingEnt.values) {
      final (t, value, cfgs) = e;
      add(mk(
        'WF5005',
        'Entitlements file referenced by the target does not exist',
        'CODE_SIGN_ENTITLEMENTS of target "${t.name}" (${cfgs.join(', ')}) points to "$value", which does not exist.',
        'Create the entitlements file or correct CODE_SIGN_ENTITLEMENTS.',
        pbxRel,
        settingLine(t, cfgs.first, 'CODE_SIGN_ENTITLEMENTS') ?? lineOf(pbxText, 'CODE_SIGN_ENTITLEMENTS'),
        'CODE_SIGN_ENTITLEMENTS = $value (${cfgs.join(', ')})',
      ));
    }

    // Swift literals in the extension's own sources
    final uses = <_GroupUse>[];
    for (final s in swiftOf(w)) {
      for (var i = 0; i + 2 < s.tokens.length; i++) {
        final t = s.tokens[i];
        if (t.kind == TokenKind.ident &&
            (t.text == 'suiteName' || t.text == 'forSecurityApplicationGroupIdentifier') &&
            s.tokens[i + 1].is_(':') &&
            s.tokens[i + 2].kind == TokenKind.str) {
          uses.add(_GroupUse(s.tokens[i + 2].text, s.file, s.tokens[i + 2].line, '${t.text}: "${s.tokens[i + 2].text}"'));
        }
      }
    }
    for (final u in uses) {
      final missing = [
        for (final e in wGroups.entries)
          if (e.value != null && !e.value!.contains(u.group)) e.key
      ];
      if (missing.isNotEmpty) {
        add(mk(
          'WF5006',
          'App Group used by the widget extension is not in its entitlements',
          'The extension "${w.name}" uses the App Group "${u.group}", but the extension\'s entitlements do not list it '
              '(${missing.join(', ')}). Shared container/UserDefaults access needs the group in the entitlements of '
              'every target that uses it.',
          'Add "${u.group}" to com.apple.security.application-groups in the extension\'s entitlements file and enable the App Groups capability.',
          ios.rel(u.file.path),
          u.line,
          u.evidence,
        ));
      }
    }
    final disjoint = <String, List<String>>{};
    for (final c in configs) {
      final wg = wGroups[c];
      final hg = hGroups[c];
      if (wg != null && hg != null && wg.isNotEmpty && hg.isNotEmpty && wg.intersection(hg).isEmpty) {
        disjoint.putIfAbsent('${(wg.toList()..sort()).join(', ')}|${(hg.toList()..sort()).join(', ')}', () => []).add(c);
      }
    }
    for (final e in disjoint.entries) {
      final parts = e.key.split('|');
      add(mk(
        'WF5006',
        'Widget extension and app use different App Groups',
        'The extension "${w.name}" lists App Groups {${parts[0]}} and the host app "${host!.name}" lists '
            '{${parts[1]}} (${e.value.join(', ')}): they share no group, so they cannot share data through an App Group container.',
        'Use the same App Group identifier in the entitlements of the app and the widget extension.',
        pbxRel,
        settingLine(w, e.value.first, 'CODE_SIGN_ENTITLEMENTS') ?? wLine,
        'App Groups: extension {${parts[0]}} vs app {${parts[1]}} (${e.value.join(', ')})',
      ));
    }
    // Flutter-side declaration: observation only (the API semantics were not verified)
    for (final g in dartGroups) {
      for (final c in configs) {
        final hg = hGroups[c];
        final wg = wGroups[c];
        if (hg != null && !hg.contains(g.group)) {
          note('iOS: ${ios.rel(g.file.path)}:${g.line} sets App Group "${g.group}" (${g.evidence}) but the app target '
              '"${host?.name}" does not list it in its entitlements ($c). Not reported as a finding (Flutter-side usage is not verified).');
          break;
        }
        if (wg != null && wg.isNotEmpty && !wg.contains(g.group)) {
          note('iOS: ${ios.rel(g.file.path)}:${g.line} sets App Group "${g.group}" but the widget extension "${w.name}" '
              'lists a different group set ($c). Not reported as a finding.');
          break;
        }
      }
    }

    // ---- WF5007: entry point --------------------------------------------------
    final sw = swiftOf(w);
    final srcs = ios.sources(w);
    if (!srcs.complete || sw.isEmpty) {
      note('iOS: the Swift sources of "${w.name}" could not be fully enumerated (missing files, Swift packages or '
          'unsupported source trees); the @main entry point was not checked.');
    } else {
      var hasMain = false;
      for (final s in sw) {
        for (var i = 0; i + 1 < s.tokens.length; i++) {
          if (s.tokens[i].is_('@') && s.tokens[i + 1].kind == TokenKind.ident && s.tokens[i + 1].text == 'main') {
            hasMain = true;
          }
        }
      }
      if (!hasMain) {
        add(mk(
          'WF5007',
          'Widget extension has no @main entry point',
          'None of the ${sw.length} Swift source file(s) of "${w.name}" contains an @main attribute. The WidgetKit '
              'documentation shows the extension\'s entry point as an @main Widget (or WidgetBundle for several widgets). '
              'Sources compiled from other targets, Swift packages or Objective-C are not considered.',
          'Mark the Widget or WidgetBundle type of the extension with @main.',
          pbxRel,
          wLine,
          'no @main in ${sw.map((s) => ios.rel(s.file.path)).take(3).join(', ')}${sw.length > 3 ? ', ...' : ''}',
        ));
      }
    }
  }
  return out;
}

String _abs(IosProject ios, String v) => v.startsWith('/') ? v : '${ios.projectDir.path}/$v';
