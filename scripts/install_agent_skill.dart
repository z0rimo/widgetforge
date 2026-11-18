/// Installs the WidgetTriage Agent Skill (`skills/widgettriage/`) for Codex and/or Claude Code.
///
/// This installs only the skill files. It does not install the `widgettriage` CLI itself.
/// It copies files from this checkout, never downloads anything, never runs automatically
/// and never touches anything outside the `widgettriage` skill directory it installs into.
///
///   dart run scripts/install_agent_skill.dart --agent both --scope project --project PROJECT_DIR
///   dart run scripts/install_agent_skill.dart --agent claude --scope user
///   dart run scripts/install_agent_skill.dart --dry-run
///
/// Exit codes: 0 = every target installed or already installed (or dry-run); 1 = at least one
/// target conflicted or failed; 2 = usage error or unusable source/home/project.
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

const skillName = 'widgettriage';

enum Agent { codex, claude }

extension on Agent {
  String get label => this == Agent.codex ? 'Codex' : 'Claude Code';

  /// Directory (relative to the project root or the user's home) that holds skills.
  List<String> get skillsDir =>
      this == Agent.codex ? ['.agents', 'skills'] : ['.claude', 'skills'];
}

enum Status {
  installed,
  alreadyInstalled,
  wouldInstall,
  wouldReplace,
  conflict,
  failed
}

extension on Status {
  String get text => switch (this) {
        Status.installed => 'INSTALLED',
        Status.alreadyInstalled => 'ALREADY INSTALLED',
        Status.wouldInstall => 'WOULD INSTALL',
        Status.wouldReplace => 'WOULD REPLACE',
        Status.conflict => 'CONFLICT',
        Status.failed => 'FAILED',
      };
  bool get isProblem => this == Status.conflict || this == Status.failed;
}

class _Result {
  _Result(this.agent, this.display, this.status, [this.detail]);
  final Agent agent;
  final String display;
  final Status status;
  final String? detail;
}

ArgParser _parser() => ArgParser()
  ..addOption('agent',
      allowed: ['codex', 'claude', 'both'],
      defaultsTo: 'both',
      help: 'Which agent to install the skill for.')
  ..addOption('scope',
      allowed: ['project', 'user'],
      defaultsTo: 'project',
      help:
          'project: <project>/.agents|.claude/skills (this project only); user: ~/.agents|~/.claude/skills (all projects).')
  ..addOption('project',
      help:
          'Project directory for --scope project (default: the current directory).')
  ..addFlag('dry-run',
      negatable: false, help: 'Show what would happen; change nothing.')
  ..addFlag('force',
      negatable: false,
      help:
          'Replace differing files inside the widgettriage skill directory (the old file is kept as <name>.bak).')
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

String usage() =>
    '''WidgetTriage Agent Skill installer (installs the skill files only, not the CLI)

Usage: dart run scripts/install_agent_skill.dart [options]

${_parser().usage}

Existing files are never overwritten without --force. Nothing outside the widgettriage skill
directory is modified. Exit codes: 0 ok, 1 conflict or failure, 2 usage error.''';

/// Runs the installer. [source] is the skill directory to copy (default: `skills/widgettriage`
/// next to this script). [env] supplies HOME/USERPROFILE; [cwd] is the default project directory.
int runInstaller(
  List<String> args, {
  required Directory source,
  required Map<String, String> env,
  required Directory cwd,
  required StringSink out,
  required StringSink err,
  Directory? repoRoot,
}) {
  final ArgResults opts;
  try {
    opts = _parser().parse(args);
    if (opts.rest.isNotEmpty) {
      throw FormatException('Unexpected argument: ${opts.rest.join(' ')}');
    }
  } on FormatException catch (e) {
    err.writeln('install_agent_skill: ${e.message}\n\n${usage()}');
    return 2;
  }
  if (opts['help'] as bool) {
    out.writeln(usage());
    return 0;
  }

  final dryRun = opts['dry-run'] as bool;
  final force = opts['force'] as bool;
  final scope = opts['scope'] as String;
  final agents = switch (opts['agent'] as String) {
    'codex' => [Agent.codex],
    'claude' => [Agent.claude],
    _ => [Agent.codex, Agent.claude],
  };

  // Source files (regular files only; a symlink in the source is refused).
  final Map<String, List<int>> files;
  try {
    files = _readSource(source);
  } on FormatException catch (e) {
    err.writeln('install_agent_skill: ${e.message}');
    return 2;
  }

  // Base directory.
  late final Directory base;
  late final String Function(String) show;
  if (scope == 'user') {
    final home = (env['HOME'] ?? '').isNotEmpty
        ? env['HOME']!
        : (env['USERPROFILE'] ?? '');
    if (home.isEmpty || !Directory(home).existsSync()) {
      err.writeln(
          'install_agent_skill: cannot determine the home directory (HOME / USERPROFILE is unset or missing); '
          'use --scope project instead.');
      return 2;
    }
    base = Directory(home);
    show = (path) => '~/${p.relative(path, from: home)}';
  } else {
    final projectArg = opts['project'] as String?;
    final dir = Directory(projectArg == null
        ? cwd.path
        : p.normalize(p.absolute(cwd.path, projectArg)));
    if (!dir.existsSync()) {
      err.writeln(
          'install_agent_skill: project directory does not exist: ${dir.path}');
      return 2;
    }
    final root = repoRoot;
    if (root != null && p.equals(_real(dir.path), _real(root.path))) {
      err.writeln(
          'install_agent_skill: ${dir.path} is the WidgetTriage checkout itself. Pass the Flutter project to '
          'install into with --project <path> (or use --scope user).');
      return 2;
    }
    base = dir;
    show = (path) => p.relative(path, from: dir.path);
  }

  out.writeln(
      'WidgetTriage Agent Skill installer${dryRun ? ' (dry run: nothing is changed)' : ''}\n');
  out.writeln('Source: ${p.relative(source.path, from: cwd.path)}');
  out.writeln('Scope:  $scope${scope == 'project' ? ' (${base.path})' : ''}\n');

  final results = <_Result>[];
  for (final agent in agents) {
    final target = p.joinAll([base.path, ...agent.skillsDir, skillName]);
    try {
      results.add(_installOne(agent, target, show(target), files,
          dryRun: dryRun, force: force));
    } on FileSystemException catch (e) {
      results.add(_Result(agent, show(target), Status.failed,
          '${e.message}${e.path == null ? '' : ' (${show(e.path!)})'}'));
    }
  }

  for (final r in results) {
    out.writeln(
        '${r.agent.label.padRight(11)} ${r.status.text.padRight(17)} ${r.display}');
    if (r.detail != null) {
      (r.status.isProblem ? err : out).writeln('            ${r.detail}');
    }
  }
  final problems = results.where((r) => r.status.isProblem).length;
  out.writeln();
  if (problems > 0) {
    out.writeln(
        'Finished with $problems problem(s); the other target(s) above were handled independently.');
    return 1;
  }
  out.writeln(dryRun
      ? 'Dry run complete. Nothing was changed.'
      : 'Installation complete. Restart the agent if it does not list the skill.');
  return 0;
}

Map<String, List<int>> _readSource(Directory source) {
  if (!source.existsSync() ||
      !File(p.join(source.path, 'SKILL.md')).existsSync()) {
    throw FormatException(
        'skill source not found (no SKILL.md in ${source.path}). Run this script from a WidgetTriage checkout.');
  }
  final files = <String, List<int>>{};
  for (final e in source.listSync(recursive: true, followLinks: false)) {
    final type = FileSystemEntity.typeSync(e.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw FormatException(
          'refusing to copy a symbolic link from the skill source: ${e.path}');
    }
    if (type == FileSystemEntityType.file) {
      files[p.relative(e.path, from: source.path)] =
          File(e.path).readAsBytesSync();
    }
  }
  return files;
}

String _real(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}

bool _same(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

_Result _installOne(
    Agent agent, String target, String display, Map<String, List<int>> files,
    {required bool dryRun, required bool force}) {
  final type = FileSystemEntity.typeSync(target, followLinks: false);
  if (type == FileSystemEntityType.link) {
    return _Result(agent, display, Status.conflict,
        'The target is a symbolic link; it is never followed or replaced. Remove or rename it yourself, then run again.');
  }
  if (type == FileSystemEntityType.file) {
    return _Result(agent, display, Status.conflict,
        'A file (not a directory) exists at the target. Move it, then run again.');
  }

  final differing = <String>[]; // files that exist but differ
  final missing = <String>[];
  if (type == FileSystemEntityType.directory) {
    for (final entry in files.entries) {
      final f = p.join(target, entry.key);
      final ft = FileSystemEntity.typeSync(f, followLinks: false);
      if (ft == FileSystemEntityType.notFound) {
        missing.add(entry.key);
      } else if (ft != FileSystemEntityType.file ||
          !_same(File(f).readAsBytesSync(), entry.value)) {
        differing.add(entry.key);
      }
    }
    if (differing.isEmpty && missing.isEmpty) {
      return _Result(agent, display, Status.alreadyInstalled);
    }
    if (differing.isNotEmpty && !force) {
      return _Result(
          agent,
          display,
          Status.conflict,
          'A different ${differing.join(', ')} already exists here (an older or edited copy). Nothing was changed. '
          'Compare it with skills/$skillName/, or run again with --force to replace it (the old file is kept as <name>.bak).');
    }
    if (differing.any((f) =>
        FileSystemEntity.typeSync(p.join(target, f), followLinks: false) !=
        FileSystemEntityType.file)) {
      return _Result(agent, display, Status.conflict,
          'A non-file entry is in the way; move it, then run again.');
    }
  }

  if (dryRun) {
    return _Result(
        agent,
        display,
        differing.isEmpty ? Status.wouldInstall : Status.wouldReplace,
        differing.isEmpty
            ? null
            : 'would keep the old ${differing.join(', ')} as <name>.bak');
  }

  final createdDirs = <Directory>[];
  final tempFiles = <File>[];
  try {
    // Create missing directories, remembering which ones are new (for cleanup).
    final toCreate = <Directory>[];
    var d = Directory(target);
    while (!d.existsSync()) {
      toCreate.add(d);
      d = d.parent;
    }
    for (final dir in toCreate.reversed) {
      dir.createSync();
      createdDirs.add(dir);
    }
    final backups = <String>[];
    for (final entry in files.entries) {
      final dest = File(p.join(target, entry.key));
      final isDiff = differing.contains(entry.key);
      if (dest.existsSync() && !isDiff) continue;
      dest.parent.createSync(recursive: true);
      final tmp = File('${dest.path}.tmp-$pid');
      tempFiles.add(tmp);
      tmp.writeAsBytesSync(entry.value, flush: true);
      if (isDiff) {
        final bak = File('${dest.path}.bak');
        if (bak.existsSync()) bak.deleteSync();
        dest.renameSync(bak.path);
        backups.add(entry.key);
      }
      tmp.renameSync(dest.path);
    }
    // Verify what is on disk now.
    for (final entry in files.entries) {
      final f = File(p.join(target, entry.key));
      if (!f.existsSync() || !_same(f.readAsBytesSync(), entry.value)) {
        throw FileSystemException(
            'installed file does not match the source', f.path);
      }
    }
    return _Result(
        agent,
        display,
        Status.installed,
        backups.isEmpty
            ? null
            : 'replaced ${backups.join(', ')}; the previous copy is kept as <name>.bak');
  } on FileSystemException {
    // Best-effort cleanup of what this run created; pre-existing user files are never deleted.
    for (final t in tempFiles) {
      if (t.existsSync()) t.deleteSync();
    }
    for (final dir in createdDirs.reversed) {
      if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
    }
    rethrow;
  }
}

void main(List<String> args) {
  final scriptDir = p.dirname(p.fromUri(Platform.script));
  final root = Directory(p.normalize(p.join(scriptDir, '..')));
  exitCode = runInstaller(
    args,
    source: Directory(p.join(root.path, 'skills', skillName)),
    env: Platform.environment,
    cwd: Directory.current,
    out: stdout,
    err: stderr,
    repoRoot: root,
  );
}
