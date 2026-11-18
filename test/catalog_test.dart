/// Rule catalog (schema/rule-catalog.json) consistency with the implementation,
/// docs/errors, the README table and the report schema (which validates only
/// the ID *format*, not existence).
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:widgettriage/widgettriage.dart';

import 'accuracy_test.dart' show validate;

final idPattern = RegExp(r'^WF[0-9]{4}$');

/// Structural validation of a catalog document; returns problems.
List<String> catalogProblems(Object? doc) {
  final errs = <String>[];
  if (doc is! Map || doc['rules'] is! List) return ['catalog: missing rules list'];
  final seen = <String>{};
  for (final r in doc['rules'] as List) {
    if (r is! Map) {
      errs.add('rule is not an object');
      continue;
    }
    final id = r['id'];
    if (id is! String || !idPattern.hasMatch(id)) {
      errs.add('bad rule id: $id');
      continue;
    }
    if (!seen.add(id)) errs.add('duplicate rule id: $id');
    for (final k in ['platform', 'command', 'severity', 'maturity', 'title', 'docs']) {
      if (r[k] is! String || (r[k] as String).isEmpty) errs.add('$id: missing $k');
    }
    if (!const {'android', 'ios'}.contains(r['platform'])) errs.add('$id: platform');
    if (!const {'doctor', 'verify'}.contains(r['command'])) errs.add('$id: command');
    if (!const {'error', 'warning', 'info'}.contains(r['severity'])) errs.add('$id: severity');
    if (!const {'tested', 'experimental'}.contains(r['maturity'])) errs.add('$id: maturity');
  }
  return errs;
}

void main() {
  final catalog = jsonDecode(File('schema/rule-catalog.json').readAsStringSync()) as Map<String, dynamic>;
  final rules = (catalog['rules'] as List).cast<Map<String, dynamic>>();
  final ids = rules.map((r) => r['id'] as String).toSet();

  test('catalog is well formed, has no duplicates, and lists 29 rules', () {
    expect(catalogProblems(catalog), isEmpty);
    expect(rules.length, ids.length);
    expect(ids.length, 29);
    expect(catalog['catalogVersion'], '1');
  });

  test('catalog validator rejects duplicates, bad formats and missing fields', () {
    Map<String, dynamic> rule(String id) => {...rules.first, 'id': id};
    expect(catalogProblems({'rules': [rule('WF1001'), rule('WF1001')]}), contains('duplicate rule id: WF1001'));
    for (final bad in ['wf1001', 'WF100', 'WF10011', 'XX1001', '', 'WF1001 ']) {
      expect(catalogProblems({'rules': [rule(bad)]}), isNotEmpty, reason: bad);
    }
    expect(catalogProblems({'rules': [{'id': 'WF9999'}]}), isNotEmpty);
    expect(catalogProblems({'nope': 1}), isNotEmpty);
  });

  test('catalog equals the set of codes the implementation can emit', () {
    final used = <String>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      used.addAll(RegExp(r"'(WF[0-9]{4})'").allMatches(f.readAsStringSync()).map((m) => m.group(1)!));
    }
    expect(used.difference(ids), isEmpty, reason: 'emitted by code but not in catalog');
    expect(ids.difference(used), isEmpty, reason: 'in catalog but never emitted by code');
  });

  test('each rule has a docs page whose title equals the catalog title, and no extra pages exist', () {
    for (final r in rules) {
      final f = File(r['docs'] as String);
      expect(f.existsSync(), isTrue, reason: r['docs'] as String);
      expect(r['docs'], 'docs/errors/${r['id']}.md');
      expect(f.readAsLinesSync().first, '# ${r['id']}: ${r['title']}');
    }
    final pages = Directory('docs/errors').listSync().whereType<File>().map((f) => f.uri.pathSegments.last).where((n) => n.startsWith('WF')).map((n) => n.replaceAll('.md', '')).toSet();
    expect(pages, ids);
  });

  test('family, platform and command agree; verify rules are exactly WF6xxx/WF7xxx', () {
    for (final r in rules) {
      final fam = (r['id'] as String)[2];
      expect(r['command'], '67'.contains(fam) ? 'verify' : 'doctor', reason: r['id'] as String);
      expect(r['platform'], '567'.contains(fam) && fam != '6' ? 'ios' : 'android', reason: r['id'] as String);
      expect(r['maturity'], r['platform'] == 'ios' ? 'experimental' : 'tested', reason: r['id'] as String);
    }
  });

  test('README table lists exactly the catalog rules', () {
    final readme = File('README.md').readAsStringSync();
    final listed = RegExp(r'\| \[(WF[0-9]{4})\]\(docs/errors/\1\.md\)').allMatches(readme).map((m) => m.group(1)!).toList();
    expect(listed.toSet(), ids);
    expect(listed.length, ids.length, reason: 'duplicate README rows');
  });

  test('docs/verify-contract.md lists every verify rule', () {
    final doc = File('docs/verify-contract.md').readAsStringSync();
    for (final r in rules.where((r) => r['command'] == 'verify')) {
      expect(doc, contains('[${r['id']}](errors/${r['id']}.md)'));
    }
  });

  test('SKILL.md covers every rule ID (by ID or range)', () {
    final skill = File('skills/widgettriage/SKILL.md').readAsStringSync();
    final ranges = RegExp(r'WF([0-9]{4})-(?:WF)?([0-9]{1,4})').allMatches(skill).map((m) {
      final lo = int.parse(m.group(1)!);
      final hiRaw = m.group(2)!;
      final hi = hiRaw.length == 4 ? int.parse(hiRaw) : (lo ~/ 10000 * 10000) + (lo ~/ 10 * 10 % 10000) + int.parse(hiRaw);
      return (lo, hi);
    }).toList();
    for (final id in ids) {
      final n = int.parse(id.substring(2));
      final covered = skill.contains(id) || ranges.any((r) => n >= r.$1 && n <= r.$2);
      expect(covered, isTrue, reason: '$id missing from SKILL.md');
    }
  });

  test('catalog severities match what the tool emits (doctor fixtures and real APK fixtures)', () {
    final bySev = {for (final r in rules) r['id'] as String: r['severity']};
    final reports = <Report>[];
    for (final d in Directory('fixtures').listSync().whereType<Directory>().where((d) => d.path.split('/').last.startsWith('err_'))) {
      final l = loadProjects(d.path, (m) => fail(m))!;
      reports.add(runDoctor(l.android, ios: l.ios, loadNotes: l.notes));
    }
    for (final f in Directory('test/artifacts').listSync().whereType<File>()) {
      reports.add(verifyArtifact(f.path));
    }
    var n = 0;
    for (final rep in reports) {
      for (final d in rep.diagnostics) {
        expect(d.severity.name, bySev[d.code], reason: d.code);
        n++;
      }
    }
    expect(n, greaterThan(30));
  });

  group('report schema validates ID format only', () {
    final schema = jsonDecode(File('schema/diagnostic-report.schema.json').readAsStringSync()) as Map<String, dynamic>;
    final codeSchema = schema['properties']['diagnostics']['items']['properties']['code'] as Map<String, dynamic>;
    test('code is a string with the pattern, not an enum', () {
      expect(codeSchema['type'], 'string');
      expect(codeSchema['pattern'], r'^WF[0-9]{4}$');
      expect(codeSchema.containsKey('enum'), isFalse);
      expect(schema['properties']['schemaVersion']['const'], '1');
      expect(schema[r'$id'], contains('z0rimo/widgettriage'));
    });
    test('all 29 current IDs and a well-formed unknown ID are accepted; malformed values are rejected', () {
      for (final id in [...ids, 'WF9999', 'WF0000']) {
        expect(validate(id, codeSchema, 'code'), isEmpty, reason: id);
      }
      for (final bad in ['wf1001', 'WF100', 'WF10011', 'XX1001', '', ' WF1001', 'WF1001\n']) {
        expect(validate(bad, codeSchema, 'code'), isNotEmpty, reason: '"$bad"');
      }
      expect(validate(1001, codeSchema, 'code'), isNotEmpty);
      expect(validate(null, codeSchema, 'code'), isNotEmpty);
    });
    test('a report with an unknown, well-formed code validates; the same report with every other field intact is otherwise unchanged', () {
      final rep = Report(projectPath: 'x', checksRun: ['c'], diagnostics: [
        Diagnostic(code: 'WF9999', severity: Severity.warning, title: 't', message: 'm', file: 'f', evidence: 'e', fix: 'x')
      ]).toJson();
      expect(validate(jsonDecode(jsonEncode(rep)), schema, 'r'), isEmpty);
    });
  });
}
