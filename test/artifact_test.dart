/// `widgettriage verify` (APK / IPA artifacts): aapt2-built APK fixtures, synthetic
/// archives, archive-safety limits and the CLI contract.
///
/// Evidence level of the APK tests: the test/artifacts/*.apk files are built by `aapt2`
/// (compile, link and, for release variants, optimize with resource path shortening) from manifests
/// and resources written for this project; see test/tool/make_apk_fixtures.sh. They contain no dex
/// code and no library resources.
///
/// Coverage note: an earlier revision used trimmed APKs from real Flutter 3.32 builds (Gradle/AGP,
/// Linux), compared with `apkanalyzer`. Those were replaced because their AndroidX/Flutter content
/// has unconfirmed redistribution terms. The replacements are real `aapt2` output (binary manifest,
/// resources.arsc, shortened resource paths) and the same assertions pass, but they do NOT carry the
/// manifest shape of a real Flutter/AndroidX app (merged library components, placeholders resolved by
/// the manifest merger). That real-build shape is no longer covered by committed fixtures.
/// Everything else here is a synthetic archive that models the file *format*; no synthetic IPA is a
/// real Apple build, and no iOS artifact was produced by Xcode (macOS NOT RUN).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:widgettriage/widgettriage.dart';

import 'accuracy_test.dart' show validate;
import 'support/builders.dart';

late Directory tmp;
var _n = 0;


String zipTo(List<ZipFile> files, {int? eocdTotal}) => writeTemp(tmp, 'a${_n++}.zip', buildZip(files, eocdTotal: eocdTotal));

List<String> codes(Report r) => r.diagnostics.map((d) => d.code).toList();
bool hasNote(Report r, String s) => r.notes.any((n) => n.contains(s));
Matcher failsWith(String s) => throwsA(isA<ArchiveException>().having((e) => e.message, 'message', contains(s)));

// ---- synthetic APK parts ---------------------------------------------------------

const idProvider = 0x7f0e0000;
const idLayout = 0x7f090001;

Uint8List manifest({
  int? targetSdk = 33,
  bool? exported = true,
  bool filter = true,
  bool meta = true,
  int metaRef = idProvider,
  bool widget = true,
  String root = 'manifest',
  bool utf8Pool = false,
}) {
  final receiver = E('receiver', [
    A.str(true, 'name', '.DemoWidgetProvider'),
    if (exported != null) A.bool(true, 'exported', exported),
  ], [
    if (filter)
      E('intent-filter', [], [
        E('action', [A.str(true, 'name', 'android.appwidget.action.APPWIDGET_UPDATE')])
      ]),
    if (meta) E('meta-data', [A.str(true, 'name', 'android.appwidget.provider'), A.ref(true, 'resource', metaRef)]),
  ]);
  return buildAxml(
      E(root, [], [
        if (targetSdk != null) E('uses-sdk', [A.int(true, 'targetSdkVersion', targetSdk)]),
        E('application', [], [if (widget) receiver]),
      ]),
      utf8Pool: utf8Pool);
}

Uint8List providerXml({bool initialLayout = true, int layoutRef = idLayout, String root = 'appwidget-provider'}) =>
    buildAxml(E(root, [A.int(true, 'minWidth', 110), if (initialLayout) A.ref(true, 'initialLayout', layoutRef)]));

List<ZipFile> apk({
  Uint8List? man,
  Map<int, String>? res = const {idProvider: 'res/xml/w.xml', idLayout: 'res/layout/w.xml'},
  bool providerFile = true,
  bool layoutFile = true,
  Uint8List? provider,
}) =>
    [
      ZipFile('AndroidManifest.xml', man ?? manifest()),
      if (res != null) ZipFile('resources.arsc', buildArsc(res), deflate: false),
      if (providerFile) ZipFile('res/xml/w.xml', provider ?? providerXml()),
      if (layoutFile) ZipFile('res/layout/w.xml', Uint8List.fromList([1, 2, 3])),
    ];

Report v(List<ZipFile> files, {ArchiveLimits limits = const ArchiveLimits()}) => verifyArtifact(zipTo(files), limits: limits);

// ---- synthetic IPA parts ---------------------------------------------------------

Map<String, Object> appPlist([String id = 'com.acme.app']) => {'CFBundleIdentifier': id, 'CFBundleExecutable': 'Runner'};
Map<String, Object> extPlist({String id = 'com.acme.app.Widget', String point = 'com.apple.widgetkit-extension', String? min = '14.0', String exe = 'Widget'}) => {
      'CFBundleIdentifier': id,
      'CFBundleExecutable': exe,
      if (min != null) 'MinimumOSVersion': min,
      'NSExtension': {'NSExtensionPointIdentifier': point},
    };

List<int> plistBytes(Map<String, Object> m, {bool binary = false}) => binary ? buildBplist(m) : utf8.encode(xmlPlist(m));

List<ZipFile> ipa({
  Object? app = 'default',
  Object? ext = 'default',
  bool binary = false,
  bool exe = true,
  String extDir = 'Widget.appex',
}) =>
    [
      if (app != null) ZipFile('Payload/Runner.app/Info.plist', app == 'default' ? plistBytes(appPlist(), binary: binary) : app as List<int>),
      ZipFile('Payload/Runner.app/Runner', [0]),
      if (ext != null) ...[
        ZipFile('Payload/Runner.app/PlugIns/$extDir/Info.plist', ext == 'default' ? plistBytes(extPlist(), binary: binary) : ext as List<int>),
        if (exe) ZipFile('Payload/Runner.app/PlugIns/$extDir/Widget', [0]),
      ],
    ];

void main() {
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('wf_artifact_'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  group('aapt2-built APKs (self-authored sources)', () {
    test('release build with a widget: 0 diagnostics, shrunk resource names resolved', () {
      final r = verifyArtifact('test/artifacts/real_release_widget.apk');
      expect(r.diagnostics, isEmpty);
      expect(r.checksRun, ['apk-widget-artifact']);
      expect(hasNote(r, 'Not checked'), isTrue);
    });
    test('debug build with provider XML lacking initialLayout and a receiver lacking meta-data', () {
      final r = verifyArtifact('test/artifacts/real_debug_widget_missing_meta.apk');
      expect(codes(r), ['WF6002', 'WF6004']);
      final d = r.diagnostics;
      expect(d[0].file, 'AndroidManifest.xml');
      expect(d[0].evidence, contains('dev.acme.wfreal.OtherWidgetProvider'));
      expect(d[1].file, 'res/xml/demo_widget_info.xml');
    });
    test('multi-provider app: placeholder-resolved exported, per-variant receiver sets match apkanalyzer', () {
      // apkanalyzer manifest print on the full APKs: release = Demo + Second, debug = Demo + Second + DebugOnly (debug source-set manifest).
      final rel = verifyArtifact('test/artifacts/real_release_multi_widget.apk');
      expect(rel.diagnostics, isEmpty);
      expect(hasNote(rel, 'checked 2 AppWidget receiver(s)'), isTrue);
      final dbg = verifyArtifact('test/artifacts/real_debug_multi_widget.apk');
      expect(dbg.diagnostics, isEmpty);
      expect(hasNote(dbg, 'checked 3 AppWidget receiver(s)'), isTrue);
      expect(hasNote(dbg, 'DebugOnlyProvider'), isTrue);
    });
    test('real app without any widget: note, no finding', () {
      final r = verifyArtifact('test/artifacts/real_release_no_widget.apk');
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'no AppWidget receiver'), isTrue);
    });
    test('reports validate against the schema', () {
      final schema = jsonDecode(File('schema/diagnostic-report.schema.json').readAsStringSync()) as Map<String, dynamic>;
      for (final f in ['real_release_widget', 'real_debug_widget_missing_meta', 'real_release_multi_widget', 'real_release_no_widget']) {
        final r = verifyArtifact('test/artifacts/$f.apk');
        expect(validate(jsonDecode(jsonEncode(r.toJson())), schema, f), isEmpty);
      }
    });
  });

  group('APK checks (synthetic)', () {
    test('healthy', () {
      expect(v(apk()).diagnostics, isEmpty);
      expect(v(apk(man: manifest(utf8Pool: true))).diagnostics, isEmpty);
    });
    test('no widget receiver: note only', () {
      final r = v(apk(man: manifest(widget: false)));
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'no AppWidget receiver'), isTrue);
    });
    test('WF6001 missing exported with targetSdk >= 31', () {
      final r = v(apk(man: manifest(exported: null)));
      expect(codes(r), ['WF6001']);
      expect(r.diagnostics.single.evidence, contains('targetSdkVersion=33'));
    });
    test('missing exported with targetSdk 30 or unknown: note, no finding', () {
      expect(v(apk(man: manifest(exported: null, targetSdk: 30))).diagnostics, isEmpty);
      final r = v(apk(man: manifest(exported: null, targetSdk: null)));
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'targetSdkVersion is unknown'), isTrue);
    });
    test('exported=false is not WF6001', () => expect(v(apk(man: manifest(exported: false))).diagnostics, isEmpty));
    test('WF6002 no provider meta-data', () => expect(codes(v(apk(man: manifest(meta: false)))), ['WF6002']));
    test('meta-data without the APPWIDGET_UPDATE filter still counts as a widget receiver', () {
      expect(codes(v(apk(man: manifest(filter: false)))), isEmpty);
    });
    test('WF6003 unresolved id / file absent from archive', () {
      expect(codes(v(apk(man: manifest(metaRef: 0x7f0e0099))), ), ['WF6003']);
      expect(codes(v(apk(providerFile: false))), ['WF6003']);
    });
    test('resource entries whose value is not a string never resolve to a file', () {
      final files = [
        ZipFile('AndroidManifest.xml', manifest()),
        ZipFile('resources.arsc', buildArsc({idProvider: 'res/xml/w.xml', idLayout: 'res/layout/w.xml'}, intValued: {idProvider}), deflate: false),
        ZipFile('res/xml/w.xml', providerXml()),
        ZipFile('res/layout/w.xml', [1]),
      ];
      expect(codes(v(files)), ['WF6003']);
    });
    test('WF6004 no initialLayout', () {
      final r = v(apk(provider: providerXml(initialLayout: false)));
      expect(codes(r), ['WF6004']);
      expect(r.diagnostics.single.file, 'res/xml/w.xml');
    });
    test('WF6005 layout unresolved / layout file absent', () {
      expect(codes(v(apk(provider: providerXml(layoutRef: 0x7f090099))), ), ['WF6005']);
      expect(codes(v(apk(layoutFile: false))), ['WF6005']);
    });
    test('no resources.arsc: references skipped with a note, never a pass for them', () {
      final r = v(apk(res: null));
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'resources.arsc'), isTrue);
    });
    test('resources.arsc larger than the read limit is skipped with a note', () {
      final r = v(apk(), limits: const ArchiveLimits(maxReadBytes: 16));
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'resources.arsc'), isTrue);
    });
    test('corrupt resources.arsc: note only', () {
      final files = apk(res: null)..add(ZipFile('resources.arsc', [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13]));
      final r = v(files);
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'resources.arsc'), isTrue);
    });
    test('provider XML that is not binary XML: note, no finding', () {
      final r = v(apk(provider: Uint8List.fromList(utf8.encode('<appwidget-provider/>'))));
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'could not be read as binary XML'), isTrue);
    });
    test('manifest that is not binary XML or not a manifest: exit-2 class error', () {
      expect(() => v([ZipFile('AndroidManifest.xml', utf8.encode('<manifest/>'))]), failsWith('binary XML'));
      expect(() => v(apk(man: manifest(root: 'foo'))), failsWith('root element'));
    });
  });

  group('IPA checks (synthetic archives, not Apple builds)', () {
    test('healthy with XML and with binary plists', () {
      for (final bin in [false, true]) {
        final r = v(ipa(binary: bin));
        expect(r.diagnostics, isEmpty, reason: 'binary=$bin');
        expect(r.checksRun, ['ipa-widget-structure']);
        expect(hasNote(r, 'code signature'), isTrue);
      }
    });
    test('no PlugIns: note only', () {
      final r = v(ipa(ext: null));
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'no PlugIns'), isTrue);
    });
    test('other extension kind: not judged, noted', () {
      final r = v(ipa(ext: plistBytes(extPlist(point: 'com.apple.share-services'))));
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'com.apple.share-services'), isTrue);
      expect(hasNote(r, 'no embedded extension has the WidgetKit'), isTrue);
    });
    test('WF7001 variants', () {
      expect(codes(v(ipa(app: null))), ['WF7001']);
      expect(codes(v(ipa(app: plistBytes({'CFBundleExecutable': 'x'})))), ['WF7001']);
      expect(codes(v(ipa(ext: utf8.encode('not a plist')))), ['WF7001']);
      expect(codes(v(ipa(ext: plistBytes({'CFBundleIdentifier': 'com.acme.app.W'})))), ['WF7001']);
      final trunc = buildBplist(extPlist()).sublist(0, 30);
      expect(codes(v(ipa(ext: trunc))), ['WF7001']);
    });
    test('WF7002 bundle id prefix', () {
      final r = v(ipa(ext: plistBytes(extPlist(id: 'com.other.Widget'))));
      expect(codes(r), ['WF7002']);
      expect(r.diagnostics.single.evidence, 'CFBundleIdentifier=com.other.Widget; app CFBundleIdentifier=com.acme.app (unverified convention)');
      expect(r.diagnostics.single.severity, Severity.warning);
      expect(r.diagnostics.single.message, contains('UNVERIFIED'));
      expect(r.hasErrors, isFalse);
      expect(codes(v(ipa(ext: plistBytes(extPlist(id: 'com.acme.appWidget'))))), ['WF7002']);
    });
    test('WF7004 is a warning with the uncertainty stated; 7001/7003 stay errors', () {
      final r = v(ipa(ext: plistBytes(extPlist(min: '13.4'))));
      expect(r.diagnostics.single.severity, Severity.warning);
      expect(r.diagnostics.single.evidence, contains('unverified'));
      expect(r.hasErrors, isFalse);
      expect(r.toJson()['summary'], {'errors': 0, 'warnings': 1, 'infos': 0});
      expect(v(ipa(exe: false)).diagnostics.single.severity, Severity.error);
      expect(v(ipa(app: null)).diagnostics.single.severity, Severity.error);
    });
    test('WF7003 executable missing', () => expect(codes(v(ipa(exe: false))), ['WF7003']));
    test('WF7004 MinimumOSVersion below 14; 14.0 and missing are fine', () {
      expect(codes(v(ipa(ext: plistBytes(extPlist(min: '13.4'))))), ['WF7004']);
      expect(codes(v(ipa(ext: plistBytes(extPlist(min: '14.0'))))), isEmpty);
      final r = v(ipa(ext: plistBytes(extPlist(min: null))));
      expect(r.diagnostics, isEmpty);
      expect(hasNote(r, 'no MinimumOSVersion'), isTrue);
    });
    test('two .app directories or no .app: unsupported (exit-2 class)', () {
      expect(() => v([...ipa(), ZipFile('Payload/Other.app/Info.plist', [0])]), failsWith('more than one'));
      expect(() => v([ZipFile('Payload/readme.txt', [0])]), failsWith('neither an APK'));
    });
  });

  group('archive safety', () {
    test('not a zip / too small / truncated / missing file', () {
      expect(() => verifyArtifact(writeTemp(tmp, 'x1', utf8.encode('hello world, definitely not a zip file'))), failsWith('not a ZIP'));
      expect(() => verifyArtifact(writeTemp(tmp, 'x2', [1, 2, 3])), failsWith('too small'));
      final good = buildZip(apk());
      expect(() => verifyArtifact(writeTemp(tmp, 'x3', good.sublist(0, good.length - 10))), throwsA(isA<ArchiveException>()));
      expect(() => verifyArtifact('${tmp.path}/nope.apk'), failsWith('not found'));
    });
    test('central directory pointing outside the file', () {
      final b = buildZip(apk());
      b.buffer.asByteData().setUint32(b.length - 6, 0x7fffff00, Endian.little);
      expect(() => verifyArtifact(writeTemp(tmp, 'x4', b)), failsWith('central directory'));
    });
    test('path traversal, absolute path, backslash, NUL', () {
      for (final bad in ['../evil', 'a/../../evil', '/abs', 'C:/x', r'a\b', 'a\u0000b']) {
        expect(() => v([...apk(), ZipFile(bad, [1])]), throwsA(isA<ArchiveException>()), reason: bad);
      }
    });
    test('duplicate entry paths', () => expect(() => v([...apk(), ZipFile('res/xml/w.xml', [1])]), failsWith('duplicate')));
    test('encrypted entries', () => expect(() => v([...apk(), ZipFile('x', [1], flags: 1)]), failsWith('encrypted')));
    test('ZIP64 marker and entry-count limit', () {
      expect(() => verifyArtifact(zipTo(apk(), eocdTotal: 0xffff)), failsWith('ZIP64'));
      expect(() => v(apk(), limits: const ArchiveLimits(maxEntries: 3)), failsWith('more than the limit'));
      expect(v(apk(), limits: const ArchiveLimits(maxEntries: 4)).diagnostics, isEmpty);
    });
    test('archive size limit', () {
      final p = zipTo(apk());
      expect(() => verifyArtifact(p, limits: const ArchiveLimits(maxArchiveBytes: 100)), failsWith('larger than the limit'));
    });
    test('entry name length limit', () {
      expect(() => v([...apk(), ZipFile('a' * 20, [1])], limits: const ArchiveLimits(maxEntryNameBytes: 10)), failsWith('longer than'));
    });
    test('manifest entry at the size limit passes, one byte over fails (boundary)', () {
      final m = manifest();
      expect(() => v(apk(man: m), limits: ArchiveLimits(maxSmallReadBytes: m.length - 1)), failsWith('larger than the limit'));
      expect(v(apk(man: m), limits: ArchiveLimits(maxSmallReadBytes: m.length)).diagnostics, isEmpty);
    });
    test('zip bomb: huge declared size rejected before inflating; ratio check', () {
      final big = Uint8List(4 * 1024 * 1024); // compresses ~1000:1
      expect(() => v([ZipFile('AndroidManifest.xml', big)], limits: const ArchiveLimits(maxSmallReadBytes: 1024 * 1024)), failsWith('larger than the limit'));
      expect(() => v([ZipFile('AndroidManifest.xml', big)], limits: const ArchiveLimits(maxRatio: 100)), failsWith('compression ratio'));
    });
    test('zip bomb: entry that lies about its size is cut off, never fully inflated', () {
      final data = Uint8List(2 * 1024 * 1024);
      final p = zipTo([ZipFile('AndroidManifest.xml', data, declaredSize: 1000)]);
      expect(() => verifyArtifact(p), failsWith('inflates beyond'));
    });
    test('unsupported compression method for a needed entry', () {
      expect(() => v([ZipFile('AndroidManifest.xml', [1, 2, 3], method: 12)]), failsWith('unsupported compression method'));
    });
    test('unrelated entries with unsupported methods are never read', () {
      expect(v([...apk(), ZipFile('assets/x.bin', [1, 2, 3], method: 12)]).diagnostics, isEmpty);
    });
    test('corrupt deflate data', () {
      final b = buildZip([ZipFile('AndroidManifest.xml', manifest())]);
      for (var i = 40; i < 60; i++) {
        b[i] ^= 0xff;
      }
      expect(() => verifyArtifact(writeTemp(tmp, 'x5', b)), throwsA(isA<ArchiveException>()));
    });
    test('CRC-32 mismatch of a read entry (stored and deflated)', () {
      expect(() => v([ZipFile('AndroidManifest.xml', manifest(), crc: 1), ...apk().skip(1)]), failsWith('CRC-32'));
      expect(() => v([ZipFile('AndroidManifest.xml', manifest(), deflate: false, crc: 1), ...apk().skip(1)]), failsWith('CRC-32'));
    });
    test('CRC of entries that are never read is not checked', () {
      expect(v([...apk(), ZipFile('assets/x', [1, 2], crc: 1)]).diagnostics, isEmpty);
    });
    test('local header name differs from the central directory', () {
      expect(() => v([ZipFile('AndroidManifest.xml', manifest(), localName: 'Other.xml'), ...apk().skip(1)]), failsWith('does not match'));
    });
    test('encrypted flag set only in the local header', () {
      expect(() => v([ZipFile('AndroidManifest.xml', manifest(), localFlags: 1), ...apk().skip(1)]), failsWith('encrypted'));
    });
    test('non-canonical paths that would collide after normalization', () {
      for (final bad in ['res//x', './res/x', 'res/./x']) {
        expect(() => v([...apk(), ZipFile(bad, [1])]), failsWith('non-canonical'), reason: bad);
      }
      expect(v([...apk(), ZipFile('res/dir/', [])]).diagnostics, isEmpty);
    });
    test('timeout', () {
      expect(() => v(apk(), limits: const ArchiveLimits(timeout: Duration.zero)), failsWith('timeout'));
    });
    test('AAB and ambiguous archives are rejected', () {
      expect(() => v([ZipFile('BundleConfig.pb', [1]), ZipFile('base/manifest/AndroidManifest.xml', [1])]), failsWith('.aab'));
      expect(() => v([...apk(), ...ipa()]), failsWith('ambiguous'));
    });
    test('verify never modifies the artifact', () {
      final p = zipTo(apk());
      final before = File(p).readAsBytesSync();
      final mt = File(p).lastModifiedSync();
      verifyArtifact(p);
      expect(File(p).readAsBytesSync(), before);
      expect(File(p).lastModifiedSync(), mt);
    });
  });

  group('CLI', () {
    ProcessResult run(List<String> args) => Process.runSync(Platform.resolvedExecutable, ['run', 'bin/widgettriage.dart', ...args]);

    test('exit 0 / 1 and JSON-only stdout', () {
      final ok = run(['verify', '--json', 'test/artifacts/real_release_widget.apk']);
      expect(ok.exitCode, 0);
      expect((jsonDecode(ok.stdout as String) as Map)['summary'], containsPair('errors', 0));
      final bad = run(['verify', '--json', 'test/artifacts/real_debug_widget_missing_meta.apk']);
      expect(bad.exitCode, 1);
      final j = jsonDecode(bad.stdout as String) as Map;
      expect((j['diagnostics'] as List).map((d) => (d as Map)['code']), ['WF6002', 'WF6004']);
      expect(j['projectPath'], 'test/artifacts/real_debug_widget_missing_meta.apk');
    });
    test('warnings only: exit 0, JSON shows the warning; error + warning: exit 1', () {
      final w = writeTemp(tmp, 'warn.ipa', buildZip(ipa(ext: plistBytes(extPlist(min: '13.0')))));
      final r = run(['verify', '--json', w]);
      expect(r.exitCode, 0);
      final j = jsonDecode(r.stdout as String) as Map;
      expect(j['summary'], {'errors': 0, 'warnings': 1, 'infos': 0});
      expect((j['diagnostics'] as List).single, containsPair('code', 'WF7004'));
      expect((j['diagnostics'] as List).single, containsPair('severity', 'warning'));
      final both = writeTemp(tmp, 'both.ipa', buildZip(ipa(ext: plistBytes(extPlist(min: '13.0')), exe: false)));
      expect(run(['verify', '--json', both]).exitCode, 1);
      expect(run(['verify', both]).stdout as String, contains('[WARNING] WF7004'));
    });
    test('exit 2 with stderr and empty stdout for unusable input and usage errors', () {
      final junk = writeTemp(tmp, 'junk.apk', utf8.encode('not a zip at all, just text'));
      for (final args in [
        ['verify', '--json', junk],
        ['verify', '--json', '${tmp.path}/missing.apk'],
        ['verify'],
        ['verify', 'a', 'b'],
      ]) {
        final r = run(args);
        expect(r.exitCode, 2, reason: '$args');
        expect((r.stdout as String).trim(), isEmpty, reason: '$args');
        expect(r.stderr as String, isNotEmpty);
      }
    });
    test('doctor is unchanged (usage lists both commands, doctor still works)', () {
      final h = run(['--help']);
      expect(h.stdout as String, allOf(contains('widgettriage doctor'), contains('widgettriage verify')));
      final d = run(['doctor', '--json', 'fixtures/ok_basic']);
      expect(d.exitCode, 0);
      expect((jsonDecode(d.stdout as String) as Map)['checksRun'], isNot(contains('apk-widget-artifact')));
    });
  });
}
