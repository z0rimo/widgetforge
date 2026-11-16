import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:widgetforge/widgetforge.dart';

const _usage = '''
widgetforge $toolVersion - read-only doctor for Flutter Android and iOS home screen widgets

Usage: widgetforge doctor [--json] [path]
       widgetforge verify [--json] <file.apk|file.ipa>

doctor reads a Flutter project's source. verify reads a built .apk or .ipa
(read-only, never extracted to disk, never executed).

Exit codes: 0 = no errors, 1 = errors found,
            2 = usage / not a Flutter project / archive unsupported, unsafe or unreadable.
''';

Never _fail(String msg) {
  stderr.writeln(msg);
  exit(2);
}

void main(List<String> args) {
  final parser = ArgParser()
    ..addFlag('json', negatable: false, help: 'Emit machine-readable JSON.')
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this usage.')
    ..addFlag('version', negatable: false, help: 'Print the version.');
  ArgResults res;
  try {
    res = parser.parse(args);
  } on FormatException catch (e) {
    _fail('${e.message}\n$_usage${parser.usage}');
  }
  if (res['help'] as bool) {
    stdout.write('$_usage${parser.usage}\n');
    return;
  }
  if (res['version'] as bool) {
    stdout.writeln('widgetforge $toolVersion');
    return;
  }
  final rest = res.rest;
  if (rest.isNotEmpty && rest.first == 'verify') {
    if (rest.length != 2) _fail('widgetforge: verify needs exactly one .apk or .ipa file\n$_usage${parser.usage}');
    Report report;
    try {
      report = verifyArtifact(rest[1]);
    } on ArchiveException catch (e) {
      _fail('widgetforge: ${e.message}');
    }
    if (res['json'] as bool) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
    } else {
      stdout.write(formatHuman(report, command: 'verify'));
    }
    exit(report.hasErrors ? 1 : 0);
  }
  if (rest.isEmpty || rest.first != 'doctor' || rest.length > 2) {
    _fail('$_usage${parser.usage}');
  }
  final path = rest.length == 2 ? rest[1] : '.';
  final loaded = loadProjects(path, (m) => _fail('widgetforge: $m'));
  final report = runDoctor(loaded!.android, ios: loaded.ios, loadNotes: loaded.notes);
  if (res['json'] as bool) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report.toJson()));
  } else {
    stdout.write(formatHuman(report));
  }
  exit(report.hasErrors ? 1 : 0);
}
