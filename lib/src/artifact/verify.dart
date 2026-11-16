import '../models.dart';
import 'apk_verify.dart';
import 'ipa_verify.dart';
import 'zip_reader.dart';

/// Opens [path], identifies it as an APK or an IPA from its contents (never
/// from the extension alone) and verifies it. Throws [ArchiveException] when
/// the file is not a supported, safely readable archive (CLI exit code 2).
Report verifyArtifact(String path, {ArchiveLimits limits = const ArchiveLimits()}) {
  final zip = ZipReader.open(path, limits: limits);
  try {
    final names = zip.entries.keys;
    final isApk = zip.entries.containsKey('AndroidManifest.xml');
    final isIpa = names.any((n) => n.startsWith('Payload/') && n.contains('.app/'));
    if (zip.entries.containsKey('BundleConfig.pb') || zip.entries.containsKey('base/manifest/AndroidManifest.xml')) {
      throw ArchiveException('Android App Bundles (.aab) are not supported; verify a built .apk');
    }
    if (isApk && isIpa) throw ArchiveException('ambiguous archive: contains both AndroidManifest.xml and Payload/*.app');
    if (isApk) return _sorted(verifyApk(zip, path));
    if (isIpa) return _sorted(verifyIpa(zip, path));
    throw ArchiveException('unsupported archive: neither an APK (AndroidManifest.xml) nor an IPA (Payload/<name>.app/)');
  } finally {
    zip.close();
  }
}

const _order = {Severity.error: 0, Severity.warning: 1, Severity.info: 2};

Report _sorted(Report r) {
  r.diagnostics.sort((a, b) {
    final s = _order[a.severity]!.compareTo(_order[b.severity]!);
    if (s != 0) return s;
    final c = a.code.compareTo(b.code);
    return c != 0 ? c : a.file.compareTo(b.file);
  });
  return r;
}
