import 'dart:io';

import 'package:path/path.dart' as p;

import 'pbxproj.dart';

/// A value of an Xcode build setting after variable expansion.
class SettingValue {
  const SettingValue(this.value, {this.unknown = false});

  /// Expanded value; null when the setting is not set in the files we can read.
  final String? value;

  /// True when the value depends on something WidgetTriage cannot resolve
  /// (unreadable xcconfig, unsupported variable/modifier, conditional setting).
  final bool unknown;
}

class IosTarget {
  IosTarget(this.id, this.data);
  final String id;
  final Map<String, Object> data;
  String get name => (data['name'] as String?) ?? id;
  String get productType => (data['productType'] as String?) ?? '';
  bool get isApp => productType == 'com.apple.product-type.application';
  bool get isAppExtension => productType == 'com.apple.product-type.app-extension';
  List<String> get buildPhaseIds => [for (final x in (data['buildPhases'] as List? ?? const [])) x as String];
  String? get productReference => data['productReference'] as String?;
  List<String> get syncedGroupIds =>
      [for (final x in (data['fileSystemSynchronizedGroups'] as List? ?? const [])) x as String];
  bool get hasPackageDependencies => ((data['packageProductDependencies'] as List?) ?? const []).isNotEmpty;
}

class IosSources {
  IosSources(this.files, this.complete);

  /// Source files of the target that exist on disk.
  final List<File> files;

  /// False when some source could not be located or enumerated (missing files,
  /// unsupported source trees). A negative statement ("no X in the sources")
  /// is only trustworthy when this is true.
  final bool complete;
}

/// Read-only model of ios/*.xcodeproj/project.pbxproj.
class IosProject {
  IosProject._(this.root, this.pbxFile, this.projectDir, this.objects, this.rootObjectId);

  final Directory root; // Flutter project root
  final File pbxFile;
  final Directory projectDir; // directory containing the .xcodeproj (SRCROOT)
  final Map<String, Map<String, Object>> objects;
  final String rootObjectId;

  /// Dart sources of the Flutter project (lib/ and bin/).
  List<String> get dartSources {
    final out = <String>[];
    for (final sub in ['lib', 'bin']) {
      final d = Directory(p.join(root.path, sub));
      if (!d.existsSync()) continue;
      out.addAll(d.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart')).map((f) => f.path));
    }
    out.sort();
    return out;
  }

  String rel(String path) => p.relative(path, from: root.path).replaceAll('\\', '/');

  /// Finds ios/*.xcodeproj. Returns null when the project has no iOS project;
  /// throws [FormatException] when the project file cannot be parsed.
  static IosProject? load(Directory root) {
    final ios = Directory(p.join(root.path, 'ios'));
    if (!ios.existsSync()) return null;
    final projs = ios.listSync().whereType<Directory>().where((d) => d.path.endsWith('.xcodeproj')).toList()
      ..sort((a, b) {
        final ar = p.basename(a.path) == 'Runner.xcodeproj' ? 0 : 1;
        final br = p.basename(b.path) == 'Runner.xcodeproj' ? 0 : 1;
        return ar != br ? ar - br : a.path.compareTo(b.path);
      });
    for (final d in projs) {
      final f = File(p.join(d.path, 'project.pbxproj'));
      if (!f.existsSync()) continue;
      final parsed = parseAsciiPlist(f.readAsStringSync());
      if (parsed is! Map<String, Object>) throw const FormatException('top-level value is not a dictionary');
      final objs = parsed['objects'];
      final rootObj = parsed['rootObject'];
      if (objs is! Map<String, Object> || rootObj is! String) {
        throw const FormatException('missing objects/rootObject');
      }
      final m = <String, Map<String, Object>>{};
      for (final e in objs.entries) {
        if (e.value is Map<String, Object>) m[e.key] = e.value as Map<String, Object>;
      }
      return IosProject._(root, f, d.parent, m, rootObj);
    }
    return null;
  }

  Map<String, Object>? obj(String? id) => id == null ? null : objects[id];

  List<IosTarget> get targets {
    final proj = obj(rootObjectId);
    final ids = [for (final x in (proj?['targets'] as List? ?? const [])) x as String];
    return [
      for (final id in ids)
        if (obj(id)?['isa'] == 'PBXNativeTarget') IosTarget(id, obj(id)!)
    ];
  }

  // ---- build settings -------------------------------------------------

  List<MapEntry<String, String>> configurations(IosTarget t) => _configs(t.data['buildConfigurationList'] as String?);

  List<MapEntry<String, String>> _configs(String? listId) {
    final l = obj(listId);
    return [
      for (final id in (l?['buildConfigurations'] as List? ?? const []))
        if (obj(id as String) != null) MapEntry((obj(id)!['name'] as String?) ?? '', id)
    ];
  }

  Map<String, String> _flatSettings(Map<String, Object>? cfg) {
    final out = <String, String>{};
    final bs = cfg?['buildSettings'];
    if (bs is Map<String, Object>) {
      for (final e in bs.entries) {
        final v = e.value;
        out[e.key] = v is String ? v : (v is List ? v.whereType<String>().join(' ') : '');
      }
    }
    return out;
  }

  /// xcconfig referenced by [cfg] (baseConfigurationReference), includes followed.
  /// Returns (settings, complete).
  (Map<String, String>, bool) _xcconfig(Map<String, Object>? cfg) {
    final ref = cfg?['baseConfigurationReference'];
    if (ref is! String) return (<String, String>{}, true);
    final path = filePath(ref);
    if (path == null) return (<String, String>{}, false);
    return _readXcconfig(File(path), 0);
  }

  (Map<String, String>, bool) _readXcconfig(File f, int depth) {
    if (depth > 8 || !f.existsSync()) return (<String, String>{}, false);
    final parsed = parseXcconfig(f.readAsStringSync());
    final out = <String, String>{};
    var ok = true;
    for (final inc in parsed.includes) {
      final (s, c) = _readXcconfig(File(p.normalize(p.join(f.parent.path, inc))), depth + 1);
      out.addAll(s);
      ok = ok && c;
    }
    out.addAll(parsed.settings);
    return (out, ok);
  }

  /// Value of [key] for target [t] in configuration [config]: target settings
  /// over target xcconfig over project settings over project xcconfig.
  /// `$(inherited)` and `$(VAR)` are expanded; anything unresolved makes the
  /// result `unknown` instead of guessing.
  SettingValue setting(IosTarget t, String config, String key) {
    final proj = obj(rootObjectId);
    String? idOf(List<MapEntry<String, String>> l) => l.where((e) => e.key == config).map((e) => e.value).firstOrNull;
    final tCfg = obj(idOf(configurations(t)));
    final pCfg = obj(idOf(_configs(proj?['buildConfigurationList'] as String?)));
    final (tx, tOk) = _xcconfig(tCfg);
    final (px, pOk) = _xcconfig(pCfg);
    final layers = <Map<String, String>>[_flatSettings(tCfg), tx, _flatSettings(pCfg), px];
    final complete = tOk && pOk;

    String? raw(String k, int from, Set<String> guard) {
      for (var i = from; i < layers.length; i++) {
        final v = layers[i][k];
        if (v == null) continue;
        return v.replaceAllMapped(RegExp(r'\$[({]inherited[)}]'), (_) => raw(k, i + 1, guard) ?? '');
      }
      return null;
    }

    var unknown = false;
    String? expand(String? v, int depth) {
      if (v == null) return null;
      if (depth > 10) {
        unknown = true;
        return v;
      }
      return v.replaceAllMapped(RegExp(r'\$[({]([A-Za-z0-9_]+)(?::([A-Za-z0-9]+))?[)}]'), (m) {
        final name = m.group(1)!;
        final mod = m.group(2);
        String? val;
        switch (name) {
          case 'SRCROOT':
          case 'PROJECT_DIR':
            val = projectDir.path;
          case 'TARGET_NAME':
            val = t.name;
          default:
            val = expand(raw(name, 0, {}), depth + 1);
        }
        if (val == null) {
          unknown = true;
          return m.group(0)!;
        }
        if (mod == 'rfc1034identifier') {
          val = val.replaceAll(RegExp(r'[^A-Za-z0-9.-]'), '-');
        } else if (mod != null) {
          unknown = true;
        }
        return val;
      });
    }

    final r = raw(key, 0, {});
    final v = expand(r, 0);
    return SettingValue(v, unknown: unknown || (!complete && r == null));
  }

  // ---- files ----------------------------------------------------------

  Map<String, String>? _parents;

  String? _parentOf(String id) {
    if (_parents == null) {
      _parents = {};
      for (final e in objects.entries) {
        final isa = e.value['isa'];
        if (isa == 'PBXGroup' || isa == 'PBXVariantGroup' || isa == 'PBXFileSystemSynchronizedRootGroup') {
          for (final c in (e.value['children'] as List? ?? const [])) {
            _parents![c as String] = e.key;
          }
        }
      }
    }
    return _parents![id];
  }

  /// Absolute path of a file reference or group, or null when its source tree
  /// is not one WidgetTriage understands (e.g. BUILT_PRODUCTS_DIR, SDKROOT).
  String? filePath(String id) {
    final o = obj(id);
    if (o == null) return null;
    final path = o['path'] as String?;
    final tree = (o['sourceTree'] as String?) ?? '<group>';
    switch (tree) {
      case '<absolute>':
        return path;
      case 'SOURCE_ROOT':
        return path == null ? projectDir.path : p.normalize(p.join(projectDir.path, path));
      case '<group>':
        final parent = _parentOf(id);
        String? base;
        if (parent == null) {
          base = projectDir.path;
          final pd = obj(rootObjectId)?['projectDirPath'] as String?;
          if (pd != null && pd.isNotEmpty) base = p.normalize(p.join(base, pd));
        } else {
          base = filePath(parent);
        }
        if (base == null) return null;
        return path == null ? base : p.normalize(p.join(base, path));
      default:
        return null;
    }
  }

  /// Source files compiled into [t].
  IosSources sources(IosTarget t) {
    final files = <File>[];
    var complete = !t.hasPackageDependencies;
    for (final phaseId in t.buildPhaseIds) {
      final ph = obj(phaseId);
      if (ph?['isa'] != 'PBXSourcesBuildPhase') continue;
      for (final bf in (ph!['files'] as List? ?? const [])) {
        final fr = obj(obj(bf as String)?['fileRef'] as String?);
        final refId = obj(bf)?['fileRef'] as String?;
        if (fr == null || refId == null) {
          complete = false;
          continue;
        }
        final path = filePath(refId);
        if (path == null || !File(path).existsSync()) {
          complete = false;
          continue;
        }
        files.add(File(path));
      }
    }
    // Xcode 16 folder-based targets: every file in the synchronized folder.
    for (final gid in t.syncedGroupIds) {
      final dir = filePath(gid);
      final g = obj(gid);
      if (dir == null || !Directory(dir).existsSync()) {
        complete = false;
        continue;
      }
      final excluded = <String>{};
      for (final es in (g?['exceptions'] as List? ?? const [])) {
        final eo = obj(es as String);
        if (eo?['isa'] == 'PBXFileSystemSynchronizedBuildFileExceptionSet' && eo?['target'] == t.id) {
          for (final x in (eo!['membershipExceptions'] as List? ?? const [])) {
            excluded.add(p.normalize(p.join(dir, x as String)));
          }
        } else if (eo != null && eo['target'] != t.id) {
          // exception set of another target: irrelevant here
        }
      }
      for (final e in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (!excluded.contains(p.normalize(e.path))) files.add(e);
      }
    }
    return IosSources(files, complete);
  }
}
