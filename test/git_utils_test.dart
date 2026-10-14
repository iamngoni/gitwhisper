import 'dart:io';
import 'dart:typed_data';

import 'package:gitwhisper/src/git_utils.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('GitUtils.getStagedDiff', () {
    late Directory repo;

    setUp(() async {
      repo = await Directory.systemTemp.createTemp('gitwhisper_diff_');
      Future<void> git(List<String> args) async {
        final result =
            await Process.run('git', args, workingDirectory: repo.path);
        if (result.exitCode != 0) {
          throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
        }
      }

      await git(['init']);
      await git(['config', 'user.email', 'test@example.com']);
      await git(['config', 'user.name', 'Test']);
    });

    tearDown(() async {
      if (repo.existsSync()) await repo.delete(recursive: true);
    });

    test('does not crash when staged content is not valid UTF-8', () async {
      // Bytes that are invalid UTF-8 (lone 0xFF/0xFE, then a bad continuation
      // sequence). Previously these crashed Process.run's UTF-8 stream decoder
      // with "Unexpected extension byte".
      final badBytes = Uint8List.fromList(
        <int>[0xFF, 0xFE, 0x00, ...'invalid'.codeUnits, 0xC0, 0xC1, 0x0A],
      );
      File(path.join(repo.path, 'bad.bin')).writeAsBytesSync(badBytes);

      final stage = await Process.run(
        'git',
        ['add', 'bad.bin'],
        workingDirectory: repo.path,
      );
      expect(stage.exitCode, 0);

      final diff = await GitUtils.getStagedDiff(folderPath: repo.path);

      // The call returns (no throw) and references the staged file.
      expect(diff, contains('bad.bin'));
    });
  });

  group('GitUtils from a subdirectory', () {
    late Directory repo;
    late String subdirectory;

    Future<void> git(List<String> args) async {
      final result =
          await Process.run('git', args, workingDirectory: repo.path);
      if (result.exitCode != 0) {
        throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
      }
    }

    setUp(() async {
      repo = await Directory.systemTemp.createTemp('gitwhisper_subdir_');
      await git(['init', '-q']);
      subdirectory = path.join(repo.path, 'sub');
      Directory(subdirectory).createSync();
    });

    tearDown(() async {
      if (repo.existsSync()) await repo.delete(recursive: true);
    });

    String canonical(String p) => Directory(p).resolveSymbolicLinksSync();

    test('getRepositoryRoot returns the top of the work tree', () async {
      final root = await GitUtils.getRepositoryRoot(folderPath: subdirectory);
      expect(canonical(root!), canonical(repo.path));
    });

    test('stageAllUnstagedFilesAndCount stages the whole repository', () async {
      File(path.join(repo.path, 'root.txt')).writeAsStringSync('root\n');
      File(path.join(subdirectory, 'sub.txt')).writeAsStringSync('sub\n');

      final staged = await GitUtils.stageAllUnstagedFilesAndCount(
        folderPath: subdirectory,
      );

      expect(staged, 2);
    });

    test('getLargeFiles resolves staged paths against the root', () async {
      File(path.join(repo.path, 'big.bin')).writeAsStringSync('x' * 64);
      File(path.join(repo.path, 'café.bin')).writeAsStringSync('y' * 64);
      File(path.join(repo.path, 'small.txt')).writeAsStringSync('s');
      await git(['add', '-A']);

      final largeFiles = await GitUtils.getLargeFiles(
        16,
        folderPath: subdirectory,
      );

      expect(
        largeFiles.map((file) => file.$1),
        unorderedEquals(['big.bin', 'café.bin']),
      );
    });

    test('unstageFile works on a branch with no commits yet', () async {
      File(path.join(subdirectory, 'big.bin')).writeAsStringSync('x' * 64);
      await git(['add', '-A']);

      await GitUtils.unstageFile('sub/big.bin', folderPath: subdirectory);

      final staged = await Process.run(
        'git',
        ['diff', '--cached', '--name-only'],
        workingDirectory: repo.path,
      );
      expect((staged.stdout as String).trim(), isEmpty);
      expect(File(path.join(subdirectory, 'big.bin')).existsSync(), isTrue);
    });

    test('addToGitignore writes the root .gitignore', () async {
      await GitUtils.addToGitignore('assets/big.bin', folderPath: subdirectory);

      expect(
        File(path.join(repo.path, '.gitignore')).readAsStringSync(),
        'assets/big.bin\n',
      );
      expect(File(path.join(subdirectory, '.gitignore')).existsSync(), isFalse);
    });
  });

  group('GitUtils.editorCommand', () {
    const tempFile = r'C:\Users\Jane Doe\AppData\Local\Temp\GITWHISPER_MSG';

    // Flattens (executable, arguments) so lists compare by value.
    List<String> command(String editor, String file, {required bool windows}) {
      final (executable, arguments) =
          GitUtils.editorCommand(editor, file, windows: windows);
      return [executable, ...arguments];
    }

    test('runs the editor through /bin/sh outside Windows', () {
      expect(
        command('code --wait', '/tmp/msg', windows: false),
        ['/bin/sh', '-c', 'code --wait "/tmp/msg"'],
      );
    });

    test('runs the editor through cmd /c on Windows', () {
      expect(
        command('code --wait', tempFile, windows: true),
        ['cmd', '/c', 'code', '--wait', tempFile],
      );
    });

    test('starts a quoted Windows editor path with spaces directly', () {
      expect(
        command(
          r'"C:\Program Files\Notepad++\notepad++.exe" -multiInst -nosession',
          tempFile,
          windows: true,
        ),
        [
          r'C:\Program Files\Notepad++\notepad++.exe',
          '-multiInst',
          '-nosession',
          tempFile,
        ],
      );
    });

    test('keeps a quoted Windows editor path without spaces in cmd', () {
      expect(
        command(r"'C:\tools\vim.exe'", tempFile, windows: true),
        ['cmd', '/c', r'C:\tools\vim.exe', tempFile],
      );
    });

    test('falls back to notepad for an empty Windows editor', () {
      expect(
        command('  ', tempFile, windows: true),
        ['notepad', tempFile],
      );
    });
  });

  group('GitUtils.sanitizeGeneratedCommitMessage', () {
    test('keeps plain commit messages unchanged', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'feat: Add local provider support',
        ),
        'feat: Add local provider support',
      );
    });

    test('extracts conventional commit lines from explanatory agent output',
        () {
      const raw = '''
Based on the staged changes, I can see:

1. **src/utils/utils.rs** - Added date formatting
2. **emails/*.html** - Redesigned templates

These are two distinct changes:

refactor: Redesign email templates with new brand identity

fix: Add German date formatting for payment emails
''';

      expect(
        GitUtils.sanitizeGeneratedCommitMessage(raw),
        '''
refactor: Redesign email templates with new brand identity
fix: Add German date formatting for payment emails
'''
            .trim(),
      );
    });

    test('preserves ticket-prefixed commit lines', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'Here you go:\n\nPAY-123 -> fix: Add payment date formatting',
        ),
        'PAY-123 -> fix: Add payment date formatting',
      );
    });

    test('extracts conventional commit from same-line agent preface', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          "I'll inspect the staged changes.docs: Add ACP smoke test note",
          requireConventionalCommit: true,
        ),
        'docs: Add ACP smoke test note',
      );
    });

    test('deduplicates repeated commit lines from agent output', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'feat: add ACP retry handling\nfeat: add ACP retry handling',
          requireConventionalCommit: true,
        ),
        'feat: add ACP retry handling',
      );
    });

    test('strict mode rejects planning text without commit lines', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          "I'll inspect the staged changes to generate the commit message.",
          requireConventionalCommit: true,
        ),
        isEmpty,
      );
    });

    group('with a configured prefix', () {
      for (final prefix in ['#42', 'proj-12', 'A-1', 'ENG_99', 'PAY-123']) {
        test('applies "$prefix" when the model left it out', () {
          expect(
            GitUtils.sanitizeGeneratedCommitMessage(
              'feat: Add dark mode toggle',
              requireConventionalCommit: true,
              prefix: prefix,
            ),
            '$prefix -> feat: Add dark mode toggle',
          );
        });

        test('keeps "$prefix" once when the model already wrote it', () {
          expect(
            GitUtils.sanitizeGeneratedCommitMessage(
              '$prefix -> feat: Add dark mode toggle',
              prefix: prefix,
            ),
            '$prefix -> feat: Add dark mode toggle',
          );
        });
      }

      test('replaces a prefix the model wrote in another form', () {
        expect(
          GitUtils.sanitizeGeneratedCommitMessage(
            'PROJ-12 -> fix: Handle empty input\n[proj 12] -> feat: Add toggle',
            prefix: 'proj-12',
          ),
          'proj-12 -> fix: Handle empty input\n'
          'proj-12 -> feat: Add toggle',
        );
      });

      test('applies the prefix to every commit line', () {
        expect(
          GitUtils.sanitizeGeneratedCommitMessage(
            'Here are the commits:\n\n'
            'feat: Add dark mode toggle\n'
            'fix: Handle empty input',
            requireConventionalCommit: true,
            prefix: '#42',
          ),
          '#42 -> feat: Add dark mode toggle\n'
          '#42 -> fix: Handle empty input',
        );
      });

      test('prefixes non-conventional output in lenient mode', () {
        expect(
          GitUtils.sanitizeGeneratedCommitMessage(
            'Add dark mode toggle',
            prefix: '#42',
          ),
          '#42 -> Add dark mode toggle',
        );
        expect(
          GitUtils.sanitizeGeneratedCommitMessage(
            '#42 -> Add dark mode toggle',
            prefix: '#42',
          ),
          '#42 -> Add dark mode toggle',
        );
      });
    });

    test('drops prose before an arrow when no prefix is configured', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'The commit message is -> feat: Add dark mode toggle',
        ),
        'feat: Add dark mode toggle',
      );
    });

    test('requires a word boundary before the commit type', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'Updated the default prefix: now reads from config',
          requireConventionalCommit: true,
        ),
        isEmpty,
      );
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'Updated the default prefix: now reads from config\n'
          'feat: Read the prefix from config',
          requireConventionalCommit: true,
        ),
        'feat: Read the prefix from config',
      );
    });

    test('normalises capitalised commit types to lowercase', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'Feat: Add dark mode\nFIX(api)!: Handle null bodies',
          requireConventionalCommit: true,
        ),
        'feat: Add dark mode\nfix(api)!: Handle null bodies',
      );
    });

    test('accepts list markers before a commit line', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          '- Feat: Add dark mode\n1. fix: Handle empty input',
          requireConventionalCommit: true,
        ),
        'feat: Add dark mode\nfix: Handle empty input',
      );
    });

    test('accepts and normalises the full-width colon', () {
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          'feat：添加深色模式\nFix：修复登录验证',
          requireConventionalCommit: true,
        ),
        'feat: 添加深色模式\nfix: 修复登录验证',
      );
      expect(
        GitUtils.sanitizeGeneratedCommitMessage(
          '提交信息如下：docs：更新说明',
          requireConventionalCommit: true,
          prefix: 'ENG_99',
        ),
        'ENG_99 -> docs: 更新说明',
      );
    });
  });
}
