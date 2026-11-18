/// Tests of `scripts/install_agent_skill.dart`. Everything runs in temporary directories with an
/// injected HOME; the real home directory and any real agent configuration are never touched.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../scripts/install_agent_skill.dart';

class _Run {
  _Run(this.code, this.out, this.err);
  final int code;
  final String out;
  final String err;
}

void main() {
  late Directory tmp;
  late Directory source;
  late Directory home;
  late Directory project;
  final skillSource = Directory('skills/widgettriage');

  _Run run(List<String> args,
      {Directory? src, Map<String, String>? env, Directory? repoRoot}) {
    final out = StringBuffer(), err = StringBuffer();
    final code = runInstaller(args,
        source: src ?? source,
        env: env ?? {'HOME': home.path},
        cwd: project,
        out: out,
        err: err,
        repoRoot: repoRoot);
    return _Run(code, out.toString(), err.toString());
  }

  String skillPath(String base, String agentDir) =>
      p.join(base, agentDir, 'skills', 'widgettriage', 'SKILL.md');
  String original() => File('skills/widgettriage/SKILL.md').readAsStringSync();

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wt_skill_test_');
    // A private copy of the real skill directory as the source.
    source = Directory(p.join(tmp.path, 'src', 'skills', 'widgettriage'))
      ..createSync(recursive: true);
    for (final f in skillSource.listSync(recursive: true).whereType<File>()) {
      final dest =
          File(p.join(source.path, p.relative(f.path, from: skillSource.path)));
      dest.parent.createSync(recursive: true);
      f.copySync(dest.path);
    }
    home = Directory(p.join(tmp.path, 'home'))..createSync();
    project = Directory(p.join(tmp.path, 'project'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('real skill source has the expected name', () {
    expect(original(), contains('name: widgettriage'));
  });

  group('install', () {
    test('Codex, project scope', () {
      final r = run(['--agent', 'codex', '--scope', 'project']);
      expect(r.code, 0, reason: r.out + r.err);
      expect(r.out, contains('INSTALLED'));
      expect(File(skillPath(project.path, '.agents')).readAsStringSync(),
          original());
      expect(Directory(p.join(project.path, '.claude')).existsSync(), isFalse);
    });

    test('Claude Code, project scope', () {
      final r = run(['--agent', 'claude', '--scope', 'project']);
      expect(r.code, 0, reason: r.out + r.err);
      expect(File(skillPath(project.path, '.claude')).readAsStringSync(),
          original());
      expect(Directory(p.join(project.path, '.agents')).existsSync(), isFalse);
    });

    test('both agents (default agent) with --project', () {
      final other = Directory(p.join(tmp.path, 'other'))..createSync();
      final r = run(['--project', other.path]);
      expect(r.code, 0, reason: r.out + r.err);
      expect(File(skillPath(other.path, '.agents')).readAsStringSync(),
          original());
      expect(File(skillPath(other.path, '.claude')).readAsStringSync(),
          original());
      expect(Directory(p.join(project.path, '.agents')).existsSync(), isFalse,
          reason: 'cwd must not be used when --project is given');
    });

    test('Codex, user scope', () {
      final r = run(['--agent', 'codex', '--scope', 'user']);
      expect(r.code, 0, reason: r.out + r.err);
      expect(
          File(skillPath(home.path, '.agents')).readAsStringSync(), original());
      expect(r.out, contains(p.join('~', '.agents', 'skills', 'widgettriage')));
    });

    test('Claude Code, user scope (Windows-style USERPROFILE only)', () {
      final r = run(['--agent', 'claude', '--scope', 'user'],
          env: {'USERPROFILE': home.path});
      expect(r.code, 0, reason: r.out + r.err);
      expect(
          File(skillPath(home.path, '.claude')).readAsStringSync(), original());
    });

    test('the source is not modified', () {
      final before = File(p.join(source.path, 'SKILL.md')).readAsBytesSync();
      run(['--agent', 'both']);
      expect(File(p.join(source.path, 'SKILL.md')).readAsBytesSync(), before);
    });
  });

  test('dry run changes nothing', () {
    final r = run(['--agent', 'both', '--scope', 'user', '--dry-run']);
    expect(r.code, 0);
    expect(r.out, contains('WOULD INSTALL'));
    expect(home.listSync(), isEmpty);
  });

  test('re-install is idempotent', () {
    expect(run(['--agent', 'both']).code, 0);
    final target = File(skillPath(project.path, '.agents'));
    final stamp = target.lastModifiedSync();
    final r = run(['--agent', 'both']);
    expect(r.code, 0);
    expect('ALREADY INSTALLED'.allMatches(r.out).length, 2);
    expect(target.lastModifiedSync(), stamp);
  });

  group('existing different skill', () {
    late File existing;
    setUp(() {
      existing = File(skillPath(project.path, '.agents'))
        ..createSync(recursive: true);
      existing.writeAsStringSync('my own edited skill\n');
    });

    test('is not overwritten and reports a conflict', () {
      final r = run(['--agent', 'codex']);
      expect(r.code, 1);
      expect(r.out, contains('CONFLICT'));
      expect(r.err, contains('--force'));
      expect(existing.readAsStringSync(), 'my own edited skill\n');
    });

    test(
        '--force replaces only that file and keeps a backup; neighbours untouched',
        () {
      final neighbour = File(
          p.join(project.path, '.agents', 'skills', 'other-skill', 'SKILL.md'))
        ..createSync(recursive: true);
      neighbour.writeAsStringSync('keep me');
      final extra = File(p.join(existing.parent.path, 'notes.txt'))
        ..writeAsStringSync('mine');
      final r = run(['--agent', 'codex', '--force']);
      expect(r.code, 0, reason: r.out + r.err);
      expect(existing.readAsStringSync(), original());
      expect(File('${existing.path}.bak').readAsStringSync(),
          'my own edited skill\n');
      expect(neighbour.readAsStringSync(), 'keep me');
      expect(extra.readAsStringSync(), 'mine');
    });

    test('--force with --dry-run changes nothing', () {
      final r = run(['--agent', 'codex', '--force', '--dry-run']);
      expect(r.code, 0);
      expect(r.out, contains('WOULD REPLACE'));
      expect(existing.readAsStringSync(), 'my own edited skill\n');
      expect(File('${existing.path}.bak').existsSync(), isFalse);
    });
  });

  group('errors', () {
    test('unknown option', () {
      final r = run(['--bogus']);
      expect(r.code, 2);
      expect(r.err, contains('--bogus'));
    });

    test('invalid --agent value', () {
      expect(run(['--agent', 'gemini']).code, 2);
    });

    test('unexpected positional argument', () {
      expect(run(['codex']).code, 2);
    });

    test('--help exits 0', () {
      final r = run(['--help']);
      expect(r.code, 0);
      expect(r.out, contains('--dry-run'));
    });

    test('missing source', () {
      final r =
          run(['--agent', 'codex'], src: Directory(p.join(tmp.path, 'nope')));
      expect(r.code, 2);
      expect(r.err, contains('skill source not found'));
      expect(Directory(p.join(project.path, '.agents')).existsSync(), isFalse);
    });

    test('missing home for user scope', () {
      final r = run(['--scope', 'user'], env: {});
      expect(r.code, 2);
      expect(r.err, contains('home directory'));
    });

    test('project directory that does not exist', () {
      expect(run(['--project', p.join(tmp.path, 'missing')]).code, 2);
    });

    test('refuses to install into the WidgetTriage checkout itself', () {
      final r = run(['--agent', 'codex', '--project', project.path],
          repoRoot: project);
      expect(r.code, 2);
      expect(r.err, contains('--project'));
      expect(Directory(p.join(project.path, '.agents')).existsSync(), isFalse);
    });

    test('a target directory cannot be created', () {
      File(p.join(project.path, '.agents')).writeAsStringSync('i am a file');
      final r = run(['--agent', 'codex']);
      expect(r.code, 1);
      expect(r.out, contains('FAILED'));
      expect(File(p.join(project.path, '.agents')).readAsStringSync(),
          'i am a file');
    });

    test(
        'one agent fails, the other is still installed and reported independently',
        () {
      File(p.join(project.path, '.agents')).writeAsStringSync('i am a file');
      final r = run(['--agent', 'both']);
      expect(r.code, 1);
      expect(r.out, contains('Codex       FAILED'));
      expect(r.out, contains('Claude Code INSTALLED'));
      expect(File(skillPath(project.path, '.claude')).readAsStringSync(),
          original());
      expect(Directory(p.join(project.path, '.agents')).existsSync(),
          isFalse); // is a file
    });

    test(
        'a symlink at the target is a conflict, even with --force, and is not followed',
        () {
      final elsewhere = Directory(p.join(tmp.path, 'elsewhere'))..createSync();
      final link =
          Link(p.join(project.path, '.claude', 'skills', 'widgettriage'))
            ..createSync(elsewhere.path, recursive: true);
      for (final args in [
        ['--agent', 'claude'],
        ['--agent', 'claude', '--force']
      ]) {
        final r = run(args);
        expect(r.code, 1, reason: r.out + r.err);
        expect(r.out, contains('CONFLICT'));
        expect(elsewhere.listSync(), isEmpty);
        expect(link.existsSync(), isTrue);
      }
    },
        skip: Platform.isWindows
            ? 'creating symlinks needs privileges on Windows'
            : false);

    test('a planted predictable temp-name symlink is never written through',
        () {
      final outside = File(p.join(tmp.path, 'outside.txt'))
        ..writeAsStringSync('precious');
      final dir =
          Directory(p.join(project.path, '.agents', 'skills', 'widgettriage'))
            ..createSync(recursive: true);
      for (final name in ['SKILL.md.tmp-$pid', 'SKILL.md.tmp', '0']) {
        Link(p.join(dir.path, name)).createSync(outside.path);
      }
      final r = run(['--agent', 'codex']);
      expect(r.code, 0, reason: r.out + r.err);
      expect(outside.readAsStringSync(), 'precious');
      final skill = p.join(dir.path, 'SKILL.md');
      expect(FileSystemEntity.typeSync(skill, followLinks: false),
          FileSystemEntityType.file);
      expect(File(skill).readAsStringSync(), original());
      expect(
          dir
              .listSync()
              .where((e) => p.basename(e.path).startsWith('.wt-install-')),
          isEmpty);
    },
        skip: Platform.isWindows
            ? 'creating symlinks needs privileges on Windows'
            : false);

    test('a symlink inside the skill source is refused', () {
      Link(p.join(source.path, 'link.md'))
          .createSync(p.join(source.path, 'SKILL.md'));
      final r = run(['--agent', 'codex']);
      expect(r.code, 2);
      expect(r.err, contains('symbolic link'));
    },
        skip: Platform.isWindows
            ? 'creating symlinks needs privileges on Windows'
            : false);
  });

  group('parent directory symlink (shared dotfiles style)', () {
    late Directory external;
    setUp(() {
      external = Directory(p.join(tmp.path, 'shared-agents'))..createSync();
      Link(p.join(project.path, '.agents')).createSync(external.path);
    });

    test(
        'installs through the link, reports the real location, keeps existing files',
        () {
      final precious =
          File(p.join(external.path, 'skills', 'other', 'SKILL.md'))
            ..createSync(recursive: true)
            ..writeAsStringSync('precious');
      final r = run(['--agent', 'codex']);
      expect(r.code, 0, reason: r.out + r.err);
      expect(
          File(p.join(external.path, 'skills', 'widgettriage', 'SKILL.md'))
              .readAsStringSync(),
          original());
      expect(precious.readAsStringSync(), 'precious');
      expect(r.out, contains('a parent directory is a symbolic link'));
      expect(r.out, contains(p.join(external.path, 'skills', 'widgettriage')));
    });

    test('dry run writes nothing behind the link and still reports it', () {
      final r = run(['--agent', 'codex', '--dry-run']);
      expect(r.code, 0, reason: r.out + r.err);
      expect(r.out, contains('WOULD INSTALL'));
      expect(r.out, contains('a parent directory is a symbolic link'));
      expect(external.listSync(), isEmpty);
    });

    test('no note when nothing is linked', () {
      final r = run(['--agent', 'claude']);
      expect(r.out, isNot(contains('symbolic link')));
    });

    test('a symlinked widgettriage directory is still a conflict', () {
      final elsewhere = Directory(p.join(tmp.path, 'elsewhere'))..createSync();
      Directory(p.join(external.path, 'skills')).createSync();
      Link(p.join(external.path, 'skills', 'widgettriage'))
          .createSync(elsewhere.path);
      final r = run(['--agent', 'codex', '--force']);
      expect(r.code, 1);
      expect(r.out, contains('CONFLICT'));
      expect(elsewhere.listSync(), isEmpty);
    });
  },
      skip: Platform.isWindows
          ? 'creating symlinks needs privileges on Windows'
          : false);

  group('resolveHome', () {
    bool Function(String) dirs(Set<String> existing) => existing.contains;

    test('HOME wins when valid', () {
      expect(
          resolveHome({'HOME': '/h', 'USERPROFILE': '/u'},
              isWindows: false, isDirectory: dirs({'/h', '/u'})),
          '/h');
    });
    test('empty HOME falls back to USERPROFILE', () {
      expect(
          resolveHome({'HOME': '', 'USERPROFILE': '/u'},
              isWindows: false, isDirectory: dirs({'/u'})),
          '/u');
    });
    test('HOME that is not an existing directory falls back to USERPROFILE',
        () {
      expect(
          resolveHome({'HOME': '/gone', 'USERPROFILE': '/u'},
              isWindows: false, isDirectory: dirs({'/u'})),
          '/u');
    });
    test(
        'Windows: a POSIX-style HOME is skipped even if that path happens to exist',
        () {
      expect(
          resolveHome({'HOME': '/home/user', 'USERPROFILE': r'C:\Users\me'},
              isWindows: true,
              isDirectory: dirs({'/home/user', r'C:\Users\me'})),
          r'C:\Users\me');
    });
    test('Windows: a real absolute HOME is used', () {
      expect(
          resolveHome({'HOME': r'D:\home', 'USERPROFILE': r'C:\Users\me'},
              isWindows: true, isDirectory: dirs({r'D:\home', r'C:\Users\me'})),
          r'D:\home');
    });
    test('Windows: invalid HOME and USERPROFILE give null', () {
      expect(
          resolveHome({'HOME': '/home/user', 'USERPROFILE': r'C:\missing'},
              isWindows: true, isDirectory: dirs({'/home/user'})),
          isNull);
    });
    test('neither set gives null; nothing is created', () {
      expect(resolveHome({}, isWindows: false, isDirectory: dirs({})), isNull);
    });
    test('a HOME that is a file is not a home directory', () {
      final f = File(p.join(tmp.path, 'afile'))..writeAsStringSync('x');
      final r = run(['--scope', 'user'],
          env: {'HOME': f.path, 'USERPROFILE': home.path});
      expect(r.code, 0, reason: r.out + r.err);
      expect(File(skillPath(home.path, '.agents')).existsSync(), isTrue);
    });
    test('both invalid: usage error naming both variables', () {
      final r = run([
        '--scope',
        'user'
      ], env: {
        'HOME': p.join(tmp.path, 'no'),
        'USERPROFILE': p.join(tmp.path, 'no2')
      });
      expect(r.code, 2);
      expect(r.err, allOf(contains('HOME'), contains('USERPROFILE')));
      expect(Directory(p.join(tmp.path, 'no')).existsSync(), isFalse);
    });
  });

  group('--project errors', () {
    test('a file is "not a directory"', () {
      final f = File(p.join(tmp.path, 'projfile'))..writeAsStringSync('x');
      final r = run(['--project', f.path]);
      expect(r.code, 2);
      expect(r.err, contains('Project path is not a directory'));
      expect(r.err, isNot(contains('does not exist')));
    });
    test('a missing path "does not exist" and is not created', () {
      final missing = p.join(tmp.path, 'missing');
      final r = run(['--project', missing]);
      expect(r.code, 2);
      expect(r.err, contains('Project directory does not exist'));
      expect(Directory(missing).existsSync(), isFalse);
    });
    test('an unreadable directory is "cannot access"', () {
      final d = Directory(p.join(tmp.path, 'locked'))..createSync();
      Process.runSync('chmod', ['000', d.path]);
      addTearDown(() => Process.runSync('chmod', ['755', d.path]));
      if (Process.runSync('id', ['-u']).stdout.toString().trim() == '0') {
        markTestSkipped('running as root: permissions are not enforced');
        return;
      }
      final r = run(['--project', d.path]);
      expect(r.code, 2);
      expect(r.err, contains('Cannot access project directory'));
    }, skip: Platform.isWindows ? 'POSIX permissions' : false);
  });

  group('displayPath', () {
    test('Windows style', () {
      expect(
          displayPath(
              r'C:\Users\me\.agents\skills\widgettriage', r'C:\Users\me',
              prefix: '~', ctx: p.windows),
          r'~\.agents\skills\widgettriage');
      expect(
          displayPath(r'D:\proj\.claude\skills\widgettriage', r'D:\proj',
              ctx: p.windows),
          r'.claude\skills\widgettriage');
    });
    test('POSIX style', () {
      expect(
          displayPath('/home/me/.agents/skills/widgettriage', '/home/me',
              prefix: '~', ctx: p.posix),
          '~/.agents/skills/widgettriage');
    });
    test('real run prints the platform style and no absolute home path', () {
      final r = run(['--agent', 'both', '--scope', 'user']);
      expect(
          r.out,
          contains(displayPath(
              p.join(home.path, '.claude', 'skills', 'widgettriage'), home.path,
              prefix: '~')));
      expect(r.out, isNot(contains(home.path)));
    });
  });

  test('CLI entry point: --help and a real dry run from a script process', () {
    final help = Process.runSync(Platform.resolvedExecutable,
        ['run', 'scripts/install_agent_skill.dart', '--help']);
    expect(help.exitCode, 0);
    expect(help.stdout as String, contains('--agent'));
    final dry = Process.runSync(
        Platform.resolvedExecutable,
        [
          p.absolute('scripts/install_agent_skill.dart'),
          '--agent',
          'both',
          '--project',
          project.path,
          '--dry-run'
        ],
        workingDirectory: Directory.current.path);
    expect(dry.exitCode, 0, reason: '${dry.stdout}${dry.stderr}');
    expect(project.listSync(), isEmpty);
  });
}
