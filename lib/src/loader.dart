import 'dart:io';

import 'package:path/path.dart' as p;

import 'ios/ios_project.dart';
import 'project.dart';

/// What could be loaded from a Flutter project root.
class LoadedProjects {
  LoadedProjects(this.root, this.android, this.ios, this.notes);
  final Directory root;
  final AndroidProject? android;
  final IosProject? ios;

  /// Remarks produced while loading (for example an unparseable iOS project).
  final List<String> notes;
}

/// Loads the Android and/or iOS side of the Flutter project at [path].
///
/// Android-only, iOS-only and combined projects are supported. A platform
/// without its project files is simply absent (no note, no finding). Returns
/// null after calling [error] when nothing can be analyzed.
LoadedProjects? loadProjects(String path, void Function(String) error) {
  final root = Directory(path).absolute;
  if (!File(p.join(root.path, 'pubspec.yaml')).existsSync()) {
    error('No pubspec.yaml in ${root.path}; not a Flutter project root.');
    return null;
  }
  final notes = <String>[];
  AndroidProject? android;
  final manifest = File(p.join(root.path, 'android', 'app', 'src', 'main', 'AndroidManifest.xml'));
  var failed = false;
  if (manifest.existsSync()) {
    android = AndroidProject.load(path, (m) {
      error(m);
      failed = true;
    });
    if (failed || android == null) return null;
  }
  IosProject? ios;
  String? iosProblem;
  try {
    ios = IosProject.load(root);
  } on FormatException catch (e) {
    iosProblem = 'The iOS project file could not be parsed (${e.message}); iOS checks were not run.';
  }
  if (android == null && ios == null) {
    error(iosProblem != null
        ? 'iOS: $iosProblem'
        : 'Neither android/app/src/main/AndroidManifest.xml nor ios/*.xcodeproj/project.pbxproj was found.');
    return null;
  }
  if (iosProblem != null) notes.add('iOS: $iosProblem');
  return LoadedProjects(root, android, ios, notes);
}
