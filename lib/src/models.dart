/// Severity of a diagnostic.
enum Severity { error, warning, info }

const toolVersion = '0.2.0';
const reportSchemaVersion = '1';

/// A single finding. Every field is part of the public JSON contract
/// (see schema/diagnostic-report.schema.json).
class Diagnostic {
  Diagnostic({
    required this.code,
    required this.severity,
    required this.title,
    required this.message,
    required this.file,
    this.line,
    required this.evidence,
    required this.fix,
  });

  final String code;
  final Severity severity;
  final String title;
  final String message;

  /// Path relative to the project root, using forward slashes.
  final String file;
  final int? line;

  /// The literal text/attribute that triggered the finding.
  final String evidence;

  /// Concrete, mechanical remediation an agent can apply.
  final String fix;

  String get docs => 'docs/errors/$code.md';

  Map<String, Object?> toJson() => {
        'code': code,
        'severity': severity.name,
        'title': title,
        'message': message,
        'file': file,
        'line': line,
        'evidence': evidence,
        'fix': fix,
        'docs': docs,
      };
}

class Report {
  Report({
    required this.projectPath,
    required this.checksRun,
    required this.diagnostics,
    this.notes = const [],
  });

  final String projectPath;
  final List<String> checksRun;
  final List<Diagnostic> diagnostics;

  /// Non-diagnostic remarks, e.g. "no AppWidget found, nothing to check".
  final List<String> notes;

  int count(Severity s) => diagnostics.where((d) => d.severity == s).length;
  bool get hasErrors => count(Severity.error) > 0;

  Map<String, Object?> toJson() => {
        'schemaVersion': reportSchemaVersion,
        'tool': {'name': 'widgettriage', 'version': toolVersion},
        'projectPath': projectPath,
        'summary': {
          'errors': count(Severity.error),
          'warnings': count(Severity.warning),
          'infos': count(Severity.info),
        },
        'checksRun': checksRun,
        'notes': notes,
        'diagnostics': diagnostics.map((d) => d.toJson()).toList(),
      };
}
